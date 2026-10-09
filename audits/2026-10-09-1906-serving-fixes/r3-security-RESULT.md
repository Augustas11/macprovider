
Audit result: one NEW MEDIUM finding; no NEW CRITICAL or HIGH findings.

### Finding

- **MEDIUM — `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6970`**
  - **Scenario:** A continuous-batching stream can hold all early output due to stop-string, UTF-8, or tool filtering. `hasObservedTokens` becomes true from generated token IDs (`:5811-5815`), so replay is skipped. The final buyer-visible content/tool chunk is emitted through raw `onChunk` (`:6970`, with emissions at `:11499`/`:11537`), bypassing `ContinuousBatchFirstTokenClock` (`:6905`). TTFT is captured earlier at `:6942`, remains nil, and the signed receipt falls back to `0` in `InferenceRelay.swift:1644`/`:1666`. Receipts remain cryptographically valid but report incorrect TTFT, affecting buyer/provider telemetry and calibration evidence.
  - **Status:** **NEW in the complete PR**, not introduced by `7398c746b`; distinct from the accepted replay-owner issue.
  - **Minimal fix:** Route final flush emissions through the canonical first-visible-chunk clock and capture TTFT after that flush. Keep replay-only emissions excluded from the clock. Add a regression test for final-flush-only content/tool output.

### Round-2 fixed items verified

- Depth-key precedence: `phase3-binary/Sources/MacProviderCore/Config.swift:840-847`; regression test at `ServingKnobsConfigTests.swift:306-320`.
- Streamed receipt TTFT propagation: `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:1546,1577,1644,1666`.
- Lower-ready-report ignore reset: `phase4-coordinator/internal/pool/provider.go:1763-1765,1815-1818`; test at `provider_test.go:163-180`.
- Served-cap documentation: `specs/CONFORMANCE.json:2986-3001`.

Permitted Go tests passed:

- `go test ./internal/buyer ./internal/pool`
- `go test ./internal/router`

Swift tests/builds were not run per the audit constraints.

VERDICT: 0C/0H/1M


