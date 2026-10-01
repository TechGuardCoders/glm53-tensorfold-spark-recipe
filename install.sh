#!/usr/bin/env bash
# One-command install: GLM-5.3-Flash on 2x NVIDIA DGX Spark with TensorFold (+ optional DFlash2).
# Tech Guard recipe: https://github.com/TechGuardCoders/glm53-tensorfold-spark-recipe
#
# Run on the HEAD Spark, as a user in the docker group with passwordless ssh to the worker:
#   curl -fsSL https://raw.githubusercontent.com/TechGuardCoders/glm53-tensorfold-spark-recipe/main/install.sh \
#     | bash -s -- --worker <user>@<worker CX7 address> [--dflash2]
#
# Options:
#   --worker USER@HOST   worker ssh target on the CX7 link (required)
#   --dflash2            also download and enable the DFlash2 drafter (CC BY-NC-ND 4.0: non-commercial; read it)
#   --models DIR         where weights live on BOTH nodes (default: ~/models; the worker's own ~ is used there)
#   --dir DIR            where the engine and this recipe are checked out (default: ~/glm53-tf)
#   --dry-run            check both nodes and print the plan; change nothing
#   -h, --help
# Re-running is safe: finished steps are skipped (weights, image, checkouts) and the config is regenerated.
# Takes ~1-2 h the first time (image build + 176 GB of weights a node); the first start then takes ~10 min.
set -euo pipefail

UPSTREAM=https://github.com/jayleaton/glm53-tensorfold-spark
UPSTREAM_SHA=b463237b014c1fd11915accc40ed6133691e5ea5
RECIPE=https://github.com/TechGuardCoders/glm53-tensorfold-spark-recipe
WEIGHTS=brandonmusic/GLM-5.3-Flash-tr3-4bpw
WEIGHTS_REV=a5fee929cf4888b1824323e33e8a19b60129e025
DRAFTER=incoai/GLM-5.3-Flash-DFlash2
DRAFTER_REV=7d74cdd881ed7e32c31175984a67823127b66cfe
IMAGE=glm53-tensorfold:dev
NEED_GB=400

usage() { cat <<'U'
Usage: install.sh --worker USER@HOST [--dflash2] [--models DIR] [--dir DIR] [--dry-run]
  --worker USER@HOST   worker ssh target on the CX7 link (required; passwordless ssh from the head)
  --dflash2            also download and enable the DFlash2 drafter (CC BY-NC-ND 4.0: non-commercial)
  --models DIR         weights on BOTH nodes (default ~/models; the worker's own home is used there)
  --dir DIR            engine + recipe checkouts (default ~/glm53-tf)
  --dry-run            check both nodes and print the plan; change nothing
Run it on the head Spark as a user in the docker group. Re-running is safe.
U
}
WORKER="" ; WITH_DRAFTER=0 ; MODELS="$HOME/models" ; DIR="$HOME/glm53-tf" ; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --worker) WORKER=${2:?}; shift 2 ;;
    --dflash2) WITH_DRAFTER=1; shift ;;
    --models) MODELS=${2:?}; shift 2 ;;
    --dir) DIR=${2:?}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

c_brand=$'\e[1;38;2;214;214;214m'; c_dim=$'\e[2m'; c_red=$'\e[31m'; c_off=$'\e[0m'
[ -t 1 ] || { c_brand=""; c_dim=""; c_red=""; c_off=""; }
step() { printf '\n%s==> %s%s\n' "$c_brand" "$*" "$c_off"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '%sinstall: %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf '    %s[dry-run]%s %s\n' "$c_dim" "$c_off" "$*"; else "$@"; fi; }
wssh() { ssh -o BatchMode=yes -o ConnectTimeout=8 "$WORKER" "$@" < /dev/null; }

printf '%sGLM-5.3-Flash on 2x DGX Spark: TensorFold%s recipe by Tech Guard%s\n' "$c_brand" "$([ $WITH_DRAFTER = 1 ] && echo ' + DFlash2')" "$c_off"
[ -n "$WORKER" ] || die "pass --worker <user>@<worker CX7 address> (see --help)"

# ---------------------------------------------------------------------------------------------------- checks ----
step "Checking both nodes"
[ "$(uname -m)" = aarch64 ] || die "run this on the head DGX Spark (aarch64), not here"
nvidia-smi -L 2>/dev/null | grep -q GB10 || die "no GB10 GPU on this node"
docker info >/dev/null 2>&1 || die "docker is not usable by $(whoami) (add the user to the docker group, log in again)"
command -v ibdev2netdev >/dev/null || die "ibdev2netdev not found (DGX OS ships it with the Mellanox OFED tools)"
for t in git curl openssl ssh; do command -v $t >/dev/null || die "missing tool: $t"; done
wssh true 2>/dev/null || die "cannot ssh to $WORKER without a password (ssh-copy-id $WORKER)"
wssh 'nvidia-smi -L' 2>/dev/null | grep -q GB10 || die "no GB10 GPU on the worker"
wssh 'docker info' >/dev/null 2>&1 || die "docker is not usable on the worker by that user"
info "head $(hostname), worker $(wssh hostname): GB10 + docker on both"

# The CX7 link: the netdev that carries an IPv4 address and is Up in ibdev2netdev.
NETDEV="" ; HEAD_IP=""
while read -r ib _ _ _ nd st; do
  [ "$st" = "(Up)" ] || continue
  ip4=$(ip -4 -br addr show "$nd" 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
  [ -n "$ip4" ] && { NETDEV=$nd; HEAD_IP=$ip4; break; }
done < <(ibdev2netdev)
[ -n "$NETDEV" ] || die "no CX7 netdev with an IPv4 address is Up (cable the Sparks and address the link first)"
# NCCL over every Up RDMA function of the same CX7 port (e.g. rocep1s0f0 + roceP2p1s0f0 for port 0).
PORTF=$(sed -E 's/.*(f[0-9]+)np[0-9]+$/\1/' <<<"$NETDEV")
HCAS=$(ibdev2netdev | awk -v f="$PORTF" '$6 == "(Up)" && $1 ~ (f "$") {print $1}' | paste -sd, -)
[ -n "$HCAS" ] || HCAS=$(ibdev2netdev | awk -v n="$NETDEV" '$5 == n {print $1}')
WHOST=${WORKER#*@}
ping -c1 -W2 "$WHOST" >/dev/null 2>&1 || die "worker $WHOST does not answer ping from the head"
info "CX7 link: $NETDEV ($HEAD_IP) -> $WHOST; NCCL_IB_HCA=$HCAS"

WHOME=$(wssh 'printf %s "$HOME"')
WMODELS=${MODELS/#$HOME/$WHOME}
gb_free() { df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc 0-9; }
mkdir_p() { if [ "$DRY" = 1 ]; then :; else mkdir -p "$1"; fi; }
mkdir_p "$MODELS"; mkdir_p "$DIR"
H_FREE=$(gb_free "$( [ -d "$MODELS" ] && echo "$MODELS" || echo "$HOME")")
W_FREE=$(wssh "d='$WMODELS'; [ -d \"\$d\" ] || d=\$HOME; df -BG --output=avail \"\$d\" | tail -1 | tr -dc 0-9")
info "free disk: head ${H_FREE:-?} GB, worker ${W_FREE:-?} GB (a fresh install needs ~$NEED_GB GB a node)"
snap="hub/models--${WEIGHTS/\//--}/snapshots/$WEIGHTS_REV"
have_w() { [ -f "$MODELS/$snap/config.json" ]; }
if ! have_w; then
  [ "${H_FREE:-0}" -ge "$NEED_GB" ] || die "head needs ~$NEED_GB GB free under $MODELS"
  [ "${W_FREE:-0}" -ge "$NEED_GB" ] || die "worker needs ~$NEED_GB GB free under $WMODELS"
fi

if [ "$WITH_DRAFTER" = 1 ]; then
  info "${c_brand}DFlash2${c_off} ($DRAFTER) is CC BY-NC-ND 4.0: non-commercial use only, no derivatives."
  info "Enabling it is your decision. Without --dflash2 the model's own MTP layer drafts (~10-50% slower on code/JSON)."
fi

# --------------------------------------------------------------------------------------------- checkouts ----
step "Engine and recipe checkouts in $DIR"
TF="$DIR/glm53-tensorfold-spark" ; REC="$DIR/recipe"
if [ -d "$TF/.git" ]; then info "engine checkout present"; else run git clone -q "$UPSTREAM" "$TF"; fi
run git -C "$TF" -c advice.detachedHead=false checkout -q "$UPSTREAM_SHA"
run git -C "$TF" submodule update -q --init --recursive
if [ -d "$REC/.git" ]; then run git -C "$REC" pull -q --ff-only; else run git clone -q "$RECIPE" "$REC"; fi
info "jayleaton/glm53-tensorfold-spark @ ${UPSTREAM_SHA:0:7} (TensorFold submodule pinned by it)"

# -------------------------------------------------------------------------------------------------- key ----
CONF="$HOME/.config/glm53"
if [ -s "$CONF/api-key" ]; then info "API key: existing $CONF/api-key"
else
  if [ "$DRY" = 1 ]; then info "[dry-run] would create an API key in $CONF/api-key"
  else mkdir -p "$CONF"; chmod 700 "$CONF"; umask 077; printf 'sk-glm-%s\n' "$(openssl rand -hex 24)" > "$CONF/api-key"; info "API key: created $CONF/api-key"; fi
fi

# ----------------------------------------------------------------------------------------------- config ----
step "Config: upstream production + the Tech Guard delta"
draft_path=""; [ "$WITH_DRAFTER" = 1 ] && draft_path="/root/.cache/huggingface/hub/models--${DRAFTER/\//--}/snapshots/$DRAFTER_REV"
cat <<EOF | sed 's/^/    /'
WORKER_SSH=$WORKER  HEAD_IP=$HEAD_IP  NCCL_SOCKET_IFNAME=$NETDEV  NCCL_IB_HCA=$HCAS
HEAD_HF=$MODELS  WORKER_HF=$WMODELS
MODEL_PATH=/root/.cache/huggingface/$snap
DRAFTER=${draft_path:-<empty: MTP drafts>}
SERVED_NAME=glm-5.3-flash HOST=127.0.0.1 PORT=8001 (key proxy on :8000)  EXTRA_ARGS=--temperature=0
GLM53_TF_REASONING_FIELDS=both  GLM53_TF_STALL_S=300  MEM_GATE_DROP_CACHES=0
EOF
if [ "$DRY" = 0 ]; then
  cfg="$TF/config/prod.env"
  [ -f "$cfg" ] && cp -p "$cfg" "$cfg.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$TF/config/prod.env.example" "$cfg"
  set_kv() { if grep -qE "^$1=" "$cfg"; then sed -i -E "s|^$1=.*|$1=$2|" "$cfg"; else printf '%s=%s\n' "$1" "$2" >> "$cfg"; fi; }
  set_kv WORKER_SSH "\"$WORKER\"";  set_kv HEAD_IP "\"$HEAD_IP\""
  set_kv NCCL_SOCKET_IFNAME "$NETDEV"; set_kv NCCL_IB_HCA "$HCAS"
  set_kv HEAD_HF "$MODELS"; set_kv WORKER_HF "$WMODELS"
  set_kv MODEL_PATH "/root/.cache/huggingface/$snap"; set_kv DRAFTER "$draft_path"
  set_kv SERVED_NAME glm-5.3-flash; set_kv HOST 127.0.0.1; set_kv PORT 8001
  set_kv MEM_GATE_DROP_CACHES 0; set_kv GLM53_TF_REASONING_FIELDS both; set_kv GLM53_TF_STALL_S 300
  set_kv EXTRA_ARGS "--temperature=0"     # no spaces: serve.sh word-splits EXTRA_ARGS into docker run
  info "wrote $cfg"
fi

# ------------------------------------------------------------------------------------------------ image ----
step "Engine image ($IMAGE)"
if docker image inspect "$IMAGE" >/dev/null 2>&1 && wssh "docker image inspect $IMAGE" >/dev/null 2>&1; then
  info "present on both nodes"
else
  info "building on the head and shipping it to the worker (pulls nvcr.io/nvidia/pytorch; ~30-60 min)"
  (cd "$TF" && run scripts/serve.sh build)
fi

# ---------------------------------------------------------------------------------------------- weights ----
hf_get() {  # $1 = repo, $2 = revision, $3 = node (head|worker): snapshot_download with the image's huggingface_hub
  local dir=$MODELS; [ "$3" = worker ] && { dir=$WMODELS; wssh "mkdir -p '$dir'"; }; [ "$3" = head ] && mkdir -p "$dir"
  local cmd="docker run --rm --network host --user \$(id -u):\$(id -g) -e HF_HUB_OFFLINE=0 -e HF_HOME=/hf \
-e HF_HUB_ENABLE_HF_TRANSFER=0 -v '$dir':/hf --entrypoint python3 $IMAGE -c \
\"from huggingface_hub import snapshot_download as s; print(s('$1', revision='$2'))\""
  if [ "$3" = head ]; then bash -c "$cmd"; else wssh "$cmd"; fi
}
step "Weights: $WEIGHTS @ ${WEIGHTS_REV:0:7} (~176 GB a node)"
info "ShapleyMcg (Brandon M. Music): attribution-required licence; see the recipe's README, Licensing."
if have_w && wssh "test -f '$WMODELS/$snap/config.json'"; then info "present on both nodes"
elif [ "$DRY" = 1 ]; then info "[dry-run] would download on both nodes in parallel"
else
  hf_get "$WEIGHTS" "$WEIGHTS_REV" head > "$DIR/download-head.log" 2>&1 & p1=$!
  hf_get "$WEIGHTS" "$WEIGHTS_REV" worker > "$DIR/download-worker.log" 2>&1 & p2=$!
  info "downloading on both nodes (logs: $DIR/download-*.log)"
  wait $p1 || die "head download failed: $DIR/download-head.log"; wait $p2 || die "worker download failed: $DIR/download-worker.log"
fi
if [ "$WITH_DRAFTER" = 1 ]; then
  step "DFlash2 drafter: $DRAFTER @ ${DRAFTER_REV:0:7} (2.3 GB a node)"
  dsnap="hub/models--${DRAFTER/\//--}/snapshots/$DRAFTER_REV"
  if [ -f "$MODELS/$dsnap/config.json" ] && wssh "test -f '$WMODELS/$dsnap/config.json'"; then info "present on both nodes"
  elif [ "$DRY" = 1 ]; then info "[dry-run] would download on both nodes"
  else hf_get "$DRAFTER" "$DRAFTER_REV" head >/dev/null & q1=$!; hf_get "$DRAFTER" "$DRAFTER_REV" worker >/dev/null & q2=$!
       wait $q1 && wait $q2 || die "drafter download failed"; info "done"; fi
fi

# ------------------------------------------------------------------------------------------------ start ----
step "Preflight and start"
if [ "$DRY" = 1 ]; then
  info "[dry-run] would run: serve.sh preflight; recipe ops/glm-tf-start.sh (cache drop, both ranks, canary, key proxy)"
  printf '\n%sDry run finished: nothing was changed.%s\n' "$c_brand" "$c_off"; exit 0
fi
(cd "$TF" && scripts/serve.sh preflight) || die "preflight reported problems (above); fix them and re-run"
TF_DIR="$TF" PROXY_DIR="$REC/proxy" WORKER="$WORKER" OTHER_CONTAINERS="" GLM_KEY_CMD="cat $CONF/api-key" \
  bash "$REC/ops/glm-tf-start.sh" || die "start failed: cd $TF && scripts/serve.sh logs"

# --------------------------------------------------------------------------------------------- verify ----
step "Verify"
KEY=$(cat "$CONF/api-key")
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 http://127.0.0.1:8000/v1/models)
[ "$code" = 401 ] || die "the proxy did not reject an unkeyed request (got $code)"
reply=$(curl -s -m 120 http://127.0.0.1:8000/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' -d '{"model":"glm-5.3-flash","max_tokens":300,"reasoning_effort":"none","messages":[{"role":"user","content":"What is 17*23? Answer with the number only."}]}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["content"].strip())' 2>/dev/null || true)
[ "$reply" = 391 ] || die "test request did not return 391 (got: ${reply:-nothing})"
LAN=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')
cat <<EOF

${c_brand}GLM-5.3-Flash is serving.${c_off}
  endpoint   http://${LAN:-<head-ip>}:8000/v1   (OpenAI-compatible)
  model      glm-5.3-flash
  API key    $CONF/api-key
  context    up to 1,048,576 tokens shared by 4 concurrent requests (we set clients to 131072)
  stop/start bash $REC/ops/glm-tf-stop.sh  |  TF_DIR=$TF PROXY_DIR=$REC/proxy WORKER=$WORKER GLM_KEY_CMD="cat $CONF/api-key" bash $REC/ops/glm-tf-start.sh
  test       GLM_BASE=http://${LAN:-<head-ip>}:8000 GLM_KEY=\$(cat $CONF/api-key) python3 $REC/bench/client_test.py
  boot       see $REC/ops/glm.service.example for a systemd unit (needs sudo once)
EOF
