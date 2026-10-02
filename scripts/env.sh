#!/usr/bin/env bash
# Shared configuration for all valhalla automation. Sourced by every script.
# Override anything by exporting the variable before running a script.
# shellcheck shell=bash
set -u

# ---------------------------------------------------------------- remote host
# SSH alias for the Strix Halo box, as configured in ~/.ssh/config (Mac side).
# Existing alias: llm_server -> 192.168.0.142 (user alyta, hostname "valhalla").
: "${VALHALLA_HOST:=llm_server}"
# Direct HTTP address for API calls from THIS machine (SSH aliases don't resolve
# for curl; use the IP or an mDNS name that actually resolves).
: "${VALHALLA_ADDR:=192.168.0.142}"
: "${VALHALLA_SSH_OPTS:=-o BatchMode=yes -o ConnectTimeout=8}"

# ------------------------------------------------------- one port, two modes
# Flex mode  : llama-swap (on-demand GGUF models)   listens on this port
# Halogen    : halogen-flash-server container      binds this port
# Only one stack runs at a time, so clients always use the same URL.
: "${VALHALLA_API_PORT:=8731}"

# ------------------------------------------------- remote layout (~ relative)
: "${VALHALLA_REMOTE_REPO:=valhalla/repo}"     # deployed copy of this project
: "${VALHALLA_REMOTE_MODELS:=valhalla/models}" # GGUF + .hgn weights
: "${VALHALLA_REMOTE_BIN:=bin}"                # llama-server, llama-swap, ...
: "${VALHALLA_REMOTE_ETC:=valhalla/etc}"       # deployed configs
: "${VALHALLA_REMOTE_RUN:=valhalla/run}"       # pidfiles
: "${VALHALLA_REMOTE_LOGS:=valhalla/logs}"     # server logs

# ------------------------------------------------------------ halogen config
: "${HALOGEN_IMAGE:=ghcr.io/peonist-ai/halogen-flash-server:0.15.2}"
: "${HALOGEN_MODEL_REPO:=peonist-ai/halogen-qwen3.8-flash-next}"
: "${HALOGEN_MODEL_DIR:=valhalla/models/halogen}"
# 4096 indexer budget = better long-context retrieval, ~7% prefill cost at 32k.
: "${HALOGEN_INDEXER_BUDGET:=4096}"
: "${HALOGEN_VISION_TOWER:=1}"
: "${HALOGEN_COMPOSABLE_CONTEXT:=1}"

# ------------------------------------------------------------------ local out
: "${BENCH_DIR:=benchmarks/results}"

# Convenience: run a command on valhalla.
v() { ssh $VALHALLA_SSH_OPTS "$VALHALLA_HOST" "$@"; }

require_valhalla() {
  if ! v 'true' 2>/dev/null; then
    echo "ERROR: cannot ssh to '$VALHALLA_HOST'. Add a Host valhalla entry to" >&2
    echo "~/.ssh/config (or export VALHALLA_HOST=... with a user@host)." >&2
    exit 1
  fi
}
