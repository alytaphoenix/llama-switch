#!/usr/bin/env python3
"""Concurrency probe (gufo/llama-swap compatible, OpenAI API).

Runs synchronized waves of N parallel requests: every session first prefills
the same prompt (max_tokens 1), a barrier waits for all preparations, then N
timed tg requests (default 128 tokens) run with prefix reuse. Reports
per-request decode rates and the aggregate (sum of individual rates), matching
gufo's documented multi-user methodology.

Usage: concurrency_probe.py --url URL --model M --concurrency 1,2,4,8 [--gen 128]
"""
import argparse
import json
import threading
import time
import urllib.request

FILLER = (
    "The expedition log records wind speed, panel temperature, coolant level, "
    "and the occasional aurora sighting in careful but unremarkable prose. "
)


def post(url, model, prompt, max_tokens, timeout=600):
    body = json.dumps({
        "model": model,
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": False,
        "messages": [{"role": "user", "content": prompt}],
    }).encode()
    req = urllib.request.Request(url.rstrip("/") + "/v1/chat/completions",
                                 data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--concurrency", default="1,2,4,8")
    ap.add_argument("--gen", type=int, default=128)
    ap.add_argument("--prompt-tokens", type=int, default=2048)
    a = ap.parse_args()

    prompt = FILLER * max(1, a.prompt_tokens * 4 // len(FILLER))
    prompt += "\n\nNow write one more sentence in the same style."
    results = []

    for n in [int(x) for x in a.concurrency.split(",")]:
        # phase 1: prefill every session (1 output token, prefix established)
        pre_barrier = threading.Barrier(n + 1)
        errors = []

        def prefill(i):
            try:
                post(a.url, a.model, prompt, 1)
            except Exception as e:  # noqa: BLE001
                errors.append(str(e)[:120])
            pre_barrier.wait()

        threads = [threading.Thread(target=prefill, args=(i,)) for i in range(n)]
        for t in threads:
            t.start()
        pre_barrier.wait()
        for t in threads:
            t.join()

        # phase 2: timed decode with prefix reuse
        barrier = threading.Barrier(n + 1)
        rates = []

        def decode(i):
            barrier.wait()
            t0 = time.time()
            try:
                r = post(a.url, a.model, prompt, a.gen)
                dt = time.time() - t0
                u = r.get("usage", {})
                toks = u.get("completion_tokens", 0)
                g = u.get("gufo", {})
                rates.append({
                    "i": i,
                    "tokens": toks,
                    "wall_s": round(dt, 2),
                    "decode_tps": g.get("decode_tps") or (round(toks / dt, 2) if dt else 0),
                })
            except Exception as e:  # noqa: BLE001
                rates.append({"i": i, "error": str(e)[:120]})
            barrier.wait()

        threads = [threading.Thread(target=decode, args=(i,)) for i in range(n)]
        for t in threads:
            t.start()
        barrier.wait()
        for t in threads:
            t.join()

        ok = [r for r in rates if r.get("tokens")]
        agg = sum(r["decode_tps"] for r in ok) if ok else 0.0
        row = {"type": "concurrency", "model": a.model, "users": n,
               "aggregate_decode_tps": round(agg, 2),
               "per_request": sorted(r["decode_tps"] for r in ok),
               "errors": errors or [r["error"] for r in rates if "error" in r]}
        results.append(row)
        print(json.dumps(row), flush=True)

    print(json.dumps({"summary": {"model": a.model,
                                   "aggregate": {str(r["users"]): r["aggregate_decode_tps"] for r in results}}}))


if __name__ == "__main__":
    main()
