## RESEARCH_235 — P3 thermal / sustained-load soak instrument (B10)

Builds the **instrument** for a thermal/sustained-load soak that characterizes
issue #584 (2026-07-13: sustained synthetic load collapsed a healthy provider
~30 → 8.9 → 5.3 tok/s, then stale heartbeats → WS EOF → removed from pool — a
thermal/sustained-throughput degradation no test in the repo captured). Same
instrument-now / campaign-later split as RESEARCH_234's cold cell.

**The soak run is PARKED** — it needs a dedicated lab Mac (running it against
prod reproduces the #584 outage). This PR ships only the instrument so it is
ready the moment hardware exists.

### What's in this PR

1. **Benchmark invariant `B10` "sustained streaming-TPS retention"**
   (`test/network-harness/internal/benchmark/benchmark.go`). Windows the
   per-request *streaming* decode-TPS distribution (tokens / (last_byte −
   (start + ttft)) — same basis as B2, **not** the structurally-unreliable
   non-streaming `sustained_tps` field) by wall-clock start into a first-5min
   and last-5min window; `retention = final_p50 / first_p50`. Bands **PASS ≥
   0.85 / WARN ≥ 0.70 / FAIL < 0.70**, SKIP if either window has < 8 samples.
   Emits `first_window_tps_p50`, `final_window_tps_p50`, `retention`, and
   per-window sample counts.
   - **Invariant ID is B10, not B8.** B8/B9 are claimed by RESEARCH_236 (open
     PR #696). main has through B7; B10 skips that range so the two never
     collide regardless of merge order.
   - **Thresholds are PROVISIONAL and the gate is UNARMED.** A new scenario flag
     `sustained_gate_armed` (default false) downgrades a would-be FAIL to WARN
     so the uncalibrated gate can never block a run. Arm it only after the first
     lab soak recalibrates the thresholds (mirrors RESEARCH_236's
     `cache_gate_armed`).
2. **Scenario `scenarios/15_thermal_soak.yaml`** — 45–60 min (3600s), 2 buyers,
   streaming, `max_tokens=64`, 30B model, 1s inter-request floor (continuous
   busy, ≤ 2 concurrent within Pearl N_eff=2.5). Targets `${LAB_GATEWAY_URL}` /
   `${LAB_COORDINATOR_URL}`, **unset by default so a bare run fails validation
   rather than hitting `malibu.tech`** (LAB PROVIDER ONLY). Invariants
   B1-B5,B10. B10 added to the scenario invariant allow-list + a
   `SustainedGateArmed` field on the scenario `Benchmark` struct.
3. **Provider-side thermal capture** `test/e2e/thermal-soak/` (sibling to
   `coldwarm-ttft/`): `thermal-collector.sh` (samples `pmset -g therm` +
   `sudo powermetrics --samplers smc,cpu_power,gpu_power` → timestamped NDJSON),
   `join-thermal.py` (correlates `per_request.jsonl` streaming-TPS to the
   thermal log by timestamp, stdlib-only), and a README with the LAB-only run
   recipe.
4. SPEC `docs/notes/SPEC-NETWORK-BENCHMARK-v0.1.md` §3.5 row + §4.15 scenario
   section.

### Parked for the lab-Mac campaign (Deliverable 3)

The actual 45–60 min soak run — the real deliverable — needs a lab Mac. It
produces the "safe sustained-load envelope" the #584 canary redesign consumes,
recalibrates B10's thresholds (then arms the gate), and answers the #463 (waived
G3 48 h soak) recommendation. Run recipe + open questions in
`test/e2e/thermal-soak/README.md`.

### Prod-safety (LAB-ONLY, enforced in code)

Any scenario declaring `B10` must have `gateway_url` and `coordinator_url`
resolve to a **loopback / private / link-local IP or `localhost`** (positive
allowlist `LabHostAllowed`) — every public host is rejected, including
trailing-dot and Unicode-separator variants; the check runs even when
`benchmark.enabled=false`; and a `CheckRedirect` guard blocks a lab gateway from
redirecting the soak to a non-lab host. A soak physically cannot reach
`malibu.tech`.

### Verification

- `go build ./...`, `go test ./...`, `go vet ./...` — GREEN in
  `test/network-harness`. New tests: B10 PASS/WARN/FAIL-armed/FAIL-downgrade-
  unarmed/SKIP-too-few/SKIP-provider-stops-before-end/SKIP-short-run/window-math;
  lab-only host allow/reject matrix (loopback/localhost/private/ipv6 ok; prod
  apex/subdomain/uppercase/trailing-dot/full-width/ideographic-dot/arbitrary-
  public rejected; disabled-benchmark still guarded; non-B10 still allows prod).
- `harness run scenarios/15_thermal_soak.yaml --dry-run` validates on a lab URL;
  fails safely without `LAB_*` env and on any prod host.
- **Three-lane codex audit (code / security / architect), 3 rounds** — R3 is
  **0 CRITICAL / 0 HIGH / 0 MEDIUM on all three lanes** (code APPROVE, security
  APPROVE, architect WATCH). Prompts + results under `audits/2026-07-22/`.
  Carried LOWs (documented, non-blocking): (1) scoped IPv6 link-local
  `[fe80::1%25en0]` is rejected by `net.ParseIP` — a legitimate-lab
  false-negative that **fails safe** (never allows prod); (2) `join-thermal.py`
  loads its inputs fully into memory (a local operator post-processing tool);
  (3) the redirect barrier has no dedicated regression test yet (its logic was
  read and verified correct by all three lanes).
- Does not touch scenario 07/08 or the money path.

Closes nothing (instrument only); advances #584.

<!-- SPEC-GOVERNANCE-DECLARATION-BEGIN
{
  "schema_version": "spec-pr-governance-v1",
  "behavior_change": "yes",
  "contract_change": "none",
  "issue": "https://github.com/Augustas11/macprovider/issues/584",
  "specs": ["SPEC-031"],
  "requirements": ["SPEC-023-R001"],
  "authority_domains": ["canary-sanction-lifecycle"],
  "arbitration": ["UNKNOWN"],
  "tests": ["go test ./... (test/network-harness)", "go vet ./... (test/network-harness)", "harness run scenarios/15_thermal_soak.yaml --dry-run"],
  "journeys": ["not-required"]
}
SPEC-GOVERNANCE-DECLARATION-END -->

🤖 Generated with [Claude Code](https://claude.com/claude-code)
