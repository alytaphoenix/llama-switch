#!/usr/bin/env bash
# Remote-side library. Runs ON the serving box (sourced via ssh from mode.sh).
# Deployed copy: ~/llama-switch/repo/scripts/remote-lib.sh
# shellcheck shell=bash
set -u

ROOT="$HOME/llama-switch"
REPO="$ROOT/repo"
ETC="$ROOT/etc"
RUN="$ROOT/run"
LOGS="$ROOT/logs"
BIN="$HOME/bin"
PORT="${LS_API_PORT:-8731}"

# The exclusive stack (podman-compose, optionally a systemd user unit).
# Overridable via the environment when this file is sourced.
EXCLUSIVE_COMPOSE_DIR="${EXCLUSIVE_COMPOSE_DIR:-$ROOT/stack}"
EXCLUSIVE_SYSTEMD_UNIT="${EXCLUSIVE_SYSTEMD_UNIT:-podman-compose@exclusive.service}"
EXCLUSIVE_CONTAINER_MATCH="${EXCLUSIVE_CONTAINER_MATCH:-exclusive}"

mkdir -p "$RUN" "$LOGS" 2>/dev/null || true

pid_alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

health() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/models" 2>/dev/null || echo 000; }

stop_llama_swap() {
  if pid_alive "$RUN/llama-swap.pid"; then
    kill "$(cat "$RUN/llama-swap.pid")" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pid_alive "$RUN/llama-swap.pid" || break; sleep 0.5; done
    pid_alive "$RUN/llama-swap.pid" && kill -9 "$(cat "$RUN/llama-swap.pid")" 2>/dev/null
    rm -f "$RUN/llama-swap.pid"
    echo "llama-swap stopped"
  else
    echo "llama-swap not running"
  fi
}

exclusive_running() { podman ps --format '{{.Names}}' 2>/dev/null | grep -E -q "$EXCLUSIVE_CONTAINER_MATCH"; }

stop_exclusive() {
  if systemctl is-active --user "$EXCLUSIVE_SYSTEMD_UNIT" >/dev/null 2>&1; then
    systemctl --user stop "$EXCLUSIVE_SYSTEMD_UNIT" && echo "exclusive stack stopped (user systemd)"
  elif systemctl is-active "$EXCLUSIVE_SYSTEMD_UNIT" >/dev/null 2>&1; then
    sudo -n systemctl stop "$EXCLUSIVE_SYSTEMD_UNIT" && echo "exclusive stack stopped (system systemd)"
  elif exclusive_running; then
    (cd "$EXCLUSIVE_COMPOSE_DIR" && podman-compose down) && echo "exclusive stack down (podman-compose)"
  else
    echo "exclusive stack not running"
  fi
}

# ------------------------------------------------------------------ guards
# Ops rule: loading a big GGUF while the exclusive stack holds most of the
# memory can freeze the box (all TCP down, ICMP alive). Guard against it.
mem_free_gib() { free -g | awk '/^Mem:/{print $7}'; }

start_llama_swap() {
  if pid_alive "$RUN/llama-swap.pid"; then echo "llama-swap already running"; return 0; fi
  if exclusive_running; then
    echo "ERROR: exclusive stack containers are running — they hold most of the RAM." >&2
    echo "Switch first:  bash $REPO/scripts/mode.sh flex   (stops the stack, starts llama-swap)" >&2
    return 1
  fi
  if [ ! -x "$BIN/llama-swap" ]; then
    echo "ERROR: $BIN/llama-swap missing — run scripts/install-llama-swap.sh" >&2
    return 1
  fi
  if [ ! -f "$ETC/llama-swap.yaml" ]; then
    echo "ERROR: $ETC/llama-swap.yaml missing — run scripts/deploy.sh" >&2
    return 1
  fi
  nohup "$BIN/llama-swap" --config "$ETC/llama-swap.yaml" --listen "0.0.0.0:$PORT" \
    >>"$LOGS/llama-swap.log" 2>&1 &
  echo $! > "$RUN/llama-swap.pid"
  echo "llama-swap started (pid $(cat "$RUN/llama-swap.pid"))"
}

start_exclusive() {
  if [ ! -d "$EXCLUSIVE_COMPOSE_DIR" ]; then
    echo "ERROR: $EXCLUSIVE_COMPOSE_DIR not found" >&2
    return 1
  fi
  if systemctl is-enabled --user "$EXCLUSIVE_SYSTEMD_UNIT" >/dev/null 2>&1 || \
     systemctl list-units --user --all 2>/dev/null | grep -q "$EXCLUSIVE_SYSTEMD_UNIT"; then
    systemctl --user start "$EXCLUSIVE_SYSTEMD_UNIT" && echo "exclusive stack started (user systemd)"
  elif systemctl is-enabled "$EXCLUSIVE_SYSTEMD_UNIT" >/dev/null 2>&1 || \
       systemctl list-units --all 2>/dev/null | grep -q "$EXCLUSIVE_SYSTEMD_UNIT"; then
    sudo -n systemctl start "$EXCLUSIVE_SYSTEMD_UNIT" && echo "exclusive stack started (system systemd)"
  else
    (cd "$EXCLUSIVE_COMPOSE_DIR" && podman-compose up -d) && echo "exclusive stack started (podman-compose)"
  fi
}

# Kill any llama-server/llama-hip-server NOT managed by llama-swap (ad-hoc test
# servers). Safe to call only when llama-swap is stopped (mode flow guarantees it).
kill_stray_servers() {
  local n=0
  for pat in "llama-server" "llama-hip-server"; do
    pkill -f "$pat" 2>/dev/null && n=$((n+1)) || true
  done
  sleep 4
  for pat in "llama-server" "llama-hip-server"; do
    pkill -9 -f "$pat" 2>/dev/null || true
  done
  sleep 2
  echo "stray servers cleaned ($n patterns matched)"
}

mode_flex() {
  stop_exclusive
  stop_llama_swap
  kill_stray_servers
  start_llama_swap || return 1
  for _ in $(seq 1 30); do
    [ "$(health)" = "200" ] && { echo "flex mode healthy on :$PORT"; return 0; }
    sleep 1
  done
  echo "WARN: llama-swap up but :$PORT health not 200 yet (check $LOGS/llama-swap.log)"
}

mode_exclusive() {
  stop_llama_swap
  start_exclusive || return 1
  echo "exclusive stack starting — first load after downtime can take minutes;"
  echo "poll: scripts/mode.sh status  (curl :$PORT/v1/models until 200)"
}

mode_stop_all() { stop_llama_swap; stop_exclusive; }

mode_status() {
  echo "llama-swap : $(pid_alive "$RUN/llama-swap.pid" && echo running || echo stopped)"
  echo "exclusive  : $(podman ps --format '{{.Names}}' 2>/dev/null | grep -E "$EXCLUSIVE_CONTAINER_MATCH" | tr '\n' ' ')"
  echo "health     : HTTP $(health) on :$PORT"
  echo "memory     : $(free -h | awk 'NR==2{print $3" used / "$2" total"}')"
}
