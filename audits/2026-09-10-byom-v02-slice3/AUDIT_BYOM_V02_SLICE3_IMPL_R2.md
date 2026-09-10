# IMPL audit R2 — BYOM v0.2 slice 3 (SPEC-010 v1.7 R007 in the coordinator; CLI GGUF digest)

**Diff reviewed:** full working tree `git diff origin/main` at `18943017` (R1 fixes `4fb50fb6`, `4f0f56e0`) + uncommitted `cmd/coordinator/main.go`. **Bar:** 0 C / 0 H / 0 M.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 C / 0 H / 1 M / 1 L |
| security-reviewer | 0 C / 0 H / 1 M |
| architect | 0 C / 0 H / 0 M / 1 L |

All three lanes confirmed the R1 fixes present and no R1 item reopened. Everything below resolved in the commit that adds this record:

- **MEDIUM (security, CWE-367):** the CLI recorded the file identity by pathname `stat`, hashed by re-opening the pathname, and re-checked the pathname: a path that resolved to another file while it was opened, restored before validation, would agree on both checks while the digest covered other bytes. `computeEvidence` now opens the blob ONCE, takes the identity from that descriptor (`fstat`) before and after hashing (`BYOMArtifactFileIdentity.of(descriptor:path:)`), hashes through the same descriptor (`GGUFArtifactDigest.compute(handle:)`), and only then re-resolves the name and requires the path identity to equal the descriptor identity. Pinned by `testDigestIdentityIsTakenFromTheOpenedDescriptorNotThePathname` (rewrite through another descriptor visible on the open one; unlink+recreate keeps the read file's inode on the descriptor while the path differs → `fileIdentityChanged`).
- **MEDIUM (code, SPEC-046-R005):** `models evaluate` hashed the complete artifact with no time bound before the probe timeout started. `BYOMEvaluationLimits` gains `artifactHashSeconds` (60 s) as an explicit limit; the digest loop checks the deadline and task cancellation between chunks and throws `hashingBudgetExceeded`, discarding the incomplete digest and recording nothing; evaluation proceeds without artifact identity (the offer, a deliberate binding command, still hashes to completion and re-validates). Pinned by `testHashingIsBoundedByItsDeadlineAndRecordsNothingOnExpiry`. No new evaluation or discovery warning code (Malibu's allow-lists are closed); documented in the runbook.
- **LOW (code, architect):** production-boundary coverage. Added `testOfferSubmissionPostsRecomputedGGUFArtifactHashesForOllamaCandidates` (BYOMAdmissionTests): `submitOffer` for an Ollama candidate posts `artifact_hashes["macprovider.gguf-file.v1"]` computed over the bytes while the manifest's locator lies, and after the blob is replaced by same-size non-GGUF bytes no GGUF digest is ever posted (artifact-backed → `artifactIdentityChanged`). Added `TestSettlementRejectsChangedOrMissingRecordedArtifactEvidence` (billing): the immutability trigger refuses any update to the route-time record, and with the trigger removed the settlement loader rejects changed signer / release / feed digest / artifact id (digest mismatch) and removed evidence (GGUF-requires-evidence validation) — no feed consulted.

Verification: `go vet ./internal/billing`; `go test ./internal/artifactidentity ./internal/modelidentity ./internal/pool ./internal/ws ./internal/billing ./internal/buyer -count=1` ok; `swift test --filter 'BYOMArtifactDigestTests|BYOMAdmissionTests|BYOMDiscovery|AutotuneArtifactFeedTests|BYOMEvaluation|BYOMModelAdmission'` 128 tests, 0 failures; `check_spec_governance.py` passed.

R3 runs the three lanes over the FULL working-tree diff.
