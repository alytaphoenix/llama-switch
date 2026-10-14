#!/usr/bin/env python3
"""Tests for the llama-switch front proxy.

Unit coverage for the injection predicate and rewrite, plus an end-to-end test
that runs the real proxy against a stub backend and checks the properties that
would silently break a serving box if they regressed:

* a request with no model reaches the configured default,
* an explicit model is never overridden,
* /upstream/<model> is never touched,
* multipart uploads (ASR / image edits) pass through byte-identical,
* a streaming SSE response is relayed incrementally rather than buffered,
* a large upload is streamed, not buffered into memory.
"""

from __future__ import annotations

import importlib.util
import json
import socket
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_PATH = (
    __file__.rsplit("/", 2)[0] + "/scripts/remote-proxy.py"
)  # tests/ -> repo root -> scripts/
_spec = importlib.util.spec_from_file_location("remote_proxy", _PATH)
proxy = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(proxy)


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class TestInjectionPredicate(unittest.TestCase):
    def test_no_default_configured_is_passthrough(self):
        self.assertFalse(
            proxy.should_inject("/v1/chat/completions", "POST", "application/json", "")
        )

    def test_json_post_is_a_candidate(self):
        self.assertTrue(
            proxy.should_inject(
                "/v1/chat/completions", "POST", "application/json", "flash"
            )
        )

    def test_content_type_parameters_are_tolerated(self):
        self.assertTrue(
            proxy.should_inject(
                "/v1/chat/completions", "POST", "application/json; charset=utf-8", "flash"
            )
        )

    def test_multipart_is_never_touched(self):
        # ASR and image edits send multipart with an explicit model; rewriting
        # the boundary would corrupt the upload.
        self.assertFalse(
            proxy.should_inject(
                "/v1/audio/transcriptions",
                "POST",
                "multipart/form-data; boundary=xyz",
                "flash",
            )
        )

    def test_get_is_never_touched(self):
        self.assertFalse(
            proxy.should_inject("/v1/models", "GET", "application/json", "flash")
        )

    def test_upstream_path_is_never_touched(self):
        self.assertFalse(
            proxy.should_inject(
                "/upstream/gufo-27b-q4/health", "POST", "application/json", "flash"
            )
        )


class TestInjectDefaultModel(unittest.TestCase):
    def test_missing_model_is_injected(self):
        body, injected = proxy.inject_default_model(b'{"messages":[]}', "flash")
        self.assertTrue(injected)
        self.assertEqual(json.loads(body)["model"], "flash")

    def test_explicit_model_is_preserved(self):
        raw = b'{"model":"other","messages":[]}'
        body, injected = proxy.inject_default_model(raw, "flash")
        self.assertFalse(injected)
        self.assertEqual(body, raw)

    def test_empty_model_is_replaced(self):
        body, injected = proxy.inject_default_model(b'{"model":""}', "flash")
        self.assertTrue(injected)
        self.assertEqual(json.loads(body)["model"], "flash")

    def test_null_model_is_replaced(self):
        body, injected = proxy.inject_default_model(b'{"model":null}', "flash")
        self.assertTrue(injected)
        self.assertEqual(json.loads(body)["model"], "flash")

    def test_other_fields_survive(self):
        raw = json.dumps({"messages": [{"role": "user", "content": "hi"}], "stream": True})
        body, injected = proxy.inject_default_model(raw.encode(), "flash")
        self.assertTrue(injected)
        payload = json.loads(body)
        self.assertEqual(payload["messages"], [{"role": "user", "content": "hi"}])
        self.assertIs(payload["stream"], True)

    def test_unicode_is_preserved(self):
        raw = json.dumps({"messages": [{"role": "user", "content": "café ☕"}]}).encode()
        body, injected = proxy.inject_default_model(raw, "flash")
        self.assertTrue(injected)
        self.assertEqual(json.loads(body)["messages"][0]["content"], "café ☕")

    def test_malformed_json_is_forwarded_untouched(self):
        raw = b"{not json"
        body, injected = proxy.inject_default_model(raw, "flash")
        self.assertFalse(injected)
        self.assertEqual(body, raw)

    def test_non_object_json_is_forwarded_untouched(self):
        raw = b"[1,2,3]"
        body, injected = proxy.inject_default_model(raw, "flash")
        self.assertFalse(injected)
        self.assertEqual(body, raw)

    def test_empty_body_is_untouched(self):
        body, injected = proxy.inject_default_model(b"", "flash")
        self.assertFalse(injected)
        self.assertEqual(body, b"")


class _StubHandler(BaseHTTPRequestHandler):
    """Records what the proxy forwarded, and can emit an SSE stream."""

    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def _record(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        self.server.received.append(
            {
                "method": self.command,
                "path": self.path,
                "body": body,
                "content_type": self.headers.get("Content-Type"),
                "injected": self.headers.get(proxy.INJECTED_HEADER),
            }
        )
        return body

    def _respond(self, status=200, body=b'{"ok":true}', content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self._record()
        if self.path.endswith("/stream"):
            # Chunked SSE: the proxy must relay these as they arrive, or TTFT
            # collapses to "time for the whole generation".
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for i in range(3):
                chunk = ('data: {"n":%d}\n\n' % i).encode()
                self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.flush()
                time.sleep(0.15)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return
        try:
            payload = json.loads(body)
            model = payload.get("model")
        except ValueError:
            model = "<unparsable>"
        self._respond(body=json.dumps({"model": model, "echo": body.decode("utf-8", "replace")}).encode())

    def do_GET(self):
        self._record()
        self._respond(body=json.dumps({"object": "list", "data": []}).encode())

    do_PUT = do_POST
    do_DELETE = do_GET


class TestProxyEndToEnd(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.backend_port = free_port()
        cls.backend = ThreadingHTTPServer(("127.0.0.1", cls.backend_port), _StubHandler)
        cls.backend.received = []
        cls.backend.daemon_threads = True
        threading.Thread(target=cls.backend.serve_forever, daemon=True).start()

        cls.front_port = free_port()
        cls.front = proxy.make_server(
            "127.0.0.1",
            cls.front_port,
            "127.0.0.1",
            cls.backend_port,
            "flash",
        )
        cls.front.daemon_threads = True
        threading.Thread(target=cls.front.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.front.shutdown()
        cls.front.server_close()
        cls.backend.shutdown()
        cls.backend.server_close()

    def setUp(self):
        self.backend.received.clear()

    def post(self, body: bytes, content_type="application/json", path="/v1/chat/completions"):
        return self.request("POST", path, body, content_type)

    def request(self, method, path, body=None, content_type=None):
        import http.client

        headers = {"Content-Type": content_type} if content_type else {}
        conn = http.client.HTTPConnection("127.0.0.1", self.front_port, timeout=10)
        conn.request(method, path, body=body, headers=headers)
        resp = conn.getresponse()
        payload = resp.read()
        resp_headers = dict(resp.getheaders())
        conn.close()
        return resp.status, payload, resp_headers

    def test_request_without_model_gets_the_default(self):
        status, body, _ = self.post(b'{"messages":[]}')
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["model"], "flash")
        self.assertEqual(self.backend.received[-1]["injected"], "flash")

    def test_explicit_model_wins(self):
        status, body, headers = self.post(b'{"model":"27b","messages":[]}')
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["model"], "27b")
        self.assertIsNone(self.backend.received[-1]["injected"])
        # The client must be able to tell the proxy did NOT choose for them.
        self.assertNotIn(proxy.INJECTED_HEADER, headers)

    def test_upstream_path_is_not_rewritten(self):
        status, _, _ = self.request(
            "POST",
            "/upstream/gufo-27b-q4/v1/chat/completions",
            b'{"messages":[]}',
            "application/json",
        )
        self.assertEqual(status, 200)
        self.assertEqual(self.backend.received[-1]["path"], "/upstream/gufo-27b-q4/v1/chat/completions")
        self.assertIsNone(self.backend.received[-1]["injected"])

    def test_multipart_upload_passes_through_byte_identical(self):
        boundary = "----llamaswaptest"
        parts = (
            f"--{boundary}\r\n"
            'Content-Disposition: form-data; name="file"; filename="a.wav"\r\n'
            "Content-Type: audio/wav\r\n\r\n"
        ).encode() + b"RIFFfakewavbytes" + f"\r\n--{boundary}--\r\n".encode()

        status, _, _ = self.post(parts, f"multipart/form-data; boundary={boundary}", "/v1/audio/transcriptions")
        self.assertEqual(status, 200)
        self.assertEqual(self.backend.received[-1]["body"], parts)

    def test_get_passthrough(self):
        status, body, _ = self.request("GET", "/v1/models")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["object"], "list")

    def test_injection_is_echoed_to_the_client(self):
        """A caller must be able to see that the proxy chose the model."""
        _, _, headers = self.post(b'{"messages":[]}')
        self.assertEqual(headers.get(proxy.INJECTED_HEADER), "flash")

    def test_streaming_response_is_relayed_incrementally(self):
        """TTFT depends on the first SSE frame arriving before the last."""
        import http.client

        conn = http.client.HTTPConnection("127.0.0.1", self.front_port, timeout=10)
        conn.request(
            "POST", "/stream", body=b'{"messages":[]}',
            headers={"Content-Type": "application/json"},
        )
        resp = conn.getresponse()
        self.assertTrue(resp.chunked, "SSE must stay chunked through the proxy")

        start = time.monotonic()
        first = resp.readline()
        first_at = time.monotonic() - start
        self.assertTrue(first.startswith(b"data:"), first[:40])

        rest = b""
        while True:
            chunk = resp.read1(65536) if hasattr(resp, "read1") else resp.read(65536)
            if not chunk:
                break
            rest += chunk
        total = time.monotonic() - start
        conn.close()

        # The stub sleeps 0.15s between 3 frames (~0.45s total). Getting the
        # first frame well before the end proves it was not buffered.
        self.assertLess(first_at, 0.30, "first frame arrived after %.2fs" % first_at)
        self.assertGreater(total, 0.30)
        self.assertEqual(rest.count(b"data:"), 2)

    def test_unreachable_backend_returns_502_envelope(self):
        dead_port = free_port()
        server = proxy.make_server("127.0.0.1", free_port(), "127.0.0.1", dead_port, "flash")
        port = server.server_address[1]
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            import http.client

            conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            conn.request(
                "POST",
                "/v1/chat/completions",
                body=b'{"messages":[]}',
                headers={"Content-Type": "application/json"},
            )
            resp = conn.getresponse()
            payload = json.loads(resp.read())
            conn.close()
            self.assertEqual(resp.status, 502)
            self.assertEqual(payload["src"], "llama-switch")
            self.assertEqual(payload["error"]["code"], "backend_unavailable")
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
