#!/usr/bin/env bash
# Mode switcher for valhalla. Only one stack serves :8731 at a time.
#   scripts/mode.sh flex|halogen|status|stop-all
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh
require_valhalla

remote_fn() {
  local fn="$1"
  v "bash -c 'source $VALHALLA_REMOTE_REPO/scripts/remote-lib.sh && $fn'"
}

case "${1:-}" in
  flex)     remote_fn mode_flex ;;
  halogen)  remote_fn mode_halogen ;;
  stop-all) remote_fn mode_stop_all ;;
  status)   remote_fn mode_status ;;
  *)
    echo "usage: $0 flex|halogen|status|stop-all" >&2
    exit 1
    ;;
esac
