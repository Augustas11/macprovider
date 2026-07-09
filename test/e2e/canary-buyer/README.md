# Canary buyer probe

A continuous synthetic buyer that measures the live macprovider network the way
a real buyer experiences it, and exports the result as Prometheus metrics.

This is **P1** from the 2026-07-09 e2e-testing review. The month's pattern was
that every serious finding came from live contact with prod (KV-cache verify,
W3 canary TTFT false-fail), yet the network had **no continuous
buyer-perspective measurement** — a metallib-class silent 2× TPS regression, or
a provider that `/v1/status` calls "ready" but that 502s every completion, would
be invisible until a buyer complained.

It productionizes `test/e2e/malibu-console/smoke.mjs` and network-harness
scenarios `07_sustained_throughput` / `09_streaming_ttft_distribution` into a
scheduled, dependency-free probe.

## What it measures (per model class, per run)

| Signal | Metric | Why it matters |
|--------|--------|----------------|
| Serviceability | `macprovider_canary_model_serviceable{model}` | 1 iff a chat actually produced a token. Catches the status-vs-serviceable divergence (status says ready, completions 502). |
| TTFT | `macprovider_canary_ttft_ms{model,quantile}` | p50/p95/p99 time-to-first-token. Feeds real numbers into the W3 `max_ttft_ms` canary gate instead of guesses. |
| Decode TPS | `macprovider_canary_decode_tps{model,quantile}` | Sustained tokens/sec (first token excluded). Catches metallib/thermal silent regressions. |
| KV-cache reuse | `macprovider_canary_cached_prompt_ratio{model}` | Turn-2 `cached_prompt_tokens / prompt_tokens`. Locks in the measured ~45% sticky-affinity win. |
| Outcomes | `macprovider_canary_requests{model,outcome}` | 2xx / 502 / 5xx / timeout / empty counts (per-run gauge) → 502-rate signal. |
| Pool view | `macprovider_canary_pool_providers{state}`, `macprovider_canary_up` | What `/v1/status` claims, for divergence comparison. |

Also writes a per-run JSON artifact (same shape as the network-harness
artifacts) for archival and offline analysis.

> **Buyer-side scope.** From the buyer we can split latency into *TTFT*
> (network + queue + prefill + first token) and *decode window* (sustained
> rate). The finer server-side phase timing the gateway logs on completion is
> not exposed in the buyer response, so this probe does not claim it — pair
> gateway logs with these metrics by `x-request-id` when you need the split.

## Run once (by hand)

```bash
export MACPROVIDER_BUYER_TOKEN=mp_...        # or MALIBU_API_KEY
node test/e2e/canary-buyer/probe.mjs --metrics-out /tmp/canary.prom --json-out ./artifacts
```

Or via the wrapper, which resolves the token from the documented harness
location (`~/.config/macprovider/buyer-api-key`) and rotates artifacts:

```bash
test/e2e/canary-buyer/run-canary.sh
```

The token is never echoed. Diagnostics go to stderr; the JSON run summary goes
to stdout.

## Schedule it (lab Mac, every 30 min)

```bash
# 1. Edit REPLACE_REPO_PATH / REPLACE_HOME in the plist to absolute paths.
cp test/e2e/canary-buyer/com.streamvc.canary-buyer.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.streamvc.canary-buyer.plist
launchctl kickstart -p gui/$(id -u)/com.streamvc.canary-buyer   # run now
```

By default it writes a `.prom` textfile to
`~/.local/state/canary-buyer/canary_buyer.prom` for the node_exporter
[textfile collector](https://github.com/prometheus/node_exporter#textfile-collector).
To push instead, set `CANARY_PUSHGATEWAY=http://host:9091` (in the plist
`EnvironmentVariables` or the environment).

## Configuration

All env, all optional except the token:

| Var | Default | Meaning |
|-----|---------|---------|
| `MACPROVIDER_BUYER_TOKEN` / `MALIBU_API_KEY` | — | buyer bearer (required) |
| `CANARY_BASE` | `https://api.streamvc.live` | gateway base URL |
| `CANARY_MODELS` | *(all from `/v1/status`)* | comma-separated model ids to probe |
| `CANARY_TTFT_SAMPLES` | `12` | short requests/model for the TTFT histogram |
| `CANARY_TPS_SAMPLES` | `3` | longer requests/model for sustained TPS |
| `CANARY_TPS_MAX_TOKENS` | `128` | decode window for TPS samples |
| `CANARY_INTERVAL_MS` | `1500` | floor gap between samples (avoids self-induced queueing; see scenario 09 pacing math) |
| `CANARY_REQ_TIMEOUT_MS` | `45000` | per-request timeout |
| `CANARY_ALLOW_INSECURE` | *(unset)* | set `1` to permit `http`/localhost/private-host targets (local mock testing only). By default `CANARY_BASE`/`CANARY_PUSHGATEWAY` must be `https` and non-private, so the buyer token can't be sent to an arbitrary origin. |

The buyer token is redacted from all logs, stdout, and artifacts even if a
mispointed gateway echoes the `Authorization` header.

Flags: `--metrics-out <path>`, `--json-out <dir>`, `--pushgateway <url>`,
`--fail-on-degraded` (exit 1 if the gateway is down or any model is
unserviceable — for CI/alerting; default exit is 0 so launchd doesn't treat a
bad-network run as a probe crash).

## Cost

Tiny. Default per model per run ≈ `12×8 + 3×128 + 2×16` ≈ **500 completion
tokens**. At 30-minute cadence and one model that is ~24k tokens/day.

## Suggested alerts

```
# Network says ready but can't actually serve. `on()` is required because
# _up has no labels while _model_serviceable has {model} — a bare `and` matches
# no series and the alert would silently never fire.
(macprovider_canary_model_serviceable == 0) and on() (macprovider_canary_up == 1)

# Silent throughput regression (tune the floor per model/tier from observed p50).
macprovider_canary_decode_tps{quantile="p50"} < 15

# TTFT SLO breach.
macprovider_canary_ttft_ms{quantile="p95"} > 7000

# Sticky affinity / KV-cache reuse collapsed.
macprovider_canary_cached_prompt_ratio < 0.1

# Probe stopped reporting.
time() - macprovider_canary_run_timestamp_seconds > 5400
```

## Validation (2026-07-09)

- Failure path verified against live prod during an active `upstream_provider_error`
  incident: `up=1`, `serviceable=0`, outcomes `{502:4, 5xx:1}` recorded correctly.
- Success path (TTFT percentiles, decode-TPS math, cache ratio, Prometheus
  emission) verified against a local mock SSE gateway.
