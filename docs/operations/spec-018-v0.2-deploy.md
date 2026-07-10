# SPEC-018 v0.2 — Deployment Operator Runbook

This runbook covers operator-facing surfaces introduced or changed by SPEC-018
v0.2 ("narrow Cline drop-in"). Read it alongside SPEC-018 §10d and the IMPL
notes at `specs/design/spec-018/SPEC-018-v0_2-IMPL-NOTES.md`.

## Prerequisites

### NTP synchronization (REQUIRED)

AC-44 streaming-timing measurements require NTP-synchronized clocks on:

- Provider Macs running phase3-binary
- Gateway hosts running phase5-gateway
- Coordinator host running phase4-coordinator (recommended, not required)

If the clock skew between provider and gateway exceeds 100 ms, AC-44 timing
samples are explicitly skipped (not silently fudged). The `/metrics/streaming`
endpoint will then report `skew_skipped_total` greater than zero.

Recommended NTP configuration:

- **macOS providers**: enable Apple's built-in NTP via System Settings →
  General → Date & Time → Set Automatically. macOS `timed` is acceptable.
- **Linux gateway / coordinator**: install `chrony` (`sudo apt install chrony`
  on Debian/Ubuntu; `sudo dnf install chrony` on Fedora) and enable the
  `chronyd` service. Verify with `chronyc tracking`. `systemd-timesyncd` is
  an acceptable alternative if `chrony` is unavailable.

Without NTP, AC-44 evidence does not accumulate and Cline release-gate p95
latency claims cannot be verified.

### Request-start heartbeat evidence

Request-start heartbeat evidence must show provider/gateway skew within
`|t_provider - t_gateway| <= 100 ms`. AC-44 latency reports use skew-corrected
`(t_first_gateway_byte - t_tool_call_open_detected) - skew_offset`.

## Environment variables

### `COORDINATOR_STREAMING_FORCE_BUFFERED=1` (kill switch)

When set to `1` on the coordinator process, ALL streaming responses are forced
to buffered-to-end behavior regardless of buyer or provider. Tool-call
`function.arguments` are not streamed incrementally; the full tool call lands
in a single SSE chunk at end-of-stream.

Use this when:

- An incremental-streaming bug is observed in production and you need to
  immediately revert to v0.1 buffered behavior across the fleet.
- A specific buyer SDK does not handle incremental tool-call deltas correctly
  and you need a coordinator-wide downgrade pending an SDK fix.

The kill switch is independent of per-(buyer, provider) auto-downgrade
(see below).

Default: unset. To rollback to v0.1 streaming behavior temporarily, set the
variable and restart the coordinator process.

### Other settings

No other v0.2-specific environment variables. v0.2 inherits v0.1 settings for
listen ports, log levels, NATS topics, etc.

## Response headers buyers may observe

### `X-MacProvider-Streaming-Mode`

Emitted on EVERY v0.2 chat-completion response (streaming and non-streaming).
Three values:

| Value | Meaning | Operator action |
|---|---|---|
| `incremental` | Default. Tool-call `function.arguments` stream as fragments. | None — normal operation. |
| `buffered_kill_switch` | Operator set `COORDINATOR_STREAMING_FORCE_BUFFERED=1`. | Visible because YOU set the kill switch. Verify it's the intended state. |
| `buffered_provider_downgrade` | Coordinator auto-downgraded this specific (buyer, provider) tuple due to malformed-stream history. | Investigate the provider's recent stream health via logs. |

Buyers MUST NOT use this header for negotiation in v0.2 — it is observation-only
per §10d.4. But they MAY surface it to end-users as a degradation explanation
("streaming temporarily disabled for this provider; falling back to buffered
mode").

### `X-MacProvider-Provider-ToolCallOpen-Unix-Ms`

Emitted by phase3-binary when the provider's parser recognizes the start of a
native tool-call markup (Qwen `<tool_call>` opening or Llama `<|python_tag|>`
opening). Unix milliseconds since epoch.

### `X-MacProvider-Coordinator-FirstForward-Unix-Ms`

Emitted by phase4-coordinator at the moment of forwarding the first tool-call
delta to the buyer. Unix milliseconds since epoch.

### `X-MacProvider-Gateway-FirstByte-Unix-Ms`

Emitted by phase5-gateway at the moment of writing the first byte of the
response body to the buyer. Unix milliseconds since epoch.

### `X-MacProvider-NTP-Skew-Ms`

DEFERRED TO v0.3 — gateway-side NTP skew measurement requires reference-clock
infrastructure not present in v0.2. AC-44 v0.2 relies on OS-level NTP sync
(chrony/timesyncd) without runtime verification of skew. v0.3 will add
reference-clock handshake at gateway.

## Auto-downgrade behavior

The coordinator tracks per-(buyer, provider) tuple malformed-stream events.
Triggers and recovery:

- **Trigger**: 3 malformed streams from the same buyer to the same provider
  within a 5-minute sliding window → coordinator downgrades that specific
  tuple's future requests to buffered-to-end mode.
- **Scope**: Per-(buyer, provider) only. Other buyers sticky-routed to the
  same provider continue to receive incremental streaming. Other providers
  for the same buyer continue to receive incremental streaming.
- **Recovery**: After 10 minutes of no further malformed streams from the
  same (buyer, provider) tuple, the downgrade lifts and incremental streaming
  resumes.

This bounded attribution is per AC-45c. A single malicious buyer cannot
trigger a fleet-wide or all-buyers-on-provider downgrade.

## Monitoring

### `/metrics/streaming` — Prometheus-style endpoint (coordinator)

Sample output:

```
# HELP macprovider_streaming_timing_samples_total Total timing samples collected.
# TYPE macprovider_streaming_timing_samples_total counter
macprovider_streaming_timing_samples_total 1234

# HELP macprovider_streaming_skew_skipped_total Samples discarded due to NTP skew > 100 ms.
# TYPE macprovider_streaming_skew_skipped_total counter
macprovider_streaming_skew_skipped_total 5

# HELP macprovider_streaming_first_delta_latency_p95_ms p95 first-delta latency in ms (skew-corrected).
# TYPE macprovider_streaming_first_delta_latency_p95_ms gauge
macprovider_streaming_first_delta_latency_p95_ms 1320
```

Target thresholds (per AC-44):

- M4 hardware: p95 ≤ 1500 ms
- M2/M3 hardware: p95 ≤ 3000 ms

If `samples_total` is zero or stuck low while traffic is high, check:

1. Are the three timing headers actually being emitted? Tail the coordinator
   debug logs for `X-MacProvider-*-Unix-Ms`.
2. Is NTP synchronized on provider + gateway? Run `chronyc tracking` on
   gateway; verify "Last offset" is well under 100 ms.

### Per-(buyer, provider) downgrade state

Currently logged to the coordinator's main log on transition events:

- `streaming_downgrade=enabled buyer=<id> provider=<id> reason=3_malformed_in_5min`
- `streaming_downgrade=cleared buyer=<id> provider=<id> reason=10min_clean`

A dedicated diagnostics endpoint exposing the current downgrade map is
v0.3 work; for v0.2, grep logs.

## Rollback procedures

### Roll back to v0.1 streaming behavior immediately

Set `COORDINATOR_STREAMING_FORCE_BUFFERED=1` on the coordinator process and
restart. All responses will now carry `X-MacProvider-Streaming-Mode:
buffered_kill_switch`. Tool calls land in a single chunk at end-of-stream.

### Roll back the entire v0.2 deployment

Standard procedure: re-deploy the prior commit. The last pre-v0.2-IMPL
checkpoint was `83472ef` (v0.1.5 IMPL). Buyers SHOULD NOT observe a
wire-shape change because v0.2 is additive per §10c, but if a customer
reports a regression, this is the rollback target.

## Known limitations / v0.3 candidates

- AC-25a CI fixture is a skeleton + replay harness using a simulated provider;
  full live VS Code + Cline extension automation in CI is v0.3 work.
- `usage.macprovider_model_hash_observed` field is buyer-visible observation
  only in v0.2; enforcement (fail-closed on unknown hash) is v0.3 (per §10c
  Amendment 1).
- Prompt-echo guard was deleted in v0.2.3 (§10c Amendment 2). Same-family
  echo of native tool-call markup from untrusted prompt content is an
  unmitigated residual risk in v0.2. v0.3 delivers the full guard.
- Structured `usage.macprovider_malformed_tool_call` diagnostic signal is
  v0.3; v0.2 surfaces failures via the thicker error envelope only.
- Per-(buyer, provider) downgrade state lives in-memory in the coordinator
  process; it does not survive process restart and does not propagate across
  multi-coordinator deployments. Single-instance Pearl deployment is
  acceptable for v0.2; multi-instance is v0.3+.

## See also

- SPEC body: `specs/SPEC-018-agentic-tool-calling.md`
- IMPL notes: `specs/design/spec-018/SPEC-018-v0_2-IMPL-NOTES.md`
- Lock-amendment discipline: §10c.1 in the SPEC
- v0.3 deferred design: `specs/v0_3-design/`
