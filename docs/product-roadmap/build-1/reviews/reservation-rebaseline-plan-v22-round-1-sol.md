# Build 1 v22 cleanup plan: independent adversarial round 1

Status: **FAIL — 0 Critical, 0 High, 3 Medium**. Native GPT-5.6 Sol read-only review of frozen linear commit `45919e65`, plan SHA-256 `ace44babdee3763748daf96ec9640c413835d098090a4fcccc5212b19419289f`, test SHA-256 `339f2bbae381195c5f5ed4f13cb5ae352d72e921d156f127820609ceaa02d60e`, against merged SPEC-044 and current #1491 draft. Earlier `f7b14c49` bytes were invalidated when the author amended a local commit; they received no gate verdict. Review did not run runtime tests.

| Severity | Evidence and consequence | Required correction |
| --- | --- | --- |
| Medium | Single registry `root` cannot retain source attempts on A and B after configuration changes (`v22 plan:26,30`; v20 custom-root tests). | Store and verify a complete saved locator per entry or use explicitly per-root registries; test A/B coexistence and retirement. |
| Medium | V22 freezes six envelope kinds/24 temps while SPEC-044 mandates a separately durable failed-dispatch pending record with its own synced unique temp (`v22 plan:28`; `SPEC-044:644-656`). | Freeze the missing pending target/encoding/recovery inventory and reconcile total cap (seven kinds/28 if enveloped); test combined crash/cap matrix. |
| Medium | `source.json` moves with final staging tree into tombstone; v22 requires validation before tombstone deletion without specifying the phase-specific source location (`v22 plan:24,30`). | Read final/source under intent, tombstone/source under tombstoned, and record-only identity after removed; test tamper and restart at both boundaries. |

Receipt-derived published leaves and receipt-free staging branches survived this review. The pending/cancel/reservations inner payload gap remains open separately and is being integrated into the next plan revision; no code approval follows from this round.
