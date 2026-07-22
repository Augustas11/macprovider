# RESEARCH_235 — resume state (thermal/sustained-load soak instrument)

**Branch:** `research/235-thermal-soak` (off origin/main). Fresh worktree
`/Users/augstar/macprovider-235`. Serves issue #584 (canary redesign) + #463
(waived G3 soak).

**Scope this session: INSTRUMENT ONLY.** The soak campaign (Deliverable 3's
actual run) is PARKED — it needs a dedicated lab Mac, unavailable now. Do NOT
soak the prod provider (reproduces the #584 outage). Same instrument-now /
campaign-later split as RESEARCH_234's cold cell.

## Invariant ID used: **B10** (NOT B8)

Prompt said "B8", but B8+B9 are taken by RESEARCH_236 (PR #696, OPEN, not
merged — sticky cache-reuse). main has through B7. Used **B10** to avoid
collision regardless of merge order. Scenario allow-list + SPEC + dispatch all
use B10.

## Deliverables — status

- [x] **D1a scenario** `test/network-harness/scenarios/15_thermal_soak.yaml`
  — 3600s (45–60 min), 2 buyers, stream:true, interval floor 1s (continuous
  busy, ≤2 concurrent within N_eff=2.5), 30B model, max_tokens=64. Targets
  `${LAB_GATEWAY_URL}`/`${LAB_COORDINATOR_URL}` (unset by default → validation
  fails rather than hitting prod). Invariants B1-B5,B10. Dry-run validates.
- [x] **D1b invariant B10** in `internal/benchmark/benchmark.go` — windows
  streaming decode-TPS p50 (same basis as B2, NOT non-streaming sustained_tps)
  into first-5min / last-5min windows; retention = final/first. Bands PASS
  ≥0.85 / WARN ≥0.70 / FAIL <0.70 (PROVISIONAL). SKIP if <8 samples/window.
  Emits first_window_tps_p50, final_window_tps_p50, retention, sample counts.
  **Gate UNARMED**: scenario flag `sustained_gate_armed` (default false) →
  would-be FAIL downgraded to WARN until a lab run calibrates. Case dispatch +
  evalB10 + computeSustainedTPS + 7 unit tests in benchmark_test.go
  (PASS/WARN/FAIL-armed/FAIL-downgrade-unarmed/SKIP×2/window-math). SPEC §3.5
  row + §4.15 scenario section. Also added B10 to scenario invariant allow-list
  (schema.go) + committed-scenarios test seeds LAB_* placeholders.
- [x] **D2 thermal capture** `test/e2e/thermal-soak/` (sibling to coldwarm-ttft):
  `thermal-collector.sh` (pmset + powermetrics → timestamped NDJSON),
  `join-thermal.py` (joins per_request.jsonl streaming-TPS to thermal by ts,
  binned; pure stdlib), `README.md`. Scripts syntax-checked + joiner smoke-tested.
- [ ] **D3 soak report + envelope** — PARKED (needs lab Mac). README documents
  the run recipe + the 4 questions a run must answer.

## Build/test status
`go build ./...` OK. `go test ./...` GREEN (whole harness). `go vet ./...` clean.
Scenario 15 `--dry-run` validates; fails safely without LAB_* env.

## Audit status
- R1 (3 lanes) DONE: code 0C/0H/1M/1L, security 0C/1H/1M/2L, architect 0C/2H/2M.
  All findings FIXED in R1-fix commit:
  - B10 final-window anchoring (code M / arch H): now anchors to TRUE run
    start/end over ALL results (incl failures); near-end disconnect → empty
    final window → SKIP (not false PASS). Span <2W → SKIP. + LOW boundary fix
    (exclusive finalCutoff). 2 new tests (provider-stops-before-end, short-run).
  - Prod-host reachable (security H): rejectProdHost() in schema.go hard-fails
    any B10 scenario whose gateway/coordinator resolves to streamvc.live(+subs).
    New regression test. README prod-stack exception removed.
  - Thermal-join channel loss (arch H): join-thermal.py matches pmset +
    powermetrics INDEPENDENTLY, emits per-channel skew, bounds max skew.
  - Bash arithmetic injection (security M): strict digit+bound validation of
    --interval/--duration before $((...)); run unprivileged, umask 077.
  - Scenario duration cap (arch M): requests_per_buyer 1000→5000 so duration
    terminates. README reframes envelope as a D3 sweep, scenario 15 = 1 point.
  - README recipe (arch M): path-stable abs paths, points to
    benchmark_summary.json (buyer_metrics.sustained_tps), no top-level sudo.
  - LOW: .gitignore thermal artifacts; SPEC §5 example gains sustained_tps.
- R2 (3 lanes): code 2H/1L, security 1H/1L, architect 1H/2M/2L — ALL from the
  R1 prod-host DENYLIST being bypassable + skipped when benchmark.enabled=false.
  R2-fix: replaced denylist with POSITIVE lab-host allowlist (LabHostAllowed:
  loopback/private/link-local/localhost only), applied regardless of
  benchmark.enabled, + CheckRedirect guard in loadgen; joiner mirrors B10
  success filter; stale skew→null; wording/SPEC-example fixes.
- R3 (3 lanes): **ALL 0 CRITICAL / 0 HIGH / 0 MEDIUM** — code APPROVE,
  security APPROVE, architect WATCH. Merge bar MET. Remaining LOWs carried
  documented: (1) scoped IPv6 link-local `[fe80::1%25en0]` rejected by
  net.ParseIP — FALSE-NEGATIVE, fails safe (never allows prod); (2) join-thermal
  loads inputs fully into memory (local operator tool); (3) redirect barrier
  lacks a dedicated regression test (impl verified correct by all 3 lanes).
  Post-R3 doc-only fixes applied (no audited logic touched): README stale
  rejectProdHost→LabHostAllowed; SPEC §5 example scenario name thermal_soak.

## Next steps (this session)
1. [x] R2/R3 three-lane codex re-audit — R3 all 0 C/H/M. DONE.
1b. [ ] (superseded) via `omc ask codex
   --prompt "$(cat <promptfile>)"`. Prompts under `audits/_prompts/` or
   `audits/<date>/`. Bar 0 C/H/M. Loop→fix→re-audit.
2. [ ] Rebase on origin/main.
3. [ ] Open PR as Augustas11 (`GH_TOKEN=$(gh auth token -u Augustas11) gh pr
   create`), request antfleet-ops review. Do NOT merge (user lands it).
   **PR body MUST have SPEC-GOVERNANCE-DECLARATION-BEGIN/END block** (model on
   PR #696) or the `check` gate fails. behavior_change yes, contract_change
   none, issue #584, specs SPEC-031 (+SPEC-023 if autotune touched — it's NOT),
   requirements SPEC-023-R001 (verify in specs/CONFORMANCE.json), authority
   ["canary-sanction-lifecycle"] (verify specs/AUTHORITY.json), arbitration
   ["UNKNOWN"], tests [go test/vet cmds], journeys ["not-required"].

## Commits pushed so far
- B10 invariant + tests (benchmark.go, benchmark_test.go)
- scenario 15 + allow-list + SPEC §3.5/§4.15
- thermal-soak collector/joiner/README + this resume file

## Parked for lab-Mac campaign
The actual 45–60 min soak run (D3). First run = the real deliverable: produces
the safe-sustained-load envelope for the #584 canary redesign, recalibrates B10
thresholds, and answers the #463 (48h soak waiver) recommendation. Run recipe
in `test/e2e/thermal-soak/README.md`.
