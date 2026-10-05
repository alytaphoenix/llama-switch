#!/usr/bin/env bash
# Download model quants on the serving box (hf CLI in a venv).
# Usage (via jobs): scripts/jobs.sh run dl-27b scripts/download-models.sh \
#   ukisai/Swift-1.5-Qwen3.8-27B-GGUF "Swift-1.5-Qwen3.8-27B-Q8_0.gguf" ukisai/Swift-1.5-Qwen3.8-27B-GGUF [revision]
set -euo pipefail
repo="${1:?hf repo}"; include="${2:?glob}"; dest="${3:?dest under llama-switch/models}"; rev="${4:-}"

mkdir -p "$HOME/llama-switch/models/$dest"
HF="$HOME/llama-switch/venv/bin/hf"
if [ ! -x "$HF" ]; then
  echo "[hf] creating venv + installing huggingface_hub"
  if python3 -m venv "$HOME/llama-switch/venv" 2>/dev/null; then
    "$HOME/llama-switch/venv/bin/pip" install -q -U pip huggingface_hub hf_transfer
    HF="$HOME/llama-switch/venv/bin/hf"
  else
    echo "[hf] venv unavailable; installing user-level (--user)"
    python3 -m pip install -q --user --break-system-packages -U huggingface_hub hf_transfer 2>/dev/null || \
      python3 -m pip install -q --user -U huggingface_hub hf_transfer
    HF="$(command -v hf || command -v huggingface-cli || echo "$HOME/.local/bin/hf")"
  fi
fi
export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_XET_HIGH_PERFORMANCE=1
extra=()
[ -n "$rev" ] && extra+=(--revision "$rev")
echo "[hf] $repo ($include) → $HOME/llama-switch/models/$dest${rev:+ @ $rev}"
"$HF" download "$repo" --include "$include" --local-dir "$HOME/llama-switch/models/$dest" "${extra[@]+"${extra[@]}"}"
echo "[hf] done:"
ls -lh "$HOME/llama-switch/models/$dest" | head -20
