# thermal-soak — provider-side thermal capture for the RESEARCH_235 soak

This directory holds the **provider-side** half of the RESEARCH_235
thermal/sustained-load soak (issue [#584](https://github.com/Augustas11/macprovider/issues/584)).
The **buyer-side** half is the harness scenario
[`test/network-harness/scenarios/15_thermal_soak.yaml`](../../network-harness/scenarios/15_thermal_soak.yaml)
and its `B10` "sustained streaming-TPS retention" invariant.

It is a **sibling of `test/e2e/coldwarm-ttft/`**: same posture (a probe/collector
that runs against a live stack), different question. Cold/warm measures the
cold-start TTFT penalty; this measures how much streaming decode throughput a
provider **retains** under 45–60 min of constant load, and whether the decay
lines up with the machine throttling.

## Status — INSTRUMENT ONLY (campaign parked)

The scenario, the `B10` invariant, and these scripts are **built and tested**,
but **no soak has been run yet**. The run needs a **dedicated lab Mac** (see
below); it must NOT run against production. The first lab run is the actual
deliverable — it produces the "safe sustained load" envelope the #584 canary
redesign consumes, and recalibrates B10's provisional thresholds. Until then:

- `B10` thresholds (PASS ≥ 0.85 / WARN ≥ 0.70 / FAIL < 0.70) are **provisional
  guesses**, and scenario 15 leaves the gate **unarmed** (`sustained_gate_armed:
  false`), so a would-be FAIL is reported as WARN and can never block a run.
- Arm B10 (set `sustained_gate_armed: true`) only after the first lab run
  recalibrates the thresholds in `benchmark.go` and `SPEC-NETWORK-BENCHMARK-v0.1.md`
  §3.5.

## LAB MAC ONLY — do not soak prod

The whole point of #584 is that a sustained synthetic load **degrades and
disconnects the single prod mac** (~30 → 8.9 → 5.3 tok/s, then stale
heartbeats → WS EOF → removed from pool). Running this soak against
`streamvc.live` with the prod provider in the pool reproduces the outage.

This is enforced in code: scenario 15 declares `B10`, and the harness rejects
any `B10` scenario whose `gateway_url` or `coordinator_url` resolves to
`streamvc.live` (or a subdomain) — see `rejectProdHost` in
`test/network-harness/internal/scenario/schema.go`. A soak **cannot** be pointed
at prod even by setting `LAB_GATEWAY_URL` to the prod host.

Requirements for a valid run:
- A Mac you **fully control** (you will run `powermetrics`/`pmset` on it and
  deliberately push it toward thermal throttle).
- It is the **only** pool member of a **lab** coordinator+gateway stack. (Do
  NOT use the prod stack — the code-level guard above forbids a prod host for a
  B10 scenario.)
- Record the machine's **model, chip, RAM, and cooling** (fan vs fanless — an
  M1 Air is fanless and throttles hard; that is *signal*, not a defect).
- Stand the lab stack up **once** and leave it. Rapid coordinator restarts
  wedge the provider CLI's v2 proof-auth (`auth_request proof rejected: type`,
  pool → 0); recover with `pkill -9 -f macprovider-cli` and let launchd
  respawn one.

## Files

| File | Role |
|---|---|
| `thermal-collector.sh` | Runs on the lab provider Mac for the soak window. Samples `pmset -g therm` (CPU speed-limit %) and `sudo powermetrics --samplers smc,cpu_power,gpu_power` (SMC temps, CPU/GPU power), writing a timestamped **NDJSON** thermal log. |
| `join-thermal.py` | Post-processes a completed run: joins the harness `per_request.jsonl` (buyer-side streaming TPS) to `thermal.ndjson` by timestamp and bins them, so the TPS decay can be overlaid on the thermal signal. Pure stdlib. |

## Run recipe (once a lab Mac exists)

Use absolute paths so the commands work from any directory. Let
`THERMAL_DIR=/abs/path/to/test/e2e/thermal-soak` and
`HARNESS_DIR=/abs/path/to/test/network-harness`.

```bash
# ── on the LAB PROVIDER mac ─────────────────────────────────────────────
# 1. Start the thermal collector JUST BEFORE the soak (own terminal / tmux).
#    Run it UNPRIVILEGED — it escalates only the internal `powermetrics` call.
"$THERMAL_DIR/thermal-collector.sh" \
  --out "$THERMAL_DIR/out/thermal-$(date -u +%Y%m%dT%H%M%SZ).ndjson" --interval 5

# ── on the machine running the harness (can be the same mac) ────────────
# 2. Point at the LAB stack and fire the soak (a prod host is rejected):
export LAB_GATEWAY_URL=http://127.0.0.1:<lab-gw-port>
export LAB_COORDINATOR_URL=http://127.0.0.1:<lab-coord-port>
export BUYER_TOKEN="$(cat ~/.config/macprovider/buyer-api-key)"   # never echo it
( cd "$HARNESS_DIR" && go build -o harness ./cmd/harness \
  && ./harness run scenarios/15_thermal_soak.yaml --out "$HARNESS_DIR/out-soak-30b" )

# 3. Stop the collector (Ctrl-C) when the soak finishes.

# 4. Correlate TPS decay vs thermal state:
"$THERMAL_DIR/join-thermal.py" \
  "$HARNESS_DIR/out-soak-30b/per_request.jsonl" \
  "$THERMAL_DIR"/out/thermal-*.ndjson --bin-seconds 60 --max-skew-seconds 30 \
  > "$THERMAL_DIR/out/overlay.ndjson"
```

The `B10` window fields (`first_window_tps_p50`, `final_window_tps_p50`,
`retention`, per-window sample counts) live in **`benchmark_summary.json`**
(under `buyer_metrics.sustained_tps`) in the `--out` dir; `benchmark_verdict.json`
carries the human-readable `B10` verdict line. `overlay.ndjson` is the thermal
correlation — each bin has both the pmset channel (`cpu_speed_limit_pct`) and
the powermetrics channel (`cpu_power_mw`/`gpu_power_mw`/`cpu_die_temp_c`), each
with its own `*_skew_s` (null when no thermal sample was within `--max-skew-seconds`).

The thermal log preserves raw device output under a `"raw"` field — **review /
redact before sharing**, and keep `out/` local (it is gitignored).

## What a run must answer (Deliverable 3, parked)

1. The **TPS-retention curve** per model class + chip, with the thermal overlay
   — does the decay coincide with a rising thermal-pressure / falling
   clock-speed signal (thermal throttle), or is it memory pressure / something
   else? #584 speculates thermal but never proved it.
2. The **safe sustained-load envelope**: the concurrency / duty-cycle at which a
   given provider class holds ≥ 0.85 retention. This tells the redesigned #584
   canary how much load it may apply, and for how long, before it becomes the
   cause of the degradation it is trying to detect. **Scenario 15 is a single
   stress point** (N=2, 1s floor) — deliberately heavier than #584's sequential
   canary, not an incident-faithful reproduction. Building the envelope needs a
   **D3 sweep** across several concurrency / duty-cycle cells (e.g. N∈{1,2,3},
   floors {1s,5s,15s}), with a cool-down between cells so each starts thermally
   neutral. Copy scenario 15 per cell (swap `count` / `interval_ms`).
3. A recommendation on [#463](https://github.com/Augustas11/macprovider/issues/463):
   can the waived G3 48 h soak be replaced by this characterized shorter soak as
   a release gate, or is a longer burn still needed before the beta cohort?
4. Whether slot-tuning (`466853e`) overheats capable machines under this load.
