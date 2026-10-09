# Round-3 disposition (final round; repo audit cap reached)

| Lane | Verdict |
| --- | --- |
| Codex architecture | 0C/0H/0M |
| Codex code | 0C/0H/1M |
| Codex security | 0C/0H/1M |
| Claude | 0C/0H/1M |

Fixed:
- **Codex code M (relay marked a request ended before its end frame was sent):** the relay un-marks it if the send fails. `cc4c3278e`.
- **Codex security M (final-flush-only streams signed TTFT 0):** the final flush marks the first-token clock, and TTFT is read after it. `cc4c3278e`.
- **Claude M1, plus a second mechanism no lane found (closed-loop shed under contention):** `fc8fae015`.
  - A queue-full refusal requeues when the accept took a seat whose occupancy the Mac had not yet confirmed.
  - A reservation miss waits in the slot queue while the coordinator's own demand (in flight, leases and waiters) is below `SlotsTotal`.
  - Under CPU stress: 52 sheds in 40 runs before, 0 in 60 after.
  - Regression tests: `TestQueueFullAfterInFlightDrainedRequeuesUntilReadyReport` and `TestReservationMissBelowAdvertisedCapacityWaitsForSeat`.
  - Gates: the closed-loop test passed `-count=50` with and without `-race`, and 6 consecutive full buyer race runs passed.
- **Claude L1:** the first ready report after a refusal now applies. `fc8fae015`.
- **Claude L2:** Malibu.app's writer owns the depth key. `fc8fae015`.

Still accepted, unchanged from r2-DISPOSITION.md: ragged prefill not bound to the signed CB policy (operator decision, AGENTS.md rule 11), and the coordinator ceiling clamping calibrated depth (by design).

Evidence:
- Go: coordinator `internal/...`, gateway router and `make vet` all green.
- Swift: built with Xcode XCTest on the Studio. The affected suites pass. The only failures are environment-bound tests (keychain, launchd, signing, TLS) in code this PR does not touch.
