# Reservation maximum-shape measurement result r3

Date: 2026-09-10. Evidence class: local production-path storage measurement on
the available Mac. This is not MLX inference, hardware qualification, runtime
implementation approval, or production evidence.

## Reviewed authorization

- Plan: `reservation-max-shape-measurement-r3.md`, SHA-256
  `2320b84909c1d0eec24e317af2bedf5bc33c3fc81fc87e7c2149a8b0de57dd77`.
- Independent GPT-5.6 Sol plan approval:
  `reviews/reservation-max-shape-measurement-r3-sol.md`, SHA-256
  `1c06799ac0e2414937fc560170cb009f077b96a48149525179adf57e52ef3267`.
- Test source SHA-256:
  `69fa2294b0036e4a35bc7d2ec63eecf89b36fb4fb23e5f46a14c7da8de9a5e21`.

## Command and result

```bash
cd phase3-binary
swift test --filter 'ModelCatalogReservationCapacityMeasurementTests/testMaximumShapeNaturalStorageReservationProgress'
```

Result: exit 0; one selected XCTest, one passed, zero failed, zero unexpected,
zero skipped; 1,223.543 seconds. The trailing Swift Testing runner selected
zero tests in a separate framework and is not counted as acceptance evidence.

Full log: ignored local artifact
`.omx/artifacts/build1-reservation-max-shape-r3.log`, SHA-256
`311ce7f23630815e0562ae6c93e57f1eda031dd9d3c5a40883b474bb0b152941`.

## Fixture and feasibility

- Initial available bytes: 78,461,747,200; required: 12,884,901,888.
- Eight setup checkpoints completed from 128 through 1,024 records.
- Exact fixture: 1,024 active records, 2,048 events each, 4,194,304 primary
  bytes each, 4,294,967,296 primary bytes total, 174,293-byte index.
- Setup: 1,167.804 seconds, below the reviewed 1,500-second ceiling.
- Maximum production record decode: 1.640422 seconds, below eight seconds.
- Production capture plus proof validation: 0.961168 seconds, below eight
  seconds.

## Six coherent calls

All six calls used the unchanged production eight-second operation budget. Each
returned typed `busy`, decoded the active index once, started the reservation
scan once, made 585 honest `bulk_read` attempts, completed no scan, captured no
retirement, published no cursor, and preserved the index/maintenance state.

| Scenario | Attempt | Seconds | Bulk reads |
| --- | ---: | ---: | ---: |
| terminal_last | 0 | 8.001900 | 585 |
| terminal_last | 1 | 8.442753 | 585 |
| terminal_last | 2 | 8.355837 | 585 |
| queued_last | 0 | 8.518524 | 585 |
| queued_last | 1 | 8.835732 | 585 |
| queued_last | 2 | 8.435251 | 585 |

The terminal-to-queued transition and both full preservation boundaries passed.
There were six call lines, eight setup lines, no `RESERVATION_MAX_ABORT`, and no
remaining `ReservationMaximumShape-*` test root after teardown.

## Supported conclusion

At this exact supported maximum shape, the current repeated-prefix reservation
scan cannot reach a valid reclaimable record in the final slot within its
unchanged eight-second budget, for either a terminal or queued final record.
The identical 585-read prefix across three attempts in each scenario supplies
the reviewed evidence of repeated-prefix starvation and establishes necessity
for the already planned bounded-progress structural fallback.

This result does not select or approve an implementation, limit change, clock
change, or production rollout. The structural runtime portion remains gated by
its normative plan, implementation tests, full Swift regressions, and final
independent complete-diff reviews. The measurement must be rerun if replay onto
the new base changes any measured production reservation, retention, evidence,
budget, or fixture source.
