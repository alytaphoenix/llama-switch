#!/usr/bin/env bash
# Build llama.cpp (Vulkan backend) on the serving box → ~/bin/llama-server etc.
# Run via: scripts/jobs.sh run llama-cpp scripts/install-llama-cpp.sh
set -euo pipefail

echo "[llama.cpp] apt deps"
if ! command -v cmake >/dev/null 2>&1 || ! command -v glslc >/dev/null 2>&1 || \
   ! ls /usr/include/vulkan/vulkan.h >/dev/null 2>&1; then
  # tolerate broken third-party repos (e.g. rocm/apt with missing Release file)
  sudo -n apt-get update -qq || echo "[llama.cpp] WARN: apt-get update had errors, continuing"
  sudo -n apt-get install -y -qq glslc glslang-tools libvulkan-dev spirv-headers cmake ninja-build python3-venv
fi
glslc="$(command -v glslc || command -v glslangValidator || true)"
echo "[llama.cpp] shader compiler: ${glslc:-MISSING}"

# Ubuntu's spirv-headers package ships no CMake config; vendor it ourselves.
if ! find_package_test="$(cmake --find-package -DNAME=SPIRV-Headers -DCOMPILER_ID=GNU -DLANGUAGE=CXX -DMODE=EXIST 2>/dev/null)"; then
  echo "[llama.cpp] vendoring SPIRV-Headers"
  mkdir -p "$HOME/src" "$HOME/.local/spirv"
  cd "$HOME/src"
  [ -d SPIRV-Headers ] || git clone --depth 1 https://github.com/KhronosGroup/SPIRV-Headers
  cmake -B SPIRV-Headers/build -S SPIRV-Headers -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$HOME/.local/spirv" >/dev/null
  cmake --install SPIRV-Headers/build >/dev/null
  cd "$HOME/src/llama.cpp"
fi
SPV_PREFIX="$HOME/.local/spirv"

mkdir -p "$HOME/src" "$HOME/bin"
cd "$HOME/src"
[ -d llama.cpp ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp
cd llama.cpp
git pull --ff-only 2>/dev/null || true

echo "[llama.cpp] configure (Vulkan)"
rm -rf build
cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF -DGGML_NATIVE=ON \
      -DCMAKE_PREFIX_PATH="$SPV_PREFIX" \
      -DCMAKE_CXX_FLAGS="-isystem $SPV_PREFIX/include"

echo "[llama.cpp] build ($(nproc) jobs)"
cmake --build build -j"$(nproc)" --target llama-server llama-cli llama-bench llama-perplexity llama-quantize

cp -f build/bin/llama-server build/bin/llama-bench build/bin/llama-perplexity build/bin/llama-quantize "$HOME/bin/"
"$HOME/bin/llama-server" --version 2>&1 | head -3 || true
echo "[llama.cpp] done"
