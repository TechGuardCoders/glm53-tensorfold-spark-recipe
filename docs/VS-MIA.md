# This recipe vs MiaAI's

[MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold)
is the other TensorFold recipe for GLM-5.3-Flash on two Sparks, and it is very good. On 2026-10-01 we moved our
production cluster to it (v1.3.1, TensorFold v0.6.0, image `v0.6.0-ae8d1c789b47`), measured everything we measure,
and moved back the same night. This page shows why, so you can tell which one fits your workload.

**Short version:** Mia's recipe has more throughput, so it suits busy, parallel and single-conversation traffic. This
recipe gets back to a long conversation instantly after the server has served another one, so it suits a fleet of
agents that take turns on one server. Agents that take turns are our traffic, so we run this one.

## Same rig, same weights, same clients

Both ran on the same two Sparks (stock DGX OS, QSFP CX7 link) with the same base GLM-5.3-Flash TR3 4-bit EXL3 weights.
Mia's `Mia-AiLab/GLM-5.3-Flash-EXL3-TR3-4bpw` is a byte-identical mirror of `brandonmusic/GLM-5.3-Flash-tr3-4bpw`; we
checked every file's SHA-256. Both used the DFlash2 drafter. Mia ran at its own defaults; the only local settings were
the worker address, port, served model name and `MEMORY_RESERVE_GIB=18`. The clients were the same unmodified
`bench/` scripts from jayleaton/glm53-tensorfold-spark plus our agent-method script, run straight against the engine.
Raw data: [`results/2026-10-01-vs-mia`](../results/2026-10-01-vs-mia).

## Results

| | **This recipe** (glm53-tensorfold-spark, TensorFold 0.3.4) | **MiaAI v1.3.1** (TensorFold 0.6.0) | |
| --- | ---: | ---: | --- |
| **Return to a conversation after another one, 7k tokens** | **0.36-0.44 s** | 3.0 s | ours 7-8x |
| **Same, 21k tokens** | **0.46-0.50 s** | 10.4 s | ours 21x |
| **Same, 37-39k tokens** | **0.44-0.46 s** | 19.6 s | ours 43x |
| Next turn of the conversation just served, 37-39k | 1.93 s | **1.76 s** | ≈ |
| 4 requests at once, aggregate | 79-89 tok/s | **95-103 tok/s** | Mia +15-19% |
| One request, agent method: code / prose / structured / edit | 59.9 / 45.8 / 81.1 / 80.9 | **65.8 / 47.6 / 80.0 / 88.8** | Mia ≈ +10% on code, edits |
| Same, with the client sending `temperature: 1` | 52.4 / 47.5 / 65.3 / 73.7 | **65.9 / 47.3 / 79.6 / 88.6** | Mia +20-26% (prose same) |
| glmbench greedy: code / structured / hashmap / essay | 76.9 / 108.3 / 51.4 / 49.5 | **87.1 / 115.1 / 56.8 / 52.4** | Mia +6-13% |
| glmbench code at T=1 (64 tokens) | **56.8** | 45.3 | ours +25% |
| Edit cells: rename / comments / print-to-log | **62.6** / 99.7 / 122.3 | 55.8 / **114.7 / 126.0** | mixed |
| Cold prompt, TTFT at 1.8k / 7k / 28k / 86k tokens | **1.47 / 4.24** / 16.06 / 50.33 s | 1.71 / 5.30 / **14.22 / 44.62** s | ours short, Mia long |
| Tool calls, opencode harness (21 cases x 5, T=0) | **105/105**, 0 corrupted | 95/105, 0 corrupted | see below |
| MMLU-200 | 89.0% | 88.5% | same (1 question) |
| Drafted == serial; batched == alone | 10/10; 4/4 | 10/10; 4/4 | same |
| 4 x 250k-token conversations, lowest free memory | **14.7 / 15.7 GiB** | 11.1 / 12.4 GiB | both pass |

The "return to a conversation" rows come from `multiturn.py --modes sessions`. Three conversations (A, B, C) share a
2,000-token system prompt and take turns A, B, A, C, B, A. The rows show the revisits. On this recipe a revisit reuses
the conversation's whole cached prompt state. On Mia it reuses only the shared 1,984-token system prompt and re-reads
everything else, every time:

```text
              turn:  A(cold)  B(cold)  A       C(cold)  B       A
this recipe   7k     4.33 s   4.70 s   0.36 s  3.45 s   0.38 s  0.44 s   (cached 6,784 of 6,873 on revisits)
Mia v1.3.1    7k     4.08 s   3.00 s   3.03 s  2.97 s   3.00 s  3.04 s   (cached 1,984 on every turn)
this recipe   21k    12.43 s  12.79 s  0.46 s  11.80 s  0.46 s  0.50 s
Mia v1.3.1    21k    11.72 s  10.47 s  10.44 s 10.39 s  10.53 s 10.43 s
```

Mia's v1.3.1 changelog fixes a related problem: `TF_GLM_MULTI_LONE` now defaults to 0, and they measured 98.1% of
prompts coming from cache with three conversations taking turns. We ran v1.3.1 with `TF_GLM_MULTI_LONE=0`, and the
cache pool had plenty of room (2.2M tokens, 8 kept prompts). We have not isolated the cause. Our guess is the
shared-system-prompt path (`SHARED_PREFIX=1`, their patch 0015): every conversation in our test, like every bot in our
fleet, shares a system prompt, and the reuse stops exactly at it. If your conversations have different system
prompts, you may not see this at all. Test it.

About the tool-call row: Mia's 10 misses are two cases (`edit_file`, `multi_turn_chain`) failing the same way in all 5
reps. The model called `read` on the file first instead of editing it straight away. That is a reasonable agent move
that this harness counts as a miss, and no call was malformed.

## Which one to run

**Run Mia's recipe if** your traffic is mostly:
- several people or agents generating **at the same time** (+15-19% aggregate);
- clients that **sample** (`temperature` 0.7-1). Mia's agent-method numbers at T=1 equal its T=0 ones (its 64-token
  glmbench code cell at T=1 is lower, so check your own prompts). This recipe drafts only at greedy, which is why it
  ships `--temperature=0` as the server default;
- **one long document at a time** (11% faster cold prefill at 28k-86k tokens);
- one conversation at a time, or conversations that never come back.

**Run this recipe if** your traffic is mostly:
- **many agents or chats taking turns on one server**, each going back to a long history: Teams/Slack bots, cron
  agents, a coding agent and its sub-agents. Every revisit here starts in under half a second instead of re-reading
  the history (3 s at 7k, 10 s at 21k, 20 s at 37k);
- a fleet whose bots share a system prompt;
- memory headroom for other work on the Sparks (3.6 GiB more free at 4 x 250k).

Our fleet is the second case. Hermes bots on Teams, cron agents and a mechanic agent interleave all day, so a 10-20
second pause on most turns outweighs +15-19% at four streams.

## Test it on your own traffic

The question is how often your traffic goes back to a conversation after serving another one. Run the same test on
either engine, straight to its port:

```bash
git clone https://github.com/jayleaton/glm53-tensorfold-spark && cd glm53-tensorfold-spark
python3 bench/multiturn.py --base http://127.0.0.1:8001 --model glm-5.3-flash --modes sessions --doc 15000 --out s15k.json
python3 bench/multiturn.py --base http://127.0.0.1:8001 --model glm-5.3-flash --modes concurrent --streams 4 --out c4.json
```

Or watch production: both engines' `/health` reports `prompt_tokens_total` and `cached_tokens_total`. A low cached
share while agents are busy means your traffic is paying the re-read.

Both recipes serve the same API (`/v1/chat/completions`, model id of your choice). The one visible difference: Mia
returns the reasoning text only as `reasoning_content`, while this recipe also sends `reasoning`. If you switch
between them, keep both installed and use a selector, as we do: a switch is one restart (about 1.5 min onto this
recipe, 2-5 min onto Mia).

## Credit

MiaAI-Lab's recipe is careful, well-documented work, and several of its patches are adapted from jayleaton's, as
their config says. We will retest when the revisit cache behaves the same way there, and update this page.
