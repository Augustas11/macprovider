# SPEC-026 R2 — CODE audit lane

You are re-auditing SPEC-026 v0.2 after the R1 rewrite. Read
`specs/SPEC-026-r1-audit.md` first for the R1 findings and the v0.2
dispositions — do NOT re-flag anything R1 already surfaced unless
v0.2 handled it wrong.

Your lens is CODE: whether v0.2's normative statements about existing
sources are technically correct, whether the proposed code shape is
buildable, and whether the invariants v0.2 claims hold in the
referenced files.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.2)
- `beta/DECISION_CRITERIA.md` Entry 102 (updated)

## Cross-reference sources (READ, do not modify)

Every path:line reference in the spec must be verified against the
working tree at HEAD of `feat/onboarding-v2-provider-identity`:

- `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift:226`
- `phase3-binary/Sources/MacProviderCore/ProviderTokenPersist.swift:42-113`
- `phase3-binary/app/Sources/Malibu/System/ProviderConfig.swift:63-99`
- `phase3-binary/app/Sources/Malibu/Agent/MalibuAgent.swift:46-50`, `:62-66`
- `phase3-binary/app/Sources/Malibu/System/PendingLinkState.swift`
- `phase3-binary/app/Sources/Malibu/MalibuApp.swift:37-45`, `:107-125`, `:163`
- `phase3-binary/app/Sources/Malibu/Onboarding/OnboardingWindow.swift:55`
- `phase3-binary/app/Tests/PendingLinkStateTests.swift`
- `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift`
- `phase4-coordinator/internal/billing/CanonicalJSON` (or similar)
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:1224-1239`
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:429-449`
- Adjacent SPECs: `specs/SPEC-001-phase3-binary.md`,
  `specs/SPEC-003-open-onboarding.md`,
  `specs/SPEC-015-receipts.md`,
  `specs/SPEC-016-payout-pipeline.md`,
  `specs/SPEC-022-verified-model-settlement.md`,
  `specs/SPEC-023-installer-autotune-recommend.md`,
  `specs/SPEC-025-native-mac-app.md`.

## What to check in R2

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO. Do not re-report
R1 findings — flag ONLY:

1. **Regressions.** v0.2 restructured many sections; check that
   nothing R1 said was fine is now broken.
2. **Citation drift.** Every path:line the spec cites must resolve
   correctly in the current tree.
3. **Buildable Swift shape (v0.2 §7.1, §7.2).**
   - `Curve25519.Signing.PrivateKey().publicKey.rawRepresentation`
     matches CryptoKit surface.
   - `@MainActor` + `async` interactions in `LaunchProviderController`
     are coherent.
   - Keychain attributes match a real `SecItemAdd` shape (`kSecClass`
     + `kSecAttrService` + `kSecAttrAccount` + `kSecAttrAccessible`
     are the standard four for `kSecClassGenericPassword`).
4. **provider_id base32 encoding (§3.3).** 32-byte SHA-256 → 52 chars
   no-pad in the pinned alphabet. Both Swift and Go implementations
   have compatible primitives — grep for them, or if you can't
   find one, flag as MEDIUM.
5. **JCS parity fixture path (§4.1, §10 step 2, AC-026-13).** The
   fixture at
   `phase4-coordinator/test/jcs_fixtures/spec026_register.json`
   doesn't exist yet; the spec says implementation PR MUST create it.
   Verify the spec's claim about JCS libraries in both languages
   (Swift `RFC8785JCS.swift`, Go `billing.CanonicalJSON` or
   equivalent) — do those symbols actually exist?
6. **`PendingLinkState` removal completeness (§7.3).** For each
   enumerated call site, verify the file:line still points at the
   claimed call. If a call site has drifted (e.g. line number
   changed), that's MEDIUM.
7. **Launch-gate composition (§7.6).** The `||` composition of
   `ProviderIdentity.isReady()` OR `ProviderConfig.isConfigured` —
   any subtle failure mode (e.g. token in Keychain but revoked; both
   are true and start races)?
8. **Migration matrix (§8.1) completeness.** Are the four state cells
   actually all the states an install can be in? Any transition v0.2
   missed?
9. **Coordinator new HTTP token-issuance primitive (§4.1 step 7).**
   The spec now says the primitive is at
   `phase4-coordinator/internal/onboarding/apptrack.go`. That file
   doesn't exist yet — implementation PR territory. Check the spec's
   claim about `provider_tokens` schema constraints
   (one-active-token, state `ACTIVE`/`USED`/`REVOKED`) matches what
   SPEC-003 §FR-C9 actually defines.
10. **Deploy checklist ordering (§10) coherence.** Any hidden
    ordering dependency the numbered list gets wrong?

## Output format

For each finding:

```
Severity: CRITICAL | HIGH | MEDIUM | LOW | INFO
Where: <file:line or spec §>
Claim: <one-line summary>
Evidence: <what you found in the working tree>
Fix: <concrete change to spec text OR to a cited file>
```

End with:

```
TOTALS: C=<n> H=<n> M=<n> L=<n> I=<n>
```

The merge gate is **0 CRITICAL, 0 HIGH, 0 MEDIUM**. LOW / INFO ship
with a PR-body callout.
