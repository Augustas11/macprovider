# Audit R3 — BYOM v0.2 slice 2b-ii: full combined diff (release assets + coordinator deploy + scheduled renewal + R2 fixes)

**Diff reviewed:** eight commits on main `bd2fc510`.
**Merge bar:** 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three lanes.

## R3 verdicts

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW / 1 INFO |
| security-reviewer | 0 CRITICAL / 0 HIGH / 1 MEDIUM / 0 LOW / 1 INFO |
| architect | **0 CRITICAL / 0 HIGH / 0 MEDIUM** / 1 LOW / 2 INFO |

Every R1 and R2 resolution was verified. All three remaining items are in
the renewal script added by the deploy/renewal half; resolved in the commit
that adds this record:

- **MEDIUM (code):** staging assembled the artifact pair when the generated
  feed file happened to exist, not from `release.json`. Now the freshly
  generated `release.json` is the only authority: bound requires and stages
  both files; unbound rejects either stray file.
- **MEDIUM (security):** the post-activation fetch interpolated
  `REMOTE_AUTOTUNE_DIR` into an SSH command before the deploy section's
  safe-path allowlist. The allowlist now runs immediately after the variable
  is defined, before any remote use; the structural test pins the order.
- **LOW (architect):** a post-activation dry-run contacted Pearl for the
  previous release. The fetch is now gated on `--deploy`; a dry-run without
  `AUTOTUNE_PREVIOUS_RELEASE_DIR` fails closed with guidance and makes no
  contact.
- **INFO (code, architect):** `cmd_status` docstring and the runbook heading
  said the surfaces were still pending; both now describe the landed state.
- **INFO (code, security, architect):** the workflow shell, deploy transport
  seam, and renewal fetch are covered structurally (validators are executed);
  carried as documented coverage boundary.

R4 re-fires the code and security lanes only.
