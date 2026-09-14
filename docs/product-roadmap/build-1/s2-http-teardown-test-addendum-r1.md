# S2 HTTP teardown test composition addendum R1

Status: AUTHOR proposal; no implementation approval claimed. Supplements approved promotion-authority-addendum-r3.md (SHA-256 6a5bd750addb0180f22a4cf16cc33862a2324a3010cfae66c794c568bfd5d0c4). Runtime correction, primary MLX admission scope, economics and the full T11 contract remain unchanged.

## Evidence and bounded correction

`internal/buyer/server.go:8488` invokes terminal `closeProviderConn` after HTTP 530 or a 3xx result. Real HTTP forwarding calls this method; WS inference errors do not expose an HTTP response status to that branch. `internal/buyer/model_admission_authority.go` requires `p.IsWSTunneled()` for primary artifact authority. Therefore an artifact-positive provider cannot simultaneously satisfy its authority contract and reach the HTTP-forwarding 530/redirect branch without fabricating incompatible preconditions. See `s2-http-teardown-test-feasibility.md` for the concrete call-site inventory.

Replace only the T10 requirement that all properties share one HTTP/artifact fixture with two independently checked compositions joined by the exact production `CloseModelAdmissionTransport`/`ModelAdmissionSessionAvailable` state. The buyer failure test must run the actual public buyer handler, actual upstream status branch and real WS-owned close callback. It must not call a mock close function as its final authority proof. Existing artifact tests must continue exercising real buyer selection before status revocation; a transport-only proof cannot replace them.

## Composition A: real HTTP producer to real WS publication

A new external `ws_test` test may use a test-only exported fixture from an internal `ws` `_test.go` file to obtain a registry, real stored `providerSession`, and actual WS Server. The fixture uses a recording `net.Conn`; no exported production API, HTTP flag or runtime hook is added. The registry provider uses the existing legacy HTTP-forwarding path with a local `httptest.Server` returning separately HTTP 530 and HTTP 302. Billing/artifact promotion is unnecessary and must not be manufactured for this composition.

Construct the actual buyer Server with its normal HTTP client and `WithModelAdmissionTransport`. Its close callback is a test wrapper around the actual WS method, solely to install a deterministic ready-update barrier: assert the exact live registry state was marked unavailable by `handleProviderFailure`, then call the real registry state updater to restore ready before invoking `wsServer.CloseModelAdmissionTransport`. Before invoking that method assert the same stored WS session remains available. The read callback is the actual `wsServer.ModelAdmissionSessionAvailable`.

For both upstream statuses assert:

1. The public request reached the intended upstream exactly once; redirect destination is never contacted. The buyer result is a terminal failure, with no paid success/receipt/settlement claimed.
2. The constructor close wrapper receives the exact provider ID, assigned ID and expected terminal reason exactly once. The original unavailable mark is observed before the forced ready update.
3. The real WS close method publishes closing before the recording socket's `Close` callback. At the recording close boundary the registry is still ready, the exact session remains stored, and `ModelAdmissionSessionAvailable` is false. No later status request or disconnect cleanup is needed to produce the assertion.
4. A subsequent real registry ready update cannot restore availability. No replacement session is substituted. Repeated/old-session close isolation remains covered by the approved T10 tests.
5. A negative composition with missing either callback refuses `ModelAdmissionAuthorityReady`; no fixture may claim enabled artifact authority from a missing close/read half. This does not change legacy HTTP eligibility.

The recording socket close callback must also demonstrate that the WS session publication pin is released before socket IO. It may use an exported test-only assertion/helper; test exports are not runtime API.

## Composition B: real closing publication to artifact route refusal

Retain T11 unchanged: persist genuine signed primary-artifact positive evidence, publish closing through an actual WS producer with cleanup/grace paused, retain ready registry/session identity and all other eligibility fields, then invoke real paid selection/direct binding before any `/models/status` revocation. Cover revocation success and injected revocation failure, default/pinned/queued paths, missing wiring, readiness revival and replacement isolation. In the fault case the positive historical event must remain unchanged while selection refuses; rejection therefore demonstrably depends on the WS read callback, not successful historical mutation.

Existing actual-service `TestBuild1PaidRouteRejectsClosingBeforeStatusRevocation` supplies the blacklist-to-paid-HTTP portion, including a SQLite revoked-INSERT failure. It does not by itself satisfy the remaining T11 path matrix. The author must map all remaining cases explicitly before claiming completion.

## Acceptance and limitations

Both compositions must pass under `-race` with selected tests and leaf counts recorded. Every asserted transition must be driven by real production methods; wrappers only expose barriers/observations. No sleeps substitute for ready/closing/socket-close ordering. No new dependencies, economic activation, artifact-kind expansion, authority relaxation, public API or production behavior change is allowed.

The intentionally absent claim is that a single provider request is simultaneously a paid primary-artifact WS inference and an HTTP-forwarded 530/redirect response. Those routing preconditions are incompatible. Instead the shared production WS owner gives the compositional proof: the reachable HTTP producer publishes its monotonic closing state, and all artifact consumers reject that same state independently of historical revocation. Independent Astra review of this exact addendum is required before authoring the new producer composition.
