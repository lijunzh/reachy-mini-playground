#!/usr/bin/env python3
"""Benchmark an OpenAI-compatible server on the turns Reachy actually does.

  ./reachy_mini_env/bin/python bench-llm.py <label> <base_url> <model> [--chat]

Examples:
  bench-llm.py "LM Studio" http://127.0.0.1:1234/v1 qwen/qwen3-coder-next --chat
  bench-llm.py "omlx"      http://127.0.0.1:8123/v1 Qwen3-Coder-Next-MLX-4bit --chat

Run each twice: the first turn includes model load. Compare the warm numbers.

--chat uses /v1/chat/completions (omlx); default uses /v1/responses (LM Studio).
"""
import json, sys, time, urllib.request

PROMPTS = [
    "Hey Reachy, introduce yourself in one sentence.",
    "What is the weather like today and what should I wear?",
    "Tell me a very short joke.",
]
SYSTEM = ("You are Reachy Mini, a small friendly desk robot. "
          "Reply conversationally in 1-3 short spoken sentences.")

def post(url, payload, timeout=300):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer x"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)

def run(label, base, model, chat):
    print(f"\n=== {label}  ({model}) ===")
    tot_t = tot_out = tot_reason = 0
    for p in PROMPTS:
        if chat:
            url, payload = base + "/chat/completions", {
                "model": model,
                "messages": [{"role": "system", "content": SYSTEM},
                             {"role": "user", "content": p}],
                "max_tokens": 256, "temperature": 0.7,
                "extra_body": {"reasoning_effort": "none"}}
        else:
            url, payload = base + "/responses", {
                "model": model, "instructions": SYSTEM, "input": p,
                "max_output_tokens": 256,
                "chat_template_kwargs": {"enable_thinking": False}}
        t0 = time.time()
        try:
            d = post(url, payload)
        except Exception as e:
            print(f"  FAIL {type(e).__name__}: {str(e)[:90]}")
            continue
        el = time.time() - t0
        u = d.get("usage", {}) or {}
        out = u.get("output_tokens") or u.get("completion_tokens") or 0
        det = u.get("output_tokens_details") or u.get("completion_tokens_details") or {}
        rsn = det.get("reasoning_tokens") or 0
        spoken = ""
        if chat:
            spoken = (d["choices"][0]["message"].get("content") or "")
        else:
            for o in d.get("output", []):
                if o.get("type") == "message":
                    c = o.get("content") or [{}]
                    spoken = str(c[0].get("text", ""))
        tot_t += el; tot_out += out; tot_reason += rsn
        print(f"  {el:6.1f}s  out={out:4d} reason={rsn:4d}  {spoken[:58]!r}")
    if tot_t:
        print(f"  ---- avg {tot_t/len(PROMPTS):.1f}s/turn | {tot_out/tot_t:.1f} tok/s "
              f"| {100*tot_reason/tot_out if tot_out else 0:.0f}% reasoning")

if __name__ == "__main__":
    a = sys.argv[1:]
    chat = "--chat" in a
    a = [x for x in a if x != "--chat"]
    run(a[0], a[1].rstrip("/"), a[2], chat)
