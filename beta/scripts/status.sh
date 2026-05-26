#!/usr/bin/env bash
# Quick provider-status check. Returns HTTP code + first few words of body
# for both tunnels. Use this any time to see who's online.

set -uo pipefail

for host in m4.streamvc.live m1.streamvc.live; do
  code=$(curl -sS -o /tmp/.macprovider-status -w "%{http_code}" --max-time 6 "https://${host}/v1/models" || echo "ERR")
  body=$(head -c 120 /tmp/.macprovider-status 2>/dev/null | tr '\n' ' ')
  case "$code" in
    200) status="ONLINE" ;;
    502) status="OFFLINE (mac asleep — tunnel up, mlx down)" ;;
    530) status="OFFLINE (no cloudflared origin)" ;;
    000|ERR) status="UNREACHABLE" ;;
    *)   status="UNEXPECTED (HTTP $code)" ;;
  esac
  printf "%-22s  %-30s  %s\n" "$host" "$status" "${body:0:80}"
done
rm -f /tmp/.macprovider-status
