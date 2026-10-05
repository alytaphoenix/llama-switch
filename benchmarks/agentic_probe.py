#!/usr/bin/env python3
"""Agentic tool-calling smoke probe (OpenAI tools API).

Sends N "weather check" style requests with tool definitions and scores
whether the model emits a correct tool call (name + required arg present).
Non-streaming; one JSON line per trial, then a {"summary": {...}} line.

Usage: agentic_probe.py --url http://<box>:8731 --model <served-name> --repeat 8
"""
import argparse
import json
import time
import urllib.request

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "get_weather",
            "description": "Get current weather for a city",
            "parameters": {
                "type": "object",
                "properties": {
                    "city": {"type": "string", "description": "City name"},
                    "unit": {"type": "string", "enum": ["c", "f"]},
                },
                "required": ["city"],
            },
        },
    }
]

CITIES = ["Paris", "Reykjavik", "Osaka", "Cusco", "Wellington", "Tromso", "Valparaiso", "Fez"]


def trial(url: str, model: str, city: str):
    body = json.dumps(
        {
            "model": model,
            "stream": False,
            "max_tokens": 512,
            "temperature": 0,
            "messages": [
                {"role": "user", "content": f"Use the tool to check the weather in {city}."}
            ],
            "tools": TOOLS,
            "tool_choice": "auto",
        }
    ).encode()
    req = urllib.request.Request(
        url.rstrip("/") + "/v1/chat/completions",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=600) as r:
        obj = json.loads(r.read().decode())
    dt = time.time() - t0
    msg = obj["choices"][0].get("message", {})
    calls = msg.get("tool_calls") or []
    name_ok = arg_ok = False
    if calls:
        fn = calls[0].get("function", {})
        name_ok = fn.get("name") == "get_weather"
        try:
            args = json.loads(fn.get("arguments") or "{}")
            arg_ok = isinstance(args.get("city"), str) and city.lower() in args["city"].lower()
        except json.JSONDecodeError:
            arg_ok = False
    return {
        "type": "tool_call",
        "model": model,
        "city": city,
        "tool_called": bool(calls),
        "name_ok": name_ok,
        "args_ok": arg_ok,
        "latency_s": round(dt, 2),
        "refused": bool(msg.get("content")) and not calls,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--repeat", type=int, default=8)
    a = ap.parse_args()

    rows = []
    for i in range(a.repeat):
        city = CITIES[i % len(CITIES)]
        try:
            row = trial(a.url, a.model, city)
        except Exception as e:  # noqa: BLE001
            row = {"type": "tool_call", "model": a.model, "city": city, "error": str(e)[:200]}
        rows.append(row)
        print(json.dumps(row), flush=True)

    good = sum(1 for r in rows if r.get("name_ok") and r.get("args_ok"))
    print(
        json.dumps(
            {
                "summary": {
                    "model": a.model,
                    "tool_call_ok": f"{good}/{len(rows)}",
                }
            }
        )
    )


if __name__ == "__main__":
    main()
