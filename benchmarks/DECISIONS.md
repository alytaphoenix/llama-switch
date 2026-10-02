# Working decisions — valhalla inference stack (2026-10-01)

Measured on Strix Halo 128 GB (gfx1151), single-stream greedy (temp 0),
agents at concurrency 1-2. Raw data in `results/`; table in `MATRIX.md`.

## The stack (full OSS, halogen-parity memory design)

- **Engines**: unslothai/llama.cpp fork (prebuilt `b11160-mix-a6922cc rocm-gfx1151`,
  at `~/src/unsloth-bin/`, HIP → full unified pool, MTP + tensor borrowing) for
  GPU paths; **ik_llama.cpp** (built at `~/bin/ik-server`, Zen5 AVX-512 CPU
  path, `--defer-ple`/`--defer-experts`, MTP via `-md`, recurrent-model context
  checkpoints) for the Swift CPU flagship. Mainline ggml-org builds kept at
  `~/bin` (no qwen4exp MTP).
- **MTP speculative decoding ON everywhere measured** — byte-identical greedy
  output; acceptance 0.73–0.91 on this hardware.
- **Engrams**: unsloth-fork `-ot "per_layer_token_embd=CPU"` is silently
  ignored for this tensor (TENSOR_READ_LAZY + no CPU-compatible buft) — the
  table stays on device there. ik_llama's `--defer-ple` genuinely keeps the
  PLE table non-resident (disk-paged) — the original design goal, achieved.
- **Serving**: llama-swap v261 on :8731 (one port, both modes).

## Numbers (decode t/s, greedy, median of 3)

| Model | ctx 4k | ctx 32k | retrieval 16k/32k | tools |
|---|---|---|---|---|
| swift-1.5-27b-q8, no MTP | 7.8 | 7.5 | 6/6 | 8/8 |
| swift-1.5-27b-q8, embedded MTP | **14.8** | ~14 (16k: 15.1) | (same model) | — |
| flash-next-gsq IQ3_S, no MTP | 22.3 | 18.6 | 0/3* | — |
| flash-next-gsq IQ3_S + MTP (GPU) | **32.1** | **30.3** | 6/6 | 8/8 |
| flash-next + MTP + engrams-on-CPU | 31.9 | 28.7 | — | — |
| swift-flash-next IQ3_M + MTP (GPU-hybrid) | 16.2 | 15.7 | 6/6 | 8/8 |
| swift-flash-next ik-CPU + MTP + deferred PLE | **22.5** | 14.8 | 6/6 | 8/8 (after --jinja) |
| **gufo 27B Q4_K_XL + DFlash2 (daily driver)** | **34.0** (smoke 36.1) | pending | 6/6 | 8/8 |
| gufo 27B Q8_K_XL + DFlash2 | 22.9 | pending | (same model) | — |
| **gufo Flash-Next UD-Q4_K_XL + MTP (FLAGSHIP, patched local build)** | **30.4** | **31.3** (64k: 34.9) | **6/6 @16k/32k/64k + 3/3 @131k** | 8/8 |

**gufo Flash-Next flagship (2026-10-01, the deep-dive result)**: the upstream
container's ROCm runtime caps `hipMalloc` at the reported device pool (62.5 GiB
= RAM/2+VRAM heuristic, independent of `amdgpu.gttsize=102400`), so its
all-weights-to-device loader fails mid-load. Built gufo LOCALLY on branch
`valhalla/managed-fallback` (~/src/gufo): weights allocate via
`hipMallocManaged` (same physical DRAM on the APU; streamed read-only weights
lose nothing), device pool stays reserved for session state/scratch so the
state-capacity admission check passes. Verified with our harness:
- decode **flat 29–35 t/s from 4k to 131k** (llama.cpp collapses to ~15 by 32k)
- full native context **262144 live** (sessions 1) and 131072 × 2 sessions
- 22 s cold load; cold prefill ~1,900 t/s (131k in ~68 s); TTFT 15–43 ms cached
- MTP acceptance ~0.67 mixed (draft_limit 7); needle clean at every depth
- memory: ~82 GiB managed weights (page-backed, evictable) + ~31 GiB device
- `amdgpu.gttsize=102400` added to GRUB (kernel pool 100 GiB) — retained for
  headroom even though the runtime cap ignores it
- rebuild: `scripts/install-gufo-local.sh` (cmake --preset release + /opt/rocm)

**gufo (2026-10-01 addition)**: MIT-licensed vertical Strix Halo engine
(gufo-org/gufo), verified on valhalla with the 27B — promoted to daily driver.
Load ~19 s; TTFT 6 ms cached; per-request usage payload reports decode t/s,
draft acceptance and cache stats. Mapped-GGUF host placement (PR #220).
**Flash-Next on gufo is BLOCKED by our 62.5 GB GTT**: its loader device-places
routed experts (~86 GB peak on gufo's own bench host) → hipMalloc fails at
blk.37. Fix candidates: raise GTT via kernel param `amdgpu.gttsize` (GRUB edit
+ reboot) or upstream guidance (their docs don't state the host GTT config).
llama.cpp's HIP runtime allocates past GTT (fine-grained system memory) which
is why llama.cpp can hold the 84 GB trunk.

*the 0/3 was probe truncation (max_tokens 64), not retrieval failure; fixed at
192 + temp 0 → 6/6.

- Prefill (cold, 32k): ~900 t/s (36 s TTFT) on Flash-Next MoE vs ~420 t/s dense 27B.
- Dense 27B Q8 decode is bandwidth-limited (~29 GB/token ÷ ~245 GB/s ≈ 8 t/s
  ceiling) — MTP is the only way past it at full quality (14.8 t/s measured).
- swift-flash-next IQ3_M runs a **CPU-hybrid** layout (`ffn_down_exps` on CPU to
  fit the fatter trunk): decode 15.7-16.3 t/s, cold prefill ~270 t/s — half the
  speed of the full-GPU IQ3_S recipe, but with the finer quant (3.7 bpw vs 3.3)
  and Swift-1.5 agentic tuning; MTP acceptance 0.91 (highest measured).
- Memory ceiling measured: ~90 GiB of HIP device allocations (IQ3_M's 88 GiB
  trunk + 32k ctx buffers does not fit fully on GPU; IQ3_S's 83.4 does).

## MTP operational notes

- `--spec-type draft-mtp --spec-draft-n-max 2`; Flash-Next also `-md <shared-Q8_0 head>`
  (always explicit; auto-discovery does not search MTP/ dirs).
- MTP wins at concurrency 1-2; net LOSS at ≥8 concurrent — if we batch hard,
  drop the flags (llama-swap entry edit + redeploy).
- Shared-Q8_0 head logs one benign borrow error at startup ("failed to measure
  the memory of the extra model") — expected, from unsloth's README.
- High temperature shrinks acceptance (greedy numbers are the honest ones).

## Serving per workload (the decision matrix)

- **Flagship (the answer)**: `gufo-flash-next` — Flash-Next UD-Q4_K_XL, full
  native 262144 context AND ~31 t/s flat decode; patched local gufo build.
- **Alias routing (fixed 2026-10-02)**: `qwen3.8-flash-next` → gufo flagship
  (was: llama.cpp 32k variant that errored on >32k prompts; the upstream
  must receive `--served-model-name` matching the client's model string).
- **llama.cpp alternative**: `flash-next-llamacpp` at 262144 ctx: 14.9 t/s
  decode, ~420 t/s prefill (ffn_down_exps on CPU to fit) — full context but
  half speed. At 32k ctx full-GPU it does 30+ t/s decode / ~900 t/s prefill.
  Trade-off: context or speed, not both, on llama.cpp.
- **ik CPU** (`swift-flash-next`): 22.5 t/s @ 4k decode, engrams+experts
  disk-paged; decode drops to ~14.8 by 32k.
- **Daily driver**: `gufo-27b-q4` (34 t/s) / `gufo-27b-q8` (22.9 t/s).
- **Gufo concurrency (serving bench, prose)**: aggregate 30.8 / 49.9 / 59.2 /
  69.1 tok/s at C1/C2/C4/C8 — scales where llama.cpp MTP is a net loss at ≥8.
  Their 157 tok/s @ 8 is the repetitive-corpus case; use their harness
  (tools/serving/gufo-serving-bench.py) + `--max-pending-per-client 32` +
  `--sessions 8` to reproduce. Note: barrier-synchronized starts ran
  serial-fallback (batch_width=1) in our first attempt — use their harness.

## ik_llama.cpp operational notes

- `--jinja` is MANDATORY for tool calling (500s without it);
  `--reasoning-format deepseek` separates thoughts from content.
- `--defer-ple` (PLE/engrams non-resident) + `--defer-experts` (fault-in) give
  the halogen-parity memory profile: ~6 GiB resident + page cache.
- MTP: `--spec-type mtp:n_max=2` + `-md <self-contained-Q8_0 head>` (the shared
  head borrows tensors — untested on ik; self-contained works).
- Recurrent-model **context checkpoints** (`--ctx-checkpoints`,
  `--ctx-ckpt-spill-dir DIR` to NVMe) — the OSS composable-context analog;
  untested here, next experiment for long agentic sessions.
- Their `-ot` regex overrides print confirmations (unlike the unsloth fork's
  silent behavior for the PLE tensor).
- ik decode slows with context (22.5 @ 4k → 14.8 @ 32k); GPU-hybrid is flatter.
  ik's CPU prefill ~230-260 t/s vs GPU ~900 t/s.

## Open items

- Swift-Flash-Next at full-GPU speed: download ukisai **IQ3_XS** trunk (~78 GB,
  fits like IQ3_S) → expect ~30 t/s with Swift quality; current IQ3_M entry is
  the quality-max hybrid at ~16 t/s. Pick per workload.
- Full-quality engrams: current GGUFs quantize the table to IQ4_NL (~4.25bpw);
  a Q8_0 table (~51 GB) needs a re-quant from the BF16 originals (335 GB source
  download) — deferred until the accuracy gap justifies it.
- Halogen 0.15.2 upgrade (v2 62 GiB checkpoint) — still recommended for halogen
  mode; flex stack no longer depends on it.
- ggml-org PR #28243 tracks MTP toward mainline — once merged, drop the fork.
