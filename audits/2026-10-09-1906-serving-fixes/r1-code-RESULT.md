
Read-only audit completed. No files changed. `git diff --check` passed; targeted Go tests passed:

- `go test ./internal/buyer ./internal/pool`
- `go test ./internal/router/...`

Swift tests/builds and network access were not used.

## Findings

1. **HIGH — PRE-EXISTING: stale slot snapshots can over-admit providers**

   Location: `phase4-coordinator/internal/buyer/slot_queue.go:184-208`, `server.go:9129`, `relay_blind.go:429,474`

   Queued and relay-blind reservation paths still pass a previously-read `provider.SlotsFree` snapshot into `reserveHead`/`reserveProvider`. The new live check is used only by the direct-selection path.

   Scenario: with one slot, request A consumes it. Request B reserved from an earlier `SlotsFree=1` snapshot is then accepted while live capacity is zero. If the provider returns `error_queue_full`, `MarkForwardedSlotFull` assumes B consumed a seat and increments `SlotsFree`, even though A remains active. The coordinator can dispatch request C beyond `slots_total`, causing repeated queue-full responses and incorrect occupancy/settlement state.

   Minimal fix: make all reservation paths query `RoutableSlotsFree()` under the queue lock, preserving lock ordering, and add a deterministic concurrent reservation/refusal test.

2. **MEDIUM — NEW: SPEC-006 contains contradictory capacity-status requirements**

   Location: `specs/SPEC-006-buyer-api.md:1872-1878`, `:2842-2852`

   The newer section requires capacity exhaustion to return retryable `429`, while the older normative section still requires `503` after queue expiry and for pinned providers with no immediately available slot.

   Scenario: rollout operators, contract validators, or older gateway implementations following the obsolete normative section can reject or emit `503` for the new capacity-shed behavior, producing inconsistent buyer retry and settlement behavior during version skew.

   Minimal fix: update/remove the obsolete `503` requirements and add one canonical status-mapping table covering public, wholesale, pinned, streaming, and queue-expiry paths.

3. **MEDIUM — PRE-EXISTING: `/v1/status` hides full but serving-capable providers**

   Location: `phase5-gateway/internal/router/server.go:1164-1171,1257-1301`; source eligibility comes from `phase4-coordinator/internal/pool/provider.go:701-724`.

   Status aggregation filters on `RoutingEligible`, which is false when `SlotsFree==0`. Thus a provider that is alive and serving-capable but temporarily full is omitted rather than counted as `no_free_slots`.

   Scenario: all providers are full. Chat correctly returns capacity `429`, but `/v1/status` can report no awake provider or omit the model entirely. Buyer dashboards, routing clients, and operators may conclude the model is unavailable rather than saturated.

   Minimal fix: expose and aggregate serving capability separately from free-slot eligibility.

4. **MEDIUM — PRE-EXISTING: calibration can exceed `--max-duration` indefinitely**

   Location: `phase3-binary/Sources/macprovider-cli/AutotuneConcurrencyCalibration.swift:760-803,818-830`; caller deadline at `AutotuneCommand.swift:1041-1043,1350-1352`.

   The redesign retains a fixed 300-second request timeout. The global deadline is checked only after `URLSession.bytes(for:)` returns and streaming begins.

   Scenario: an opt-in calibration target accepts the connection but sends no response headers. `autotune --recommend --max-duration …` can block for up to five minutes, delaying operator rollout or leaving a provider calibration process stuck.

   Minimal fix: derive request/task timeout from the remaining global deadline and race the request against explicit deadline cancellation.

5. **LOW — NEW: closed-loop capacity test does not prove the refusal path executed**

   Location: `phase4-coordinator/internal/buyer/closed_loop_capacity_test.go:100-116,250-259`

   The fake relay records queue-full and backpressure counts, but the test only includes them in failure text; it never asserts either branch occurred.

   Scenario: a regression in queue-full hold, requeue, or slot restoration could pass while the test exercises only ordinary dispatch.

   Minimal fix: inject a deterministic `queue_full`/backpressure response while another request is live, then assert the refusal count, slot restoration, hold release, and final settlement/refund behavior.

## Cleared areas

No additional concrete defects were found in the inspected implementations for:

- coordinator/gateway 429 mapping and no-provider 503 handling;
- receipt TTFT clock, signing, and verifier constraints;
- ragged shared prefill grouping and masks;
- ended-request relay accounting and request-ID reuse;
- concurrency calibration ladder/math and v1 decoding;
- provider depth bound 32 and unchanged coordinator ceiling 8;
- opt-in trace and lab-only hybrid decode controls.

VERDICT: 0C/0H/1M


