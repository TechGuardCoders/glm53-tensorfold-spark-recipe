"""The fleet agent's baseline method: non-streaming, usage.completion_tokens / wall time, 256-token cap, median of 3,
for code / prose / structured / edit. Usage: GLM_KEY=... python3 agent_method.py [base_url] [extra_json]
Default base: http://127.0.0.1:8000 (the key proxy). extra_json is merged into every request body."""
import json, os, statistics, sys, time, urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000"
EXTRA = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
KEY = os.environ.get("GLM_KEY", "")
src = "\n".join(f"def handler_{i}(req, cfg):\n    data = req.get(\"payload\", {{}})\n    if not data:\n        return {{\"error\": \"empty\", \"code\": {400+i}}}\n    total = sum(int(v) for v in data.values())\n    return {{\"ok\": True, \"total\": total, \"cfg\": cfg.name}}\n" for i in range(8))
PROMPTS = {
    "code": "Write a Python function that parses ISO 8601 durations like P3DT4H5M into seconds, with input validation.",
    "prose": "Write a 300-word essay on why small businesses should take cybersecurity seriously.",
    "structured": "Return only a JSON array of 20 fictional employees with fields id, name, department, email, start_date.",
    "edit": "Rename the parameter cfg to config everywhere in this file and return the complete file only:\n\n" + src,
}


def one(prompt):
    body = {"model": "glm-5.3-flash", "max_tokens": 256, "reasoning_effort": "none",
            "messages": [{"role": "user", "content": prompt}], **EXTRA}
    h = {"Content-Type": "application/json", **({"Authorization": "Bearer " + KEY} if KEY else {})}
    t = time.time()
    r = json.load(urllib.request.urlopen(urllib.request.Request(BASE + "/v1/chat/completions", json.dumps(body).encode(), h), timeout=300))
    return r["usage"]["completion_tokens"] / (time.time() - t)


for kind, prompt in PROMPTS.items():
    v = [one(prompt) for _ in range(3)]
    print("%-10s %6.1f tok/s  (reps %s)" % (kind, statistics.median(v), ", ".join("%.1f" % x for x in v)), flush=True)
