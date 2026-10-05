#!/usr/bin/env python3
"""Needle-in-a-haystack retrieval probe (long-context accuracy).

Plants a unique passphrase at depth d of a filler haystack, asks the model to
recall it, and checks exact-substring hit. One JSON line per trial, then a
{"summary": {...}} line.

Usage:
  needle_probe.py --url http://<box>:8731 --model <served-name> \
                  --ctxs 16384,32768 --depths 0.25,0.5,0.75
"""
import argparse
import json
import random
import time
import urllib.request

FILLER = (
    "The maintenance log records wind speed, panel temperature, coolant level, "
    "and the occasional aurora sighting in careful but unremarkable prose. "
)


def haystack(tokens: int, depth: float, code: str) -> str:
    words = int(tokens * 4 / 7.5)  # ~7.5 chars/word incl. spaces
    n_sent = max(1, words // 22)
    sents = [FILLER] * n_sent
    idx = int(len(sents) * depth)
    idx = min(max(idx, 0), len(sents) - 1)
    sents.insert(idx, f"SYSTEM NOTE: the quarantine passphrase for the deep vault is {code}.")
    return " ".join(sents)


def ask(url: str, model: str, prompt: str) -> str:
    body = json.dumps(
        {
            "model": model,
            "stream": False,
            "max_tokens": 192,
            "temperature": 0,
            "messages": [
                {"role": "user", "content": prompt},
            ],
        }
    ).encode()
    req = urllib.request.Request(
        url.rstrip("/") + "/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=3600) as r:
        obj = json.loads(r.read().decode())
    msg = obj["choices"][0].get("message", {})
    return msg.get("content") or msg.get("reasoning_content") or ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--ctxs", default="16384,32768")
    ap.add_argument("--depths", default="0.25,0.5,0.75")
    a = ap.parse_args()

    rng = random.Random(20261001)
    trials = []
    for ctx in [int(x) for x in a.ctxs.split(",")]:
        for depth in [float(x) for x in a.depths.split(",")]:
            code = "".join(rng.choice("abcdefghjkmnpqrstuvwxyz23456789") for _ in range(10))
            text = haystack(ctx, depth, code)
            question = (
                text
                + "\n\nQuestion: What is the quarantine passphrase for the deep vault? "
                "Answer with only the passphrase."
            )
            t0 = time.time()
            try:
                answer = ask(a.url, a.model, question)
                hit = code in answer
                err = ""
            except Exception as e:  # noqa: BLE001
                answer, hit, err = "", False, str(e)[:200]
            row = {
                "type": "needle",
                "model": a.model,
                "ctx_tokens": ctx,
                "depth": depth,
                "hit": hit,
                "expected": code,
                "answer": answer[:80],
                "latency_s": round(time.time() - t0, 2),
            }
            if err:
                row["error"] = err
            trials.append(row)
            print(json.dumps(row), flush=True)

    by_ctx = {}
    for t in trials:
        c = by_ctx.setdefault(t["ctx_tokens"], [0, 0])
        c[1] += 1
        c[0] += 1 if t["hit"] else 0
    summary = {
        "model": a.model,
        "retrieval": {str(k): f"{v[0]}/{v[1]}" for k, v in sorted(by_ctx.items())},
    }
    print(json.dumps({"summary": summary}))


if __name__ == "__main__":
    main()
