#!/usr/bin/env bash
# Build llama.cpp with ROCm/HIP on the serving box → ~/bin/llama-hip-server
# HIP allocates from the FULL unified memory pool on APUs, unlike Vulkan's
# small device heap. Set HIP_TARGETS for your GPU (default gfx1151).
# Run via: scripts/jobs.sh run llama-hip scripts/install-llama-cpp-hip.sh
set -euo pipefail

hip_targets="${HIP_TARGETS:-gfx1151}"

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

echo "[llama.cpp-HIP] configure ($hip_targets)"
rm -rf build-hip
env HIPCXX="$HIPCXX" HIP_PATH="$HIP_PATH" \
  cmake -B build-hip -DGGML_HIP=ON -DAMDGPU_TARGETS="$hip_targets" \
        -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF -DGGML_NATIVE=ON

echo "[llama.cpp-HIP] build ($(nproc) jobs)"
cmake --build build-hip -j"$(nproc)" --target llama-server llama-bench llama-perplexity

cp -f build-hip/bin/llama-server    "$HOME/bin/llama-hip-server"
cp -f build-hip/bin/llama-bench     "$HOME/bin/llama-hip-bench"
cp -f build-hip/bin/llama-perplexity "$HOME/bin/llama-hip-perplexity"
"$HOME/bin/llama-hip-server" --version 2>&1 | head -3 || true
echo "[llama.cpp-HIP] done"
