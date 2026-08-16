## Lane: CODE — Round 3

## Context

R2 three-lane audit returned: CODE 0/2/1/1/1, SEC 0/2/2/1/1, ARCH 0/0/3/2/0.

R2 fix-pass landed as commit `102d4f1` on branch `fix/iss244-deploy-pearl-tls-safety` in `/Users/augstar/macprovider-iss244/`. The big changes:

1. **Three-state classification**: HAVE / RENEW / MISSING (per domain), with a `vhost=0|1` flag. Stub install gated to `DOMAINS_NEED_STUB = MISSING ∩ vhost=0`. RENEW domains keep their existing TLS vhost — a certbot failure leaves the soon-expiring cert serving instead of an HTTP-only stub.
2. **No `declare -A`**: replaced associative array with regular array `_seen=()` + linear scan, for bash 3.2 compatibility (macOS default).
3. **Validate `tier2.catalog_path`** against strict pattern before flowing into single-quoted SSH commands.
4. **Missing `openssl` on remote is FATAL** (no silent file-presence fallback). step 2 also apt-installs openssl explicitly.
5. **Stricter parser**: `read -r status domain vhost extra` rejects malformed lines with extra fields.
6. **Pre-upload assertion** extended to verify `server_name` + `/etc/letsencrypt/live/<d>/` paths in templates.
7. **STATS_DOMAIN/STATS_REQUIRED/etc.** documented in usage header.
8. **bash 3.2 + `set -u` compat**: every `"${arr[@]}"` empty-array expansion replaced with `${arr[@]+"${arr[@]}"}` guard.

## Your job

CODE LANE round 3. Re-audit the full file with the same critical eye. Check:

- Did R2's bash 3.2 guards actually plug all the empty-array hazards? Are there still references that crash under `set -u` on bash 3.2?
- Is the new three-state classification correctly threaded through the script (step 5 / step 6 / step 6b)?
- Is the strict parser handling of `read -r` and the `<<<` heredoc-string syntax correct on bash 3.2?
- The remote probe heredoc `<<'REMOTE_PROBE'` — does it correctly preserve `$@` semantics under `bash -s -- '$DOMAIN' '$STATS_DOMAIN'`?
- The catalog_path validator — is the regex tight enough? Any bypass via Unicode / control chars / odd path separators?
- Any new regression introduced by the R2 changes?

Produce findings in the standard severity-graded format. If no findings at a severity, write "(none)".

## Files in scope

- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-stats.malibu.tech.conf`

R2→R3 diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`
R0→R3 cumulative diff: `git -C /Users/augstar/macprovider-iss244 diff HEAD~3 HEAD`
