# harness/ — executable seam regression tests

Simulates **our `phase5-gateway` enrolled as an OpenRouter upstream** and runs the
adversarial scenarios that reproduce each seam risk in `../findings.md`, asserting on wire
status + `usage` billing + settlement/health outcome.

The rig is not a separate server: the "mock-upstream" is a controllable `roundTripFunc`
transport injected into the gateway via `WithHTTPClient` (and, for the coordinator tests, a
directly-driven `RelayStream`). This reuses each package's own test scaffolding, so the tests
are deterministic and need no running server or credentials.

Test files:
- `phase5-gateway/internal/router/seam_harness_test.go`
- `phase5-gateway/internal/router/idless_dedupe_test.go` (H5a's miss/bypass siblings, #762)
- `phase5-gateway/internal/router/settlement_journal_recovery_test.go` (H7's recovery-ladder
  siblings, #763)
- `phase5-gateway/internal/settlement/journal/journal_test.go` (H7's durability siblings: the
  per-effect fsync, torn tails, rotation/prune, reopen-after-close, the hard size cap)
- `phase4-coordinator/internal/buyer/seam_h3_test.go`

## Run

```bash
cd phase5-gateway     && go test ./internal/router/ -run TestSeam  -v
cd phase5-gateway     && go test ./internal/router/ -run TestSettlementJournal -v   # H7 siblings (#763)
cd phase5-gateway     && go test ./internal/settlement/... -v                       # journal durability (#763)
cd phase4-coordinator && go test ./internal/buyer/  -run TestSeamH -v
```

## Results (verified 2026-07-27) — 7 of 8 execute; only H4 is a documented skip

**Gateway suite**

| Scenario | Finding | Verdict | What executes |
|---|---|---|---|
| **H1** `ProgressingStreamSurvivesLegacyWall` | P0-2 | **PASS = certifies FIX** (#760) | a steadily-progressing stream runs 3s past a 1s legacy wall and completes with `[DONE]`, no `provider_disconnected`, clean usage outcome |
| **H2** `BuyerDisconnectSettlesConsumerSide` | — | **PASS** | buyer-cancel → consumer-side settle, billed bounded to delivered |
| **H5a** `IdlessRetryBillsOnce` | P1-1 | **PASS = certifies FIX** (#762) | two id-less calls bill 20 once; 2nd carries `X-MacProvider-Dedupe: replay` with attempt 1's exact body, upstream dispatched once |
| **H5b** `StableRequestIDBillsOnce` | P1-1 | **PASS** (control) | same-UUID 2nd call → 409, billed once (20) |
| **H6** `ProviderOverReportBoundedToDelivered` | — | **PASS** | provider `completion_tokens=100000` rejected → estimate, billed 24 not 100008 |
| **H7** `SettlementRecoveredFromJournal` | P1-2 | **PASS = certifies FIX** (#763) | committed 200 stream + settle double-failure → still dropped IN-BAND (refunded, `usageRows=0`), but the effect journaled before the attempt is re-driven by a second Server over the same store + journal into `usageRows=1` / 20 tokens, refund intact, seal `usage_event`; a second pass is a no-op |
| H3 / H4 | P0-3 / P2-1 | pointer-SKIP | see coordinator suite |

**Coordinator suite**

| Scenario | Finding | Verdict | What executes |
|---|---|---|---|
| **H3** `RelayTimeoutStrikesOnBuyerCancel` | P0-3 | **FIXED (#761) — asserts guard** | one `ErrRelayTimeout` + a cancelled buyer ctx (threshold=1) → cancel terminal, provider stays `StateReady` |
| **H3s** `RelayTimeoutNoStrikeOnBuyerCancel` | P0-3 | **FIXED (#761) — asserts guard** | streaming twin, 20 iterations across the select race — provider stays `StateReady` |
| **H4** `SingleTerminalWins` | P2-1 | **SKIP (documented)** | not unit-testable: no arbiter joins the billing terminal and the buyer-504 terminal; testable only once a single-terminal arbiter exists |

The "confirms FAIL/GAP" tests pass by asserting the **buggy-today** behavior, so when a fix lands
they flip to failing-until-the-assertion-is-updated — a durable regression tripwire per finding.
As of #763 no gateway scenario is still in that state: H1, H5a and H7 have all been re-pointed at the
shipped fix, with their scenarios (not their assertions) left untouched, so each one now guards a
behavior instead of documenting a gap.

## Mechanism note (surfaced by wiring H1)

The total wall **was** `upCtx = context.WithTimeout(r.Context(), CoordinatorTimeout())`
(`chat_proxy.go:122`); the upstream request is created with it (`http.NewRequestWithContext(upCtx,…)`).
The streaming read loop selects on `r.Context()` + the idle timer, **not** `upCtx` — so
the total wall reached a mid-stream generation only because the real `net/http.Transport` closes the
body when `upCtx` expires. A naive mock pipe ignores ctx and would let a stream outlive the wall (a
test artifact, not a code fix); `seamStreamingUpstreamCtx` honors the request ctx to emulate the real
transport, which is what made the original P0-2 confirmation faithful — and is exactly what makes the
flipped test a real regression tripwire now.

**Post-#760.** That wall is replaced by one cancel funnel with per-phase budgets
(`phase5-gateway/internal/router/request_deadlines.go`): `admission` → `first_token` →
a never-re-armed `stream_ceiling` derived from `max_tokens`, plus the idle timer converted from
"any byte" to CONTENT progress. Non-streaming keeps its flat wall
(`timeouts.non_stream_request_seconds`, unchanged 300s). H1 therefore flipped from
"PASS = confirms FAIL" to "PASS = certifies FIX", with the scenario itself untouched.

The wall had a **second copy** the harness cannot see: `http.Client.Timeout` in `cmd/gateway/main.go`,
which also covers body reads. Fixing only the request context would have been a production no-op, so
the client is now built by a testable `newCoordinatorClient(cfg)` with `Timeout: 0` and a dedicated
regression test (`cmd/gateway`, `TestCoordinatorClientHasNoBodyTimeout`, `httptest.NewServer`-backed).

## Mechanism note (H5a, post-#762)

H5a's scenario is likewise untouched — two byte-identical id-less calls — but its verdict flipped from
"PASS = confirms FAIL" to "PASS = certifies FIX". A fingerprint over the RAW body bytes (plus account,
demo-token hash, and sticky conversation tag) lets attempt 2 replay attempt 1's buyer-visible response
instead of re-dispatching inference; `X-MacProvider-Dedupe: replay` is what the tripwire asserts on.

The replay cache is explicitly NOT the money invariant, so a green H5a alone would over-claim: the
durable `(account_id, request_id)` reservation key still is, and every cache miss adopts attempt 1's id
and lands on the existing `duplicate_request_id` 409. `idless_dedupe_test.go` carries that half —
outside-window resend, truncated stream, error terminal, waiter-cap overflow (asserting the adopted id
on the 409), body eviction, both bypasses, and the `idless_dedupe_window_seconds: 0` kill switch — so
"billed once" is proven on the miss paths and not only on the happy path.

## Mechanism note (H7, post-#763)

H7's scenario is untouched — same settle-failing spy, same double failure — and so is its IN-BAND
outcome: the request goroutine still refunds and still writes no usage row, because at that point
there is nothing left to try. What flipped is the PERMANENCE. The settle effect is journaled (one
`write(2)` + `fsync`) BEFORE the settle attempt, to an append-only JSONL file that is deliberately
NOT `gateway.db`: a table in the same sqlite file shares every failure mode with the write that just
failed, so it would have turned H7 green while leaving the risk untouched.

The tripwire therefore asserts BOTH halves — the in-band drop AND the recovery — and it runs the same
`RecoverSettlementJournal` entry point `cmd/gateway` runs at startup and on its ticker. A regression
that stops arming the effect, seals it before the durable bill exists, or breaks a rung of the
re-drive ladder turns H7 red again. What H7 alone does NOT prove: that the record is durable across a
power loss (`journal_test.go` pins the fsync call order through the real file), that a re-drive of an
already-settled request cannot double-bill (`TestSettlementJournal_SettleLandedButSealLost`), or that
a `#762` replay journals nothing (`TestSettlementJournal_ReplayedIdlessRetryWritesNoEffect`) — a
replay performs no reserve and no settle, so a journal record there would describe a money effect
that never happened.

The companion clocks in the harness suite live in
`phase5-gateway/internal/router/request_deadlines_test.go` (ceiling on an endless stream, heartbeat-only
stream vs. content progress, first-token phase, cause-based structured-output timeout).
