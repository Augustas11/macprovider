# Build 1 integration acceptance evidence

Status: the original Go service journey passed its targeted race and vet checks.
The added parsed CLI bootstrap-to-service composition passed in Swift25, including
actual WS admission, receipt, exact ledger and teardown checks. Broader combined
verification remains lead-owned. Fixture evidence is never physical MLX
qualification, TLS qualification or production authority.

## Storage correction discovered

The production money path and the existing cross-service harness persist to SQLite,
not PostgreSQL. `phase4-coordinator/cmd/coordinator/main.go` opens auth/request-log
stores with `OpenStoreWithManualWALCheckpoint(cfg.Storage.DBPath)` and constructs
`NewSQLiteModelAdmissionStore(reqLogStore.DB())`. Billing uses that SQLite DB.
`phase5-gateway/cmd/gateway/main.go` opens `sqlite.Open(ctx,cfg.Storage.DBPath)` and
`sqlite.OpenReadOnly`. `test/integration/harness_test.go` launches real service
binaries with separate disposable coordinator.db and gateway.db files. PostgreSQL
configuration elsewhere serves onboarding/stats/emission. The storage correction was approved independently (review digest
`2bf83b9cc55140c634aec51a08703967243af7db33913967b750b4dd1460adb6`),
without reducing persisted receipt, snapshot, exact accounting or real transport
acceptance.

## Physical acceptance feasibility

No model was loaded or downloaded and no installed provider was mutated by this
lane. B1-T10 remains unproven. `AutotuneHMACSecretStore.defaultPath` in
`phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift` resolves through
`FileManager.default.homeDirectoryForCurrentUser` to the operator config tree.
`AutotuneCommand.swift` calls `loadOrCreate` with this default at multiple entry
points. Changing a subprocess HOME string alone is not proof of isolation for
Foundation home lookup. The executable physical harness must first prove explicit
HMAC, identity, configuration, artifact, discovery and runtime roots and loopback
service targets, then establish qualified real artifact/feed/reference inputs.
There is currently no physical execution evidence in this document.

## Implemented acceptance fixture

- `test/integration/build1_artifact_journey_test.go`: fresh test-signed candidate,
  artifact and rate bodies; independent fixture Tier2 signer; explicit effective
  candidate rates; real services, provider-token auth, provider-signed offer and
  coordinator-owned promotion. No admission/probe/snapshot/receipt/credit is
  preseeded. Only disposable account/token/public admission credential setup is
  seeded. It does not establish CLI bootstrap or provider identity enrollment.
- `test/integration/build1_transport_test.go`: X25519/HKDF/AES-GCM fixture client
  exercises actual coordinator WS probe and actual buyer request. Decrypts the
  real request, checks exact model, returns a canned completion and signed v4
  receipt. Fixture crypto keys stay in process memory.
- `test/integration/harness_test.go`: opt-in wiring reuses existing opaque service
  binaries, temp SQLite DBs, loopback ports and process lifecycle. Existing HTTP
  provider fixtures retain their behavior.

Assertions cover signed-field substitution rejection without an admission record,
actual single wire probe, `settlement_capable` readback, immutable six-field artifact
binding (separate from Tier2 digest), explicit model/rate/session/event provenance,
verified persisted receipt, exact buyer quota debit and provider credit, signed-offer
replay deduplication, and real coordinator restart with byte-identical snapshot,
receipt API readback, unchanged accounting and refusal to route an old session.
The default rate is deliberately double the explicit candidate rate, so fallback
billing cannot accidentally produce the expected result.

## Verification

From `test/integration`:

```
go test -race -run '^(TestBuild1ArtifactAdmissionSettlesThroughRealServices|TestJourneyBuyerEnforceIsolatedCandidate|TestJourneyBuyerPaidPathIsolatedCandidate)$' -count=1 -v
```

Final result (2026-09-10): exit 0, 3 selected / 3 passed, 0 skipped, 14.548s.
Build1 journey 4.27s; existing enforce journey 3.94s; existing paid-path journey
0.82s. The final Build1 journey has uncached prompt usage, exact gross 16 /
provider 14 credits and buyer debit 20 tokens. Candidate cache rate 250000 is
independently bound in the immutable snapshot; the default cache rate is 1000000.
The `-race` flag instruments the Go fixture process; TestMain builds normal real
service binaries. Coordinator/gateway race tests remain their own surface gates.

`go vet ./...`: exit 0. Full integration (including Swift fixture builds), full
service gates and cumulative audits are lead-owned and are not claimed here.

The real journey exposed two coordinator integration defects, fixed by the
coordinator lane: candidate catalog key incorrectly compared with Tier2's runtime
model key, and unmarked live-provider lookup unable to find an offer submitted
without reconnecting. The positive path and restart checks passed after those
corrections. Fixture construction failures (incomplete artifact-feed coverage,
token auth disabled, missing encrypted WS transport) were corrected before the
accepted run; a stale-session expectation was corrected from 503 to the actual
404 model-not-found contract with inference/settlement both false.

## Remaining evidence boundaries

B1-T07/T08 full authority/concurrency matrices and B1-T09 per-field tampering,
receipt incompatibility/cap failures belong to coordinator/billing tests. This
fixture proves real transport and persistence composition; it does not replace
those matrices. Payout/epoch settlement remains disabled: a verified receipt and
credited ledger row do not imply a payout was executed.

B1-T10/B1-T11 actual MLX and CLI bootstrap remain unproven here. A physical run
needs an exact qualified cached target, freshly authenticated artifact/candidate/
rate inputs, independently justified matching Tier2 reference material and
explicit isolated config/identity/HMAC/transaction/runtime roots. No generated
fixture signature or fixture hash is physical reference evidence. No actual
model cache contents were loaded or downloaded in this lane.

A trial nested OpenAI `prompt_tokens_details.cached_tokens` fixture did not prove
cache accounting (exit 1 on the expected-discount assertion): this coordinator's
cache contract requires `usage.cached_prompt_tokens` and a real sticky HIT;
single-provider routing does not produce that HIT. That unsupported trial was
removed. The final test does not claim cached-token discount coverage; dedicated
coordinator/billing cache and recovery tests own that claim.

Sanitized final evidence: caller request `b1111111-1111-4111-8111-111111111111`,
fixture model `mlx-community/Llama-3.2-3B-Instruct-4bit`, snapshot hash algorithm
`macprovider.snapshot-manifest.v1`, admission `settlement_capable`, receipt v4
`valid`/`verified`/closed, one credit row before and after coordinator restart,
20 settled buyer quota tokens, 16 gross credits, 14 provider credits. Test-scoped
provider/session/request/receipt identities are generated anew each run. Raw logs
remain temporary; no private keys, operator credentials or raw production data
are included here.

## B1-T11 fixture composition follow-up

The new test-only `Build1FixtureProvider.swift` compiles a standalone Swift
loopback provider executable that directly owns its listener, accepts the real
candidate runner's serve/artifact arguments, and streams delayed SSE content.
Its sibling configuration controls readiness delay, per-chunk delay and count.
It records process arguments, readiness, chat/chunk completion and SIGTERM under
a test-owned root; no environment or credential contents are logged. A fresh
XCTest child can reopen that compiled fixture without recompiling or carrying
in-memory state. This is deterministic transport/timing evidence, not MLX.

Standalone helper module compilation and embedded executable compilation passed.
A local smoke passed readiness, a 14 KB POST body, 100 SSE chunks in 0.118 seconds,
terminal usage/DONE, SIGTERM observation, child exit and closed port. The response
omits provider-reported generation timing so Stage1 calculates throughput from
actual streamed wall time. The CLI owner subsequently reported seven real
prepared-recommendation scenarios passing through this helper and the actual
Stage1 prober (Swift10 owner suite: 17 tests passed); its durable owner report is
the authority for those owner assertions, rather than this standalone smoke.

Parsed full command composition is still pending. Default-preserving shared
command execution and separate-process fixture details were approved in
`command-composition-testability-addendum-r2.md` (SHA-256
`5e68de58a6835e621f18b06a3091590c5fa56a00dbdbd57d27f796102f123428`). The journey
must first execute parsed catalog-economics to obtain each exact reserved action,
then execute prepare/recommendation from that output, rediscover after process
restart, read the original result bytes, adopt, and compose signed offer/status/
retry with local authentication. No transaction or eligible result may be seeded.
The independent gate and shared production command edits remain lead-owned.
The typed context and signed-input fixture loader are implemented. Shipping
baked artifact inputs remain nil; fixture authority is explicitly injected and
passes the real signature, release and artifact binding validators.

Baseline adoption test bypass found while composing the fixture:
`ModelsAdoptRecommendationCommand.validateSignedAuthority` previously contained
a DEBUG-only early return for XCTest environment/process detection. The lead
removed that bypass. Parsed production and fixture execution now use the real
signed authority validator. Existing rollback tests were migrated to disposable
signed inputs and verified bytes; their hand-authored recommendations are unit
rollback fixtures and are not counted as measured bootstrap evidence.

Joint Swift14 compiled the new subprocess bootstrap, input loader, context,
retention, owner and adoption tests. The lead-owned run executed 98 tests with
10 failures (5 unexpected); it is not a passing acceptance gate. The three
signed-input tests passed, including default-nil authority and wrong-signer /
cross-release rejection. The bootstrap stopped before preparation because its
explicit socket override made protocol-2 local transaction context unavailable.
That fixture path now lives in its isolated mode-0600 config, with no projection
socket override. The adoption success unit still failed final config verification,
while post-return comparisons of all 13 fields and `ensureConfigParity` passed;
the lead is investigating the in-command path. Context failures belong to the
lead's secure filesystem alias correction. These changes require a new run.

The bootstrap test starts with no model/session/admission/recommendation or
transaction. Every reservation must come from parsed catalog-economics, and each
command runs in a fresh XCTest subprocess with only PATH/HOME/TMPDIR. Its fixture
config is `home/.config/macprovider/config.yaml`; explicit resolver injection
preserves the captured durable root and no HF/MACPROVIDER environment override
is used. Original result bytes, restart discovery and actual Stage1 wall-time
measurement assertions are implemented but have not yet been reached by a
passing complete run. Signed offer/status/retry and local-service settlement
composition remain an explicit unfinished extension, beyond the separate Go
real-service journey above.

Swift17 follow-up: the lead-owned targeted run compiled the new Swift service
bridge and executed 117 tests with 11 failures (8 unexpected). The migrated
`ModelsSubcommandTests` passed all 46 tests, including signed-authority negatives,
original adoption success and rollback; the root-owned journal URL parent check
fix removed the prior finalization failure. The bootstrap still stopped at
projection because the root-owned context loader compared an unnormalized HOME
alias; its context suite reproduced that failure. The new service join has not
run successfully and is not acceptance evidence yet.

The test-only Go bridge imports the exact Swift fixture's signed candidate,
artifact, demand and rate bytes, generates independently signed deterministic
Tier2 fixture material, and starts actual coordinator/gateway binaries without a
provider session. It waits for parsed CLI offer/status, connects the actual WS
fixture, then waits for parsed retry before checking buyer traffic, receipt,
exact ledger and immutable snapshot/restart. It seeds only auth/bootstrap inputs,
never an offer, model admission, recommendation, probe, route snapshot, receipt or
ledger row. Temporary credentials stay in mode-0600 files under the private
fixture root. Shipping factories remain the default; command fixture factories
use isolated protected credential stores. The companion test skips when it is
not selected with its private fixture manifest.

The new Go bridge and default-preserving harness hooks compiled with
`go test -c -o /tmp/build1-cli-integration.test` (exit 0). The existing
`go test -run '^TestBuild1ArtifactAdmissionSettlesThroughRealServices$' -count=1`
regression passed (1 test, 7.690 seconds, no skip) after the hook additions.

Swift18 narrowed the remaining bootstrap failure after successful parsed prepare,
separate-process discovery/status, actual measured recommendation and exact
committed result readback: the fixture's UNIX socket path exceeded Darwin's
length limit. The entire mode-0700 fixture root now uses the shorter
`/private/tmp/b1-<UUID>` namespace, with all config/model/credential/runtime paths
remaining inside it. That run executed 32 tests with 2 failures (1 unexpected);
it did not reach signed adoption or the service bridge. The remaining context
assertion compared equivalent macOS URL aliases and was corrected by its owner.

Swift19 reached successful original-byte adoption, then stopped during creation
of disposable protected-file credentials: `/private/tmp` normalizes to `/tmp`,
whose symlink/world-writable ancestry is rejected by the existing custody policy.
No Keychain or operator identity was used; the protected store maps its I/O error
to the shared key-store error type. The fixture now uses a short
`NSTemporaryDirectory/b1-<12 UUID chars>` root (mode 0700), preserving the supported
private `/var/folders` ancestry. A read-only Foundation check measured the resolved
socket path at 73 UTF-8 bytes, and the test asserts fewer than 104 bytes before
its workflow. Production custody policy was not changed. Swift19 executed 10
tests with 2 failures (1 unexpected); the other failure was an owner-corrected
URL directory-hint assertion. Bridge service execution remains unproven pending
the corrected fixture run.

Verification scheduling correction: the complete Go integration suite is not
independent of Swift source changes. `swift_relay_provider_test.go` calls
`swift build --product macprovider-cli` and `swift build --show-bin-path` from
`buildSwiftRelayBinary`; its full-suite gate requires a coordinated Swift source
freeze. The lead's concurrent full Go race attempt failed after 44.740 seconds
while those fixtures saw incomplete retention edits. It is an overall failed
run, not evidence of a new Go behavioral regression or a passing integration
gate. The targeted Build1 Go regression above does not invoke that Swift helper.

Fixture lifecycle hardening: the new Go service bridge runs inside a dedicated
XCTest process group. A parent-lifetime guard terminates that owned group on
parent death; normal shutdown signals the companion, waits for service cleanup,
and has bounded TERM/KILL fallback against the confirmed child group. This
covers the Go wrapper, test binary and service descendants. The helper preserves
the same sanitized subprocess environment and private credential roots.

Swift20 compiled the complete bootstrap bridge and executed 63 targeted tests
with 3 failures (2 unexpected) in 250.325 seconds, exit 1
(`/tmp/build1-joint-swift20.log`). The bootstrap completed prepare, restarted
discovery, measured recommendation, exact result readback, original-byte adoption
and real coordinator/gateway startup. Its first parsed offer then rejected the
HTTP loopback coordinator URL. The other two failures belong to the retention
and transaction-owner lanes. This is not a passing composed journey.

The approved fixture context now supplies a logical HTTPS origin to parsed
commands and maps only that exact origin through the existing admission-client
initializer to the observed HTTP loopback server. The fixture validates host
`127.0.0.1`, exact port, empty path, and absent userinfo/query/fragment; alternate
paths and hosts are rejected. Offer, status and retry share that same client
factory and endpoint. No production URL validation, environment override or
trust check changed. Actual transport is local HTTP, so this test supplies no
TLS qualification evidence. Validation of this correction is pending the next
coordinated Swift run.

Swift21 (`swift test --filter Build1CommandBootstrapTests`) compiled in 31.21s
and exited 1: 3 tests, 1 failure (1 unexpected), 31.279s
(`/tmp/build1-bootstrap-swift21.log`). Two selected tests are subprocess entry
helpers, not independent journeys. Parsed signed offer and pending status passed.
The WS fixture then failed readiness because a durable admission identity already
existed and the old fake provider sent no challenge-bound identity signature.
The original Go journey had connected before establishing that identity.

The approved test-only companion now forwards its public initial/challenge frames
to the Swift bridge, which loads the same owned protected-file identity, validates
provider and coordinator key hint, and signs the real protocol transcript/attempt
tuple. Only public frames and signature response files cross the process boundary;
no private key is exported. The coordinator still validates the actual signature.
A focused regression rejects wrong provider/key and checks signature failure for
a different auth attempt or session ephemeral key. The constructor publication
fence callback added by the CLI owner is also passed through the real prepared
fixture runner. These corrections await the next coordinated compile/run.

Swift22 compiled in 35.13 seconds, and the focused identity proof negative/binding
regression passed. The composed journey was interrupted by the lead after the
main XCTest process became stuck inside an unconditional Foundation
`Process.waitUntilExit()` in `runCommand`, reached from the parsed offer stage.
A process sample showed the blocking frame despite no remaining child processes.
The lead terminated only that owned XCTest process; the run exited 1 without a
completed suite result. This is interrupted evidence, neither a test pass nor a
completed assertion failure (`/tmp/build1-joint-swift22.log`, sample
`/tmp/build1-swift22-sample.txt`).

The fixture now polls completion with bounded deadlines and removes the redundant
unbounded wait. If the original command deadline expires it reports timeout even
when the child later exits zero. Termination status is read only after Foundation
reports completion. The bridge shutdown and Go child wrapper use bounded polling
as well. The correction is pending validation; no command success is inferred
from missing process-table entries alone.

Swift24 ran `NSUnbufferedIO=YES swift test --skip-build --filter
Build1CommandBootstrapTests` against the compiled Swift23 snapshot with a
180-second outer deadline. It completed normally with exit 1: 4 tests, 1 assertion
failure (0 unexpected), 15.253 seconds (`/tmp/build1-bootstrap-swift24.log`).
Both helpers and the identity-proof regression passed. The composed journey
passed parsed signed offer, pending status, actual signed WS identity proof,
parsed retry to `settlement_capable`, status readback, buyer request, verified
closed receipt, one exact ledger row (20 buyer tokens, 16 gross credits,
14 provider credits), six-field immutable snapshot, real coordinator restart
and receipt readback, and clean bridge exit. The sole failure was the final
SIGTERM-specific `terminated` trace marker assertion. The suite is not claimed
passed.

The fixture can also terminate through its parent guard or the real runner's
bounded SIGKILL escalation; neither emits the SIGTERM marker. This run did not
retain which alternative occurred. Teardown acceptance now directly asserts
every recorded fixture PID and its process group are absent (`ESRCH`) and the
candidate listener is closed, with public event names retained as diagnostics.
It does not infer graceful termination from a missing marker. This stronger
observable teardown check awaits the next compiled fixture run.

Cleanup after interrupted Swift22: one remaining mode-0700 fixture directory
was identified by its self-matching public manifest, expected catalog key and
recorded creation timestamp. Every recorded fixture PID and process group was
absent before that exact inactive root was removed. No credential values were
read or emitted; no operator root was accessed. Completed Swift24 removed its
owned fixture root through the normal test cleanup.

## Parsed command composition: first complete passing evidence

Swift25 compiled the current fixture snapshot in 40.13 seconds. Its
`Build1CommandBootstrapTests` class passed all 4 selected tests with 0 failures
in 14.977 seconds: one complete composed journey (14.974s), one identity-proof
negative/binding regression (0.002s), and two subprocess entry helpers. Log:
`/tmp/build1-joint-swift25.log`. This is a class result; the broader Swift25 suite
was still running when this evidence was recorded.

The passing journey begins without a cached artifact, prepared transaction,
recommendation, provider session or admission. Parsed `catalog-economics` emits
the exact action UUID/generation; parsed prepare downloads only the deterministic
fixture bytes and publishes the verified durable artifact. Separate processes
discover it, create and execute a measured recommendation through the real engine
and Stage1 prober, read back its exact committed result, and adopt the original
bytes through the shared signed-authority validator and control socket. The
fixture runtime loader supplies deterministic model behavior.

Parsed offer and status then use protected fixture credentials and the same
signed artifact/candidate/rate inputs against real coordinator/gateway binaries.
The WS companion proves the existing admission identity with a real signed
challenge, parsed retry performs the actual encrypted WS probe, and status reads
`settlement_capable`. The buyer request produces a verified closed receipt and
exact persisted accounting: one ledger row, 20 buyer tokens, 16 gross credits,
14 provider credits. All six artifact binding fields and captured candidate rates
match the immutable snapshot; the independent Tier2 digest stays distinct. A real
coordinator restart preserves the snapshot bytes, accounting and receipt readback.
Every recorded local fixture PID and process group is absent and the candidate
listener is closed after completion; no graceful-signal claim is made.

This proves deterministic command/service composition under the approved typed
fixture inputs. The provider responses, model bytes and Tier2 reference remain
fixtures; the transport is loopback HTTP plus actual encrypted WS. It does not
qualify physical MLX, real model quality, calibrated Tier2 references, production
feed availability or TLS. Cached-token discount settlement remains outside this
real-service fixture. Subsequent production binding changes require a fresh
final gate against the final source snapshot.

## S2-T11: real paid-route rejection before status revocation

Approved authority: `promotion-authority-addendum-r3.md`, SHA-256
`6a5bd750addb0180f22a4cf16cc33862a2324a3010cfae66c794c568bfd5d0c4`;
the lead confirmed independent 0C/H/M/L review and SPEC-047 update before code.
This lane changes only the Build1 integration fixture files.

`TestBuild1PaidRouteRejectsClosingBeforeStatusRevocation` in
`test/integration/build1_closing_route_test.go` starts real coordinator/gateway
binaries with SQLite, genuinely signed fixture authority and one WS provider.
An actual offer/probe produces the persisted positive admission. The test calls
real `/admin/blacklist`, whose production effects are drain delivery, reversible
`MarkState(draining)`, and monotonic closing publication before its existing
one-minute hard-close schedule. It does not change canary or other exclusions.
A fixture-only drain barrier withholds the ready frame until that HTTP call has
returned; the test observes draining, releases the real ready state update, then
observes the same assigned session ready again. No status, retry, model-list or
route predicate runs between closing and the tested buyer request.

Before that first buyer HTTP call, the test checks `routing_eligible=true`, zero
canary failures, unchanged provider/session/model/hash/receipt/catalog/auth/slot
and exclusion fields, unchanged byte-identical positive `authority_json`, matching
assigned session and both authority/probe leases valid for more than ten further
seconds. Signed fixture inputs/config are not reloaded or mutated. The same exact
ready session remains observable after rejection. Thus generic draining, canary
exclusion, stale lease, replacement or eventual registry cleanup cannot explain
the denial. The actual scheduled timer is not replaced or paused; the assertions
finish before its one-minute deadline while the live session remains present.
This black-box test does not substitute for package-local held-timer coverage.

The actual gateway-to-buyer request returns the existing `503`
`byom_non_settlement_unavailable` error with `inference_ran=false` and
`settlement_ran=false`. The fixture receives no paid frame and no additional
unmetered/probe frame; only the original admission probe exists. No route
snapshot, receipt verdict, provider ledger credit or buyer debit is created.
The normal case appends revocation. The second fresh fixture installs a SQLite
trigger rejecting only INSERTs with `next_state='revoked'`; all other admission
operations are unchanged. Its positive event remains latest throughout, yet the
paid route still refuses. No production availability callback is mocked.

Final verification from `test/integration`:

```
go test -race -run '^(TestBuild1PaidRouteRejectsClosingBeforeStatusRevocation|TestBuild1ArtifactAdmissionSettlesThroughRealServices)$' -count=1 -v
```

Exit 0, 2 parent tests passed plus both closing-route subcases, 0 failed, 0 skipped,
9.564 seconds (`/tmp/build1-closing-route-final2-race.log`). Positive journey
3.85s; closing matrix 1.10s (0.55s each). The positive journey still settles exact
16 gross / 14 provider credits and survives restart. `go vet ./...` in integration
exited 0 before the final assertion-only tightening; `git diff --check` passed.
The race detector instruments the Go harness; its real service binaries are normal
builds. No Swift build/test or physical MLX execution was part of this gate.

Earlier bounded runs: the first race run failed both subcases after all isolation
preconditions because the test expected 404 instead of the existing 503 route
error (7.192s, `/tmp/build1-closing-route-race1.log`). A launch from the repository
root selected no tests because that directory has no Go module
(`/tmp/build1-closing-route-race2.log`); it is not a test result. Corrected targeted
run passed both subcases in 6.324s; the first combined positive/negative run passed
in 8.641s. The final run above adds the explicit no-additional-probe-frame check.

S2-T11 coverage boundary:

| Required surface | Evidence / owner |
| --- | --- |
| Real HTTP paid request before any status revocation, positive SQLite event, actual scheduled closing and ready revival | Passed here, both fresh subcases |
| Route denial when only revocation persistence fails | Passed here via real SQLite revocation-only INSERT trigger |
| No-drift actual selection, immutable snapshot, exact receipt/accounting/restart | Passed existing Build1 real-service journey in the same final gate |
| Direct resolver, binding/require-binding, default/pinned/queued selection, memory and SQLite combinations | WS/buyer owner matrix; not claimed by this narrow cross-service test |
| Held graceful/operator/trust/buyer-failure close producers and eventual cleanup barriers | WS/buyer owner matrix; actual blacklist schedule only is exercised here |
| Missing read/close wiring and exact callback tuple/absence/closed/closing/available cases | WS/buyer owner matrix; not run by this lane |
| Replacement session/old timer isolation, separate replacement admission, stale CAS | WS/buyer owner matrix; not run by this lane |
| Short callback lock released before downstream routing/persistence; guard-held view avoids recursive getter | WS/buyer owner matrix; not run by this lane |
| Full coordinator/gateway/Go-integration gates and cumulative independent audits | Lead-owned; not claimed by this targeted gate |

The complete S2-T11 matrix remains dependent on the other owner’s fresh evidence;
this passing black-box regression alone does not close that full matrix.

## S2 T03/T08/T09 final readback race slice

From phase4-coordinator: `go test -race ./internal/ws -run '^(TestPromotionCASWinnerReadback|TestAdmissionReadbackAfterPromotionRace|TestAdmissionGuardCompatibilityAndReopen)$' -count=1 -v`. Exit0,19.830s,3parent tests/59leaf cases (24/28/7),zero failures/skips/race reports. Log `/tmp/build1-readback-race3.log` SHA256 `255e14369a136c29f9fe5b5866eb2b3596c8ade8a5ec1f4f68133197f771c9fd`. Sole new source `internal/ws/model_admission_readback_race_test.go` SHA256 `146e275234370f40b670b4a62c427320909612b3cb8159a423ed91bdeee2e87e`; gofmt/diffcheckpassed.

T03 uses actual authenticated HTTP offer/retry and real WS probes, both stores/promotion boundaries, withdrawal/fresh-tuple reoffer/revocation winners, with no leaked positive replay key. T08 includes postcommit/current observation plus offer/retry replay/status, CAS winner and CAS-to-store-error, unchanged idempotent reservation bytes, throttled retry without store writes. T09 checks exact two positive evidence/CAS-chain transitions, replay after withdrawal, unsupported guard remaining pending, unchanged legacy settlement, and actual SQLite close/reopen without live session revoking authority.

Catalog evidence is the shared WS fixture. This does not prove signed-loader drift, all actual teardown producers, paid-route refusal, deployed services or MLX inference; those retain separate evidence/gates. Parent/leaf counts are not separate physical journeys.

## Consolidated transport/readback rerun

The final frozen integration-owned selection combined the 380 promotion leaves,
228 replay/status leaves, 38 throttled-retry leaves and 59 direct CAS/readback
leaves. Running that selection under `go test -race` completed successfully in
212.263 seconds. The log contains no failure, skip or data-race marker and has
SHA-256 `0cc679d57e9508dc4df6fca42af06059cfef07693017325f97e6f854240922a3`.
The count is 705 logical leaves as defined by the test matrix; nested `=== RUN`
lines are not reported as independent journeys. This rerun does not close the
separate T06/T10/T11 gaps identified by independent test-mapping review.
