# 2026-10-24: upstream b463237 -> dd5df45

Rig: same pair as 09-30 / 10-01 (2x DGX Spark, GB10, QSFP CX7 link, stock DGX OS). Engine:
[glm53-tensorfold-spark](https://github.com/jayleaton/glm53-tensorfold-spark) @ `dd5df45` (81 patches, same
TensorFold v0.3.4 submodule), production config + [`config/prod.env.delta`](../../config/prod.env.delta) unchanged
(DFlash2, `--temperature=0`). Same weights (base GLM-5.3-Flash EXL3 4-bit, ShapleyMcg TR3 @ `a5fee92`), same drafter
(incoai DFlash2 @ `7d74cdd`), same prepared weights. Clients: upstream's `bench/` scripts, unmodified, against the
engine on 127.0.0.1:8001. Our production cluster has served from this build since 2026-10-24 22:38 EDT.

## Why we moved

Our "the endpoint stops answering" incidents since mid-October were the head's earlyoom killing TensorFold rank 0:
another service we had added to the head (since removed) plus slow host-RSS growth in rank 0 (10.6-12.8 GB when killed)
pushed MemAvailable under earlyoom's floor. dd5df45 brings the two upstream fixes for that growth:
`MALLOC_ARENA_MAX=4` set by `serve.sh` in both containers, and patch 0670 (a smaller in-RAM index for the NVMe session
tier). It also brings 0690, 0630 and 0660; see [`docs/HOW-IT-WORKS.md`](../../docs/HOW-IT-WORKS.md#upstream-dd5df45).

## Gate 2 on dd5df45

| Check | Client and arguments | Result | Raw |
| --- | --- | --- | --- |
| tool calling | `toolcall_harness --toolset opencode --stream --reps 5 --temperature 0` | **105/105 clean, 0 corrupted** | [txt](toolcall-dd5df45-20261024.txt), [json](toolcall-dd5df45-20261024.json) |
| exactness | `glmbench --suites exact` | drafted == serial **10/10** (drafted 44.6-91.3 tok/s, serial ~36) | [json](tf-dd5df45-roce-20261024.json) (`exact`) |
| batch exactness | `multiturn --modes batchexact` | batched == alone **4/4** | [txt](multiturn-dd5df45-roce-20261024.txt), [json](multiturn-dd5df45-roce-20261024.json) |
| 4 streams | `multiturn --modes concurrent --streams 4` (2 reps) | **85.1 / 78.0 tok/s** aggregate, TTFT 0.47-0.55 s a stream | same |
| revisited sessions | `multiturn --modes sessions` (three ~39k-token conversations, A B A C B A) | revisits **0.40-0.53 s** TTFT (cold 24.9-27.2 s) | same |

The tool-calling run was taken before the RoCE marker below was cleared (NCCL transport; a data move, same bits). The
glmbench and multiturn files are on RoCE. On NCCL the same multiturn run gave 85.5 / 80.2 tok/s and 0.41-0.49 s.

## Decode, single stream, on RoCE

`glmbench --suites tf,tweet,kit,exact --reps 3`, tok/s, decode only, median of 3. The 09-30 column is
[`B1-dflash2.json`](../2026-09-30/B1-dflash2.json) (b463237, same config). Edit cells were not re-run.

| Cell | 09-30, b463237 | **10-24, dd5df45** | change |
| --- | ---: | ---: | ---: |
| tf code, sampled T=1, 64 tok | 56.2 | 53.8 | -4.2% |
| tf chat, sampled T=1, 64 tok | 48.6 | 46.9 | -3.5% |
| tf code, greedy, 64 tok | 76.7 | **71.1** | -7.4% |
| tf chat, greedy, 64 tok | 53.0 | 50.4 | -4.8% |
| tweet sequence, greedy, 512 tok | 100.7 | **91.4** | -9.3% |
| tweet code, greedy, 512 tok | 61.1 | 59.1 | -3.3% |
| tweet json, greedy, 512 tok | 90.2 | **81.8** | -9.4% |
| kit hashmap (prose), greedy, 200 tok | 51.4 | **48.7** | -5.3% |
| kit structured, greedy, 200 tok | 108.5 | **98.2** | -9.5% |
| kit essay, greedy, 200 tok | 49.6 | **48.3** | -2.6% |

Raw: [`tf-dd5df45-roce-20261024.json`](tf-dd5df45-roce-20261024.json).

## Why it is 2.5-9.5% under 09-30 (and why that is not dd5df45)

- **Same outputs, same drafts.** Every cell's 3 replies have the same sha256 as on 09-30, and the engine's request log
  shows the same requests taking the same rounds at the same tokens a round. Only the milliseconds a round grew.
- **Both GPUs, equally.** An nsys profile of both ranks: GPU busy 96.8% of a round, head and worker kernel time equal
  (ratio 0.997), no rank skew. The engine's own re-measured calibration has verify +5.7-8.3% and the drafter block +33%
  over its 09-30 values, so this is GPU kernel time, not the host, the link or the scheduler.
- **Ruled out:** the image and code (the b463237 image is just as slow today), the config, driver / kernel / firmware,
  CPU, GPU clocks, power and thermals (2.5 GHz, ~55 W, every throttle counter unchanged during decode), GPU memory
  bandwidth (241 / 243 GB/s), the CX7 link, host memory fragmentation (compaction + restart: no change).
- **Today matches upstream's own reference.** Prose rounds take 52.8 ms and the routed experts 27.9 ms a round, against
  upstream's published 53.3 / 27.8 ms. Our 09-30 / 10-01 numbers were the outlier: both GPUs ran ~8% faster then, and we
  have not found why. The one reset not tried yet is a cold power-cycle of both Sparks.

So the front page now quotes today's numbers, which are what a fresh install should expect. The 09-30 / 10-01 runs stay
in [`results/`](..) as measured.

## RoCE was off for 11 days, silently

Patch 0230 leaves a marker (`GLM53_TF_ROCE_MARK`, default `/cache/roce-failed`, in the `glm53-tf-cache` Docker volume)
when a RoCE exchange times out, so the next start uses NCCL. When earlyoom killed rank 0 mid-exchange on 10-13, the
worker's rank 1 timed out and wrote that marker; every start after that used NCCL with nothing but a boot-log line to
say so. Clearing it (we renamed it, to keep the evidence) brought RoCE back: +2-3% on decode. Check for it after any
kill: [operator tips](../../docs/HOW-IT-WORKS.md#operator-tips).
