# Long hash / short controls r1 — independent Astra architecture gate

Verdict: CHANGES REQUIRED. 0 Critical, 0 High, 1 Medium, 0 Low.

Exact reviewed plan: `docs/product-roadmap/build-1/long-hash-control-addendum-r1.md`.
SHA-256: `31b861879fe0607a523ab10b1811f2ec393b48512e6e423baf9ea2299625d9e7`.
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587` and current implementation. Reviewed transaction owner, store reconciliation, durable publication and the relevant exact-selector/short-helper requirements in transaction-control-addendum-r3. No source edits, subagents, physical model reads, or test execution.

## HASH-M1 — Moving hashes alone leaves unbounded work in the short control’s global journal critical section

Severity: MEDIUM. Confidence: high.

Evidence: `ModelCatalogTransactions.swift:309–339` wraps the entire interrupted-owner reconciliation in `locked`. At lines 315–318 it invokes recursive `cleanup(id)` before checking published bytes. That cleanup enumerates/removes up to 100,000 staging entries. R1 moves content hashing out of the lock and caps seal metadata enumeration, but does not remove or bound this earlier recursive cleanup. The independently evolving transaction-control-r3 contract still explicitly lists artifact hashing/cleanup after selector verification under the same journal lock (lines 328–339), so an implementer cannot safely infer that this behavior is superseded. `locked` itself currently uses blocking flock without a deadline.

R1 also permits complete metadata/tree rechecks in the publication critical section and up to ten seconds of interrupted metadata traversal. A ten-second traversal plus lock acquisition/journal writes cannot meet a ten-second helper lifetime; a global lock held that long can also push another owner’s five-second heartbeat beyond its ten-second contract. Bounding file count does not bound slow individual filesystem calls or total lock wait.

Consequence: valid owner-loss recovery with large leftover staging can still time out and be killed repeatedly before terminal journal persistence. While it holds the global lock, unrelated owners cannot emit progress or observe cancellation. The proposed correction would therefore retain the practical responsiveness defect it claims to resolve, even with a valid metadata seal and no weight hashing.

Required r2 correction:

- Explicitly supersede short-control recursive staging deletion. After owner loss, short controls may record cleanupRequired and expose the existing independently confirmed long cleanup operation; they must not enumerate/remove the staging tree as part of status/cancel/result. Preserve staged/published evidence when verification is incomplete. No new command is needed.
- Specify a control deadline covering lock acquisition, seal decoding/traversal and terminal writes. Avoid blocking global-lock waits; fail busy/unavailable without mutation when the budget is exhausted.
- Keep potentially long seal inventory traversal outside the global journal lock while retaining appropriate exact per-operation owner exclusion, then reacquire the short lock and revalidate the selector and current record before mutation. Alternatively provide an explicit smaller critical-section budget that preserves the heartbeat/control deadline and fails closed before publication. Do not merely relabel a ten-second metadata walk as a short lock.
- Test stalled staging cleanup, slow metadata enumeration and lock contention, not just a blocking content hash. Show an unrelated owner keeps heartbeat/cancellation access, short controls return or terminate within their bound without changing another generation, and incomplete recovery leaves an explicit cleanup/verification path rather than false success.

## Seal design assessment

The proposed reuse of a prior actual byte-verification proof is suitable for historical transaction terminal truth within the stated trusted-operator-UID boundary. It is not a new cryptographic proof of present model bytes and must not become readiness, artifact identity admission, recommendation/adoption, routing, or settlement authority. Fresh subsequent use continues through full canonical content verification. A private seal plus journal digest does not defend against an operator UID that can rewrite both; r1 explicitly does not claim that threat boundary.

Implementation must bind the seal to the exact transaction/generation/context and authenticated target/revision/hash/candidate authority, keep descriptor-based no-follow regular-file ownership and no-hardlink checks, include device/inode identity and complete relative inventory, and compare high-resolution file size/mtime/ctime around actual reads. Rename-adjusted directory identity must not drop file stability checks. A seal generated from a copy cannot authorize reuse of a different incumbent inode; existing-destination reuse needs its own actual verification and stable seal. Extra files, same-size ordinary overwrite, replacement, corrupted/missing/oversized seal, incomplete metadata proof or deadline must never turn write-ahead intent into succeeded.

Publication intent, seal persistence and final directory durability must be ordered so crash recovery succeeds only for the exact previously verified published object. Cancel before commit prevents publication; cancel after commit can disclose too late. A stale generation/control response must not mutate a newer record. Tests must include crash after intent but before rename, after rename before post-rename identity persistence, existing-destination reuse, and post-verification ordinary mutation.

These constraints are compatible with r1’s intent and do not establish an additional finding. HASH-M1 must be resolved in a frozen r2 before implementation. Existing full-diff, operation-custody, cleanup and physical-qualification gates remain independent.
