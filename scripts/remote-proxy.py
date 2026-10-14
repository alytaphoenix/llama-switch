#!/usr/bin/env python3
"""llama-switch front proxy: owns the public API port, llama-swap sits behind it.

Why this exists
---------------
llama-swap 404s a request that carries no usable ``model`` field
("no model id could be identified"). A single-primary deployment still wants
other models switchable on the same port, and clients that legitimately omit
the field (curl without a model, SDKs with no configured default, ad-hoc probes)
should not have to care. Rather than depend on a feature that may not exist in
whatever llama-swap build is installed, llama-switch owns the public port and
injects the default itself.

Design
------
* The proxy binds the public port; llama-swap is started on an internal
  loopback port and becomes an implementation detail.
* ``--default-model`` names the model served when a request has none.
  An explicit ``model`` in the body always wins.
* Injection is deliberately narrow, so it cannot corrupt a request:
  - only ``application/json`` bodies are ever touched (multipart uploads -
    the ASR/image endpoints - always carry ``model`` explicitly),
  - only when the decoded object is a dict with no non-empty ``model``,
  - never on ``/upstream/<model>/...``, which addresses one model directly.
* Bodies that are not injected are streamed straight through, so large
  multipart uploads are never buffered.
* Responses are streamed too, including SSE, so a proxied streaming chat
  completion keeps its time-to-first-token.

Run on the serving box; see scripts/remote-lib.sh for the wiring.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import socket
import socketserver
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Hop-by-hop headers must not be forwarded in either direction (RFC 9110).
HOP_BY_HOP = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    }
)

# Guard against a hostile or broken Content-Length. Request bodies are only
# buffered when we inject a model into them (JSON, so small in practice); this
# bounds the damage if something sends a huge JSON body.
MAX_BUFFERED_BODY = 64 * 1024 * 1024

# Chunk size for response streaming. Small enough to keep SSE latency low.
STREAM_CHUNK = 64 * 1024

# Marker header so an operator (and the benchmark harness) can tell that the
# proxy, not the client, chose the model.
INJECTED_HEADER = "X-Llama-Switch-Default-Model"


def is_json_content_type(content_type: str | None) -> bool:
    if not content_type:
        return False
    return content_type.split(";", 1)[0].strip().lower() in (
        "application/json",
        "text/json",
    )


def should_inject(path: str, method: str, content_type: str | None, default_model: str) -> bool:
    """Decide whether this request is a candidate for default-model injection.

    Kept as a pure predicate so it can be tested without a socket.
    """
    if not default_model:
        return False
    if method not in ("POST", "PUT", "PATCH"):
        return False
    # /upstream/<model>/... always names its model in the path.
    if path.startswith("/upstream/"):
        return False
    return is_json_content_type(content_type)


def inject_default_model(body: bytes, default_model: str) -> tuple[bytes, bool]:
    """Return (body_to_forward, injected).

    Only acts on a JSON object whose ``model`` is absent, null or empty. A
    malformed or non-object JSON body is forwarded untouched: rejecting it here
    would invent an error the upstream is better placed to report.
    """
    if not body:
        return body, False
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return body, False
    if not isinstance(payload, dict):
        return body, False
    model = payload.get("model")
    if isinstance(model, str) and model != "":
        return body, False
    payload["model"] = default_model
    encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    return encoded, True


class _LengthReader:
    """Read exactly ``length`` bytes from a stream, for streaming pass-through.

    http.client accepts a file-like body plus an explicit Content-Length and
    reads it in blocks, so an upload proxy never buffers the whole payload.
    """

    def __init__(self, stream, length: int):
        self._stream = stream
        self._remaining = length

    def read(self, size: int = -1) -> bytes:
        if self._remaining <= 0:
            return b""
        if size is None or size < 0:
            size = self._remaining
        size = min(size, self._remaining)
        chunk = self._stream.read(size)
        if not chunk:
            # Truncated upload: stop rather than spin.
            self._remaining = 0
            return b""
        self._remaining -= len(chunk)
        return chunk


class _ChunkedReader:
    """Decode a chunked request body so it can be buffered for injection."""

    def __init__(self, stream):
        self._stream = stream

    def read(self, size: int = -1) -> bytes:
        out = bytearray()
        while True:
            line = self._stream.readline(65536).strip()
            if not line:
                break
            try:
                length = int(line.split(b";", 1)[0], 16)
            except ValueError:
                break
            if length == 0:
                # consume trailer
                while True:
                    trailer = self._stream.readline(65536)
                    if trailer in (b"", b"\r\n", b"\n"):
                        break
                break
            remaining = length
            while remaining > 0:
                chunk = self._stream.read(min(remaining, STREAM_CHUNK))
                if not chunk:
                    break
                out += chunk
                remaining -= len(chunk)
            self._stream.read(2)  # trailing CRLF
            if len(out) > MAX_BUFFERED_BODY:
                break
        return bytes(out)


class ProxyHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "llama-switch/1.0"
    sys_version = ""

    # Injected by make_server().
    backend_host = "127.0.0.1"
    backend_port = 0
    default_model = ""
    access_log = False

    # Set per-request when this request's model was substituted, so _relay can
    # echo the substitution back to the client. Per-request, not shared state:
    # the server is threaded.
    _injected = False

    # -------------------------------------------------------------- helpers
    def log_message(self, fmt, *args):  # noqa: A003 - BaseHTTPRequestHandler API
        if self.access_log:
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _error_envelope(self, status: int, code: str, message: str) -> bytes:
        """OpenAI-compatible error body, matching llama-swap's shape."""
        return json.dumps(
            {
                "src": "llama-switch",
                "error": {
                    "message": message,
                    "type": "server_error",
                    "param": None,
                    "code": code,
                },
            }
        ).encode("utf-8")

    def _send_error_envelope(self, status: int, code: str, message: str) -> None:
        body = self._error_envelope(status, code, message)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _read_body(self):
        """Return (body_or_reader, content_length).

        A bytes body means it was buffered (injection path or a chunked
        request); a file-like object means stream it through untouched.
        """
        te = (self.headers.get("Transfer-Encoding") or "").lower()
        if "chunked" in te:
            return _ChunkedReader(self.rfile).read(), None

        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            return None, None
        try:
            length = int(raw_length)
        except ValueError:
            return None, None
        if length <= 0:
            return None, None
        return _LengthReader(self.rfile, length), length

    # ------------------------------------------------------------- forwarding
    def _proxy(self) -> None:
        content_type = self.headers.get("Content-Type")
        body, content_length = self._read_body()
        injected = False
        self._injected = False

        if should_inject(self.path, self.command, content_type, self.default_model):
            raw = body.read() if hasattr(body, "read") else (body or b"")
            if len(raw) > MAX_BUFFERED_BODY:
                self._send_error_envelope(
                    413, "request_too_large", "request body too large to inspect"
                )
                return
            new_body, injected = inject_default_model(raw, self.default_model)
            # Always forward the buffered bytes, not the drained reader: the
            # reader is at EOF now, and pairing it with the original
            # Content-Length would make the backend wait for a body that has
            # already been consumed.
            body = new_body
            content_length = len(new_body)
            self._injected = injected

        headers = {}
        for key, value in self.headers.items():
            if key.lower() in HOP_BY_HOP or key.lower() == "content-length":
                continue
            headers[key] = value
        if injected:
            headers[INJECTED_HEADER] = self.default_model
        if body is None:
            pass
        elif content_length is not None:
            headers["Content-Length"] = str(content_length)

        try:
            conn = http.client.HTTPConnection(
                self.backend_host, self.backend_port, timeout=None
            )
            conn.request(self.command, self.path, body=body, headers=headers)
            resp = conn.getresponse()
        except (OSError, http.client.HTTPException) as exc:
            self._send_error_envelope(
                502,
                "backend_unavailable",
                "llama-swap backend is unreachable: %s" % exc,
            )
            return

        try:
            self._relay(resp)
        finally:
            conn.close()

    def _relay(self, resp) -> None:
        self.send_response_only(resp.status, resp.reason)

        # Echo the substitution back to the caller so an operator (and the
        # benchmark harness) can tell the proxy chose the model, not the client.
        if self._injected:
            self.send_header(INJECTED_HEADER, self.default_model)

        content_length = resp.getheader("Content-Length")
        for key, value in resp.getheaders():
            lowered = key.lower()
            if lowered in HOP_BY_HOP or lowered == "content-length":
                continue
            self.send_header(key, value)

        # A backend Content-Length is passed through so the client can reuse the
        # connection. Otherwise the body is framed as chunked, which keeps
        # streaming (SSE) responses streaming instead of buffering them.
        if content_length is not None:
            self.send_header("Content-Length", content_length)
            chunked = False
        else:
            self.send_header("Transfer-Encoding", "chunked")
            chunked = True
        self.end_headers()

        if self.command == "HEAD":
            return

        # read1() returns as soon as any data is available. Plain read(n)
        # blocks until it has n bytes, which for an SSE stream means the client
        # sees nothing until the whole generation is done — TTFT would collapse
        # to total latency.
        read = getattr(resp, "read1", None) or resp.read

        try:
            while True:
                chunk = read(STREAM_CHUNK)
                if not chunk:
                    break
                if chunked:
                    self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                else:
                    self.wfile.write(chunk)
                self.wfile.flush()
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # The client hung up mid-stream (a cancelled generation, typically).
            # The upstream request is torn down with the connection below.
            self.close_connection = True

    # One entry point per method: the proxy is transparent.
    def do_GET(self):  # noqa: N802 - BaseHTTPRequestHandler API
        self._proxy()

    def do_HEAD(self):  # noqa: N802
        self._proxy()

    def do_POST(self):  # noqa: N802
        self._proxy()

    def do_PUT(self):  # noqa: N802
        self._proxy()

    def do_PATCH(self):  # noqa: N802
        self._proxy()

    def do_DELETE(self):  # noqa: N802
        self._proxy()

    def do_OPTIONS(self):  # noqa: N802
        self._proxy()


class ThreadedProxy(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    # A big model can hold a request open for minutes; the default 5s backlog
    # plus OS accept queue is fine, but be explicit rather than incidental.
    request_queue_size = 128


def make_server(
    listen_host: str,
    listen_port: int,
    backend_host: str,
    backend_port: int,
    default_model: str,
    access_log: bool = False,
) -> ThreadedProxy:
    handler = type(
        "BoundProxyHandler",
        (ProxyHandler,),
        {
            "backend_host": backend_host,
            "backend_port": backend_port,
            "default_model": default_model,
            "access_log": access_log,
        },
    )
    return ThreadedProxy((listen_host, listen_port), handler)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--listen-host", default="0.0.0.0")
    parser.add_argument("--listen-port", type=int, default=8731)
    parser.add_argument("--backend-host", default="127.0.0.1")
    parser.add_argument(
        "--backend-port",
        type=int,
        default=int(os.environ.get("LS_BACKEND_PORT", "8732")),
    )
    parser.add_argument(
        "--default-model",
        default=os.environ.get("LS_DEFAULT_MODEL", ""),
        help="model served when a request carries none (empty = passthrough)",
    )
    parser.add_argument("--access-log", action="store_true")
    args = parser.parse_args(argv)

    if not 0 <= args.listen_port <= 65535 or not 0 <= args.backend_port <= 65535:
        parser.error("ports must be between 0 and 65535")
    if args.listen_port == args.backend_port:
        parser.error("the proxy and the backend cannot share a port")

    server = make_server(
        args.listen_host,
        args.listen_port,
        args.backend_host,
        args.backend_port,
        args.default_model,
        args.access_log,
    )
    mode = "default=%s" % (args.default_model or "<none: passthrough>")
    sys.stderr.write(
        "[llama-switch] listening on %s:%d -> %s:%d (%s)\n"
        % (
            args.listen_host,
            server.server_address[1],
            args.backend_host,
            args.backend_port,
            mode,
        )
    )
    sys.stderr.flush()

    def _shutdown(_signum, _frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    try:
        import signal

        signal.signal(signal.SIGTERM, _shutdown)
        signal.signal(signal.SIGINT, _shutdown)
    except (ImportError, ValueError):
        # Not the main thread, or no signals on this platform: serve anyway.
        pass

    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
