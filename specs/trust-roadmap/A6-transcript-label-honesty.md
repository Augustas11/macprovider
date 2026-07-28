# A6 — Transcript / stats-label honesty

**Type**: ship-now · **Size**: S-M (~4-8 operator hours) · **Dependencies**: none

## Problem (roadmap §4.9, from F9 / §8)
- The `autotune --recommend` human transcript surfaces none of #772's
  `confidence`/provenance/drift (JSON-only) and prints "Benchmarked N" where N
  is the *eligible* count, not the benchmarked count (`AutotuneRecommend.swift:2057`).
- The donor message asserts a `$0.0050/hr` gate SPEC-023 v0.4 deleted
  (`AutotuneCommand.swift:958`).
- `/v1/stats/overview` publishes chip-table capacity constants
  (`ProviderHardwareSummary.swift:48-105`) unlabeled.

## Change
Render `confidence`/provenance/drift in the transcript (the
`RecommendationEmitter.swift:169-177` style is the house standard); fix
"Benchmarked N"; delete the `$0.0050/hr` string; label the stats-overview
synthetic capacity fields as estimates.

## Files
`AutotuneRecommend.swift` (`humanTranscript`), `AutotuneCommand.swift:958`,
`internal/stats/handlers.go` + `poolsnapshot.go`; a small SPEC-017 note for the label.

## Non-goals
No new evidence; no scale-triggered `source` object (a larger SPEC-017 change
deferred with the buyer-decision-support surfaces).
