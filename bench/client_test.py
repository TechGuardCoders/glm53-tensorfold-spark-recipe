"""Client-side acceptance test for an OpenAI-compatible GLM endpoint (any engine): auth, chat, reasoning fields,
streaming, tool calls.  GLM_BASE=http://<host>:8000 GLM_KEY=... python3 client_test.py   (the key is never printed)"""
import json, os, sys, time, urllib.request, urllib.error

BASE = os.environ.get("GLM_BASE", "http://127.0.0.1:8000")
KEY = os.environ["GLM_KEY"]
MODEL = "glm-5.3-flash"
ok = True


def req(path, body=None, key=KEY, timeout=300, stream=False):
    h = {"Content-Type": "application/json"}
    if key:
        h["Authorization"] = f"Bearer {key}"
    r = urllib.request.Request(BASE + path, json.dumps(body).encode() if body else None, h)
    try:
        resp = urllib.request.urlopen(r, timeout=timeout)
        return resp.status, (resp if stream else json.loads(resp.read() or b"{}"))
    except urllib.error.HTTPError as e:
        return e.code, None


def check(name, cond, detail=""):
    global ok
    ok &= bool(cond)
    print(f"{'PASS' if cond else 'FAIL'}  {name}  {detail}")


# 1. auth
check("unkeyed /v1/models -> 401", req("/v1/models", key=None)[0] == 401)
check("wrong key -> 401", req("/v1/models", key="not-the-key")[0] == 401)
code, m = req("/v1/models")
ids = [d["id"] for d in (m or {}).get("data", [])]
check("keyed /v1/models -> 200, model glm-5.3-flash", code == 200 and MODEL in ids, f"ids={ids} ctx={(m or {}).get('data', [{}])[0].get('context_length')}")

# 2. plain chat, thinking at low effort
t = time.time()
code, r = req("/v1/chat/completions", {"model": MODEL, "max_tokens": 600, "temperature": 0, "reasoning_effort": "low",
                                       "messages": [{"role": "user", "content": "What is 17*23? Answer with just the number."}]})
msg = (r or {}).get("choices", [{}])[0].get("message", {})
check("chat 200 + correct answer", code == 200 and "391" in (msg.get("content") or ""),
      f"{time.time()-t:.1f}s content={msg.get('content')!r} finish={(r or {}).get('choices',[{}])[0].get('finish_reason')}")
check("reasoning in both fields (reasoning + reasoning_content)",
      bool(msg.get("reasoning")) and bool(msg.get("reasoning_content")),
      f"keys={sorted(k for k in msg if msg[k])} usage={(r or {}).get('usage')}")

# 3. streaming
t = time.time()
code, resp = req("/v1/chat/completions", {"model": MODEL, "max_tokens": 200, "stream": True, "reasoning_effort": "none",
                                          "messages": [{"role": "user", "content": "Count from 1 to 30, comma separated."}]}, stream=True)
chunks, first, done, text = 0, None, False, ""
if code == 200:
    for raw in resp:
        line = raw.decode().strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            done = True
            break
        chunks += 1
        first = first or time.time() - t
        d = json.loads(data)["choices"][0].get("delta", {})
        text += d.get("content") or ""
check("streaming SSE: many chunks, [DONE]", code == 200 and chunks > 5 and done,
      f"chunks={chunks} first_chunk={first and round(first, 2)}s total={time.time()-t:.1f}s text={text[:60]!r}")

# 4. tool call
tools = [{"type": "function", "function": {"name": "get_weather", "description": "Get current weather for a city",
          "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]
code, r = req("/v1/chat/completions", {"model": MODEL, "max_tokens": 800, "temperature": 0, "tools": tools, "reasoning_effort": "low",
                                       "messages": [{"role": "user", "content": "What's the weather in Paris right now?"}]})
ch = (r or {}).get("choices", [{}])[0]
tc = ch.get("message", {}).get("tool_calls") or []
args = None
try:
    args = json.loads(tc[0]["function"]["arguments"]) if tc else None
except Exception:
    pass
check("tool call get_weather(city=Paris), finish tool_calls",
      code == 200 and ch.get("finish_reason") == "tool_calls" and tc and tc[0]["function"]["name"] == "get_weather"
      and args and "paris" in args.get("city", "").lower(), f"finish={ch.get('finish_reason')} calls={[(c['function']['name'], c['function']['arguments']) for c in tc]}")

print("ALL PASS" if ok else "SOME FAILED")
sys.exit(0 if ok else 1)
