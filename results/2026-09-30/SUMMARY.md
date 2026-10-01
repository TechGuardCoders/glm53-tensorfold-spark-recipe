# 2026-09-30: vLLM -> TensorFold, then + DFlash2

Rig: 2x DGX Spark (GB10, 128 GB unified), DGX OS 7, driver 580.173.02, QSFP CX7 link (RoCE), stock desktop OS
(no OS tuning). Engine: [glm53-tensorfold-spark](https://github.com/jayleaton/glm53-tensorfold-spark) @ `b463237`
(image b11, 77 patches), production config + [`config/prod.env.delta`](../../config/prod.env.delta). Weights: base
GLM-5.3-Flash EXL3 4-bit (not the abliterated checkpoint upstream measures on). Client: upstream's
`bench/glmbench.py`, suites `tf,tweet,kit,edit`, 3 reps (median), straight to the engine on 127.0.0.1:8001, nothing
else on the GPUs.

## Decode, single stream (tok/s, decode only)

| Cell | **B0** MTP drafts only | **B1** + DFlash2 | B1 vs B0 | upstream W20 (abliterated, DFlash2, OS-tuned) |
| --- | ---: | ---: | ---: | ---: |
| tf code, sampled T=1, 64 tok | 57.7 | 56.2 | -3% | 51.1 |
| tf chat, sampled T=1, 64 tok | 50.3 | 48.6 | -3% | 48.6 |
| tf code, greedy, 64 tok | 69.5 | **76.7** | **+10%** | 89.6 |
| tf chat, greedy, 64 tok | 55.6 | 53.0 | -5% | 51.6 |
| tweet sequence, greedy, 512 tok | 66.4 | **100.7** | **+52%** | 105.1 |
| tweet code, greedy, 512 tok | 59.7 | 61.1 | +2% | 75.9 |
| tweet json, greedy, 512 tok | 75.5 | **90.2** | **+19%** | 84.0 |
| kit hashmap (prose), greedy, 200 tok | 52.5 | 51.4 | -2% | 59.6 |
| kit structured, greedy, 200 tok | 83.0 | **108.5** | **+31%** | 112.3 |
| kit essay, greedy, 200 tok | 52.7 | 49.6 | -6% | 50.5 |
| edit rename, greedy, 1024 tok | 54.8 | **61.8** | **+13%** | 124.1 |
| edit comments, greedy, 1024 tok | 76.9 | **97.6** | **+27%** | 108.0 |
| edit print-to-log, greedy, 1024 tok | 118.3 | 121.7 | +3% | 126.5 |

Raw: [`B0-baseline-mtp.json`](B0-baseline-mtp.json), [`B1-dflash2.json`](B1-dflash2.json). Edit cells are one rep.

Reading it:
- DFlash2 pays on structured, sequential, JSON, code and edit output (+10% to +52%) and costs 2-6% on prose. That
  matches upstream's acceptance tables: DFlash2 is no better than MTP at draft position 1 on prose (0.68 vs 0.72) and
  wins through depth on code (4.39 vs 3.46 tokens a round) and agent text (5.76 vs 3.99). Agent and coding traffic is
  most of ours, so it stays on.
- Sampled (T=1) cells barely move: upstream's `auto` policy drafts sampled rounds with MTP.
- The gap to upstream's W20 on code / hashmap / edit-rename is not explained yet: different weights (base vs
  abliterated), no OS tuning here (upstream measured +4.8%), and 1-rep edit cells. Tracked in the roadmap.

## Startup canary (engine's own probe)

| | tokens a round | decode |
| --- | ---: | ---: |
| MTP only | 4.38-4.44 | 57.5-65.7 tok/s |
| + DFlash2 | 5.71 | 78.4 tok/s |

## The vLLM stack it replaced (same pair, same weights)

Entrpi's vLLM fork with DFlash2 k=7, `MAX_SEQS=4`, 524k context: 106-113 ms a step, 21-23 tok/s on our prose probe;
start to ready 8-10 min. TensorFold on the same probe: ~50-52 tok/s; restart ~1.5 min (first start ~10 min).

## Concurrency: 4 agent-like sessions

[`bench/soak4.py`](../../bench/soak4.py): 4 concurrent sessions, ~34.5k-token prompts (12k shared system prefix +
per-session context), 3 growing turns each, 400-token replies, T 0.6, `reasoning_effort` low.

| | ok | wall | MemAvailable min head / worker | Xid / engine errors / stalls |
| --- | ---: | ---: | --- | --- |
| MTP only ([txt](soak4-mtp.txt)) | 12/12 | 141 s | 19.1 GiB / (not sampled) | 0 / 0 / 0 |
| + DFlash2 ([txt](soak4-dflash2.txt)) | 12/12 | 141 s | 16.3 GiB / 17.4 GiB | 0 / 0 / 0 |

Follow-up turns reuse 34,496 of ~34,700 prompt tokens (session cache + shared-prefix reuse) and answer in 8-20 s.
The wall time is dominated by four cold ~34.5k prefills arriving at once. The vLLM stack this replaced died twice
(GPU Xid 31) under similar multi-agent load.
