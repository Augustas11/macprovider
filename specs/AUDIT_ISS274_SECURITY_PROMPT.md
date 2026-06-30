# AUDIT — Issue #274 — SECURITY lane

## Goal
Adversarial security audit on PR-pending commit `0e4dce2` (branch `fix/iss274-provider-id-validator`). Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW + INFO allowed.

## Scope

- `phase4-coordinator/internal/config/config.go` — `ValidateProviderID`
- `phase4-coordinator/internal/ws/messages.go` — ParseHello, parseAuthInitial, parseAuthProof
- `phase4-coordinator/internal/auth/tokens.go` — IssueToken, MintAdmissionTokenAndPairOT
- Test files for the three packages

## Threat model

This fix closes a validator-drift gap surfaced by #266 Tranche 3 codex security review. The trust boundary:

- `pool.Provider.SortKey()` returns `ProviderID + "/" + AssignedID` and is used as a map key for routing decisions (excluded set, balanced-score cache, faulted-route tracking)
- A hostile or buggy provider that connects via WS self-serve could pre-#274 submit `provider_id: "a/b"` which registered without validation
- With `AssignedID = c` the SortKey becomes `"a/b/c"` — ambiguous with a legitimate `(provider_id=a, assigned_id=b/c)` if such a value could exist

Current AssignedID values are coordinator-issued UUIDs, so a practical collision is not exploitable today — but the validator drift was real and the fix consolidates the gate at all entry points.

## Lens — SECURITY

Audit for:

- **Bypass paths** — is there any code path that mints a provider_id without going through `ValidateProviderID`? Specifically check:
  - WS message types beyond Hello + auth_request that carry a `provider_id` field (heartbeat, state_update, etc.) — do they trust an earlier-validated value or re-accept new strings?
  - Database / storage paths that read a `provider_id` from disk and trust it without re-validating
  - Any test-only or admin-only paths (coordinator-cli, admin endpoints) that mint tokens
- **TOCTOU / race conditions** — pre-validation race between Hello and auth_request where one frame passes but the other holds a different value
- **Injection** — even with the regex `^[a-zA-Z0-9_.-]{1,64}$` are there any downstream contexts (SQL, log emission, file paths, URL paths) where a `.` or `-` could be misinterpreted?
- **Length / DoS** — the 64-char cap is enforced everywhere?
- **Error leakage** — does the `fmt.Errorf("invalid provider_id %q", s)` error message leak the attacker-controlled string into logs in a way that could enable log-injection or terminal-CSI sequences? (Note: the regex itself rejects control chars and `\n`, so the `%q` quote is belt-and-braces — but verify.)
- **Test gaps** — does the test suite cover boundary cases the regex might mishandle (Unicode, RTL, zero-width, byte-vs-rune-length)?
- **Audit trail** — when a provider_id is rejected, is the rejection visible to operators (audit log / metric / counter) so a hostile provider hammering the gate is observable?

## Specific must-check items

1. Does `parseAuthRequest` validate provider_id in BOTH `initial` and `proof` stages? (the fix claims yes — verify)
2. Does the `coordinator-cli/main.go` IssueToken call site flow through the new gate? (it should — it calls `store.IssueToken`)
3. Is there any provisional/legacy registration path that the issue body didn't enumerate?

## Out of scope

- Code style and refactor cleanliness (CODE lane)
- SPEC alignment (ARCHITECT lane)

## Output format

```
SEVERITY-N (CRITICAL|HIGH|MEDIUM|LOW|INFO) — <one-line title>
File: <path>:<line>
Finding: <what>
Risk: <why it matters; cite threat model>
Recommendation: <concrete fix>
```

Summarize at the end: `C/H/M/L/INFO = a/b/c/d/e`.

If nothing above LOW: `ACCEPT — 0 C/H/M`.
