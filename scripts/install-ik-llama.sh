#!/usr/bin/env bash
# Build ik_llama.cpp (CPU, Zen5 AVX-512 IQK path) on the serving box → ~/bin/ik-server
# Run via: scripts/jobs.sh run ik-server scripts/install-ik-llama.sh
set -euo pipefail

mkdir -p "$HOME/src" "$HOME/bin"
cd "$HOME/src"
[ -d ik_llama.cpp ] || git clone --depth 1 https://github.com/ikawrakow/ik_llama.cpp
cd ik_llama.cpp
git pull --ff-only 2>/dev/null || true

echo "[ik] configure (CPU AVX-512 per docs/build.md)"
rm -rf build
cmake -B build -DCMAKE_BUILD_TYPE=Release \
      -DGGML_NATIVE=ON \
      -DGGML_AVX512=ON \
      -DGGML_AVX512_VBMI=ON \
      -DGGML_AVX512_VNNI=ON \
      -DGGML_AVX512_BF16=ON \
      -DLLAMA_CURL=OFF

echo "[ik] build ($(nproc) jobs)"
cmake --build build --config Release -j"$(nproc)"

echo "[ik] verify AVX-512 IQK path (expect 'hundreds' of vpdpbusd)"
echo "vpdpbusd count: $(objdump -d build/bin/llama-cli | grep -c vpdpbusd || true)"

cp -f build/bin/llama-server  "$HOME/bin/ik-server"
cp -f build/bin/llama-cli     "$HOME/bin/ik-cli" 2>/dev/null || true
cp -f build/bin/llama-bench   "$HOME/bin/ik-bench" 2>/dev/null || true
"$HOME/bin/ik-server" --version 2>&1 | head -2 || true
echo "[ik] done"
