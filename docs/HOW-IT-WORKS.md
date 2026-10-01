# How it works

The recipe is upstream's production config plus a short delta, a key proxy, and start/stop scripts.
`install.sh` does all of it; this page explains each piece and how to do it by hand.

## What we changed from upstream's production config

All of it is in [`config/prod.env.delta`](../config/prod.env.delta). Upstream's production config otherwise unchanged
(image b11 at `b463237`).

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

