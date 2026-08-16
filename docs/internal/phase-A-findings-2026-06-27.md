# Phase-A network-harness findings — 2026-06-27

Internal. Source: `test/network-harness/artifacts/` (this worktree).
Audience: maintainers preparing the SPEC-002 routing-contract addendum
and the pre-beta engineering punch list.

## Run conditions

- Target: live `https://api.malibu.tech` + `wss://coordinator.malibu.tech`.
- Buyer: `~/.config/macprovider/buyer-api-key` (the operator's own account).
- Providers attached at time of run:
  - `augustass-macbook-air` — `mlx-community/Qwen3-32B-4bit`, 1 slot,
    pre-watchdog the WS was wedged for 42h (see Finding 7 + watchdog ops).
  - `air5` — `mlx-community/Qwen2.5-Coder-7B-Instruct-4bit`, 1 slot,
    hash-verified, occasionally flaps WS (same root cause as the local Mac).
  - `air8gb` — intentionally offline (operator's other machine, closed lid).
- Effective ready capacity: **2 slots × 2 models** at best, 0 when both
  flap. Coordinator counts only `ready` providers in `/v1/models`.

## Hard-invariant scoreboard

| Scenario | I1 (reconcile) | I2 (orphan 5xx) | I3 (overcharge structural) | I4 (silent hang) |
|---|---|---|---|---|
| smoke | PASS | PASS | PASS | PASS |
| 01 happy_path_concurrent | PASS | PASS | PASS | PASS |
| 02 capacity_contention | **FAIL** | PASS | PASS | PASS |
| 03 sticky_multi_turn | **FAIL** | PASS | PASS | PASS |
| 04 wrong_model | PASS | PASS | PASS | PASS |
| 05 mid_stream_drop | **FAIL** | PASS | PASS | PASS |
| 06 cold_start_race | PASS | PASS | PASS | PASS |

Per-bundle JSONL evidence in
`test/network-harness/artifacts/<scenario>-<UTC ts>/`.

## Findings

### F-1 — Per-account rate limit (429) fires at very low concurrency

**What we saw.** Scenario 02 (10 concurrent buyers, single account) →
7×429, 2×503, 1×200. Scenario 03 (3 buyers × 5 sequential, single
account) → 11×503, 2×429, 2×200. Even sequential 3 requests from one
buyer in `smoke` produced 1×5xx.

**Why it matters for beta.** The buyer's effective concurrency on the
network is currently ~1, not "as many slots as providers offer". A
beta participant hammering the API will see far more 429s than the
network's nominal capacity suggests.

**Product question for the contract.** What IS the documented
per-account concurrency limit? Is the 429 a documented
`rate_limit_exceeded` with retry-after, or an internal throttle the
contract doesn't mention?

### F-2 — Gateway returns HTTP 404 for unknown model, not 503

**What we saw.** Scenario 04 fired requests for
`nonexistent-model-9000-test-only`. Results: 2×404, 1×429. SPEC-002
v1.4.1 FR-B1 documents `503 no_provider_available` as the response
when no provider matches.

**Why it matters for beta.** OpenAI-compatible buyers (the canonical
client) interpret 404 as "endpoint missing" — they don't retry, and
they don't tell the operator anything useful. 503 with the documented
code lets clients retry or report capacity.

**Product question.** Should the contract say 404 (which the code
emits today and which "model not found" is technically reasonable for)
or 503 `no_provider_available` (what the spec says)? Pick one, write
it down.

### F-3 — Mid-stream provider drop ends in HTTP 200 + zero billed tokens

**What we saw.** Scenario 05: 1 streaming buyer request to Qwen3-32B.
Chaos event killed the local provider at t=10s mid-stream. Buyer
received 13,097 bytes of SSE content, terminated with `[DONE]`, HTTP
200, `saw_terminator=true`, but `completion_tokens_received=0`.
Gateway `usage_events` had **no row at all** for this request (I1
reported "1 harness success unmatched on gateway").

**Why it matters for beta.** The buyer got partial content for free
and the provider isn't compensated for the work done before death.
The buyer's client also has no signal that the response was truncated
(no error message, just shorter content than `max_tokens` would
suggest).

**Product question.** Three valid contracts:
1. Bill partial — provider gets paid, buyer charged for delivered tokens.
   Gateway settles `usage_events` with `outcome=stream_truncated` and
   the count actually delivered.
2. Best-effort failover — gateway retries on another provider with
   `excluded=[failed]`. Buyer sees one stream's worth, billed once.
3. Status quo — buyer gets free partial, provider works for free, no
   billing entry. Write it down as the explicit contract if so.

### F-4 — Cold-start race returns HTTP 404, not "warming" / 503

**What we saw.** Scenario 06: chaos killed the local provider at t=0;
buyer fired Qwen3-32B request at t=0.2s (while provider restart was
in flight). Result: HTTP 404 `not_found` in 515ms.

**Why it matters for beta.** Indistinguishable from F-2 — the buyer
can't tell "this model doesn't exist" from "give it 30 seconds."
There's no `model_warming` or `try_again_after_seconds` signal.

**Product question.** Should the network expose a transient
"warming/cold-start" state with a retry hint? Or accept that
cold-start during chaos is rare enough to fail like wrong-model?

### F-5 — No shared correlation ID across gateway↔coordinator

**What we saw.** Verified live: gateway returns one UUID to the buyer
(`Eebb3b7a-…`), coordinator writes a different UUID in `request_log`
(`A100f43b-…`) for the same logical request. They never overlap. The
harness's reconciler had to fall back to fuzzy matching by
`(model, completion_tokens, ts ± 60s)`.

**Why it matters for beta.** Without a shared id, the harness can't
confidently distinguish "gateway over-billed me by 17 tokens" from
"concurrent live traffic from another buyer happened in my window".
That's the exact difference between a money-path bug and noise. The
+17/+32 token "drift" in scenarios 02/03 is **almost certainly
concurrent traffic**, not actual overcharge — but we can't prove it.

**Engineering ask (not a product call — clear win).** Plumb a
`X-Correlation-Id` (or similar) end-to-end:
- Gateway accepts on inbound request, generates if absent, returns in
  response header.
- Gateway forwards to coordinator via WS/HTTP.
- Coordinator stores in `request_log.correlation_id`.
- Gateway stores in `usage_events.correlation_id`.

Single line of correlation makes I1 reconcile **exactly**, not
fuzzily.

### F-6 — Silent WS disconnection on provider Macs (fleet-wide)

**What we saw.** Local provider PID 49589 had been alive 1d19h, was
listening on `127.0.0.1:18080`, but `lsof` showed **zero outbound
sockets**. WS to coordinator was dead. Coord side: 90s
heartbeat-inactive threshold fired the kill, but the provider's reconnect
loop had silently stopped firing. `~/Library/Logs/macprovider/macprovider.out.log`
had no entries between `2026-06-25 13:17` and the next restart.

`air5` exhibited the same pattern — coord journal showed it being
removed after disconnect-grace at 06:15:47, then reconnecting moments
later (operator likely intervened or launchd kicked).

**Why it matters for beta.** Every provider on the network is currently
vulnerable. Operator has no signal until buyers start failing.

**Mitigation shipped (local).** `ops/macprovider-watchdog/` LaunchAgent
polls every 60s, checks `netstat` for an ESTABLISHED TCP to coord IP,
`launchctl kickstart`s on detection of half-open state. Installed and
verified. Generalizing requires reading provider id from
`~/.config/macprovider/config.yaml` and shipping the watchdog as part
of `get.malibu.tech/install.sh`.

**Engineering ask.** Proper Swift-side fix in `phase3-binary/`. Most
likely culprit: `runReconnectLoop`'s `connectAndRunOnce()` hangs
indefinitely when the WS dies in a way URLSession doesn't surface
(suspected: macOS App Nap / Task starvation). Needs repro (suspend the
Mac for 5 minutes? hold a network blip? `MACPROVIDER_KEEPALIVE_DEBUG=1`
and wait days?) before the fix.

### F-7 — Sticky affinity is OFF in production (confirmed)

**What we saw.** `/v1/models` tier1_disclosure reports
`sticky_affinity.enabled: false`. Scenario 03's data was too noisy
(11/15 5xx) to verify the routing distribution empirically, but the
disclosure is authoritative.

**Phase B decision.** Do we want sticky for beta? Pro: model context
caching reduces TTFT for multi-turn workloads. Con: fairness/load
distribution loses.

### F-8 — Harness streaming token counter understates

**What we saw.** Scenario 05 buyer received 13 KB of SSE content but
`completion_tokens_received=0`. The harness's `chunkPayload` parser
looks for `usage.completion_tokens` in each chunk. Streaming responses
typically only emit `usage` in the FINAL chunk (or sometimes never
inline for SSE — clients are expected to compute from delta content).

**Engineering ask (harness-side, not network).** Either (a) count
`choices[].delta.content` tokens locally using a tokenizer, or (b) sum
chunk content lengths as a proxy. Without this, I3 (overcharge) is
basically blind on streaming.

## Non-findings (good news)

- **I4 never fired.** No silent hangs across 6 scenarios. Terminating
  errors are properly emitted on every failure mode tested.
- **I2 never fired.** Every 5xx the harness saw carried a request id
  — the gateway is settle-path eligible for all failures.
- **The harness itself is sound.** All 6 scenarios completed; chaos
  events fired on schedule; artifact bundles are clean and triagable.

## What to read for each finding

| Finding | Primary evidence |
|---|---|
| F-1 | `02_capacity_contention-*/per_request.jsonl`, `03_sticky_multi_turn-*/metrics_summary.json` |
| F-2 | `04_wrong_model-*/per_request.jsonl` (2×404, 1×429) |
| F-3 | `05_mid_stream_drop-*/per_request.jsonl` + `chaos_events.json` |
| F-4 | `06_cold_start_race-*/per_request.jsonl` (HTTP 404 at +515ms) |
| F-5 | Any scenario's `ledger_reconcile.json` — UUID columns never overlap |
| F-6 | `ops/macprovider-watchdog/README.md` + Pearl coord journal grep `augustass-macbook-air` |
| F-7 | live `GET /v1/models` → `tier1_disclosure.sticky_affinity.enabled` |
| F-8 | `05_mid_stream_drop-*/per_request.jsonl` — `bytes_received=13097`, `completion_tokens_received=0` |
