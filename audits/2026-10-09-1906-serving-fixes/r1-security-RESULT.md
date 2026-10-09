
Audit completed read-only. I reviewed the merge-base diff (87 files), surrounding specs, and ran:

- `go test ./internal/buyer ./internal/pool`
- `go test ./internal/router/...`

Both passed. No network, PR fetch, Swift build, or Swift tests were run.

Findings:

1. **MEDIUM — NEW — live-slot accounting is incomplete**

   Files: `phase4-coordinator/internal/buyer/server.go:8857,9129`; `phase4-coordinator/internal/buyer/relay_blind.go:429,474,527`; `phase4-coordinator/internal/pool/provider.go:1718-1733`

   Several pinned, queued, relay-blind, and private-provider paths still pass snapshot `provider.SlotsFree` into reservation/blocking checks instead of using `Registry.RoutableSlotsFree`.

   During rollout, a snapshot may report one free slot after another request consumes it or a safety hold activates. The coordinator can then reserve or dispatch against zero live capacity, producing provider queue-full responses, unnecessary 429/retry churn, and stale occupancy accounting. Privacy eligibility remains enforced; this is an integration defect in slot accounting.

   Minimal fix: route every reservation/blocking path through a live-slot callback under the queue lock, including pinned and relay-blind/private selection.

2. **MEDIUM — NEW — calibrated concurrency above eight is not actually routable under the default Pearl ceiling**

   Files: `phase3-binary/Sources/macprovider-cli/ProviderStatus.swift:181-187,943-958`; `phase4-coordinator/internal/config/config.go:819-839,1699`; `phase4-coordinator/internal/ws/server.go:6073-6088,6171-6188,6687-6750`

   The provider can calibrate and advertise 16/24/32 slots, but the coordinator still clamps provider capacity to its default ceiling of 8. A calibrated provider therefore appears locally capable of higher concurrency while Pearl continues serving only eight buyer slots.

   The ordinary default fleet remains safely capped at eight; this is a deployment/completeness failure for the new opt-in calibration feature, not unsafe over-admission. The release gate must align the coordinator ceiling with calibrated cohorts and prevent claiming higher live capacity while Pearl remains capped at eight.

3. **MEDIUM — NEW — signed TTFT can describe replay delivery rather than the canonical inference**

   Files: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:6870-6889,6930-6945`; `phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:2401-2418,2465-2477,5438-5481`; `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:965-992`

   If the original streaming waiter disconnects and a duplicate/replay waiter becomes the settlement owner, `ContinuousBatchFirstTokenClock` can mark replay delivery as its first token. Terminal replay may instead fall back to near-zero elapsed time. The resulting receipt remains cryptographically valid and verifier-accepted, but its signed `ttft_ms` no longer represents the actual inference row’s request-accepted-to-first-output interval.

   This can corrupt settlement evidence, SLA metrics, and operator calibration data, although I found no direct token-charge error. Minimal fix: carry the canonical row’s original first-token timestamp/TTFT through duplicate and terminal replay ownership; do not derive TTFT from replay delivery.

4. **LOW — PRE-EXISTING reachability, NEW ragged-prefill expansion — lab harness commands remain executable in release builds**

   Files: `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:43,57-65`; `phase3-binary/Sources/macprovider-cli/MSBThroughputCommand.swift:57-84,1166-1265`

   Hidden MSB commands are registered outside the existing lab compile gate. The new ragged-prefill scenario can load models and allocate paged-KV/GPU resources on a serving installation if an operator or automation invokes it, potentially starving live buyers. It is not remotely buyer-reachable and is not a privacy bypass.

   Minimal fix: place all MSB command registration and implementations behind `DEBUG || MACPROVIDER_LAB_HARNESS`, or enforce an explicit “not while serving” guard.

I found no new billing/refund invariant violation in the marked 429 path, no free-inference path, no retry classifier bypass, no plaintext privacy fallback, and no ragged-prefill cross-row isolation defect.

VERDICT: 0C/0H/3M


