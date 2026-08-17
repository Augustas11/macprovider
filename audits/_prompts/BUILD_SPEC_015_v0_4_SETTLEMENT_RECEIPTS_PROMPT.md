# BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_PROMPT

You are starting the prerequisite work required before SPEC-022 enforce-mode
implementation can begin.

## Why this exists

SPEC-022 v0.1.4 hard-gates enforce-mode buyer debit and provider settlement on
a locked settlement-capable receipt profile for both non-streaming and
streaming requests.

The current locked receipt spec is `SPEC-015 v0.3.4`. It is not
settlement-capable for SPEC-022 because it does not bind request attempt,
terminal state, route-time verification snapshot, or streaming delivery/storage.
Do not wire SPEC-022 enforce-mode money movement against v0.3 receipts.

This prompt is Deliverable 0 from
`specs/BUILD_SPEC_022_VERIFIED_MODEL_SETTLEMENT_IMPL_PROMPT.md`.

## Objective

Create and implement a locked SPEC-015 v0.4 or successor receipt profile that
is settlement-capable for SPEC-022.

The output must let SPEC-022 settlement verify:

- the same request attempt;
- the same provider receipt-key identity;
- the same route-time verification snapshot;
- the same model id and non-null model hash;
- the same prompt hash and output hash;
- the same terminal state;
- the same usage fields used for buyer debit and provider settlement;
- a receipt timestamp accepted by the v0.4 timestamp policy;
- a receipt version/profile accepted by `verified_model_settlement`.

## Scope

In scope:

- SPEC-015 v0.4 normative document or successor receipt-profile document;
- provider receipt issuance for non-streaming and streaming;
- coordinator receipt ingestion, storage, and internal verification hooks;
- verifier support for the new receipt profile;
- streaming receipt delivery that does not break OpenAI-compatible clients;
- terminal-state and chargeability classification required by SPEC-022 R-5.5
  through R-5.9;
- tests and audit prompts for every v0.4 acceptance criterion.

Out of scope:

- SPEC-022 enforce-mode buyer debit or provider settlement wiring;
- payout-ready aggregation changes;
- gateway final-debit gating;
- hardware attestation;
- runtime binary attestation;
- any claim that a provider cannot falsify its own loaded-model hash
  measurement.

## Required reading

Read before writing:

1. `specs/SPEC-022-verified-model-settlement.md` v0.1.4.
2. `specs/BUILD_SPEC_022_VERIFIED_MODEL_SETTLEMENT_IMPL_PROMPT.md`.
3. `specs/SPEC-015-receipts.md` v0.3.4.
4. `specs/SPEC-015-v0-3-audit.md`.
5. `phase3-binary/Sources/macprovider-cli/{ReceiptBuilder,HTTPServer,InferenceRelay,ModelRuntime,ReceiptAudit}.swift`.
6. `phase4-coordinator/internal/buyer/{server,billing_recorder,forward_with_failover,forward_loop,streaming_timing}.go`.
7. `phase4-coordinator/internal/billing/{hotpath,store,settlement}.go`.
8. `phase4-coordinator/internal/tier2/catalog.go`.
9. `phase5-gateway/internal/router/chat_proxy.go`.
10. `phase7-verify/internal/{receipt,verify,catalog,cli,resolver}`.

## Required v0.4 receipt profile

The v0.4 settlement-capable signed tuple must include at least:

- `receipt_version`: string, expected `"4"` or successor profile name;
- `account_scope` or privacy-preserving account-scope digest;
- `request_id`;
- `attempt_n` or equivalent monotonic route-attempt id;
- `provider_id`;
- `provider_receipt_key_id` or fingerprint of the signing key;
- `model_id`;
- `model_hash`: non-null 64 lowercase hex string;
- `prompt_hash`;
- `output_hash`;
- `usage`: canonical usage fields used for buyer debit/provider settlement;
- `terminal_state`;
- `terminal_state_ts_unix_ms` or equivalent timestamp;
- `route_snapshot_digest`;
- `route_snapshot_policy_version`;
- `route_snapshot_mode`;
- `catalog_id`;
- `catalog_body_digest`;
- `expected_catalog_model_hash`;
- `signature_key_alg`;
- `issued_at_unix_ms`.

The signed wire envelope may carry the signature and verification-key material
required by the profile, but audit, telemetry, verdict rows, and operator
surfaces must not contain raw receipt signatures, raw receipt public keys, raw
receipt envelopes, raw prompts, raw outputs, bearer tokens, receipt private
keys, or provider-private state. Use receipt-key fingerprints or digests for
identity in settlement and audit records.

## Non-streaming issuance

For non-streaming requests:

- provider emits the v0.4 receipt with the response or coordinator-ingested
  side channel defined by the profile;
- receipt must bind the request-start model hash, not a later warm-swap state;
- receipt verification must prove the SPEC-022 R-3.3 three-way equality:
  `receipt.model_hash == route_snapshot.provider_reported_model_hash ==
  route_snapshot.expected_catalog_model_hash`;
- receipt must bind the canonical prompt/output hashes already used by
  SPEC-015 v0.3 where applicable;
- error receipts are allowed only if the profile defines their terminal state
  and chargeability;
- `model_hash: null` is not settlement-capable for SPEC-022 enforce mode.

## Streaming issuance and delivery

For streaming requests:

- the client-facing SSE stream must remain OpenAI-compatible and must not
  require non-standard `data:` events for receipt delivery;
- normal `[DONE]`, provider error, buyer cancel, gateway timeout, and upstream
  transport disconnect must each produce a terminal state;
- terminal-state timestamp anchors the SPEC-022 pending receipt deadline;
- the issuer/provider-facing contract must expose the receipt submission
  deadline or `pending_deadline_seconds` basis and must disclose that late
  receipts are non-settling once the row has quarantined;
- delivered output prefix must be canonicalized and hashable for partial
  outcomes;
- partial usage must be derived or cross-checked against coordinator/gateway
  observed state;
- if delivered-prefix hash material or partial-usage material needed for a
  buyer-debitable/provider-creditable partial terminal state is unavailable,
  the row must remain pending until deadline, then quarantine with buyer
  reservation released and no provider credit;
- transparent failover must produce one receipt per provider attempt/prefix;
- overlapping prefixes must be detectable so SPEC-022 can avoid double charge.

Acceptable delivery designs include a coordinator-ingested provider end frame,
post-stream internal receipt submission, or another SDK-safe internal channel.
If the design uses buyer retrieval, that retrieval is optional for settlement;
internal settlement verification must not depend on buyer action.

## Coordinator ingestion and storage

Add a receipt-ingestion/storage design that can support SPEC-022 without
positive money movement:

- store receipt records keyed by account scope, request id, attempt id, and
  provider id;
- preserve first-terminal receipt-selection semantics;
- store raw receipt only where retention/security policy permits;
- segregate any raw receipt retention from audit/telemetry stores; never copy
  receipt signatures, receipt public keys, or raw receipt envelopes into audit,
  telemetry, or verdict rows;
- store parsed/verifier-safe fields required by SPEC-022;
- store receipt verification outcome and reason;
- store terminal-state timestamp and pending-deadline basis;
- store route-snapshot digest and policy version/mode from request start;
- store provider receipt-key fingerprint, not raw public key, in audit rows;
- support idempotent retry/replay handling;
- expose internal verification APIs for SPEC-022 settlement code.

Do not add provider-positive credit or final buyer debit in this step.

## Verifier support

Extend `phase7-verify` or a coordinator-internal verifier package so v0.4 can:

- parse strict tuple shape and reject missing/extra fields;
- verify Ed25519 signature against the expected provider receipt key;
- verify request attempt identity;
- verify terminal state;
- verify route-snapshot digest;
- verify non-null model hash equals the expected catalog model hash;
- verify non-null model hash also equals the route-time
  `provider_reported_model_hash`, preserving SPEC-022 R-3.3 three-way equality;
- verify prompt/output hash against supplied canonical request/output material;
- verify usage fields against supplied canonical usage material;
- classify legacy v0.1/v0.2/v0.3 receipts as not settlement-capable for
  SPEC-022 enforce mode;
- classify unknown future versions as inconclusive, not payable.

The profile must also define the settlement mapping from receipt-verifier
results to SPEC-022 outcomes:

- `valid` with a chargeable terminal-state row maps to `verified` only after
  every route snapshot, attempt, hash, usage, timestamp, and receipt-key check
  succeeds;
- `valid` with a non-creditable terminal-state row maps to `zero_settled` only
  when the chargeability table explicitly allows it;
- `invalid`, mismatched, legacy, hashless, wrong-key, wrong-attempt,
  wrong-snapshot, wrong-terminal-state, or insufficient-binding receipts map to
  `quarantined`;
- missing receipts and receipt trust-root `inconclusive` results remain
  `pending` until the configured deadline, then map to `quarantined`; they must
  never map to `verified` or `zero_settled`.

Timestamp policy must be strict enough for SPEC-022 R-4.5:

- `issued_at` and terminal-state timestamps must be bounded to the exact
  account/request/attempt settlement window;
- accepted skew must be explicit and fail closed for positive settlement;
- clock-skew warnings alone are not sufficient for `verified` or
  `zero_settled`;
- replay outside the attempt/window must map to `quarantined`.

`phase7-verify` must preserve its pure-stdlib discipline unless the user
explicitly approves a dependency.

## Chargeability table

The v0.4 profile must define a chargeability row for each terminal state:

- `normal_done`;
- `provider_error`;
- `buyer_cancel`;
- `gateway_timeout`;
- `upstream_transport_disconnect`.

For each row define:

- whether buyer final debit can occur;
- whether provider positive settlement can occur;
- whether `zero_settled` is possible;
- required output-prefix hash material;
- required usage material;
- retry/failover relationship;
- whether absence of receipt is pending then quarantine.

## Tests and acceptance criteria

Create v0.4 acceptance criteria covering:

- strict tuple field set and canonicalization;
- non-null model hash requirement for settlement-capable receipts;
- request id / attempt id / account-scope binding;
- provider receipt-key fingerprint binding;
- route-snapshot digest binding;
- terminal-state binding;
- timestamp policy;
- prompt/output hash matching;
- usage matching and provider-only usage rejection;
- SPEC-022 R-3.3 three-way model-hash equality;
- verifier-result mapping into `pending`, `verified`, `quarantined`, and
  `zero_settled`;
- legacy v0.3 receipt rejected as not settlement-capable;
- unknown future receipt version inconclusive;
- non-streaming happy path;
- streaming normal `[DONE]` happy path;
- streaming provider error;
- streaming buyer cancel;
- streaming gateway timeout;
- streaming upstream transport disconnect;
- future streaming resume/failover protocols that span multiple provider
  attempts: per-attempt receipt handling;
- receipt replay/idempotency;
- late receipt after deadline classification;
- partial-output binding unavailable goes pending until deadline, then
  quarantines with buyer reservation released and no provider credit;
- provider-visible receipt submission deadline and late-receipt non-settlement
  disclosure;
- audit redaction for receipt signatures, receipt public keys, raw receipt
  envelopes, raw prompts, raw outputs, bearer tokens, receipt private keys, and
  provider-private state;
- raw receipt retention segregation from audit, telemetry, and verdict rows.

Minimum verification commands once implemented:

```bash
cd phase3-binary && swift test
cd phase4-coordinator && go test ./...
cd phase5-gateway && go test ./...
cd phase7-verify && go test ./...
```

## Audit loop

After writing the v0.4 receipt-profile spec and implementation plan, create
audit prompts for:

- Codex code lane;
- Codex security lane;
- Codex architect lane;
- Claude subscription CLI adversarial verification lane;
- Claude subscription CLI product design critic lane.

Loop until every lane returns 0 critical, 0 high, and 0 medium before starting
SPEC-022 enforce-mode implementation.

## Stop condition

Stop this phase when:

- the receipt-profile prerequisite is written;
- it is clear that SPEC-022 enforce-mode code remains blocked until this
  profile is locked and implemented;
- the audit lanes for this prerequisite plan have reached 0 critical, 0 high,
  and 0 medium.
