## Lane: SECURITY — Round 2

## Context

R1 three-lane codex audit returned 0 CRITICAL across all lanes, 2 HIGH on SEC (unquoted DOMAIN/EMAIL into SSH; unreachable primary cert failure guard), 3 MEDIUM, 1 LOW.

R1 fix-pass landed as commit `592989b` on branch `fix/iss244-deploy-pearl-tls-safety`. Changes:

1. **DOMAIN/STATS_DOMAIN/EMAIL validation at script startup.** Strict DNS-name regex `^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[...])+$` and a basic email regex.
2. **DOMAIN/STATS_DOMAIN override is refused** if it doesn't equal the baked-in template hostname.
3. **HAVE check** now requires fullchain.pem + privkey.pem present + `openssl x509 -checkend 86400` valid.
4. **HAVE/NEED parser** is strict: malformed line / unknown domain / duplicate / missing → fail closed.
5. **Remote probe** uses `bash -s -- '$DOMAIN' '$STATS_DOMAIN'` with single-quoted remote heredoc.
6. **Pre-upload assertion** refuses deploy unless dist/ confs ship `ssl_certificate /etc/letsencrypt` UNCOMMENTED. Defensive sed removed.
7. **Primary-failure exit-9** moved immediately after step 6b (before 6c/7/8).
8. **STATS_REQUIRED=1** opt-in promotes non-primary failure to fail-closed.

## Your job

SECURITY LANE round 2: re-audit the full attack surface now that the R1 fix-pass has layered in. Look for:

- Did the input validators close the injection vectors, or are there bypasses (e.g., the regex permits `evil.example` followed by metacharacters)?
- Does the `bash -s -- '$DOMAIN' '$STATS_DOMAIN'` invocation correctly defend against injection given that the values are already validated?
- The `STATS_REQUIRED=1` knob — does its default-WARN-only behavior expose a money-path-adjacent failure mode that auditors should still flag?
- The pre-upload conf assertion — does it actually prevent a malicious local edit, or can the operator be tricked into running with a poisoned dist/ conf?
- New attack surface in the R1 fix that wasn't there before (e.g., the remote heredoc, the openssl check, the strict-parser exit paths).
- TLS posture downgrades, ACME stub abuse, certbot misconfiguration, secret leakage.

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
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`
- `/Users/augstar/macprovider-iss244/phase4-coordinator/dist/nginx-stats.malibu.tech.conf`

R1→R2 diff: `git -C /Users/augstar/macprovider-iss244 show HEAD`
R0→R2 cumulative diff: `git -C /Users/augstar/macprovider-iss244 diff HEAD~2 HEAD`
