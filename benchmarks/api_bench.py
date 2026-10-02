#!/usr/bin/env python3
"""Throughput probe against any OpenAI-compatible endpoint (halogen, llama-swap).

Streams a chat completion and reports TTFT (≈ prefill speed) and decode t/s.
Prints one JSON object per repeat, then a final {"summary": {...}} line.

Usage:
  api_bench.py --url http://valhalla:8731 --model swift-1.5-27b-q8 \
               --ctx 16384 --gen 256 --repeat 3
"""
import argparse
import json
import time
import urllib.request

FILLER = (
    "The archivist organized the shelves by expedition year, catalogued every "
    "artifact, and rewrote the index cards in careful handwriting. "
)


def stream_chat(url: str, model: str, prompt: str, gen_tokens: int):
    body = json.dumps(
        {
            "model": model,
            "stream": True,
            "max_tokens": gen_tokens,
            "temperature": 0,
            "messages": [{"role": "user", "content": prompt}],
        }
    ).encode()
    req = urllib.request.Request(
        url.rstrip("/") + "/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    t0 = time.time()
    ttft = None
    n = 0
    with urllib.request.urlopen(req, timeout=3600) as r:
        for raw in r:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            try:
                obj = json.loads(payload)
            except json.JSONDecodeError:
                continue
            choices = obj.get("choices") or [{}]
            delta = choices[0].get("delta") or {}
            if delta.get("content") or delta.get("reasoning_content"):
                if ttft is None:
                    ttft = time.time() - t0
                n += 1
    return t0, ttft, n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--ctx", type=int, default=4096, help="approx prompt tokens")
    ap.add_argument("--gen", type=int, default=256)
    ap.add_argument("--repeat", type=int, default=3)
    a = ap.parse_args()

    prompt = FILLER * max(1, a.ctx * 4 // len(FILLER))
    results = []
    for _ in range(a.repeat):
        t0, ttft, n = stream_chat(a.url, a.model, prompt, a.gen)
        total = time.time() - t0
        decode = (total - (ttft or 0)) or 1e-9
        row = {
            "type": "api_bench",
            "ttft_s": round(ttft or 0.0, 3),
            "decode_tps": round(n / decode, 2),
            "gen_tokens": n,
            "total_s": round(total, 2),
        }
        results.append(row)
        print(json.dumps(row), flush=True)

    ok = [r for r in results if r["gen_tokens"] > 0]
    if ok:
        ok.sort(key=lambda r: r["decode_tps"])
        med = ok[len(ok) // 2]
        print(
            json.dumps(
                {
                    "summary": {
                        "model": a.model,
                        "ctx_tokens": a.ctx,
                        "gen": a.gen,
                        "repeat": a.repeat,
                        "median_ttft_s": med["ttft_s"],
                        "median_decode_tps": med["decode_tps"],
                    }
                }
            )
        )


if __name__ == "__main__":
    main()
