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
| KV-cache reuse | `macprovider_canary_cached_prompt_ratio{model}` | Turn-2 `cached_prompt_tokens / prompt_tokens` over a large shared prefix. Locks in the sticky-affinity win (measured ~64% live 2026-07-09). Requires the usage frame to survive large prompts (gateway PR #511). |
| Outcomes | `macprovider_canary_requests{model,outcome}` | Per-run gauge over buckets `2xx / 502 / 5xx / timeout / network_error / stream_error / empty / other` → 502-rate and mid-stream-failure signal. |
| Sample counts | `macprovider_canary_ttft_samples{model}`, `macprovider_canary_decode_tps_samples{model}` | Valid samples collected — alert on `== 0 while serviceable == 1` to catch a signal going dark (e.g. gateway stops returning usage). |
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

## Schedule it (always-on Linux host, e.g. Pearl — every 30 min)

Prefer this over a lab Mac when you have an always-on host: a sleeping Mac
creates blind spots. Units ship next to this README (`canary-buyer.service`,
`canary-buyer.timer`).

```bash
apt-get install -y nodejs            # Ubuntu 24.04 ships node 18 (probe-compatible)
install -d -o macprovider -g macprovider -m 0755 /opt/macprovider/canary-buyer
cp probe.mjs run-canary.sh /opt/macprovider/canary-buyer/
install -d -o macprovider -g macprovider -m 0750 /var/lib/macprovider/canary-buyer
# buyer token via a 0640 env file — never inline in the unit, never echoed:
printf 'MACPROVIDER_BUYER_TOKEN=%s\n' "$TOKEN" > /etc/macprovider/canary-buyer.env
chown root:macprovider /etc/macprovider/canary-buyer.env && chmod 0640 /etc/macprovider/canary-buyer.env
cp canary-buyer.service canary-buyer.timer /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now canary-buyer.timer
systemctl start canary-buyer.service   # run once now; check `journalctl -u canary-buyer`
```

### Alerting without Prometheus — dead-man's-switch heartbeat

No Prometheus/pushgateway is required. The service runs with `--fail-on-degraded`,
so a down gateway or unserviceable model makes the run **exit non-zero** (visible
in `journalctl -u canary-buyer`) and the wrapper then **does not** ping the
heartbeat. Point `CANARY_HEARTBEAT_URL` at a BetterStack "Heartbeat" (or
healthchecks.io) monitor with an expected period ≥ the timer interval: a healthy
run pings it; a degraded/failed/missed run leaves it stale and the monitor
alerts. Add to `/etc/macprovider/canary-buyer.env`:

```
CANARY_HEARTBEAT_URL=https://uptime.betterstack.com/api/v1/heartbeat/<token>
```
(https required unless `CANARY_ALLOW_INSECURE=1`; the URL carries no buyer token.)

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
| `CANARY_STICKY_PREFIX_LINES` | `80` | shared-prefix size (~10 tok/line) for the sticky KV-cache test; must exceed the provider's prefix-cache granularity or turn-2 `cached_prompt_tokens` is always 0 |
| `CANARY_ALLOW_INSECURE` | *(unset)* | set `1` to permit `http`/localhost/private-host targets (local mock testing only). By default `CANARY_BASE`/`CANARY_PUSHGATEWAY` must be `https` and non-private, so the buyer token can't be sent to an arbitrary origin. |
| `CANARY_HEARTBEAT_URL` | *(unset)* | https dead-man's-switch ping (BetterStack/healthchecks). Pinged by `run-canary.sh` only on a healthy (exit-0) run; a degraded run with `--fail-on-degraded` leaves it stale so the upstream monitor alerts. |

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

# Serviceable but a signal went dark (e.g. gateway stopped returning usage).
macprovider_canary_model_serviceable == 1 and on(model) macprovider_canary_decode_tps_samples == 0

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
