# Round 3 dispositions (final round under the three-round cap)

Round 3 verdicts: code 0C/1H/1M/0L, security 0C/0H/1M/0L, architecture 0C/0H/2M/3L. All lanes verified the round-1 and round-2 fixes, and accepted the kept items (scheduler-step cohort accounting, divergence precedence, route-table reuse, pre-existing store trust boundary).

All round-3 findings are fixed in the commit after this file. No fourth audit round was run (three-round cap):

- Cohort queue timeout fell through to a generic deferral (code HIGH): a `queueWaitTimedOut` from the cohort batch is now `probeShapeUnmet` at that width. As with a cohort shortfall, it fails closed unless a buyer request was in flight or started during the step.
- Shape-unavailable decision during a re-measure left the re-measure markers (code MEDIUM, architecture LOW): that branch now clears `inProgressSlots`, `remeasureInProgress` and `remeasureAfter`, and stamps `decidedAt`. It re-runs when the bound reaches 2.
- First-width divergence before a serial baseline read as `serial_baseline_unavailable` (architecture MEDIUM): with nothing verified, the first measurement's divergence is now the decision before the serial guard. Test: `testCrashBeforeAnySerialBaselineRevokesAPriorGrant`.
- SPEC said every width up to the scheduler rows is checked (architecture MEDIUM): FR-CB10 item 2 now says up to the ladder bound, including the probe shape bound.
- Grants were not capped by the queue limit (security MEDIUM): `grantableRows` is now min(scheduler rows, queue limit, probe shape bound). Test: `testProbeShapeBoundCapsTheLadderOnSmallPools`.
- Decision list without `single_row`, and the change log's crossing-row wording (architecture LOW): both fixed.

## Closure check (Codex, after e838fce56)

Verdict: 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW. Every round-3 finding is
CLOSED with file:line evidence and a covering test: the cohort timeout maps to
`probe_shape_unmet`; the shape-unavailable re-measure clears its markers; a
first-width divergence precedes the serial-baseline guard; SPEC-038 FR-CB10
names the ladder bound; and grants are capped by scheduler rows, queue limit
and probe shape on every grant path. e838fce56 introduced no new
finding. Prompt: `PROMPT_CLOSURE.md`.
