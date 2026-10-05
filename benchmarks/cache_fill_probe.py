#!/usr/bin/env python3
"""Cache-capacity fill probe: interleaved conversations + abort poisoning.

Reproduces the production waste pattern found in llama-swap.log (2026-10-02):
once the RAM snapshot store fills its byte budget, new full-prompt boundaries
(purpose=kRetry, max_priority 0) can never be admitted, families' fallback
chains go stale, and aborted-generation turns (client disconnect mid-stream,
history re-sent with a partial reply) fall back to FULL re-prefills.

N distinct conversations (distinct fillers -> distinct token families) are
interleaved turn-by-turn so they compete for the snapshot store, with an
abort injected into the first conversation. Reports per-turn TTFT + the
endpoint usage payload (cached_tokens is the hit/miss signal).

Usage:
  cache_fill_probe.py --url http://<box>:8731 --model <served-name> \
      --convos 7 --turns 4 --ctx 48000
"""
import argparse
import json
import time
import urllib.request

FILLERS = [
    "The observatory log records seeing conditions, filter wheel position, "
    "guide star drift, and the occasional satellite trail in terse nightly prose. ",
    "The greenhouse ledger tracks soil moisture, vent opening, fan speed, "
    "and the occasional pollinator visit in plain but careful notes. ",
    "The workshop journal notes tool temperature, coolant flow, spindle load, "
    "and the occasional power dip in steady mechanical detail. ",
    "The tide station diary logs wave height, wind bearing, mooring tension, "
    "and the occasional seal visit in unhurried watch-house style. ",
    "The bakery daybook records proof time, oven humidity, batch weight, "
    "and the occasional experiment in margin notes kept deliberately dull. ",
    "The rail depot log notes wagon count, brake pressure, platform clearances, "
    "and the occasional schedule slip in matter-of-fact dispatcher tone. ",
    "The apiary register lists hive weight, brood frames, flight traffic, "
    "and the occasional swarm warning in calm seasonal accounting. ",
    "The dive log records depth, bottom time, water temperature, "
    "and the occasional current shift in compact tabular prose. ",
]

QUESTIONS = [
    "Summarize the most recent entries in one sentence.",
    "Which value was out of range, and what does it suggest?",
    "Write the next two entries in the same style.",
    "What pattern do you see across the whole log?",
]


def history(conv: int, ctx_tokens: int):
    target = ctx_tokens * 4
    msgs = []
    total = 0
    i = 0
    filler = FILLERS[conv % len(FILLERS)]
    while total < target:
        user = filler * 8 + f" (entry {i} of log {conv})"
        asst = f"Logged. All readings nominal; archived log {conv} entry {i}."
        msgs.append({"role": "user", "content": user})
        msgs.append({"role": "assistant", "content": asst})
        total += len(user) + len(asst)
        i += 1
    return msgs


def stream_turn(url, model, msgs, gen, abort_after_chunks=None):
    body = json.dumps(
        {
            "model": model,
            "stream": True,
            "stream_options": {"include_usage": True},
            "max_tokens": gen,
            "temperature": 0,
            "messages": msgs,
        }
    ).encode()
    req = urllib.request.Request(
        url.rstrip("/") + "/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    t0 = time.time()
    ttft = None
    chunks = 0
    content = []
    usage = None
    aborted = False
    resp = urllib.request.urlopen(req, timeout=3600)
    try:
        for raw in resp:
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
            if obj.get("usage"):
                usage = obj["usage"]
            choices = obj.get("choices") or [{}]
            delta = (choices[0].get("delta") or {}) if choices[0] else {}
            piece = delta.get("content") or delta.get("reasoning_content") or ""
            if piece:
                if ttft is None:
                    ttft = time.time() - t0
                chunks += 1
                content.append(piece)
                if abort_after_chunks and chunks >= abort_after_chunks:
                    aborted = True
                    break
    finally:
        resp.close()
    return ttft, chunks, "".join(content), usage, aborted


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--convos", type=int, default=7)
    ap.add_argument("--turns", type=int, default=4)
    ap.add_argument("--ctx", type=int, default=48000)
    ap.add_argument("--gen", type=int, default=80)
    ap.add_argument("--abort-on", type=int, default=0, help="conversation index that gets an aborted turn (default 0)")
    ap.add_argument("--abort-at", type=int, default=2, help="turn number that gets aborted (default 2)")
    a = ap.parse_args()

    convs = {c: {"msgs": history(c, a.ctx), "aborted_once": False} for c in range(a.convos)}
    rows = []

    def run(c, turn, abort=False):
        msgs = convs[c]["msgs"]
        t0 = time.time()
        ttft, chunks, content, usage, aborted = stream_turn(
            a.url, a.model, msgs, a.gen, abort_after_chunks=6 if abort else None
        )
        total = time.time() - t0
        row = {
            "type": "cache_fill",
            "convo": c,
            "turn": turn,
            "aborted": aborted,
            "ttft_s": round(ttft or 0.0, 3),
            "total_s": round(total, 2),
            "prompt_tokens": (usage or {}).get("prompt_tokens"),
            "cached_tokens": (usage or {}).get("cached_tokens"),
            "completion_tokens": (usage or {}).get("completion_tokens"),
            "gen_chars": len(content),
        }
        rows.append(row)
        print(json.dumps(row), flush=True)
        if content and not aborted:
            convs[c]["msgs"] = msgs + [
                {"role": "assistant", "content": content},
                {"role": "user", "content": QUESTIONS[(turn - 1) % len(QUESTIONS)]},
            ]
        elif aborted and content:
            # client keeps the partial reply it managed to read
            convs[c]["msgs"] = msgs + [
                {"role": "assistant", "content": content},
                {"role": "user", "content": QUESTIONS[(turn - 1) % len(QUESTIONS)]},
            ]

    # interleave: all conversations take turn 1, then turn 2, ...
    for turn in range(1, a.turns + 1):
        for c in range(a.convos):
            abort = c == a.abort_on and turn == a.abort_at and not convs[c]["aborted_once"]
            run(c, turn, abort)

    # ---------------------------------------------------------------- summary
    def med(vals):
        vals = sorted(v for v in vals if v is not None)
        return round(vals[len(vals) // 2], 3) if vals else None

    follow = [r for r in rows if r["turn"] > 1]
    misses = [r for r in follow if not r["cached_tokens"]]
    summary = {
        "model": a.model,
        "convos": a.convos,
        "turns": a.turns,
        "ctx_est": a.ctx,
        "followup_turns": len(follow),
        "followup_misses": len(misses),
        "miss_turns": [
            {"convo": r["convo"], "turn": r["turn"], "ttft_s": r["ttft_s"], "prompt_tokens": r["prompt_tokens"]}
            for r in misses
        ],
        "median_followup_ttft_s": med([r["ttft_s"] for r in follow]),
        "miss_median_ttft_s": med([r["ttft_s"] for r in misses]),
        "wasted_prefill_tokens_est": sum(
            (r["prompt_tokens"] or 0) for r in misses
        ),
    }
    print(json.dumps({"summary": summary}))


if __name__ == "__main__":
    main()
