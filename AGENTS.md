# AGENTS.md — llama-switch

Orchestration + benchmark layer for local LLM inference on a unified-memory
box (built on a 128 GiB AMD Strix Halo, gfx1151), driven over SSH from a
client machine.

## Hard rules

- **Big models are machine-exclusive.** Never load a big model (or run a
  server holding >8 GB of weights) while another engine holds memory — on
  unified memory this freezes the box (ping alive, all TCP dead → power
  cycle). `scripts/mode.sh` enforces it: mode switches stop other stacks and
  kill stray ad-hoc servers first; `remote-lib.sh` refuses to start flex
  while exclusive engines run.
- **Configs are edited here and deployed** (`scripts/deploy.sh`); nothing is
  hand-edited on the box.
- **Benchmark results land in `benchmarks/results/` as JSONL** and roll up
  via `python3 benchmarks/matrix.py`. Never edit raw results by hand.
- Accuracy-first defaults: finer quants, MTP speculative decode
  (byte-identical greedy), retrieval-quality knobs — unless benchmarks
  disagree.

## Facts that live in the code

- **The front proxy owns the public port.** `scripts/remote-proxy.py` binds
  `LS_API_PORT` (8731) and forwards to llama-swap on `LS_BACKEND_PORT`
  (8732, loopback only). llama-swap is an internal detail — never advertise it
  or bind it publicly.
- **`LS_DEFAULT_MODEL` is llama-switch's own feature.** llama-swap 404s a
  request with no `model` field, so the proxy injects a configured default.
  Injection is narrow on purpose: JSON POSTs only, never `multipart/form-data`
  (ASR/image uploads always send `model` and rewriting the boundary corrupts
  them), never `GET`, never `/upstream/<model>`. An explicit `model` always
  wins. Tests: `python3 tests/test_remote_proxy.py`.
- **Never buffer a streamed response.** The proxy reads the backend with
  `read1`, not `read(n)`; `read(n)` blocks until it has `n` bytes and would
  turn a streaming completion's TTFT into total latency. Likewise, if a request
  body was buffered to inspect it, forward the buffered copy — a drained
  reader plus the original `Content-Length` hangs the backend forever.
- One port for everything (`LS_API_PORT`, default 8731). Clients never
  reconfigure.
- Two exclusive modes share the port: **flex** (llama-swap, on-demand GGUF)
  and **exclusive** (a single engine that wants the whole machine, e.g. the
  halogen container engine — engines are swappable, the mode is not).
- llama-swap multi-line `cmd` REQUIRES trailing backslashes.
- Upstream engines check the forwarded model string: set `--served-model-name`
  or llama-swap `useModelName`.
- The APU runtime caps `hipMalloc` at the reported device pool (RAM/2+VRAM);
  `hipMallocManaged` escapes it (checksums verified) and is performance-
  neutral for read-only weights on the APU.
- Automation (Switchyard loadbalancer, `lan-switch.py`) consumes `scripts/api.sh` — raw JSON + exit codes, never `switch.sh`'s human formatting.
- Remote jobs: `> log 2>&1 < /dev/null &` + pidfiles (`scripts/jobs.sh`).
- `apt-get update` may fail on broken third-party repos; scripts tolerate it.
- Vulkan device heap on iGPUs = BIOS carve-out only; big trunks need HIP.
