# Issue #82 item 3 — coordinator-cli pre-flip-audit — SECURITY-lane audit

You are the **security** lane of a three-lane audit of #82 item 3.
This lane is the primary stakeholder for the FR-C9.4 flag-flip
gate — your verdict on whether the audit command actually closes
the credential-capture surface is the load-bearing security check.

## Why security cares

SPEC-003 FR-C9.4 closes a credential-capture vector: under
`RequireProviderTokens=true`, a tokenless connect claiming
victim provider_id MUST be rejected. But the FLIP itself is
security-sensitive — if the operator flips while an attacker
already holds a token (or before a legitimate provider has
proved possession via `last_used_at`), the post-flip state
inherits the unverified bearer.

The new `coordinator-cli pre-flip-audit` is the executable gate
that the FR-C9.4 runbook had only as prose. Its correctness
under attacker conditions is what matters.

## Branch / commit

- Branch: `fix/coordinator-cli-pre-flip-audit`
- Worktree: `../macprovider-82-item3-preflip` (origin/main base: 5a233bc)
- Files in scope (`git diff origin/main`).

## Security-lane scope (apply each; stay in lane)

### SEC-1. Does the audit catch every credential-capture path?
- The audit flags:
  - Active row with `last_used_at IS NULL` (provider never
    authenticated with Bearer → operator MUST reconnect or
    revoke before flip).
  - Active row with stale `last_used_at` older than cutoff
    (provider not recently active → might be a captured
    credential, might be a legitimate provider that went
    offline; operator decides).
- It does NOT flag:
  - Revoked rows (correctly — they can't authenticate).
- Is there a category the audit misses? For instance, a row
  with `last_used_at` set to a FUTURE timestamp (clock skew
  attack)? The lex `<` compare would not flag a future-dated
  row as stale. Is this an exploitable gap?

### SEC-2. Lex comparison safety
- Timestamp comparison uses `r.LastUsedAt.String < cutoffStr`.
  If a malicious actor can write to the DB with a non-canonical
  format (e.g. "Z" missing, microsecond precision, +00:00
  instead of Z), the lex compare could either:
  - False-pass (looks fresh because lex-sorts late)
  - False-fail (looks stale because lex-sorts early)
- BUT the DB writes go through `nowString()` (UTC RFC3339Z), so
  the format invariant is server-enforced. Confirm no other
  code path writes to `last_used_at` with a different format.

### SEC-3. Default safety
- `--max-last-used-age` defaults to 24h. SPEC-003 §FR-C9.4
  runbook recommends 24h. Is the default conservative enough?
- A 24h cutoff means a legitimate provider that went offline
  21h ago would still pass — possibly bearer captured during
  those 21h could still authenticate. Tightening to 1h would
  catch more, but break operators with longer settling
  windows. Audit verdict: is 24h the right default, or should
  the SPEC say "operators SHOULD use the shortest tolerable
  cutoff"?

### SEC-4. Output disclosure surface
- The audit prints `token_prefix`, `provider_id`,
  `provider_name`, `created_at`, `last_used_at`, `reason`.
  Token PREFIX is not the full token (only the first ~12
  chars per `IssueToken`). Confirm this matches the existing
  `list-tokens` disclosure surface (no new credential
  leakage).
- Operator-facing output → assumed to be in a trusted
  context (the operator's shell). Acceptable disclosure?

### SEC-5. Race conditions
- The audit lists rows then exits — no transactional snapshot.
  If a provider authenticates DURING the audit run, the row's
  `last_used_at` could update mid-loop. Worst case: a flagged
  row's status changes after the audit prints "stale" but the
  operator reads it as stale. Acceptable (operator can rerun).
- Conversely, a row could be revoked mid-loop. Also acceptable
  (operator can rerun).

### SEC-6. SPEC v0.10.1 normative strength
- The change log says the gate is "normatively required". The
  prose says "Operators MUST integrate this command into the
  deploy pipeline". Is MUST the right level vs SHOULD? The
  existing v0.8.4 runbook used MUST for the underlying check.
  Confirm.

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence fix>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Write to `specs/82_ITEM3_SECURITY_audit.md`. If 0 CRITICAL/HIGH/
MEDIUM AND the credential-capture closure is sound, end with:
`VERDICT: security lane READY TO MERGE`
