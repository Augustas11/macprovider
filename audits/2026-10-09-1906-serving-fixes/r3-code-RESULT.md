
Round 3 finds no NEW CRITICAL/HIGH issues. One NEW MEDIUM remains, plus one PRE-EXISTING MEDIUM capacity-path gap.

Round-2 fixes verified:

- Live-slot reservations now use live callbacks under queue/pool locking: `slot_queue.go:126-235`, `server.go:8047-8084,8898-8902,9160-9188`.
- Capacity 429 negotiation, legacy fallback, gateway propagation, refund, and conservative settlement are present: `server.go:2491-2494,7440-7474`; `chat_proxy.go:716-717,2139-2155,2408-2416`.
- SPEC-006 status contradiction is corrected: `specs/SPEC-006-buyer-api.md:2842-2865`.
- Rollback-safe depth/v1 calibration handling is present: `Config.swift:837-847`; `ConfigApplier.swift:588-593,695-708`; `AutotuneConcurrencyCalibration.swift:118-146`.
- Sparse calibration TTFT fallback uses first visible deltas: `AutotuneConcurrencyCalibration.swift:467-469,491-511`.
- Lower ready reports are ignored once, then accepted; reset paths are covered: `provider.go:1754-1767,1796-1817,2848-2875`; `provider_test.go:163-180`.
- CB TTFT now reaches streaming and cancellation receipts: `InferenceRelay.swift:1543-1547,1573-1580,1639-1669`; runtime timing is present in `ModelRuntime.swift:6880-6905,6933-6943`.
- Ragged grouping spread and row-local masks are enforced: `ContinuousBatchScheduler.swift:684-759`; `PagedKVRuntimeBridge.swift:3439-3459,3910-3921`.
- Lab traps and the low-severity accounting/spec fixes are present: `bench.sh:16-20`, `profile-serve-1906.sh:10-15`, `forward_with_failover.go:100-111`, `CONFORMANCE.json:2997-3001`.

Findings:

- **MEDIUM — NEW** — `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:388-393`, admission at `:289`.

  The relay inserts the request into `endedRequestIDs` before `try await sendFrame(frame)` succeeds. During prolonged websocket backpressure, the terminal frame has not reached the coordinator, but `active.count - endedRequestIDs.count` already admits another request. The provider and coordinator can temporarily disagree about occupancy; the original buyer may time out/retry while new work is accepted.

  Minimal fix: mark the request ended only after the terminal `sendFrame` succeeds, and add a regression test with a blocked/failing terminal send. This is NEW in the full PR, though not introduced by `7398c746b`.

- **MEDIUM — PRE-EXISTING** — `phase4-coordinator/internal/buyer/server.go:4681-4691`.

  Buffered streaming/tool-call requests classify provider `error_queue_full` as `wsForwardFailed` instead of `wsForwardQueueFull`. Consequently, the shared failover path does not set `capacityRefused` or apply the queue-full hold, and the buyer misses the intended capacity-shed response path used by normal streaming at `server.go:4459-4463`.

  Minimal fix: special-case `end.Status == "error_queue_full"` in the buffered branch and return `wsForwardQueueFull` with the appropriate attempt metadata.

The explicitly accepted risks in `r2-DISPOSITION.md`—signed CB policy scope, coordinator depth ceiling 8, replay-owner TTFT, and internal retry telemetry—are not re-reported.

Validation passed:

- `go test ./internal/buyer ./internal/pool`
- `go test ./internal/router/...`

No Swift builds/tests or network operations were run. Worktree remains clean.

VERDICT: 0C/0H/1M


