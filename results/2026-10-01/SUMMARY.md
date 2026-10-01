# 2026-10-01: full eval set on the production recipe

Config: upstream production (`b463237`, image b11) + [`config/prod.env.delta`](../../config/prod.env.delta) including
DFlash2 and `--temperature=0`. Base GLM-5.3-Flash EXL3 4-bit (ShapleyMcg TR3, brandonmusic). Stock DGX OS. Clients:
upstream's `bench/` scripts, unmodified, against the engine on 127.0.0.1:8001. Light production traffic may have
overlapped some steps (it was after midnight; GLM showed 0-1 foreign requests when checked).

| Step | Client and arguments | Result | Raw |
| --- | --- | --- | --- |
| E1 exactness | `glmbench --suites exact` | drafted == serial **10/10**; drafted 44-103 tok/s vs serial ~36 | [txt](E1-exact.txt), [json](E1-exact.json) |
| E2 prefill / TTFT | `glmbench --suites ctx --ctx 2000,8000,32000,98000 --reps 2` | 1,213 / 1,660 / 1,747 / 1,705 tok/s at 1.8k / 7.0k / 28.0k / 85.8k; warm TTFT 0.10-0.26 s; decode behind them 91-105 tok/s | [txt](E2-ctx.txt), [json](E2-ctx.json) |
| E3 edit cells | `glmbench --suites edit --reps 3` | 62.6 / 99.7 / 122.3 tok/s (rename / comments / print-to-log) | [txt](E3-edit.txt), [json](E3-edit.json) |
| E4 concurrency, sessions | `multiturn --modes concurrent,batchexact,sessions,followup --streams 4 --reps 3` | 4 streams **80.0 / 86.2 / 80.7 tok/s** aggregate; batched == alone 4/4; revisited 39k sessions TTFT **0.44-0.46 s** (cold 23.6-24.5 s); follow-up 1.93 s (cold 22.73 s) | [txt](E4-multiturn.txt), [json](E4-multiturn.json) |
| E5 quality | `quality.py` | MMLU-200 **89.0%** (178/200); refusal probe 1/10 | [txt](E5-quality.txt), [json](E5-quality.json) |
| E6 tool calling | `toolcall_harness --toolset opencode --stream --reps 5 --temperature 0` | **105/105 passed, 0 corrupted** | [txt](E6-toolcall.txt), [json](E6-toolcall.json) |
| E7 memory stress | `multiturn --modes stress --stress-target 250000 --mem-hosts local,worker` | 4 conversations grown to ~250k tokens each (~1M in the shared KV pool), then 3 decoding while the 4th sends a 250k turn: **PASS**, MemAvailable minimum **14.69 GiB head / 15.70 GiB worker**; longest decode gap during the final prefill 3.6 s | [txt](E7-stress.txt), [json](E7-stress.json) |

Also on 10-01: the default-temperature A/B and the reasoning-effort A/B quoted in the
[README](../../README.md#e-the-default-temperature-trap) ([architect prompt](effort-ab-architect.txt),
[tool turn](effort-ab-toolturn.txt)).

For comparison, upstream's W20 4 x 250k stress minimum on its rig: 10.57 / 10.68 GiB (after host OS tuning).
