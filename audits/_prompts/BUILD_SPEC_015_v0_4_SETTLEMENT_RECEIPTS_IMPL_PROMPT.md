# BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_IMPL_PROMPT

You are starting a fresh implementation session for MacProvider in
`/Users/augstar/macprovider-poc`. Read this prompt end-to-end before writing
code.

Your job is to implement **SPEC-015 v0.4.2** settlement-capable receipts:

- Normative spec: `specs/SPEC-015-receipts.md`
- Audit rollup: `specs/SPEC-015-v0-4-audit.md`
- Upstream consumer: `specs/SPEC-022-verified-model-settlement.md`

This is money-path and trust-path prerequisite work. Follow `CLAUDE.md`: do
not develop on local `main`; use a feature branch or isolated implementation
worktree; do not inspect clean-room `d-inference` source.

## Objective

Ship the first full-product receipt profile that lets SPEC-022 tie buyer final
debit and provider-positive settlement to a provider-signed receipt that
matches the route-time catalog/model snapshot.

SPEC-015 v0.4 implementation is complete only when both non-streaming and
streaming attempts can produce, ingest, verify, store, and audit
settlement-capable receipts without breaking OpenAI-compatible clients.

## Hard gates

1. Do not wire SPEC-022 enforce-mode buyer final debit, provider-positive
   settlement, payout readiness, or gateway money movement in this prompt.
   This prompt builds the locked receipt prerequisite that SPEC-022 consumes.
2. Do not treat SPEC-015 v0.1/v0.2/v0.3 receipts as settlement-capable.
3. Streaming is first-class. A non-streaming-only implementation is incomplete.
4. `receipt_version` MUST be exactly `"4"` for this profile.
5. `attempt_n` is zero-based. First route attempt is `0`; retries/failovers
   increment by exactly `1`.
6. v0.4 `output_hash` MUST be
   `sha256(UTF-8(JCS(settlement_output_v1)))` for both streaming and
   non-streaming attempts. Do not use the legacy §5 three-key object as the
   v0.4 settlement hash input.
7. No buyer-facing or operator-facing claim may say this proves a malicious
   provider cannot falsify its own local model-hash measurement.

## Required reading

Read before coding:

1. `CLAUDE.md`.
2. `specs/SPEC-015-receipts.md` v0.4.2, especially §N and AC-43 through AC-71.
3. `specs/SPEC-015-v0-4-audit.md`.
4. `specs/SPEC-022-verified-model-settlement.md` and
   `specs/BUILD_SPEC_022_VERIFIED_MODEL_SETTLEMENT_IMPL_PROMPT.md`.
5. `specs/SPEC-005-billing.md`, `specs/SPEC-008-tier2.md`, and
   `specs/SPEC-011-operator-pushed-warm-swap.md`.
6. Provider receipt code:
   `phase3-binary/Sources/macprovider-cli/{ReceiptBuilder,HTTPServer,InferenceRelay,ModelRuntime,CoordinatorClient,RFC8785JCS,ReceiptAudit}.swift`.
7. Coordinator buyer/billing/request-log code:
   `phase4-coordinator/internal/buyer/{server,billing_recorder,forward_with_failover,forward_state,streaming_timing,transport_result}.go`,
   `phase4-coordinator/internal/billing/{hotpath,store,settlement,quarantine,recovery,endpoints}.go`,
   `phase4-coordinator/internal/requestlog/store.go`,
   `phase4-coordinator/internal/tier2/catalog.go`,
   `phase4-coordinator/internal/config/config.go`.
8. Gateway routing/disclosure code:
   `phase5-gateway/internal/router/{chat_proxy,disclosure,server}.go`.
9. Verifier code:
   `phase7-verify/internal/{receipt,verify,catalog,cli,jcs,canon,resolver,cache}`.

## Branching and audit discipline

Create an isolated implementation worktree:

```bash
git fetch origin
git worktree add ../macprovider-impl-spec-015-v0-4 -b impl/spec-015-v0-4-settlement-receipts origin/main
cd ../macprovider-impl-spec-015-v0-4
```

If the SPEC-015 v0.4 spec branch has not merged yet, base the worktree on the
SPEC branch that contains `SPEC-015 v0.4.2`.

After each numbered step, write the matching
`specs/AUDIT_SPEC_015_v0_4_IMPL_STEP_N_*_PROMPT.md` prompts and audit with:

- Codex code lane;
- Codex security lane;
- Codex architect lane;
- Claude subscription CLI adversarial verification lane;
- Claude subscription CLI product design critic lane.

Loop each step until 0 critical / 0 high / 0 medium. Do not refire a lane that
already reached 0/0/0 for the current step unless the code it audited changes
materially. Use Claude via subscription CLI, not API.

## Step 0 - Preflight and baseline

What lands: no product behavior.

Verify:

1. SPEC-015 line 3 is v0.4.2 LOCKED and `specs/SPEC-015-v0-4-audit.md`
   shows every required lane at 0/0/0.
2. SPEC-022 does not yet wire enforce-mode money movement to v0.3 receipts.
3. Baseline commands pass or known unrelated failures are documented:

```bash
cd phase3-binary && swift test
cd phase4-coordinator && go test ./...
cd phase5-gateway && go test ./...
cd phase7-verify && go test ./...
```

Done when: baseline evidence is recorded in `implementation-notes-spec-015-v0-4.md`.

## Step 1 - v0.4 canonical contract and fixtures

What lands:

1. Golden fixture corpus for `receipt_version: "4"` signed tuples.
2. Golden fixture corpus for `route_snapshot_v1`.
3. Golden fixture corpus for strict `settlement_output_v1` with EXACTLY the
   SPEC-015 §N.5 fields and no extras, covering:
   - non-streaming `normal_done`;
   - streaming `[DONE]`;
   - `provider_error`;
   - `buyer_cancel`;
   - `gateway_timeout`;
   - `upstream_transport_disconnect`;
   - empty prefix and non-empty prefix.
4. Golden fixture corpus for strict `usage`.
5. Cross-language JCS parity tests proving Swift and Go produce byte-identical
   canonical bytes for receipt tuple, route snapshot, usage, and
   `settlement_output_v1`.
6. Go fixture conformance tests in every module that must compute or verify
   v0.4 hashes: `phase4-coordinator`, `phase5-gateway`, and `phase7-verify`.
   These Go modules are separate and MUST NOT import `phase7-verify/internal/*`
   from coordinator or gateway. Either introduce a repo-approved shared package
   with a legal import path, or keep small module-local implementations locked
   by identical golden fixtures.

Do not add product behavior before fixtures pin the wire contract.

Tests:

- Swift JCS parity tests in `phase3-binary`.
- Go JCS/receipt tests in `phase7-verify`.
- Go JCS/settlement-output tests in `phase4-coordinator` and `phase5-gateway`
  if those modules compute `route_snapshot_v1`, `usage`, or
  `settlement_output_v1`.
- Fixture regeneration command documented and deterministic.

## Step 2 - Coordinator route-time settlement snapshot

What lands:

1. A coordinator route snapshot record created before provider dispatch for
   every covered attempt.
2. Strict `route_snapshot_v1` fields exactly matching SPEC-015 §N.2.
3. Snapshot digest:
   `sha256(UTF-8(JCS(route_snapshot_v1)))`.
4. Zero-based `attempt_n` persisted consistently with existing SPEC-002/SPEC-005
   attempt identity.
5. Route-time model/catalog equality material:
   `provider_reported_model_hash`, `expected_catalog_model_hash`,
   `catalog_id`, `catalog_body_digest`, catalog signing-key id/fingerprint,
   catalog expiry, SPEC-008 hash status, policy version/mode, paid entrypoint,
   provider session/generation ids, prompt hash basis, and prompt hash.
6. Provider receipt-key fingerprint:
   `ed25519-sha256:<64 lowercase hex>` over the raw 32-byte Ed25519 public key.

Likely files:

- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/buyer/forward_with_failover.go`
- `phase4-coordinator/internal/buyer/billing_recorder.go`
- `phase4-coordinator/internal/requestlog/store.go`
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/tier2/catalog.go`

Tests:

- Snapshot created before dispatch.
- Snapshot immutable across catalog rotation, provider reconnect, and policy
  reload.
- Mutating each §N.2 route-validity field changes the digest.
- First attempt is `0`; retry/failover increments by exactly `1`.

## Step 3 - Terminal-state, output, and usage canonicalization

What lands:

1. Coordinator/gateway observes terminal states:
   `normal_done`, `provider_error`, `buyer_cancel`, `gateway_timeout`,
   `upstream_transport_disconnect`.
2. Client-facing SSE remains OpenAI-compatible. Do not require non-standard
   receipt `event:` or receipt-only `data:` frames.
3. Coordinator/gateway reconstructs strict `settlement_output_v1` for
   streaming and non-streaming attempts before any provider receipt can be
   considered settlement-capable.
4. Half-open output byte ranges
   `[output_prefix_start_byte, output_prefix_end_byte)` are persisted per
   attempt with `output_hash`.
5. Transparent failover records one provider-attempt prefix per attempted
   provider and marks duplicate/overlapping ranges as non-creditable evidence
   for later SPEC-022 consumption.
6. Usage is coordinator/gateway-derived or cross-checked; provider-only usage
   cannot produce a `verified` or `zero_settled` settlement-verifier outcome.

Likely files:

- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/buyer/forward_with_failover.go`
- `phase4-coordinator/internal/buyer/forward_state.go`
- `phase4-coordinator/internal/buyer/streaming_timing.go`
- `phase4-coordinator/internal/buyer/transport_result.go`
- `phase5-gateway/internal/router/chat_proxy.go`
- `phase4-coordinator/internal/billing/hotpath.go`
- `phase4-coordinator/internal/billing/store.go`

Tests:

- Streaming `[DONE]` happy path.
- Provider error after partial output.
- Buyer cancel after partial output.
- Gateway timeout with empty and non-empty prefix.
- Upstream disconnect with empty and non-empty prefix.
- Adjacent, overlapping, duplicate, and out-of-order retry ranges.
- Stock OpenAI-compatible streaming client reads through terminal condition.
- Canonical hashes unavailable for a paid entrypoint exclude that entrypoint
  from paid SPEC-022 traffic; this prompt may only record the exclusion
  capability, while SPEC-022 owns enforce-mode startup policy.

## Step 4 - Verifier support and settlement mapping

What lands:

1. v0.4 receipt parser/verifier with strict tuple shape and unknown-version
   forward compatibility.
2. Signature verification against route-snapshot-pinned receipt key.
3. Request attempt, route snapshot, model hash, prompt hash, output hash,
   usage, timestamp, terminal-state, and receipt-key checks.
4. SPEC-015/SPEC-022-compatible outcome mapping:
   - `valid` chargeable row -> `verified` only after every §N check succeeds;
   - valid non-creditable row -> `zero_settled` only when §N.7 allows it;
   - invalid/mismatched/legacy/hashless/wrong-key/wrong-attempt/wrong-snapshot/
     wrong-terminal/replayed/insufficient-binding -> `quarantined`;
   - missing or trust-root inconclusive -> `pending` until deadline, then
     `quarantined`;
   - unknown future versions -> inconclusive and not payable.
5. Coordinator-internal verification API uses the same fixture-locked
   semantics as `phase7-verify`. Do not couple coordinator production code to
   `phase7-verify/internal/*`; the modules are separate.
6. `phase7-verify` remains pure stdlib unless explicitly approved otherwise.

Likely files:

- `phase7-verify/internal/receipt/receipt.go`
- `phase7-verify/internal/verify/verify.go`
- `phase7-verify/internal/cli/cli.go`
- `phase7-verify/internal/cli/output.go`
- `phase7-verify/internal/jcs/jcs.go`
- `phase7-verify/internal/canon/canon.go`
- coordinator-internal verifier package or module-local implementation if
  settlement cannot safely depend on the CLI module.

Tests:

- AC-43 through AC-71 each have runnable fixtures.
- Legacy v0.1/v0.2/v0.3 receipts are not settlement-capable.
- Unknown future receipt version is inconclusive, not valid and not payable.
- Wrong route snapshot, key, terminal state, usage, timestamp, prompt hash, or
  output hash maps to `quarantined`.

## Step 5 - Coordinator receipt ingestion, storage, and verdict state

What lands:

1. Internal receipt-ingestion API/channel for v0.4 receipts.
2. Parsed receipt records keyed by
   `(account_scope, request_id, attempt_n, provider_id)`.
3. First-terminal receipt-selection semantics.
4. State machine outcomes: `pending`, `verified`, `quarantined`,
   `zero_settled`.
5. Late receipt behavior: receipt-received timestamp decides deadline; provider
   `issued_at_unix_ms` cannot extend it.
6. Raw receipt retention only under explicit retention/security policy and
   segregated from audit, telemetry, verdict, and operator rows.
7. Audit categories `settlement_receipt_ingested` and
   `settlement_receipt_verdict` with redacted scalar fields only.
8. The state machine stores and exposes receipt-verifier outcomes and
   authorization evidence for SPEC-022, but does not itself create buyer final
   debit, provider-positive credit, payout-ready rows, or gateway money
   movement.

Likely files:

- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/billing/settlement.go`
- `phase4-coordinator/internal/billing/quarantine.go`
- `phase4-coordinator/internal/billing/recovery.go`
- `phase4-coordinator/internal/billing/endpoints.go`
- `phase4-coordinator/internal/requestlog/store.go`

Tests:

- Missing receipt remains pending until deadline, then quarantines.
- Valid receipt after deadline quarantine is a no-op or rejected audit event.
- Replay across account/request/attempt/provider/key/snapshot/terminal state
  quarantines.
- Resubmission cannot change the closed receipt outcome or expose a second
  positive-settlement authorization to SPEC-022; actual buyer debit, provider
  credit, and payout-ready row tests are deferred to the SPEC-022
  implementation.
- Raw receipt material is absent from audit/telemetry/verdict/operator rows.

## Step 6 - Provider v0.4 receipt issuance

What lands:

1. Swift provider constructs and signs the strict §N.1 tuple using route
   snapshot, terminal, output-prefix, usage, verifier, and ingestion material
   produced by Steps 2 through 5.
2. `signature_key_alg` is exactly `"Ed25519"`.
3. `model_hash` is non-null 64 lowercase hex from request-start loaded model
   state.
4. Provider receives or derives only the route metadata needed to sign the
   receipt; raw buyer credentials and bearer tokens are never included.
5. Receipt issuance supports non-streaming responses and streaming terminal
   receipt submission through the internal coordinator-ingested channel from
   Step 5.
6. Provider/issuer surface exposes the receipt submission deadline or
   `pending_deadline_seconds` basis and discloses late-receipt non-settlement.

Likely files:

- `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift`
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
- `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift`
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
- `phase3-binary/Sources/macprovider-cli/ReceiptAudit.swift`

Tests:

- Strict tuple field set; missing/extra field fixtures rejected by Go verifier.
- Wrong `signature_key_alg` rejected.
- Wrong receipt key/fingerprint quarantines.
- `model_hash: null` cannot produce a settlement-capable v0.4 receipt.
- Receipt timestamp obeys the SPEC-015 §N.3 skew/window policy.

## Step 7 - Product disclosures and operator diagnostics

What lands:

1. Provider-facing rejection reason codes for v0.4 receipt submission failures.
2. Buyer/product disclosure text that says v0.4 verifies provider-reported
   request-start model hash against the route-time catalog snapshot and does
   not detect a provider falsifying its own measurement.
3. Operator diagnostics that show fingerprints/digests/reason codes, not raw
   receipt public keys, raw signatures, raw envelopes, raw prompts, raw
   outputs, bearer tokens, receipt private keys, or provider-private state.

Likely files:

- `phase5-gateway/internal/router/disclosure.go`
- `phase4-coordinator/internal/billing/endpoints.go`
- provider/coordinator docs adjacent to the changed surfaces
- `beta/DECISION_CRITERIA.md` if a new product/security decision is made

Tests:

- Disclosure appears on the relevant paid/network buyer surface.
- Diagnostics include reason codes and omit prohibited raw material.
- AC-67 and AC-68 pass.

## Step 8 - Integration acceptance

Run full acceptance after all earlier steps are clean:

```bash
cd phase3-binary && swift test
cd phase4-coordinator && go test ./...
cd phase5-gateway && go test ./...
cd phase7-verify && go test ./...
```

Additional required evidence:

- End-to-end non-streaming `normal_done` produces a verified v0.4 receipt.
- End-to-end streaming `[DONE]` produces a verified v0.4 receipt without
  non-standard SSE receipt events.
- Each partial/terminal state row in §N.7 is exercised with
  `delivered_output_bytes == 0` and `> 0`.
- Transparent failover emits one receipt per provider-attempt prefix and
  prevents duplicate positive receipt authorization for overlapping prefixes.
- SPEC-015 exposes clear v0.4 capability and route-time catalog-match evidence
  for SPEC-022; actual SPEC-022 enforce-mode startup gating is deferred to the
  SPEC-022 implementation prompt.

## Final deliverables

1. Code implementing SPEC-015 v0.4.2.
2. `implementation-notes-spec-015-v0-4.md` with decisions, commands, audit
   status, and known gaps.
3. Step audit prompts and audit rollups for all 5 lanes.
4. Tests proving AC-43 through AC-71.
5. No SPEC-022 enforce-mode buyer debit/provider settlement wiring in this PR.

Stop only when the implementation and all required audit lanes are 0 critical /
0 high / 0 medium, or when a spec contradiction blocks correct implementation.
