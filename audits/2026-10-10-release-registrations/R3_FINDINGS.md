=================== code
## Raw output

```text
Round-2 CODE findings:

- **FIXED — Edited-but-unapplied config recovery.** `pearl-cli-config.py:444–461` now validates and restarts when disk bytes already match but boot digests differ.
- **FIXED — Empty compatibility identity passed registrations.** `release-registrations.py:351` fails closed; status derives missing IDs only from a trusted signed tag and explicitly requires compatibility acceptance.
- **NOT FIXED — Publication-time registration gap.** The added check immediately before dispatch narrows the gap but does not protect publication after a queued workflow or environment approval.

Also confirmed: explicit tag signer allowlists are enforced, and recommendation completion requires both the advertised version and applied target ID.

**Gate FAIL: two MEDIUM findings.**

1. **MEDIUM — Publication still lacks a live registration check. Pre-existing; retained from round 2.**  
   **Location:** `scripts/ops/cli-release.sh:552`; `.github/workflows/promote-acceptance-candidate.yml:516`.  
   **Scenario:** Registrations pass at dispatch, then disappear while promotion waits for approval. The workflow’s prepublication verifier does not check compatibility acceptance or privacy approval before undrafting. Showing approval instructions only while local status passes does not enforce the publication boundary.  
   **Fix:** Require candidate-bound live registration evidence immediately before undrafting; refuse publication when unavailable. Test registration removal between dispatch and publication.

2. **MEDIUM — Counter resets can conceal rejections during rollout verification. New.**  
   **Location:** `scripts/ops/cli-release.sh:996`; `scripts/ops/lib/release-registrations.py:275`.  
   **Scenario:** The first sample is zero, privacy advertisements are rejected, then the coordinator restarts before the second sample. Its counter returns to zero, so the computed delta is zero and verification proceeds. Negative-delta detection cannot detect this reset.  
   **Fix:** Bind both samples to the same coordinator invocation and refuse on an invocation change, or check timestamped journal events across the entire window. Add a regression with intervening rejections followed by a reset to the initial count; current entrypoint tests cover growth but not resets.

Validation: nine targeted registration tests passed; shell syntax and diff whitespace checks passed. An offline probe confirmed JSON-only staging recovers on retry and remains idempotent. Another confirmed equal counters pass without detecting intervening resets. No SSH injection issue found in the allowlisted helper arguments. Checkout remains clean; no Pearl or GitHub contact.

C/H/M/L = 0/0/2/0
=================== security
## Raw output

```text
Round-2 security finding: **FIXED — OpenPGP signer authorization.** [cli-release.sh:904](/Users/augstar/macprovider-release-registrations/scripts/ops/cli-release.sh:904) requires an explicit SSH allowed-signers file or an allowlisted OpenPGP `VALIDSIG` fingerprint. Valid signatures from other imported keys no longer suffice.

New finding:

- **MEDIUM — Config secrets can leak through uncaught YAML exceptions.** [release-registrations.py:135](/Users/augstar/macprovider-release-registrations/scripts/ops/lib/release-registrations.py:135), exposed by [cli-release.sh:1025](/Users/augstar/macprovider-release-registrations/scripts/ops/cli-release.sh:1025).
  **Scenario:** A malformed coordinator config or overlay contains an inline credential, such as an unterminated quoted `auth.operator_key`. `yaml.safe_load` raises an exception containing the source line. The helper leaves it uncaught, and staging forwards remote stderr into the operator’s terminal or captured session logs. An in-memory probe confirmed a synthetic secret appears in the traceback.
  **Fix:** Catch exceptions at the helper entry point and emit a fixed diagnostic or exception type only, following `pearl-cli-config.py`. Add a regression check asserting malformed secret-bearing YAML never appears in stderr. **Introduced by this PR.**

No additional security findings in remote argument construction, staged permissions/ownership, metadata signature and version enforcement, signing-key handling, or metric cardinality.

Reviewed the complete diff and touched code. Shell syntax, production Python AST parsing, and diff whitespace checks passed. No files edited; no Pearl or GitHub contact; checkout remains clean.

**Security gate: FAIL.**

C/H/M/L = 0/0/1/0
=================== architecture
## Raw output

```text
Round-2 architecture findings:

- **NOT FIXED — Publication lacks a live registration gate.** `_check-registrations` now runs immediately before dispatch, but publication occurs later without rechecking.
- **FIXED — Already-edited config cannot recover unapplied state.** `pearl-cli-config.py:444–460` validates and restarts when disk bytes differ from boot digests.
- **FIXED — Missing compatibility identity fails open.** `release-registrations.py:351` rejects an empty ID; status derives it only from a trusted signed tag.
- **FIXED — Recommendation completion ignores target identity.** `cli-release.sh:561` requires both the advertised version and applied candidate `target_id`.

Previously fixed architecture findings remain fixed: applied-config evidence, setup through the ops entry point, windowed rejection checks, and signed-tag verification. Tag verification now also requires an explicit signer allowlist.

**Architecture status: BLOCK. Gate FAIL.**

1. **MEDIUM — Publication-time registration gap remains. Pre-existing; still unclosed.**  
   **Locations:** [cli-release.sh:552](/Users/augstar/macprovider-release-registrations/scripts/ops/cli-release.sh:552), [promote-acceptance-candidate.yml:500](/Users/augstar/macprovider-release-registrations/.github/workflows/promote-acceptance-candidate.yml:500), [publication at :516](/Users/augstar/macprovider-release-registrations/.github/workflows/promote-acceptance-candidate.yml:516).  
   **Failure scenario:** Registrations pass at dispatch. During the production-environment approval wait, Pearl rolls back compatibility acceptance or loses privacy approval. The workflow checks signed feeds and recommendation, then undrafts without checking either registration. The original upgrade failure remains possible. Restricting which approval instruction status displays does not enforce the condition when publication happens.  
   **Fix:** Require candidate-bound running-coordinator registration evidence immediately before undrafting, failing closed if unavailable. Provide the necessary authenticated check through the supported ops/publication path; test registration removal between dispatch and publication.

2. **MEDIUM — Published releases cannot repair lost compatibility acceptance through the train.**  
   **Locations:** [cli-release.sh:447](/Users/augstar/macprovider-release-registrations/scripts/ops/cli-release.sh:447), [registration refusal at :499](/Users/augstar/macprovider-release-registrations/scripts/ops/cli-release.sh:499).  
   **Failure scenario:** After publication, candidate acceptance is removed, rolled back, or present only in unapplied disk config. The train unconditionally marks `pearl_accepted_ids` done because the release is published. Its subsequent registration gate blocks before `recommendation_bump`, so neither the acceptance editor nor the restart-recovery path can run. This recreates an uncleared tooling refusal under rules 5 and 8. The publication shortcut is **pre-existing**; its incompatibility with the new persistent registration gate is introduced here.  
   **Evidence:** An isolated, offline invocation of the actual `decide()` function with publication true and compatibility acceptance false produced `accepted_ids step: done` and `selected next: registrations:blocked`.  
   **Fix:** Determine acceptance completion from live acceptance regardless of publication. Select the guarded `_pearl-config --accepted-id` repair when missing or unapplied, preserving the current target. Add a post-publication recovery test.

The remaining registration coverage is coherent: CB/MTP retain signed-feed gates; their provenance identities are not per-CLI authorization lists. Version floors are admission thresholds, not registrations requiring advancement on every cut. Setup, restart, and conditional rollback follow the ops path. No new automatic expiry is introduced.

Reviewed the complete diff and touched code. Registration unit tests passed **9/9**; shell syntax and diff whitespace checks passed. No source edits, Pearl/GitHub contact, or broad workloads.

C/H/M/L = 0/0/2/0
