"""4 concurrent agent-like sessions against the GLM endpoint on the head (via the :8000 proxy).
Shared ~12K-token system prefix + per-bot ~12K unique context, 3 growing turns each. Samples MemAvailable on both
nodes. Run on the head: GLM_KEY=... WORKER=<ssh alias> python3 soak4.py  (the key is never printed)."""
import json, subprocess, threading, time, urllib.request, os

BASE = "http://127.0.0.1:8000"
KEY = os.environ["GLM_KEY"]
WORKER = os.environ.get("WORKER", "worker")
SYS = "You are an operations agent for an MSP. " + " ".join(
    f"Policy {i}: tickets for client site {i % 37} escalate after {i % 9 + 1} hours unless the asset is tagged tier-{i % 4}." for i in range(700))
mem = {"head": [], "worker": []}
stop = False
results = []


def memav(node):
    cmd = ["awk", "/MemAvailable/{print int($2/1024)}", "/proc/meminfo"]
    if node == "worker":  # one remote string, quoted for the remote shell
        cmd = ["ssh", "-o", "BatchMode=yes", WORKER, "awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo"]
    try:
        return int(subprocess.run(cmd, capture_output=True, text=True, timeout=10).stdout.strip())
    except Exception:
        return None


def sampler():
    while not stop:
        for n in mem:
            v = memav(n)
            if v:
                mem[n].append(v)
        time.sleep(2)


def bot(i):
    ctx = " ".join(f"Bot {i} log line {j}: host srv-{i}-{j % 50} reported disk {j % 97}% and {j % 13} failed logins." for j in range(650))
    msgs = [{"role": "system", "content": SYS}, {"role": "user", "content": ctx + "\n\nSummarize the three worst hosts and why."}]
    for turn in range(3):
        body = {"model": "glm-5.3-flash", "max_tokens": 400, "temperature": 0.6, "reasoning_effort": "low", "messages": msgs}
        t = time.time()
        try:
            r = urllib.request.urlopen(urllib.request.Request(
                BASE + "/v1/chat/completions", json.dumps(body).encode(),
                {"Content-Type": "application/json", "Authorization": f"Bearer {KEY}"}), timeout=900)
            d = json.loads(r.read())
            u = d["usage"]; el = time.time() - t
            results.append((i, turn, "ok", u["prompt_tokens"], u.get("prompt_tokens_details", {}).get("cached_tokens", 0),
                            u["completion_tokens"], round(el, 1)))
            msgs += [{"role": "assistant", "content": d["choices"][0]["message"].get("content") or "ok"},
                     {"role": "user", "content": f"Turn {turn + 2}: now list remediation steps for host srv-{i}-{turn * 7}."}]
        except Exception as e:
            results.append((i, turn, f"ERROR {e}", 0, 0, 0, round(time.time() - t, 1)))
            return


s = threading.Thread(target=sampler, daemon=True); s.start()
t0 = time.time()
ths = [threading.Thread(target=bot, args=(i,)) for i in range(4)]
[t.start() for t in ths]; [t.join() for t in ths]
stop = True; wall = time.time() - t0
for r in sorted(results):
    print("bot %d turn %d %-6s prompt=%6d cached=%6d completion=%4d %6.1fs" % r)
ok = [r for r in results if r[2] == "ok"]
print(f"requests ok {len(ok)}/12  errors {12 - len(ok)}  wall {wall:.0f}s  completion tokens {sum(r[5] for r in ok)}"
      f"  aggregate {sum(r[5] for r in ok) / wall:.1f} tok/s (incl. prefill)")
for n, v in mem.items():
    print(f"MemAvailable {n}: min {min(v) if v else '?'} MiB, max {max(v) if v else '?'} MiB ({len(v)} samples)")
