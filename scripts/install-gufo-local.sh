#!/usr/bin/env bash
# Build gufo from source on the serving box.
# Set GUFO_BRANCH to use a fork/feature branch (default: main).
# Run via: scripts/jobs.sh run gufo scripts/install-gufo-local.sh
set -euo pipefail

gufo_branch="${GUFO_BRANCH:-main}"

cd "$HOME/src/gufo"
git checkout "$gufo_branch" 2>/dev/null || true
git log --oneline -1

echo "[gufo] configure (release, /opt/rocm)"
rm -rf build/release
cmake --preset release \
      -DCMAKE_PREFIX_PATH=/opt/rocm \
      -DCMAKE_INSTALL_PREFIX="$HOME/.local" \
      -DCMAKE_HIP_COMPILER=/opt/rocm/llvm/bin/clang++ 2>&1 | tail -4

echo "[gufo] build ($(nproc) jobs)"
cmake --build --preset release --parallel "$(nproc)" 2>&1 | tail -4

echo "[gufo] install"
cmake --install build/release 2>&1 | tail -2

mkdir -p "$HOME/bin"
ln -sf "$HOME/.local/bin/gufo" "$HOME/bin/gufo"
"$HOME/bin/gufo" --version 2>&1 | head -2 || true
echo "[gufo] local build done"
