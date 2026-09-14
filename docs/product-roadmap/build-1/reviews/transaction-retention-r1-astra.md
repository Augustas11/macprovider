# Transaction retention r1 — independent security plan gate

Verdict: **CHANGES REQUIRED — 0 Critical, 0 High, 1 Medium.** The zero-C/H/M gate is not met. This review does not authorize implementation or terminal-record deletion.

Reviewer: independent native GPT-6 Astra, high reasoning; not the proposal author. Review scope is the retention proposal, current reservation/start/cancel behavior, and architecture-r1 M4. This is a plan gate, not the final combined implementation audit.

## Exact review inputs

Base/HEAD: `914f7cafcdbcfc1805a10f4f34167218341d5587`. Working implementation is uncommitted and other lanes remain active. SHA-256 values captured for the reviewed files:

```text
723cc9995dd0fd1ddda764055d5ead002e2d7d9bb53658e25d8e877e05db28b4  docs/product-roadmap/build-1/transaction-retention-addendum-r1.md
92217d889618d1cabfef58b0d22a1b808fd6a23982f2990e2efc4047a65822b2  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
976901b3ad04ed011c8210ccdd629b508dc4a1a664ba033339a549668a77ca80  docs/product-roadmap/build-1/reviews/architecture-r1-astra.md
a5c7a56a68d3ea111289b122cd0a44d41aa4690900ed6f4b6257cf75c3c36e0d  docs/product-roadmap/build-1/plan-r4.md
```

## M1 — Retained history still permanently exhausts executable recovery

**Evidence.** Addendum lines 7–9 retain every started, cancelled, completed, and result-bearing record indefinitely, count retained transactions against the same 1,024 allocation cap, and explicitly provide no archive, deletion command, or other capacity recovery. Current `reserve` (`ModelCatalogTransactions.swift:232–250`) allocates records for new actions. Cancelling an untouched reservation writes `cancel_requested` and `cancelled` (`:312–315`), permanently excluding it from the proposed reclamation rule even when no owner, staging, result, committed intent, or adoption reference ever existed. Once 1,024 such records accumulate, all new prepare/evaluate allocations fail forever. Status, result, and cleanup availability cannot restore allocation capacity.

**Consequence.** The proposal fixes passive polling exhaustion and at-cap reuse, but ordinary explicit cancellation or completed work can still permanently disable preparation and measurement. Recovering then requires an unspecified manual journal intervention. Merely documenting a lifetime limit does not supply the actionable recovery required by plan-r4 or resolve this availability failure. This is a local product/recovery defect; no remote attacker or privilege escalation is asserted.

**Required correction.** Revise and independently gate a supported capacity-recovery policy before accepting the retained-history limit. Separate safely resolved historical records from allocation capacity, or define an equivalent bounded history/recovery mechanism that permits new work after resolved transactions accumulate. Preserve UUID binding, original terminal truth, active owners, unresolved cleanup, committed publication/recovery evidence, and usable or adoption-linked measured results. Do not solve the quota problem by deleting arbitrary terminal journals or discarding protected evidence. If the solution needs a normative/architecture addendum, complete that gate now rather than defer the only recovery path to future work. A full pool of genuinely unresolved/protected live work may fail closed; it must not be indistinguishable from an irreversible lifetime quota consumed by obsolete resolved history.

**Required tests.** Exercise more than 1,024 cancel-before-start/resolved transactions through the supported lifecycle and demonstrate recovery followed by successful new allocation. At capacity, execute the actual recovery operation and verify terminal truth/readback semantics and protection of active owners, pending cleanup/publication, usable results, adoption references, and unrelated files. Keep the proposed passive-polling and reuse-before-cap regressions as separate cases.

## Deletion safety and implementation acceptance obligations

The proposed narrow reclamation predicate is directionally sound: expire only untouched queued reservations, validate identity and private regular-file custody, serialize journal decisions, retain all sidecars/protected evidence, and fsync successful removal. The following details must be explicit in the revised tests and resulting implementation:

- Startup is not entirely serialized by the journal lock. `run` reads the seed under that lock, creates/acquires the owner lock outside it, then reacquires the journal lock to reload the record and enforce freshness before writing `startedAt` (`:355–369`). Race reclamation against both gaps at the 1,800-second boundary. Either a valid start wins and is protected, or the expired/deleted reservation fails before download, drain, publication, or config mutation. Preserve the locked reload/freshness check; never unlink owner-lock files to manufacture reclaimability.
- Sidecar absence must mean a no-follow absence check. Broken symlinks, unexpected file types, inaccessible entries, and inspection errors must protect the record rather than count as absent. Cover result, cleanup, staging, and owner entries independently, including cancellation and terminal transitions racing the scan.
- Bind deletion to the validated journal directory and the exact UUID filename and file identity. Fail closed on replacement or ancestor/root substitution, preserve mismatched bytes, and test interruption before/after unlink and directory fsync. This is not authority to mutate any artifact or recommendation/adoption path.
- A bounded scan must not silently omit protected entries when deciding that capacity is available. Test the declared bound, over-cap/corrupt entries, and repeated concurrent reservation requests without duplicate allocations or deletion of fresh reservations.

These are acceptance obligations for the intended safe design, not additional established vulnerabilities in an implementation that has not yet been written.

## Validation limits

Read-only source/contract tracing and exact file hashing were performed. No runtime test was executed for this plan-only review, and no implementation source was changed. The broader security-r1 findings and final stable-diff review remain separate gates.
