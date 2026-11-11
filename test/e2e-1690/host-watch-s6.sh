#!/usr/bin/env bash
# Host-side watcher: while the in-VM S6 has nginx returning 503 on the buyer
# routes, curl the VM's forwarded 443 from the Mac ("verify from outside
# Pearl", runbook s9 rollback step 1) and drop the result into the VM
# evidence. Exits when the in-VM driver reports ALL-PASSES-DONE.
set -uo pipefail
. "$(dirname "$0")/env.sh"
while ! vm "grep -q 'ALL-PASSES-DONE\|FATAL' /root/e2e/run-passes.out" 2>/dev/null; do
  if vm "test -f /etc/nginx/sites-available/api.malibu.tech.e2e-pre503" 2>/dev/null; then
    d="$(vm "ls -dt /root/e2e/evidence/p*-s6 | head -1")"
    if ! vm "test -s $d/outside-curl.done"; then
      code="$(curl -s -o /dev/null -w '%{http_code}' --resolve api.malibu.tech:28443:127.0.0.1 -k -X POST https://api.malibu.tech:28443/v1/chat/completions)"
      vm "echo 'host (outside Pearl) curl -X POST https://api.malibu.tech/v1/chat/completions -> $code' > $d/outside-curl.txt; echo 1 > $d/outside-curl.done"
      e2e_log "outside curl during nginx 503 ($d): $code"
    fi
  fi
  sleep 5
done
