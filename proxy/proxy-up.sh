#!/usr/bin/env bash
# Start (or replace) the API-key proxy on :8000 in front of TensorFold (127.0.0.1:8001).
# The key is read from GLM_API_KEY, or printed by the command in GLM_KEY_CMD (so it never sits in a file you commit).
#   GLM_KEY_CMD="cat ~/.config/glm/api-key" ./proxy-up.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
KEY=${GLM_API_KEY:-}
[ -n "$KEY" ] || [ -z "${GLM_KEY_CMD:-}" ] || KEY=$(bash -c "$GLM_KEY_CMD")
[ -n "$KEY" ] || { echo "proxy-up: set GLM_API_KEY or GLM_KEY_CMD" >&2; exit 1; }
docker rm -f glm-proxy >/dev/null 2>&1 || true
docker run -d --name glm-proxy --restart unless-stopped --network host \
  -e GLM_KEY="$KEY" -v "$here/Caddyfile:/etc/caddy/Caddyfile:ro" \
  --log-opt max-size=10m --log-opt max-file=3 caddy:2-alpine >/dev/null
for _ in $(seq 1 20); do ss -ltn | grep -q ':8000 ' && { echo "glm-proxy listening on :8000"; exit 0; }; sleep 1; done
echo "proxy-up: :8000 not listening" >&2; docker logs --tail 20 glm-proxy >&2; exit 1
