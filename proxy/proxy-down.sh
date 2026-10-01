#!/usr/bin/env bash
docker rm -f glm-proxy >/dev/null 2>&1 && echo "glm-proxy removed" || echo "glm-proxy was not running"
