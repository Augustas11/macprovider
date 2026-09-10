# AUDIT — BYOM v0.2 slice 4 IMPL round 3 (codex, code-reviewer + architect; security at bar since R2)

Prompt: `AUDIT_BYOM_V02_SLICE4_IMPL_PROMPT.md` (ROUND 3 EXTRA). Diff: `git diff origin/main` at `ce7458e0` + uncommitted `cmd/coordinator/main.go`.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 1 HIGH / 2 MEDIUM / 0 LOW / 0 INFO |
| architect | 0 CRITICAL / 1 HIGH / 0 MEDIUM / 0 LOW / 0 INFO |

R2 fixes confirmed (session epoch on hello/heartbeat, section ownership, approval precedence, (ii) ordering, parse/decode errors, feed commit inside the hold).

## Findings and disposition (all fixed in the follow-up commit)

**HIGH — publication sweep ran before session identities were re-verified; the refresh did not advance the epoch** (both lanes). `PublishArtifactIdentitySetsWith` swept immediately, `RefreshTier2HashStatuses` re-verified sessions later, and `UpdateModelIdentities` mutated verdict/pin/artifact binding without touching `ModelAdmissionSessionEpoch` — a feed-member session whose release set disappeared could keep a re-stamped binding and pass compare-and-insert. Fix: `afterReleasePublished` now owns the ordered sequence publish → `refreshSessionIdentities()` (registry-wide re-verification, registry → release order, no section) → per-provider sweeps with (a)/(d) evaluation → survivor re-stamp; `UpdateModelIdentities` bumps the session epoch whenever the identity fingerprint changes; `RefreshTier2HashStatuses` = publish-staged (which runs the full sequence) + refresh. Test: `TestModelAdmissionPublicationRefreshesSessionsBeforeSweep` (release-1 set dropped on a re-stamp → session loses `hash_verified`, epoch advances, candidate revoked `runtime_identity_drift`, in-flight guard fails closed).

**MEDIUM — feed bytes committed before the internal release inside the hold** (code). Fix: `publishReleaseLocked` first, `commit()` last, both under the one write-lock hold; a lock-free feed reader can at worst see previous bytes against the new internal release (a provider admitted from them is a retained compatible-previous release), never unrecognised new bytes. Test: `TestModelAdmissionEpochOnModelIDChangeAndFeedCommitOrder`.

**MEDIUM — model-id-only heartbeat change did not advance the epoch** (code). The fingerprint compare ran before `p.ModelID` was assigned. Fix: compare after the assignment. Test: same.
