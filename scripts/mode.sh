#!/usr/bin/env bash
# Mode switcher. Only one stack serves the API port at a time.
#   scripts/mode.sh flex       → llama-swap (on-demand GGUF models)
#   scripts/mode.sh exclusive  → the exclusive heavyweight stack (containers)
#   scripts/mode.sh status     → what's running, health, memory
#   scripts/mode.sh stop-all   → stop everything
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh
require_remote

remote_fn() {
  local fn="$1"
  # The remote shell is fresh, so the settings that decide where the stack
  # listens and what the default model is have to be carried across explicitly.
  # Quoted with %q so a path or value with spaces survives.
  local fwd=()
  local name
  for name in LS_REMOTE_ROOT LS_REMOTE_ETC LS_API_PORT LS_BACKEND_PORT \
              LS_DEFAULT_MODEL LS_PROXY_HOST EXCLUSIVE_COMPOSE_DIR \
              EXCLUSIVE_SYSTEMD_UNIT EXCLUSIVE_CONTAINER_MATCH; do
    fwd+=("$(printf '%s=%q' "$name" "${!name}")")
  done
  v "env $(printf '%s ' "${fwd[@]}") bash -c 'source $LS_REMOTE_REPO/scripts/remote-lib.sh && $fn'"
}

case "${1:-}" in
  flex)      remote_fn mode_flex ;;
  exclusive) remote_fn mode_exclusive ;;
  stop-all)  remote_fn mode_stop_all ;;
  status)    remote_fn mode_status ;;
  *)
    echo "usage: $0 flex|exclusive|status|stop-all" >&2
    exit 1
    ;;
esac
