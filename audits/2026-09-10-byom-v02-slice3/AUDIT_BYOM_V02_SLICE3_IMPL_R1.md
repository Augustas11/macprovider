# IMPL audit R1 — BYOM v0.2 slice 3 (SPEC-010 v1.7 R007 in the coordinator; CLI GGUF digest)

**Diff reviewed:** working tree `git diff origin/main` at `01e76d77` + uncommitted `cmd/coordinator/main.go` (secret-preflight false positive; operator commits it). **Bar:** 0 C / 0 H / 0 M.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 C / 2 H / 4 M / 1 L |
| security-reviewer | 0 C / 0 H / 3 M |
| architect | 0 C / 2 H / 2 M |

All three lanes converged on the same defects; every one resolved in the commit that adds this record:

- **HIGH (code, architect) / MEDIUM (security):** a session whose pair resolved through the feed to a *secondary snapshot-manifest* member could reach a route snapshot carrying the member hash and NO six-value provenance (only GGUF forced the evidence), indistinguishable from the row-bound primary. `recordRouteSnapshot` now fails closed whenever `Provider.ArtifactIdentity` is set and the BYOM binding is not artifact-derived (`artifact identity requires admission and feed evidence`); pinned by `TestSecondaryMLXMemberWithoutAdmissionEvidenceNeverSettles`.
- **HIGH (code, architect) / MEDIUM (security):** no freshness gate. `artifactidentity.Provenance` carries `FeedGeneratedAt`; `Provenance.Fresh(now)` implements SPEC-023 §3.7.6 rules 4–5 (14 days, 10-minute skew); the ws resolver requires `index.Fresh(s.now())` and the buyer settlement prerequisite requires `binding.Provenance.Fresh(s.now())` at route time; the index builder records the feed's stamp. Tests: index freshness boundaries, ws stale → mismatch with the primary path untouched, buyer stale binding → no settlement.
- **MEDIUM (code, architect):** SIGHUP swapped the admission catalog but kept the boot index. The buyer server now exposes a feed-publish observer (`WithAutotuneFeedsObserver`, invoked by `SetAutotuneFeeds` after the publish, outside the lock); boot wires one that rebuilds the index from the EXACT feeds just published and installs it with `ws.SetArtifactIdentityIndex` (nil on a rebuild failure). The catalog swap that precedes the publish drops the previous index (`SetAutotuneCatalog`), so between the two steps a new-release session is primary-only — fail closed, never verified against another release. `reloadCoordinatorConfig` itself is untouched (it is a conformance-mapped fragment whose evidence must not be self-blessed). Pinned in the ws artifact test and `TestAutotuneFeedsObserverReceivesEachRuntimePublish`.
- **MEDIUM (code):** `ModelAdmissionSettlementBindingForRouteSnapshot` accepted a GGUF expected identity with all six values empty. Complete evidence is now required when the expected algorithm is GGUF or any artifact field is present; `TestGGUFAdmissionPredicateRequiresCompleteArtifactEvidence`.
- **MEDIUM (code, security, architect):** CLI file binding ended before the report, and an artifact-backed candidate could degrade to an identity-less offer. `computeEvidence` returns the digest bound to the exact file (path, size, inode, device, mtime at `stat` seconds+nanoseconds) and the locator; `validateCurrent` re-resolves the name through the manifest and re-checks identity immediately before `submitOffer`; a candidate discovery reported as `catalog_matched` / `artifact_hash_available` fails the offer closed on any resolution or identity failure, while a never-artifact-backed candidate keeps the v0.1 identity-less path. Tests: manifest retarget after hashing → `fileIdentityChanged`; artifact-backed unresolvable → offer fails closed; same-size in-place rewrite is a different identity.
- **LOW (code):** millisecond mtime — superseded by the `stat` nanosecond identity above.

Verification: `go test ./internal/artifactidentity ./internal/modelidentity ./internal/pool ./internal/ws ./internal/billing ./internal/buyer` ok; `swift test --filter 'BYOMArtifactDigestTests|BYOMDiscovery|AutotuneArtifactFeedTests|BYOMEvaluation|BYOMModelAdmission'` 96 tests, 0 failures; `check_spec_governance.py` passed.

R2 runs all three lanes over the FULL working-tree diff.
