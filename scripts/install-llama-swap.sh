#!/usr/bin/env bash
# Install llama-swap (single static binary) on the serving box → ~/bin/llama-swap
# Run via: scripts/jobs.sh run llama-swap scripts/install-llama-swap.sh
set -euo pipefail

mkdir -p "$HOME/bin" "$HOME/src"
cd "$HOME/src"

tag="$(curl -fsSL https://api.github.com/repos/mostlygeek/llama-swap/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')"
tag="${tag#v}"
echo "[llama-swap] latest tag: $tag"

asset="llama-swap_${tag}_linux_amd64.tar.gz"
url="https://github.com/mostlygeek/llama-swap/releases/download/$tag/$asset"
echo "[llama-swap] trying asset: $asset"
mkdir -p llama-swap-dl && cd llama-swap-dl
if ! curl -fsSL -o "$asset" "$url"; then
  # fall back: list assets and grab the linux amd64 tarball whatever it's named
  echo "[llama-swap] asset guess failed; listing release assets"
  curl -fsSL "https://api.github.com/repos/mostlygeek/llama-swap/releases/latest" \
    | grep -oP '"browser_download_url":\s*"\K[^"]*linux[^"]*amd64[^"]*' | head -5
  asset_url="$(curl -fsSL "https://api.github.com/repos/mostlygeek/llama-swap/releases/latest" \
    | grep -oP '"browser_download_url":\s*"\K[^"]*linux[^"]*amd64[^"]*' | head -1)"
  curl -fsSL -o "$asset" "$asset_url"
fi
tar -xzf "$asset"
bin="$(find . -maxdepth 2 -name 'llama-swap' -type f | head -1)"
[ -n "$bin" ] || { echo "[llama-swap] binary not found in archive"; exit 1; }
cp -f "$bin" "$HOME/bin/llama-swap"
chmod +x "$HOME/bin/llama-swap"
"$HOME/bin/llama-swap" --help 2>&1 | head -5 || true
echo "[llama-swap] installed at $HOME/bin/llama-swap"
