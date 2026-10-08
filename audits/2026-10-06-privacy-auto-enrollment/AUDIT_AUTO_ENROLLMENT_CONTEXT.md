# Audit context: SPEC-049 v0.2.0 automatic privacy-class enrollment (#1749)

METHOD: READ-ONLY first-party software-correctness review. Read source, specs, and tests, and run EXISTING tests only. Do not modify files. Do not author or construct malformed payloads, exploit inputs, or attack tooling; describe any gap abstractly (component, field, condition) in prose.

Worktree: `/Users/augstar/macprovider-poc/.claude/worktrees/agent-abd7bfa1bb864efa3`, branch `feat/privacy-class-auto-enrollment`. Scope is the FULL combined diff `git -C <worktree> diff origin/main...HEAD`. Gate: 0 CRITICAL, 0 HIGH, 0 MEDIUM. Attribute each finding as NEW (introduced by this branch) or PRE-EXISTING.

## Operator decision being implemented

Privacy must work across the whole network automatically. Replace per-provider operator pinning (SE key pins, relay-blind identity pins, per-release approved code identities, per-provider buyer pin files) with automatic enrollment. The security properties must stay explicit in the SPEC.

## Normative text

- `specs/SPEC-049-operator-constrained-privacy-class.md` v0.2.0: §1.5, §2.2 (credential-holder and coordinator-host adversaries), §2.5, §2.6 (what enrollment trusts and does not), §4.10 claim, §4.11 directory, R001, R004, R006, R008, R016, R017, R018, R020 (two new residual risks), R021, new R024..R028, §6, §8, §10.
- `specs/SPEC-041-relay-blind-request-encryption.md` v0.5.0: §2 and R002 (enrollment as an identity binding for privacy records only; network discovery only through the signed directory).

## Design summary

1. Provider (Swift, `phase3-binary`): `privacy_class_beta` unset is automatic mode. `PrivacyAutoEnrollment.swift` runs a read-only eligibility check (no ptrace or setrlimit), then the existing R007 hardening; ineligible hosts and automatic-mode hardening failures serve ordinarily. Explicit false or explicit `relay_blind_enabled: false` opts out; forced true keeps the exit-78 refusal. `MacProviderCLI.resolveServeConfig` orders this before credential resolution. The provider advertises `privacy_enrollment` {version, identity_public_key, se_public_key} beside non-empty `privacy_key_records`.
2. Coordinator (`phase4-coordinator/internal/relayblind`): `resolveKeys` per key: config pin, then active durable enrollment (`store_enrollment.go`, table `privacy_class_enrollment`, partial unique indexes on active provider, identity fingerprint, SE fingerprint), then the session claim. `VerifyPosture` enrolls only after every check passes, before committing posture. A claim or enrollment conflict with a different key quarantines (`privacy_enrollment_key_changed`) and keeps the enrollment; only `coordinator-cli privacy-class reenroll` replaces it. An unenrolled session cannot change its claim mid-session. Unapproved (not denied) code identity is now ineligible without quarantine; `denied_code_cdhashes` quarantines.
3. Release-derived approval (`release_identities.go`): signed `pearl-release.json` + `.sig` pairs in `privacy_class.release_code_identities.metadata_dir` are re-verified (ECDSA P-256 over the exact bytes, PEM SPKI key) at startup and every challenge interval; `provider_code_identity` per SPEC-025 §6.2.1. The Pearl updater (`ops/pearl-updater/macprovider-pearl-update`, `install_privacy_release_identity`) writes those pairs on install.
4. Directory (`directory.go`, byte-identical in both relay-blind modules under `scripts/test-relay-blind-parity.sh`; `directory_service.go`): an online Ed25519 key (`coordinator-cli privacy-class directory-keygen`, file 0600/0400, loaded by `NewPrivacyAuthority`) signs `privacy-identity-directory-v1` with domain-separated framing over the exact payload bytes; 15 s envelope cache; TTL 60..3600. Coordinator route `GET /v1/privacy-class/directory` (gateway context), gateway passthrough for API-key buyers (`phase5-gateway/internal/router/privacy_directory.go`), and `relay-blind-client` auto-pin when `--identity-pin` is absent (`--directory-public-key` or `MACPROVIDER_PRIVACY_DIRECTORY_PUBLIC_KEY`).
5. Config: `relay_blind.identity_public_keys` and `privacy_class.provider_se_public_keys` may be empty when the class is enabled; an SE pin requires an identity pin; enabled requires a directory signing key and an approval source.

`phase4-coordinator/cmd/coordinator/main.go` is deliberately untouched (a local secret-preflight hook blocks commits to it); wiring goes through `NewPrivacyAuthority` and `buyer.WithPrivacyAuthority`.

## Tests run by the author

- `cd phase4-coordinator && go test ./... -count=1` (two timing tests, `TestAdminRateLimitBucketConsumesFailures` and `TestSlotQueueWaitsThroughQueueFullSafetyHold`, failed under full-suite load and pass alone)
- `cd phase5-gateway && go test ./... -count=1`
- `bash scripts/test-relay-blind-parity.sh`
- `cd test/integration && go test -race -count=1 ./...` (includes the Swift privacy fixture)
- `cd phase3-binary && swift build --build-tests && swift test --skip-build --filter 'PrivacyAutoEnrollmentTests|PrivacyPostureResponderTests|PrivacyRuntimeHardeningTests|...'`
- `cd ops/pearl-updater && python3 -m unittest test_pearl_updater`
- `python3 scripts/gen_spec_index.py --check`, `python3 scripts/check_spec_governance.py --base-ref origin/main`

## Output

Findings by severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), each with file:line, condition, and fix, attributed NEW or PRE-EXISTING. End with exactly one line:
`VERDICT: <n> CRITICAL / <n> HIGH / <n> MEDIUM / <n> LOW / <n> INFO`
