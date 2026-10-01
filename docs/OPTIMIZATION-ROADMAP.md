# Optimization roadmap

Where more tokens a second can still come from on this build, ranked by expected gain for **agent and coding
traffic** (what we serve) against effort and risk. Every step is gated by an A/B with upstream's `bench/glmbench.py`
(13 cells, 3 reps) plus [`bench/soak4.py`](../bench/soak4.py), and must keep replies exact where upstream's patches
promise exactness (`glmbench --suites exact`).

Decode on this engine is `tok/s = tokens a round / ms a round`. Every idea below moves one of the two.

Status: **done** = measured and live; **next** = queued; **research** = needs building; **declined** = decided against.

## Done

| # | Change | Lever | Measured |
| --- | --- | --- | --- |
| D1 | vLLM fork -> TensorFold (upstream production config) | both | ~2.3x on prose (21-23 -> ~50 tok/s), restart 8-10 min -> ~1.5 min |
| D2 | DFlash2 drafter on (`DRAFTER=`) | tokens a round | +10% to +52% on code / structured / JSON / edits, -2% to -6% on prose ([results](../results/2026-09-30/SUMMARY.md)) |
| D3 | Server default `--temperature=0` (`EXTRA_ARGS`) | tokens a round | requests that send no temperature: 4.36 -> 5.73 tokens a round, ~68 -> ~83 tok/s (+20%). The model's default is 1.0 and TensorFold drafts DFlash2 only on greedy rounds, so agent frameworks that omit temperature never got DFlash2 ([README](../README.md#e-the-default-temperature-trap)) |

## Next: cheap, likely

| # | Idea | Lever | Expected | Notes |
| --- | --- | --- | --- | --- |
| N1 | ~~Clients send `reasoning_effort: low`~~ | - | **measured: no speed effect on this checkpoint** | GLM-5.3-Flash wrote ~130 characters of reasoning at `high` and none at `low`/`none` on an architecture prompt, same wall time within noise. The real client-side lever was temperature (D3). We still use `low` for agents: upstream's tool-calling runs scored best there. |
| N2 | **Stable system prompts** in agent frameworks | prefill skipped | TTFT, not tok/s | Shared-prefix reuse already gives 34.5k of 35k cached on follow-up turns; anything that injects timestamps or random IDs into the system prompt throws that away. Audit our agent frameworks. |
| N3 | **Explain the remaining gap to upstream W20** on code greedy (76.7 vs 89.6), hashmap (51.4 vs 59.6), edit-rename (61.8 vs 124.1) | both | unknown | Re-run edit cells with 3 reps; run the same cells on upstream's abliterated checkpoint to separate weights from host. If weights explain it, nothing to do; if not, find the host difference. |
| N4 | **Draft vocabulary from our own traffic** (patch 0420, `GLM53_TF_DRAFT_VOCAB`) | ms a round (drafter head) | +0.5-0.8% (upstream, from real agent traffic) | Needs a token-frequency list built from our replies; the request log stores no text, so build it client-side. |
| N5 | **Firmware parity** between the two nodes (one Spark is on an older BIOS) | ms a round | unknown, probably small | TP2 runs at the speed of the slower rank; measure per-rank round time first. |

## Research: the bigger levers

| # | Idea | Lever | Why it might work | Cost / risk |
| --- | --- | --- | --- | --- |
| R1 | **A drafter trained on our own agent transcripts** | tokens a round | Acceptance is workload-specific: DFlash2 keeps 5.76 tokens a round on agent text and 2.69 on prose. Agent traffic is repetitive in structure (tool-call JSON, file paths, code idioms); a drafter tuned on it should raise acceptance at depth. Upstream ships drafter-training records (patch 0430) and a training write-up (`docs/DRAFTER-TRAINING.md`). | GPU time to train. DFlash2's licence is CC BY-NC-ND, so a fine-tune of *it* cannot be shared; train from the base model's MTP head or from scratch instead. |
| R2 | **Tree / multi-branch drafts** in the 16-row verify window | tokens a round | Prose fails mostly at position 1 (p1 = 0.72). Verifying two candidate first tokens (MTP top-2) in one window turns many first-position misses into hits at the cost of rows the window already has (`GLM53_TF_MAX_DRAFT_ROWS=16`). | Engine change; must keep exactness (verify picks the target's token, drafts only propose). |
| R3 | **Upstream's decode-plan engineering items** (`docs/DECODE-PLAN.md`): expert-read bandwidth (205-214 of a 235 GB/s ceiling), dense q4 reads (175 of 230 GB/s), PDL launch overlap, vocab-trimmed head, RoCE exchange | ms a round | Upstream's own estimate for the remaining items: about +25% at 1 stream and 4 streams ("engineering mid") | Kernel work; best done with upstream, measured on two rigs instead of one. |
| R4 | **Per-request draft policy by content** (structured / code -> DFlash2 deep, prose -> MTP shallow) | tokens a round | Removes D2's 2-6% prose cost. Upstream's per-slot simulator showed -0.4% in batch, but a per-request choice keyed on `response_format` / tools / the first tokens of a reply is a different policy. | Engine change; small. |
| R5 | **Prompt-lookup over the repository**, not just the prompt (patch 0020 looks only at the current context) | tokens a round | Coding agents re-emit code that exists in the repo but not in the prompt. A suffix index over the workspace files, passed with the request, would feed the 16-row verify window with long correct runs (edit cells already reach 120+ tok/s when lookup hits). | New request field and index; client and engine work. |

## Declined

| # | Idea | Measured elsewhere | Why not |
| --- | --- | --- | --- |
| X1 | Headless OS + service trimming + IRQ pinning (upstream's former `OS-TUNING.md`) | +4.8% 1 stream, +4.3% 4 streams | Not worth losing the desktop and adding a reboot-and-recover procedure on these boxes for ~5%. |
| X2 | Server containers pinned to the X925 cores (`CPUSET`) | -1.5% at 4 streams | Slower. |
| X3 | FP8 prefill (patch 0083) | +7-11% prefill | Replies diverge from bf16 prefill on 25 of 30 prompts. |
