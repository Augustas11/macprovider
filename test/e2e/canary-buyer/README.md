# Canary buyer safety runbook

The canary has two deliberately separate modes:

- `liveness` is the only scheduled mode. It sends one request with at most eight
  completion tokens for each exact expected-fleet model, never retries, checks the pool before and after
  every request, and requires a recovery soak before reporting healthy.
- `qualification` sends load only to one private/loopback provider HTTP endpoint.
  It never sends qualification load through the production gateway. Operator
  `/poolz` must prove that exact target is non-routable while the separately
  enumerated rollout-safety fleet remains Ready. The production gateway is
  observed only for safety, not used for the qualification workload.

The shipped systemd and launchd schedules are fail-closed. The wrapper returns
status `20` for the emergency-disable sentinel and `21` for a missing enable
gate. The systemd unit records those deliberate no-load states as successful
unit outcomes for alert hygiene, but rollout/recovery tooling requires the
original `ExecMainStatus=0`; neither skip status is serving evidence.

For the current Issue #584 containment, Pearl's timer stays disabled/inactive,
both historical empty enable gates stay absent, `/var/lib/macprovider-canary-buyer/DISABLED`
stays present, and `pool.canary_enabled` stays false. This Partial does not
authorize removing the sentinel, recreating an enable gate, enabling the timer,
or using either mode as production rollout proof.

## Emergency disable — one command

```bash
sudo /opt/macprovider-canary-buyer/emergency-disable.sh
```

This first writes a sentinel checked before credential resolution, before
networking, and again before every request. It then removes the enable gate,
stops the in-progress service, disables the timer, and verifies both are
inactive. On macOS it resolves the invoking non-root user under `sudo`, boots
out that user's LaunchAgent, and verifies the agent is gone. Do not remove the
sentinel or recreate the enable gate until reviewed approval.

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
| Recovery soak | 45 seconds |

The internal budget is enforced globally because the buyer cannot predict gateway
routing. Even if every request routes to one provider, that provider cannot
exceed the stated cap. A failed or degraded run stops immediately and is never
automatically repeated. `CANARY_DEGRADED_RETRIES` values other than `0` are
rejected before the probe process starts. Every invocation is also wrapped by
GNU `timeout`/`gtimeout` (`120s` liveness, `330s` qualification by default), so
DNS, output delivery, or runtime bugs cannot defeat the external deadline.
The exact expected-fleet topology is the reviewed provider inventory, not an
operator count override. During every stream a separate safety observer polls
at two-second intervals and aborts the request immediately if provider,
heartbeat, thermal, memory, queue, session, or build identity regresses.

For systemd, install `probe.mjs`, `safety.mjs`, `run-canary.sh`, and
`emergency-disable.sh` together,
plus the buyer token, operator token, heartbeat URL, and expected-fleet JSON
credentials documented in `canary-buyer.service`. Leave
`/etc/macprovider-canary-buyer/enabled` absent and keep the DISABLED sentinel in
place. A later signed re-enable change must provide the reviewed production
procedure; this Partial intentionally provides no command that can arm Pearl.

The dead-man heartbeat is pinged only after successful preconditions, workload,
postconditions, and recovery soak. A failure never pings and never retries.

For the per-user macOS LaunchAgent, the four fallback files under
`~/.config/macprovider` (buyer token, operator token, heartbeat URL, and expected
fleet) must be owned by that user and mode `0400` or `0600`. The wrapper rejects
symlinks, files owned by another uid, and any group/world permission bits.
Install the complete runtime, including the universal emergency command, before
bootstrapping the LaunchAgent:

```bash
sudo install -d -o root -g wheel -m 0755 /opt/macprovider-canary-buyer
sudo install -o root -g wheel -m 0755 \
  probe.mjs safety.mjs run-canary.sh emergency-disable.sh \
  /opt/macprovider-canary-buyer/
```

## Explicit performance qualification

Run only with capacity isolated from rollout-safety capacity, one target model
per invocation:

```bash
CANARY_MODELS='<model-id>' \
CANARY_BASELINE_FILE=/secure/canary-baselines.json \
CANARY_EXPECTED_FLEET_FILE=/secure/canary-expected-fleet.json \
CANARY_POOLZ_URL='https://coordinator.example/poolz' \
CANARY_OPERATOR_TOKEN="$(< /secure/operator-token)" \
CANARY_ISOLATED_PROVIDER_ID='provider-id-from-poolz-and-local-status' \
CANARY_ISOLATED_PROVIDER_BASE='http://127.0.0.1:8080' \
CANARY_ALLOW_INSECURE_PROVIDER_OBSERVER=1 \
run-canary.sh --mode qualification --fail-on-degraded
```

Qualification refuses to start without every required argument above. The
operator `/poolz` API supplies exact provider membership, connection identity,
state, model, routing eligibility, and heartbeat timestamps. The target must
appear exactly once, match `CANARY_ISOLATED_PROVIDER_ID` and `CANARY_MODELS`, and
be non-routable (`routing_eligible=false`; Ready or draining). The local
`/v1/status` `safety_telemetry` object and every SSE response must independently
report the same provider, model, and exact coordinator-assigned session. Every
successful stream must terminate with `[DONE]`. Local HTTP is allowed only by the narrowly
scoped `CANARY_ALLOW_INSECURE_PROVIDER_OBSERVER=1`; buyer and operator
credentials are never sent to the local endpoint. Failure to establish any of
these facts aborts as `isolation_unproven` before additional load.

Expected rollout-safety fleet schema (the qualification target is intentionally
not listed; no unlisted provider other than that exact target is accepted):

```json
{
  "schema_version": 1,
  "providers": [
    { "provider_id": "ready-provider-a", "model_id": "model-a" },
    { "provider_id": "ready-provider-b", "model_id": "model-b" }
  ]
}
```

Scheduled liveness uses the same document without an allowed extra target, so
membership, provider IDs, model IDs, Ready/routable state, and heartbeat
freshness must all match exactly. The document is required to contain the
operator-reviewed live protected fleet: provider IDs are unique, duplicate
model IDs are allowed when multiple protected providers serve the same model,
and every model in the fleet must be probed by `CANARY_MODELS`.
`CANARY_MODELS` must exactly equal the unique model set in the document. The
shipped schedules pin Pearl's live models:
`mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` and
`mlx-community/Llama-3.2-3B-Instruct-4bit`, and
`mlx-community/Qwen3-8B-4bit`, producing one 8-token request each.
Each provider heartbeat carries versioned `safety_telemetry`; the coordinator
validates it, stamps receipt freshness, and publishes it through authenticated
`/poolz`. Version 2 binds the observation to the coordinator session, binary,
compatibility set, model hash, and power source and carries live CPU/GPU,
queue, current RSS, thermal, and memory-pressure signals. Liveness fails closed
if any expected provider lacks a complete measurement,
so Pearl does not need a provider-local route to enforce queue, restart,
memory-pressure, RSS, thermal, and runtime-state invariants.
GPU utilization is explicitly marked `host` scope: Apple exposes AGX device
utilization rather than per-process accounting. The expected fleet keeps one
provider service per physical Mac, and evidence reviewers treat this as a
host-condition signal rather than misattributing it to the provider process.

Baseline file schema:

```json
{
  "schema_version": 3,
  "entries": [{
    "model": "model-id",
    "provider": "x-provider-id value",
    "hardware_tier": "8GB",
    "compatibility_set_id": "Augustas11/macprovider:v1.8.33@0123456789abcdef0123456789abcdef01234567",
    "binary_version": "1.8.33",
    "model_hash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "power_source": "external",
    "decode_tps_p50": 30.0,
    "ttft_p95_ms": 1200,
    "sample_size": 20,
    "cold_sample_size": 10,
    "warm_sample_size": 10,
    "max_tps_regression_fraction": 0.35,
    "max_ttft_regression_fraction": 0.5,
    "percentile_choice": "decode p50 / TTFT p95",
    "conditions": "warm model, AC power, nominal thermal state",
    "safety_margin": "35% TPS / 50% TTFT",
    "thermal_condition": "nominal",
    "decode_tps_variance": 2.1,
    "ttft_ms_variance": 12000,
    "measured_at": "2026-07-14T12:00:00Z",
    "approved_at": "2026-07-14T12:05:00Z",
    "valid_until": "2026-07-21T12:05:00Z",
    "evidence_uri": "s3://immutable-evidence/run.json",
    "evidence_sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }]
}
```

A sharp per-request regression aborts immediately even when the request returns
HTTP 2xx. The generic 15 tok/s onboarding default is not used as the
qualification performance decision. Baselines expire, may be approved for at
most 30 days, and match only the exact provider, hardware tier, compatibility
set, binary, model hash, and current external/battery state.

## Invariants and recovery

Before load, between requests, after load, and throughout soak the probe checks:

- gateway and coordinator remain up and non-degraded;
- total/Ready provider counts and per-model Ready counts do not change;
- every expected rollout-safety provider stays Ready/routable with its exact model;
- the isolated qualification target stays non-routable without reconnecting;
- actual heartbeat timestamps (never generic activity) remain fresh and never
  regress between soak samples, and the final sample advances from the initial
  timestamp across a soak longer than the production heartbeat cadence;
- versioned provider telemetry observations advance on every successive sample,
  queues return to zero,
  memory stays below its configured fraction, RSS growth stays bounded, and
  thermal and memory-pressure states remain clear.

If any attempted request fails—including 401/403 authentication failures—the
probe issues no more workload, but it still performs post-request observation
and the fixed recovery soak. The original failure remains the primary result;
any recovery failure is preserved separately in `safety.recovery_result`.

Failures are recorded in JSON and Prometheus with an explicit class such as
`precondition_failed`, `budget_exhausted`, `performance_regression`,
`provider_state_regression`, `heartbeat_regression`, `memory_regression`,
`thermal_regression`, `authentication_failure`, `request_failure`,
`isolation_unproven`, `safety_observer_failure`, or
`recovery_failed`. Each JSON artifact preserves per-request TTFT, decode time,
total time, token reservation/usage, provider, request ID, and outcome.
It also preserves the bounded raw safety observation series and recovery record
summaries so heartbeat and workload evolution can be audited after the run.

## Configuration summary

| Variable | Liveness default | Purpose |
|---|---:|---|
| `CANARY_MAX_REQUESTS_PER_PROVIDER` | `4` | worst-case routed request cap |
| `CANARY_MAX_COMPLETION_TOKENS_PER_PROVIDER` | `32` | worst-case reserved completion-token cap |
| `CANARY_MAX_RUN_DURATION_MS` | `90000` | internal whole-run cap |
| `CANARY_RECOVERY_SOAK_SECONDS` | `45` | spans the 30-second production heartbeat cadence |
| `CANARY_RECOVERY_POLL_MS` | `7000` | samples faster than the 30-second production heartbeat cadence |
| `CANARY_SAFETY_POLL_MS` | `2000` | concurrent in-request safety observation cadence |
| `CANARY_MIN_READY_PROVIDERS` | `2` | rollout-safety capacity floor (also at least expected-fleet size) |
| `CANARY_MAX_HEARTBEAT_AGE_MS` | `90000` | operator-observed freshness cap |
| `CANARY_MAX_MEMORY_GROWTH_MB` | `512` | provider RSS growth cap |
| `CANARY_MAX_MEMORY_FRACTION` | `0.9` | provider RSS / RAM cap |
| `CANARY_ENABLE_FILE` | unset | scheduled fail-closed enable gate |
| `CANARY_DISABLE_FILE` | user state path | emergency no-load sentinel |
| `CANARY_EXPECTED_FLEET_FILE` | required | exact provider/model allow-list |
| `CANARY_POOLZ_URL` / `CANARY_OPERATOR_TOKEN` | required | authenticated operator truth |
| `CANARY_PROBE_TIMEOUT_SECONDS` | `120` | mandatory external wrapper timeout |

The only cleartext override is
`CANARY_ALLOW_INSECURE_PROVIDER_OBSERVER=1`, scoped to the private provider
qualification endpoint. A separate test-only
`CANARY_ALLOW_INSECURE_HEARTBEAT=1` does not affect any other URL. Buyer and
operator tokens are redacted from logs, stdout, and artifacts; the heartbeat
URL is supplied to curl over stdin rather than exposed in the process argv.

## Production re-enable remains out of scope

Do not re-enable Pearl from this runbook. Issue #584 remains open until all of
the following physical and operational evidence is reviewed and signed:

- per-model/per-hardware-tier cold and warm baselines with sample size,
  percentile, variance, thermal/power conditions, and safety margin
  (collection matrix: `ops/runbooks/584-physical-baseline-matrix.md`);
- the isolated qualification matrix on M1 8 GB and higher-memory M-series Macs,
  including thermal pressure, memory pressure, battery/AC, sustained load, and
  injected stream/heartbeat/provider failures;
- a normal-operating-day liveness cadence with stable heartbeats, no provider
  disconnect/restart/drain, and the expected Ready pool after every soak;
- a Pearl emergency-disable drill proving the sentinel is installed before the
  service/timer are stopped and remain inactive afterward
  (drill paper: `ops/runbooks/584-emergency-disable-drill.md`); and
- an approved go/no-go record followed by a separately reviewed timer flip.

FR-CAN23 multi-provider correlation is a software Partial in
`phase4-coordinator/internal/canarycorr` (design:
`audits/2026-07-23/FR-CAN23-CORRELATION-EPOCH-DESIGN.md`). It is **not** wired
into live canary dispatch and does not authorize re-enable.

The coordinator's internal sanction loop is independently governed by
SPEC-031 §16 and remains disabled until every requirement in that normative
re-enable bar passes.

## Validation

```bash
node --test test/e2e/canary-buyer/probe.test.mjs \
  test/e2e/canary-buyer/safety.test.mjs
bash test/e2e/canary-buyer/run-canary.test.sh
```

These tests prove the software controls, installed-file layout, abort and auth
classification, exact fleet/isolation invariants, recovery requirements, kill
switches, and no retry/load amplification. They do not prove physical-Mac
safety. Thermal and memory-pressure behavior, real heartbeat/disconnect
recovery, the emergency-disable drill, and an operating-day cadence remain
production re-enable gates.
