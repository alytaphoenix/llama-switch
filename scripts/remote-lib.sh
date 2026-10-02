#!/usr/bin/env bash
# Remote-side library. Runs ON valhalla (sourced via ssh from mode.sh / jobs).
# Deployed copy: ~/valhalla/repo/scripts/remote-lib.sh
# shellcheck shell=bash
set -u

REPO="$HOME/valhalla/repo"
ETC="$HOME/valhalla/etc"
RUN="$HOME/valhalla/run"
LOGS="$HOME/valhalla/logs"
BIN="$HOME/bin"
PORT="${VALHALLA_API_PORT:-8731}"

# Your existing halogen stack (podman-compose, systemd user unit)
HALOGEN_COMPOSE_DIR="/srv/backends/halogen"
HALOGEN_SYSTEMD_UNIT="podman-compose@halogen.service"

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

stop_halogen() {
  if systemctl is-active --user "$HALOGEN_SYSTEMD_UNIT" >/dev/null 2>&1; then
    systemctl --user stop "$HALOGEN_SYSTEMD_UNIT" && echo "halogen compose stopped (user systemd)"
  elif systemctl is-active "$HALOGEN_SYSTEMD_UNIT" >/dev/null 2>&1; then
    sudo -n systemctl stop "$HALOGEN_SYSTEMD_UNIT" && echo "halogen compose stopped (system systemd)"
  elif podman ps --format '{{.Names}}' 2>/dev/null | grep -q halogen; then
    (cd "$HALOGEN_COMPOSE_DIR" && podman-compose down) && echo "halogen compose down (podman-compose)"
  else
    echo "halogen not running"
  fi
}

# ------------------------------------------------------------------ guards
# Ops rule learned 2026-10-01: loading a big GGUF while halogen holds memory
# freezes the box (all TCP down, ICMP alive). Guard against it.
halogen_running() { podman ps --format '{{.Names}}' 2>/dev/null | grep -q halogen; }

mem_free_gib() { free -g | awk '/^Mem:/{print $7}'; }

start_llama_swap() {
  if pid_alive "$RUN/llama-swap.pid"; then echo "llama-swap already running"; return 0; fi
  if halogen_running; then
    echo "ERROR: halogen containers are running — they hold most of the RAM." >&2
    echo "Switch first:  bash $REPO/scripts/mode.sh flex   (stops halogen, starts llama-swap)" >&2
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

start_halogen() {
  if [ ! -d "$HALOGEN_COMPOSE_DIR" ]; then
    echo "ERROR: $HALOGEN_COMPOSE_DIR not found" >&2
    return 1
  fi
  if systemctl is-enabled --user "$HALOGEN_SYSTEMD_UNIT" >/dev/null 2>&1 || \
     systemctl list-units --user --all 2>/dev/null | grep -q "$HALOGEN_SYSTEMD_UNIT"; then
    systemctl --user start "$HALOGEN_SYSTEMD_UNIT" && echo "halogen compose started (user systemd)"
  elif systemctl is-enabled "$HALOGEN_SYSTEMD_UNIT" >/dev/null 2>&1 || \
       systemctl list-units --all 2>/dev/null | grep -q "$HALOGEN_SYSTEMD_UNIT"; then
    sudo -n systemctl start "$HALOGEN_SYSTEMD_UNIT" && echo "halogen compose started (system systemd)"
  else
    (cd "$HALOGEN_COMPOSE_DIR" && podman-compose up -d) && echo "halogen compose started (podman-compose)"
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
  stop_halogen
  stop_llama_swap
  kill_stray_servers
  start_llama_swap || return 1
  for _ in $(seq 1 30); do
    [ "$(health)" = "200" ] && { echo "flex mode healthy on :$PORT"; return 0; }
    sleep 1
  done
  echo "WARN: llama-swap up but :$PORT health not 200 yet (check $LOGS/llama-swap.log)"
}

mode_halogen() {
  stop_llama_swap
  start_halogen || return 1
  echo "halogen starting — first load after downtime can take minutes;"
  echo "poll: scripts/mode.sh status  (curl :$PORT/v1/models until 200)"
}

mode_stop_all() { stop_llama_swap; stop_halogen; }

mode_status() {
  echo "llama-swap : $(pid_alive "$RUN/llama-swap.pid" && echo running || echo stopped)"
  echo "halogen    : $(podman ps --format '{{.Names}}' 2>/dev/null | grep halogen | tr '\n' ' ')"
  echo "health     : HTTP $(health) on :$PORT"
  echo "memory     : $(free -h | awk 'NR==2{print $3" used / "$2" total"}')"
}
