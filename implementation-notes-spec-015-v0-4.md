# SPEC-015 v0.4 implementation notes

## Step 0 - Preflight and baseline

Date: 2026-06-30

Worktree:

- Path: `/Users/augstar/macprovider-impl-spec-015-v0-4`
- Branch: `impl/spec-015-v0-4-settlement-receipts`
- Base: SPEC branch commit `d70eb16` (`Lock settlement receipt trust floor`)
- Dirty state before product edits: clean (`git status -sb` showed only the
  branch name)

Locked-spec evidence:

- `specs/SPEC-015-receipts.md` line 3 is locked at `0.4.2`.
- `specs/SPEC-015-v0-4-audit.md` final status is 0 critical / 0 high /
  0 medium across Codex code, Codex security, Codex architect, Claude
  adversarial verification, and Claude product design critic lanes.
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT_AUDIT.md`
  final status is 0 critical / 0 high / 0 medium across the same five lanes.

SPEC-022 boundary:

- SPEC-022 D-022-1 frames this as a product-wide trust floor, not a beta-only
  shortcut or temporary launch exception.
- `specs/SPEC-022-verified-model-settlement.md` still treats SPEC-015 v0.3 or
  earlier receipts as not settlement-capable. SPEC-015 v0.4 work must not wire
  enforce-mode buyer final debit, provider-positive settlement, payout
  readiness, or gateway money movement.
- Step 1 remains a contract/fixture slice before any product behavior lands.

Baseline commands:

| Command | Result | Evidence |
|---|---|---|
| `cd phase4-coordinator && go test ./...` | PASS | completed before implementation edits |
| `cd phase5-gateway && go test ./...` | PASS | completed before implementation edits |
| `cd phase7-verify && go test ./...` | PASS | completed before implementation edits |
| `cd phase3-binary && swift test` | FAIL, known baseline | 672 tests, 7 skipped, 1 failure |

Swift baseline failure:

- Full suite log: `/tmp/spec015-v04-swift-test.log`.
- Failing test:
  `ModelsSubcommandTests.testModelsListDisabledModePrintsIdleTableAndExitsZero`
  at `phase3-binary/Tests/macprovider-cliTests/ModelsSubcommandTests.swift:64`.
- Targeted rerun:
  `swift test --filter ModelsSubcommandTests/testModelsListDisabledModePrintsIdleTableAndExitsZero`
  also failed with the same assertion.
- This branch had no product code edits when the failure was observed, so later
  SPEC-015 verification should use targeted tests for changed receipt behavior
  and keep this failure visible as a pre-existing baseline issue until fixed in
  a separate slice.

Stop condition:

- Step 0 is complete when the five Step 0 audit lanes report 0 critical /
  0 high / 0 medium on this preflight evidence.

## Step 1 - v0.4 canonical contract and fixtures

Date: 2026-06-30

What landed:

- Deterministic v0.4 settlement fixture generator:
  `phase7-verify/testdata/generator/v04/main.go`.
- Shared fixture corpus:
  `testdata/spec015/v04_settlement_receipts.json`.
- Swift fixture/parity tests:
  `phase3-binary/Tests/macprovider-cliTests/SPEC015V04SettlementFixtureTests.swift`.
- Go module-local conformance tests:
  `phase4-coordinator/internal/spec015contract/`,
  `phase5-gateway/internal/spec015contract/`, and
  `phase7-verify/internal/jcs/v04_settlement_fixture_test.go`.

Fixture coverage:

- `receipt_version: "4"` signed tuples with deterministic Ed25519 signatures
  and strict v0.4 tuple keys.
- `route_snapshot_v1` strict object and digest.
- `settlement_output_v1` strict objects for non-streaming `normal_done`,
  streaming `[DONE]`/`normal_done`, `provider_error`, `buyer_cancel`,
  `gateway_timeout`, and `upstream_transport_disconnect`, including empty and
  non-empty prefix cases.
- A signed streaming/tool-call tuple with a non-zero output prefix and
  adversarial canonicalization content (`<`, `>`, `&`, and decomposed Unicode)
  so the streaming path is represented end-to-end, not only as a standalone
  output object.
- Strict `usage` objects for normal billable, zero-settled empty prefix, and
  partial-prefix billable cases.
- Per-request attempt sequencing fixtures use `attempt_n` as a zero-based
  contiguous retry/failover counter; scenario identity lives in fixture IDs,
  not in attempt numbers.
- Negative receipt vectors cover output-hash mismatch, route digest mismatch,
  model-hash mismatch, terminal-state mismatch, out-of-enum terminal state,
  attempt mismatch, wrong-key signature, legacy receipt version, missing
  `output_hash`, extra top-level tuple field, mismatched
  `delivered_output_bytes`, negative usage values, missing/extra usage fields,
  and `usage: null`.
- `negative_range_scenarios` cover overlapping, duplicate, and out-of-order
  output prefix ranges outside the positive receipt corpus, while the positive
  shared chain keeps adjacent half-open ranges `[0,13)` and `[13,30)` with
  `upstream_transport_disconnect` as the non-final prefix and streaming
  `normal_done` as the final tuple.
- Cross-language canonical byte/hash parity between Swift and Go for the
  receipt tuple, route snapshot, usage, and `settlement_output_v1` fixtures.
- Cross-object assertions bind each signed tuple to its route snapshot digest,
  output hash, output byte range, usage delivered-byte count, Ed25519
  signature, and `provider_receipt_key_id`.

Import boundary:

- `phase4-coordinator` and `phase5-gateway` do not import
  `phase7-verify/internal/*`. Their Step 1 tests use module-local test
  canonicalizers locked by the same golden fixture corpus.
- `phase5-gateway` now uses the same `golang.org/x/text v0.37.0` module
  version already used by phase4 and phase7 so its test-only canonicalizer can
  normalize string values to NFC.

Validation:

| Command | Result |
|---|---|
| `cd phase3-binary && swift test --filter SPEC015V04SettlementFixtureTests` | PASS, 8 tests |
| `cd phase4-coordinator && go test ./...` | PASS |
| `cd phase5-gateway && go test ./...` | PASS |
| `cd phase7-verify && go test ./...` | PASS |
| `rg -n "phase7-verify/internal\|github.com/augstar/macprovider/phase7-verify/internal" phase4-coordinator phase5-gateway` | no matches |
| deterministic regeneration diff for `testdata/spec015/v04_settlement_receipts.json` | PASS, no diff |

Post-Step 1 baseline cleanup:

- The prior full `cd phase3-binary && swift test` failure in
  `ModelsSubcommandTests.testModelsListDisabledModePrintsIdleTableAndExitsZero`
  was a non-hermetic test issue, not settlement behavior. The test expected
  `--model old-model` to be the idle row, but the command also reads local
  operator config; machines with configured `supported_models` correctly prefer
  that catalog. The test now passes explicit `--supported-models old-model`.
- Follow-up validation:
  `cd phase3-binary && swift test --filter ModelsSubcommandTests.testModelsListDisabledModePrintsIdleTableAndExitsZero`
  passed, and full `cd phase3-binary && swift test` passed with 680 tests,
  7 skipped, and 0 failures.

Stop condition:

- Step 1 is complete when the five Step 1 audit lanes report 0 critical /
  0 high / 0 medium on this fixture/contract slice.

## Step 2 - Coordinator route-time settlement snapshot

Date: 2026-07-01

What landed:

- Durable `settlement_route_snapshots` table in the coordinator billing DB,
  keyed by `(account_scope, request_id, attempt_n, provider_id)` and storing
  both `route_snapshot_digest` and canonical JSON.
- Production JCS helper in `phase4-coordinator/internal/billing/jcs.go` used
  for route snapshot digests and coordinator prompt hashes.
- Strict `billing.RouteSnapshot` model with §N.2 fields only, validation, and
  digest computation.
- Tier-2 catalog snapshot material for route-time settlement evidence:
  expected model hash, signed catalog body digest, signature key id, signature
  pubkey fingerprint, catalog expiry, and SPEC-008 hash status.
- Buyer dispatch hook records a route snapshot after provider-specific model
  rewrite succeeds and before HTTP, WS, or streaming provider dispatch.
- Snapshot `attempt_n` is a zero-based provider-dispatch ordinal, independent
  from request-log write timing, so retry/failover attempts increment exactly
  once per provider dispatch.
- Coordinator prompt hash basis is `coordinator_prompt_canonical_v1`, computed
  from the post-rewrite provider-bound request body so alias/model-class routes
  hash the same prompt material the provider receives. The canonicalizer mirrors
  the provider prompt canonicalizer shape for model/messages/tools/options,
  including raw-string treatment for tool-call arguments and ECMAScript number
  rendering thresholds for decimal options.

Scope boundary:

- This step does not enforce SPEC-022 buyer final debit, provider-positive
  settlement, payout readiness, or gateway money movement.
- Legacy routes without a published provider receipt key or without active
  catalog material continue through the existing path; receipt/catalog-capable
  covered routes fail closed if snapshot construction or persistence fails
  before dispatch.
- `provider_generation_id` is currently `null` because the coordinator pool
  does not expose a generation id yet; `provider_session_id` is the provider
  assigned session id.
- `provider_receipt_key_source` is currently fixed to `auth_session` because
  the provider pool has no rotation-grace/operator-pin provenance field yet.
- `route_snapshot_policy_version` is `spec022-prereq-v0` and
  `route_snapshot_mode` is `observe` until SPEC-022 policy config lands.

Validation:

| Command | Result |
|---|---|
| `cd phase4-coordinator && go test ./internal/billing ./internal/tier2 ./internal/buyer` | PASS |
| `cd phase4-coordinator && go test ./...` | PASS |

Audit fixes before closure:

- HIGH: prompt hash originally used pre-rewrite buyer request JSON. Fixed by
  hashing the provider-rewritten dispatch body and adding alias-route test
  coverage that rejects the buyer alias hash.
- HIGH: `catalog_signature_pubkey_fingerprint` originally persisted bare
  64-hex. Fixed to `ed25519-sha256:<64 lowercase hex>` across catalog material,
  validation, schema, and tests.
- MEDIUM: route snapshot catalog fields and SPEC-008 hash status could be read
  from different catalog states. Fixed by computing snapshot material and hash
  status from one locked catalog state.
- HIGH: JCS number rendering used Go shortest formatting directly, producing
  values such as `1e-06` where provider-side ECMAScript/JSON.stringify style
  canonicalization emits `0.000001`. Fixed with ECMAScript threshold rendering
  and decimal prompt-option regression coverage.

Focused test coverage:

- `TestRouteSnapshotStrictKeysAndDigestSensitivity` verifies the exact §N.2
  key set and proves mutating every route-validity field changes the digest.
- `TestInsertRouteSnapshotPersistsCanonicalDigestAndRejectsRewrite` verifies
  persisted canonical digest and rejects immutable-key rewrite attempts.
- `TestRouteSnapshotsPersistBeforeDispatchAndRetryAttempts` verifies the first
  upstream observes its snapshot already committed before dispatch and that
  retry snapshots are attempts `0` and `1`. It also covers decimal prompt
  options in the stored post-rewrite prompt hash.
- `TestCanonicalJSONNumberFormattingMatchesECMAScriptThresholds` locks the
  direct coordinator JCS behavior for `1e-7`, `1e-6`, `1e20`, `1e21`, and
  negative fractional values.

Stop condition:

- Step 2 implementation is ready for the five required Step 2 audit lanes.

## Step 3 - Terminal-state, output, and usage canonicalization

Date: 2026-07-01

What landed:

- Durable `settlement_attempt_outputs` table in the coordinator billing DB,
  keyed by `(account_scope, request_id, attempt_n, provider_id)` and storing
  `terminal_state`, `terminal_state_ts_unix_ms`, half-open output byte range,
  `output_hash`, strict usage canonical JSON, `usage_hash`, `usage_source`,
  `output_available`, and an `overlapping_or_duplicate` marker. Step 4 audit
  closure removed raw `settlement_output_v1` canonical JSON persistence; the
  table keeps the scalar evidence and hash needed for settlement binding, not
  buyer-visible output bodies.
- Strict `billing.SettlementOutput` and `billing.SettlementUsage` models with
  canonical digest helpers. Output hashes are
  `sha256(UTF-8(JCS(settlement_output_v1)))`; usage hashes are computed over
  the strict usage object.
- Terminal-state reconstruction for `normal_done`, `provider_error`,
  `buyer_cancel`, `gateway_timeout`, and `upstream_transport_disconnect`.
- Non-streaming OpenAI response reconstruction from
  `choices[0].message.content`, `choices[0].finish_reason`, and function tool
  calls before evidence is persisted.
- Streaming SSE reconstruction that observes standard OpenAI `data:` frames,
  accumulates buyer-visible `delta.content`, finish reason, and complete
  streamed tool-call fragments, while leaving client-facing SSE unchanged. A
  non-empty `data:` frame that is not JSON, malformed JSON, or an incomplete
  tool-call accumulator makes output evidence unavailable instead of producing
  a forged strict output hash.
- Streaming `normal_done` evidence latches `terminal_state_ts_unix_ms` at the
  observed `data: [DONE]` terminal signal. Later non-empty `data:` frames are
  rejected as malformed settlement evidence rather than appended to the output
  prefix.
- HTTP and WS attempt hooks now attach settlement output evidence for normal
  completion, provider failures, retry/failover, committed stream disconnects,
  and timeout/error terminal states.
- WS non-streaming success persists the settlement attempt output before
  exposing the receipt-bearing 200 response to the buyer. HTTP non-streaming
  already followed this order; streaming committed paths cannot retract bytes
  already sent to the buyer, but malformed terminal evidence is persisted as
  unavailable provider-error evidence instead of available empty output.
- Usage evidence is byte-estimated from coordinator-observed delivered output
  bytes when token usage is unavailable; those rows persist observed output
  estimates but keep billable input/output tokens at zero. Step 4 later added
  the stronger `coordinator_observed` path for provider-returned token usage
  that the coordinator saw directly on the response. Provider-only usage is
  still not settlement-capable without that coordinator-side observation and
  verifier cross-check.
- Unavailable output evidence is durable, not skipped: rows persist
  `output_available=0`, a valid terminal state, terminal-state timestamp, zero
  delivered bytes, and nullable output hash. These rows are pending/quarantine
  evidence for later SPEC-022 policy, not signed catalog-matching receipts.
- Transparent failover persists one attempted-provider output prefix row per
  logged attempt. Duplicate or overlapping output byte ranges for a request are
  marked as non-creditable evidence for later SPEC-022 consumption.
- Settlement output `attempt_n` is aligned to the provider-dispatch ordinal
  captured by route snapshots, so WS failover-before-first-chunk cannot make
  route snapshot and output evidence disagree on `(request_id, attempt_n,
  provider_id)`.

Scope boundary:

- This step still does not wire SPEC-022 enforce-mode buyer final debit,
  provider-positive settlement, payout readiness, or gateway money movement.
- The coordinator is the Step 3 evidence owner. Gateway client-facing streaming
  remains OpenAI-compatible; no receipt-only SSE frames or non-standard `event:`
  records were added.
- Provider-side v0.4 receipt signing/verification is not complete in this
  step. The output/usage evidence here is the prerequisite that later receipt
  ingestion and SPEC-022 settlement logic must bind to the signed tuple.
- Partial streaming tool-call fragments are only included when complete enough
  to satisfy strict `settlement_output_v1` validation; incomplete fragments on
  terminal errors force unavailable output evidence and do not make the row
  settlement-capable.

Validation:

| Command | Result |
|---|---|
| `cd phase4-coordinator && go test ./internal/billing ./internal/tier2 ./internal/buyer` | PASS |
| `cd phase4-coordinator && go test ./...` | PASS |

Focused test coverage:

- `TestSettlementOutputStrictKeysAndDigestSensitivity` verifies the exact
  strict output key set and digest sensitivity.
- `TestSettlementUsageStrictKeysAndDeliveredBytes` verifies strict usage keys,
  delivered-byte linkage, and usage canonicalization.
- `TestInsertSettlementAttemptOutputPersistsAndRejectsRewrite` verifies
  persisted canonical hashes and immutable conflict behavior.
- `TestInsertSettlementAttemptOutputMarksOverlap` verifies duplicate/overlap
  marking for output byte ranges.
- `TestRouteSnapshotsPersistBeforeDispatchAndRetryAttempts` now verifies retry
  output rows: failed attempt `0` persists an empty `provider_error` prefix and
  successful attempt `1` persists a normal prefix with byte-estimated usage.
- `TestStreamingSettlementOutputPersistsOpenAICompatibleSSE` verifies standard
  OpenAI-compatible streaming SSE is relayed unchanged while strict settlement
  output evidence stores the output hash, range `[0,5)`, `normal_done`, and
  byte-estimated usage without persisting raw output JSON.
- `TestMalformedNonStreamingOutputPersistsUnavailableEvidence` verifies a
  malformed 200 response is forwarded to the buyer but persists
  `output_available=0` with no output hash.
- `TestTerminalStateFromAttemptCoversReceiptTerminalStates` verifies
  `buyer_cancel`, `gateway_timeout`, `provider_error`, and `normal_done`
  reconstruction.
- `TestSettlementStreamOutputQuarantinesIncompleteToolCall` verifies incomplete
  streamed tool-call evidence preserves the observed terminal state while
  remaining unavailable for settlement hashing.
- `TestSettlementStreamOutputLatchesDoneAndRejectsPostDoneData` verifies
  `[DONE]` timestamps normal streaming completion and rejects post-terminal
  `data:` frames.

Stop condition:

- Step 3 implementation is ready for the five required Step 3 audit lanes.

## Step 4 - Verifier support and settlement mapping

Date: 2026-07-01

What landed:

- `phase7-verify/internal/verify` now has a v0.4 settlement verifier API that
  parses strict `receipt_version: "4"` tuples, verifies the Ed25519 signature
  against the route-snapshot-pinned receipt key, and maps verifier results to
  SPEC-015 §N.8 settlement outcomes.
- `phase4-coordinator/internal/billing` now has a module-local settlement
  verifier with the same fixture-locked semantics. It uses the coordinator
  `RouteSnapshot` model and digest helper directly, avoiding imports from
  `phase7-verify/internal/*`.
- The verifier checks request/attempt/account/provider/key binding, route
  snapshot digest, route policy version/mode, three-way model hash equality,
  prompt hash, output hash, output prefix range, usage, terminal state,
  terminal timestamp, receipt issuance window, and receipt deadline.
- `verified` and `zero_settled` now require an independent coordinator/gateway
  usage cross-check: the signed tuple usage must exactly match the expected
  ledger usage object, `UsageCrossChecked` must be true, and the usage source
  must be `coordinator_observed`. Provider-signed usage alone, byte-estimated
  usage, or mismatched usage maps to `quarantined`.
- The verifier consumes ledger state needed to keep cryptographically valid
  receipts non-payable when they are not settlement-eligible:
  `OverlappingOrDuplicate` maps to `quarantined` with
  `overlapping_output_prefix`, and `TerminalOutcomeFinal` maps to
  `duplicate_receipt_after_terminal`.
- Verifier results now include sanitized parsed receipt facts and verification
  checks for Step 5 ingestion. Facts include scalar digests, ids, hashes,
  timestamps, terminal state, and tuple canonical digest, but not raw receipt
  envelopes, signatures, raw public keys, prompts, outputs, tokens, private
  keys, or provider-private state. Facts also expose the signed receipt usage
  digest, and checks are populated progressively so invalid/quarantined results
  can still tell Step 5 which gates were reached without reparsing a raw
  receipt.
- Settlement output persistence now retains only scalar evidence and hashes.
  The coordinator computes `output_hash` from strict `settlement_output_v1`
  bytes and intentionally stores `NULL` for raw canonical output JSON in the
  settlement table.
- `settlement_attempt_outputs` is account-scoped. Overlap/duplicate detection
  and immutable conflicts use `(account_scope, request_id, attempt_n,
  provider_id)`, preventing cross-account request-id collisions from poisoning
  settlement evidence.
- Duplicate zero-byte tool-call outputs are marked non-creditable by matching
  `output_hash` even when byte ranges do not overlap.
- Coordinator attempt rows with token usage observed directly on the upstream
  response can now use `usage_source: "coordinator_observed"` and verify.
  Byte-estimated rows remain non-settlement-capable.
- `phase7-verify` route snapshots now validate required fields, digest shapes,
  receipt-key fingerprint shape, timestamp bounds, and deadline positivity
  before computing the snapshot digest.
- Negative shared fixtures now lock public failure reasons through
  `expected_failure`, including strict-shape, usage-shape, wrong-key,
  legacy-version, terminal out-of-enum, and mismatch vectors.
- Non-normal partial-prefix settlements allow zero billable tokens when
  delivered bytes are positive, as long as billable usage remains within the
  independently observed usage bounds.
- Historical receipt versions (`"1"`, `"2"`, `"3"` or absent
  `receipt_version`) are `not_settlement_capable` for settlement. Unknown
  future versions, including `"10"`, are `inconclusive:
  unknown_receipt_version` and cannot produce `verified` or `zero_settled`.
- Missing receipts and trust-root inconclusive rows remain `pending` before
  the route snapshot deadline and become `quarantined` after the deadline.
- Non-creditable terminal rows with verified zero delivered bytes map to
  `zero_settled`; chargeable verified rows map to `verified`; every invalid,
  mismatched, wrong-key, wrong-snapshot, wrong-terminal, wrong-attempt,
  malformed-shape, or insufficient-binding vector maps to `quarantined`.

Scope boundary:

- This step still does not add receipt ingestion/storage state transitions,
  buyer final debit, provider-positive settlement, payout readiness, or
  SPEC-022 enforce activation.
- Raw receipt envelopes are test inputs only. The verifier result type carries
  outcome, receipt-result class, reason, and receipt version; it does not
  expose raw signatures, raw receipt public keys, prompts, outputs, or bearer
  material.
- `phase7-verify` keeps the existing v0.3 CLI verifier behavior: a v0.3
  verifier reading a v0.4 receipt still reports unknown receipt version through
  the historical tri-state path. The new settlement API is explicit and
  separate.

Validation:

| Command | Result |
|---|---|
| `cd phase7-verify && go test ./internal/verify -run Settlement -count=1 -v` | PASS |
| `cd phase7-verify && go test ./...` | PASS |
| `cd phase4-coordinator && go test ./internal/billing -run 'Settlement\|RouteSnapshot' -count=1 -v` | PASS |
| `cd phase4-coordinator && go test ./internal/buyer -run 'RouteSnapshot\|Settlement' -count=1 -v` | PASS |
| `cd phase4-coordinator && go test ./internal/billing ./internal/tier2 ./internal/buyer` | PASS |
| `cd phase4-coordinator && go test ./...` | PASS |
| `git diff --check` | PASS |

Focused test coverage:

- Positive shared v0.4 receipt fixtures prove `verified` versus
  `zero_settled` across the §N.7 terminal-state matrix.
- Negative fixture vectors prove output-hash mismatch, route digest mismatch,
  model-hash mismatch, terminal-state mismatch/out-of-enum, attempt mismatch,
  wrong-key signature, legacy receipt version, strict tuple-shape failures,
  usage null/missing/extra/negative fields, and delivered-byte mismatch all
  quarantine.
- Deadline tests prove missing receipts map `pending` before deadline and
  `quarantined` after deadline.
- Replay tests prove a valid signed receipt cannot be replayed onto a
  different account, request, attempt, provider, receipt key, route snapshot,
  terminal state, terminal timestamp, or timestamp window.
- Ledger-state tests prove valid signed receipts quarantine when usage is not
  cross-checked, usage comes from `byte_estimated`, expected usage mismatches,
  output prefixes overlap/duplicate, or the terminal outcome is already final.
- Coordinator-observed row tests prove token-bearing upstream responses can
  produce settlement-capable usage evidence, while byte-estimated rows remain
  quarantined for settlement.
- Persistence tests prove raw output canonical JSON is not retained, lowercase
  64-hex digests are enforced, account scope isolates request-id collisions,
  and duplicate zero-byte output hashes mark the later row overlapping.
- Partial-prefix tests prove non-normal terminal receipts can settle zero
  billable tokens without requiring strictly positive billable usage.
- Phase7 route snapshot tests prove invalid route snapshot inputs are rejected
  before digest comparison.
- Unknown-future-version tests prove `"10"` is inconclusive and not payable,
  avoiding lexical version-order bugs.

Audit fixes before closure:

- CRITICAL/HIGH: provider-signed usage could previously drive `verified`
  without coordinator/gateway usage authority. Fixed by adding expected usage,
  usage source, and cross-check inputs to both verifier implementations, and
  by quarantining missing, byte-estimated, or mismatched usage evidence.
- HIGH/MEDIUM: overlap/duplicate output ranges and already-terminal rows were
  not part of the Step 4 verifier API. Fixed with explicit ledger-state inputs
  and non-payable reasons.
- HIGH: Step 5 would have needed to reparse raw receipts to persist §N.9
  verifier-safe fields. Fixed by adding sanitized parsed facts and check
  booleans to the verifier result.
- MEDIUM: replay coverage only covered one or two dimensions. Fixed with
  table-driven trust-boundary mutations in both module-local test suites.
- LOW: SQLite fingerprint CHECK constraints used a weak `GLOB` expression.
  Fixed by checking prefix, length, and rejecting non-hex suffix bytes.
- HIGH: settlement outputs initially persisted raw canonical output JSON.
  Fixed by making output hashes transiently computable and storing `NULL` for
  the raw canonical output column.
- HIGH/MEDIUM: route/output digest database constraints allowed non-hex bytes
  and usage facts did not carry a sanitized digest. Fixed with lower-hex
  `CHECK` constraints, receipt-side `usage_digest`, and progressive check
  reporting.
- HIGH: coordinator rows never became settlement-capable because all usage was
  byte-estimated. Fixed by recording token-present upstream responses as
  `coordinator_observed` while keeping byte-estimated rows non-capable.
- HIGH: settlement output rows were not account-scoped. Fixed by threading
  account scope through persistence, uniqueness, immutable conflicts, and
  overlap queries.
- MEDIUM: zero-byte tool-call outputs could bypass overlap marking. Fixed by
  treating duplicate output hashes as duplicate evidence even when ranges are
  empty.
- MEDIUM: negative fixture reason semantics and terminal out-of-enum ordering
  were not stable enough. Fixed with `expected_failure` assertions and
  terminal enum validation before ledger-state terminal mismatch.
- MEDIUM: partial-prefix non-normal terminals incorrectly required positive
  billable tokens. Fixed by allowing zero billable tokens within observed
  usage bounds.
- MEDIUM: `phase7-verify` route snapshot digests initially accepted invalid
  snapshot structures. Fixed by adding local snapshot validation before digest.

Final Step 4 auditor status:

| Lane | Final status |
|---|---|
| Codex code | CRITICAL=0 / HIGH=0 / MEDIUM=0 |
| Codex security | CRITICAL=0 / HIGH=0 / MEDIUM=0 |
| Codex architect | CRITICAL=0 / HIGH=0 / MEDIUM=0 |
| Claude adversarial/product | Deferred until full implementation, per operator instruction |

Stop condition:

- Step 4 implementation is closed for the three required Codex audit lanes:
  code, security, and architect are all at 0 critical / 0 high / 0 medium.
  Claude lanes are intentionally deferred until the full implementation lands.
  The branch is ready to continue with Step 5.

## Step 5 - Coordinator receipt ingestion, storage, and verdict state

Date: 2026-07-01

What landed:

- `phase4-coordinator/internal/billing` now has a coordinator-internal
  settlement receipt ingestion API:
  `IngestSettlementReceipt` for v0.4 receipt headers and
  `RecordMissingSettlementReceipt` for deadline-driven missing-receipt
  verdicts. `GetSettlementReceiptAuthorization` exposes a redacted durable
  positive-settlement-candidate view intended for later SPEC-022 settlement
  code; it deliberately does not claim final money `Payable` authority.
- A durable `settlement_receipt_verdicts` table stores one parsed/verifier-safe
  state row keyed by `(account_scope, request_id, attempt_n, provider_id)`.
  It records receipt version/result, settlement outcome/reason,
  idempotency status, terminal state/timestamp, deadline basis, received
  timestamp, route snapshot digest/policy/mode, paid entrypoint, optional
  provider session/generation IDs, route-time hash status, receipt-key
  fingerprint, catalog/model/prompt/output/usage digests, Step 5 no-money
  movement outcomes, verifier checks, diagnostics, and sanitized facts.
- First-terminal receipt selection is enforced by the state machine. Once a row
  reaches `verified`, `quarantined`, or `zero_settled`, later receipts for the
  same attempt return the existing terminal state as `terminal_noop` and cannot
  rewrite the closed outcome.
- Pending missing-receipt rows can transition to `verified` when a valid
  receipt arrives before the route snapshot deadline, or to `quarantined` when
  the deadline elapses.
- Late receipt behavior is based on coordinator-stamped receipt-received time:
  `received_at_unix_ms > terminal_state_ts_unix_ms +
  pending_deadline_seconds*1000` quarantines with `receipt_after_deadline`.
  Provider `issued_at_unix_ms` and external callers cannot extend the
  settlement deadline. Tests use the store clock seam rather than a public
  ingestion timestamp.
- Receipt ingestion loads route snapshots and settlement attempt output rows
  from coordinator evidence, then calls the Step 4 verifier. The verifier
  remains the only code path that maps receipt material to `verified`,
  `zero_settled`, `pending`, or `quarantined`.
- Verdict rows and audit payloads keep coordinator-authoritative
  model/output/usage evidence. Provider-signed receipt facts stay confined to
  `facts_json` and the explicitly receipt-scoped tuple digest diagnostic.
- `GetSettlementReceiptAuthorization` rejoins the current attempt-output row
  before reporting positive candidate status, so later overlap/duplicate
  backfill can suppress SPEC-022 candidate evidence even if a receipt verdict
  was previously verified.
- Route snapshot validation and database checks now constrain
  `route_snapshot_mode` to `observe|enforce`; pending receipt deadlines are
  capped at 900 seconds in config, route validation, and schema checks.
- Audit events `settlement_receipt_ingested` and
  `settlement_receipt_verdict` are inserted in the same transaction as verdict
  state. Payloads contain only redacted scalar fields and verifier checks.
  Account scope is represented as `account_scope_hash`, not raw
  `account_scope`.
- Raw receipt headers, raw signatures, raw receipt public keys, raw prompts,
  raw outputs, bearer tokens, private keys, and provider-private material are
  not persisted in verdict rows or audit payloads.

Scope boundary:

- Step 5 still does not create buyer final debit, provider-positive settlement,
  `ledger_payout_ready` rows, gateway money movement, or SPEC-022 enforce-mode
  activation.
- No provider submission endpoint is added in this step. Step 6 will wire the
  provider-side v0.4 receipt emission/submission path into the internal
  ingestion API.
- The billing store expects the shared `audit_log` table to exist, matching
  existing quarantine/admin audit behavior. If audit insertion fails, verdict
  state insertion rolls back with it.

Validation:

| Command | Result |
|---|---|
| `cd phase4-coordinator && go test ./internal/billing -run 'SettlementReceipt\|Settlement\|RouteSnapshot' -count=1 -v` | PASS |
| `cd phase4-coordinator && go test ./internal/billing ./internal/tier2 ./internal/buyer ./internal/config` | PASS |
| `cd phase4-coordinator && go test ./...` | PASS |
| `git diff --check` | PASS |

Focused test coverage:

- `TestIngestSettlementReceiptPersistsVerifiedStateAndRedactedAudit` proves a
  valid v0.4 receipt persists a terminal `verified` verdict, emits ingested and
  verdict audit events, omits raw receipt/key material, and does not create
  ledger request credits, operator credits, or payout-ready rows.
- `TestRecordMissingSettlementReceiptQuarantinesAfterDeadlineAndLateReceiptNoops`
  proves missing receipts remain `pending` before deadline, become terminal
  `quarantined` after deadline, and a later valid receipt cannot resurrect the
  row.
- `TestSettlementReceiptPendingCanCloseWithValidReceiptBeforeDeadline` proves a
  pending missing-receipt row can close as `verified` when a valid receipt
  arrives before deadline.
- `TestSettlementReceiptReceivedAfterDeadlineQuarantinesEvenWithValidHeader`
  proves receipt-received timestamp, not provider-issued timestamp, controls
  late receipt quarantine.
- `TestSettlementReceiptResubmissionCannotChangeClosedOutcome` proves
  resubmission with a different receipt after terminal selection is a no-op
  and leaves the original positive authorization unchanged.
- `TestSettlementReceiptRejectsCallerControlledReceiveTime` proves public
  ingestion callers cannot backdate receipt arrival to bypass the deadline.
- `TestSettlementReceiptPersistsCoordinatorEvidenceForMismatchedSignedReceipt`
  proves signed but mismatched receipt facts cannot overwrite coordinator
  model/output/usage evidence in verdict rows or audit payloads.
- `TestSettlementReceiptAuthorizationRejectsLaterOverlapBackfill` proves the
  authorization API refuses positive candidate status when current
  attempt-output evidence has since been marked overlapping or duplicate.
- `TestRouteSnapshotRejectsInvalidModeAndDeadline` and config validation tests
  prove route mode and pending-deadline policy bounds are enforced before
  settlement authorization.

Audit fixes before closure:

- CODE-M1: `settlement_receipt_verdict` audit payloads lacked SPEC-022 R-11
  structured verdict fields. Fixed by persisting and emitting paid entrypoint,
  route policy/mode, provider session/generation, hash status, receipt profile,
  receipt result, buyer/provider/payout no-money outcomes, and related
  catalog/model evidence.
- SECURITY-H1: provider-controlled receipt facts could overwrite
  coordinator-authoritative model/output/usage fields. Fixed by sourcing those
  fields only from route/output evidence and by storing receipt tuple facts only
  as receipt-scoped diagnostics.
- ARCH-H1: SPEC-022 consumers had no durable read/authorization API. Fixed with
  `GetSettlementReceiptAuthorization`.
- ARCH-H2: receipt deadlines trusted a public caller-supplied receive time.
  Fixed by coordinator-stamping receipt arrival through the store clock.
- ARCH-H3: previously verified receipts could remain payable after later
  overlap backfill. Fixed by rejoining current attempt-output state in the
  authorization API.
- ARCH-H4 / ARCH-M1: deadline and route mode policy bounds were not enforced.
  Fixed with config, validation, and schema constraints.
- SECURITY-M1: audit payloads exposed raw `account_scope`. Fixed by emitting a
  stable `account_scope_hash` and testing that the raw account field is absent.
- SECURITY-M2 / ARCH-M1: terminal duplicate/late no-op verdict audit events
  omitted verdict fields when no verifier checks were available. Fixed by
  always emitting receipt result, settlement outcome, reason, deadline,
  idempotency status, Step 5 money outcomes, and
  `attempted_received_at_unix_ms` on verdict audit events.
- ARCH-H1 rerun: `GetSettlementReceiptAuthorization` exposed `Payable=true`
  before SPEC-022 policy and ledger idempotency own final money authorization.
  Fixed by renaming the API surface to `PositiveSettlementCandidate` /
  `CandidateBlockedReason`.

Stop condition:

- Step 5 implementation is closed for the three required Codex audit lanes:
  code, security, and architect are all at 0 critical / 0 high / 0 medium.
  Claude lanes remain deferred until the full implementation lands.

## Step 6 - Provider v0.4 receipt issuance

Implementation summary:

- Coordinator WS dispatch now attaches settlement metadata to provider
  `inference_request` frames when a Step 2 route snapshot and receipt key are
  available. The metadata contains the §N.1 route/catalog/prompt/deadline
  inputs required for signing and intentionally excludes raw buyer credentials,
  bearer tokens, prompts, and request bodies.
- Tier2 encrypted dispatch keeps the buyer request body encrypted while
  carrying the settlement metadata as route-time control metadata. Relay tests
  assert the encrypted body does not expose prompt/body content and the
  metadata contains no credential-looking material.
- Swift provider relay parses settlement metadata, rejects mismatched request
  or provider identities, and signs v0.4 settlement receipts only when the
  served request-start model hash is a non-null 64-character lowercase hex hash
  matching `expected_catalog_model_hash`.
- Direct HTTP dispatch now carries the same settlement metadata in
  `X-MacProvider-Settlement-Metadata`; Swift HTTP serving parses it, validates
  request/provider/model/hash binding, and emits v0.4 receipts for
  non-streaming `normal_done` responses.
- Direct HTTP streaming emits settlement receipts as HTTP trailers so
  OpenAI-compatible SSE body bytes remain unchanged. The coordinator reads
  provider trailers after incremental EOF and after buffered/downgrade body
  drain, then ingests `X-MacProvider-Receipt` through the same Step 5 internal
  path.
- `ReceiptBuilder.buildSettlement` emits the strict SPEC-015 §N.1 tuple with
  `receipt_version: "4"` and `signature_key_alg: "Ed25519"`, checks the
  `ed25519-sha256:<hex>` receipt-key fingerprint against the active signing
  key, canonicalizes the settlement output/usage tuple with RFC8785 JCS, and
  fails closed on integer overflow.
- Non-streaming and streaming successful terminal paths include the signed
  receipt on `inference_response_end`, along with
  `terminal_state_ts_unix_ms`, `receipt_pending_deadline_seconds`, and
  `late_receipt_settlement: "not_settled"`.
- Coordinator WS end-frame parsing preserves the deadline/non-settlement
  markers and terminal timestamp, records the coordinator-observed settlement
  output, and ingests the returned receipt through the Step 5 internal
  `IngestSettlementReceipt` path after the attempt row is durably recorded.
- Settlement route-snapshot creation is opt-in for v0.4-capable providers only:
  a provider must have a usable receipt key, an exact lowercase 64-hex
  `model_hash`, verified Tier2 catalog snapshot material, and equality between
  provider-reported hash and expected catalog hash. Missing, mismatched,
  unverified, or uppercase hashes continue through legacy/non-settlement paths
  without route-snapshot metadata.
- Cancellation/error terminal states still produce coordinator terminal/output
  evidence, but the provider does not issue a positive v0.4 settlement receipt
  for unsuccessful terminal paths in this step.

Validation:

| Command | Result |
|---|---|
| `swift test --package-path phase3-binary --filter InferenceRelayTests` | PASS |
| `swift test --package-path phase3-binary --filter ReceiptBuilderTests` | PASS |
| `swift test --package-path phase3-binary --filter HTTPServerReceiptTests` | PASS |
| `swift test --package-path phase3-binary --filter 'HTTPServerReceiptTests\|ReceiptBuilderTests\|InferenceRelayTests'` | PASS, 49 tests |
| `swift test --package-path phase3-binary --filter SPEC015V04SettlementFixtureTests` | PASS, 8 tests |
| `cd phase4-coordinator && go test ./internal/buyer ./internal/ws ./internal/billing ./internal/tier2 ./internal/config -count=1` | PASS |
| `cd phase4-coordinator && go test ./...` | PASS |
| `git diff --check` | PASS |

Focused test coverage:

- `testBuildSettlementSignsStrictV04Tuple` proves the Swift builder signs the
  strict §N.1 field set with `receipt_version: "4"`, `Ed25519`, matching model
  hash/catalog hash, canonical output hash, and self-verifying signature.
- `testBuildSettlementRejectsWrongReceiptKeyID` proves provider-supplied route
  metadata cannot bind a receipt to a different signing key fingerprint.
- `testRelayNonStreamingEndFrameCarriesV04SettlementReceipt` proves the provider
  non-streaming relay returns a signed v0.4 receipt, deadline basis,
  late-receipt non-settlement disclosure, and a terminal timestamp matching the
  signed tuple.
- `testRelayRejectsSettlementMetadataForDifferentRequest` proves mismatched
  settlement route metadata is rejected before inference starts.
- `testHTTPNonStreamingHandlerWritesV04SettlementReceipt` proves direct HTTP
  non-streaming v0.4 receipt issuance and deadline/non-settlement headers.
- `testHTTPStreamingHandlerWritesV04SettlementReceiptTrailerWithWarmSwapDisabled` proves direct
  HTTP streaming v0.4 receipt trailers without changing the SSE body.
- `TestRouteSnapshotSkippedForUppercaseModelHash` proves non-lowercase
  provider hashes cannot be repaired into settlement eligibility.
- `TestRelayDispatchCarriesSettlementMetadata` proves the coordinator sends
  settlement metadata on plaintext provider dispatch.
- `TestEncryptedRelayDispatchCarriesSettlementMetadataOutsideBody` proves Tier2
  dispatch keeps body/prompt content encrypted while carrying only route
  settlement metadata.
- `TestInferenceResponseEndPreservesSettlementReceiptDeadline` proves the Go
  coordinator end-frame schema preserves deadline and non-settlement markers
  emitted by the provider.

Scope boundary:

- Step 6 does not wire SPEC-022 enforce-mode buyer final debit, provider-positive
  credit, payout readiness, or gateway money movement.
- Claude adversarial/product lanes remain deferred until the full implementation
  lands, per the updated user instruction. Step 6 will use only the Codex code,
  security, and architect lanes.

Audit closure:

- Codex code: 0 critical / 0 high / 0 medium.
- Codex security: 0 critical / 0 high / 0 medium.
- Codex architect: 0 critical / 0 high / 0 medium.

## Step 7 - Product disclosures and operator diagnostics

Implementation summary:

- Buyer-facing `/v1/models tier1_disclosure` now includes
  `model_verification_limit`, stating that v0.4 settlement receipts verify the
  provider-reported request-start model hash against the route-time catalog
  snapshot and do not detect a provider falsifying its own loaded-model hash
  measurement.
- The account page, docs markdown, frontdoor console disclosure, and
  SPEC-006 v0.9.4 §1.6 / §5.3.1 carry the same model-verification caveat so
  buyer/product surfaces do not imply malicious-provider detection.
- Provider earnings responses now expose a `settlement_receipts` summary with
  v0.4 profile, verified/zero-settled/failed/pending counts, recent failed
  receipt reason codes, and explicit diagnostics window bounds. The summary is
  provider-token scoped through the existing `/providers/{id}/earnings`
  authorization path.
- Operator `/admin/ledger/providers` responses now include the same redacted
  settlement receipt summary for each listed provider. Diagnostics show reason
  codes plus route policy/mode, paid entrypoint, SPEC-008 hash status,
  provider-reported and expected model hashes, route/catalog/model/prompt/output
  /usage digests, and receipt-key fingerprints. They do not expose raw receipt
  public keys, raw signatures, raw envelopes, raw prompts, raw outputs, bearer
  tokens, receipt private keys, account scopes, or provider-private state.
- Settlement receipt diagnostics queries are indexed by provider and recent
  receive time. Provider/admin summaries use a bounded 31-day default
  diagnostics window when no earnings range is supplied, recent-failure lookup
  is backed by a partial closed-quarantined index, and handlers explicitly
  close SQLite cursors before issuing downstream diagnostics queries to preserve
  the repo's `MaxOpenConns(1)` test invariant.

Validation:

| Command | Result |
|---|---|
| `cd phase4-coordinator && go test ./internal/billing -run 'TestEarningsEndpointIncludesProviderSettlementReceiptReasonCodes\|TestProvidersEndpointIncludesRedactedSettlementReceiptDiagnostics\|TestProvidersEndpoint_CursorStartsAfterLastEmittedProvider\|TestSettlementReceiptDiagnosticsQueryShapeIsBounded' -count=1 -timeout 60s -v` | PASS |
| `cd phase4-coordinator && go test ./internal/billing -run TestProvidersEndpoint_CursorStartsAfterLastEmittedProvider -count=1 -timeout 30s -v` | PASS |
| `cd phase4-coordinator && go test ./internal/billing -count=1 -timeout 180s` | PASS |
| `cd phase4-coordinator && go test ./... -count=1` | PASS |
| `cd phase5-gateway && go test ./internal/router -run 'TestModelsResponseIncludesTier1Disclosure\|TestTier1DisclosureMatchesSpecSection16' -count=1 -timeout 60s -v` | PASS |
| `cd phase5-gateway && go test ./internal/router -count=1 -timeout 120s` | PASS |
| `cd phase5-gateway && go test ./... -count=1` | PASS |
| `git diff --check` | PASS |

Focused test coverage:

- `TestModelsResponseIncludesTier1Disclosure` proves the gateway replaces any
  upstream disclosure with the local truthful model-verification limit.
- `TestTier1DisclosureMatchesSpecSection16` proves account, docs, console, and
  SPEC-006 disclosure text stay in parity.
- `TestEarningsEndpointIncludesProviderSettlementReceiptReasonCodes` proves a
  provider-token-scoped earnings response exposes the persisted v0.4 rejection
  reason code, route-policy/hash context, zero-settled vs failed vs pending
  counters, and does not leak raw receipt/public-key/account material.
- `TestProvidersEndpointIncludesRedactedSettlementReceiptDiagnostics` proves
  operator diagnostics include reason codes, route-policy/hash context,
  digests, and fingerprints while omitting raw receipt/public-key/account
  material.
- `TestProvidersEndpoint_CursorStartsAfterLastEmittedProvider` caught and now
  locks the cursor-close ordering needed before diagnostics queries run on the
  provider-list path.
- `TestSettlementReceiptDiagnosticsQueryShapeIsBounded` prevents reintroducing
  an unbounded window-ranking query shape and checks the partial failed-receipt
  diagnostics index.

Scope boundary:

- Step 7 does not authorize SPEC-022 money movement, provider payout readiness,
  or buyer debit finality. It surfaces the existing Step 5/6 v0.4 receipt
  verdicts and product caveats only.
- Claude adversarial/product lanes remain deferred until the full
  implementation lands, per the updated user instruction. Step 7 will use only
  the Codex code, security, and architect lanes.

Audit closure:

- Codex code: 0 critical / 0 high / 0 medium. One low stale SPEC-006
  property-number reference was fixed locally; the lane was not re-fired
  because the C/H/M gate was already clean.
- Codex security: 0 critical / 0 high / 0 medium / 0 low after rerun.
- Codex architect: 0 critical / 0 high / 0 medium / 0 low after rerun.
- Claude adversarial and product-design lanes remain deferred until the full
  implementation lands, per the updated user instruction.

## Step 8 - Integration acceptance

Implementation summary:

- Added `TestSPEC015V04AcceptanceCriteria` in coordinator billing as the
  consolidated AC-43 through AC-71 acceptance gate. The test reuses the shared
  v0.4 settlement fixture corpus, verifier inputs, store seeding helpers, and
  Step 7 disclosure files instead of inventing a second fixture set.
- Added `scripts/verify-spec015-v04-step8.sh` as the executable Step 8
  integration target. It runs exact named tests across provider Swift receipt
  issuance, coordinator route/output/verdict handling, gateway buyer
  disclosures/header boundaries, and the independent phase7 verifier fixtures.
- The test fails if any SPEC-015 v0.4 acceptance criterion AC-43 through AC-71
  lacks local evidence. AC markers are set only after concrete assertions pass:
  strict tuple shape, receipt version, null model hash, replay/context binding,
  route snapshot/policy/hash binding, model-hash equality, prompt/output hash
  binding, canonical-hash availability, usage cross-checks, normal and
  streaming terminal states, missing-receipt deadline behavior, failover prefix
  coverage, idempotent terminal outcomes, late receipt quarantine,
  future/legacy receipt versions, redaction, deadline disclosure, buyer
  disclosure language, signature algorithm, receipt-key fingerprint, and the
  full §N.7 zero/nonzero terminal-state matrix.
- The failover acceptance assertion uses the existing `req_spec015_v04_chain_0001`
  fixture chain: attempt 0 binds an upstream disconnect prefix and attempt 1
  binds the adjacent streaming normal-done prefix. Overlap/double-credit
  prevention is asserted separately through the verifier overlap gate.
- Full Step 8 acceptance was run across Swift provider code, coordinator,
  gateway, and phase7 verifier. The previous Step 0 Swift baseline failure in
  `ModelsSubcommandTests.testModelsListDisabledModePrintsIdleTableAndExitsZero`
  is no longer present in this run.

Validation:

| Command | Result |
|---|---|
| `scripts/verify-spec015-v04-step8.sh` | PASS |
| `cd phase4-coordinator && go test ./internal/billing -run TestSPEC015V04AcceptanceCriteria -count=1 -timeout 60s -v` | PASS |
| `cd phase3-binary && swift test` | PASS, 687 tests, 7 skipped |
| `cd phase4-coordinator && go test ./... -count=1` | PASS |
| `cd phase5-gateway && go test ./... -count=1` | PASS |
| `cd phase7-verify && go test ./... -count=1` | PASS |

Focused test coverage:

- `TestSPEC015V04AcceptanceCriteria` explicitly covers AC-43 through AC-71 and
  fails on any missing AC marker.
- `scripts/verify-spec015-v04-step8.sh` is the runnable acceptance manifest for
  cross-phase Step 8 evidence and includes exact test names rather than a
  documentation-only checklist.
- The Step 8 full-suite run re-executes provider v0.4 receipt issuance,
  coordinator route/output/verdict storage, gateway buyer disclosures, and the
  phase7 verifier against the current worktree.

Scope boundary:

- Step 8 does not wire SPEC-022 enforce-mode buyer final debit,
  provider-positive settlement, payout readiness, gateway money movement, or
  payout idempotency. It only proves the SPEC-015 v0.4 receipt prerequisite is
  acceptance-covered for SPEC-022 consumption.
- Claude adversarial/product lanes remain deferred until the full
  implementation lands, per the updated user instruction. Step 8 will use only
  the Codex code, security, and architect lanes.

Audit closure:

- Codex code: 0 critical / 0 high / 0 medium / 0 low after rerun.
- Codex security: 0 critical / 0 high / 0 medium / 0 low after rerun.
- Codex architect: 0 critical / 0 high / 0 medium / 0 low after adding the
  executable Step 8 acceptance target.
- Claude adversarial and product-design lanes remain deferred until the full
  implementation lands, per the updated user instruction.
