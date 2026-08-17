#!/usr/bin/env bash
# micromdm-serve.sh — launched by micromdm.service
set -euo pipefail
: "${MICROMDM_SERVER_URL:?MICROMDM_SERVER_URL unset}"
API_KEY="$(cat /etc/micromdm/api-key)"
exec /opt/micromdm/bin/micromdm serve \
  -server-url "${MICROMDM_SERVER_URL}" \
  -api-key "${API_KEY}" \
  -config-path /var/lib/micromdm \
  -filerepo /var/lib/micromdm/repo \
  -http-addr 127.0.0.1:8080 \
  -tls=false \
  -http-proxy-headers=true \
  -homepage=false \
  -log-time=true
