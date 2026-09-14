# Transaction retention r4 — independent security plan gate

Verdict: **APPROVE PLAN — 0 Critical, 0 High, 0 Medium, 0 Low.** The three prior retention findings are resolved at design level. This approves the exact retention proposal. Implementation still awaits the forthcoming transaction-control-r3 gate and normative completion, plus the final implementation/test gates. The generation contract reviewed here is retained from control-r2; control-r2 as a whole was rejected with two Medium findings and is not approved by this report.

Reviewer: independent native GPT-6 Astra, high reasoning; not the proposal author. Base/HEAD: `914f7cafcdbcfc1805a10f4f34167218341d5587`. Scope: full r4 retention design, prior r1/r2/r3 findings, current store result/cleanup behavior, and the actual operation-generation control contract. No implementation was performed.

## Exact review inputs

```text
caa5fe5ea845651312680cb5ceebf59b9c3e82d0490525d561f01a89165221dc  docs/product-roadmap/build-1/transaction-retention-addendum-r4.md
53c6f2a431e1e4317d7fdd01f4c423d736877ab678227480d6714f04ec81edf4  docs/product-roadmap/build-1/transaction-control-addendum-r2.md
ccf517366232ad36787c8542a677b04b83914ea5dc482acb68769935f771bf53  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
```

The store is current uncommitted corroborating source, not an implementation of the approved retention design. Other lanes remain active.

## Prior finding closure

| Prior finding | Evidence of correction | Consequence avoided |
| --- | --- | --- |
| R1 M1: retained history consumes a permanent 1,024 allocation quota | R4 lines 7–9 separate active capacity from logical archived history; retirement retains original UUID files; acceptance tests exceed 1,024 resolved/cancelled transactions | Resolved historical work no longer permanently disables future preparation/evaluation |
| R2 M1: fresh queued reuse skips completed-result indexing | R4 lines 84–96 publish at successful completion and perform bounded indexing before every adoption projection independently of reservation reuse | A completed evaluation remains discoverable with fresh successor B, including restart before pointer publication |
| R3 M1: cleanup changes the full-record digest and invalidates the pointer | R4 lines 72–80 bind the immutable success commitment and original result bytes, excluding precisely identified mutable cleanup bookkeeping; full-file digests remain transient retirement checks | Successful cleanup preserves pointer equality and permits subsequent retirement without generic mismatch repair |

The r4 cleanup/restart and substitution tests cover the concrete prior failure trace. No additional severity finding remains in the reviewed design.

## Operation-generation and legacy boundaries

**Evidence.** Transaction-control-r2 Section D requires separate canonical UUIDs for transaction ID and operation generation, reservation before action projection, stable evaluation generation, a fresh cleanup generation for each explicit attempt, and exact kind/generation selection before reconciliation or mutation. R4 takes the actual persisted evaluation `operationGeneration` and matching original terminal event generation into the commitment. It explicitly rejects inferred counters, timestamps, transaction-ID substitution and missing-generation defaults. Cleanup cannot replace the original evaluation selector.

**Assessment.** These generation contracts align. The current store does not yet contain the generation fields, so this is an integration prerequisite rather than existing runtime evidence. Retention must consume the transaction owner's implemented selector and validated-result helpers after the forthcoming control-r3 approval and normative completion. Control-r2's complete proposal remains rejected with two Medium findings; this approval neither overrides that verdict nor authorizes a separate invented generation scheme. Re-review any change to the generation contract in the approved successor.

**Legacy evidence.** Current `validatedCommittedResult` requires an evaluation record, persisted committed flag and `resultSHA256`, exact result-byte digest equality, successful historical parsing with `enforceFreshness: false`, and exact model/catalog/revision/artifact binding. R4 permits retirement of safely resolved generationless history only when this owner-controlled historical validation supports its evidence. It prohibits generating a pointer/action selector for that history, preserves all bytes, and retains unsupported/corrupt evidence in active capacity. The exception also remains subject to the ordinary resolved-cleanup/staging/publication predicates.

**Assessment.** This removes a healthy-legacy lifetime quota without manufacturing a control/adoption authorization. It does not imply a public legacy result/control endpoint: only read paths already allowed by the control contract may be exposed. Flagless new controls and generationless positive actions remain prohibited. The specified 1,024-entry legacy migration/retirement test and unsupported-result negatives must prove this distinction.

## Security properties retained for implementation verification

- Active intent precedes primary creation; incomplete allocations are recovered conservatively. Membership is checked under the stable journal lock before every write. Archived history cannot be resumed or overwritten.
- Migration is bounded once, never truncates an over-bound scan, and never rebuilds a missing/corrupt index by guessing from history. Routine access uses bounded active metadata and direct UUID/context lookups.
- Retirement holds the journal lock and obtains the stable owner lock nonblocking, then rechecks membership, record, sidecars, generation and inode identities. Both owner-start gaps and cleanup-start races remain explicit deterministic test cases.
- Every filesystem operation must satisfy descriptor-relative no-follow custody, only-ENOENT absence, private regular-file/bounded-read checks, and exact temporary-file ownership. Lock inodes are never unlinked; no historical result, artifact or adoption evidence is deleted for quota recovery.
- Success is committed before pointer publication; pointer failure cannot rewrite terminal truth. Bounded projection recovery retries indexing without nested locks or history enumeration, and pointer publication precedes retirement.
- Pointer commitment validation must use the preserved historical result-validation rules; current adoption freshness/authority checks remain decisive for exposing or executing the action. An old result becoming stale must not be mistaken for corrupt historical bytes. Legitimate cleanup preserves the commitment; actual identity/result/terminal-event substitution fails closed without pointer repair.
- Excluding earlier event-container data from the pointer digest is not permission to rewrite event history or skip full event validation. The successful terminal object, its selector, sequence and original success truth remain pinned, and history preservation is independently required.

These are the proposal's acceptance boundaries, not extra implementation authority or a claim that all tests currently pass.

## Validation and limits

Verified exact file hashes, compared r4 against previously reviewed r3 and traced the current result validator, cleanup primary-record update and control-r2 Section D. No runtime tests were executed for this plan review. Final acceptance still requires the specified deterministic migration/capacity/owner/crash/pointer tests and the complete resulting code/security/architecture audit. This report does not certify physical MLX operation, settlement or a release artifact.
