# Benchmark matrix — valhalla

Decision table for serving configs on Strix Halo (128 GB, gfx1151).
Raw data: `benchmarks/results/*.json`. Regenerate: `python3 benchmarks/matrix.py`.

## Throughput (OpenAI API probes)

| file | model | ctx | gen | TTFT s | decode t/s |
|---|---|---|---|---|---|
| 2026-10-01_102503__api__swift-1.5-27b-q8.json | swift-1.5-27b-q8 | 4096 | 256 | 12.948 | 7.83 |
| 2026-10-01_102503__api__swift-1.5-27b-q8.json | swift-1.5-27b-q8 | 16384 | 256 | 27.088 | 7.65 |
| 2026-10-01_102503__api__swift-1.5-27b-q8.json | swift-1.5-27b-q8 | 32768 | 256 | 0.223 | 7.45 |
| 2026-10-01_102627__api__flash-next-gsq.json | flash-next-gsq | 4096 | 256 | 0.126 | 22.3 |
| 2026-10-01_102627__api__flash-next-gsq.json | flash-next-gsq | 16384 | 256 | 22.094 | 20.52 |
| 2026-10-01_102627__api__flash-next-gsq.json | flash-next-gsq | 32768 | 256 | 0.163 | 18.56 |
| 2026-10-01_104314__api__flash-next-gsq.json | flash-next-gsq | 4096 | 256 | 0.155 | 32.11 |
| 2026-10-01_104314__api__flash-next-gsq.json | flash-next-gsq | 16384 | 256 | 0.18 | 30.82 |
| 2026-10-01_104314__api__flash-next-gsq.json | flash-next-gsq | 32768 | 256 | 0.219 | 30.27 |
| 2026-10-01_133152__api__swift-flash-next-iq3m.json | swift-flash-next-iq3m | 4096 | 256 | 15.287 | 16.19 |
| 2026-10-01_133152__api__swift-flash-next-iq3m.json | swift-flash-next-iq3m | 16384 | 256 | 0.289 | 16.25 |
| 2026-10-01_133152__api__swift-flash-next-iq3m.json | swift-flash-next-iq3m | 32768 | 256 | 0.327 | 15.71 |
| 2026-10-01_162015__api__swift-flash-next.json | swift-flash-next | 4096 | 256 | 0.16 | 22.97 |
| 2026-10-01_162015__api__swift-flash-next.json | swift-flash-next | 16384 | 256 | 0.2 | 19.97 |
| 2026-10-01_162015__api__swift-flash-next.json | swift-flash-next | 32768 | 256 | 0.323 | 14.81 |
| 2026-10-01_215533__api__Qwen3.8 Flash Next.json | Qwen3.8 Flash Next | 4096 | 256 | 2.172 | 30.44 |
| 2026-10-01_215533__api__Qwen3.8 Flash Next.json | Qwen3.8 Flash Next | 16384 | 256 | 0.015 | 33.18 |
| 2026-10-01_215533__api__Qwen3.8 Flash Next.json | Qwen3.8 Flash Next | 32768 | 256 | 0.016 | 29.04 |
| 2026-10-01_215533__api__Qwen3.8 Flash Next.json | Qwen3.8 Flash Next | 65536 | 256 | 0.026 | 34.92 |
| 2026-10-01_215533__api__Qwen3.8 Flash Next.json | Qwen3.8 Flash Next | 131072 | 256 | 0.043 | 31.33 |

## Long-context retrieval (needle)

| file | model | retrieval hits by ctx |
|---|---|---|
| 2026-10-01_102503__api__swift-1.5-27b-q8.json | swift-1.5-27b-q8 | {'16384': '3/3', '32768': '3/3'} |
| 2026-10-01_102627__api__flash-next-gsq.json | flash-next-gsq | {'16384': '0/3', '32768': '1/3'} |
| 2026-10-01_104314__api__flash-next-gsq.json | flash-next-gsq | {'16384': '3/3', '32768': '3/3'} |
| 2026-10-01_133152__api__swift-flash-next-iq3m.json | swift-flash-next-iq3m | {'16384': '3/3', '32768': '3/3'} |
| 2026-10-01_162015__api__swift-flash-next.json | swift-flash-next | {'16384': '1/3', '32768': '2/3'} |
| 2026-10-01_215533__api__Qwen3.8 Flash Next.json | Qwen3.8 Flash Next | {'16384': '3/3', '32768': '3/3', '65536': '3/3'} |

## Tool calling (agentic smoke)

| file | model | correct tool calls |
|---|---|---|
| 2026-10-01_102503__api__swift-1.5-27b-q8.json | swift-1.5-27b-q8 | 8/8 |
| 2026-10-01_102627__api__flash-next-gsq.json | flash-next-gsq | 0/8 |
| 2026-10-01_104314__api__flash-next-gsq.json | flash-next-gsq | 8/8 |
| 2026-10-01_133152__api__swift-flash-next-iq3m.json | swift-flash-next-iq3m | 8/8 |
| 2026-10-01_162015__api__swift-flash-next.json | swift-flash-next | 0/8 |
| 2026-10-01_215533__api__Qwen3.8 Flash Next.json | Qwen3.8 Flash Next | 8/8 |

## Working decisions

- (fill after benchmark runs)
