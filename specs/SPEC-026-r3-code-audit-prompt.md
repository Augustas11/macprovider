# SPEC-026 R3 — CODE audit lane

You are re-auditing SPEC-026 v0.3 after the R2 rewrite. Read
`specs/SPEC-026-r1-audit.md` and `specs/SPEC-026-r2-audit.md` first
— they list what R1 and R2 already surfaced and how v0.2 / v0.3
resolved each. Do NOT re-flag anything already fixed.

Your lens is CODE: correctness of citations, buildability of the
proposed Swift/Go surface, and consistency with the actual working
tree at HEAD of `feat/onboarding-v2-provider-identity` (worktree
`/Users/augstar/macprovider-onboarding-v2`).

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.3)
- `beta/DECISION_CRITERIA.md` Entry 102

## What to check in R3

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO.

1. **§4.1 step 7 rewrite (rotate-on-duplicate model).** Verify:
   - `phase4-coordinator/internal/auth/tokens.go:248-257`
     actually has the columns SPEC-026 references
     (`token_hash`, `token_prefix`, `provider_id`, `created_at`,
     `revoked_at`, `last_used_at`).
   - The rotate-on-duplicate flow is atomic (SELECT ... FOR UPDATE
     is claimed) and Postgres-safe.
2. **§4.3 rewrite — proof-stage `identity_signature`.** Verify:
   - SPEC-001 v1.6 §6.7 actually has an `auth_proof` frame (or
     analogous proof-stage frame) that the client sends after
     receiving `auth_challenge`. If the frame name in SPEC-001 is
     different (e.g. `auth_response`), flag as MEDIUM.
   - Field names `provider_ecdh_public_key` and `auth_attempt_id`
     match what SPEC-001 v1.6 uses.
3. **§3.3 base32 encoding claim.** Verify Go stdlib
   `encoding/base32.NewEncoding` supports a custom alphabet
   (it does) and that `WithPadding(base32.NoPadding)` exists (it
   does). Note if Swift's Foundation base32 gap is accurately
   described.
4. **§5.1 enforcement primitives.** The spec introduces two
   schema changes (`withdrawal_hold_reason` column + a
   `wallet_daily_malibu_emission` aggregate table). Verify:
   - The reward-emission ledger name is left generic
     ("whichever reward-emission ledger table the coordinator
     writes MALIBU emissions to"). Does such a table already
     exist in the coordinator source? If not, the spec should
     probably say "if one exists; if not, the implementing PR
     creates one." If it exists at a specific path, spec should
     name it.
   - The `wallet_daily_malibu_emission` `PRIMARY KEY(bound_wallet,
     emission_day)` composite key is deadlock-safe under
     concurrent inserts.
5. **§7.3 test file path.** `phase3-binary/app/Tests/MalibuTests/PendingLinkStateTests.swift`
   should exist at that path in the tree. Verify.
6. **§7.6 launch gate.** Verify the reverted "unchanged gate"
   claim is coherent with §8.1 matrix — the v2-partial state must
   NOT reach `MalibuAgent.start()`, and the spec should be
   consistent about that.
7. **§8.1 CLI-owned config, no App marker row.** Verify:
   - `ProviderConfig.saveProviderIdentity` at
     `ProviderConfig.swift:69-72` actually throws
     `existingConfigNotOwnedByApp` — matching the finding CODE-M5
     R2.
   - SPEC-025 §3.4 actually documents the import/migration dialog
     the spec now references. If SPEC-025 doesn't have that, the
     row is aspirational.
8. **§2 receipt-key generation citation.** Verify
   `ReceiptKeyStore.swift:41` is a `Curve25519.Signing.PrivateKey()`
   call and not something else.
9. **§9.1 earnings endpoint alignment.** Verify SPEC-005 §11.4
   actually defines `GET /providers/{provider_id}/earnings` with
   the bearer-token subject-equals-{id} auth model. If it doesn't,
   the alignment claim is wrong.
10. **§9.3 `POST /v1/providers/{id}/notification-channel` and
    the HMAC cancel URL.** Both are new API surface introduced by
    §9.3. Are they enumerated anywhere in the API section §4?
    Nope — §4 lists only `/register`. This is a coverage gap —
    the new endpoints should be in §4.
11. **CLI-track `receipt_pubkey` claim (§4.3).** The spec says
    coordinator validates the CLI-track proof-stage
    `identity_signature` "against `receipt_pubkey` from
    `phase4-coordinator/internal/receipts/keys.go`." Verify this
    file exists and holds a `receipt_pubkey` lookup helper. If
    not, the claim is aspirational.

## Output format

For each finding:

```
Severity: CRITICAL | HIGH | MEDIUM | LOW | INFO
Where: <file:line or spec §>
Claim: <one-line summary>
Evidence: <what you found in the working tree>
Fix: <concrete change>
```

End with:

```
TOTALS: C=<n> H=<n> M=<n> L=<n> I=<n>
```

Merge gate: **0 CRITICAL, 0 HIGH, 0 MEDIUM**.
