# PR #1962 Codex audit round 1

Base origin/main efcb9ab35, head 459523a54. Gate 0 C/H/M met in all three lanes. LOW findings are carried.

=================== code
```text
Reviewed the complete five-file diff. No CRITICAL, HIGH, or MEDIUM correctness findings.

- **LOW — `phase3-binary/Tests/macprovider-cliTests/NativeMTPTupleOfferLogTests.swift:7`: logging behavior is untested.** The formatter test still passes if production logging becomes debug-gated or its call sites disappear. Fix: exercise the existing send test seam and capture stderr with keepalive debugging disabled, covering sent/skipped/send-failed outcomes and successful-send deduplication.

- **INFO — `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:7473`: skipped logging is not deduplicated.** When an offer exists but wire identity remains unavailable, each general `sendStateUpdate(state:reason:)` emits another unconditional line. Send failures likewise log on each retry. This retry placement is **pre-existing**; unconditional visibility is new. Fix if bounded volume is required: deduplicate diagnostics per session/tuple/reason while preserving retries.

Correctness conclusions:

- The session-not-active return preserves the original exit behavior and prevents a false acceptance log.
- Result logging follows successful `CompleteNativeMTPCanary`; rejected completions do not log “recorded.”
- Successful offers are digest-deduplicated. New lines do not fire per heartbeat, capacity-transition update, or 30-second sweep. Accepted offers log per received offer; recorded results log per successful completion.
- Admin and `/poolz` use the same diagnostics type. `Snapshot` and `Resolve` clone it under lock; admin projection does not alias registry memory. Separate requests can naturally observe different moments.
- Each harness owns its configuration, registry, bank, clock, and log buffer. New tests do not directly mutate a registry-owned provider pointer.
- Static Swift logging accesses no actor-instance state.
- Go assertions distinguish the changed behavior from the base. The Swift test requires the new helper but does not establish production stderr behavior.

Validation: four targeted Go tests passed with default test vet checks; the existing Swift test passed using `--skip-build`; gofmt and diff whitespace checks were clean. The targeted race run was interrupted during compilation, so race verification remains unproven. No files were edited or live hosts contacted.

C/H/M/L = 0/0/0/1
VERDICT: PASS
```

=================== security
```text
- **LOW — `phase4-coordinator/internal/ws/native_mtp_canary_integration.go:126,178`: repeated offers produce unsuppressed info logs.** An authenticated provider can repeatedly submit the same valid offer, generating an acceptance line each time; when canaries are disabled, each valid offer generates an ignored line. This can increase log volume and obscure operational signals. **Pre-existing:** rejected offers/results already generate unsuppressed warn logs, so this does not introduce a new flooding capability. **Fix:** log acceptance once per session/tuple and rate-limit identical disabled notices.

Security checks:

- **Operator boundary holds.** Both route registrations (`server.go:2026–2027`) enter `handleAdminProviders`, which checks `authorizedOperator` before dispatching list, detail, or events (`admin_providers.go:63`). That helper accepts only the configured operator key (`server.go:7656`), excluding gateway credentials. Events return event records rather than `adminProviderView`.
- **No additional public exposure.** `adminProviderView` is confined to the admin handlers. The new field adds no buyer-, provider-, or gateway-facing projection. All diagnostic fields—including revisions, hashes, cache namespace, status, reasons, and timestamps—already appear through operator-only `/poolz`, which embeds `pool.Provider`.
- **Coordinator log inputs are constrained.** Offer strings reject control characters; tuple digests require lowercase SHA-256; release ID must match the verified challenge bank. Result outcome/reason come from fixed evaluator constants, not provider reason text. Production logs use JSON encoding. Provider/session identities match existing neighboring logs; the newly logged digest and release ID contain no raw prompt, buyer data, credential, or key material.
- **Provider log injection is constrained.** Actions and skip reasons are literals, generation is numeric, and the tuple digest is locally computed SHA-256. Error text has controls/newlines replaced and length bounded (`CoordinatorClient.swift:1512`). Sanitization does not redact secrets, but the inspected send path does not interpolate authorization headers or payload contents into errors. The same error description was already debug-logged.
- **Recorded-result repetition is bounded.** Completion consumes the in-flight request (`native_mtp_canary_store.go:98`); repeated results cannot repeatedly reach the new recorded-result info line.

Validation: the five existing targeted tests for admin authorization, gateway-token rejection, offer/result info logs, disabled notices, and diagnostic projection **passed** with `GOMAXPROCS=2 go test -p 1 ./internal/ws -run '<five exact test names>' -count=1`. Swift tests were not run because this operator host prohibits full Swift test/build workloads. Existing tests do not establish duplicate-offer log suppression.

No files edited, live hosts contacted, or payloads constructed.

C/H/M/L = 0/0/0/1  
VERDICT: PASS
```

=================== architecture
```text
No CRITICAL, HIGH, or MEDIUM architecture findings in the complete five-file diff.

- **LOW — pre-existing:** `scripts/native_mtp_enablement_rehearsal.py:607` and `scripts/native_mtp_r014_isolated.py:315` detect receipt using the coordinator-log substring `native_mtp_tuple_offer`. The new acceptance message at `phase4-coordinator/internal/ws/native_mtp_canary_integration.go:184` does not contain that substring, so successful acceptance can still produce `tuple_offer_received=false`. **Fix:** add a stable structured event identifier to the acceptance log and align these consumers.
- **LOW:** `phase4-coordinator/internal/ws/native_mtp_canary_integration.go:306` logs results with session identity but without tuple generation/digest or challenge identity. When a session offers successive tuples, an isolated result entry cannot identify which tuple passed or failed. **Fix:** include `target_generation`, `native_mtp_runtime_tuple_sha256`, and `challenge_id`.

Contract assessment: SPEC-031-R033 already requires separate native-MTP state and operator diagnostics. This additive projection does not require a new normative requirement or conformance row; a field-availability note and additional test references would improve documentation. Live-only omission is coherent with SPEC-035-R004 and neighbouring volatile diagnostics. `/poolz` already serializes this diagnostics type. No offer/result wire schemas, golden frames, routing, or trust semantics change.

Info logging is appropriate for accepted offers and recorded outcomes; metrics would complement these identity-bearing events. The provider stderr format follows neighbouring `event=… action=…` lines, and error text uses the existing bounded sanitization.

Validation: all three new Go visibility tests and both existing connected/offline admin-view tests passed. `git diff --check` passed. Swift tests were not run because of the operator-host build boundary. No files were edited or live hosts contacted.

C/H/M/L = 0/0/0/2
VERDICT: PASS
```
