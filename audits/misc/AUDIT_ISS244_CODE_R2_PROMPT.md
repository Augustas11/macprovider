## Lane: CODE — Round 2

## Context

R1 three-lane codex audit returned 0 CRITICAL across all lanes, 1 HIGH on CODE (primary-failure exit-9 unreachable), 2 MEDIUM, 1 LOW.

R1 fix-pass landed as commit `592989b` on branch `fix/iss244-deploy-pearl-tls-safety` in worktree `/Users/augstar/macprovider-iss244/`. Changes:

1. Moved primary-failure exit-9 block immediately after step 6b (before step 6c/7/8).
2. Validate DOMAIN/STATS_DOMAIN/EMAIL up-front against strict DNS-name / email regexes.
3. Refuse if DOMAIN/STATS_DOMAIN env overrides don't match the baked-in vhost templates.
4. Strengthened HAVE classification: fullchain.pem + privkey.pem present + `openssl x509 -checkend 86400` valid.
5. Strict HAVE/NEED parser: every expected domain must produce exactly one HAVE/NEED line; pass domains as positional args via `bash -s -- "$DOMAIN" "$STATS_DOMAIN"` with single-quoted remote heredoc.
6. Replaced defensive sed with pre-upload assertion on dist/ confs (refuses deploy unless `ssl_certificate /etc/letsencrypt` is uncommented).
7. Added `STATS_REQUIRED=1` opt-in: when set, any non-primary cert failure becomes fail-closed exit-9. Default WARN-only.
8. Empty failed-domain loop fix: `"${DOMAINS_ISSUED_FAIL[@]}"` (no `:-}` default).

## Your job

CODE LANE round 2: re-audit the script as a whole now that R1 changes have layered in. Look for:

- New bash correctness regressions introduced by the fix-pass (quoting, expansion, escaping, here-doc edges, `set -e` interactions, array handling).
- Did the move of the exit-9 block correctly preserve the flow? Any path where step 6c/7/8 still runs even though we wanted to fail closed?
- Is the new bash heredoc `<<'REMOTE_PROBE'` … `REMOTE_PROBE` correctly quoted? Does the `bash -s -- '$DOMAIN' '$STATS_DOMAIN'` interpolation respect quotes?
- Is the openssl check on the remote correctly handled when openssl is absent (the `have_openssl=0` branch)?
- Is the strict-parser logic correct? Does it handle the case where the remote produces lines for ONLY one of two domains (missing-coverage), or extra lines (unexpected-domain)?
- Are the new validation regexes (DNS name, email) too strict / too loose for the operational inputs?

Re-read the FULL file. Produce findings in this format:

```
CRITICAL: <title>
  file:line — <problem>
  why it matters: <one sentence>
  suggested fix: <one to two sentences>

HIGH: <...>
MEDIUM: <...>
LOW: <...>
INFO: <...>
```

If a severity has no findings, write "(none)".

## Files in scope

- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-stats.streamvc.live.conf`

R1→R2 diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`
R0→R2 cumulative diff: `git -C /Users/augstar/macprovider-iss244 diff HEAD~2 HEAD`
