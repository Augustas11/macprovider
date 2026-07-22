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

## Next steps (this session)
1. [ ] Three-lane codex audit (code/security/architect) via `omc ask codex
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
