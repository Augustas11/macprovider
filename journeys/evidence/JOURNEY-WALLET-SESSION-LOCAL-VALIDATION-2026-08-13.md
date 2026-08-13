# JOURNEY-WALLET-SESSION-LOCAL-VALIDATION-2026-08-13

Mapped SPECs: SPEC-040
Mapped authority domains: wallet-buyer-session, buyer-api-error-contract, billing-settlement-formula, verified-model-settlement
Issue: https://github.com/Augustas11/macprovider/issues/930
Status: local automated evidence captured; production rollout evidence not claimed

## Candidate

- Worktree: `/Users/augstar/macprovider-930-wallet-session`
- Branch: `feat/930-wallet-buyer-session`
- Base/current HEAD at capture start: `origin/main` / `b907cd7e`
- Feature state: local working tree implementation and tests, not deployed

## Validation Commands

- `go test ./... -count=1` from `phase5-gateway`
- `go test ./internal/storage/sqlite -run 'Wallet(Session|Registration|Reaper|Stale|Seal)' -count=1` from `phase5-gateway`
- `go test ./internal/router -run 'WalletSession|GatewayErrorCodeCompleteness' -count=1` from `phase5-gateway`
- `go test ./internal/config -run TestWalletSessionsRejectsPrefixAndSecretReuse -count=100` from `phase5-gateway`
- `bash ops/macprovider-watchdog/Scripts/test-ac-19-20-watchdog-recovery.sh`
- `python3 ops/pearl-updater/test_tier2_enforcement_watchdog.py`
- `python3 scripts/check_spec_governance.py`
- `python3 scripts/gen_spec_index.py --check`
- `git diff --check`

## Evidence Map

- Account-authorized challenge and registration: `TestWalletSessionRegistrationSelfServiceReplayAndModelFilter`, `TestWalletChallengeConsumptionRaceCreatesOneSession`, `TestWalletRegistrationRejectsChallengeProofDrift`, `TestWalletRegistrationRejectsAlreadyExpiredSessionProof`.
- Signed inference and metadata access: `TestWalletSessionRegistrationSelfServiceReplayAndModelFilter`, `TestWalletSessionAnthropicMessagesAcceptsXAPIKeyBearer`, `internal/auth` wallet canonicalization/signature vector tests.
- Concurrent and total cap enforcement: `TestWalletActiveSessionCapConcurrentRegistrations`, `TestWalletSessionRegistrationActiveCapReturnsConflict`, `TestWalletSessionExhaustionReturnsPaymentRequired`, `TestWalletReplayDuplicateAndMismatchDoNotReserveAgain`.
- Revocation, expiry, and stale pre-dispatch/dispatch recovery: `TestWalletSessionExpiredBearerWritesAudit`, `TestWalletStaleClaimsRefundPreDispatchReservations`, `TestWalletReaperRefundsExpiredPreDispatchClaims`, `TestWalletStaleDispatchArmsMoveToHeld`, `TestWalletReaperDoesNotSplitExpiredDispatchedReservations`.
- Settlement recovery and reconciliation: `TestWalletSessionSettlementReconcileClosesWalletHeldReservations`, `TestSealWalletSessionUsageEventConsumesSessionAndReleasesAccountHold`, `TestSettlementJournal_WalletConflictPathReleasesAccountHold`, settlement journal recovery tests under `phase5-gateway/internal/router`.
- Status, usage, and IDOR-safe management: `TestWalletSessionRegistrationSelfServiceReplayAndModelFilter`, `TestWalletSessionListPaginates`, `TestWalletSessionManagementRejectsAmbiguousCredentials`.
- Disabled-mode coexistence, shared-route protection, and config determinism: `TestWalletSessionsDisabledSharedRouteRejectsMPSBearer`, `TestWalletSessionsRejectsPrefixAndSecretReuse`, wallet-session default-off config validation, migration idempotence tests.

## Explicit Non-Claims

- No production deployment or live buyer traffic was exercised.
- No old released gateway binary was run against the post-migration database in this local pass.
- PR review, merge, release, and operator rollback rehearsal remain separate release gates.
