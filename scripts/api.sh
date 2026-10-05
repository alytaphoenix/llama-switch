#!/usr/bin/env bash
# Machine-readable llama-swap API for programmatic consumers (switchyard).
#
# Unlike scripts/switch.sh (human CLI: pretty tables, prose), api.sh emits
# RAW JSON on stdout, stays silent on success, and exits nonzero on failure —
# the contract automation needs:
#   0 OK   2 unreachable   3 usage   4 HTTP error
#
#   scripts/api.sh health            -> exit 0 iff :8731 answers 200
#   scripts/api.sh status            -> GET /running (JSON)
#   scripts/api.sh models            -> GET /v1/models (JSON, per-model status)
#   scripts/api.sh metrics <model>   -> GET /upstream/<model>/metrics (raw text)
#   scripts/api.sh load <model>      -> load ahead, no inference (long timeout)
#   scripts/api.sh unload [model]    -> unload one model, or all if omitted
#   scripts/api.sh switch <model>    -> unload all, then load target
#
# Every target is env-overridable before sourcing env.sh:
#   LS_ADDR=<ip> LS_API_PORT=8731 scripts/api.sh status
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh
base="http://$LS_ADDR:$LS_API_PORT"

die() { echo "api.sh: $1" >&2; exit "${2:-4}"; }

# GET/POST helper: bodies to stdout, HTTP status checked, never retries.
# Branch on curl's own exit status — on transport failure curl still prints
# "000" via -w, so appending || echo 000 would corrupt the code, not flag it.
req() {
  local method="$1" path="$2" timeout="${3:-10}" tmp code body rc=0
  tmp=$(mktemp)
  code=$(curl -s -o "$tmp" -w '%{http_code}' -X "$method" \
         --max-time "$timeout" "$base$path") || rc=$?
  body=$(cat "$tmp" 2>/dev/null); rm -f "$tmp"
  if [ "$rc" -ne 0 ]; then die "unreachable (curl exit $rc): $base" 2; fi
  if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
    die "HTTP $code from $path" 4
  fi
  printf '%s' "$body"
}

case "${1:-}" in
  health)
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$base/health") || code=000
    [ "$code" = "200" ] || { echo "api.sh: health -> HTTP $code" >&2; exit 2; }
    ;;
  status)   req GET /running ;;
  models)   req GET /v1/models ;;
  metrics)  model="${2:?usage: api.sh metrics <model>}"; req GET "/upstream/$model/metrics" 30 ;;
  load)
    model="${2:?usage: api.sh load <model>}"
    req GET "/upstream/$model/health" 900 > /dev/null
    ;;
  unload)
    if [ -n "${2:-}" ]; then req POST "/api/models/unload/$2" 30 > /dev/null
    else req POST "/api/models/unload" 30 > /dev/null; fi
    ;;
  switch)
    model="${2:?usage: api.sh switch <model>}"
    req POST "/api/models/unload" 30 > /dev/null
    req GET "/upstream/$model/health" 900 > /dev/null
    req GET /running
    ;;
  *)
    echo "usage: $0 health|status|models|metrics <model>|load <model>|unload [model]|switch <model>" >&2
    exit 3
    ;;
esac
