#!/usr/bin/env bash
# Build llama.cpp with ROCm/HIP for gfx1151 (Strix Halo) → ~/bin/llama-hip-server
# HIP allocates from the FULL unified memory pool (122 GiB) unlike Vulkan's
# 20.7 GiB device heap. Run via: scripts/jobs.sh run llama-hip scripts/install-llama-cpp-hip.sh
set -euo pipefail

mkdir -p "$HOME/src" "$HOME/bin"
cd "$HOME/src"
[ -d llama.cpp ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp
cd llama.cpp
git pull --ff-only 2>/dev/null || true

hipconfig=/opt/rocm/bin/hipconfig
[ -x "$hipconfig" ] || { echo "hipconfig missing"; exit 1; }
HIPCXX="$("$hipconfig" -l)/clang"
HIP_PATH="$("$hipconfig" -R)"
echo "[llama.cpp-HIP] HIPCXX=$HIPCXX HIP_PATH=$HIP_PATH"

echo "[llama.cpp-HIP] configure (gfx1151)"
rm -rf build-hip
env HIPCXX="$HIPCXX" HIP_PATH="$HIP_PATH" \
  cmake -B build-hip -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1151 \
        -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF -DGGML_NATIVE=ON

echo "[llama.cpp-HIP] build ($(nproc) jobs)"
cmake --build build-hip -j"$(nproc)" --target llama-server llama-bench llama-perplexity

cp -f build-hip/bin/llama-server    "$HOME/bin/llama-hip-server"
cp -f build-hip/bin/llama-bench     "$HOME/bin/llama-hip-bench"
cp -f build-hip/bin/llama-perplexity "$HOME/bin/llama-hip-perplexity"
"$HOME/bin/llama-hip-server" --version 2>&1 | head -3 || true
echo "[llama.cpp-HIP] done"
