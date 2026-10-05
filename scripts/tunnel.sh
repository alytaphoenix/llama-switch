#!/usr/bin/env bash
# Tunnel the serving box's API port to this Mac so local clients (OpenCode, Codex CLI,
# anything on localhost) can reach the serving stack without knowing SSH.
#   scripts/tunnel.sh        → localhost:8731 → box:8731
#   scripts/tunnel.sh 9000   → localhost:9000 → box:8731
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh
require_remote
local_port="${1:-$LS_API_PORT}"

echo "tunneling localhost:$local_port → $LS_HOST:$LS_API_PORT (ctrl-c to stop)"
exec ssh -N -L "$local_port:127.0.0.1:$LS_API_PORT" $LS_SSH_OPTS "$LS_HOST"
