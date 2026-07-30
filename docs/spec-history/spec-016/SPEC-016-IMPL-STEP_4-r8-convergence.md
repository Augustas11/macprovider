# SPEC-016 Step 4 — r8 CONVERGENCE

All three audit lanes returned **0/0/0/0**:

| Lane | Round | Verdict |
|------|-------|---------|
| Architecture | r4 | CONVERGENT 0/0/0/0 |
| Security | r5 | CONVERGENT 0/0/0/0 |
| Code | r8 | COMMENT 0/0/0/1 → CLOSED by `<this commit>` (LOW comment drift) |

## Round-by-round closure history

| Round | Code | Security | Arch |
|-------|------|----------|------|
| r1 | 0/2/3/1 — REQUEST CHANGES | 0/1/3/0 — BLOCK MERGE | 1/2/1/2 — BLOCK |
| r2 | 0/1/3/0 — REQUEST CHANGES | 0/1/1/0 — BLOCK MERGE | 0/2/0/0 — BLOCK |
| r3 | 0/1/3/1 — REQUEST CHANGES | 0/1/1/0 — BLOCK MERGE | 0/1/1/0 — BLOCK |
| r4 | 0/0/4/1 — COMMENT | 0/0/1/1 — BLOCK MERGE | **0/0/0/0 — CONVERGENT** |
| r5 | 0/2/3/3 — REQUEST CHANGES | **0/0/0/0 — CONVERGENT** | — |
| r6 | 0/1/0/0 — REQUEST CHANGES (regression introduced in r5) | — | — |
| r7 | 0/1/0/0 — REQUEST CHANGES (deduction overload caught) | — | — |
| r8 | **0/0/0/1 — COMMENT** (LOW comment drift only) | — | — |

The single r8 LOW (stale comments at `runner.go:127, :483, :942`
describing the pre-r7 outcome-level deduction) is closed in
this commit. The CODE behavior was verified correct by the r8
auditor across all 4 `rowOutcomePaid` emit sites.

## Final fix-pass commits per round

| Round | Commit | Surface |
|-------|--------|---------|
| r1 | `b7ff8b1` + `dd72e0e` | TuningProvider plumbing + runner halt primitive; 6 MEDIUMs + 2 LOWs |
| r2 | `fe6a699` | RunNowController + SPKI live-read + AST exact identifiers + halt-race body + §7.1 alert field names |
| r3 | `6eb49c0` | RPC CloseIdleConnections + SIGHUP wiring + stale-producer snap.RunInterval + RunOnce runID + payout_config_* fields + chain-balance event rename + halt-race interface |
| r4 | `bc1409f` | YAML-load structured emit + chain-balance hot_wallet + close-idle test + stale-producer test + BoundViolationError rename + runbook §6 |
| r5 | `e0f7da1` | payout_insufficient_funds path + payout_daily_cap_tripped event + 3 §7.1 field fixes + 3 LOWs |
| r6 | `2935ed6` | Insufficient-funds guard relocated into broadcast path |
| r7 | `1975494` | Deduction co-located with broadcast acceptance (not at rowOutcomePaid) |
| r8 | `<this commit>` | LOW comment drift closure |

## Convergent fix arc summary

The audit-loop discipline caught 7 substantive design refinements across
8 rounds, each landing the next-correct authority layer:

1. **r1 (3 convergent BLOCKers).** `runner.RequestHalt` primitive +
   `TuningProvider` plumbed into 4 reloadable consumers +
   `LowBalance/LowNative` thresholds wired into `RunnerOptions`.
   Pattern: abstraction exists but isn't authoritative.

2. **r2 (1 convergent MAJOR + 1 arch-only MAJOR + 3 MEDIUMs).**
   `RunNowController` centralizes admin run-now contract across all
   3 mux levels; `NewHTTPRPCClient` takes `func() string` so TLS
   verifier reads the live SPKI pin per handshake.

3. **r3 (1 convergent HIGH + 1 arch MAJOR + 4 MEDIUMs).** SPKI
   `CloseIdleConnections` + SIGHUP wiring; runner stale-producer
   uses `snap.RunInterval`; `Runner.RunOnce` returns runID for
   correlation; §7.1 reload event names.

4. **r4 (CONVERGENT arch + 1 convergent MEDIUM + small drift).**
   Architect declared TuningSnapshot exhaustive after a per-field
   enumeration; YAML-load structured emit + chain-balance
   hot_wallet + test gaps.

5. **r5 (CONVERGENT security + 2 HIGH money-path).**
   `payout_insufficient_funds` path implemented per SPEC §4.3 step
   6-7 + §7.1 line 3722; `payout_daily_cap_tripped` event distinct
   from per-payout cap event + loop-break semantics.

6. **r6 (1 HIGH).** Insufficient-funds guard relocated from row-loop
   top INTO `allocateBuildSignBroadcast` — fires only after
   per-payout-cap + daily-cap + existing-attempt decisions.

7. **r7 (1 HIGH).** Deduction relocated from RunOnce row-loop switch
   INTO broadcast paths — co-located with actual spend event, not
   with overloaded `rowOutcomePaid` outcome.

8. **r8 (1 LOW).** Comment drift cleanup.

The recurring pattern (per `[[audit-cycles-are-design-discovery]]`):
each round caught the next "is this primitive used at the right
authority layer?" question that the prior fix-pass exposed. The
abstractions (TuningProvider, halt primitive, RunNowController,
SPKI live-read, runningBalance + in-broadcast check + co-located
deduction) are all correct; the iteration was about *placement* and
*co-location*.

## Branch tip at convergence

- Branch: `impl/spec-016`
- HEAD: `<this commit>` (Step 4 r8 LOW closure)
- Step 4 of SPEC-016 is now CONVERGED.

## Next steps (PR-open)

Per the single-PR consolidation plan in commit `92c8672`:

1. Push `impl/spec-016` to origin (per `[[git-identity-rule]]` —
   plain `git push origin impl/spec-016` routes to Augustas11
   automatically).
2. Open the single PR for SPEC-016 covering Step 1 + Step 2 +
   Step 3 + Step 4 IMPL.
3. File ONE tracking issue per `[[tracking-issue-scope-control]]`
   covering the deferred [arch:4.5] LOW Step 3 advisories
   (`ProduceStaleOutboxRows` LIMIT + chronic single-RPC outage
   telemetry).
4. After PR squash-merges, `git reset --hard origin/main` per
   `[[pr-merge-workflow-rule]]`.

## Validation at convergence

- `go build ./...` from `phase4-coordinator/`: PASS
- `go test -count=1 ./...` from `phase4-coordinator/`: PASS (21 packages)
- `go test -race -count=1 ./internal/payout/...`: PASS
- `gofmt -l phase4-coordinator/internal/payout/ phase4-coordinator/cmd/coordinator/`: clean
- `govulncheck ./...` (per r5 + r8 security verification): no called vulnerabilities
- `git diff --check`: clean

Step 4 CONVERGED on 2026-06-26 across 8 audit rounds.
