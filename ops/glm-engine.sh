#!/usr/bin/env bash
# Pick the engine a single systemd unit runs, so a migration is one word and a rollback is one word.
#   glm-engine.sh            show the selected engine and what is running
#   glm-engine.sh tf         switch to TensorFold and restart the unit
#   glm-engine.sh vllm       switch back to the previous (vLLM) stack and restart the unit
# The choice lives in ~/.glm-engine (ENGINE=tf|vllm; missing = vllm), written on both nodes so tools on the worker
# know which rank-1 container to look for. The unit's start/stop scripts read it (see glm-start.dispatch.sh).
# Needs `sudo -n systemctl start|stop <unit>` for this user (a scoped sudoers rule is enough).
set -euo pipefail
UNIT=${GLM_UNIT:-glm}
WORKER=${WORKER:-worker}
F=$HOME/.glm-engine
cur=$( { sed -n 's/^ENGINE=//p' "$F" 2>/dev/null || true; } | head -1); cur=${cur:-vllm}

case "${1:-}" in
  "")
    echo "selected engine : $cur"
    echo "$UNIT.service     : $(systemctl is-active "$UNIT" 2>/dev/null || true)"
    echo "head containers : $(docker ps --format '{{.Names}}' | grep -E '^(vllm_glm53|glm53-tf-r0|glm-proxy)$' | tr '\n' ' ')"
    echo "worker          : $(ssh -o BatchMode=yes -o ConnectTimeout=5 "$WORKER" "docker ps --format '{{.Names}}'" 2>/dev/null < /dev/null | grep -E '^(vllm_glm53|glm53-tf-r1)$' | tr '\n' ' ')"
    ;;
  tf|vllm)
    if [ "$1" = "$cur" ] && systemctl is-active -q "$UNIT"; then echo "already on $cur and $UNIT is active"; exit 0; fi
    echo "switching $UNIT: $cur -> $1"
    sudo -n /usr/bin/systemctl stop "$UNIT"
    echo "ENGINE=$1" > "$F"
    ssh -o BatchMode=yes -o ConnectTimeout=5 "$WORKER" "echo ENGINE=$1 > ~/.glm-engine" < /dev/null \
      || echo "warning: could not write ~/.glm-engine on the worker" >&2
    sudo -n /usr/bin/systemctl start "$UNIT"
    echo "$UNIT: $(systemctl is-active "$UNIT") on $1"
    ;;
  *) echo "usage: glm-engine.sh [tf|vllm]" >&2; exit 2 ;;
esac
