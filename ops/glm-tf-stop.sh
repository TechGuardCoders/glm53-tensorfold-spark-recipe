#!/usr/bin/env bash
# Stop both TensorFold ranks and the :8000 key proxy. Safe when nothing is running; always exits 0
# (a container that is already gone is the desired end state).
here=$(cd "$(dirname "$0")" && pwd)
TF_DIR=${TF_DIR:-$HOME/glm53-tensorfold-spark}
WORKER=${WORKER:-worker}
cd "$TF_DIR" 2>/dev/null && timeout 120 scripts/serve.sh stop < /dev/null >/dev/null 2>&1
docker rm -f glm53-tf-r0 >/dev/null 2>&1
ssh -o BatchMode=yes -o ConnectTimeout=5 "$WORKER" 'docker rm -f glm53-tf-r1' >/dev/null 2>&1 < /dev/null
docker rm -f glm-proxy >/dev/null 2>&1
exit 0
