# Canary buyer safety runbook

The canary has two deliberately separate modes:

- `liveness` is the only scheduled mode. It sends one request with at most eight
  completion tokens per model, never retries, checks the pool before and after
  every request, and requires a recovery soak before reporting healthy.
- `qualification` is an explicit, isolated-capacity operation. It retains TTFT,
  decode, and cache measurement, but requires operator pool telemetry,
  provider-local status telemetry, and a provider/hardware-specific baseline.

The shipped systemd and launchd schedules are fail-closed. They issue no network
requests until an operator creates the configured enable-gate file after the
Issue #584 production re-enable criteria are approved.

## Emergency disable — one command

```bash
sudo test/e2e/canary-buyer/emergency-disable.sh
```

This first writes a sentinel checked before credential resolution or networking,
then removes the enable gate and stops/disables `canary-buyer.timer`. On macOS it
also boots out the LaunchAgent. Do not remove the sentinel or recreate the enable
gate until reviewed approval.

## Scheduled liveness

The service runs:

```bash
run-canary.sh --mode liveness --fail-on-degraded
```

Default hard worst-case-per-provider budget:

| Limit | Default |
|---|---:|
| Requests | 4 |
| Reserved completion tokens | 32 |
| Whole run, including soak | 90 seconds |
| Recovery soak | 15 seconds |

The budget is enforced globally because the buyer cannot predict gateway
routing. Even if every request routes to one provider, that provider cannot
exceed the stated cap. A failed or degraded run stops immediately and is never
automatically repeated. `CANARY_DEGRADED_RETRIES` values other than `0` are
rejected before the probe process starts.

For systemd, install the files and credentials but leave
`/etc/macprovider/canary-buyer.enabled` absent until sign-off. After sign-off:

```bash
sudo install -m 0644 /dev/null /etc/macprovider/canary-buyer.enabled
sudo systemctl enable --now canary-buyer.timer
```

The dead-man heartbeat is pinged only after successful preconditions, workload,
postconditions, and recovery soak. A failure never pings and never retries.

## Explicit performance qualification

Run only with capacity isolated from rollout-safety capacity, one target model
per invocation:

```bash
CANARY_MODELS='<model-id>' \
CANARY_BASELINE_FILE=/secure/canary-baselines.json \
CANARY_POOLZ_URL='https://coordinator.example/poolz' \
CANARY_OPERATOR_TOKEN="$(< /secure/operator-token)" \
CANARY_PROVIDER_STATUS_URLS='https://provider.example/v1/status' \
run-canary.sh --mode qualification --capacity-isolated --fail-on-degraded
```

Qualification refuses to start without every required argument above. The
operator `/poolz` API supplies exact provider membership, connection identity,
state, and heartbeat/activity timestamps. Provider-local `/v1/status` or
`/v1/health` supplies RSS, restart, queue, state, uptime, and coordinator
connectivity. Explicit thermal/memory-pressure fields are consumed when exposed;
otherwise state changes and RSS bounds remain the available safety proxies, and
the missing real-hardware evidence remains a production re-enable blocker.

Baseline file schema:

```json
{
  "schema_version": 1,
  "entries": [{
    "model": "model-id",
    "provider": "x-provider-id value",
    "hardware_tier": "m1-8gb",
    "decode_tps_p50": 30.0,
    "ttft_p95_ms": 1200,
    "sample_size": 20,
    "max_tps_regression_fraction": 0.35,
    "max_ttft_regression_fraction": 0.5,
    "percentile_choice": "decode p50 / TTFT p95",
    "conditions": "warm model, AC power, nominal thermal state",
    "safety_margin": "35% TPS / 50% TTFT"
  }]
}
```

A sharp per-request regression aborts immediately even when the request returns
HTTP 2xx. The generic 15 tok/s onboarding default is not used as the
qualification performance decision.

## Invariants and recovery

Before load, between requests, after load, and throughout soak the probe checks:

- gateway and coordinator remain up and non-degraded;
- total/Ready provider counts and per-model Ready counts do not change;
- no provider drains, disconnects, restarts, disappears, or becomes non-routable;
- heartbeat or activity remains fresh and advances during qualification soak;
- provider queues return to zero, memory stays below its configured fraction,
  RSS growth stays bounded, and any exposed thermal/memory pressure stays clear.

Failures are recorded in JSON and Prometheus with an explicit class such as
`precondition_failed`, `budget_exhausted`, `performance_regression`,
`provider_state_regression`, `heartbeat_regression`, `memory_regression`,
`thermal_regression`, `request_failure`, `safety_observer_failure`, or
`recovery_failed`. Each JSON artifact preserves per-request TTFT, decode time,
total time, token reservation/usage, provider, request ID, and outcome.

## Configuration summary

| Variable | Liveness default | Purpose |
|---|---:|---|
| `CANARY_MAX_REQUESTS_PER_PROVIDER` | `4` | worst-case routed request cap |
| `CANARY_MAX_COMPLETION_TOKENS_PER_PROVIDER` | `32` | worst-case reserved completion-token cap |
| `CANARY_MAX_RUN_DURATION_MS` | `90000` | internal whole-run cap |
| `CANARY_RECOVERY_SOAK_SECONDS` | `15` | stable post-workload interval |
| `CANARY_RECOVERY_POLL_MS` | `5000` | safety observation cadence |
| `CANARY_MIN_READY_PROVIDERS` | `1` (`2` qualification) | rollout-safety capacity floor |
| `CANARY_MAX_HEARTBEAT_AGE_MS` | `90000` | operator-observed freshness cap |
| `CANARY_MAX_MEMORY_GROWTH_MB` | `512` | provider RSS growth cap |
| `CANARY_MAX_MEMORY_FRACTION` | `0.9` | provider RSS / RAM cap |
| `CANARY_ENABLE_FILE` | unset | scheduled fail-closed enable gate |
| `CANARY_DISABLE_FILE` | user state path | emergency no-load sentinel |

Local/private HTTP observer URLs require `CANARY_ALLOW_INSECURE=1`; never use
that override for an untrusted target. Buyer and operator tokens are redacted
from logs, stdout, and artifacts.

## Validation

```bash
node --test test/e2e/canary-buyer/probe.test.mjs \
  test/e2e/canary-buyer/safety.test.mjs
bash test/e2e/canary-buyer/run-canary.test.sh
```

These tests prove software budgets, abort classification, pool invariants,
recovery requirements, kill switches, and no retry/load amplification. They do
not replace the physical-Mac thermal, memory-pressure, heartbeat, disconnect,
and operating-day cadence evidence required by Issue #584 before production
re-enable.
