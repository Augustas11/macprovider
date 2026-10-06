# Audit R1: SPEC-049 v0.2.0 automatic enrollment (CODE lane)

Read `audits/2026-10-06-privacy-auto-enrollment/AUDIT_AUTO_ENROLLMENT_CONTEXT.md` first; its METHOD constraint applies.

Check for this lane:

- Correctness of `resolveKeys`, `AcceptPrivacyKeysWithClaim`, `VerifyPosture`, `policyFailure`, `approve`, `sessionClaimChanged`, and `commitPosture` interplay: generations, epochs, snapshot claim, `NoteChallengeTimeout` on every non-quarantine reject path, and mutex discipline (`mu` vs `releaseMu`), with `go test -race`.
- `store_enrollment.go`: SQL correctness, partial unique indexes on SQLite, transaction scope, idempotent enroll, `ReenrollPrivacyProvider` (revocation retention arithmetic, reservation rejection, quarantine delete), migration on existing stores, and `ListPrivacyEnrollments` retention window.
- `directory.go` and `directory_service.go`: closed decoding, sorting and uniqueness, empty directory, TTL arithmetic with sub-second clocks, cache correctness and copying, ambiguous duplicate identities, operator-pin entries, error propagation. The file is byte-identical in the gateway module.
- `release_identities.go`: deterministic ordering, de-duplication, error and rejection reporting, the ws reload logging (no log spam, no content in logs).
- Config validation (`config.go` `validatePrivacyClass` and the relay-blind pin rule), defaults, and `NewPrivacyAuthority` startup failures; `NewAuthority` now accepting an empty pin set.
- ws parsing of `privacy_enrollment` in hello, both auth messages, and heartbeat; `AuthRequest.Hello()` carry-over; heartbeat acceptance path.
- Buyer and gateway routes: method handling, auth, error mapping to the shared inventory, `Cache-Control`, size bounds, wallet-session refusal, and the inventory completeness tests.
- `relay-blind-client`: flag and env handling, pre-network validation, GET signing helper refactor, stderr disclosure lines, no regression for `--identity-pin` and wallet flows.
- Swift: `Config.swift` tri-state tracking across YAML/env/CLI, forced-mode implicit relay-blind, `resolveServeConfig` ordering in all three modes, `PrivacyAutoEnrollment` hooks and default state directory creation, `enrollmentClaim()` latching, CoordinatorClient advertisement, the fixture descriptor, and Swift 6 concurrency warnings.
- Pearl updater: staging into the candidate validation directory, `install_privacy_release_identity` ownership, modes, atomic writes, signature re-verification, tag validation, and effect on rollback and existing tests.
- Tests: do they exercise the claimed behaviour (no vacuous assertions, no sleeps that hide races), and is CONFORMANCE.json mapped to real selectors?

Lane: CODE.
