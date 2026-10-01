#!/usr/bin/env bash
# One health verdict for a TensorFold pair behind the key proxy: the signals our watchdog acts on.
# Exit 0 = healthy, 1 = unhealthy (reason on stdout). Run on the head. WORKER = ssh alias of the worker.
#   containers glm53-tf-r0 (head), glm53-tf-r1 (worker), glm-proxy (head) running
#   /health 200 through the proxy
#   tensorfold_engine_fatal == 0   (the engine raised; the ranks are out of step: restart both)
#   tensorfold_requests_stalled == 0  (needs GLM53_TF_STALL_S > 0 in prod.env; prefill time is allowed for)
# Act only after several consecutive failures, and cap restarts per hour: a restart destroys the evidence.
WORKER=${WORKER:-worker}
API=${API:-http://127.0.0.1:8000}
running() { [ "$("$@" 2>/dev/null)" = true ]; }
fail() { echo "UNHEALTHY: $*"; exit 1; }
running docker inspect -f '{{.State.Running}}' glm53-tf-r0 || fail "rank-0 container not running"
running docker inspect -f '{{.State.Running}}' glm-proxy || fail "key proxy not running"
w=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$WORKER" "docker inspect -f '{{.State.Running}}' glm53-tf-r1" 2>/dev/null < /dev/null) \
  || fail "worker unreachable (needs a person, not a restart)"
[ "$w" = true ] || fail "rank-1 container not running"
h=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$API/health"); [ "$h" = 200 ] || fail "/health returned ${h:-000}"
m=$(curl -s -m 5 "$API/metrics")
# TensorFold metrics are labelled: tensorfold_engine_fatal{model="..."} 0
tfm() { awk -v n="$1" '{k = $1; sub(/[{].*/, "", k)} k == n {s += $NF} END {printf "%d", s}' <<<"$m"; }
[ "$(tfm tensorfold_engine_fatal)" -eq 0 ] || fail "engine_fatal=1"
[ "$(tfm tensorfold_requests_stalled)" -eq 0 ] || fail "$(tfm tensorfold_requests_stalled) stalled request(s)"
echo "HEALTHY: inflight=$(tfm tensorfold_requests_inflight)"
