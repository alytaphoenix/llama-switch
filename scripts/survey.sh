#!/usr/bin/env bash
# Hardware/runtime survey of valhalla. Appends a timestamped log to
# benchmarks/results/ and prints it. Safe: read-only on the remote.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/env.sh
source scripts/env.sh
require_valhalla
mkdir -p "$BENCH_DIR"
ts=$(date +%F_%H%M%S)
out="$BENCH_DIR/hw-survey-$ts.log"

v 'bash -s' <<'EOF' | tee "$out"
set -u
echo "== kernel / uptime =="
uname -a; uptime
echo; echo "== memory =="
free -h
echo; echo "== cpu =="
lscpu | sed -n '1,18p'
echo; echo "== gpu (lspci) =="
lspci 2>/dev/null | grep -iE 'vga|display|radeon' || echo "lspci missing"
echo; echo "== devices =="
ls -l /dev/kfd /dev/dri 2>/dev/null || echo "no kfd/dri"
echo; echo "== rocm =="
command -v rocminfo >/dev/null 2>&1 && rocminfo 2>/dev/null | grep -E '^Name:|^Marketing|gfx|' | head -30 || echo "rocminfo not installed"
echo; echo "== vulkan =="
command -v vulkaninfo >/dev/null 2>&1 && vulkaninfo --summary 2>/dev/null | sed -n '1,40p' || echo "vulkaninfo not installed"
echo; echo "== containers =="
command -v podman >/dev/null 2>&1 && { podman --version; podman ps -a 2>/dev/null | head -10; }
command -v docker >/dev/null 2>&1 && { docker --version; docker ps -a 2>/dev/null | head -10; }
true
echo; echo "== running model-ish processes =="
ps aux | grep -iE 'halogen|llama|ollama|tabby|vllm|sglang' | grep -v grep | head -10 || true
echo; echo "== listening ports =="
(ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null) | grep -E ':(8731|8080|8000|11434)' || echo "none of 8731/8080/8000/11434 listening"
echo; echo "== python / hf =="
command -v python3 >/dev/null 2>&1 && python3 --version
command -v hf >/dev/null 2>&1 && hf --version 2>/dev/null | head -1 || echo "hf CLI not installed"
echo; echo "== compilers/build =="
for b in gcc clang cmake ninja make git; do command -v "$b" >/dev/null 2>&1 && echo "$b: ok" || echo "$b: MISSING"; done
echo; echo "== package manager =="
for pm in apt-get dnf zypper pacman; do command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; break; }; done
echo; echo "== disk =="
df -h / | tail -1
df -h "$HOME" 2>/dev/null | tail -1
EOF
echo "survey saved to $out"
