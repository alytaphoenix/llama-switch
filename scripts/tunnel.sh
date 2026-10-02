#!/usr/bin/env bash
# Tunnel valhalla's API port to this Mac so local clients (OpenCode, Codex CLI,
# anything on localhost) can reach the serving stack without knowing SSH.
#   scripts/tunnel.sh        → localhost:8731 → valhalla:8731
#   scripts/tunnel.sh 9000   → localhost:9000 → valhalla:8731
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh
require_valhalla
local_port="${1:-$VALHALLA_API_PORT}"

echo "tunneling localhost:$local_port → $VALHALLA_HOST:$VALHALLA_API_PORT (ctrl-c to stop)"
exec ssh -N -L "$local_port:127.0.0.1:$VALHALLA_API_PORT" $VALHALLA_SSH_OPTS "$VALHALLA_HOST"
