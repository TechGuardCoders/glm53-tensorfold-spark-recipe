# GLM-5.3-Flash on 2x DGX Spark: Tech Guard's TensorFold recipe

How we run GLM-5.3-Flash in production on two NVIDIA DGX Sparks for a small team of developers and coding agents, on
top of [jayleaton/glm53-tensorfold-spark](https://github.com/jayleaton/glm53-tensorfold-spark) (the TensorFold engine
plus 77 patches). This repo is the delta: what we changed, why, what it measured, and where we think the next speed
comes from.

**Result on our pair:** single-stream decode went from ~21-23 tok/s on the vLLM fork we ran before to ~50 tok/s
(prose) and 61-122 tok/s (code, structured output, JSON, file edits) with DFlash2 drafting; restarts went from 8-10
minutes to ~1.5. Four concurrent ~35k-token agent sessions run clean (12/12, no GPU faults) with 16+ GiB free per
node. Full tables: [`results/2026-09-30/SUMMARY.md`](results/2026-09-30/SUMMARY.md).

> Measured on one pair of Sparks, on a stock (desktop) DGX OS install, with the base GLM-5.3-Flash EXL3 4-bit
> checkpoint. Upstream is marked work in progress, and so is this. Measure your own rig.

## What we changed from upstream's production config

All of it is in [`config/prod.env.delta`](config/prod.env.delta):

| Change | Why |
| --- | --- |
| Our existing base EXL3 checkpoint, mounted from a plain folder (`HEAD_HF` = its parent, `MODEL_PATH=/root/.cache/huggingface/<folder>`) | No re-download, and the same model behaviour our clients already had. Upstream measures on an abliterated checkpoint. |
| DFlash2 drafter on | +10% to +52% on code / structured / JSON / edit output; -2% to -6% on prose. Our traffic is mostly the former. |
| `SERVED_NAME=glm-5.3-flash`, engine on `127.0.0.1:8001`, Caddy on `:8000` | Same model id, port and Bearer-key contract as the vLLM server it replaced, so no client changed. TensorFold has no API-key check. |
| `GLM53_TF_REASONING_FIELDS=both` | Clients written for vLLM read `reasoning_content`; newer ones read `reasoning`. |
| `MEM_GATE_DROP_CACHES=0` + cache drop in our start script | `serve.sh` drops page caches with `sudo -n`; our service account has none. Without a drop, leftover page cache once made TensorFold start with **1 request slot instead of 4**. |
| `GLM53_TF_STALL_S=300` | Lets a watchdog act on the engine's own stall signal. |
| NCCL on both PCIe functions of CX7 port 0 | Our cable is on port 0; upstream's example assumes port 1. |

## Layout

| Path | What |
| --- | --- |
| [`config/prod.env.delta`](config/prod.env.delta) | the config lines we change, with reasons |
| [`proxy/`](proxy/) | Caddy front door: Bearer key on `:8000`, streaming pass-through, `/health` and `/metrics` open |
| [`ops/glm-tf-start.sh`](ops/glm-tf-start.sh), [`ops/glm-tf-stop.sh`](ops/glm-tf-stop.sh) | start/stop the pair + proxy (cache drop, canary via `serve.sh`, keyed check) |
| [`ops/glm-engine.sh`](ops/glm-engine.sh), [`ops/glm-start.dispatch.sh`](ops/glm-start.dispatch.sh), [`ops/glm.service.example`](ops/glm.service.example) | one systemd unit, two engines: switch or roll back with one word |
| [`ops/tf-health.sh`](ops/tf-health.sh) | the health signals our watchdog acts on (containers, proxy, `engine_fatal`, `requests_stalled`) |
| [`bench/client_test.py`](bench/client_test.py) | client acceptance: auth, chat, both reasoning fields, streaming, tool calls |
| [`bench/soak4.py`](bench/soak4.py) | 4 concurrent agent-like sessions with long shared-prefix prompts, memory sampled on both nodes |
| [`results/`](results/) | raw benchmark JSON and summaries |
| [`docs/OPTIMIZATION-ROADMAP.md`](docs/OPTIMIZATION-ROADMAP.md) | what we will try next, ranked |

## Apply it

1. Set up upstream first, exactly as its README says (two Sparks on a QSFP CX7 link, Docker with the NVIDIA runtime,
   passwordless ssh head -> worker), and build its image: `scripts/serve.sh build`.
2. `cp config/prod.env.example config/prod.env` in upstream's checkout, then apply [`config/prod.env.delta`](config/prod.env.delta).
3. If you use DFlash2, download it on **both** nodes into `<models>/hub` (read its licence first, below):
   ```bash
   docker run --rm --network host --user "$(id -u):$(id -g)" -e HF_HUB_OFFLINE=0 -e HF_HOME=/hf \
     -v "$HOME/models:/hf" --entrypoint python3 glm53-tensorfold:dev -c \
     "from huggingface_hub import snapshot_download as s; print(s('incoai/GLM-5.3-Flash-DFlash2', revision='7d74cdd881ed7e32c31175984a67823127b66cfe'))"
   ```
   (The image sets `HF_HUB_OFFLINE=1` on purpose; override it only for this download.)
4. `scripts/serve.sh preflight`, then start with [`ops/glm-tf-start.sh`](ops/glm-tf-start.sh) (or `serve.sh start`
   plus [`proxy/proxy-up.sh`](proxy/proxy-up.sh)). The first start writes ~82 GB of prepared weights a node and takes
   ~10 minutes; later starts ~1.5.
5. Check from a client machine: `GLM_BASE=http://<head>:8000 GLM_KEY=... python3 bench/client_test.py`.

Client settings that worked for us: model `glm-5.3-flash`, context window 131072 (the server allows 1,048,576 shared
across 4 slots), temperature 0 for agents, max output 8192, `reasoning_effort: low` for agents.

## Licensing

- This repo's own scripts and docs: Apache-2.0 ([`LICENSE`](LICENSE)). Upstream code is not copied here; we
  reference and configure it. See [`NOTICE`](NOTICE).
- **Weights are not included.** GLM-5.3-Flash EXL3 checkpoints carry their own licences (ours: ShapleyMCG 1.0).
- **DFlash2** (`incoai/GLM-5.3-Flash-DFlash2`) is **CC BY-NC-ND 4.0: non-commercial, no derivatives.** Decide
  whether your use qualifies before enabling it. With `DRAFTER=` empty, TensorFold drafts with the model's own MTP
  layer ([numbers](results/2026-09-30/SUMMARY.md), column B0).

## Credits

[jayleaton/glm53-tensorfold-spark](https://github.com/jayleaton/glm53-tensorfold-spark) did the engine work this
rests on; [TensorFold](https://github.com/ashhart/TensorFold) is the engine. DFlash2 by incoai. Measurements and ops
recipe by Tech Guard LLC.
