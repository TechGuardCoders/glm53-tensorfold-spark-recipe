# GLM-5.3-Flash on 2x DGX Spark: the Tech Guard TensorFold + DFlash2 recipe

How we serve GLM-5.3-Flash on two NVIDIA DGX Sparks to a small team of developers and coding agents, on top of
[jayleaton/glm53-tensorfold-spark](https://github.com/jayleaton/glm53-tensorfold-spark) (the
[TensorFold](https://github.com/ashhart/TensorFold) engine plus 77 patches). This repo is the delta: what we changed,
why, every number we measured, and where the next speed comes from.

Weights: [ShapleyMcg](https://github.com/brandonmmusic-max/shapleymcg) by Brandon M. Music ([brandonmusic/GLM-5.3-Flash-tr3-4bpw](https://huggingface.co/brandonmusic/GLM-5.3-Flash-tr3-4bpw)); full attribution notice under [Licensing](#licensing).

## Results at a glance

Two DGX Sparks (GB10, 128 GB unified each), QSFP CX7 link, stock DGX OS desktop install (no OS tuning), base
GLM-5.3-Flash EXL3 4-bit weights. Measured 2026-09-30 / 10-01 with upstream's own benchmark clients.

| | Before (vLLM fork, DFlash2) | **This recipe** |
| --- | ---: | ---: |
| Single-stream decode, prose | 21-23 tok/s | **49-53 tok/s** |
| Single-stream decode, structured / sequence / JSON | not measured | **90-109 tok/s** |
| Agent file edits (1024-token rewrites) | not measured | **62-122 tok/s** |
| 4 concurrent streams, aggregate | - | **80-86 tok/s** |
| Prefill, 7k-86k tokens | 1,000-1,500 tok/s | **1,660-1,750 tok/s** |
| Time to first token, revisited 39k-token session | - | **0.44 s** (cold: 24 s) |
| Tool calls, opencode harness (21 cases x 5, streamed) | - | **105/105 clean, 0 corrupted** |
| MMLU-200 | - | **89.0%** |
| Drafted == serial (exactness) | - | **10/10**, batched == alone **4/4** |
| 4 x 250k-token conversations at once (memory floor) | - | **PASS, 14.7 / 15.7 GiB free** |
| Restart to serving | 8-10 min | **~1.5 min** |
| Multi-agent load that crashed the old stack (GPU Xid 31) | crashed twice | **12/12 clean** |

## What we changed from upstream's production config

All of it is in [`config/prod.env.delta`](config/prod.env.delta). Upstream's production config otherwise unchanged
(image b11 at `b463237`).

| Change | Why | Effect |
| --- | --- | --- |
| **DFlash2 drafter on** (`DRAFTER=`) | Our traffic is mostly code, JSON and tool calls, where DFlash2 drafts deep | +10% to +52% on structured / code / JSON / edit cells, -2% to -6% on prose ([table](#a-decode-single-stream)) |
| **`EXTRA_ARGS=--temperature=0`** (server default sampling) | Agent frameworks (Hermes, in our case) send no `temperature`, so the model's default 1.0 applied, and TensorFold drafts DFlash2 only on greedy rounds | requests without a temperature: 4.36 -> **5.73 tokens a round**, ~68 -> **~83 tok/s** (+20%) ([e](#e-the-default-temperature-trap)). Clients that send a temperature keep it. |
| Base EXL3 weights mounted from a plain folder | No re-download; same model behaviour our clients already had | upstream measures on an abliterated checkpoint |
| `SERVED_NAME=glm-5.3-flash`, engine on `127.0.0.1:8001`, [Caddy](proxy/) on `:8000` | Same model id, port and Bearer-key contract as the vLLM server it replaced; TensorFold has no API-key check | zero client changes |
| `GLM53_TF_REASONING_FIELDS=both` | vLLM-era clients read `reasoning_content`, newer ones `reasoning` | both work |
| `MEM_GATE_DROP_CACHES=0` + a container-based cache drop in [`ops/glm-tf-start.sh`](ops/glm-tf-start.sh) | `serve.sh` drops page caches with `sudo -n`; our service account has none | without it, leftover page cache once started TensorFold with **1 request slot instead of 4** |
| `GLM53_TF_STALL_S=300` | The engine marks stalled requests itself; our watchdog acts on that and on `engine_fatal` | see [`ops/tf-health.sh`](ops/tf-health.sh) |
| NCCL on both PCIe functions of CX7 **port 0** | Our cable is on port 0; upstream's example assumes port 1 | |

## Benchmarks

Clients are upstream's, unmodified: `bench/glmbench.py`, `bench/multiturn.py`, `bench/quality.py`,
`bench/toolcall_harness.py`. Straight to the engine on `127.0.0.1:8001`, nothing else on the GPUs except where noted.
Raw JSON and logs: [`results/2026-09-30`](results/2026-09-30) and [`results/2026-10-01`](results/2026-10-01).

### (a) Decode, single stream

tok/s, decode only, median of 3 (edit cells: 1 rep, re-run on 10-01 within 1-3%). B0 = upstream production config
with MTP drafts only; B1 = + DFlash2. The right column is upstream's published W20 production (abliterated weights,
DFlash2, host OS tuning) for reference, not a same-rig comparison.

| Cell | B0 MTP only | **B1 + DFlash2** | B1 vs B0 | upstream W20 |
| --- | ---: | ---: | ---: | ---: |
| tf code, sampled T=1, 64 tok | 57.7 | 56.2 | -3% | 51.1 |
| tf chat, sampled T=1, 64 tok | 50.3 | 48.6 | -3% | 48.6 |
| tf code, greedy, 64 tok | 69.5 | **76.7** | +10% | 89.6 |
| tf chat, greedy, 64 tok | 55.6 | 53.0 | -5% | 51.6 |
| tweet sequence, greedy, 512 tok | 66.4 | **100.7** | **+52%** | 105.1 |
| tweet code, greedy, 512 tok | 59.7 | 61.1 | +2% | 75.9 |
| tweet json, greedy, 512 tok | 75.5 | **90.2** | +19% | 84.0 |
| kit hashmap (prose), greedy, 200 tok | 52.5 | 51.4 | -2% | 59.6 |
| kit structured, greedy, 200 tok | 83.0 | **108.5** | **+31%** | 112.3 |
| kit essay, greedy, 200 tok | 52.7 | 49.6 | -6% | 50.5 |
| edit rename, greedy, 1024 tok | 54.8 | **61.8** (62.6) | +13% | 124.1 |
| edit comments, greedy, 1024 tok | 76.9 | **97.6** (99.7) | +27% | 108.0 |
| edit print-to-log, greedy, 1024 tok | 118.3 | **121.7** (122.3) | +3% | 126.5 |

Startup canary (the engine's own probe): 4.4 tokens a round / 57-66 tok/s with MTP only, **5.71 / 78.4 tok/s** with
DFlash2. The vLLM fork this replaced (Entrpi's, DFlash2 k=7) did 21-23 tok/s on our prose probe on the same pair;
TensorFold does 50-52 on that probe.

### (b) Prefill and time to first token

`glmbench --suites ctx`, unique prompts, kernels compiled (2 reps).

| Prompt | Cold TTFT | Prefill | Warm TTFT (same prompt again) | Decode behind it |
| ---: | ---: | ---: | ---: | ---: |
| 1.8k | 1.47 s | 1,213 tok/s | 0.26 s | 104.8 tok/s |
| 7.0k | 4.24 s | 1,660 tok/s | 0.10 s | 94.1 tok/s |
| 28.0k | 16.06 s | 1,747 tok/s | 0.16 s | 97.2 tok/s |
| 85.8k | 50.33 s | 1,705 tok/s | 0.23 s | 90.7 tok/s |

### (c) Sessions and prefix reuse (what agents actually feel)

`multiturn --modes sessions,followup`: three ~39k-token conversations sharing a system prompt, visited A, B, A, C, B, A.

| Turn | Prompt | Cached | TTFT |
| --- | ---: | ---: | ---: |
| A (cold) | 39,409 | 0 | 24.52 s |
| B (cold) | 39,349 | 0 | 24.30 s |
| A again | 39,491 | 39,360 | **0.44 s** |
| C (new, shared system prompt) | 39,349 | 1,984 | 23.64 s |
| B again | 39,431 | 39,296 | **0.46 s** |
| A again | 39,513 | 39,360 | **0.46 s** |
| follow-up after a 37k cold prompt | 39,546 | 37,312 | **1.93 s** (cold: 22.73 s) |

### (d) Concurrency and load

`multiturn --modes concurrent,batchexact --streams 4` (3 reps): **80.0 / 86.2 / 80.7 tok/s aggregate**, TTFT 0.46-0.53 s
per stream; batched replies identical to the same requests alone (4/4).

[`bench/soak4.py`](bench/soak4.py): 4 concurrent agent-like sessions, ~34.5k-token prompts with a shared 12k system
prefix, 3 growing turns each: **12/12 ok, 0 GPU Xid, 0 engine errors, 0 stalls**, MemAvailable minimum 16.3 / 17.4 GiB
(head / worker). Follow-up turns reuse 34,496 of ~34,700 prompt tokens and answer in 8-20 s. The vLLM stack this
replaced died twice (Xid 31 on both GPUs) under this kind of load.

Memory stress (`multiturn --modes stress --stress-target 250000`): 4 conversations grown together to ~250k tokens
each (~1M tokens in the shared KV pool), then 3 decode while the 4th sends a 250k-token turn: **PASS**, MemAvailable
minimum **14.69 GiB head / 15.70 GiB worker** (earlyoom acts at 3.7 GiB; upstream's tuned rig: 10.6 / 10.7 GiB).
Longest decode gap during the final prefill: 3.6 s. Details: [`results/2026-10-01/SUMMARY.md`](results/2026-10-01/SUMMARY.md).

### (e) The default-temperature trap

If your client sends no `temperature`, TensorFold uses the model's `generation_config.json`: **1.0**. Sampled rounds
are drafted by MTP only, so DFlash2 never runs. Same JSON-generation request, three ways:

| Request | Tokens a round | Decode |
| --- | ---: | ---: |
| no `temperature`, server default (model: 1.0) | 4.36 | 66.6-69.9 tok/s |
| `temperature: 0` | 5.73 | 84.4-86.6 tok/s |
| no `temperature`, server started with `--temperature=0` | **5.73** | **81.8 tok/s** |

`reasoning_effort` is **not** a speed lever on this checkpoint: on an architecture prompt the model wrote ~130
characters of reasoning at `high` and none at `low`/`none`, with the same wall time within noise
([`effort-ab-architect.txt`](results/2026-10-01/effort-ab-architect.txt),
[`effort-ab-toolturn.txt`](results/2026-10-01/effort-ab-toolturn.txt)).

### (f) Exactness

`glmbench --suites exact`: drafted vs serial (`"draft": false`) token-id equality, greedy and sampled, 5 prompts:
**10/10 identical**, drafted 1.2-2.8x faster than serial (serial ~36 tok/s).

### (g) Quality

`bench/quality.py`: MMLU-200 (stratified over 57 subjects, greedy, thinking off) **89.0% (178/200)**; upstream's
abliterated checkpoint scores 88.0%. Refusal probe: **1/10** (a shoplifting-tactics prompt; these are base weights,
not abliterated; upstream's abliterated weights refuse 0/10).

### (h) Tool calling

`bench/toolcall_harness.py --toolset opencode --stream --reps 5 --temperature 0`: opencode's tool surface, 21 cases x 5,
streamed: **105/105 passed, 0 corrupted** (corrupted = leaked GLM markup or unparseable arguments). Upstream's run on
its checkpoint: 200/210, 0 corrupted.

## Layout

| Path | What |
| --- | --- |
| [`config/prod.env.delta`](config/prod.env.delta) | the config lines we change, with reasons |
| [`proxy/`](proxy/) | Caddy front door: Bearer key on `:8000`, streaming pass-through, `/health` and `/metrics` open |
| [`ops/glm-tf-start.sh`](ops/glm-tf-start.sh), [`ops/glm-tf-stop.sh`](ops/glm-tf-stop.sh) | start / stop the pair and the proxy (cache drop, upstream's canary, keyed check) |
| [`ops/glm-engine.sh`](ops/glm-engine.sh), [`ops/glm-start.dispatch.sh`](ops/glm-start.dispatch.sh), [`ops/glm.service.example`](ops/glm.service.example) | one systemd unit, two engines: migrate or roll back with one word |
| [`ops/tf-health.sh`](ops/tf-health.sh) | the signals our watchdog acts on (containers, proxy, `engine_fatal`, `requests_stalled`) |
| [`bench/client_test.py`](bench/client_test.py) | client acceptance: auth, chat, both reasoning fields, streaming, tool calls |
| [`bench/soak4.py`](bench/soak4.py) | 4 concurrent agent-like sessions, memory sampled on both nodes |
| [`results/`](results/) | raw JSON and logs for every number above |
| [`docs/OPTIMIZATION-ROADMAP.md`](docs/OPTIMIZATION-ROADMAP.md) | what we try next, ranked |

## Apply it

1. Set up upstream exactly as its README says (two Sparks on a QSFP CX7 link, Docker with the NVIDIA runtime,
   passwordless ssh head -> worker) and build its image: `scripts/serve.sh build`.
2. In upstream's checkout: `cp config/prod.env.example config/prod.env`, then apply
   [`config/prod.env.delta`](config/prod.env.delta).
3. For DFlash2, download it on **both** nodes into `<models>/hub` (read its licence first, [below](#licensing)):
   ```bash
   docker run --rm --network host --user "$(id -u):$(id -g)" -e HF_HUB_OFFLINE=0 -e HF_HOME=/hf \
     -v "$HOME/models:/hf" --entrypoint python3 glm53-tensorfold:dev -c \
     "from huggingface_hub import snapshot_download as s; print(s('incoai/GLM-5.3-Flash-DFlash2', revision='7d74cdd881ed7e32c31175984a67823127b66cfe'))"
   ```
   The image sets `HF_HUB_OFFLINE=1` on purpose; override it only for this download.
4. `scripts/serve.sh preflight`, then [`ops/glm-tf-start.sh`](ops/glm-tf-start.sh) (or `serve.sh start` plus
   [`proxy/proxy-up.sh`](proxy/proxy-up.sh)). The first start writes ~82 GB of prepared weights a node (~10 min);
   later starts take ~1.5 min.
5. From a client machine: `GLM_BASE=http://<head>:8000 GLM_KEY=... python3 bench/client_test.py`.

Client settings that worked for us: model `glm-5.3-flash`; context window 131072 (the server allows 1,048,576, shared
by 4 slots); **temperature 0 for agents** (or leave it unset with our server default); max output 8192.

Gotchas we hit, so you don't:
- `EXTRA_ARGS` must not contain spaces: `serve.sh` word-splits it into the `docker run` line, so
  `"--temperature 0"` made `0` the image name and the start failed. Use `--temperature=0`.
- An agent gateway on macOS started by its own launchd job (not the vendor's) can lose **Local Network** permission:
  every call to a `192.168.x.x` endpoint fails with `Errno 65 (No route to host)` while `curl` from a shell works,
  and the agent silently falls back to whatever is next in its chain. Use the vendor's launcher.

## Limits and negatives

- One pair of Sparks, one checkpoint, two days of measurement. Upstream marks its work in progress; so do we.
- DFlash2 costs 2-6% on prose; we keep it because most of our tokens are code, JSON and tool calls.
- We trail upstream's W20 on tf code greedy (76.7 vs 89.6), hashmap (51.4 vs 59.6) and edit-rename (62 vs 124). Not
  explained yet: different weights, no OS tuning here (upstream measured +4.8% from it), or something else.
- Four long requests share one 1,048,576-token KV pool: one request can use it all, four long ones wait for room.
- KV cache is FP8 (upstream production default); upstream documents that greedy replies diverge from bf16 KV early on
  most prompts, with quality checks unchanged.
- No `logprobs`, `n > 1` rejected (upstream's API limits).

## Licensing

- **This repo** (scripts, configs, docs, results): Apache-2.0 ([`LICENSE`](LICENSE), [`NOTICE`](NOTICE)). No upstream
  code is copied here; we configure and benchmark it.
- **Weights (not included):** [brandonmusic/GLM-5.3-Flash-tr3-4bpw](https://huggingface.co/brandonmusic/GLM-5.3-Flash-tr3-4bpw),
  produced with ShapleyMcg by Brandon M. Music under the
  [ShapleyMcg License v1.0](https://github.com/brandonmmusic-max/shapleymcg/blob/main/LICENSE), which requires the
  attribution notice below. Base model [zai-org/GLM-5.3-Flash](https://huggingface.co/zai-org/GLM-5.3-Flash).
  ShapleyMcg attribution notice (reproduced as its licence requires):

  > This work includes or was produced using ShapleyMcg, created by Brandon M. Music
  > (https://github.com/brandonmmusic-max/shapleymcg). ShapleyMcg is licensed under the ShapleyMcg License v1.0, an
  > attribution-required license that grants no rights to the person known as "0xSero." Use of ShapleyMcg without this
  > attribution is unlicensed.

- **DFlash2 drafter (not included):** [incoai/GLM-5.3-Flash-DFlash2](https://huggingface.co/incoai/GLM-5.3-Flash-DFlash2)
  is **CC BY-NC-ND 4.0: non-commercial, no derivatives.** Decide whether your use qualifies before enabling it. With
  `DRAFTER=` empty, TensorFold drafts with the model's own MTP layer (column B0 above).
- **Engine (not included):** glm53-tensorfold-spark is Apache-2.0; TensorFold is MIT; see their repositories.

Citation for the weights' method (required by its licence for technical publications):

```bibtex
@misc{music2026shapleymcg,
  author = {Music, Brandon M.},
  title  = {ShapleyMCG: An Auditable Calibration-to-Encoding Pipeline for
            Low-Bit Mixture-of-Experts Models},
  year   = {2026},
  url    = {https://github.com/brandonmmusic-max/shapleymcg},
  note   = {Licensed under the ShapleyMcg License v1.0}
}
```

## Credits

This recipe is a thin layer on other people's work. Thank you:

- **[jayleaton / glm53-tensorfold-spark](https://github.com/jayleaton/glm53-tensorfold-spark)**: the 77 patches,
  production config, launcher, canary and every benchmark client used here. Everything that makes this fast is theirs.
- **[Ash Hart / TensorFold](https://github.com/ashhart/TensorFold)** and the TensorFold contributors: the engine.
- **[Brandon M. Music / ShapleyMcg](https://github.com/brandonmmusic-max/shapleymcg)**: the GLM-5.3-Flash TR3 4-bit EXL3
  weights we serve ([brandonmusic/GLM-5.3-Flash-tr3-4bpw](https://huggingface.co/brandonmusic/GLM-5.3-Flash-tr3-4bpw)),
  with the Local Inference Lab contributors credited on that card for the runtime foundation.
- **[incoai](https://huggingface.co/incoai/GLM-5.3-Flash-DFlash2)**: the DFlash2 drafter
  ([blog](https://inco.ai/blog/dflash2/), [DFlash](https://github.com/z-lab/dflash)).
- **[Z.ai](https://huggingface.co/zai-org/GLM-5.3-Flash)**: GLM-5.3-Flash.
- **[turboderp / ExLlamaV3](https://github.com/turboderp-org/exllamav3)**: the EXL3 format.
- **[Entrpi / vllm-glm-5.3-flash-spark](https://github.com/Entrpi/vllm-glm-5.3-flash-spark)**: the GLM-5.3-Flash 2x Spark vLLM fork we ran in production before this, and
  the baseline in our before/after numbers.
- **[MiaAI-Lab](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks)** and
  **[Reederey87](https://github.com/Reederey87/glm53-flash-exl3-2x-dgx-spark)**: the 2x Spark vLLM kits this whole line
  of work grew from; upstream's fat-expert MoE kernel (in the image we run) adapts Reederey87's code.
- **[local-inference-lab/b12x](https://github.com/local-inference-lab/b12x)** (Luke Alonso and contributors): the RoCE
  all-gather and kernel designs in upstream's patches.
- **[kindlingai](https://github.com/kindlingai/glm-5.3-flash-gx10)**: the two-CX7-function NCCL setting we use.
- **[mlc-ai/xgrammar](https://github.com/mlc-ai/xgrammar)**: structured output in the image.
- **[neko-legends](https://huggingface.co/neko-legends)**: the abliterated checkpoint upstream's reference numbers come from.
- **NVIDIA**: DGX Spark and the PyTorch container the image builds on. **[vLLM](https://github.com/vllm-project/vllm)**,
  **[Caddy](https://caddyserver.com)**, **[Hugging Face](https://huggingface.co)**.

Recipe, ops scripts and measurements: Tech Guard LLC.
