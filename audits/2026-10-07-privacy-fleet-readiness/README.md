# Privacy fleet readiness verification record

Date: 2026-10-07

Gates: G001–G003

Status: **G001 PASS; G002 PASS; G003 IN PROGRESS**

G001 code SHA: `947b468570761953b7f1010088b5c0d671db0076`

This record captures final review, CI, governance, and ops-review proof for the
frozen privacy-fleet code. It does not grant merge, release, deployment, or
production-rollout authorization. Hardware-campaign acceptance belongs to G004
and is not part of G001 completion.

This evidence-only README does not change the frozen code SHA.

## Candidate identity

| Item | Value | Status |
| --- | --- | --- |
| Candidate base | `eedd1c1456242afab775072bef622a68c3b634a0` (`origin/main`) | Recorded |
| Local synchronization merge | `734b4df2370fe2855ca4a3323a7421d240d4adf2` | Reconciliation point |
| Draft pull request | `#1871` | Draft; formal ops review approved the code, but G004 and activation work remain and no merge is authorized here |
| Frozen and published draft head | `947b468570761953b7f1010088b5c0d671db0076` | G001 review target |
| Production state | No production changes made | Confirmed for this evidence window |

The code candidate is frozen and pushed at
`947b468570761953b7f1010088b5c0d671db0076`. Final G001 reviews and automated
gates are bound to that SHA. Pull request `#1871` remains draft pending the
separate G004 hardware campaign; this record grants no merge authority.

## Evidence ledger

| Check | Result | G001 meaning |
| --- | --- | --- |
| Main-conflict reconciliation | PASS for the local reconciliation | Preserves the SPEC-049 v0.2 / SPEC-048 v0.1.25 scrub-overlay and reenrollment behavior. |
| JSON parsing | PASS | Relevant changed JSON parsed successfully. This is a narrow syntax check, not the complete governance gate. |
| `gen_spec_index --check` | PASS | Generated spec index was current for the checked state. |
| `check_spec_governance --base-ref origin/main` | **NOT PASSED locally; PASS in CI** | The local run was interrupted at the operator-machine resource boundary and was never counted as success. Spec-index/governance CI run `37550680545` completed successfully at the frozen SHA, providing the complete gate result. |
| Updater candidate-staging fixture | PASS in deploy-tooling CI | The earlier root-local command, `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest ops/pearl-updater/test_pearl_updater.py -k candidate_staging`, reported 2 tests run with one pass and one root-only skip. That skip is retained as local history, not a current CI gap. Deploy-tooling job [`112565141125`](https://github.com/Augustas11/macprovider/actions/runs/37550680549/job/112565141125) completed successfully and its completed log records `test_candidate_staging_survives_real_dropped_uid_filesystem_access ... ok` at `2026-10-07T00:26:19.9623274Z`; the updater suite ran 282 tests in 29.315s. |
| Seven targeted quarantine selectors | PASS | Ordinary run completed in 0.308s; race-enabled run completed in 1.908s after correcting both the database-connection and `sync.Once` hook deadlocks. |
| Privacy CLI overlay, reenroll, and directory-keygen check | PASS | `go test ./cmd/coordinator-cli -run 'TestPrivacyClassCLIConfigOverlay|TestPrivacyClassCLIReenrollAndDirectoryKeygen' -count=1 -timeout=30s` completed in 0.604s. |
| Historical quarantine regression attempts | FAILED during diagnosis | Earlier attempts timed out at 60 and 90 seconds because of test deadlocks. They are retained as diagnostic history and are superseded by the passing ordinary and race runs above; they were never counted as passes. |
| Code-review lane | **APPROVE: 0 CRITICAL / 0 HIGH / 0 MEDIUM; 1 LOW** | Final review covered the full combined 63-file diff from base `eedd1c1456242afab775072bef622a68c3b634a0` through frozen SHA `947b468570761953b7f1010088b5c0d671db0076`. The reviewer independently reran the seven targeted selectors in 0.390s: PASS. The LOW finding is carried below. |
| Architecture-review lane | **CLEAR: 0 CRITICAL / 0 HIGH / 0 MEDIUM** | Final review covered the same full combined 63-file diff and frozen SHA. |
| Security-review lane | **CLEAR: 0 CRITICAL / 0 HIGH / 0 MEDIUM** | Final review covered the same full combined 63-file diff and frozen SHA. |
| Deploy-tooling CI | PASS | Job [`112565141125`](https://github.com/Augustas11/macprovider/actions/runs/37550680549/job/112565141125) in run `37550680549` completed successfully at the frozen SHA, including the formerly root-skipped candidate-staging case. |
| Swift CI | PASS | Job `112565208116` in required CI run [`37550680549`](https://github.com/Augustas11/macprovider/actions/runs/37550680549) completed successfully at the frozen SHA. |
| Required CI | PASS | Run [`37550680549`](https://github.com/Augustas11/macprovider/actions/runs/37550680549) completed successfully at the frozen SHA; `ci-required` reports SUCCESS. |
| Spec-index / governance CI | PASS | Run [`37550680545`](https://github.com/Augustas11/macprovider/actions/runs/37550680545) completed successfully at the frozen SHA. |
| Formal ops review | APPROVED | `antfleet-ops` approved actual source SHA `947b468570761953b7f1010088b5c0d671db0076` through GitHub review at `2026-10-07T00:40:07Z`. This is code approval, not production activation authorization. |
| Hardware / fleet acceptance | Outside G001 | Governed by G004. No hardware or production claim is made here. |

## Finding dispositions

| Finding | Severity | Current disposition | Required closure evidence |
| --- | --- | --- | --- |
| Timestamp-based operator-clear comparison could let an older clear erase a newer quarantine latch | Correctness | Closed at the frozen SHA | Targeted regression passed; final code, architecture, and security reviews found no blocking issue. |
| Quarantine retry and operator clear were not atomic | Correctness | Closed at the frozen SHA | Race regression passed; final code, architecture, and security reviews found no blocking issue. |
| A newer latch could be deleted by completion of an older retry | Correctness | Closed at the frozen SHA | Targeted regression passed; final code, architecture, and security reviews found no blocking issue. |
| Same-store concurrency regression tests self-deadlocked | **MEDIUM** | Closed at the frozen SHA | Database-connection and `sync.Once` hook deadlocks were corrected; ordinary, race, and independent reviewer reruns passed. Earlier timeouts remain recorded as failed diagnostic attempts. |
| Final audit lanes previously reviewed a moving candidate | Gate/watch | Closed at the frozen SHA | All three final reviews covered the same full combined 63-file diff; each reports 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings. |
| `gofmt` alignment in `test/integration/harness_test.go:227` | LOW | Carried explicitly | Address in the subsequent landing candidate freeze. Repository policy permits an explicitly carried LOW; it does not block current G001 completion. |

## G001 completion proof

G001 completed against frozen code SHA
`947b468570761953b7f1010088b5c0d671db0076` because:

1. Required CI run `37550680549` and `ci-required` completed successfully.
2. Spec-index/governance run `37550680545` completed successfully.
3. Code, architecture, and security reviews covered the full combined 63-file
   diff with 0 CRITICAL, 0 HIGH, and 0 MEDIUM findings.
4. Formal ops review approved the same actual source SHA.
5. The draft PR head and this record remain bound to the reviewed SHA.

The carried LOW formatting finding remains explicit for the subsequent landing
candidate. G001 PASS does **not** authorize merging, release, deployment,
production activation, or transition out of draft status. G004 hardware
acceptance and the new activation exception remain pending and are tracked
separately.

## G002 fleet reconciliation proof

Decision: **PASS**

The sanitized fleet snapshot at `2026-10-07T00:44:56Z` recorded:

| Measure | Count |
| --- | ---: |
| Connected providers | 10 |
| Ordinary-routing eligible | 3 |
| Providers with a usable privacy key | 1 |
| Quarantines | 0 |

The automatic-enrollment schema was absent at snapshot time. All 10 connected
rows were accounted for with per-row exclusions and accountable operator
remediations in a separate ignored private artifact; this public record contains
no provider-specific identifiers or private operational details.

Three known unsupported loopback runtimes were present: two `llama.cpp` and one
Ollama. They remain on ordinary routing. Their remediation is migration to a
natively supported runtime. Privacy-rollout readiness for the other rows remains
unproven, and absence of a privacy key is not treated as evidence of an opt-out.

The serving-executable code signature matches the usable attestation set. The
snapshot does not prove provider-specific attribution, so no host is cleared for
privacy rollout by G002.

## G003 signed journey status

Decision: **IN PROGRESS**

The earlier frozen partial v2 scaffold was not accepted. The current working
diff implements the versioned full v2 journey profile while preserving exact
historical v1 recomposition, but it is not yet a frozen candidate.

Two interim review findings drove the latest corrections:

- Security WATCH: raw primary evidence needed recomputation with bound
  provenance. The `privacy_v2_primary_recompute` correction now has a stable
  primary handoff.
- Architecture WATCH: the generic conformance satisfier and direct promoter
  blocked only the v1 evidence ID, so v2 evidence could have counted toward
  promotion incorrectly. The `privacy_v2_governance_guard` correction uses one
  shared privacy evidence-only ID set across validation dispatch, the satisfier,
  and the promoter. Explicit `compose --profile` selection prevents a partial v2
  input from being inferred as v1.

The architecture governance gap is closed by two independently verified
regressions, which passed in 0.099s:

- `scripts.tests.test_spec_governance.GovernanceValidatorTests.test_privacy_class_beta_v2_signed_result_cannot_satisfy_requirement`
- `scripts.tests.test_journey_result_tools.JourneyResultToolsTests.test_promoter_rejects_privacy_class_beta_v2_without_rewrite`

The latest stable primary handoff targeted suite passed 9 tests in 18.299s
(18.7s wall time) after tightening the binary public-signature secret/path
scanner. It included
`V2RawEvidenceTests`,
`GovernanceTests.test_primary_extractor_exports_v2_sources_with_bound_provenance`,
and
`EvidenceTests.test_committed_evidence_validates_and_recomposes_exactly`.
The full 21-step v2 compose/validate path and exact historical v1 recomposition
were exercised. Coverage includes source-assertion-only handling, database
mutations, automatic enrollment and reenrollment, release pins, signatures,
schema-invalid evidence, directory tampering, pin expiry, revocation, and
parity. Expected stderr from negative extractor cases is not a test failure.

Python compilation checks for the changed scripts and the diff whitespace check
also passed. These are targeted results for the current working diff, not final
frozen-candidate proof. G003 remains pending a fresh full audit and CI against a
new frozen SHA. No G003 pass, hardware proof, rollout clearance, production
change, or activation authorization is claimed.

### `dda5168d1fad38207c51203b20d3250f9042d762` audit and CI disposition

The full 74-file candidate received these frozen-SHA review results:

- Security: CLEAR, 0 CRITICAL / 0 HIGH / 0 MEDIUM.
- Architecture: CLEAR, 0 CRITICAL / 0 HIGH / 0 MEDIUM.
- Code: 0 findings. The reviewer left a COMMENT only because LSP was
  unavailable; replacement validation is still required.

Required CI run `37557833947` did not pass. Deploy job `112588057931` failed the
static signed-privacy workflow guard because public signature verification made
a direct OpenSSL call. The root cause is verification at the wrong abstraction
layer, not a need to weaken the signing guard.

The narrow correction is assigned to the primary implementation owner: move
public verification to the existing trusted public API helper without weakening
the signing guard. G003 remains pending a new frozen SHA, replacement validation,
fresh full audits, and successful CI. The `dda5168d1fad38207c51203b20d3250f9042d762`
review results are retained as historical evidence and are not a G003 pass.
