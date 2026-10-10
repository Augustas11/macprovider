=================== code
## Raw output

```text
Gate FAIL: three MEDIUM findings, all introduced by this diff.

- **MEDIUM — [release-registrations.py:391](/Users/augstar/macprovider-1919/scripts/ops/lib/release-registrations.py:391): Missing healthz mode bypasses disagreement checks.** With applied floor config and an absent healthz mode, `evaluate()` returns `compat_accepted=true`. SPEC-002-R004 treats an absent mode as legacy allowlist, so this combination must disagree. **Fix:** normalize absent mode to `legacy_allowlist` before comparison and admission checks. Add a floor-config/absent-mode regression test.

- **MEDIUM — [cli-release.sh:519](/Users/augstar/macprovider-1919/scripts/ops/cli-release.sh:519): Explicit disagreement still permits mutation.** When healthz reports `version_floor` but applied config is legacy, evaluation rejects acceptance, yet step 5 selects `_pearl-config --accepted-id …` and a restart. The later registrations blocker cannot override that earlier selection because `set_next()` preserves the first step. **Fix:** block policy disagreement before selecting mutations, including migration and combined privacy setup. Test both disagreement directions and assert the selected next action is blocked.

- **MEDIUM — [release-registrations.py:353](/Users/augstar/macprovider-1919/scripts/ops/lib/release-registrations.py:353), [pearl-cli-config.py:144](/Users/augstar/macprovider-1919/scripts/ops/lib/pearl-cli-config.py:144): Python admission checks accept numeric overflow.** A same-repository identity with version `9223372036854775808.0.0` is admitted by Python’s unlimited integers, while Go’s comparator rejects it. This falsely proves coordinator acceptance and violates the overflow requirement. **Fix:** enforce the coordinator’s numeric bounds in both Python admission helpers; add overflow parity tests.

Validation: 17 targeted Python tests passed; isolated reproductions confirmed the missing-mode acceptance, disagreement mutation selection, and overflow acceptance. Go/Swift tests were not run. No checkout changes or live-host contact.

C/H/M/L = 0/0/3/0
=================== security
## Raw output

```text
Reviewed the complete `origin/main...HEAD` diff at `d6cd3c945`. **Security gate: FAIL — one MEDIUM finding.** No files edited or live hosts contacted.

- **MEDIUM — Migration can strand connected providers.** [scripts/ops/lib/pearl-cli-config.py:165](/Users/augstar/macprovider-1919/scripts/ops/lib/pearl-cli-config.py:165) uses `latest_versions()`, whose query at line 220 includes rejected authentication attempts. A provider still serving on `1.8.200` can make an authenticated reconnect claiming `1.8.224` that fails admission; that failure replaces its older successful version in the migration table. Migration then permits floor `1.8.224`, restarts the coordinator, and rejects the previously connected provider. Config validation and `/healthz` policy checks do not detect lost fleet admission; the SIGHUP guard is bypassed by the restart.
  **Evidence:** An in-memory SQLite reproduction returned only `1.8.224` and allowed that floor despite the earlier admitted `1.8.200`.
  **Fix:** Use successful admission records for historical usage and check every currently connected session against the proposed policy before migration. Add regression coverage for a rejected newer reconnect while an older session remains connected. The event selector is **pre-existing**; its use for floor migration is new.

- **INFO — Self-reported identities remain forgeable by design.** [specs/SPEC-002-coordinator.md:5174](/Users/augstar/macprovider-1919/specs/SPEC-002-coordinator.md:5174) explicitly acknowledges that a modified provider can report another identity and evade an exact revocation. This trust limitation is **pre-existing**; matching `binary_version` does not authenticate the binary. No additional fix is required for the stated metadata policy; cryptographic build exclusion would require a separately verified identity binding.

No additional blocking findings found in canonical-version checks, exact repository comparison, reload fencing, helper argument handling, or lock enforcement. Validation was source inspection plus the in-memory reproduction; no build or full test suite ran.

C/H/M/L = 0/0/1/0
=================== architecture
## Raw output

```text
Architecture gate: **FAIL — two MEDIUM findings.** Reviewed the complete `origin/main...HEAD` diff and affected code. Both findings are new.

1. **MEDIUM — Migration protects releases already excluded by current policy.**  
   [scripts/ops/lib/pearl-cli-config.py:165](/Users/augstar/macprovider-1919/scripts/ops/lib/pearl-cli-config.py:165), [specs/SPEC-002-coordinator.md:5203](/Users/augstar/macprovider-1919/specs/SPEC-002-coordinator.md:5203).  
   **Failure scenario:** The latest-version query includes failed connection attempts and never filters against `accepted_ids`. A recently seen, currently excluded `1.8.117` or `1.8.123` blocks migration to `1.8.224`. Following the refusal’s instruction to lower the floor re-admits those excluded releases at the compatibility gate. Reproduced in memory. The implementation follows R004’s text; the architectural defect is also normative.  
   **Fix:** Apply the preservation check only to providers whose latest reported release is currently accepted. Keep excluded versions visible in the table without letting them constrain the floor. Update R004, runbooks, and regression coverage together.

2. **MEDIUM — Registrations can prove admission against stale policy.**  
   [scripts/ops/lib/release-registrations.py:391](/Users/augstar/macprovider-1919/scripts/ops/lib/release-registrations.py:391), [scripts/ops/cli-release.sh:185](/Users/augstar/macprovider-1919/scripts/ops/cli-release.sh:185).  
   **Failure scenario:** Only the health **mode** is compared. Boot with floor A, SIGHUP-load a stricter floor or revocation, then restore the original disk config without reloading. Disk and boot digests match, both modes remain `version_floor`, and registrations can approve a candidate the running policy rejects. An absent health mode also permits floor-based admission instead of enforcing the required legacy interpretation. Privacy approval does not correct either compatibility verdict.  
   **Fix:** Pass the full applied health policy to evaluation and compare target, floor, and revocations—or a policy fingerprint. Treat absent mode as legacy and reject floor-policy facts. Preserve boot-digest verification for restart-only privacy fields.

Old CLI acknowledgement compatibility remains intact through `compatibility_policy: "configured"`. No files changed or live hosts contacted; validation used lightweight in-memory checks.

C/H/M/L = 0/0/2/0
