# S2 HTTP teardown test feasibility

Scope: read-only feasibility of the proposed new process-integration test for
HTTP 530/redirect teardown, against approved
`promotion-authority-addendum-r3.md` S2-T10/T11. No runtime or test source was
changed. No test was run; no producer-coverage claim is made.

## Observed implementation boundaries

- `phase4-coordinator/internal/buyer/model_admission_authority.go`,
  `resolveModelAdmissionAuthority`, requires `p.IsWSTunneled()` in its
  `session_or_feed_unavailable` predicate. Artifact-positive authority cannot be
  established for the HTTP-forwarding route by the existing resolver.
- `phase4-coordinator/internal/buyer/server.go`, `handleChatCompletions`, selects
  the WS dispatch path using `state.provider.IsWSTunneled()` (around line 2496).
  The non-WS HTTP dispatch constructs `EndpointURL + /v1/chat/completions` and
  executes `providerhttp.Client.Do`; its non-200 branch passes the actual
  `resp.StatusCode` to `handleProviderFailure` (around lines 3150/3254).
  The streaming HTTP equivalent passes `resp.StatusCode` around line 4192.
- The same file's `handleProviderFailure` (around line 8488) marks the exact
  provider session unavailable and calls `closeProviderConn` for status 530 or
  any 300–399 status. Its WS error call sites use 502/504; the WS relay wire
  messages do not provide an arbitrary HTTP 530/redirect status channel.
- `closeProviderConn` invokes the constructor-wired close callback when present.
  The production callback is
  `ws.Server.CloseModelAdmissionTransport` in
  `phase4-coordinator/internal/ws/model_admission_transport.go`. It resolves the
  exact stored session, then `providerSession.closeTransport` publishes
  `beginClosing` before calling that socket's `Close` immediately.
- `test/integration/harness_test.go` runs separately built coordinator binaries
  through `TestMain`/`buildBinary`. Its fake Build 1 provider and
  `build1_artifact_journey_test.go:respondBuild1Frame` exercise encrypted WS
  inference frames. The separate test process cannot invoke the private buyer
  producer or interpose on the coordinator's accepted socket `Close` to retain
  registry/map membership after closing publication.
- `build1_closing_route_test.go` uses the real blacklist's one-minute graceful
  close schedule, allowing readiness restoration and selection checks before
  cleanup. That existing method does not test the buyer HTTP failure producer,
  whose close is immediate; copying that assertion strategy would substitute a
  different producer.

Line numbers identify the inspected shared worktree and may shift during the
ongoing implementation. Symbols and branch predicates are the stable anchors.

## Consequence

A process test that obtains artifact-positive admission, then expects that same
unchanged provider's ordinary buyer dispatch to execute the HTTP 530/redirect
branch, is unreachable under the current transport contract. Changing the
provider to HTTP forwarding, weakening `IsWSTunneled`, or replacing the actual
producer with a callback invocation would change the premise or weaken the
required evidence. Likewise socket failure after dispatch is not proof that
selection rejected a closing artifact session before status revocation.

## Feasible compositions for lead reconciliation

1. **Real producer with real WS, in process.** Use a test in package `buyer` so
   it can invoke actual `handleProviderFailure(provider, status)` for 530 and
   redirect statuses, as S2-T10 explicitly requests. Construct a real WS server
   and actual registered session; wire `CloseModelAdmissionTransport` and
   `ModelAdmissionSessionAvailable`. Use a test-owned accepted `net.Conn`
   wrapper whose `Close` blocks before closing the underlying socket. This can
   observe that real WS closing publication has happened while retaining the
   live map/registry entry. A constructor callback adapter may place a barrier
   before forwarding to the real WS close function, permitting a real registry
   ready update after the producer's unavailable mark. It must always call the
   real close implementation; it cannot return synthetic success. Then check
   fresh artifact resolver/paid selection before status, including failed
   revocation persistence. A real handshake and signed authority fixture are
   still required; copying or sharing test-only fixture code may be necessary.
   This proves the actual producer and real close ordering, but does not claim
   ordinary artifact HTTP dispatch can generate status 530.
2. **Separate reachable HTTP dispatch compatibility test.** A registered legacy
   HTTP-forwarding provider can return actual 530/redirect responses to drive
   the real public buyer handler and its close callback. This establishes that
   HTTP dispatch reaches the producer and retains legacy behavior. It cannot
   independently substitute for the artifact-positive, cleanup-delayed selection
   assertion in option 1.

Neither option is implemented here. The first needs a different test ownership
scope and in-process fixture composition; any required runtime seam must be
reviewed by its owner before changes. If the lead treats this reconciliation as
materially changing the approved T10 test strategy, reopen the independent plan
gate. Do not count callback-only, legacy-only, or post-cleanup observations as
completion of the full artifact producer/selection obligation.
