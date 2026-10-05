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
  v "bash -c 'source $LS_REMOTE_REPO/scripts/remote-lib.sh && $fn'"
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
