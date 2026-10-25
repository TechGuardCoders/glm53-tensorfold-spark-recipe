# How it works

The recipe is upstream's production config plus a short delta, a key proxy, and start/stop scripts.
`install.sh` does all of it; this page explains each piece and how to do it by hand.

## What we changed from upstream's production config

All of it is in [`config/prod.env.delta`](../config/prod.env.delta). Upstream's production config otherwise unchanged
(at `dd5df45` since 2026-10-24; `b463237`, image b11, before that).

| Change | Why | Effect |
| --- | --- | --- |
| **DFlash2 drafter on** (`DRAFTER=`) | Our traffic is mostly code, JSON and tool calls, where DFlash2 drafts deep | +10% to +52% on structured / code / JSON / edit cells, -2% to -6% on prose ([table](EVALS.md#a-decode-single-stream)) |
| **`EXTRA_ARGS=--temperature=0`** (server default sampling) | Agent frameworks (Hermes, in our case) send no `temperature`, so the model's default 1.0 applied, and TensorFold drafts DFlash2 only on greedy rounds | requests without a temperature: 4.36 -> **5.73 tokens a round**, ~68 -> **~83 tok/s** (+20%) ([e](EVALS.md#e-the-default-temperature-trap)). Clients that send a temperature keep it. |
| Base EXL3 weights mounted from a plain folder | No re-download; same model behaviour our clients already had | upstream measures on an abliterated checkpoint |
| `SERVED_NAME=glm-5.3-flash`, engine on `127.0.0.1:8001`, [Caddy](../proxy/) on `:8000` | Same model id, port and Bearer-key contract as the vLLM server it replaced; TensorFold has no API-key check | zero client changes |
| `GLM53_TF_REASONING_FIELDS=both` | vLLM-era clients read `reasoning_content`, newer ones `reasoning` | both work |
| `MEM_GATE_DROP_CACHES=0` + a container-based cache drop in [`ops/glm-tf-start.sh`](../ops/glm-tf-start.sh) | `serve.sh` drops page caches with `sudo -n`; our service account has none | without it, leftover page cache once started TensorFold with **1 request slot instead of 4** |
| `GLM53_TF_STALL_S=300` | The engine marks stalled requests itself; our watchdog acts on that and on `engine_fatal` | see [`ops/tf-health.sh`](../ops/tf-health.sh) |
| NCCL on both PCIe functions of CX7 **port 0** | Our cable is on port 0; upstream's example assumes port 1 | |

## Upstream dd5df45

On 2026-10-24 we moved the pin from `b463237` to `dd5df45` (upstream main; same TensorFold v0.3.4 submodule, 77 -> 81
patches). Nothing in our delta changed, and with upstream's `GLM53_TF_TOOL_FIXES=all` the new tool-call repairs are on
without a config line. What it adds, and why we took it:

| Change | Upstream author | What it does | For us |
| --- | --- | --- | --- |
| **`MALLOC_ARENA_MAX=4`**, set by `serve.sh` in both containers | Jay Leaton | glibc's default (8 arenas a core, 160 on GB10) lets every HTTP, tokenizer and disk-tier thread keep its own arena, and freed memory stays mapped in all of them, so host RSS creeps up over days. 4 bounds it. Override it in `prod.env` | our outages: earlyoom on the head killed rank 0 once its RSS had crept to 10.6-12.8 GB next to another service. This is the main reason we moved |
| **0670** `glm-sessdisk-index-tail` | Jay Leaton | the NVMe session tier's in-RAM index kept every entry's token ids as Python lists (8-36 B a token); it now keeps length, page chain, a digest per 64 tokens and the tail (~1.2 B a token). Lookups match as before | the other half of the RSS creep: our tier is 64 GiB and full |
| **0690** `glm-open-tool-calls` | kuhlsnu (semantics from MiaAI-Lab's patch 0055) | two new names in `GLM53_TF_TOOL_FIXES`, both in `all`. `opencalls`: a call the model's end token left without `</tool_call>` is returned as a call only when it is otherwise complete (every value closed by the model, an offered tool, every required parameter present); anything else stays text. **Fail-closed**: a value cut mid-string is never guessed shut. `argkeys`: a call missing an `<arg_key>` tag gets it back before parsing | agents get a call instead of markup in the text, never a half-written shell command run as one |
| **0630** `glm-batch-idle-doorbell` | sayyidfareed (adapted from TensorFold #132) | when every batch slot is empty, rank 1 waits on the rendezvous TCP store instead of spinning in a GPU collective | the idle worker GPU goes back to 0% instead of running hot between requests |
| **0660** `glm-vision-overflow` | Jay Leaton | the image-count 400 says the limit counts the whole history; opt-in `GLM53_TF_VISION_OVERFLOW=drop_oldest` replaces the oldest images with a text marker | off (we keep upstream's default, `refuse`) |

Measured on the new pin: [`results/2026-10-24`](../results/2026-10-24/SUMMARY.md). Tool calls, exactness and batch
exactness unchanged; decode is 2.5-9.5% under our 09-30 run, but on identical outputs and draft choices, and the
b463237 image is just as slow on the same day. The cause is GPU kernel time on both nodes, not this commit.

## Operator tips

- **After any earlyoom kill (or any crash of one rank), check the worker for a RoCE marker.** When a rank dies
  mid-exchange, its peer's RoCE exchange times out and patch 0230 writes `/cache/roce-failed` into that node's
  `glm53-tf-cache` volume (after a worker crash, look on the head too). Every later start then falls back to NCCL, and
  only one boot-log line says so. A timeout right after the peer was killed is not a link fault. Check, and move it
  aside before the next start:
  ```bash
  ssh <worker> 'docker run --rm --network none -v glm53-tf-cache:/cache --entrypoint ls glm53-tensorfold:dev -la /cache'
  ssh <worker> 'docker run --rm --network none -v glm53-tf-cache:/cache --entrypoint mv glm53-tensorfold:dev /cache/roce-failed /cache/roce-failed.cleared-$(date +%Y%m%d)'
  ```
  Ours sat there for 11 days and cost 2-3% of decode. If the next start writes a new one, the link really is at fault.
- **Never run upstream's `tests/` that execute `serve.sh` (e.g. `tests/test_serve_ops.py`) on a live Spark.** Run
  inside the image on our serving head, that test recursed into thousands of processes, earlyoom killed rank 0, and the
  restart failed because rank 1 still held its GPU: an 18-minute outage. Run them on a machine that is not serving, or
  not at all.

## Layout

| Path | What |
| --- | --- |
| [`install.sh`](../install.sh) | the one-command installer: checks both nodes, detects the CX7 link and NCCL devices, pins upstream, writes the config below, builds the image, downloads weights on both nodes, starts, verifies |
| [`assets/`](../assets/) | logo and the README graphics (`make_svgs.py` regenerates them) |
| [`config/prod.env.delta`](../config/prod.env.delta) | the config lines we change, with reasons |
| [`proxy/`](../proxy/) | Caddy front door: Bearer key on `:8000`, streaming pass-through, `/health` and `/metrics` open |
| [`ops/glm-tf-start.sh`](../ops/glm-tf-start.sh), [`ops/glm-tf-stop.sh`](../ops/glm-tf-stop.sh) | start / stop the pair and the proxy (cache drop, upstream's canary, keyed check) |
| [`ops/glm-engine.sh`](../ops/glm-engine.sh), [`ops/glm-start.dispatch.sh`](../ops/glm-start.dispatch.sh), [`ops/glm.service.example`](../ops/glm.service.example) | one systemd unit, two engines: migrate or roll back with one word |
| [`ops/tf-health.sh`](../ops/tf-health.sh) | the signals our watchdog acts on (containers, proxy, `engine_fatal`, `requests_stalled`) |
| [`bench/client_test.py`](../bench/client_test.py) | client acceptance: auth, chat, both reasoning fields, streaming, tool calls |
| [`bench/soak4.py`](../bench/soak4.py) | 4 concurrent agent-like sessions, memory sampled on both nodes |
| [`results/`](../results/) | raw JSON and logs for every number above |
| [`docs/OPTIMIZATION-ROADMAP.md`](OPTIMIZATION-ROADMAP.md) | what we try next, ranked |

## Manual install (what install.sh automates)

1. Set up upstream exactly as its README says (two Sparks on a QSFP CX7 link, Docker with the NVIDIA runtime,
   passwordless ssh head -> worker) and build its image: `scripts/serve.sh build`.
2. In upstream's checkout: `cp config/prod.env.example config/prod.env`, then apply
   [`config/prod.env.delta`](../config/prod.env.delta).
3. For DFlash2, download it on **both** nodes into `<models>/hub` (read its licence first, [below](../README.md#licensing)):
   ```bash
   docker run --rm --network host --user "$(id -u):$(id -g)" -e HF_HUB_OFFLINE=0 -e HF_HOME=/hf \
     -v "$HOME/models:/hf" --entrypoint python3 glm53-tensorfold:dev -c \
     "from huggingface_hub import snapshot_download as s; print(s('incoai/GLM-5.3-Flash-DFlash2', revision='7d74cdd881ed7e32c31175984a67823127b66cfe'))"
   ```
   The image sets `HF_HUB_OFFLINE=1` on purpose; override it only for this download.
4. `scripts/serve.sh preflight`, then [`ops/glm-tf-start.sh`](../ops/glm-tf-start.sh) (or `serve.sh start` plus
   [`proxy/proxy-up.sh`](../proxy/proxy-up.sh)). The first start writes ~82 GB of prepared weights a node (~10 min);
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

