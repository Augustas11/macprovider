# Audit prompt — #1749 operator-constrained privacy class (SPEC-049 v0.1.0)

METHOD CONSTRAINT (read first): this is a first-party software-correctness and
proof review of our own code. Do NOT author or construct malformed payloads,
exploit code, or attack tooling. Evaluate by reading source and running the
EXISTING tests only. Describe any gap abstractly (component, field, condition)
in prose.

## Scope

Repository worktree: `/Users/augstar/macprovider-privacy-1749`, branch
`feat/1749-privacy-class-runtime`. Review the complete change as it will land:

```bash
git -C /Users/augstar/macprovider-privacy-1749 diff origin/main...HEAD
git -C /Users/augstar/macprovider-privacy-1749 diff HEAD   # any uncommitted remainder
```

Normative authority, in order: `specs/SPEC-049-operator-constrained-privacy-class.md`,
`specs/SPEC-041-relay-blind-request-encryption.md` (v0.3.0), `AGENTS.md`.
Journey: `journeys/JOURNEY-PRIVACY-CLASS-BETA.md`. Runbook:
`docs/runbooks/privacy-class-beta-operations.md`.

The feature is default-off at every component (provider flag, coordinator
`privacy_class.enabled`, gateway `features.privacy_class`, buyer client
`--privacy-class`). No production config is changed.

Surfaces:
- Shared Go crypto/types: `phase4-coordinator/internal/relayblind/privacy.go`
  (byte-identical copy in `phase5-gateway/internal/relayblind/`), `types.go`.
- Coordinator: `internal/relayblind/privacy_authority.go`, `store.go`,
  `internal/ws/privacy_posture.go`, `messages.go`, `server.go`, `relay.go`,
  `internal/buyer/privacy_class.go`, `relay_blind.go`, `server.go`,
  `internal/config/config.go`, `cmd/coordinator-cli/privacy_class.go`,
  `cmd/coordinator/main.go`.
- Gateway: `internal/router/privacy_class.go`, `relay_blind*.go`,
  `chat_proxy.go`, `disclosure.go`, `server.go`, `internal/config/config.go`,
  `cmd/relay-blind-client/main.go`.
- Provider (Swift): `PrivacyClass.swift`, `PrivacyRuntimeHardening.swift`,
  `PrivacyPostureResponder.swift`, `PrivacyClassIdentityCommand.swift`,
  `InferenceRelay.swift`, `RelayBlindProvider.swift`, `CoordinatorClient.swift`,
  `HTTPServer.swift`, `KVDiskTier.swift`, `ModelRuntime.swift`,
  `MacProviderCLI.swift`, `Config.swift`, `RelayBlindFixtureCommand.swift`.
- Tests and fixtures: `test/integration/privacy_class_integration_test.go`,
  `swift_relay_provider_test.go`, `harness_test.go`,
  `test/fixtures/relay-blind/privacy-*.json`, and the unit tests next to each file.
- Governance: `specs/AUTHORITY.json`, `specs/CONFORMANCE.json` (SPEC-049
  requirements stay `pending`), `specs/README.md`.

Known and documented limitation (do not report as a finding unless the code
or docs overclaim it): the Secure Enclave key is device-bound, not code-bound,
so a patched provider binary on the same Mac could sign a false posture. The
assurance label is `device_bound_self_attested_beta`; SPEC-049 §2.5 and the
runbook residual-risk table disclose it.

Useful existing tests (run what you need):

```bash
cd phase4-coordinator && go test ./internal/relayblind/... ./internal/ws/... ./internal/buyer/... ./internal/config/... ./cmd/coordinator-cli/... -count=1
cd phase5-gateway && go test ./internal/relayblind/... ./internal/router/... ./internal/config/... ./cmd/relay-blind-client/... -count=1
cd test/integration && go test -run 'TestPrivacyClass|TestRelayBlind' -race -count=1 -timeout 30m
cd phase3-binary && swift test --filter 'Privacy'
bash scripts/test-relay-blind-parity.sh
python3 scripts/check_spec_governance.py --base-ref origin/main
```

## Lane

CODE lane: correctness against SPEC-049 and SPEC-041; every MUST in SPEC-049 R001-R023 is implemented where CONFORMANCE.json maps it; error-code inventory and HTTP status parity between coordinator, gateway, fixture and buyer client; frame-sequence, final-frame and truncation handling; reservation/consume/dispatch state transitions, quota refunds and at-most-once journal; config validation bounds and defaults; Swift/Go byte parity of framing, HKDF labels, AAD and nonce construction; test adequacy (no skipped, stubbed or tautological tests; adversarial subtests assert the right code and dispatch count); regressions to plain SPEC-041 relay-blind and plaintext paths when the feature is off.

## Output

List findings ordered by severity, each with: severity (CRITICAL / HIGH /
MEDIUM / LOW / INFO), `file:line`, the defect, the concrete condition that
triggers it, and a fix direction. Attribute each finding as NEW (introduced by
this diff) or PRE-EXISTING. Gate: 0 CRITICAL, 0 HIGH, 0 MEDIUM.

End with exactly one line:
`VERDICT: <n> CRITICAL / <n> HIGH / <n> MEDIUM / <n> LOW / <n> INFO`

## Round 2 addendum

Round 1 findings, fixed in commit 49d2c4ee8 (`git show 49d2c4ee8`):
1. HIGH (code): PersistEvidence dropped provider-bound privacy rejections (privacy_class_posture_stale, privacy_class_downgrade_rejected). Fix: they are accepted for privacy reservations only, the ws validation gate admits them for privacy dispatches only, and the buyer returns the typed privacy error with a quota refund.
2. MEDIUM (security): quarantine and privacy-key revocation were not atomic. Fix: Store.QuarantineAndRevokePrivacy does it in one transaction. The in-memory posture invalidation runs even if the transaction fails.
3. LOW (security): kill switch and held-reservation rejection were not atomic. Fix: Store.DisablePrivacyAndRejectPredispatch.
4. LOW (security): the coordinator chat endpoint returned relay_blind_envelope_invalid for a privacy header on a plaintext body or an invalid header value. Fix: it now returns privacy_class_downgrade_rejected before parse, quota and dispatch.
5. LOW (architect): key_class was mutable on the shared (provider_id,kid) row. Fix: a cross-class re-advertisement is rejected, and revocation is scoped by key class and reservation privacy flag.

Verify that each fix closes its finding without regression. Then re-review the complete diff (`git diff origin/main...HEAD`) for your lane. Report only open findings.
