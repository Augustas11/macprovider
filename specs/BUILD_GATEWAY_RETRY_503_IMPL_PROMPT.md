# BUILD_GATEWAY_RETRY_503_IMPL — Gateway retry-with-backoff on coordinator 503 (no_provider_available)

## Motivation (measured, 2026-07-04)

A reliability sweep of 90 sequential streaming buyer requests against
`https://api.streamvc.live/v1/chat/completions` produced the following
503 rates as a function of inter-request gap (single-provider network,
`mac` provider on M5 32GB, `max_concurrency_override: 1`, model
`qwen3-coder-30b-a3b-instruct`):

| Inter-request gap | Success | 503 rate |
|---|---:|---:|
| 0.5 s | 18/30 | **40.0 %** |
| 2.0 s | 26/30 | **13.3 %** |
| 5.0 s | 30/30 | 0.0 % |

Coordinator journal shows the mechanism:

```
provider_id=mac state=busy slots_free=0 slots_total=1
```

Gateway journal shows the corresponding response:

```
INFO chat completion request_id=… status=503 wall_ms=4
```

Coordinator returns 503 in ≈4 ms when the sole provider slot is still
draining. The buyer's second request (arriving < 500 ms after the first
completed) fails, even though the provider will be free within tens of
milliseconds. No client SDK retries on this class of 503 by default.

## Goal (this PR)

Wrap the gateway's coordinator dispatch in a bounded retry loop that
retries **only** 503 responses whose OpenAI error `code` field is
`no_provider_available` (or whose body indicates the same class — see
§ "Retryable-503 detection" below). All other 503 sub-classes
(`tier2_hash_*`, `null-usage-provider-error`, etc.) must continue to
pass through with existing semantics.

The retry loop must be transparent to the buyer: on success the buyer
sees a normal 200 (or 5xx from a subsequent attempt), never a
partial-then-retried response body. Total added latency must be
bounded so a paying buyer never waits > ~1 s of retry backoff on a
single request.

## Non-goals

- No change to coordinator code (phase4-coordinator).
- No change to provider code (phase3-binary).
- No new buyer-visible endpoints or headers.
- No change to non-503 error handling.
- No change to streaming settlement, reservation, or receipt flows.
- No client-facing rate-limit header changes.

## Scope of change

Files that MUST change:
- `phase5-gateway/internal/router/chat_proxy.go`
- `phase5-gateway/internal/config/config.go`
- `phase5-gateway/internal/router/chat_proxy_retry_test.go` (new file)

Files that MAY change (only if the implementer determines it's the
cleanest home):
- `phase5-gateway/dist/gateway.yaml.example` (add commented example of
  the new config block, if such a file exists — do not create one if
  not).
- Package-level docs / comments if adding a helper.

Files that MUST NOT change:
- Anything under `phase4-coordinator/**`.
- Anything under `phase3-binary/**`.
- Existing test files, except adding new tests to
  `chat_proxy_retry_test.go` (new file).
- Any billing / settlement / receipt logic path outside the retry loop
  itself.

## Location

The retry loop wraps the coordinator dispatch. In `chat_proxy.go`, this
is the block around:

```go
resp, err := s.client.Do(upReq)
```

Currently at approximately line 340, inside the main handler function
that runs before the split to `forwardStreamingChat` /
`forwardNonStreamingChat`.

## Behavioural requirements

**R1 — Retryable class only.** A 503 is retried iff *all* of the
following hold:

- HTTP status is exactly 503.
- The response body's OpenAI error `code` field (`{"error":{"code":…}}`)
  is `no_provider_available`, OR the body is empty / not-JSON while
  status is 503 (coord may fast-refuse with an empty body — treat that
  as `no_provider_available` for retry purposes).
- The body is NOT recognised by `isNullUsageProviderError(body)`.
- The body is NOT recognised by `coordinatorTier2PolicyError(status,
  body)`.

Any 503 not matching all four MUST fall through unchanged to the
existing handlers (`forwardStreamingChat` /
`forwardNonStreamingChat`), which will apply the current pass-through
or refund logic.

**R2 — Bounded attempts.** Default: 3 total attempts (1 initial + 2
retries). Configurable via new config block (see § "Config").

**R3 — Exponential backoff with jitter.** Between retry attempts the
gateway sleeps for `backoff_base_ms * 2^(attempt-1)` capped at
`backoff_max_ms`, then applies ±25 % uniform random jitter. Defaults:
`backoff_base_ms = 100`, `backoff_max_ms = 500`. Worst-case total added
latency with defaults: 100 + 200 = 300 ms plus ≤ 25 % jitter each, so
< 400 ms of retry sleep across a full 3-attempt loop.

**R4 — Context/cancellation.** All retries share the same `upCtx`
(the request context with the 300 s coordinator budget). If
`upCtx.Err() != nil` at any point before or during the sleep, abort
the loop and return the last observed response / error. Do not sleep
past context deadline.

**R5 — Request replay.** The buyer's request body (`bytes.NewReader(
body)` at approx. line 274) MUST be replayed intact on each attempt.
Preferred: rebuild `upReq` on each attempt with a fresh
`bytes.NewReader(body)` and re-apply headers with the same helper /
inline code that produced the first-attempt request. Alternative: seek
the reader back to zero via `bytes.Reader.Seek(0, io.SeekStart)` before
each retry. Either is acceptable so long as request headers, method,
URL, and body bytes are byte-identical across attempts.

**R6 — Response body handling.** On a retryable 503, the previous
response's body MUST be fully drained (or a bounded prefix drained
enough to test `code`) and then closed before the retry sleep. Failing
to close body leaks connections in `net/http`'s conn pool.

**R7 — Reservation preservation.** The buyer's concurrency reservation
and quota reservations were taken before the dispatch. The retry loop
MUST NOT refund or re-take reservations between attempts. Only the
terminal outcome (either final success passed to
`forward{Streaming,NonStreaming}Chat`, or terminal failure) touches
reservation state, using the existing paths already wired to the
non-retry code path.

**R8 — Existing behaviour on terminal failure.** After exhausting all
retry attempts, the loop MUST hand the final `*http.Response` (with a
buffer-backed body if it was drained during the retry check — see R6)
back to the existing dispatch site so that
`forward{Streaming,NonStreaming}Chat` handles the 503 exactly as they
do today. Response body content MUST NOT be lost between the retry
check and the downstream handler.

**R9 — Structured observability.** For each retry attempt (i.e. each
time the loop decides to sleep-and-retry, NOT the initial dispatch),
emit exactly one `slog.Info(...)` line with:

- key: `"gateway coord 503 retry"` (message)
- fields: `request_id` (from `requestID(r)`), `attempt` (1-indexed
  attempt about to be made, i.e. the retry number, so first retry is
  `attempt=2`), `backoff_ms` (the actual sleep in ms after jitter),
  `body_code` (the parsed OpenAI error code, or `""` if unparseable /
  empty).

For terminal success on a retry attempt (i.e. attempt > 1 returned
200), emit exactly one `slog.Info("gateway coord 503 retry recovered",
...)` line with `request_id`, `attempt` (the winning attempt number,
so 2 or 3), and `total_backoff_ms` (sum of all sleeps executed).

For terminal failure (all attempts returned retryable 503), emit
exactly one `slog.Warn("gateway coord 503 retry exhausted", ...)` line
with `request_id`, `attempts` (total attempts made, equal to
configured max), and `total_backoff_ms`.

Do NOT emit a log line on the initial (attempt=1) dispatch even if it
was a retryable 503 — that is covered by the retry-attempt line for
the *following* retry.

**R10 — Retry disabled.** If the new config field
`retry_503.enabled` is false, the retry loop MUST behave exactly as
today's code: single dispatch, pass through response to downstream
handler regardless of status. This includes not emitting any of the
R9 log lines.

## Retryable-503 detection

Add a package-private helper:

```go
// isCoordNoProviderAvailable503 returns true when the coordinator's
// response indicates the request MAY succeed on a retry — i.e. the
// provider pool was momentarily busy. It intentionally does NOT
// retry:
//   - null-usage provider errors (billable failures)
//   - tier2 policy errors (permanent for this request)
//   - any 5xx other than 503
func isCoordNoProviderAvailable503(status int, body []byte) bool { … }
```

Implementation:

- Return false if `status != 503`.
- If `body` is empty or not valid JSON, return `true` (coord fast-refuse).
- If `isNullUsageProviderError(body)` returns true, return `false`.
- If `coordinatorTier2PolicyError(503, body)` returns true, return
  `false`.
- Parse OpenAI error envelope via existing `openAIErrorCode(body)`.
  If code is `""` or `no_provider_available`, return `true`. Otherwise
  return `false`.

Place this helper adjacent to `coordinatorTier2PolicyError` and
`openAIErrorCode` in `chat_proxy.go` for review-locality.

## Config

Extend `phase5-gateway/internal/config/config.go`:

```go
type Retry503Config struct {
    Enabled          bool `yaml:"enabled"`
    MaxAttempts      int  `yaml:"max_attempts"`
    BackoffBaseMs    int  `yaml:"backoff_base_ms"`
    BackoffMaxMs     int  `yaml:"backoff_max_ms"`
}
```

Add a `Retry503 Retry503Config `yaml:"retry_503"`` field on the top-level
`Config` (or on the most appropriate nested struct — the implementer
should pick the location that best matches the surrounding style).

Defaults applied via existing config-defaults pattern (or in a small
new normaliser if the codebase doesn't have one):

- `Enabled: true`
- `MaxAttempts: 3`
- `BackoffBaseMs: 100`
- `BackoffMaxMs: 500`

Validation:
- `MaxAttempts` in range `[1, 10]`. Value 1 = disable retry (single
  attempt). Value > 10 = config validation error.
- `BackoffBaseMs` in `[10, 5000]`.
- `BackoffMaxMs` in `[10, 10000]`.
- `BackoffMaxMs >= BackoffBaseMs`.

Return a config-validation error on out-of-range values, using the
existing pattern (see `WarmupFallbackS` validation as reference).

## Jitter

Use `math/rand/v2` (already Go 1.22+; check go.mod) via a
package-level `*rand.Rand` if the codebase uses one, or the global
`rand.Float64()` if it doesn't. Do NOT introduce a new random-source
package. Jitter formula:

```go
jittered := sleep + (int64(sleep) * int64(rng.IntN(51) - 25)) / 100
if jittered < minSleep { jittered = minSleep }
```

Ensure the sleep is always non-negative.

## Acceptance criteria

**AC1** — `swift build` and any relevant Go build succeeds:
`cd phase5-gateway && go build ./...` clean.

**AC2** — All existing tests pass unchanged:
`cd phase5-gateway && go test ./... -count=1`.

**AC3** — New tests in `phase5-gateway/internal/router/chat_proxy_retry_test.go` cover:

- Coord returns 503-no-provider twice then 200; buyer sees 200; two
  retry log lines emitted; one `retry recovered` log line.
- Coord returns 503-no-provider three times; buyer sees 503; two retry
  log lines emitted; one `retry exhausted` log line.
- Coord returns 503-tier2-policy on first attempt; buyer sees existing
  pass-through behaviour; ZERO retry log lines emitted.
- Coord returns 503-null-usage-provider on first attempt; buyer sees
  existing pass-through billing behaviour; ZERO retry log lines
  emitted.
- Coord returns 200 on first attempt; buyer sees 200; ZERO retry log
  lines emitted.
- Config `retry_503.enabled=false`: coord returns 503-no-provider once;
  buyer sees 503; ZERO retry log lines emitted.
- Config validation: `max_attempts=0`, `max_attempts=11`,
  `backoff_base_ms=5`, `backoff_max_ms=15000`, and
  `backoff_max_ms<backoff_base_ms` each produce a load-time error via
  the existing config-loader entry-point.
- Retry replay integrity: verify the coordinator sees byte-identical
  request bodies across all three attempts (e.g. by capturing bodies
  in a mock RoundTripper).
- Concurrency reservation: verify (via a store spy) that no
  refund/re-take happens between retry attempts.

**AC4** — Streaming path: retry loop applies BEFORE the split into
`forwardStreamingChat` / `forwardNonStreamingChat`. This means a
retried 503 on a streaming request must result in the buyer seeing
either the eventual 200 stream or the terminal 503 — never a mixed
partial-body response.

**AC5** — Under default configuration, worst-case retry backoff for a
buyer whose request exhausts all attempts must not exceed 750 ms of
sleep total (measured; assert in test with a fake clock or bounded
sleep captor).

**AC6** — Coordinator client cancellation: an outbound context cancel
(buyer disconnects) during retry sleep must abort the loop within
one context.Deadline check (i.e. the sleep must be cancellable via
`select { case <-time.After(sleep): ; case <-upCtx.Done(): }`).

## Observability contract

Structured `slog` lines only. Do NOT add metrics counters, Prometheus,
or new HTTP endpoints in this PR. Metrics wiring can be a follow-up.

Log messages must be the exact strings in R9 so operator dashboards
can grep for them stably.

## Backwards compatibility

- Buyer-observable behaviour on non-503 responses is unchanged.
- Buyer-observable behaviour on `retry_503.enabled=false` is unchanged
  vs today.
- Buyer-observable behaviour on retry-exhausted-503 is unchanged (same
  `writeError(...503 no_provider_available)` as today).
- The only new buyer-observable behaviour is that a buyer whose
  request would previously have received 503 may now receive 200 if a
  retry succeeds (this is the goal).

## Prohibited implementation choices

- Do NOT wrap `s.client` in a middleware that retries. The retry
  behaviour is 503-body-content-specific and must be visible in the
  handler.
- Do NOT introduce a background goroutine for retries. The retry
  happens synchronously on the request goroutine.
- Do NOT change `s.client.Timeout`, `Transport`, or connection-pool
  configuration.
- Do NOT change the `X-Request-ID` forwarding — the same request ID
  must be sent on every retry attempt so coord's request_log can
  correlate.
- Do NOT reset or mutate the buyer's concurrency reservation between
  attempts.
- Do NOT change `writeError` / `passThroughNoProviderCoordinatorError`
  / `passThroughReceiptEligibleProviderError` signatures or behaviour.
- Do NOT add sleep or wait logic on the initial (attempt=1) dispatch.

## Test data notes

Where existing test infrastructure uses `httptest.NewServer`, prefer
extending that pattern. Where a mock `http.RoundTripper` on `s.client`
is used, prefer that. If neither pattern is present in current
`chat_proxy` tests, look at `server_test.go` for a compatible harness.

## Commit style

The commit message follows the repo convention:

```
fix(gateway): retry coord 503 no_provider_available with bounded backoff (#<PR>)

Motivation: reliability sweep 2026-07-04 measured 40% 503 rate under
0.5s inter-request gap on a single-slot provider network. Provider
slot drains within tens of milliseconds; second request arrives too
early and coord refuses in 4ms with no_provider_available.

Change: gateway wraps coord dispatch in a bounded retry loop (max 3
attempts, exponential backoff 100→500ms with ±25% jitter). Only 503s
whose OpenAI error code is no_provider_available (or empty body) are
retried; tier2 policy errors and null-usage provider errors pass
through unchanged.

Constraint: total added latency ≤ 750ms; reservations preserved
across attempts; request bodies replayed byte-identical.

Config: new retry_503.{enabled,max_attempts,backoff_base_ms,
backoff_max_ms} block, defaults on.

Tested: new chat_proxy_retry_test.go; existing suite unchanged.
```

## Audit boundaries

Three separate audit lanes will be fired against this diff after
implementation:

- **CODE** — correctness of retry loop, race conditions, context
  cancellation propagation, response body drain / close discipline,
  header replay integrity, jitter bounds, config validation branches.
- **SECURITY** — no request body / auth header leakage across
  attempts, no unbounded resource consumption, no timing side-channel
  in retry decisions, correct behaviour when buyer disconnects mid-retry.
- **ARCHITECT** — placement in `chat_proxy.go` vs
  `forward{Streaming,NonStreaming}Chat`, config block naming
  consistency with existing knobs, observability line naming stability
  for future metric wire-up, no scope creep into coord/provider code
  paths.

## References

- Reliability sweep raw data:
  `scratchpad/results/reliability_sweep.json` (not committed).
- Coordinator single-slot mechanism: `phase4-coordinator/internal/ws/
  server.go` around the `slots_free=0` heartbeat and immediate 503
  return path.
- Existing 503 handling: `phase5-gateway/internal/router/chat_proxy.go`
  around lines 374-408 (non-stream) and 460-490 (stream).
- Existing tier2 / null-usage guards:
  `coordinatorTier2PolicyError` and `isNullUsageProviderError` in
  the same file.
