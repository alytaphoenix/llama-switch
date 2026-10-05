#!/usr/bin/env python3
"""Power/thermal sampler for the serving box. Runs ON the box.

Samples amd-smi (socket/sys/GFX power, clocks, temps, DRAM bandwidth) plus
hwmon sensors (k10temp Tctl, acpitz, amdgpu) at a fixed interval and writes
a CSV. Stop with SIGTERM/SIGINT; it flushes and exits cleanly.

Usage:
  python3 remote-telemetry.py --out /path/out.csv [--interval 0.2]
"""
import argparse
import csv
import os
import signal
import subprocess
import sys
import time

AMD_SMI = ["amd-smi", "metric", "-p", "-t", "-c", "-u", "--csv"]


def find_hwmon(name: str) -> str | None:
    base = "/sys/class/hwmon"
    for d in sorted(os.listdir(base)):
        try:
            with open(f"{base}/{d}/name") as f:
                if f.read().strip() == name:
                    return f"{base}/{d}"
        except OSError:
            continue
    return None


def read_str(path: str) -> str:
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def parse_array(s: str):
    """Parse amd-smi CSV array cells like '[0.02, 0.01]' into floats."""
    s = s.strip()
    if not s.startswith("["):
        try:
            return [float(s)]
        except ValueError:
            return []
    vals = []
    for part in s[1:-1].split(","):
        part = part.strip().strip("'\"")
        if part in ("N/A", ""):
            continue
        try:
            vals.append(float(part))
        except ValueError:
            pass
    return vals


def pick(row: dict, name: str):
    v = row.get(name, "")
    if v in ("", "N/A"):
        return ""
    return v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--interval", type=float, default=0.2)
    a = ap.parse_args()

    k10 = find_hwmon("k10temp")
    acpi = find_hwmon("acpitz")
    amdg = find_hwmon("amdgpu")

    running = True

    def stop(signum, frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    header = [
        "ts",
        "socket_w",        # instantaneous APU socket power
        "sys_w",           # APU average system power (incl. memory fabric)
        "gfx_w",           # APU average iGPU power
        "cpu_w",           # APU average all-core CPU power
        "edge_c",          # amdgpu edge temp
        "tctl_c",          # k10temp (CPU)
        "acpitz_c",        # acpitz (board)
        "amdgpu_w",        # amdgpu hwmon power1_average
        "amdgpu_c",        # amdgpu hwmon temp1
        "sclk_mhz",        # average gfx clock
        "uclk_mhz",        # average memory clock
        "cpu_clk_mhz",     # max per-core clock
        "dram_r_mbs",      # average DRAM read bandwidth
        "dram_w_mbs",      # average DRAM write bandwidth
        "gfx_busy_pct",    # average gfx activity
    ]

    f = open(a.out, "w", newline="")
    w = csv.writer(f)
    w.writerow(header)

    while running:
        t0 = time.time()
        try:
            out = subprocess.run(AMD_SMI, capture_output=True, text=True, timeout=5)
            lines = [l for l in out.stdout.splitlines() if l.strip()]
            row = {}
            if len(lines) >= 2:
                hdr = next(csv.reader([lines[0]]))
                vals = next(csv.reader([lines[1]]))
                # lowercase keys: amd-smi CSV mixes case (APU_AVERAGE_* vs
                # apu_average_*) depending on metric flags
                row = {k.lower(): v for k, v in zip(hdr, vals)}
        except (subprocess.TimeoutExpired, OSError) as e:
            sys.stderr.write(f"amd-smi failed: {e}\n")
            row = {}

        def scalar(name):
            v = pick(row, name)
            if v == "":
                return ""
            return v

        def arrmax(name):
            vals = parse_array(pick(row, name) or "")
            return max(vals) if vals else ""

        def arrsum(name):
            vals = parse_array(pick(row, name) or "")
            return round(sum(vals), 2) if vals else ""

        rec = [
            f"{t0:.3f}",
            scalar("socket_power"),
            scalar("apu_average_sys_power"),
            scalar("apu_average_gfx_power"),
            scalar("apu_average_all_core_power"),
            scalar("edge"),
            f"{int(read_str(f'{k10}/temp1_input') or 0) / 1000:.1f}" if k10 else "",
            f"{int(read_str(f'{acpi}/temp1_input') or 0) / 1000:.1f}" if acpi else "",
            f"{int(read_str(f'{amdg}/power1_average') or 0) / 1000:.1f}" if amdg else "",
            f"{int(read_str(f'{amdg}/temp1_input') or 0) / 1000:.1f}" if amdg else "",
            scalar("apu_average_gfxclk_frequency"),
            scalar("apu_average_uclk_frequency"),
            arrmax("apu_current_coreclk"),
            scalar("apu_average_dram_reads"),
            scalar("apu_average_dram_writes"),
            scalar("apu_average_gfx_activity"),
        ]
        w.writerow(rec)
        f.flush()

        elapsed = time.time() - t0
        sleep = a.interval - elapsed
        if sleep > 0:
            # sleep in small chunks so signals are handled promptly
            end = time.time() + sleep
            while running and time.time() < end:
                time.sleep(min(0.1, end - time.time()))

    f.close()
    print(f"wrote {a.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
