#!/usr/bin/env bash
# Shared configuration for llama-switch automation. Sourced by every script.
# Override anything by exporting the variable before running a script.
# shellcheck shell=bash
set -u

# ---------------------------------------------------------------- remote host
# The serving box is driven entirely over SSH from this machine.
# SSH alias for the box, as configured in ~/.ssh/config (this machine side).
: "${LS_HOST:=llm_server}"
# Direct HTTP address for API calls from THIS machine. An SSH alias does not
# resolve for curl, so point this at an IP or mDNS name that does.
: "${LS_ADDR:=$LS_HOST}"
: "${LS_SSH_OPTS:=-o BatchMode=yes -o ConnectTimeout=8}"

# ------------------------------------------------------- one port, two modes
# Flex mode  : llama-swap (on-demand GGUF models)   listens on this port
# Exclusive : a single heavyweight serving stack (container, e.g.
#              halogen-flash-server) binds the same port
# Only one stack runs at a time, so clients always use the same URL.
: "${LS_API_PORT:=8731}"

# ------------------------------------------------- remote layout (~ relative)
: "${LS_REMOTE_ROOT:=llama-switch}"
: "${LS_REMOTE_REPO:=$LS_REMOTE_ROOT/repo}"    # deployed copy of this project
: "${LS_REMOTE_MODELS:=$LS_REMOTE_ROOT/models}" # GGUF + other weights
: "${LS_REMOTE_BIN:=bin}"                       # llama-server, llama-swap, ...
: "${LS_REMOTE_ETC:=$LS_REMOTE_ROOT/etc}"       # deployed configs
: "${LS_REMOTE_RUN:=$LS_REMOTE_ROOT/run}"       # pidfiles
: "${LS_REMOTE_LOGS:=$LS_REMOTE_ROOT/logs}"     # server logs

# ------------------------------------------------- exclusive-mode stack
# The exclusive stack is a podman-compose deployment, optionally wrapped in a
# systemd user unit. Override to match your setup.
: "${EXCLUSIVE_COMPOSE_DIR:=$LS_REMOTE_ROOT/stack}"
: "${EXCLUSIVE_SYSTEMD_UNIT:=podman-compose@exclusive.service}"
# `podman ps` name pattern used to detect the stack (regex, -E).
: "${EXCLUSIVE_CONTAINER_MATCH:=exclusive}"

# ------------------------------------------------------------------ local out
: "${BENCH_DIR:=benchmarks/results}"

# ------------------------------------------------------------------ helpers
# v: run a command on the remote box, streaming output locally.
v() { ssh $LS_SSH_OPTS "$LS_HOST" "$@"; }

require_remote() {
  if ! v 'true' 2>/dev/null; then
    echo "ERROR: cannot ssh to '$LS_HOST'. Add a Host entry to ~/.ssh/config" >&2
    echo "(or export LS_HOST=... with a user@host)." >&2
    exit 1
  fi
}
