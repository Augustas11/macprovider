# AUDIT R3 — PR #334 ARCHITECT lane

Re-audit after R2. R2 flagged 1 HIGH (A1 stub metrics → authoritative
UI). Verify closed. Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM.

Working tree: `/Users/augstar/macprovider-pr334-audit`
(branch `audit/pr334`, based on `feat/malibu-native-app`).

R2 findings file:
`/Users/augstar/macprovider-pr334-audit/.omc/artifacts/ask/codex-audit-r2-pr-334-architect-lane-re-audit-after-r1-fixes-confi-2026-07-03T07-08-57-604Z.md`

## R2 finding to verify closed

- **R2 A1 (HIGH)** — Optional metric fields existed in the domain
  model, but `MalibuAgent.consume(.metricsResponse)` still wrote the
  CLI stub's `0/0/0` tuple into them. UI then rendered "$0.00" as
  authoritative.
  Fix in `phase3-binary/app/Sources/Malibu/Agent/MalibuAgent.swift`
  `consume` handler: detect the exact stub shape
  `usdc == 0 && malibu == 0 && uptime == 0 && gpuC == nil && latency == nil`
  and drop it — the presenter then shows "—" and the earnings line
  now says "Today: — USDC · — MALIBU (metrics not implemented)".
  Real metric responses populate at least `uptime_sec > 0` within
  seconds of the daemon coming up.

## Focus for this pass

1. False negatives on the stub-detection heuristic:
   - A real serving Mac with `uptime_sec > 0` and `earnings_usdc == 0
     && malibu_accrued == 0` (nobody hit the model yet today) would
     NOT match the stub tuple because `uptime > 0`. Good.
   - A brand-new serving Mac at exactly `uptime_sec == 0` would match
     the stub tuple and mask real "zero today" metrics for a poll
     cycle. But by the second poll uptime should be >0 and we'd start
     showing real values. Acceptable UX?
2. Any better semantic gate? E.g. a `metrics_ready` capability field
   in the metrics_response frame. Not implemented — the CLI stub does
   not emit it and the SPEC-025 §5.2 wire format does not include it.
   Adding it now would be a wire-format change. Scope-appropriate?
3. Verify presenter output on both shapes:
   - Both metrics nil → "Today: — USDC · — MALIBU (metrics not implemented)".
   - Both metrics real → "Today: $X.XX USDC · Y.YY MALIBU".
   - Mixed one-nil (real-usdc + nil-malibu, or vice versa) —
     `AgentSnapshotPresenter.earningsLine` handles that; is the
     phrasing correct?
4. Re-check A5 (MalibuAgent SRP) after R2 changes:
   - `MalibuAgent` gained `isShuttingDown` and an isConfigured guard.
   - `ControlSocketClient` reads no longer block the actor.
   - Uninstall drain routed through `applicationShouldTerminate`.
   - Is the class still a reasonable P0 coordinator shape, or has R2
     churn re-crossed the SRP line? (R2 verdict already closed A5 as
     acceptable for P0.)
5. Re-check A7 (CLI compat gate) after R2:
   - Fast-fail path (elapsed < 3s + exit code != 0) is intact.
   - The new `isShuttingDown` guard prevents post-shutdown reconnect;
     does it also prevent legit reconnect after a slow-crash? No —
     the flag is only set by `shutdown()`. Legit crash → reconnect
     path is unaffected.
6. Test coverage — the R1 test additions are still valid; do we need
   tests for the new R2 items (readloop-off-actor,
   applicationShouldTerminate, in-memory nonce, stub-metrics
   suppression)? The test target includes
   `AgentSnapshotPresenterTests` covering some of this; the readloop
   change is not unit-testable without a running socket.

## Skip

- Everything already skipped.
- SPEC drift ledger (A9 LOW).
- Two-codec duplication (§12 followup).

## Output format

Same as R1/R2 (A<n>, File, Concern, 12-month trajectory, Fix). Return
`0 CRITICAL, 0 HIGH, 0 MEDIUM` on convergence.
