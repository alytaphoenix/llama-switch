#!/usr/bin/env bash
# Run the API benchmark suite against whatever is serving :8731 (either mode).
#   MODEL=my-model scripts/bench.sh
#   URL=http://localhost:8731 MODEL=my-model scripts/bench.sh
#   CTXS=4096,16384 CTX_MAX... see vars below
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh

url="${URL:-http://$LS_ADDR:$LS_API_PORT}"
model="${MODEL:?set MODEL=<served model name>}"
ctxs="${CTXS:-4096,16384,32768,65536}"
needle_ctxs="${NEEDLE_CTXS:-16384,32768}"
gen="${GEN:-256}"
mkdir -p "$BENCH_DIR"
out="$BENCH_DIR/$(date +%F_%H%M%S)__api__${model}.json"

echo "probing $url model=$model"
{
  for c in ${ctxs//,/ }; do
    echo "# ctx=$c"
    python3 benchmarks/api_bench.py --url "$url" --model "$model" --ctx "$c" --gen "$gen" --repeat 3
  done
  echo "# needle"
  python3 benchmarks/needle_probe.py --url "$url" --model "$model" --ctxs "$needle_ctxs"
  echo "# tool-calling"
  python3 benchmarks/agentic_probe.py --url "$url" --model "$model" --repeat 8
} | tee "$out"

python3 benchmarks/matrix.py
echo "results → $out"
