#!/usr/bin/env python3
"""Aggregate benchmarks/results/*.json (JSONL from bench harnesses) → MATRIX.md.

Reads {"summary": ...} lines from api_bench / needle / tool_call probes and
writes a markdown decision table. Usage: python3 benchmarks/matrix.py
"""
import glob
import json
import os

OUT = "benchmarks/MATRIX.md"
HEADER = """# Benchmark matrix — valhalla

Decision table for serving configs on Strix Halo (128 GB, gfx1151).
Raw data: `benchmarks/results/*.json`. Regenerate: `python3 benchmarks/matrix.py`.

"""

def main():
    api_rows = []      # (file, summary)
    needle_rows = []
    tool_rows = []
    for path in sorted(glob.glob("benchmarks/results/*.json")):
        for line in open(path):
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            s = obj.get("summary")
            if not s:
                continue
            if "median_decode_tps" in s:
                api_rows.append((path, s))
            elif "retrieval" in s:
                needle_rows.append((path, s))
            elif "tool_call_ok" in s:
                tool_rows.append((path, s))

    with open(OUT, "w") as f:
        f.write(HEADER)
        f.write("## Throughput (OpenAI API probes)\n\n")
        if api_rows:
            f.write("| file | model | ctx | gen | TTFT s | decode t/s |\n|---|---|---|---|---|---|\n")
            for path, s in api_rows:
                f.write(
                    f"| {os.path.basename(path)} | {s['model']} | {s['ctx_tokens']} | "
                    f"{s['gen']} | {s['median_ttft_s']} | {s['median_decode_tps']} |\n"
                )
        else:
            f.write("_no api_bench results yet_\n")
        f.write("\n## Long-context retrieval (needle)\n\n")
        if needle_rows:
            f.write("| file | model | retrieval hits by ctx |\n|---|---|---|\n")
            for path, s in needle_rows:
                f.write(f"| {os.path.basename(path)} | {s['model']} | {s['retrieval']} |\n")
        else:
            f.write("_no needle results yet_\n")
        f.write("\n## Tool calling (agentic smoke)\n\n")
        if tool_rows:
            f.write("| file | model | correct tool calls |\n|---|---|---|\n")
            for path, s in tool_rows:
                f.write(f"| {os.path.basename(path)} | {s['model']} | {s['tool_call_ok']} |\n")
        else:
            f.write("_no tool-call results yet_\n")
        f.write("\n## Working decisions\n\n- (fill after benchmark runs)\n")
    print(f"wrote {OUT}")

if __name__ == "__main__":
    main()
