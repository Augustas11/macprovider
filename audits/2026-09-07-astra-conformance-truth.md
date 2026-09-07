# SPEC-041/045/046/047 Conformance Truth Audit

Date: 2026-09-07. Audited base: `7d1ce3c4c82651064832455c19675ad30c669eca`
(`origin/main` after fetch). Independent audit and review agents use
`gpt-6-astra`, `reasoning_effort=ultra`. All work was local to the isolated
`codex/astra-conformance-truth-20260907` worktree.

After the audit, upstream `1481c852` corrected unrelated SPEC-016 evidence
metadata. The task commit was rebased onto that update; the four audited specs,
their requirement rows, runtime code, and test implementation were unaffected.

## Result

The 32 requirements have substantially different implementation maturity.
SPEC-041 is a gateway rejection/disclosure slice; full request encryption is
absent. SPEC-045 has substantial working code and a valid historical signed
journey, but several complete requirements are overstated as conformant.
SPEC-046/047 have significant code and tests omitted from their conformance
mappings; missing workflows and signed evidence still justify pending status.

One bounded fix adds a database-reopen regression for SPEC-041 replay
retention. Runtime code, specs, authority, conformance states, and signed
artifacts are unchanged. This audit does not certify deployment or release
readiness, and the outstanding findings below are not fixed by that test.

| Spec | Claimed requirement states | Audited verdict totals |
| --- | --- | --- |
| 041 | 8 pending; gateway mappings already present | 6 partially implemented, 1 not implemented, 1 evidence gap |
| 045 | 8 conformant | 1 implemented, 6 partially implemented, 1 test gap |
| 046 | 8 pending; implementation/test arrays empty | 2 implemented, 2 partially implemented, 2 test gaps, 1 evidence gap, 1 stale metadata |
| 047 | 8 pending; implementation/test arrays empty | 4 partially implemented, 3 test gaps, 1 evidence gap |

Verdicts apply to the complete requirement, not just its existing slice.
`implemented` describes inspected local behavior, not signed conformance.
Risk includes readiness risk: an absent, disabled cryptographic feature is a
High blocker to a future privacy claim, not evidence of a current exploit.
Findings are source-supported unless an execution result is explicitly given.

## Ranked Findings

1. **High: ambiguous SPEC-045 sends free potentially spent local budget.**
   `ConsumeCommand.swift:1343` initiates `NWConnection.send`; the classifier
   at `:1365` turns every send failure into `preDispatchUnavailable`. The
   downstream failure path at `:5661` settles the reservation to zero and
   reports no forwarding. The passing test at `ConsumeCommandTests.swift:1651`
   explicitly expects this conversion even from `dispatchedUnavailable`.
   Apple defines completion as processing by the network stack; an error is
   not proof of zero remote delivery. Conservative exposure retention is the
   necessary inference, not a claim that every failed send delivered bytes.
   [Apple send completion](https://developer.apple.com/documentation/network/nwconnection/sendcompletion/contentprocessed(_:)),
   [Apple Network.framework presentation](https://developer.apple.com/videos/play/wwdc2018/715/).
   Confidence: high; no real gateway send failure was induced.
2. **Medium: SPEC-045 conformant rows exceed implemented behavior.**
   Immutable credential custody never reloads and wipes only at deinit
   (`ConsumeCommand.swift:4199`); the invalid/expired state is absent (`:3494`).
   `/v1/models` returns the local allowlist without current upstream visibility
   (`:6396`). Unpriced budget admission holds the entire remaining budget and
   returns 503 without dispatch (`:6341`). Contact/error history is always
   null/empty (`:4169`), and the server has no signal-triggered bounded
   drain/hold/descriptor cleanup (`:4521`). Tests cover these intermediate
   shapes, not the omitted contract. R003/R005/R006/R008 in particular must
   not be treated as fully satisfied because a journey signature validates.
3. **Medium: SPEC-041 reject-path coverage and behavior remain incomplete.**
   Required malformed/cap/freshness failures bypass the privacy audit
   (`relay_blind.go:170`, `:187`, `:195`, `:199`); a cap test explicitly expects
   zero privacy-audit events (`relay_blind_test.go:1489`). Wallet metadata
   admission precedes relay replay lookup (`relay_blind.go:167`, `:207`):
   static control flow indicates that the same envelope with a fresh signed
   outer request ID can encounter a wallet rate limit before permanent replay
   rejection. That precedence hypothesis needs a focused reproduction before
   a cross-SPEC-040 change. The separate database-reopen test gap is fixed here.
4. **Medium: SPEC-046's E2E oracle and redaction diagnostics are incomplete.**
   The manual harness expects `would_submit=false` and `evaluation_required`
   (`test/e2e/byom/run-cli-onboarding-e2e.py:471`), while its offerable 64-GB
   catalog fixture produces `would_submit=true` and
   `catalog_binding_unverified` (`BYOMDiscovery.swift:2582`, `:2611`). This is
   a deterministic source/fixture disagreement; the full E2E was not run.
   Sensitive optional labels and absent labels both become null, and unsafe
   model records disappear without a warning (`:3361`, `:3575`), contrary to
   the redacted-versus-absent diagnostic contract. Content suppression exists;
   no secret leakage was demonstrated.
5. **Medium: SPEC-047 policy/probe/revocation workflows are not connected.**
   `AppendModelAdmissionDecision` and `ModelAdmissionRevocationForRuntimeDrift`
   have no production callers. Offers/withdrawals are live code, but tests
   directly create later admission states. Route-time guards reject invalid
   trusted catalog/hash/receipt predicates; this is incomplete functionality,
   not an established earnings bypass. Full transition, all-state no-charge,
   withdrawal signature-role, parser-bound, and real drift tests are missing.
6. **Low: governance maps and historical narratives need reconciliation.**
   SPEC-046/047 empty implementation/test arrays understate the code below.
   SPEC-045's Phase 4 matrix still says signed evidence is missing. SPEC-041
   is omitted from four consumed authority domains: provider wire,
   coordinator admission, onboarding identity, and Tier-2 evidence
   (`AUTHORITY.json:10`, `:29`, `:47`, `:131`). SPEC-047 R002/R007 consume
   SPEC-026 current admission identity without listing it in `depends_on` or
   the corresponding authority consumer list. These omissions confer no new
   authority and do not justify promotion.

## Reference Key

Paths are repo-relative; line references use the audited base except `RST`,
whose new test is in this change. Symbols in the matrix identify implementation
and test functions; grouped requirements still have one row per requirement.

| Alias | File |
| --- | --- |
| GC / GCT | `phase5-gateway/internal/config/config.go` / `config_test.go` |
| GR / GRT | `phase5-gateway/internal/router/relay_blind.go` / `relay_blind_test.go` |
| GD | `phase5-gateway/internal/router/disclosure.go` |
| GS / GST | `phase5-gateway/internal/storage/sqlite/store.go` / `wallet_session_test.go` |
| RST | `phase5-gateway/internal/storage/sqlite/relay_blind_replay_test.go` |
| GSR / GSRT | `phase5-gateway/internal/router/server.go` / `server_test.go` |
| C / CT | `phase3-binary/Sources/macprovider-cli/ConsumeCommand.swift` / `phase3-binary/Tests/macprovider-cliTests/ConsumeCommandTests.swift` |
| P / PT | `phase3-binary/Sources/macprovider-cli/ConsumeTrustedPricing.swift` / `phase3-binary/Tests/macprovider-cliTests/ConsumeTrustedPricingTests.swift` |
| B / M | `phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift` / `ModelsSubcommand.swift` |
| DT / ET | `phase3-binary/Tests/macprovider-cliTests/BYOMDiscoveryTests.swift` / `BYOMEvaluationTests.swift` |
| OT / AT | `phase3-binary/Tests/macprovider-cliTests/BYOMOfferDryRunTests.swift` / `BYOMAdmissionTests.swift` |
| EC / ECT | `phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift` / `phase3-binary/Tests/macprovider-cliTests/ModelCatalogEconomicsTests.swift` |
| A / AST | `phase4-coordinator/internal/ws/model_admission.go` / `model_admission_test.go` |
| BR / BRT | `phase4-coordinator/internal/buyer/model_admission.go` / `route_snapshot_test.go` |
| RF / RFT | `phase4-coordinator/internal/routing/filter.go` / `filter_test.go` |
| H | `test/e2e/byom/run-cli-onboarding-e2e.py` |

Artifact labels:

- **D041**: `specs/design/spec-041/BUILD_SPEC_041_RELAY_BLIND_REQUEST_ENCRYPTION_IMPL.md` explicitly limits scope to admission/disclosure; no SPEC-041 signed result or journey descriptor found.
- **D045**: `specs/design/spec-045/BUILD_SPEC_045_PHASE_4_CONFORMANCE_MATRIX.md` and the Phase 1-4C prompts. They describe staged implementation and local fixtures; their old pending-evidence statements are stale.
- **E045**: the existing signed journey and redacted source described below.
- **H046**: H, `test/e2e/byom/README.md`, and `CANDIDATE-E2E-RUNBOOK.md`; unsigned manual scaffolding. No signed `JOURNEY-PROVIDER-BYOM-DISCOVERY` result found.
- **J047**: `journeys/JOURNEY-NETWORK-MODEL-ADMISSION.md`, a draft 12-step test contract, plus H's fake coordinator. No matching signed admission result found.

## Requirement Matrix

### SPEC-041

All rows claim `pending`; existing gateway mappings acknowledge the partial
slice. All journey/evidence arrays are empty. Provider key/decryption tests
must not be inferred from SPEC-008 encryption tests.

| Requirement | Summary | Claimed | Implementation files/functions | Tests found | Artifacts | Actual verdict | Risk |
| --- | --- | --- | --- | --- | --- | --- | --- |
| SPEC-041-R001 | Default off; separate privacy scope; endpoint disclosure | pending | GC:469 `Default`; GD:476 `applyRelayBlindDisclosure`, :482 unavailable labels | GCT:48 `TestRelayBlindRequestsDefaultOffDoesNotRequireBounds`; GRT:21 default omitted, :37 enabled unavailable, :1038 plaintext compatibility | D041; no signed evidence | evidence_gap | Low |
| SPEC-041-R002 | Provider-signed keys, canonical IDs, rotation/revocation | pending | No SPEC-041 key ingestion/signature/revocation; `phase4-coordinator/internal/ws/relay.go:579` is SPEC-008 `sealInferenceRequest` | No key-lifecycle vectors; `internal/trustpool/root_manifest_test.go:164` only rejects premature relay-blind promises | D041; none | not_implemented | High |
| SPEC-041-R003 | Closed envelope; X25519/HKDF/AEAD/AAD and wallet binding | pending | GR:868 `validateRelayBlindRequestEnvelope`; :634 replay material; wallet raw-body signatures in `router/wallet_sessions.go:525`; no buyer crypto/transcript | GRT:774 invalid envelope, :823 multiple JSON, :856 token caps, :915 malformed sentinels; no crypto vectors | D041; none | partially_implemented | High |
| SPEC-041-R004 | Authenticated no-store reservations; fail closed before dispatch/quota | pending | GSR:236 route mount; GR:68 `handleRelayBlindRouteReservations`, :158 reject guard, :282 disabled endpoints; no usable binding mint/dispatch | GRT:79 no-store/no-quota, :145 wallet signature, :363 no dispatch, :545 rate isolation, :1078 disabled family | D041; none | partially_implemented | Medium |
| SPEC-041-R005 | Provider validation; durable single-use replay; no pre-dispatch billing | pending | No provider crypto; GS:2166 `RecordRelayBlindReplay`, :2220 `RelayBlindReplaySeen`; `sqlite/migrate.go:187` persistent DDL | GRT:450 replay, :485 same-store toggle; GST:46 duplicate before capacity; RST:13 `TestRelayBlindReplaySurvivesReopenAndHonorsOriginalRetention` | D041; local new test only | partially_implemented | High |
| SPEC-041-R006 | Existing settlement, clear caps, no premature verified claims, redaction | pending | GD:482 exact unavailable settlement labels; GR:689/:711 redacted audit; no successful encrypted usage/clamp/receipt path | GRT:37 disclosure, :363 no charge/redaction, :404 wallet correlation; cap tests do not prove successful settlement | D041; none | partially_implemented | Medium |
| SPEC-041-R007 | Typed permanent/retry errors; downgrade resistance; rejection audit | pending | GSR:1293/:1367 classification; GR emitters and audit helpers; several required rejects unaudited; no provider emissions | GSRT:6553 retry map, :6698 completeness; GRT:1586 downgrade, :1809 audit failure | D041; none | partially_implemented | Medium |
| SPEC-041-R008 | Disabled defaults, rollback, mixed binaries, signed promotion gate | pending | GC:1004 `validateRelayBlindRequestsConfig`; GR:792-824 fallback bounds; no provider/coordinator successful mode | GCT:58 validation; GRT:485 toggle, :645 capacity, :1078 endpoint flags; RST reopen test; no real mixed-binary journey | D041; none | partially_implemented | Medium |

### SPEC-045

Each row claims `conformant`, gap null, with mapped commit `dc63ecec` and E045.
Valid signed provenance and a complete normative implementation are separate
questions. D045 is design/history, not an override of the normative spec.

| Requirement | Summary | Claimed | Implementation files/functions | Tests found | Artifacts | Actual verdict | Risk |
| --- | --- | --- | --- | --- | --- | --- | --- |
| SPEC-045-R001 | Loopback consume command, fixed port, redacted stderr startup | conformant | C:66 `ConsumeRunCommand.run`, :3177 `normalizeBindAddress`, :4442 `writeStartup`, :4521 server | CT:274 bind limits, :485 startup, :509 collision, :445 descriptor/redaction, :536 lock | E045 + D045 | implemented | Low |
| SPEC-045-R002 | Exact HTTP subset, bounded parsing/resources, verbatim body/SSE, visible models | conformant | C:4816 framing, :4894 endpoints, :5002 strict JSON, :4285 resource counter, :835 SSE; :6396 model list ignores upstream visibility | CT:681 targets/framing/origins, :856 caps, :970 duplicate JSON, :4386 live SSE, :4584/:4654 SDK-shaped payloads, :5649 local-only list | E045 + D045 | partially_implemented | Medium |
| SPEC-045-R003 | Credential reload/wipe/auth state; local token; pinned safe upstream | conformant | C:3440 HMAC verifier, :3572 loader, :3627 FD checks, :1159/:1232 pinned TLS fetch; :4199 immutable custody and :3494 missing expired state | CT:314 auth, :332 precedence, :407/:432 file/symlink/ACL/deletion, :4707 redirects, :4765 headers; no runtime reload/wipe or TLS-failure matrix | E045 + D045 | partially_implemented | Medium |
| SPEC-045-R004 | Trusted model/pricing admission; exposure caps; usable overrides | conformant | C:336 estimator, :491 budget config, :5060 admission; P:193 trust/freshness; C:6341 unpriced hold-only placeholder | CT:1015 flags, :1396 arithmetic, :4807 caps, :5540 atomic admission, :5573 holds without forwarding; PT:9/:39/:66 trust/freshness | E045 + D045 | partially_implemented | Medium |
| SPEC-045-R005 | Durable ledger, conservative unknown exposure, restart/recovery, graceful shutdown | conformant | C:2177 ledger, :2868 fsync append, :2597 restart holds, :2607 release; :1365 unsafe send classifier; :4521 lacks signal drain | CT:1531 dispatched hold, :1594 pre-dispatch zero, :1651 unsafe send expectation, :5192/:5427 state integrity, :4488 cancel; no SIGTERM/drain test | E045 + D045 | partially_implemented | High |
| SPEC-045-R006 | Truthful bounded diagnostics, secure descriptor, no-store/redaction | conformant | C:3769 descriptor, :3837 lock, :3864 private atomic write, :4152 `statusPayload`; :4169/:4170 contact/error placeholders | CT:445/:536 descriptor, :524 missing endpoint, :599 auth/no-store checks only error-ring array shape, :1360 pricing | E045 + D045 | partially_implemented | Medium |
| SPEC-045-R007 | Upstream status preservation, safe errors/provenance, bounded responses, no retry | conformant | C:6021 `classifyUpstreamFailure`, :6089 decode, :6472 local errors, :6661 header allowlist; :1365 loses ambiguous-send provenance | CT:2296/:2408 compression/provenance, :3453 compressed SSE, :4318 upstream errors, :4707 redirect stripping, :1651 unsafe send expectation | E045 + D045 | partially_implemented | High |
| SPEC-045-R008 | Complete negative automated coverage plus real-gateway signed journey | conformant | C/P plus capture/builder/protected signer; missing mechanisms above prevent complete test fulfillment | 124 CT, 7 PT, 2 fake-journey tests pass; missing reload/wipe/expired state, SIGTERM, nonempty error ring, current model visibility and TLS matrix | E045 is valid; D045 pending prose stale | test_gap | High |

### SPEC-046

All rows claim `pending`, with empty implementation/test/evidence arrays and
the discovery journey ID. Empty mappings are stale even when the primary
verdict below highlights a larger gap. Local tests never grant admission,
catalog price authority, hardware verification, or earning eligibility.

| Requirement | Summary | Claimed | Implementation files/functions | Tests found | Artifacts | Actual verdict | Risk |
| --- | --- | --- | --- | --- | --- | --- | --- |
| SPEC-046-R001 | CLI-owned discover/evaluate and distinct closed output contracts | pending, no mappings | M:25/:65 command runners; B:324/:482 distinct schemas; JSON stdout/warning stderr | DT:51 schema, :216 warnings, :234 JSON flag; ET:19 hermetic command; `scripts/tests/test_byom_contract_lock.py:56` taxonomy | H046; no signed result | conformance_metadata_stale | Low |
| SPEC-046-R002 | Explicit bounded local adapters; loopback/no scanning; warnings | pending, no mappings | B:1972 discover, :3164 Ollama, :3299 origin validator, :1877 bounded no-proxy client; :3361 silently drops malformed records | DT:310 origin, :426 rejection, :462/:484 size, :502 redirect, :546 malformed syntax; no per-item warning test | H046 | partially_implemented | Medium |
| SPEC-046-R003 | HMAC candidate IDs, null fields, local state/source/guidance | pending, no mappings | B:193 candidate, :2690 private namespace, :2793 HMAC identity, :3720 local states, :843 strict coordinator status | DT:51 selected schema fields, :106 no namespace, :245 stable scoped identity; AT:537/:569/:592 invalid schema/identity/source; exact nested keys/local ladder gaps | H046 | test_gap | Low |
| SPEC-046-R004 | Advisory nullable capabilities; no verified overclaim | pending, no mappings | B:56 nullable capabilities, :3079/:3249 candidate builders, :2423 not-tested probe features | DT:51 nullable output, :371 advisory labels; ET:19 capability results | H046 | implemented | Info |
| SPEC-046-R005 | Bounded local evaluation; no money/serving mutation; hashed output | pending, no mappings | B:2027 limits, :2067 evaluate, :2129 local probe, :2482 timeout, :2475 hashes; MLX execution explicitly blocked | ET:19 local probe, :70 MLX blocked, :93 injected timeout, :170 malformed choices, :204 token bounds, :312 redirects; no stalled deadline/output-byte-cap test | H046 | test_gap | Medium |
| SPEC-046-R006 | Read-only discovery; no download/install/config/switch side effects | pending, no mappings | B:1972 discovery, :2909 bounded enumeration, :2946 bounded file read, :3012 cache-contained symlinks; only local namespace provisioned by evaluation | DT:106 absent namespace unchanged, :124 symlinks, :567 cache unchanged; ET:70 blocked MLX, :117/:129 namespace provisioning | H046 | implemented | Low |
| SPEC-046-R007 | No secrets/paths/transcripts; distinguish absence from redaction | pending, no mappings | B:3499 privacy, :3575 safe labels, :2475 hashes; absent and suppressed labels indistinguishable, unsafe records silently omitted | DT:162 unsafe refs, :371 suppressed labels, :426 origin redaction; ET:147 body hash, :260 unsafe target; no distinct redaction assertion | H046 | partially_implemented | Medium |
| SPEC-046-R008 | Full schema/negative/copy/ladder tests and signed discovery journey | pending, no mappings | Implemented MLX-cache/Ollama discovery; H:471 stale oracle; opaque candidate journey scenario absent | DT/ET/AT/OT local tests; contract text locks; no complete opaque/ladder/timing/redaction matrix | H046 is unsigned scaffolding, not execution evidence | evidence_gap | Medium |

### SPEC-047

All rows claim `pending`, with empty implementation/test/evidence arrays and
J047. State stores and route guards exist; policy-driven promotion and drift
events must not be inferred from tests that insert coordinator decisions.

| Requirement | Summary | Claimed | Implementation files/functions | Tests found | Artifacts | Actual verdict | Risk |
| --- | --- | --- | --- | --- | --- | --- | --- |
| SPEC-047-R001 | Durable closed state machine, fresh re-entry, ordered demotion | pending, no mappings | A:124 memory append, :399 SQLite provider append, :565 decision append, :778 transitions, :854 freshness; decision has no live caller | AST:451 withdrawn re-entry, :518 state/routing, :788 persistence, :1166 append ordering; rejected/revoked matrix incomplete | J047 | partially_implemented | Medium |
| SPEC-047-R002 | Dry run, current-key signed closed offer/withdrawal, strict status | pending, no mappings | M:151/:248/:319 commands; B:1247 offer builder, :1350 withdrawal, :1454 client; A:1097/:1152 handlers, :1267/:1331 signatures | OT:67 no submission/rates, :107 emitted schema; AT:30/:187 signing, :275 tuple, :537 strict decode; AST:214 key roles; withdrawal parity gaps | J047 + H | partially_implemented | Medium |
| SPEC-047-R003 | Settlement-capable-only paid path; exact trusted catalog/receipt binding | pending, no mappings | A:983 snapshot binding; BR:20 default gate, :51 durable binding, :131 enforce/hash/receipt guard; `buyer/route_snapshot.go:69` dispatch snapshot | BRT:751 no provider reach/credit, :884 binding, :958 receipt key, :1029 mismatch; GSRT:7477 no charge/verified claim; all-state coverage incomplete | J047 | test_gap | Medium |
| SPEC-047-R004 | Advisory prices, null non-earning economics, trusted rates and honest copy | pending, no mappings | A:1759 guidance; EC:351 projection, :498 trusted rates, :555 null economics; B:913 strict guidance; terminal catalog-path distinction incomplete | ECT:6/:49/:135/:154/:202/:264 nulls/trust/state; OT:67/:138; AT:423 missing catalog; no terminal catalog/noncatalog matrix | J047 + H | partially_implemented | Medium |
| SPEC-047-R005 | Default buyer invisibility; no sole-provider relaxation; opt-in experimental only | pending, no mappings | `buyer/server.go:2027` models gate; RF:301 BYOM filter; BR:20 durable admission even without heartbeat marker; experimental publication absent and fails closed | RFT:387 exclusion; BRT:751 hidden single provider, :832 alias; GSRT:6599/:7477 permanent unavailable/no charge; all-state/entrypoint gaps | J047 | test_gap | Medium |
| SPEC-047-R006 | Signed withdrawal; drift/staleness demotion and reason visibility | pending, no mappings | B:1720 withdrawal/fallback; A:1152 durable withdrawal; :1026 drift helper has no live caller and only handles settlement-capable; buyer guards still reject mismatch | AT:219/:275/:318 withdrawal; AST:70/:146; :1128 helper tests, :676 manual reason events; no heartbeat-to-revocation test | J047 + H withdrawal only | partially_implemented | Medium |
| SPEC-047-R007 | Current-key auth, replay/resource limits, unsafe-content rejection, sanctions | pending, no mappings | A:41 bounds, :1097/:1152 attempt limit, :1267/:1331 signatures, :1392 sanctions, :1599/:1672 validation, :1906 unsafe-text checks | AST:214 key roles, :270 rate limits, :292 sanctions, :323/:349/:366 unsafe refs, :1017/:1053 replay; parser/withdrawal/sanction matrix incomplete | J047; H checks signature presence only | test_gap | Medium |
| SPEC-047-R008 | Complete admission negative matrix and signed multi-state journey | pending, no mappings | Local fixtures and H exist; no admission-specific signed result/promotion workflow or live full journey | Partial Swift/Go tests above; H fake coordinator lacks real signature/policy/probe/drift/settlement verification | J047 is a contract; no signed result | evidence_gap | Medium |

## Evidence And Reconciliation

E045 is
`journeys/evidence/local-consumer-endpoint-20260824T060103Z.spec-045-r001-spec-045-r002-spec-045-r003-spec-045-r004-spec-045-r005-spec-045-r006-spec-045-r007-spec-045-r008.journey-result.signed.json`.
Its SHA-256 is `991c30ba0f34377ec66c993e27e2a3dd6b47705acc2799f5cf973d2ebd434161`.
The redacted source is `journeys/evidence/local-consumer-endpoint-20260824T060103Z.redacted.json`.
The repository validator verifies the pinned public-key signature, source
binding, expiry (2027-08-24), and all eight requirement IDs. It covers the
2026-08-24 candidate `dc63ecec`, CLI 1.8.104, and an operator-reviewed SDK,
budget denial, restart-held recovery, redaction, and cleanup journey.

Committed support evidence consists of hashes/byte counts and signed
operator review, not the underlying CLI/ledger/log/status captures. This run
does not independently reconstruct those bytes, replay the gateway journey,
or inspect production. No evidence falsification was established. Signature
validity cannot resolve the missing runtime mechanisms in the matrix.

`specs/PROCESS.md:21` separates lifecycle, implementation, production, and
requirement conformance. Thus SPEC-045 remaining draft/not-deployed alongside
conformant rows is not itself a contradiction. Reconciliation should preserve
historical E045 while recording current incomplete clauses for R002-R008;
it must not promote the spec because the signature passes. SPEC-041 stays
pending. SPEC-046/047 need accurate local mappings and explicit remaining gaps,
while preserving pending states and absent signed evidence. Authority owners
remain SPEC-005 for billing and SPEC-022 for verified settlement. This report
records reconciliation recommendations; it does not edit the manifests.

## Targeted Fix And Next Slice

Changed code surface: `phase5-gateway/internal/storage/sqlite/relay_blind_replay_test.go`
only. The new test records replay material, closes SQLite, opens the same
database through normal migrations, and verifies both lookup and insertion.
Account and wallet-session scopes each exercise exact replay and independently
colliding request ID, nonce, ephemeral key, and envelope digest. Shorter current
retention cannot shorten the stored window; duplicates beat saturated row/byte
capacity; the original expiry boundary releases storage capacity.

This is proof of the local replay-store contract, not a process crash/power-loss
test, wallet HTTP authentication test, provider replay implementation, successful
encryption vector, or signed journey. Runtime behavior and dependency pins are
unchanged. The source-supported test gap is closed without changing authority or
invalidating historical implementation mappings. No additional fixes were made.

**Next best bounded implementation slice:** fix SPEC-045's ambiguous-send
classification for streaming and non-streaming attempts. Retain exposure after
send has begun; preserve zero release for proven pre-send failure. Replace the
unsafe assertion and test classified failures through the ledger, forwarded
status, subsequent budget denial, streaming pre-head/post-head handling, and
restart/recovery. Reconcile only evidence/mappings affected by that slice;
do not reuse the old signed candidate to certify changed implementation. Leave
credential reload, diagnostics, model fetching, and shutdown for separate work.

Other deferred Low issues: SPEC-047 withdrawals can replace the stored catalog
key because tuple comparison only covers candidate/served reference (A:836,
:847); the spec does not unambiguously prohibit that change, and no paid-path
bypass was found. Terminal-state earning-path copy also loses the catalog
distinction (A:1759). Clarify the contract before changing either side.

## Verification

All commands ran in this worktree; module-specific commands ran in the named
module. No deployment, release, real-gateway capture, signing, secret use,
billing mutation, push, or merge was performed.

| Command | Exact result |
| --- | --- |
| `git diff --check` | exit 0 |
| `jq empty specs/AUTHORITY.json specs/CONFORMANCE.json` | exit 0 |
| `PYTHONDONTWRITEBYTECODE=1 python3 scripts/gen_spec_index.py --check` | exit 0; 47 canonical specs; index up to date |
| `PYTHONDONTWRITEBYTECODE=1 python3 scripts/gen_spec_index.py --lint` | exit 0; specs root canonical-only, 51 tracked |
| Gateway: `go test ./internal/storage/sqlite -run '^TestRelayBlindReplaySurvivesReopenAndHonorsOriginalRetention$' -count=1 -v` | exit 0; both scopes and all 10 collision subtests PASS |
| Gateway: `go test ./internal/storage/sqlite -race -count=1` | exit 0; complete sqlite package PASS, 9.596s on the final file layout (earlier run 9.376s) |
| Gateway: `go vet ./internal/storage/sqlite` | exit 0 |
| Gateway: `go test ./internal/config ./internal/router ./internal/storage/sqlite -run 'RelayBlind\|GatewayErrorCodeCompleteness' -count=1` | exit 0; config 0.517s, router 1.455s, sqlite 1.145s (baseline) |
| Gateway: `go test ./internal/router -run '^TestBYOM(NonSettlementUnavailableIsPermanent\|NonSettlementCoordinatorUnavailableDoesNotChargeOrClaimVerified)$' -count=1` | exit 0; router PASS, 0.885s |
| Coordinator: `go test ./internal/ws ./internal/buyer ./internal/routing ./internal/billing -run 'ModelAdmission\|BYOM\|PoolCheckReadinessAppliesBYOM' -count=1` | exit 0; ws 0.820s, buyer 1.175s, routing 2.002s, billing 1.575s |
| Swift: `swift test --jobs 4 --filter 'BYOMDiscoveryTests\|BYOMEvaluationTests\|BYOMOfferDryRunTests\|BYOMAdmissionTests\|ConsumeCommandTests\|ConsumeTrustedPricingTests\|ConsumeConformanceJourneyTests'` | exit 0; 199 tests, 0 failures: 25 discovery, 13 evaluation, 8 dry run, 20 admission, 124 consume, 7 pricing, 2 local fake-journey |
| Swift: `swift test --skip-build --filter ModelCatalogEconomicsTests` | exit 0; 8 tests, 0 failures |
| `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_byom_contract_lock.BYOMContractLockTests.test_legacy_model_command_strings_remain_pinned scripts.tests.test_byom_contract_lock.BYOMContractLockTests.test_byom_command_taxonomy_uses_distinct_schema_owners scripts.tests.test_byom_contract_lock.BYOMContractLockTests.test_earning_verdict_first_human_output_contract` | exit 0; 3 tests, 0.003s; text/manifest contracts only |
| `PYTHONDONTWRITEBYTECODE=1 python3 scripts/validate-signed-journey-result.py journeys/evidence/local-consumer-endpoint-20260824T060103Z.spec-045-r001-spec-045-r002-spec-045-r003-spec-045-r004-spec-045-r005-spec-045-r006-spec-045-r007-spec-045-r008.journey-result.signed.json --requirement-ids SPEC-045-R001,SPEC-045-R002,SPEC-045-R003,SPEC-045-R004,SPEC-045-R005,SPEC-045-R006,SPEC-045-R007,SPEC-045-R008` | exit 0; `validated 8 requirement(s) without promotion` |
| `PYTHONDONTWRITEBYTECODE=1 python3 scripts/check_spec_governance.py --base-ref origin/main` | exit 1; initial baseline had SPEC-010/SPEC-016 issues below; final rerun after upstream correction has only SPEC-010-R002; no target-spec errors |

Swift emitted existing concurrency/deprecation warnings. Its generated removal
of platform-unused `Package.resolved` pins was restored; no dependency changes
are included. Full Swift, full coordinator/gateway, and manual BYOM E2E suites
were not run. Existing passing tests do not close untested normative clauses.

The global governance gate is **not green**: `SPEC-010-R002` commit evidence
`6a2278f4` differs from the current mapped `sendHeartbeat` selector. The initial
baseline also failed because `SPEC-016-R002` evidence and its signed journey
expired on 2026-09-05. Upstream commit `1481c852` demoted that unrelated row to
pending while this audit ran; the final branch includes that change and the
fresh validator now reports only SPEC-010-R002. Both initial failures were
outside this run's four-spec/one-fix scope; no additional fix was authored here.
No gate bypass or production promotion is authorized by this audit.

## Final Diff Review

Independent `gpt-6-astra` / `ultra` code, security, and architecture/spec-boundary
lanes reviewed the complete test/report diff. Each reported **0 Critical,
0 High, 0 Medium** introduced findings. Code review independently reran the
new test with `-race -count=1 -v` (PASS, 1.821s); security review reran it without
race instrumentation (PASS, 0.477s). Architecture review checked all 32 IDs,
summary counts, unchanged authority/conformance, and historical-evidence limits.

One Info limitation is carried deliberately: row and byte caps are saturated
together, so this test proves duplicate precedence under saturation rather
than independent enforcement of each cap. That enforcement is not the new
test's claim. There are no Low findings on the final diff. The remaining
runtime and SPEC-010 governance findings above are unresolved and are not covered
by the three-lane acceptance of this narrow test change.
