=================== code
## Raw output

```text
Round-1 CODE findings:

- **FIXED — Existing unsigned tags passed.** `cli-release.sh:885` now verifies the exact remote tag object; tests cover unsigned and untrusted signatures.
- **FIXED — Expiry discarded timezone offsets.** `release-registrations.py:300` compares timezone-aware instants. Both offset cases reproduced correctly.
- **FIXED — Timestamp truncation accepted unapplied config.** `release-registrations.py:341` now compares disk digests with the current invocation’s boot digests.

**Gate FAIL: two new MEDIUM findings and one retained MEDIUM gap.**

1. **MEDIUM — `scripts/ops/lib/pearl-cli-config.py:400` — Already-written config cannot recover stale runtime state.**  
   If execution stops after installing the config but before restarting, retrying `pearl_accepted_ids` produces unchanged bytes and returns success without restarting. Status correctly detects that the coordinator never applied those bytes, so `next --run` repeats indefinitely. Unrelated hot config changes can also trigger this condition. An in-memory probe confirmed `changed:false` with zero restart calls.  
   **Fix:** Treat unchanged disk bytes as complete only when the running process demonstrably holds the requested state; otherwise validate, restart and verify under the existing locks. Add a test with the candidate already on disk but absent from boot state.

2. **MEDIUM — `scripts/ops/lib/release-registrations.py:350`, `scripts/ops/cli-release.sh:478` — Empty compatibility identity passes registrations.**  
   A published release inspected from fresh local ops state has no `signed_byte_verification` marker, hence no `compat_id`. Evaluation can recover the privacy identity from remote metadata, but only records missing compatibility acceptance when `compat_id` is nonempty. Reproduced verdict: `compat_accepted:false`, `missing:[]`. If the recommendation already equals the release version, rollout verification becomes runnable despite compatibility acceptance never being proved.  
   **Fix:** Fail closed on an empty compatibility ID, recover it from verified release evidence, and require `compat_accepted:true` explicitly. Add a published-release test without local markers.

3. **MEDIUM — `scripts/ops/cli-release.sh:535`; `.github/workflows/promote-acceptance-candidate.yml:517` — Publication-time registration gap remains. Pre-existing; reported by the round-1 architecture lane.**  
   Registrations are checked before workflow dispatch. A queued promotion can outlive removal or rollback of those registrations; the unchanged workflow checks feeds before undrafting, but does not recheck compatibility/privacy approval. Re-gating subsequent status calls after publication cannot prevent that publication.  
   **Fix:** Recheck candidate-bound live registrations immediately before undrafting. Test removal between dispatch and publication.

The entrypoint tests do not cover these scenarios. Matching JSON-only staging remains recoverable on retry; conflicting existing bytes are refused. No SSH command injection found in the allowlisted helper arguments.

Validation: shell syntax, changed Python parsing and diff whitespace checks passed; in-memory probes reproduced findings 1–2. No files edited, no Pearl or GitHub contact, and no broad suites run. Checkout remains clean.

C/H/M/L = 0/0/3/0
=================== security
## Raw output

```text
Round-1 security finding: **NOT FIXED fully.** Unsigned and invalidly signed tags now fail, and verification uses the exact remote tag object. The approved-signer requirement remains incomplete for OpenPGP.

- **MEDIUM — [scripts/ops/cli-release.sh:885](/Users/augstar/macprovider-release-registrations/scripts/ops/cli-release.sh:885), also :914.** Bare `git verify-tag` accepts a valid OpenPGP signature from an imported key with undefined trust by default. Thus, in an OpenPGP-configured checkout, a non-approved signer’s tag on the candidate can return `on_candidate` and satisfy promotion. The tests cover SSH allowed-signers enforcement only. **Fix:** enforce an explicit approved signing-fingerprint allowlist, or require SSH signing with an approved `allowedSignersFile`, before accepting existing tags or pushing new ones. The promotion workflow’s target-only check is **pre-existing**; this PR’s gate still lacks complete signer authorization.

No additional security findings in the Pearl config editor/restart path, remote argument construction, staged permissions, metadata signature/version enforcement, secret output, or metric cardinality.

Reviewed the complete diff and touched code. Shell/Python syntax and diff whitespace checks passed. Checkout remained clean; no Pearl or GitHub contact. Runtime tests were not run.

**Security gate: FAIL.**

C/H/M/L = 0/0/1/0
=================== architecture
## Raw output

```text
Architecture gate: **FAIL — four MEDIUM findings remain.**

Round-1 architecture findings:

1. **FIXED — Disk approval treated as live approval.** Boot config digests now prove restart-only registrations were applied; release-file approval additionally requires the running authority’s loaded-version metric. Disabled privacy class fails closed.
2. **NOT FIXED — Enforcement ends at workflow dispatch.** Rechecking after publication does not protect the irreversible publication itself; see finding 1 below.
3. **FIXED — Setup bypassed the ops entry point.** Setup now runs through `next --run`, with both Pearl locks, key/readability preflight, validation, restart and conditional restoration.
4. **FIXED — Historical rejections blocked recovery.** Rollout now evaluates a windowed delta rather than the lifetime counter.
5. **FIXED — Existing unsigned annotated tags passed.** The exact remote tag object must now pass `git verify-tag`.

Remaining findings:

1. **MEDIUM — Publication still lacks a live registration gate.**  
   **Location:** `.github/workflows/promote-acceptance-candidate.yml:500`, `:516`; `scripts/ops/cli-release.sh:535`.  
   **Scenario:** Registrations pass when the train dispatches promotion. While the workflow waits for environment approval, Pearl rolls back its compatibility config or loses the privacy identity. The workflow’s pre-publication verifier checks feeds and recommendation, but neither compatibility acceptance nor privacy approval, then undrafts the release. Providers can therefore upgrade into the original failure. This omission is **pre-existing and remains unclosed**.  
   **Fix:** Require candidate-bound, running-coordinator registration evidence immediately before undrafting. Fail closed when that evidence is unavailable. Post-publication checks cannot substitute for this gate.

2. **MEDIUM — Already-edited disk config creates an unrecoverable train loop.**  
   **Location:** `scripts/ops/lib/pearl-cli-config.py:400`; `scripts/ops/cli-release.sh:432`.  
   **Scenario:** The candidate ID is already on disk, but the running coordinator booted with older bytes—for example, an earlier edit was interrupted before restart. Status correctly selects `pearl_accepted_ids`. The helper sees no text change and returns success without restarting. Every subsequent status selects the same step. The prescribed ops entry point cannot complete recovery, while direct restart is prohibited by rule 8.  
   **Evidence:** An in-memory probe returned `{"changed": false}` with **zero restart calls**.  
   **Fix:** Distinguish disk idempotence from live idempotence. Under both locks, verify applied digests and requested postconditions; validate and restart when the requested disk state is unapplied.

3. **MEDIUM — Missing local compatibility identity makes the registration gate fail open.**  
   **Location:** `scripts/ops/lib/release-registrations.py:350`; `scripts/ops/cli-release.sh:379`, `:478`.  
   **Scenario:** A published release is checked from a fresh operator state directory without its verification marker. The evaluator can recover privacy identity from Pearl’s signed metadata, but `compat_id` remains empty. It omits the compatibility failure and returns `missing: []`, even with only the old compatibility set accepted. Published releases skip `pearl_accepted_ids`; if recommendation already equals the release, rollout verification becomes runnable.  
   **Evidence:** An in-memory probe returned **`compat_accepted: false` and `missing: []`**.  
   **Fix:** Treat an absent candidate compatibility ID as missing evidence. Recover it from the verified published compatibility manifest, or block until that evidence is reconstructed. Require `compat_accepted` explicitly.

4. **MEDIUM — Recommendation completion ignores the compatibility target.**  
   **Location:** `scripts/ops/cli-release.sh:542`.  
   **Scenario:** Pearl advertises the candidate binary version, but `compatibility_set.target_id` still names the previous release. Candidate acceptance and privacy approval pass, and the train marks `recommendation_bump` complete without invoking the new repair path. Consumer updates then fail with `coordinator_compatibility_target_mismatch` (`AutoUpdater.swift:294`). This completion predicate is **pre-existing**, but remains inconsistent with the revised step and verification runbook.  
   **Fix:** Require both the advertised version and candidate target ID in the applied config. Select the guarded recommendation edit when either differs, and verify both after restart.

CB/native-MTP feeds remain covered by the existing signed-feed gates; their identities are provenance rather than per-CLI authorization registrations. Version floors are admission thresholds and need not advance on every cut. Routine rollback preserves bytes read under both locks and checks that its own replacement remains before restoring. Optional expiry generation respects rule 10.

Reviewed the complete local diff and touched code. `git diff --check` passed; checkout remained clean. No files edited, Pearl/GitHub contact, or broad build/test workloads.

C/H/M/L = 0/0/4/0
