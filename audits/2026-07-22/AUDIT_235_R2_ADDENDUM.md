# AUDIT_235 R2 — re-audit after R1 fixes (thermal-soak instrument)

Branch `research/235-thermal-soak` (macprovider). R1 three-lane codex audit
returned findings; all were fixed. RE-VERIFY, in your lane, that each finding
below is resolved AND that the fix introduced no regression. Report severity
CRITICAL / HIGH / MEDIUM / LOW / INFO with file:line. Merge bar: 0 C / 0 H /
0 M. Read the CURRENT files (not the R1 diff). `go build/test/vet` are green in
`test/network-harness`.

## What changed since R1 (verify each)

### Code / architect lane (benchmark.go, benchmark_test.go)
- **B10 final-window anchoring (was code-MEDIUM / architect-HIGH).**
  `computeBuyerMetrics` now derives `runStart`/`runEnd` from the earliest/latest
  timestamp over **ALL** results (including failed/disconnected ones, whose
  StartUTC/EndUTC are set at dispatch). `computeSustainedTPS(samples, runStart,
  runEnd)` windows `[runStart, runStart+300s)` and `(runEnd-300s, runEnd]`,
  anchored to the true run span — NOT the last successful sample. Verify:
  - A near-end provider disconnect (healthy early samples, then only failures to
    run end) → empty final window → B10 **SKIP**, never a false ~1.0 PASS.
    (test `TestB10_Retention_Skip_ProviderStopsBeforeEnd`.)
  - Run span < 2×window (600s) → zero-count windows → **SKIP**, no overlapping
    windows. (test `TestB10_Retention_Skip_ShortRunOverlappingWindows`.)
  - Final-window lower bound is now **exclusive** (`s.start.After(finalCutoff)`).
  - No new div-by-zero / NaN / boundary regression; existing PASS/WARN/FAIL/
    unarmed-downgrade tests still hold.

### Security lane
- **Prod-host reachability (was HIGH).** `rejectProdHost` in
  `internal/scenario/schema.go` now hard-fails validation for any scenario
  declaring `B10` whose `gateway_url` or `coordinator_url` host is
  `streamvc.live` or a subdomain. Verify a B10 scenario cannot be pointed at
  prod by any URL/env value, subdomain/apex/case variations are covered, and a
  non-B10 scenario is unaffected (test `TestB10_LabOnly_RejectsProdHost`). The
  README prod-stack exception was removed.
- **Bash arithmetic injection (was MEDIUM).** `thermal-collector.sh` now
  strictly validates `--interval` (`^[1-9][0-9]{0,3}$`, ≤3600) and `--duration`
  (`^(0|[1-9][0-9]{0,6})$`, ≤604800) BEFORE any `$((...))`, runs unprivileged
  (sudo scoped to the internal `powermetrics` call), and sets `umask 077`.
  Verify no remaining unvalidated-operand path and that raw device text→`python3
  -c json.dumps` still can't inject.
- **LOW carried/fixed:** `.gitignore` now covers `test/e2e/thermal-soak/out/`,
  `*.ndjson`, and `test/network-harness/out-soak-30b/`. Joiner memory is still
  load-all (documented LOW, local operator tool on own files).

### Architect lane (scenario + README + SPEC + joiner)
- **Scenario duration cap (was MEDIUM):** `requests_per_buyer` 1000→5000 so
  `duration` is the terminating condition even on a fast provider.
- **Thermal-join channel loss (was HIGH):** `join-thermal.py` now matches
  `pmset` and `powermetrics` **independently** (per-source nearest), emits each
  channel's timestamp + `*_skew_s`, and returns null beyond `--max-skew-seconds`
  (default 30). Verify both channels attach and stale samples are dropped.
- **Broken operator recipe (was MEDIUM):** README uses path-stable absolute
  paths, points the window fields to `benchmark_summary.json`
  (`buyer_metrics.sustained_tps`), drops top-level `sudo`, and reframes the
  "safe sustained-load envelope" as a D3 **sweep** (scenario 15 = one stress
  point). SPEC §5 artifact example gained the `sustained_tps` object.

Focus your lane on: are these resolved, and did any fix create a NEW C/H/M?
