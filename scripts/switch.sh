#!/usr/bin/env bash
# Programmatic model-switch API for the serving box (llama-swap flex mode).
#
#   scripts/switch.sh status            → currently loaded models
#   scripts/switch.sh list              → all configured models + state
#   scripts/switch.sh load <model>      → load ahead (no inference)
#   scripts/switch.sh unload [model]    → unload one model, or all if omitted
#   scripts/switch.sh switch <model>    → unload everything, then load target
#
# In flex mode switching is also implicit: send any request with
# "model": "<serve_name-or-alias>" and llama-swap swaps processes for you.
# (Exclusive mode serves a fixed model; use scripts/mode.sh to change modes.)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh
base="http://$LS_ADDR:$LS_API_PORT"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$base/v1/models" || echo 000)
if [ "$code" != "200" ]; then
  echo "nothing healthy on :$LS_API_PORT (HTTP $code) — check: scripts/mode.sh status" >&2
  exit 1
fi

case "${1:-}" in
  status)  curl -s "$base/running" | python3 -m json.tool ;;
  list)    curl -s "$base/v1/models" | python3 -c '
import json, sys
for m in json.load(sys.stdin)["data"]:
    mid = m["id"]
    meta = m.get("meta", {}).get("llamaswap", {})
    aliases = ",".join(meta.get("aliases", []))
    status = m.get("status", {}).get("value", "")
    print("%-32s %-28s %s" % (mid, aliases, status))' ;;
  load)
    model="${2:?usage: switch.sh load <model>}"
    curl -s --max-time 600 -o /dev/null -w 'load %s -> HTTP %{http_code}\n' "$base/upstream/$model/health"
    curl -s "$base/running" | python3 -c 'import json,sys; [print("running:", r["model"]) for r in json.load(sys.stdin)["running"]]'
    ;;
  unload)
    if [ -n "${2:-}" ]; then
      curl -s -X POST "$base/api/models/unload/$2" && echo "unloaded $2"
    else
      curl -s -X POST "$base/api/models/unload" && echo "unloaded all"
    fi
    ;;
  switch)
    model="${2:?usage: switch.sh switch <model>}"
    curl -s -X POST "$base/api/models/unload" >/dev/null
    echo "all unloaded; loading $model ..."
    curl -s --max-time 900 -o /dev/null -w 'switch -> HTTP %{http_code}\n' "$base/upstream/$model/health"
    curl -s "$base/running" | python3 -c 'import json,sys; [print("running:", r["model"]) for r in json.load(sys.stdin)["running"]]'
    ;;
  *)
    echo "usage: $0 status|list|load <model>|unload [model]|switch <model>" >&2
    exit 1
    ;;
esac
