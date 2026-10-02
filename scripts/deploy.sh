#!/usr/bin/env bash
# Deploy repo + configs to valhalla (configs also copied to ~/valhalla/etc).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh
require_valhalla

v "mkdir -p $VALHALLA_REMOTE_REPO $VALHALLA_REMOTE_ETC $VALHALLA_REMOTE_RUN $VALHALLA_REMOTE_LOGS $VALHALLA_REMOTE_MODELS"

# Repo copy (exclude local-only data)
rsync -a --delete \
  --exclude '.git' \
  --exclude 'benchmarks/results' \
  --exclude '.DS_Store' \
  ./ "$VALHALLA_HOST:$VALHALLA_REMOTE_REPO/"

# Configs to the live etc/ dir. llama-swap cmd strings are exec'd directly
# (no shell), so shell vars like $HOME do NOT expand; we render @HOME@ here.
rhome="$(v 'printf %s "$HOME"')"
sed "s|@HOME@|$rhome|g" configs/llama-swap.yaml > "$BENCH_DIR/.llama-swap-rendered.yaml"
rsync -a "$BENCH_DIR/.llama-swap-rendered.yaml" "$VALHALLA_HOST:$VALHALLA_REMOTE_ETC/llama-swap.yaml"
rm -f "$BENCH_DIR/.llama-swap-rendered.yaml"
rsync -a configs/halogen/halogen.env "$VALHALLA_HOST:$VALHALLA_REMOTE_ETC/halogen.env"

echo "deployed to $VALHALLA_HOST:~/valhalla/{repo,etc}"
