#!/usr/bin/env bash
# Safe smoke test: a single tiny chat completion against whatever serves :8731.
# No big-model loading is done directly by this script — llama-swap/halogen
# handle loading through the normal mode machinery.
#   scripts/smoke.sh                    # auto-detects a running model
#   scripts/smoke.sh swift-1.5-27b-q8   # flex mode: loads via llama-swap on demand
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh
require_valhalla
url="${URL:-http://$VALHALLA_ADDR:$VALHALLA_API_PORT}"

# What's serving?
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url/v1/models" || echo 000)
if [ "$code" != "200" ]; then
  echo "nothing healthy on :$VALHALLA_API_PORT (HTTP $code) — check: scripts/mode.sh status" >&2
  exit 1
fi

model="${1:-$(curl -s "$url/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')}"
echo "smoke: $url  model=$model"

curl -s --max-time 120 "$url/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$model\",\"max_tokens\":40,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: VALHALLA SMOKE OK\"}]}" \
  | python3 -c 'import json,sys
r = json.load(sys.stdin)
m = r["choices"][0]["message"]
print("content :", (m.get("content") or m.get("reasoning_content") or "")[:200])
print("usage   :", r.get("usage", {}))'
echo "smoke passed"
