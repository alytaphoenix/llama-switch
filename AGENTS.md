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
