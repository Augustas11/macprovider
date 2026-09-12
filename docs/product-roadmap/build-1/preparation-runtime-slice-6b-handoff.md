# Build 1 preparation runtime slice 6B handoff

Date: 2026-09-12

## Outcome

**Historical and superseded. Do not implement from this handoff.** The private
preparation contract and codec foundation was drafted at commit
`9e72f1fdb6efefbfcd38e175e13444a6f88b17d8` and proposed in PR #1491. That draft
used a five-kind durable-state envelope and raw root bootstrap contract, and it
had focused codec evidence at the time. Later v21/v22 review reopened the gate:
the current Build 1 authority is the seven-kind v22 cleanup/publication
reconciliation in
[`reservation-rebaseline-plan-v22-cleanup-reconciliation.md`](reservation-rebaseline-plan-v22-cleanup-reconciliation.md)
and
[`reservation-rebaseline-test-spec-v22-cleanup-reconciliation.md`](reservation-rebaseline-test-spec-v22-cleanup-reconciliation.md).
The five-kind draft, v1 cleanup record, staging receipt requirement, and
acknowledgement-as-marker shape are not accepted implementation contracts.

## Historical local draft contents

- Closed public preparation action contract without adding pricing or identity authority.
- Strict private records for root identity, reservation, active state, progress, cancellation acknowledgement, failed dispatch, publication receipt, and cleanup recovery.
- Canonical receipt and artifact identity derivation with substitution and correlated-mutation rejection.
- Negative coverage for malformed shapes, noncanonical numbers, unsafe leaves, invalid sizes/counters, root drift, tuple drift, event-key drift, receipt mutation, and illegal nullability.
- Superseded five-kind private-state envelopes with byte-identical temp/durable representation, exact target leaves, canonical payload encoding, temp filename binding, and v20 inner/outer size limits. Root identity remains a separate raw record.

## Not yet implemented by this slice

- Durable filesystem storage and descriptor-safe mutation behavior.
- CLI projection, run, cancellation, and recovery command wiring.
- Malibu action adapter and UX state integration.
- Signed release/updater packaging evidence.

## Qualification state

| Claim | State | Evidence or blocker |
| --- | --- | --- |
| Contract/codec implementation | Superseded local draft | Commit `9e72f1fd`; PR #1491; v22 requires revised seven-kind contracts before use |
| Focused local verification | Historical fixture evidence only | 23 XCTest tests passed for the superseded draft shape |
| Full Swift package | Not green | Existing hang, unavailable MLX Metal library, and unrelated baseline failures recorded in the review artifact |
| Physical Mac preparation | Unproven | Requires later runtime slices and Slice 7 physical evidence |
| Valid network admission | Unproven | Requires coordinator journey after executable wiring |
| Correctly settled request | Unproven | Requires physical end-to-end journey; no economic activation is authorized |
| Production qualification | Blocked | Signed release, updater, hardware, deployed-service, and operator evidence absent |

## Next safe slice

Do not implement descriptor-safe private storage and recovery from this handoff.
First revise PR #1491 and any dependent storage work to the current v22
seven-kind plan/test authority, then rerun the plan gate and complete combined
code/security/architecture audits to zero Critical/High/Medium. Physical
acceptance remains owned by the later Build 1 Slice 7 journey and must not be
inferred from fixtures or local contract tests.
