# M2-1e forwardWithFailover core — SECURITY-lane R3 (post-commit re-verify)

You are the **security** lane, round 3. r1 + r2 both verdict-line'd
`READY TO MERGE` with 0 C/H/M. Since r2, the fix-pass:
1. Staged the previously-untracked `forward_with_failover.go`.
2. Updated 2 doc comments to say "FOUR" intentional divergences.

Re-verify nothing security-relevant regressed on the committed state.

## Branch / commit
- Branch: `fix/m2-1e-forward-with-failover-core`
- Worktree: `../macprovider-m2-1e-forward-core`
- Read: `git log -1 --stat` and `git diff origin/main`

## Closure check

- No new money-path semantic change vs r2.
- No new cancelAttempt / shouldRetry / logAttempt / logProviderRow /
  failoverCandidate call site.
- No provider attribution surface change.

## Output format

```
NEW FINDINGS (r3):
CRITICAL (N): ...
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write to
`specs/M2_1E_FORWARD_CORE_SECURITY_r3_audit.md`.

If zero NEW C/H/M, end with:
`VERDICT: security lane READY TO MERGE`
