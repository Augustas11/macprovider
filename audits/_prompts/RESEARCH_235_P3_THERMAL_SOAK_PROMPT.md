# RESEARCH_235 — P3: thermal / sustained-load soak with a degradation assertion

**Carry this in a fresh session.** Self-contained; assumes no memory of the P1/P2 sessions.
It is one of the four e2e tests proposed in the 2026-07-09 e2e-testing review (P1 canary-buyer
probe = shipped; P2 cold/warm TTFT matrix = instrument landed, campaign pending; P3 = this;
P4 = `RESEARCH_236`).

## Why this exists now (the forcing function)

On **2026-07-13** the production canary collapsed a healthy provider under sustained synthetic
load: the M1 8 GB Llama provider fell from a repeatedly-measured **~29–31 tok/s p50** to
**8.91**, then a full retry drove it to **5.26 tok/s p50**, after which the coordinator saw
stale heartbeats → WebSocket EOF → removal from the Ready pool. That incident is
[issue #584](https://github.com/Augustas11/macprovider/issues/584) (P0, OPEN — "redesign
production canary before re-enabling it"). It is, at root, a **thermal / sustained-throughput
degradation** event that no test in the repo characterizes.

P3 is the test that characterizes it: a controlled soak that drives a provider under constant
decode load for 45–60 min, measures how TPS decays over the window, and correlates the decay
with on-device thermal state. Its output is the **"safe sustained load" envelope** the #584
canary redesign needs, and it **restores the G3 48 h soak coverage** that was waived pre-beta in
[#463](https://github.com/Augustas11/macprovider/issues/463) — replacing a waived 48 h soak with
a characterized shorter one.

## Hard prerequisite — this needs a LAB provider (do not run on prod)

**This is the same hardware blocker as P2.** The whole point of #584 is that sustained synthetic
load *degrades and disconnects the single prod mac*. You must **not** run a 45–60 min soak against
`api.malibu.tech` / the prod coordinator with the prod provider in the pool — you would
reproduce the outage. P3 requires a **dedicated lab Mac** serving into a **lab coordinator+gateway
stack** (or the prod stack with the lab provider as the *only* pool member and prod buyers routed
away). Until a lab Mac exists, P3 is **parked at the campaign step** — but the instrument (scenario
+ invariant + thermal capture) can and should be built now so it is ready the moment hardware is.

If you have a lab Mac: it must be a machine you fully control (you will run `powermetrics`/`pmset`
on it and deliberately push it toward thermal throttle). Capture its model, chip, RAM, and cooling
(fan vs fanless — an M1 Air is fanless and throttles hard; that is *signal*, not a defect).

## What already exists (do not rebuild)

- **The Go harness:** `test/network-harness` (`go build -o harness ./cmd/harness`). Scenario-YAML
  driven, phase A/B/C, fires a concurrent buyer fleet at a coordinator+gateway stack, writes
  `per_request.jsonl`, `metrics_summary.json`, `ledger_reconcile.json`, `invariants.json`,
  `benchmark_verdict.json`. Read `test/network-harness/README.md` first.
- **The base scenario:** `test/network-harness/scenarios/07_sustained_throughput.yaml` — but it is
  only a **6-minute, 2-buyer** steady-state baseline asserting benchmark invariants **B1–B5**, and
  it explicitly says *"not a chaos test — providers should stay up the whole window."* P3 extends
  this to a long-duration soak with a **new** degradation invariant. Do not delete or repurpose 07.
- **The benchmark-invariant engine:** `test/network-harness/internal/benchmark/benchmark.go`. The
  catalog is `B1..B7` (`evalB1..evalB7`); each is a `case "Bn":` in the dispatch loop returning a
  `Verdict{ID, Title, Unit, Value, Target, BareMin, Status}`. `B7` (cold/warm ratio, scenario 08)
  is the closest template for adding a new windowed metric. Thresholds live both here and in
  `docs/notes/SPEC-NETWORK-BENCHMARK-v0.1.md` §3.5 (the invariant table) — update both.
- **Per-request timing:** each `buyer.Result` carries `StartUTC` and `TTFTMillis`; streaming TPS is
  derivable per request. The reducer for the new invariant windows these by wall-clock time — no
  new capture on the buyer side is needed for the TPS-retention metric (thermal capture is
  provider-side, see below).

## The mission — three deliverables

The instrument is not the deliverable. The deliverables are:

### Deliverable 1 — the soak scenario + a sustained-retention invariant (build now)

1. **New scenario** `test/network-harness/scenarios/15_thermal_soak.yaml`:
   - `duration: 2700s`–`3600s` (45–60 min), 2 buyers, `stream: true`, `pattern: interval` paced so
     the provider stays continuously busy (short inter-request floor) but within `N_eff` — reuse
     07's pacing math (`wall_p95 + interval` floor keeps `mean_active < N_eff`; see 07's header).
   - Target the **lab** stack (lab gateway/coordinator URLs), not `malibu.tech`.
   - One model per soak run (start with the 30B, since that is the prod model class that collapsed;
     add smaller classes as separate runs). Realistic `max_tokens` (64) so decode dominates.
2. **New benchmark invariant `B8` — "sustained TPS retention"** in `benchmark.go`:
   - Window streaming-TPS p50 into a **first window** (first 5 min of samples) and a **final window**
     (last 5 min). `retention = final_p50 / first_p50`.
   - Thresholds (calibrate from the first real run, do not ship guesses as final): **PASS ≥ 0.85,
     WARN ≥ 0.70, FAIL < 0.70.** Emit `first_window_tps_p50`, `final_window_tps_p50`, `retention`,
     and the number of samples per window in the verdict detail. `SKIP` if either window has too
     few samples (define a floor, e.g. ≥ 8).
   - Add the `case "B8":` dispatch + `evalB8`, a unit test in `benchmark_test.go` (synthetic
     decaying-TPS fixture → asserts PASS/WARN/FAIL boundaries), and a row in
     `SPEC-NETWORK-BENCHMARK-v0.1.md` §3.5.
   - Declare `invariants: [B1, B2, B3, B4, B5, B8]` in `15_thermal_soak.yaml`.

### Deliverable 2 — provider-side thermal capture + correlation (build now, needs lab Mac to run)

On the lab provider, sample thermal state for the full soak window and align it to the TPS decay:
- `sudo powermetrics --samplers smc,cpu_power,gpu_power -i 5000` (SMC temps, CPU/GPU power), and/or
  `pmset -g therm` (thermal pressure / CPU speed-limit %), logged with timestamps.
- A small collector script under `test/e2e/thermal-soak/` (sibling to `test/e2e/coldwarm-ttft/`)
  that writes an NDJSON thermal log the analysis can join to `per_request.jsonl` by timestamp.
- The report must answer: **does the TPS decay coincide with a rising thermal-pressure / falling
  clock signal?** (i.e. is the collapse thermal throttling, memory pressure, or something else —
  #584 speculates thermal but never proved it).

### Deliverable 3 — the soak report + the "safe sustained load" envelope

A written report (`test/e2e/thermal-soak/SOAK_REPORT.md` or a `RESEARCH_235_RUN_*` result file):
- The **TPS-retention curve** per model class + chip, with the thermal overlay.
- The **safe sustained-load envelope**: the concurrency / duty-cycle at which a given provider class
  holds ≥ 0.85 retention. This is the number the **#584 canary redesign** consumes — it tells the
  redesigned canary how much load it may apply, and for how long, before it is itself the cause of
  the degradation it is trying to detect.
- A recommendation on **#463**: can the waived G3 48 h soak be replaced by this characterized
  shorter soak as a release gate, or is a longer burn still required before the beta cohort?
- If slot-tuning (`466853e`) is in play, whether it overheats capable machines under this load.

## Hard rules (paid-for lessons — do not relearn them)

1. **Lab provider only.** Never soak the prod mac. #584 is the receipt.
2. **One clean coordinator, no restart churn.** Rapid coordinator restarts wedge the provider CLI's
   v2 proof-auth (symptom: `auth_request proof rejected: type`, pool → 0). Stand the lab stack up
   once and leave it. If the CLI wedges, the fix is `pkill -9 -f macprovider-cli` and let launchd
   respawn one — see the P1 findings (#519).
3. **The metric is streaming TPS, measured buyer-side.** Do **not** use the non-streaming
   `sustained_tps` field for the retention verdict — it is structurally unreliable (it reads
   17k–33k tok/s for a warm 30B because it divides completion tokens by full round-trip on a tiny
   response). B8 must be built on the *streaming* decode-TPS distribution (post-TTFT tokens / decode
   duration), the same basis as B2.
4. **Instrument first, then a real run — but the run is the deliverable.** Learn from P2/RESEARCH_234
   run 1: it built the instrument, produced two PRs and *zero samples*, and both PRs died stale. The
   first milestone once a lab Mac exists is **a completed soak run with a retention verdict**, not a
   merged instrument PR.
5. **Keep the PR fresh.** This repo's `origin/main` moves fast (dozens of commits/day). Rebase the
   branch at session start and again immediately before opening the PR; run the attribution check on
   any red CI (does it fail identically on the base commit? then it is pre-existing — find/wait for
   the fix on main, do not fight it blind).

## Repo conventions (must follow)

- **Fresh worktree off `origin/main`** for all code work — never edit the canonical checkout. See
  the project `CLAUDE.md` "Worktree isolation" section.
- **This is a test-harness change, not money-path** — but the `B8` thresholds and any
  release-gate recommendation touch how providers are judged, so route the harness+invariant change
  through the standard **three-lane codex audit** (code / security / architect via `omc ask codex`)
  to **0 CRITICAL / 0 HIGH / 0 MEDIUM** before PR, and author the PR as **Augustas11** so
  antfleet-ops can review. Prompts/results live under `audits/` (not `specs/` — a CI gate rejects
  prompt files in `specs/`).
- **Never print the buyer token** (`~/.config/macprovider/buyer-api-key`) to the transcript; the
  harness reads it from `${BUYER_TOKEN}`.
- Cross-refs: #584 (the incident this serves), #463 (waived G3 soak), scenario `07`/`08`, the P2
  cold/warm matrix (`RESEARCH_234`, complementary — P2 measures cold-load TTFT, P3 measures
  sustained-decode retention), and P4 (`RESEARCH_236`, the sibling regression gate).
