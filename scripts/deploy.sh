#!/usr/bin/env bash
# Deploy repo + configs to the serving box (configs also copied to ~/llama-switch/etc).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh
require_remote

v "mkdir -p $LS_REMOTE_REPO $LS_REMOTE_ETC $LS_REMOTE_RUN $LS_REMOTE_LOGS $LS_REMOTE_MODELS"

# Repo copy (exclude local-only data)
rsync -a --delete \
  --exclude '.git' \
  --exclude 'benchmarks/results' \
  --exclude '.DS_Store' \
  ./ "$LS_HOST:$LS_REMOTE_REPO/"

# Configs to the live etc/ dir. llama-swap cmd strings are exec'd directly
# (no shell), so shell vars like $HOME do NOT expand; we render @HOME@ here.
rhome="$(v 'printf %s "$HOME"')"
sed "s|@HOME@|$rhome|g" configs/llama-swap.yaml > "$BENCH_DIR/.llama-swap-rendered.yaml"
rsync -a "$BENCH_DIR/.llama-swap-rendered.yaml" "$LS_HOST:$LS_REMOTE_ETC/llama-swap.yaml"
rm -f "$BENCH_DIR/.llama-swap-rendered.yaml"
rsync -a configs/exclusive/halogen.env "$LS_HOST:$LS_REMOTE_ETC/halogen.env"

echo "deployed to $LS_HOST:~/llama-switch/{repo,etc}"
