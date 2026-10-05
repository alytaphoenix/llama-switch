#!/usr/bin/env bash
# Long-running remote jobs (builds, downloads) with pidfiles + logs.
#   scripts/jobs.sh run <name> <remote-script-relpath> [args...]
#   scripts/jobs.sh status
#   scripts/jobs.sh tail <name> [lines]
#   scripts/jobs.sh stop <name>
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh
require_remote

case "${1:-}" in
  run)
    name="${2:?name}"; script="${3:?repo-relative script path}"; shift 3
    args=""; for a in "$@"; do args="$args $(printf '%q' "$a")"; done
    v "bash -c 'mkdir -p $LS_REMOTE_RUN $LS_REMOTE_LOGS/jobs
      nohup bash $LS_REMOTE_REPO/$script$args \\
        > $LS_REMOTE_LOGS/jobs/$name.log 2>&1 &
      echo \$! > $LS_REMOTE_RUN/job-$name.pid
      echo \"job $name started (pid \$(cat $LS_REMOTE_RUN/job-$name.pid))\"'"
    ;;
  status)
    v "bash -c 'for f in $LS_REMOTE_RUN/job-*.pid; do
        [ -e \"\$f\" ] || { echo \"no jobs\"; exit 0; }
        p=\$(cat \"\$f\")
        if kill -0 \"\$p\" 2>/dev/null; then echo \"RUNNING \$(basename \"\$f\") (pid \$p)\"
        else echo \"DONE   \$(basename \"\$f\") (pid \$p)\"; fi
      done'"
    ;;
  tail)
    name="${2:?name}"; lines="${3:-25}"
    v "tail -n $lines $LS_REMOTE_LOGS/jobs/$name.log"
    ;;
  stop)
    name="${2:?name}"
    v "bash -c 'p=\$(cat $LS_REMOTE_RUN/job-$name.pid 2>/dev/null) && kill \$p && echo stopped $name'"
    ;;
  *)
    echo "usage: $0 run <name> <script> [args...] | status | tail <name> [n] | stop <name>" >&2
    exit 1
    ;;
esac
