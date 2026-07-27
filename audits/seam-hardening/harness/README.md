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
- `phase4-coordinator/internal/buyer/seam_h3_test.go`

## Run

```bash
cd phase5-gateway     && go test ./internal/router/ -run TestSeam  -v
cd phase4-coordinator && go test ./internal/buyer/  -run TestSeamH -v
```

## Results (verified 2026-07-26) — 7 of 8 execute; only H4 is a documented skip

**Gateway suite**

| Scenario | Finding | Verdict | What executes |
|---|---|---|---|
| **H1** `FlatWallKillsProgressingStream` | P0-2 | **PASS = confirms FAIL** | a steadily-progressing stream is cut at the (shortened) total wall, never hitting the idle timer |
| **H2** `BuyerDisconnectSettlesConsumerSide` | — | **PASS** | buyer-cancel → consumer-side settle, billed bounded to delivered |
| **H5a** `IdlessRetryDoubleBills` | P1-1 | **PASS = confirms FAIL** | two id-less calls bill 40 (2×20) |
| **H5b** `StableRequestIDBillsOnce` | P1-1 | **PASS** (control) | same-UUID 2nd call → 409, billed once (20) |
| **H6** `ProviderOverReportBoundedToDelivered` | — | **PASS** | provider `completion_tokens=100000` rejected → estimate, billed 24 not 100008 |
| **H7** `SettlementNotCrashDurable` | P1-2 | **PASS = confirms GAP** | committed 200 stream + settle double-failure → usage row dropped, refunded, nobody billed |
| H3 / H4 | P0-3 / P2-1 | pointer-SKIP | see coordinator suite |

**Coordinator suite**

| Scenario | Finding | Verdict | What executes |
|---|---|---|---|
| **H3** `RelayTimeoutStrikesOnBuyerCancel` | P0-3 | **PASS = confirms FAIL** | one `ErrRelayTimeout` + a cancelled buyer ctx (threshold=1) → provider struck to `StateDegraded` |
| **H4** `SingleTerminalWins` | P2-1 | **SKIP (documented)** | not unit-testable: no arbiter joins the billing terminal and the buyer-504 terminal; testable only once a single-terminal arbiter exists |

The "confirms FAIL/GAP" tests pass by asserting the **buggy-today** behavior, so when a fix lands
they flip to failing-until-the-assertion-is-updated — a durable regression tripwire per finding.

## Mechanism note (surfaced by wiring H1)

The total wall is `upCtx = context.WithTimeout(r.Context(), CoordinatorTimeout())`
(`chat_proxy.go:122`); the upstream request is created with it (`http.NewRequestWithContext(upCtx,…)`).
The streaming read loop selects on `r.Context()` + the 10s idle timer (`:1047`), **not** `upCtx` — so
the total wall reaches a mid-stream generation only because the real `net/http.Transport` closes the
body when `upCtx` expires. A naive mock pipe ignores ctx and would let a stream outlive the wall (a
test artifact, not a code fix); `seamStreamingUpstreamCtx` honors the request ctx to emulate the real
transport, confirming P0-2 faithfully.
