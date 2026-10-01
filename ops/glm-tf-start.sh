#!/usr/bin/env bash
# Start GLM-5.3-Flash on TensorFold behind the :8000 key proxy. Meant as (or called from) a systemd ExecStart.
#   TF_DIR     glm53-tensorfold-spark checkout on the head (default ~/glm53-tensorfold-spark)
#   PROXY_DIR  this repo's proxy/ folder (default: ../proxy next to this script)
#   WORKER     ssh alias of the worker (default: worker)
#   GLM_API_KEY or GLM_KEY_CMD   as proxy/proxy-up.sh
# Restarts reuse TensorFold's prepared weights and take ~1.5 min; the first start after an image or config change
# compiles kernels and writes ~82 GB of prepared weights a node (~10 min).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
TF_DIR=${TF_DIR:-$HOME/glm53-tensorfold-spark}
PROXY_DIR=${PROXY_DIR:-$here/../proxy}
WORKER=${WORKER:-worker}
wssh() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$WORKER" "$@" < /dev/null; }

# Never start on top of another stack that holds the GPUs (here: the vLLM container we migrated from).
# OTHER_CONTAINERS="" (set but empty) skips this.
for c in ${OTHER_CONTAINERS-vllm_glm53}; do docker rm -f "$c" >/dev/null 2>&1; wssh "docker rm -f $c" >/dev/null 2>&1; done

# serve.sh wants MemFree >= MEM_GATE_GIB and drops page caches with `sudo -n`. Without passwordless sudo the drop fails,
# and page cache left by large reads (the first start's 82 GB prepared-weight write, backups, model copies) can make
# TensorFold start with 1 request slot instead of 4. Drop them with a privileged one-shot container instead.
dropc='sync; docker run --rm --privileged alpine sh -c "sync; echo 3 > /proc/sys/vm/drop_caches"'
bash -c "$dropc" >/dev/null 2>&1 && echo "glm-tf-start: dropped the head's page cache"
wssh "$dropc" >/dev/null 2>&1 && echo "glm-tf-start: dropped the worker's page cache"

echo "glm-tf-start: starting TensorFold (serve.sh start)"
cd "$TF_DIR" || { echo "glm-tf-start: $TF_DIR missing" >&2; exit 1; }
if ! scripts/serve.sh start < /dev/null; then
  echo "glm-tf-start: serve.sh start failed; see: cd $TF_DIR && scripts/serve.sh logs" >&2
  exit 1
fi

echo "glm-tf-start: starting the :8000 key proxy"
bash "$PROXY_DIR/proxy-up.sh" || exit 1

key=${GLM_API_KEY:-$( [ -n "${GLM_KEY_CMD:-}" ] && bash -c "$GLM_KEY_CMD")}
code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 -H "Authorization: Bearer $key" http://127.0.0.1:8000/v1/models)
if [ "$code" != 200 ]; then echo "glm-tf-start: keyed /v1/models through the proxy returned $code" >&2; exit 1; fi
echo "glm-tf-start: TensorFold up; :8000 keyed /v1/models = 200"
