# Build 1 preparation runtime slice 6B handoff

Date: 2026-09-12

## Outcome

The private preparation contract and codec foundation is implemented at commit `9e72f1fdb6efefbfcd38e175e13444a6f88b17d8` and proposed in PR #1491. After reopening the review for an under-bound recovery envelope and then a root-identity representation contradiction, the approved v20 plan led to a separate five-kind durable-state envelope and raw root bootstrap contract. The complete corrected diff passed independent code, security, and architecture gates at zero Critical, High, and Medium findings. Focused validation passed 23 XCTest cases.

## Completed locally

- Closed public preparation action contract without adding pricing or identity authority.
- Strict private records for root identity, reservation, active state, progress, cancellation acknowledgement, failed dispatch, publication receipt, and cleanup recovery.
- Canonical receipt and artifact identity derivation with substitution and correlated-mutation rejection.
- Negative coverage for malformed shapes, noncanonical numbers, unsafe leaves, invalid sizes/counters, root drift, tuple drift, event-key drift, receipt mutation, and illegal nullability.
- Self-authenticating five-kind private-state envelopes with byte-identical temp/durable representation, exact target leaves, canonical payload encoding, temp filename binding, and v20 inner/outer size limits. Root identity remains a separate raw record.

## Not yet implemented by this slice

- Durable filesystem storage and descriptor-safe mutation behavior.
- CLI projection, run, cancellation, and recovery command wiring.
- Malibu action adapter and UX state integration.
- Signed release/updater packaging evidence.

## Qualification state

| Claim | State | Evidence or blocker |
| --- | --- | --- |
| Contract/codec implementation | Implemented locally | Commit `9e72f1fd`; PR #1491 |
| Focused local verification | Verified | 23 XCTest tests passed |
| Full Swift package | Not green | Existing hang, unavailable MLX Metal library, and unrelated baseline failures recorded in the review artifact |
| Physical Mac preparation | Unproven | Requires later runtime slices and Slice 7 physical evidence |
| Valid network admission | Unproven | Requires coordinator journey after executable wiring |
| Correctly settled request | Unproven | Requires physical end-to-end journey; no economic activation is authorized |
| Production qualification | Blocked | Signed release, updater, hardware, deployed-service, and operator evidence absent |

## Next safe slice

After PR #1491 review, implement descriptor-safe private storage and recovery using these exact contracts. Any material contract or architecture change must reopen the v17 plan gate. Physical acceptance remains owned by the later Build 1 Slice 7 journey and must not be inferred from fixtures or local contract tests.
