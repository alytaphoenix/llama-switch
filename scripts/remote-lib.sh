#!/usr/bin/env bash
# Remote-side library. Runs ON the serving box (sourced via ssh from mode.sh).
# Deployed copy: ~/llama-switch/repo/scripts/remote-lib.sh
# shellcheck shell=bash
set -u

# The remote root is overridable so a box can keep its own layout (e.g. an
# existing ~/valhalla with models symlinked to /srv) instead of a second
# parallel tree.
ROOT="$HOME/${LS_REMOTE_ROOT:-llama-switch}"

# Box settings live on the box. Anything that must survive an ssh into a fresh
# shell -- which model answers a request that names no model, where the box's
# config lives -- belongs in a settings file here, not in the environment of
# whoever happened to run mode.sh. Sourced before the settings below are
# resolved, so box.env can set any of them.
#
# $HOME/.llama-switch.box.env is listed first and is independent of ROOT: a box
# whose root is not ~/llama-switch would otherwise be unable to configure the
# root in the first place, and a file inside ROOT/repo would be deleted by the
# next deploy (rsync --delete).
for _boxenv in "$HOME/.llama-switch.box.env" "$ROOT/box.env" "$ROOT/etc/box.env"; do
  if [ -f "$_boxenv" ]; then
    # shellcheck disable=SC1090
    . "$_boxenv"
  fi
done
unset _boxenv

REPO="$ROOT/repo"
# The config directory is overridable independently of ROOT. A box usually owns
# its llama-swap.yaml (real weight paths, tuning) while using these scripts, so
# LS_REMOTE_ETC points at the box's config without this repo taking ownership of
# it -- deploying ours over theirs would silently change a serving box.
ETC="${LS_REMOTE_ETC:-$ROOT/etc}"
RUN="$ROOT/run"
LOGS="$ROOT/logs"
BIN="$HOME/bin"
# Public port: the llama-switch front proxy. llama-swap moves behind it.
PORT="${LS_API_PORT:-8731}"
BACKEND_PORT="${LS_BACKEND_PORT:-8732}"
DEFAULT_MODEL="${LS_DEFAULT_MODEL:-}"
PROXY_HOST="${LS_PROXY_HOST:-0.0.0.0}"
PROXY="$REPO/scripts/remote-proxy.py"

# The exclusive stack (podman-compose, optionally a systemd user unit).
# Overridable via the environment when this file is sourced.
EXCLUSIVE_COMPOSE_DIR="${EXCLUSIVE_COMPOSE_DIR:-$ROOT/stack}"
EXCLUSIVE_SYSTEMD_UNIT="${EXCLUSIVE_SYSTEMD_UNIT:-podman-compose@exclusive.service}"
EXCLUSIVE_CONTAINER_MATCH="${EXCLUSIVE_CONTAINER_MATCH:-exclusive}"

mkdir -p "$RUN" "$LOGS" 2>/dev/null || true

pid_alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

health() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/v1/models" 2>/dev/null || echo 000; }

# Health of llama-swap itself, i.e. what the proxy forwards to.
backend_health() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$BACKEND_PORT/v1/models" 2>/dev/null || echo 000; }

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

# The front proxy owns the public port, so it must be stopped (and :$PORT
# freed) before anything else can bind it.
stop_proxy() {
  if pid_alive "$RUN/proxy.pid"; then
    kill "$(cat "$RUN/proxy.pid")" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pid_alive "$RUN/proxy.pid" || break; sleep 0.5; done
    pid_alive "$RUN/proxy.pid" && kill -9 "$(cat "$RUN/proxy.pid")" 2>/dev/null
    rm -f "$RUN/proxy.pid"
    echo "llama-switch proxy stopped"
  else
    echo "llama-switch proxy not running"
  fi
}

start_proxy() {
  if pid_alive "$RUN/proxy.pid"; then echo "llama-switch proxy already running"; return 0; fi
  if [ ! -f "$PROXY" ]; then
    echo "ERROR: $PROXY missing — run scripts/deploy.sh" >&2
    return 1
  fi
  if [ "$(backend_health)" != "200" ]; then
    echo "ERROR: llama-swap backend unhealthy on :$BACKEND_PORT (HTTP $(backend_health))" >&2
    return 1
  fi
  nohup python3 "$PROXY" \
      --listen-host "$PROXY_HOST" --listen-port "$PORT" \
      --backend-host 127.0.0.1 --backend-port "$BACKEND_PORT" \
      --default-model "$DEFAULT_MODEL" \
      >>"$LOGS/proxy.log" 2>&1 &
  echo $! > "$RUN/proxy.pid"
  # Confirm it really answers before claiming the port is up.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ "$(health)" = "200" ] && { echo "llama-switch proxy started (pid $(cat "$RUN/proxy.pid"))"; return 0; }
    pid_alive "$RUN/proxy.pid" || break
    sleep 0.5
  done
  echo "ERROR: llama-switch proxy did not come up on :$PORT (see $LOGS/proxy.log)" >&2
  return 1
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
  nohup "$BIN/llama-swap" --config "$ETC/llama-swap.yaml" --listen "127.0.0.1:$BACKEND_PORT" \
    >>"$LOGS/llama-swap.log" 2>&1 &
  echo $! > "$RUN/llama-swap.pid"
  echo "llama-swap started (pid $(cat "$RUN/llama-swap.pid")) on :$BACKEND_PORT"
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
  # Order matters: the proxy owns :$PORT, so release it before llama-swap
  # claims the backend port, and bring the proxy up only once the backend is
  # healthy.
  stop_proxy
  stop_llama_swap
  kill_stray_servers
  start_llama_swap || return 1
  for _ in $(seq 1 30); do
    [ "$(backend_health)" = "200" ] && break
    sleep 1
  done
  if [ "$(backend_health)" != "200" ]; then
    echo "WARN: llama-swap up but :$BACKEND_PORT health not 200 yet (check $LOGS/llama-swap.log)"
  fi
  start_proxy || return 1
  echo "flex mode healthy on :$PORT (proxy -> llama-swap :$BACKEND_PORT, default=${DEFAULT_MODEL:-none})"
}

mode_exclusive() {
  stop_proxy
  stop_llama_swap
  start_exclusive || return 1
  echo "exclusive stack starting — first load after downtime can take minutes;"
  echo "poll: scripts/mode.sh status  (curl :$PORT/v1/models until 200)"
}

mode_stop_all() { stop_proxy; stop_llama_swap; stop_exclusive; }

mode_status() {
  echo "proxy       : $(pid_alive "$RUN/proxy.pid" && echo "running (pid $(cat "$RUN/proxy.pid"))" || echo stopped)  default=${DEFAULT_MODEL:-none}"
  echo "llama-swap  : $(pid_alive "$RUN/llama-swap.pid" && echo "running on :$BACKEND_PORT" || echo stopped)"
  echo "exclusive   : $(podman ps --format '{{.Names}}' 2>/dev/null | grep -E "$EXCLUSIVE_CONTAINER_MATCH" | tr '\n' ' ')"
  echo "health      : HTTP $(health) on :$PORT (public)"
  echo "memory      : $(free -h | awk 'NR==2{print $3" used / "$2" total"}')"
}
