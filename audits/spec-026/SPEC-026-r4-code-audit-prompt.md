# SPEC-026 R4 — CODE audit lane

You are re-auditing SPEC-026 v0.4 after the R3 rewrite. Read
`specs/SPEC-026-r1-audit.md`, `specs/SPEC-026-r2-audit.md`, and
`specs/SPEC-026-r3-audit.md` first — they list what R1/R2/R3
already surfaced and how each version resolved. Do NOT re-flag
anything already fixed.

Your lens is CODE: correctness of citations, buildability of the
proposed Swift/Go surface, consistency with the working tree at
HEAD of `feat/onboarding-v2-provider-identity` (worktree
`/Users/augstar/macprovider-onboarding-v2`).

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.4)
- `beta/DECISION_CRITERIA.md` Entry 102 (updated to v0.4)

## What to check in R4

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO. Skip anything
already covered by R1-R3.

1. **§4.3 corrected frame shape.** Verify:
   - `type: "auth_request", stage: "proof"` matches what
     SPEC-001 v1.6 §6.7 says (grep the actual SPEC-001 file).
   - `provider_ecdh_public_key` is the right field name (not
     `ecdh_pubkey`).
   - Existing Swift proof frame at `CoordinatorClient.swift:1152-1157`
     (per R3) actually uses the type/stage combo the spec now
     matches.
2. **§4.3 provider_auth_policy table.** New table introduced.
   Verify:
   - SQL syntax is correct for Postgres (the coordinator's DB).
   - No naming collision with any existing coordinator table.
3. **§4.3 CLI-track receipt-key lookup helper.** The spec now
   says the impl PR MUST add a helper like
   `phase4-coordinator/internal/receipts.LookupCurrentPubKey(providerID)`.
   Grep the tree for anything close — if there's already an
   equivalent, the spec should name it precisely.
4. **§4.5 `POST /notification-channel` endpoint.** New API.
   Verify:
   - Request/response schemas are Swift + Go implementable.
   - `action` enum uses reasonable values.
   - The identity_signature over `JCS(body \ signature)` follows
     the same pattern as `/register`.
5. **§4.6 `GET /wallet-swap/cancel`.** New API. Verify:
   - HMAC-SHA256 primitive is standard-library available in both
     Swift and Go.
   - URL parameter encoding is unambiguous (`sig` as hex vs
     base64).
6. **§5.1 `provider_rewards_ledger` extension.** Verify the
   migration path is idempotent and the ledger's existing
   consumer code doesn't break when `amount_malibu` is null.
7. **§5.1 SERIALIZABLE isolation.** Verify Postgres's
   `SET TRANSACTION ISOLATION LEVEL SERIALIZABLE` behavior + the
   40001 retry loop shape.
8. **§7.3 `PendingLinkStateTests.swift` path unchanged from v0.3.**
   Re-verify against the actual tree.
9. **§7.6 launch gate.** v0.4 restored `ProviderConfig.isConfigured`
   as the sole gate. Verify: identity-only state cannot reach
   `MalibuAgent.start()`. Any code path that COULD run
   `MalibuAgent.start()` before onboarding completes?
10. **§8.4 import/migration dialog.** New section. Verify:
    - The `.malibu-owned` marker file naming matches what
      `ProviderConfig` actually uses.
    - The `config.yaml.cli-backup-<timestamp>` rename doesn't
      break any expected CLI-track behavior.
11. **§10 checklist step 1** enumerates v0.4 migrations. Verify
    the dependency chain (each migration can run without
    prerequisite gaps).
12. **Entry 102 update.** Verify it accurately summarizes v0.4
    (not v0.3).

## Output format

```
Severity: CRITICAL | HIGH | MEDIUM | LOW | INFO
Where: <file:line or spec §>
Claim: <one-line summary>
Evidence: <what you found>
Fix: <concrete change>
```

End:

```
TOTALS: C=<n> H=<n> M=<n> L=<n> I=<n>
```

Merge gate: **0 CRITICAL, 0 HIGH, 0 MEDIUM**.
