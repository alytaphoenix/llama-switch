# llama-switch

One OpenAI-compatible port, many engines, on a box that cannot run two big
models at once.

**llama-switch** is an ops-and-benchmark layer for local LLM inference on
unified-memory machines (developed against a 128 GiB AMD Strix Halo — Ryzen
AI Max+ 395, Radeon 8060S / gfx1151, LPDDR5X shared by CPU and iGPU). It puts
**its own front door on the API port** and wraps
[llama-swap](https://github.com/mostlygeek/llama-swap) behind it, adding:

- **a front proxy** — `scripts/remote-proxy.py` binds the public port and
  forwards to llama-swap on an internal loopback port, making llama-swap an
  implementation detail rather than the thing clients talk to;
- **a default model** — requests that carry no `model` field are served by a
  configured default instead of 404ing, which is what lets one port hold a
  primary model plus a set of alternates;
- **mode machinery** — exclusive server stacks (an on-demand GGUF flex stack,
  a single heavyweight container engine) behind one never-changing port,
  switched with one command;
- **programmatic switching** — load-ahead, unload, and swap calls over the
  API, plus implicit swaps via any request's `"model"` field;
- **engine installers** — reproducible user-level builds and prebuilt fetches
  for the engines that matter on this silicon;
- **a benchmark harness** — throughput ladders, long-context needle
  retrieval, tool-calling smoke probes, concurrency and cache-fill probes,
  all writing JSON results that roll up into a human-readable decision matrix.

The philosophy: **accuracy first, then speed** — prefer finer quants, MTP
speculative decoding (byte-identical to greedy), and retrieval-quality knobs
unless a benchmark proves otherwise.

## Why

Unified-memory boxes change the rules:

- There is no separate VRAM to oversubscribe — every big model competes for
  the same pool, and **co-running two big models freezes the machine**
  (learned the hard way; see [Gotchas](#gotchas)).
- Quantization is not an optimization but a **correctness precondition**:
  large hybrid-MoE models do not fit at BF16/FP8 at all, so quant *quality*
  is the accuracy decision.
- Purpose-built engines (open or closed) can be dramatically faster than
  general ones on the same weights — the stack treats engines as swappable.

So the layer enforces exclusive memory discipline automatically, keeps
clients on a stable endpoint, and makes every engine/model/quant choice
measurable.

## Architecture

```
   clients (agents, OpenCode, Codex CLI, OpenAI SDKs)
        │
        ▼
  http://<box>:8731              ← one port, never changes
        │
        ▼
  ┌────────────────────────────────────────────────────────────┐
  │  llama-switch front proxy (our code)                        │
  │  binds :8731, injects the default model when a request     │
  │  has none, streams everything else through untouched       │
  └────────────────────────────────────────────────────────────┘
        │  forwards to
        ▼
  ┌────────────────────────────────────────────────────────────┐
  │  llama-swap (flex mode), on 127.0.0.1:8732                 │
  │  routes by requested "model" name, starts/stops engine     │
  │  processes on demand, TTL auto-unload, exclusive groups    │
  └────────────────────────────────────────────────────────────┘
        │  spawns on demand
        ▼
  engine processes   gufo (local build) · llama-server · ik-llama-server · ...
```

Two exclusive **modes** share the port — only one is ever up:

```
            scripts/mode.sh flex                scripts/mode.sh exclusive
        ┌──────────────────────────┐      ┌──────────────────────────────┐
        │  llama-swap on :8731     │      │  one container engine on     │
        │  N GGUF models, on       │      │  :8731 (e.g. halogen), wants │
        │  demand, TTL unload      │      │  nearly all of the RAM       │
        └──────────────────────────┘      └──────────────────────────────┘
        ▲                                   ▲
        └─────────  mode.sh stops the other, kills stray
                    ad-hoc servers, then starts the target  ──────────┘
```

- **flex** (default) — llama-swap with on-demand GGUF models;
- **exclusive** — an engine that wants the whole machine (a container
  engine such as halogen), run alone.

`scripts/mode.sh flex|exclusive|status|stop-all` switches modes **and**
cleans up stray ad-hoc servers first (a leftover test server OOMs the next
load). `scripts/switch.sh status|list|load|unload|switch` drives models
inside flex mode; or just send any request with the model name you want.

## The front proxy and the default model

llama-swap answers a request whose body has no usable `model` field with
`404 no model id could be identified`. That is a papercut for a
single-primary deployment: you want a default *and* the alternates on the same
port.

Rather than wait for a feature in whichever llama-swap build is installed,
llama-switch owns the public port and injects the default itself:

```sh
LS_DEFAULT_MODEL=gufo-flash-next scripts/mode.sh flex
```

```sh
# no "model" field → served by gufo-flash-next
curl -s localhost:8731/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hi"}]}'

# explicit "model" always wins
curl -s localhost:8731/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"gufo-27b-q4","messages":[]}'
```

With `LS_DEFAULT_MODEL` unset the proxy is a pure pass-through and behaviour is
unchanged.

The injection is deliberately narrow, because a proxy that rewrites requests
can corrupt them:

| Request | Injected? |
|---|---|
| JSON POST with no / empty / null `model` | yes |
| JSON POST with an explicit `model` | no — explicit always wins |
| `multipart/form-data` (ASR uploads, image edits) | no — the body is streamed byte-for-byte, and these endpoints always send `model` explicitly |
| `GET` (e.g. `/v1/models`) | no |
| `/upstream/<model>/...` | no — the path already names the model |

Responses stream in both directions, so a streaming chat completion keeps its
time-to-first-token (`scripts/remote-proxy.py` uses `read1`, not `read(n)`,
which would block until a full chunk arrived). Bodies that are not injected are
forwarded as a stream rather than buffered, so a large upload is never held in
proxy memory. When the proxy substituted a model it says so:

```
X-Llama-Switch-Default-Model: gufo-flash-next
```

If llama-swap itself is down the proxy returns `502` with an OpenAI-shaped
error envelope rather than a bare connection reset.

Tests: `python3 tests/test_remote_proxy.py` (unit coverage for the injection
rules plus an end-to-end run against a stub backend covering default
injection, explicit-model precedence, multipart integrity, SSE incremental
relay and the 502 path).

## Layout

```
scripts/
  env.sh                  shared config (host alias, LAN address, port, paths)
  survey.sh               read-only hardware/runtime survey of the box
  deploy.sh               rsync repo + configs to the box (configs rendered)
  remote-proxy.py         the front proxy: owns :8731, injects the default model
  mode.sh                 flex|exclusive|status|stop-all (+ stray cleanup)
  switch.sh               status|list|load|unload|switch (programmatic switching)
  api.sh                  machine-readable twin of switch.sh (raw JSON + exit codes)
  jobs.sh                 long-running remote jobs with pidfiles + logs
  smoke.sh                single tiny chat completion against whatever serves
  tunnel.sh               SSH tunnel for localhost clients
  telemetry.sh            power/thermal sampling around a workload
  remote-telemetry.py     the sampler (runs ON the box)
  remote-lib.sh           remote-side library (runs ON the box)
  install-llama-cpp.sh    mainline llama.cpp, Vulkan backend
  install-llama-cpp-hip.sh mainline llama.cpp, ROCm/HIP (HIP_TARGETS=…)
  install-ik-llama.sh     ik_llama.cpp CPU (Zen5 AVX-512 IQK path)
  install-llama-swap.sh   llama-swap release binary
  install-gufo-local.sh   gufo from source (GUFO_BRANCH=… for forks)
  download-models.sh      hf CLI bootstrap + revision-pinned weight downloads
  bench.sh                the full probe suite against whatever serves the port
tests/
  test_remote_proxy.py    unit + end-to-end tests for the front proxy
benchmarks/
  api_bench.py            TTFT + decode t/s at a given prompt size (streaming)
  needle_probe.py         needle-in-a-haystack at depths (long-context accuracy)
  agentic_probe.py        OpenAI tools API smoke (correct tool call + args)
  concurrency_probe.py    synchronized parallel waves + aggregate rates
  cache_fill_probe.py     multi-turn conversation fill (prefix-cache pressure)
  matrix.py               aggregates results/*.json -> MATRIX.md
  DECISIONS.md            worked example: engine/quant decisions with numbers
configs/
  llama-swap.yaml         flex-mode config template (@HOME@ rendered at deploy)
  exclusive/halogen.env   exclusive-mode env template (halogen engine)
data/
  model-registry.json     model/quant inventory (pinned HF repos + revisions)
```

## Quickstart

Prereqs: a Linux box with a ROCm-capable GPU, your SSH alias to it in
`~/.ssh/config`, podman or docker, and this repo on your client machine.

```sh
# 0) configure scripts/env.sh (host alias + LAN address + port) and pick the
#    model that answers requests which name no model
export LS_DEFAULT_MODEL=gufo-flash-next

# 1) survey the box (read-only)
scripts/survey.sh

# 2) engines: llama-swap binary + at least one inference engine
scripts/jobs.sh run llama-swap scripts/install-llama-swap.sh
scripts/jobs.sh run llama-cpp scripts/install-llama-cpp.sh

# 3) weights (revision-pinned)
scripts/jobs.sh run dl scripts/download-models.sh \
  <org>/<repo> "<glob>" <dest-under-llama-switch/models> [revision]

# 4) edit configs/llama-swap.yaml for your models, then deploy
scripts/deploy.sh

# 5) bring up flex mode and use it
scripts/mode.sh flex
scripts/switch.sh list
scripts/switch.sh switch <model-id>     # or just send requests
scripts/api.sh default                  # what a model-less request will get

# 6) benchmark whatever is serving
MODEL=<served-name> scripts/bench.sh
```

Every client only ever sees `http://<box>:8731/v1`. On the same machine as
your clients, `scripts/tunnel.sh` forwards the port over SSH.

## Configuration

Everything is overridable by exporting a variable before running a script
(see `scripts/env.sh`):

| Variable | Default | Meaning |
|---|---|---|
| `LS_HOST` | `llm_server` | SSH alias for the box |
| `LS_ADDR` | `$LS_HOST` | HTTP address resolvable from the client (IP/mDNS) |
| `LS_API_PORT` | `8731` | the one and only API port (the proxy's) |
| `LS_BACKEND_PORT` | `8732` | llama-swap's internal loopback port |
| `LS_DEFAULT_MODEL` | *(empty)* | model served when a request carries none; empty = pass-through |
| `LS_PROXY_HOST` | `0.0.0.0` | bind address for the public port |
| `LS_REMOTE_ROOT` | `llama-switch` | remote `~/` subdirectory for repo/etc/run/logs/models |
| `EXCLUSIVE_COMPOSE_DIR` | `$LS_REMOTE_ROOT/stack` | podman-compose dir of the exclusive engine |
| `EXCLUSIVE_SYSTEMD_UNIT` | `podman-compose@exclusive.service` | optional systemd unit wrapping it |
| `EXCLUSIVE_CONTAINER_MATCH` | `exclusive` | `podman ps` name regex used to detect it |
| `BENCH_DIR` | `benchmarks/results` | where local results land |

## Engines, measured on a 128 GiB Strix Halo (gfx1151)

| Engine | Memory story | Notes |
|---|---|---|
| llama.cpp (mainline, HIP) | allocates ~84–89 GiB device | no qwen4exp MTP; the flexible backbone |
| llama.cpp (mainline, Vulkan) | device heap = BIOS carve-out only (~20 GiB!) | fine for small models; **cannot** hold big trunks |
| unslothai/llama.cpp fork | same as mainline | qwen4exp MTP graph + cross-model tensor borrowing; needed for embedded-MTP serving |
| ik_llama.cpp (CPU, Zen5) | ~6 GiB resident + page cache | `--defer-ple` keeps per-layer token embeddings **non-resident** (disk-paged); `--jinja` mandatory for tools; decode drops with context |
| gufo (local build) | ~82 GiB managed weights + ~31 GiB device state | fastest Flash-Next path: flat 29–35 t/s d0→d131k, full 262144 ctx, MTP |
| container exclusive engines | machine-exclusive by design | give them their own mode, never co-run |

A worked example with the full decision log lives in
[`benchmarks/DECISIONS.md`](benchmarks/DECISIONS.md) (single-stream greedy:
a large MoE flagship at multiple quants, a fine-tune in three serving
layouts, and a dense 27B with MTP/DFlash2).

## Switchyard integration (programmatic LAN control)

`scripts/api.sh` is the machine-readable twin of `scripts/switch.sh`: raw
JSON on stdout, no prose, and exit codes automation can branch on
(0 OK · 2 unreachable · 3 usage · 4 HTTP error). It is the supported entry
point for programmatic LAN control — the Switchyard routing proxy's
loadbalancer and its `lan-switch.py` utility drive the box through these
calls (status/load/unload/switch over the llama-swap endpoints). All
targets are env-overridable (`LS_ADDR`, `LS_API_PORT`), so the
same calls work from any host that can reach the box.

## Gotchas

Everything below cost real time — encoded here so it costs none of yours:

1. **Never co-run big models** on unified memory: ping stays alive, every TCP
   port dies, power-cycle required. Enforce exclusivity in code, not habits.
2. **llama-swap multi-line `cmd` needs trailing backslashes** — without them
   each line runs as a separate command and the upstream starts in an empty
   router mode that looks like "exited prematurely".
3. **The upstream engine must accept the model string your client sends** —
   set `--served-model-name` (gufo) or llama-swap's `useModelName` rewrite;
   aliases route correctly but the forwarded name is what the engine checks.
4. **The APU runtime caps `hipMalloc` at the reported device pool**
   (RAM/2 + VRAM ≈ 62.5 GiB on 128 GiB) — `amdgpu.gttsize` raises the kernel
   pool, not the runtime cap. `hipMallocManaged` escapes the cap (verified
   with checksums) and is performance-neutral on the APU for read-only
   weights.
5. **`apt-get update` fails on broken third-party repos** (e.g. a stale ROCm
   apt entry without a Release file) — scripts run `update || true` and
   install from existing lists.
6. **Background jobs over ssh need `> log 2>&1 < /dev/null &`** — otherwise
   the ssh client hangs on exit, and a killed client breaks the job's stdout
   pipe (SIGPIPE deadlocks any thread barrier).
7. **Vulkan's device heap on iGPUs is the BIOS carve-out**, not unified
   memory — 20 GiB-ish on a 128 GiB box. Big models need HIP.
8. **A proxy that buffers a streamed response destroys TTFT.** The front proxy
   reads the backend with `read1`, not `read(n)`: `read(n)` blocks until it
   has `n` bytes, so a client would see nothing until the whole generation
   finished. `tests/test_remote_proxy.py` guards this.
9. **If you buffer a request body to inspect it, forward the buffered copy.**
   Pairing an already-drained reader with the original `Content-Length` makes
   the backend wait forever for bytes that were consumed — a hang that looks
   exactly like a stuck model. Also covered by the tests.
10. **Stop the proxy before llama-swap on a shared port.** The proxy owns the
    public port; `mode_flex` releases it in order rather than racing the bind.

## Roadmap

- [ ] Restart-safe continuation cache (`--cache-disk`) wired into the flex
  entries for long agent sessions
- [ ] Concurrency ladder on the repetitive corpus (best-case speculative
  batching) and why barrier-synchronized starts keep serial-fallback plans
- [ ] Logit-parity quality gates vs upstream per-model quality suites
- [ ] Upstream the managed-fallback patch (with the allocation diagnostics)
- [ ] Utility-model slots (embeddings/reranker) running concurrently with the
  loaded flagship
- [ ] Consider a small resident pool of cheap models (ASR/TTS-style) so the
  proxy can serve them without a swap, now that one group no longer has to
      mean "exactly one model"

## License

MIT — see [LICENSE](LICENSE). Model weights are never bundled; they keep
their publishers' terms.
