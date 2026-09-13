# Build 1 v22 cleanup plan: independent adversarial round 2

Status: **FAIL — 0 Critical, 0 High, at least 4 Medium**. Native GPT-5.6 Sol read-only review of commit `56b73e45bacbdc0e5d43f1bd3d6214fa93aed634`, plan SHA-256 `60dadb9340ad69351e3c4ced5a29e3f96429f8616e2111d5b75188a06d227195`, test SHA-256 `a120cdd37a07c7a8ae7b71240c96a347386fb3a27323748fba5ab06ef7077af5`, inherited v20/v21 and merged SPEC-044. The previous three Medium findings are closed at plan level. The reviewer also identified an order-test overclaim; it remains a gate correction even though the review's numbered Medium list contains four items. No implementation tests were run.

| Severity | Evidence/consequence | Required correction |
| --- | --- | --- |
| Medium | The 29th/fifth recognized temp is not promoted but v22 omits v20's deterministic, descriptor-revalidated cleanup of recognizable stale excess (`v22 plan:28`; v20:208). Ordinary crash debris can wedge. | Preserve bounded stale-excess cleanup, distinguish hostile/ambiguous excess, test both. |
| Medium | Reservation v4 says it retains v3's `schema`, leaving the version literal ambiguous (`v22 plan:30`; draft v3 decoder). | Freeze literal `model_catalog_reservation.v4`, common fields versus new branch keys, and cross-version rejection tests. |
| Medium | `cancel.json` marker includes long escaped root/event fields within the 4096-byte inner cap (`v22 plan:34`), so an admitted valid action can become uncancellable. | Define constructible private cap and preflight exact prospective marker before admission, with worst-case escaped-input tests; keep public ack cap separate. |
| Medium | Near-cap terminal history plus changed 64 projected reservations can block all future projection (`v22 plan:30,32`). | Serialize eligible oldest-history eviction under ordered locks, preserve pending/current terminal semantics, test liveness at byte/count caps. |
| Medium test-gap | Fixed failed-dispatch records have no independent order witness, so a checksum-valid array permutation cannot be recognized as malformed (`v22 test:T8`). | Test writer-preserved insertion/eviction order without claiming intrinsic permutation rejection, or add an independently checkable wrapper order witness while leaving exact SPEC record unchanged. |

The gate remains closed. A correction must retain SPEC-044 pending-history ordering, the seven-kind map, multi-root source retention, phase-specific recovery, and receipt-derived publication.
