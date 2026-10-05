#!/usr/bin/env bash
# Telemetry driver: samples power/thermal on the serving box while a workload runs.
# The sampler (remote-telemetry.py) runs on the serving box; this script pushes it,
# starts/stops it, and fetches the CSV into benchmarks/results/.
#
#   scripts/telemetry.sh run <tag> <cmd...>   # start, run cmd, stop, fetch
#   scripts/telemetry.sh start <tag>          # start sampler (run workload yourself)
#   scripts/telemetry.sh stop <tag>           # stop sampler, fetch CSV
#   scripts/telemetry.sh status [tag]         # show sampler state
#
# Env: TELEMETRY_INTERVAL (default 0.2 s)
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh

INTERVAL="${TELEMETRY_INTERVAL:-0.2}"
RESULTS="$BENCH_DIR"
# Relative to the remote $HOME (ssh non-interactive cwd); the logs dir exists.
REMOTE_TELE="llama-switch/logs"

push_sampler() {
  v "mkdir -p $REMOTE_TELE"
  scp -q scripts/remote-telemetry.py "$LS_HOST:$REMOTE_TELE/remote-telemetry.py"
}

start() {
  local tag="$1"
  push_sampler
  # Detach discipline (learned the hard way, 2026-10-03):
  #  - background ONLY the python (brace group), not the whole "cd && rm && ..."
  #    chain — a backgrounded chain stays alive waiting on python and holds the
  #    ssh channel open forever;
  #  - </dev/null on the sampler: its stdin must not be the ssh channel either.
  v "cd $REMOTE_TELE && rm -f tele-$tag.pid && { nohup python3 remote-telemetry.py \
       --out tele-$tag-\$(date +%F_%H%M%S).csv --interval $INTERVAL \
       < /dev/null > tele-$tag.log 2>&1 & echo \$! > tele-$tag.pid; }"
  echo "sampler started on the box (tag=$tag, interval=${INTERVAL}s)"
}

stop() {
  local tag="$1" pid csv
  pid=$(v "cat $REMOTE_TELE/tele-$tag.pid 2>/dev/null" || true)
  if [ -n "${pid:-}" ]; then
    v "kill $pid 2>/dev/null; sleep 1; kill -0 $pid 2>/dev/null && kill -9 $pid 2>/dev/null; rm -f $REMOTE_TELE/tele-$tag.pid"
  fi
  csv=$(v "ls -t $REMOTE_TELE/tele-$tag-*.csv 2>/dev/null | head -1" || true)
  if [ -n "${csv:-}" ]; then
    mkdir -p "$RESULTS"
    scp -q "$LS_HOST:$csv" "$RESULTS/"
    echo "fetched $csv -> $RESULTS/$(basename "$csv")"
  else
    echo "WARN: no CSV found for tag=$tag" >&2
  fi
}

status() {
  local tag="${1:-}"
  if [ -n "$tag" ]; then
    v "cd $REMOTE_TELE && { [ -f tele-$tag.pid ] && kill -0 \$(cat tele-$tag.pid) 2>/dev/null && echo 'sampler running (pid '\$(cat tele-$tag.pid)')' || echo 'sampler not running'; }; tail -3 tele-$tag.log 2>/dev/null"
  else
    v "cd $REMOTE_TELE && ls -t tele-*.pid 2>/dev/null || echo 'no samplers'"
  fi
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  run)
    tag="${1:?usage: telemetry.sh run <tag> <cmd...>}"; shift
    start "$tag"
    trap 'stop "$tag"' EXIT
    "$@"
    stop "$tag"
    trap - EXIT
    ;;
  start) start "${1:?usage: telemetry.sh start <tag>}" ;;
  stop)  stop "${1:?usage: telemetry.sh stop <tag>}" ;;
  status) status "${1:-}" ;;
  *) echo "usage: $0 run|start|stop|status [tag] [cmd...]"; exit 1 ;;
esac
