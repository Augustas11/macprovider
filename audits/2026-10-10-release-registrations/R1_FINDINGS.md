=================== code
## Raw output

```text
Gate fails: **three MEDIUM findings**, all introduced by this PR.

1. **MEDIUM — scripts/ops/cli-release.sh:821, :837 — Existing unsigned tags pass the signed-tag gate.**  
   `release_tag_state` checks only annotation and the peeled SHA. An unsigned annotated tag on the candidate returns `on_candidate`; status marks it done, and `_release-tag` returns before `git verify-tag`. Promotion is therefore permitted without the promised signature verification.  
   **Fix:** Fetch and verify the exact remote tag object before accepting it. Add tests for unsigned and invalidly signed annotated tags on the correct candidate.

2. **MEDIUM — scripts/ops/lib/release-registrations.py:263 — Expiry checks discard timezone offsets.**  
   At 10:00 UTC, `12:00:00+03:00` is already expired, but the helper accepts it. Conversely, `08:00:00-03:00` is still valid, but the helper rejects it. This can permit promotion despite the coordinator refusing the configured identity, or unnecessarily block promotion. Reproduced both cases in memory.  
   **Fix:** Parse timezone-aware timestamps and compare their actual instants, matching Go’s `time.Time` semantics. Test positive and negative offsets.

3. **MEDIUM — scripts/ops/lib/release-registrations.py:289 — Timestamp truncation permits unapplied registrations.**  
   With coordinator start `1000` and config mtime `1000.9`, `int(mtime) <= started` reports `config_applied=true`. A registration written after startup within that second can pass even though the running coordinator never loaded it. Reproduced this verdict in memory.  
   **Fix:** Compare disk digests against the process’s existing boot `coordinator_config_applied` evidence. At minimum, preserve timestamp precision and refuse ambiguous comparisons. The test’s moving “started now” stub misses this case.

Read the complete diff and affected code. Matching JSON-only uploads are recoverable on retry; conflicting existing bytes are refused. No injection path found in the new allowlisted SSH arguments.

Validation: shell syntax and diff whitespace checks passed; repository remained unchanged. No Pearl or GitHub contact; full suites were not run.

C/H/M/L = 0/0/3/0
=================== security
## Raw output

```text
Security gate: **FAIL** — one MEDIUM finding.

- **MEDIUM — [scripts/ops/cli-release.sh:821](/Users/augstar/macprovider-release-registrations/scripts/ops/cli-release.sh:821), also :837.** An existing annotated tag pointing to the candidate SHA is classified as `on_candidate` without signature verification. Status marks the signed-tag gate complete, and `_release-tag` returns before reaching `git verify-tag`. An unsigned or invalidly signed annotated tag pushed beforehand therefore satisfies the gate. A local stub reproduced `on_candidate` without supplying any signature evidence. **Fix:** fetch the exact remote tag object into an isolated ref, verify its signature against the approved operator signer policy, and verify its peeled commit before accepting it. The promotion workflow’s target-only verifier is **pre-existing**; this PR’s new signed-tag gate inherits that gap.

No additional findings in remote argument construction, staged ownership/modes, metadata signature and version checks, secret handling, or metric cardinality. Staging re-verifies against the repository’s pinned release key; the coordinator independently verifies signatures and identity fields.

Reviewed the complete diff and touched code. No files edited; no Pearl or GitHub contact.

C/H/M/L = 0/0/1/0
=================== architecture
## Raw output

```text
Architecture gate: **FAIL**. The PR improves registration ordering, but does not yet prove approval in the running coordinator or enforce it at publication.

1. **HIGH — Disk approval is treated as live approval.** [release-registrations.py:305](/Users/augstar/macprovider-release-registrations/scripts/ops/lib/release-registrations.py:305) verifies metadata with the current on-disk public key; the coordinator caches its key at startup and loads identities separately. A replaced key, service-user read failure, or failed reload can leave the candidate unapproved while `registrations` passes. The canary’s zero-rejections-in-ten-minutes check also passes when no privacy advertisement occurred during that window. An in-memory probe confirmed evaluation returns `missing: []` even with `privacy_class_enabled=false`. **Fix:** require positive, candidate-bound approval from the running authority before canary completion and promotion. Use the loaded-identity metric as supporting evidence and prove successful privacy enrollment/posture.

2. **MEDIUM — Registration enforcement ends at workflow dispatch.** [cli-release.sh:472](/Users/augstar/macprovider-release-registrations/scripts/ops/cli-release.sh:472) checks registrations before dispatching promotion. The promotion workflow’s existing pre-publication gate checks feeds and recommendation, but not compatibility/privacy registrations. A queued environment approval can outlive a config rollback or identity removal, then publish an unregistered candidate. This publication-time omission is **pre-existing and remains unclosed**. **Fix:** recheck candidate-bound live registrations immediately before undrafting, alongside the existing feed gate.

3. **MEDIUM — One-time setup requires bypassing the ops entry point.** [privacy-class-beta-operations.md:90](/Users/augstar/macprovider-release-registrations/docs/runbooks/privacy-class-beta-operations.md:90), mirrored by [cli-release.sh:99](/Users/augstar/macprovider-release-registrations/scripts/ops/cli-release.sh:99), instructs an in-place config edit and direct coordinator restart. The new step blocks but supplies no executable setup path through `status` → `next --run`. This conflicts with AGENTS.md rules 5 and 8, and provides no guarded health-check/rollback sequence if the configured key prevents startup. **Fix:** implement the setup through `scripts/ops/`, including locks, key/readability preflight, config backup, restart, health verification, and restoration on failure.

4. **MEDIUM — Historical fleet-wide rejections make recovery require another restart.** [cli-release.sh:513](/Users/augstar/macprovider-release-registrations/scripts/ops/cli-release.sh:513) blocks rollout verification on any process-lifetime unapproved-identity rejection, including unrelated providers. Hot-registering the missing identity cannot clear the counter; the prescribed recovery is another coordinator restart. An old or unsupported provider can immediately block it again. **Fix:** evaluate candidate-specific failures after registration against a recorded baseline and require positive recovery evidence. Retain the lifetime counter for observability without making its historical value an uncleareable rollout gate.

5. **LOW — An existing unsigned annotated tag satisfies the “signed tag” gate.** [cli-release.sh:819](/Users/augstar/macprovider-release-registrations/scripts/ops/cli-release.sh:819) checks only the remote object and peeled commit. `on_candidate` skips signature verification, including in `_release-tag`. The underlying workflow’s target-only check is **pre-existing**. **Fix:** fetch and verify the exact remote tag object before marking the signed-tag step complete.

CB/native-MTP feed identities are currently provenance rather than per-CLI authorization gates; their existing promotion feed checks remain relevant. Version floors are admission thresholds, not registrations to advance on every cut. Additive privacy metadata and retention of the prior compatibility target support rollback. The optional-expiry change respects rule 10.

Reviewed the complete local diff and touched paths. `git diff --check` passed; checkout remained clean. No Pearl or GitHub contact, edits, or broad test/build workloads.

C/H/M/L = 0/1/3/1
