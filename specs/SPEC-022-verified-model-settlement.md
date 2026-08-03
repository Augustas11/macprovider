# SPEC-022 - Verified model settlement

Version: v0.1.6
Status: Draft, lock-ready after round-4 closure
Date drafted: 2026-06-30
Depends on: SPEC-001, SPEC-002, SPEC-005, SPEC-006, SPEC-008, SPEC-010, SPEC-011, SPEC-015, SPEC-016

## Change log

### v0.1.6

Editorial, non-normative: registers the conformance-unit requirement IDs
`SPEC-022-R001`..`SPEC-022-R011` (one per normative requirement group R-1..R-11)
in `specs/CONFORMANCE.json` and anchors each ID in the corresponding `### R-N`
requirement-group header under `## Normative requirements`. No requirement text, obligation, or
observable contract changes; this only migrates SPEC-022 out of the
`requirement_id_migration: pending` state so governance declarations can cite
verified-model-settlement requirements.

### v0.1.5

Amends "Known limitations (B)" (runbook item 19): the effective per-request
deadline is authoritatively recoverable from
`settlement_route_snapshots.pending_deadline_seconds` (the coarse
`route_snapshot_policy_version` literal does not track a runtime SIGHUP of
`settlement.pending_deadline_seconds`). Reporting that needs the effective
deadline MUST read/group by that column; the `settlement_verdict_counters`
diagnostics now disaggregate by it (resolved via `route_snapshot_digest`) so
counters are no longer merged across deadline regimes under one policy version.
No settlement-correctness change; the SPEC-022 R-1.1 authoritative policy object
remains the deferred follow-up.

### v0.1.4

Minor-only closure pass after ADVERSARIAL VERIFICATION round 4 returned
0 critical and 0 major findings:

- Requires covered ledger and settlement rows to persist request-start
  `policy_version` and `mode`.
- Splits canonical-hash mismatch from canonical-hash-unavailable acceptance
  coverage.
- Defines receipt-selection behavior for multiple receipts on the same pending
  attempt.
- Adds pre-enforce payout-ready backlog classification coverage.
- Pins pending-deadline timing to terminal-state timestamps.
- Adds provider-side late-receipt disclosure and failover billing disclosure.

### v0.1.3

Round-3 audit fix pass after CODE, SECURITY, ARCHITECT, and PRODUCT DESIGN
CRITIC lanes met the lock bar, but ADVERSARIAL VERIFICATION returned three
major findings:

- Makes quarantine terminal. A late valid receipt cannot resurrect a
  deadline-quarantined row, re-debit the buyer, or credit the provider.
- Defines covered streaming failover as per-attempt settlement. Buyer debit is
  the sum of verified billable per-attempt prefixes; unverified prefixes cannot
  be charged or paid.
- Requires per-terminal-state streaming acceptance rows instead of a grouped
  partial-output AC.
- Adds AC coverage for receipt-key substitution, concurrent settlement-worker
  idempotency, quota-hold disclosure, and partial-usage authority.

### v0.1.2

Round-2 audit fix pass after CODE and SECURITY returned minor findings,
ARCHITECT returned ready-to-lock, and Claude subscription-cli ADVERSARIAL
VERIFICATION and PRODUCT DESIGN CRITIC lanes returned blocking findings:

- Adds explicit buyer-disclosure limits for provider-reported model-hash
  measurement. SPEC-022 binds the provider-reported request-start hash to the
  signed catalog and settlement receipt; it does not detect a provider that
  falsifies its own hash measurement.
- Defines `zero_settled` buyer reservation handling.
- Requires prompt/output hash comparison against persisted canonical request
  and delivered-output hashes.
- Broadens streaming partial-settlement rules beyond buyer cancel to every
  partial-output terminal state.
- Expands acceptance criteria for model-substitution, mid-request hash drift,
  policy-source failure, receipt replay, non-streaming missing receipts,
  buyer-retrieval independence, route-valid catalog expiry, direct payout
  bypasses, audit completeness, and rollout transition edges.

### v0.1.1

Round-1 audit fix pass after CODE, SECURITY, and ARCHITECT lanes returned
blocking findings:

- Defines SPEC-022 as the settlement gate only. Receipt wire shape,
  streaming receipt delivery, verifier semantics, and receipt versioning must
  be owned by a locked SPEC-015 v0.4 or successor receipt spec before
  SPEC-022 can enter enforce mode.
- Requires a settlement-capable receipt profile for both non-streaming and
  streaming requests. SPEC-015 v0.3 receipts do not bind request attempt or
  terminal state, so they are not sufficient for positive settlement under
  SPEC-022.
- Adds an authoritative `verified_model_settlement` policy surface with
  route-time policy snapshots.
- Pins catalog verification to an immutable route-time snapshot instead of an
  ambiguous "active catalog" at settlement time.
- Separates internal settlement verification from optional buyer receipt
  retrieval.
- Excludes all non-verified receipt outcomes from provider credit aggregates,
  earnings APIs, payout readiness, and admin money-positive bypasses.
- Adds rollout, rollback, direct-entrypoint, catalog-rotation, pending-deadline,
  and buyer-debit invariants.

### v0.1

Initial draft.

## Goal

SPEC-022 defines the first product-wide trust floor for paid MacProvider
traffic:

> A paid request may finally debit the buyer and positively settle for the
> provider only when the request was routed under a catalog-verified
> provider/model snapshot and the completed request has a settlement-capable
> provider-signed receipt that matches that route-time snapshot.

This SPEC composes existing model-catalog, warm-swap, receipt, gateway,
billing, and payout contracts into one launch gate. It does not replace those
specs. It states when their combined behavior is strong enough to make a
buyer-facing model-integrity claim and when money may flow to a provider.

## Non-goals

- Hardware attestation.
- Runtime binary attestation.
- Provider-private prompts or buyer-to-provider end-to-end encryption.
- Malicious-provider output-quality guarantees.
- Replacing SPEC-008 Pillars B, C, or D.
- Replacing SPEC-015 receipt cryptography or verifier ownership.
- Changing provider reward rates or model prices.
- Defining a second buyer protocol.

## Product claim

When SPEC-022 is enforced for a model and entrypoint, MacProvider MAY claim:

- The paid request was routed only to a provider whose request-start loaded
  model hash matched the signed catalog entry pinned in the route-time
  verification snapshot.
- Buyer final debit and provider positive settlement required a
  settlement-capable provider-signed receipt that bound request identity,
  route attempt, model id, model hash, prompt hash, output hash, usage fields,
  provider receipt-key identity, terminal state, timestamp, receipt version,
  and the route-time verification snapshot.
- Settlement rejected or quarantined requests whose receipt was missing,
  malformed, unsigned, legacy, hashless, request-mismatched,
  terminal-state-mismatched, or catalog-mismatched.

MacProvider MUST NOT use SPEC-022 to claim:

- Provider hardware was attested.
- The provider binary was attested.
- A provider that falsifies its own loaded-model hash measurement is detected by
  SPEC-022. The SPEC-022 claim binds the provider-reported request-start hash to
  the signed catalog and settlement receipt; it protects against drift,
  misconfiguration, receipt forgery, and mismatch, not against a provider that
  lies about the hash measurement itself.
- The provider could not inspect buyer plaintext.
- The provider could not produce low-quality or malicious text.
- The coordinator was unable to observe buyer plaintext.

## Ownership and relationship to existing specs

### SPEC-022 ownership

SPEC-022 owns the product-wide money gate:

- the policy surface for verified model settlement;
- the route-time verification snapshot required by settlement;
- the rule that non-verified receipt outcomes cannot become buyer-final,
  provider-creditable, earnings-visible, or payout-ready;
- rollout, rollback, and disclosure invariants for the gate.

SPEC-022 does not own receipt wire format or verifier implementation. It states
the minimum receipt properties required for settlement.

### SPEC-008

SPEC-008 Pillar A owns the coordinator-side model catalog and hash predicate.
SPEC-022 requires Pillar A enforcement for paid launch traffic by requiring the
equivalent of `tier2.require_hash_verified: true` for every model and entrypoint
covered by a SPEC-022 enforce policy.

SPEC-008 remains authoritative for hash-status values, catalog validation,
routing exclusion, `/v1/models` model-hash disclosure, and Pillar A audit
events.

SPEC-022 does not unlock SPEC-008 Pillars B, C, or D.

### SPEC-010 and SPEC-011

SPEC-010 owns provider-supported model declarations. SPEC-011 owns warm-swap
model-hash emission and the loaded-model state machine.

SPEC-022 requires the SPEC-011 hash path for paid traffic. A provider whose
request-start model hash cannot be determined MUST NOT receive positive
provider settlement for that request.

### SPEC-015 or successor receipt spec

SPEC-015 v0.3 owns the current non-streaming receipt shape and verifier
semantics for `model_hash` and `receipt_version`.

SPEC-015 v0.3 receipts are not settlement-capable for SPEC-022 because they do
not bind request id, route attempt, terminal state, or the route-time
verification snapshot. They MAY be used in observe mode and buyer-side
verification tooling, but they MUST NOT create positive provider settlement
under SPEC-022 enforce mode.

Before SPEC-022 can enter enforce mode, a locked SPEC-015 v0.4 or successor
receipt spec MUST define the settlement-capable receipt profile for both
non-streaming and streaming requests, including wire shape, delivery/storage,
retrieval, verifier semantics, timestamp policy, retention, and versioning.

### SPEC-005 and SPEC-016

SPEC-005 owns billing, ledger rows, settlement, and quarantine semantics.
SPEC-016 owns payout readiness and payout execution.

SPEC-022 adds a product-wide precondition to buyer final debit, positive
provider settlement, earnings visibility, and payout readiness: no row may
become final/payable unless receipt verification returns `verified` under the
route-time policy snapshot for that request attempt.

### SPEC-006

SPEC-006 owns the buyer API, public disclosure language, quota reservation, and
streaming gateway behavior.

SPEC-022 requires SPEC-006 disclosure to move from "model identity is
provider-reported" to "model identity is checked against a signed catalog" only
for models, entrypoints, and traffic classes where SPEC-022 enforce mode is
actually active. If a buyer-facing surface uses the shorter word "verified," the
provider-reported-hash caveat MUST be co-located in the same view.

Buyer receipt retrieval, if exposed, is a SPEC-006 or receipt-spec surface. It
is optional for settlement. Internal settlement verification MUST NOT depend on
buyer retrieval or buyer action.

## Definitions

**Paid traffic** means a buyer request that can debit buyer quota, accrue
provider credit, appear in earnings, or enter a payout-ready ledger path.

**Paid entrypoint** means any HTTP, gateway, direct-tunnel, SDK, internal relay,
or compatibility surface through which paid traffic can enter the system.
Every paid entrypoint is in scope. An entrypoint that cannot satisfy SPEC-022
MUST be disabled for paid traffic or explicitly marked non-paid before any
SPEC-022 product claim is made.

**Request attempt identity** means the accounting identity for one provider
attempt: `account_id` or a privacy-preserving account scope, `request_id`, and
`attempt_n` or an equivalent monotonic route-attempt id.

**Positive provider settlement** means any ledger state that can increase
provider credit, rewards, payout readiness, or any downstream provider
compensation balance.

**Final buyer debit** means buyer quota or balance becoming final rather than
reserved/pending. Under SPEC-022 enforce mode, final buyer debit waits for the
same verified receipt outcome that permits positive provider settlement.

**Verified model settlement policy** means the authoritative policy snapshot
for this gate. The policy is named `verified_model_settlement` and has at least:

- `policy_version`: monotonically increasing string or integer;
- `mode`: `observe` or `enforce`;
- `enabled_at`: policy activation timestamp;
- `model_ids`: exact model ids or explicit model classes covered;
- `entrypoints`: covered paid entrypoints;
- `receipt_profile`: accepted settlement-capable receipt profile/version set;
- `pending_deadline_seconds`: receipt deadline measured from request terminal
  time, default 300 and maximum 900. This value is backed by its own
  coordinator config key `settlement.pending_deadline_seconds` (default 300,
  validated to 1..900). It MUST NOT be derived from
  `settlement.recovery_grace_seconds` (SPEC-005 recovery-grace, default 30s),
  which retains its distinct recovery-grace meaning; conflating the two would
  quarantine receipts arriving 30–300s after terminal state under `enforce`.
  The pending-deadline default 300 was introduced under route-snapshot policy
  version `spec022-prereq-v1` (bumped from `spec022-prereq-v0`, which pinned
  the prior 30s-derived deadline); existing `v0` rows keep settling under
  their original 30s deadline, only new rows adopt 300s/`v1`;
- `require_hash_verified`: always true when `mode: enforce`;
- `catalog_policy`: active catalog id/signature key rules.

The coordinator is the authoritative source for this effective policy. Gateway,
billing, payout, and disclosure surfaces MUST consume, cache, or persist the
coordinator-issued effective policy. They MUST NOT independently invent
incompatible policy state.

**Route-time verification snapshot** means the immutable settlement input
captured when a request attempt is admitted to a provider. It contains at least:

- policy version and mode;
- paid entrypoint;
- request attempt identity;
- provider id;
- provider receipt-key identity accepted for this attempt;
- provider session id or generation id when available;
- requested model id;
- catalog id;
- catalog body digest;
- catalog signature key id or public-key fingerprint;
- catalog `expires_at`;
- expected catalog model hash;
- provider-reported request-start model hash;
- SPEC-008 hash status at route time;
- route decision timestamp.

Settlement MUST verify against this snapshot, not against an unspecified
current catalog at settlement time.

**Settlement-capable receipt profile** means the receipt profile accepted by
the effective policy. It MUST bind at least:

- request attempt identity;
- provider receipt-key identity;
- requested model id;
- non-null model hash;
- prompt hash;
- output hash, including streamed output prefix for partial outcomes;
- usage fields used by buyer debit and provider settlement;
- terminal state;
- receipt version/profile;
- unix timestamp;
- route-time verification snapshot digest or equivalent snapshot binding;
- provider signature.

**Receipt verification outcome** has exactly these SPEC-022 settlement values:

- `verified`: buyer final debit and positive provider settlement may proceed;
- `pending`: receipt or internal verification not available before the pending
  deadline;
- `quarantined`: trust failure, including missing, invalid, legacy, hashless,
  request-mismatched, route-snapshot-mismatched, terminal-state-mismatched,
  catalog-mismatched, or expired-policy receipt;
- `zero_settled`: verified non-creditable terminal outcome where no provider
  credit is owed.

`zero_settled` MUST NOT be used for receipt trust failures.

**Terminal-state timestamp** means the timestamp at which the gateway or
coordinator records the terminal state for deadline calculation. For streaming:
normal completion is the observed `[DONE]`; provider error is the accepted
provider error terminal frame or response; buyer cancel is the observed buyer
cancel signal; gateway timeout is the timeout firing time; upstream transport
disconnect is the connection-close observation time.

**Completed streaming request** means a streaming request that reached a
terminal state: normal `[DONE]`, provider error, buyer cancel, transport
disconnect, or gateway timeout. Every terminal state that can create final buyer
debit or positive provider settlement requires a receipt binding that terminal
state and terminal-state timestamp.

## Normative requirements

Requirement IDs `SPEC-022-R001`..`SPEC-022-R011` are the conformance units and
map one-to-one to the top-level requirement groups R-1..R-11 below; the `R-N.M`
sub-clauses are the normative obligations within each group. The IDs are
registered in `specs/CONFORMANCE.json`.

### R-1. Policy authority and mode (SPEC-022-R001)

R-1.1. Implementations MUST expose exactly one authoritative
`verified_model_settlement` policy surface from the coordinator.

R-1.2. Default mode is `observe`. `observe` MAY compute verdicts and emit audit
events, but MUST NOT change buyer debit, provider credit, earnings, payout
readiness, or buyer-facing verification claims.

R-1.3. `enforce` MUST fail startup or refuse activation unless:

- all covered models have an active signed catalog entry;
- the effective policy requires hash-verified routing;
- all covered paid entrypoints can receive and persist the policy;
- a locked settlement-capable receipt profile exists for every covered request
  mode, including streaming;
- billing and payout storage can exclude every non-`verified` outcome; and
- disclosure surfaces can distinguish observe from enforce.

Activation refusal MUST identify the unmet precondition or preconditions.

R-1.4. Product launch traffic that claims verified model integrity MUST run
under `mode: enforce`.

R-1.5. All services that handle covered traffic MUST record the effective policy
version and mode on request, ledger, settlement, and audit records they create.
Settlement and rollback decisions MUST read the row's stored request-start
policy version and mode, not the current effective policy. If a service cannot
obtain the effective policy, it MUST fail closed for paid traffic covered by the
claim.

### R-2. Entrypoint and routing preconditions (SPEC-022-R002)

R-2.1. Every paid entrypoint is either covered by SPEC-022 enforce mode,
disabled for paid traffic, or explicitly excluded from the product claim and
incapable of creating paid ledger rows.

R-2.2. Every model eligible for paid traffic under SPEC-022 MUST have an active
signed catalog entry at route time. The catalog MUST be signature-valid and not
expired at route time.

R-2.3. The coordinator MUST route covered paid requests only to provider/model
pairs whose current hash status is `hash_verified` under SPEC-008.

R-2.4. Providers with `uncatalogued`, `catalog_unavailable`, `hash_mismatch`,
`hash_invalid`, missing, empty, stale, or ambiguous model-hash state MUST be
excluded from covered paid routing.

R-2.5. Warm-swap transitions MUST be fail-closed. A provider that is loading,
draining, or has not yet emitted the post-swap verified hash MUST NOT be
eligible for covered paid routing for the target model.

R-2.6. "Eligible" in SPEC-022 means "passes the SPEC-022 verified-model
predicate." Ordinary routing filters still apply, including provider readiness,
auth state, slots, model support, context limits, breaker state, quota policy,
and sticky-affinity rules.

### R-3. Route-time verification snapshot (SPEC-022-R003)

R-3.1. For every covered request attempt, the coordinator MUST create and
persist a route-time verification snapshot before forwarding work to the
provider.

R-3.2. The snapshot MUST be immutable for the request attempt. Catalog rotation,
catalog rollback, provider reconnect, warm-swap, or delayed receipt arrival MUST
NOT change the snapshot used by settlement.

R-3.3. Settlement MUST verify:

`receipt.model_hash == route_snapshot.provider_reported_model_hash == route_snapshot.expected_catalog_model_hash`.

R-3.4. Settlement MUST verify that the receipt binds the same request attempt,
provider receipt-key identity, terminal state, usage, and route snapshot as the
ledger row.

R-3.4.1. Usage fields used for buyer debit or provider settlement MUST be
derived from or cross-checked against coordinator/gateway-observed canonical
request and output state under the applicable SPEC-005 settlement rules.
Provider-signed usage fields alone are not sufficient for positive settlement.

R-3.5. Settlement MUST compare receipt `prompt_hash` and `output_hash` against
persisted canonical hashes for the exact request attempt: the buyer request
payload as normalized by the coordinator/gateway, and the delivered response or
streamed output prefix used for buyer debit and provider settlement. If either
canonical hash is unavailable or mismatched, the row MUST be quarantined.

R-3.6. Catalog expiry after route time does not invalidate an already admitted
request attempt if the snapshot proves the catalog was signature-valid and
unexpired at route time. A request routed under an expired, unverifiable, or
missing catalog MUST be quarantined and MUST NOT final-debit the buyer or pay
the provider.

### R-4. Receipt requirement (SPEC-022-R004)

R-4.1. Every covered paid request that completes with any buyer-debitable or
provider-creditable outcome MUST produce a settlement-capable provider-signed
receipt.

R-4.2. A receipt with `model_hash: null` MUST NOT produce final buyer debit or
positive provider settlement.

R-4.3. A legacy receipt version, including SPEC-015 v0.3 or earlier, MUST NOT
produce final buyer debit or positive provider settlement under enforce mode
unless a locked successor receipt spec explicitly upgrades that version into
the settlement-capable profile.

R-4.4. A valid provider signature is necessary but not sufficient. The
settlement verifier MUST also check catalog snapshot match, request attempt
identity, provider receipt-key identity, terminal state, timestamp policy, usage
binding, and route-snapshot binding.

R-4.4.1. A receipt signed by a provider receipt-key identity other than the
identity pinned in the route-time snapshot for that attempt MUST be quarantined.

R-4.5. Receipt timestamp policy is owned by the settlement-capable receipt
profile, but SPEC-022 requires it to be strict enough to prevent replay across
request attempts and settlement windows. Clock-skew warnings alone are
insufficient for positive settlement.

R-4.6. Receipt selection is terminal per request attempt. The first receipt for
an attempt that reaches a terminal verifier outcome (`verified`, `quarantined`,
or `zero_settled`) closes the row for SPEC-022 money movement. Subsequent
receipts for the same attempt MUST be idempotent no-ops or rejected and MUST NOT
change buyer debit, provider credit, payout readiness, or settlement outcome.

### R-5. Streaming receipts (SPEC-022-R005)

R-5.1. Streaming requests are first-class paid traffic. They MUST satisfy the
same settlement-capable receipt requirement as non-streaming requests before
final buyer debit or positive provider settlement.

R-5.2. Implementations MUST define and ship a streaming receipt delivery and
internal verification path in a locked receipt spec before SPEC-022 can enter
`mode: enforce`.

R-5.3. The streaming receipt path MUST NOT require non-standard SSE events that
break common OpenAI-compatible streaming clients.

R-5.4. Internal settlement verification MUST NOT depend on buyer retrieval or
buyer action. Buyer-authenticated receipt retrieval MAY exist, but it is an
optional API surface separate from the internal money gate.

R-5.5. A streaming receipt MUST bind the terminal state. Terminal states MUST
distinguish at least:

- normal completion;
- provider error;
- buyer cancel;
- gateway timeout;
- upstream transport disconnect.

R-5.6. If any partial-output terminal state can create positive provider
settlement or final buyer debit for partial work, including buyer cancel,
provider error, gateway timeout, or upstream transport disconnect, the receipt
MUST bind the delivered output prefix and partial usage that settlement uses. If
that binding is unavailable, the row MUST remain pending until deadline, then
become quarantined with buyer reservation released and no provider credit.
Partial usage used for buyer debit or provider settlement MUST be derived from
or cross-checked against the coordinator/gateway-observed delivered prefix and
the settlement usage rules. Provider-signed usage fields alone are not
sufficient for partial-output settlement.

R-5.7. Synchronous buyer response completion and asynchronous receipt
verification MAY be decoupled. Until verification returns `verified`, buyer
debit remains reserved/pending and provider settlement remains pending.

R-5.8. The settlement-capable receipt profile or SPEC-005 settlement profile
MUST define the chargeability classification for every R-5.5 terminal state:
which states can be billable with a verified receipt, which states are
`zero_settled`, and which states quarantine on missing or insufficient binding.
SPEC-022 enforce mode MUST NOT activate until that classification exists for
every covered streaming terminal state.

R-5.9. Covered streaming failover settles per request attempt. If one buyer
request delivers output from multiple provider attempts, each attempt MUST have
its own route-time snapshot and settlement-capable receipt for the prefix and
usage attributed to that attempt. Buyer final debit for the request MUST equal
the sum of verified billable per-attempt prefixes. Unverified prefixes MUST NOT
be final-debited to the buyer or positively settled to any provider. Overlapping
or duplicate output across attempts MUST NOT be charged or credited twice.

### R-6. Buyer receipt retrieval (SPEC-022-R006)

R-6.1. If a buyer receipt retrieval endpoint is exposed, the requester MUST
authenticate as the account that owns the exact `(account_id, request_id,
attempt_n)` or as an operator.

R-6.2. Retrieval responses MUST NOT include raw prompts or raw outputs.

R-6.3. Retrieval responses MAY include only the receipt proof, canonical hashes,
terminal state, usage, provider receipt-key identity, route-snapshot digest,
catalog id, verifier metadata, and settlement outcome.

R-6.4. The retrieval spec MUST define retention, rate limits, idempotency,
404/403 behavior, and whether pending/quarantined receipts are visible to
buyers.

### R-7. Settlement, quarantine, and payout exclusion (SPEC-022-R007)

R-7.1. SPEC-005 settlement MUST add a receipt-verification gate before any row
can create final buyer debit, provider credit, earnings visibility, settlement
sweep inclusion, or payout readiness under SPEC-022.

R-7.2. Any row whose `receipt_verification_outcome != verified` MUST be
excluded from provider credit aggregates, earnings APIs, settlement sweeps,
`ledger_payout_ready` insertion, and SPEC-016 payout consumption.

R-7.3. `pending` and `quarantined` rows MUST NOT enter SPEC-016 payout
readiness.

R-7.4. `quarantined` is mandatory for receipt trust failures. Missing,
malformed, unsigned, legacy, hashless, request-mismatched,
terminal-state-mismatched, route-snapshot-mismatched, catalog-mismatched, and
expired-policy receipts MUST NOT be recorded as `zero_settled`.

R-7.5. `zero_settled` is reserved for verified non-creditable terminal
outcomes.

R-7.5.1. Quarantine is terminal for SPEC-022 money movement. A receipt arriving
after a row reaches `quarantined`, including deadline quarantine, MUST NOT
transition the row to `verified`, create provider credit, create payout
readiness, or re-debit the buyer. A later operator review path, if ever allowed,
requires a separate spec and MUST NOT be automatic settlement.

R-7.5.2. Provider-facing onboarding or operating docs MUST disclose that receipts
arriving after `pending_deadline_seconds` are non-settling and non-recoverable
unless a future operator-review spec defines an explicit exception path.

R-7.6. Missing receipts MUST NOT silently fall back to provider-reported usage
or gateway byte estimates under enforce mode.

R-7.7. Existing SPEC-005 and SPEC-006 fallback credit rules for cancel,
disconnect, or estimated usage are superseded for covered enforce-mode traffic.
Those rules MAY still run in observe mode or for non-covered traffic.

R-7.8. Operator/admin money-positive bypasses are forbidden for non-`verified`
SPEC-022 rows, including pending rows, quarantined rows, force-credit attempts,
fresh payout-ready compensation rows, and manual payout insertions. A later spec
may define an exception only with a receipt-failure-specific hold, evidence
bundle, dual-control audit trail, and explicit exclusion from automatic payout
until hold expiry.

### R-8. Buyer debit semantics (SPEC-022-R008)

R-8.1. Covered traffic uses reservation-first buyer accounting. Buyer quota or
balance may be reserved while the request runs, but final debit MUST wait for
`receipt_verification_outcome == verified`.

R-8.2. If receipt verification reaches `quarantined`, the buyer reservation MUST
be released or refunded and provider credit MUST remain zero.

R-8.3. If receipt verification remains `pending` past
`pending_deadline_seconds`, the row MUST transition to `quarantined`, release or
refund buyer reservation, and keep provider credit zero. The deadline is
measured from the recorded terminal-state timestamp.

R-8.4. If receipt verification returns `zero_settled`, the row is terminal. The
buyer final debit MUST be zero or the buyer reservation MUST be released or
refunded; provider credit MUST remain zero; and the row MUST remain excluded
from earnings, settlement sweeps, and payout readiness while included in
zero-settled counters.

R-8.5. Buyer-visible usage and receipt-status APIs MUST distinguish pending,
verified, quarantined/refunded, and zero-settled outcomes. Buyer-facing labels
MUST make clear that `quarantined` means not charged because model-integrity or
receipt verification failed, and `zero_settled` means not charged because no
billable verified work was produced.

R-8.6. SPEC-006 quota policy MUST define aggregate reservation behavior for
concurrent covered requests, including reservation caps, admission behavior when
many agentic requests are in flight, and release behavior after terminal
outcomes. A terminal SPEC-022 row MUST NOT permanently reduce buyer available
quota through a stale reservation.

### R-9. Rollout, migration, and rollback (SPEC-022-R009)

R-9.1. The effective policy applies by request-start timestamp and request
attempt identity.

R-9.2. Requests started before `mode: enforce` activation MUST NOT be
retroactively quarantined or reclassified by SPEC-022 unless a separate
backfill spec says so.

R-9.3. Requests started under enforce mode MUST NOT downgrade to payable solely
because the operator later rolls back to observe mode.

R-9.4. Rollback from enforce to observe affects only new request attempts.
Already-enforced pending, verified, quarantined, or zero-settled rows retain
their original policy version, pending deadline, and payout exclusion behavior.

R-9.5. Pre-existing payout-ready rows created before SPEC-022 enforce mode MUST
be explicitly classified as outside the policy snapshot. They MUST NOT be used
as evidence that SPEC-022 enforcement is active.

### R-10. Buyer disclosure (SPEC-022-R010)

R-10.1. `/v1/models` and product docs MUST distinguish:

- model identity verified against signed catalog from the provider-reported
  request-start model hash;
- provider hardware not attested;
- provider runtime not attested;
- providers that falsify their own loaded-model hash measurement are outside
  the SPEC-022 guarantee;
- prompts and outputs visible to selected provider hardware.

R-10.2. A model served by a mixed pool MUST NOT be described as fully verified
unless every provider eligible for paid traffic for that model and entrypoint
satisfies SPEC-022. A per-request verified claim is permitted for a request that
settled `verified`; a per-model "always verified" claim is permitted only when
every paid provider path for that model and entrypoint is covered by enforce
mode.

R-10.3. If observe mode is active, buyer-facing language MUST NOT claim
enforcement.

R-10.4. Disclosure MUST name any paid entrypoint excluded from the claim, or the
entrypoint MUST be disabled for paid traffic.

R-10.5. Buyer-facing disclosure MUST state that buyer cancel, gateway timeout,
provider error, or upstream disconnect can still produce a partial charge only
when a settlement-capable receipt binds the delivered output prefix and partial
usage. If transparent streaming failover spans multiple provider attempts,
buyer-facing disclosure MUST state that the request is billed only for delivered,
verified output across attempts and is not double-charged for overlapping
output.

R-10.6. Buyer-facing usage and quota surfaces MUST explain that a completed
request can briefly keep quota reserved while receipt verification is pending,
and that the reservation releases or refunds on a non-`verified` terminal
outcome.

### R-11. Audit and observability (SPEC-022-R011)

R-11.1. Every covered request attempt MUST produce a structured settlement
verdict audit event containing at least:

- policy version and mode;
- paid entrypoint;
- request id;
- attempt id or attempt number;
- redacted account identifier;
- provider id;
- provider receipt-key identity fingerprint;
- provider session/generation id when available;
- model id;
- route-time model hash status;
- route-time provider model hash;
- expected catalog model hash;
- catalog id;
- catalog body digest;
- terminal state;
- receipt profile/version;
- receipt verification outcome;
- buyer debit outcome;
- provider settlement outcome;
- payout exclusion outcome; and
- reason code on any non-verified outcome.

R-11.2. Audit events MUST NOT contain raw prompts, raw outputs, receipt
signatures, or receipt public keys unless an existing spec already permits the
field for that exact surface.

R-11.3. The system MUST expose aggregate counters for verified, pending,
quarantined, and zero-settled rows by policy version, model id, entrypoint, and
reason code.

R-11.4. Recovery/backfill paths MUST either populate every required audit field
from persisted state or mark the row outside SPEC-022 enforcement. They MUST
NOT synthesize missing route snapshots after the fact.

## Acceptance criteria

- **AC-022-1:** With enforce mode enabled, a provider/model pair whose
  route-time model hash matches the signed catalog passes the SPEC-022 hash
  predicate; ordinary routing filters still apply.
- **AC-022-2:** With enforce mode enabled, a provider with missing
  `model_hash` fails the SPEC-022 hash predicate and cannot receive covered paid
  routing.
- **AC-022-3:** With enforce mode enabled, a provider with mismatched
  `model_hash` fails the SPEC-022 hash predicate and emits the SPEC-008
  mismatch event.
- **AC-022-4:** During warm-swap loading or draining, the provider fails the
  SPEC-022 hash predicate for the target model.
- **AC-022-5:** Covered routing persists a route-time verification snapshot
  before forwarding work to the provider.
- **AC-022-6:** Catalog rotation after route time does not change the snapshot
  used for settlement verification.
- **AC-022-7:** A request routed under an expired or unverifiable catalog cannot
  final-debit the buyer or pay the provider.
- **AC-022-8:** A non-streaming request with a settlement-capable,
  catalog-matching receipt creates final buyer debit and positive provider
  settlement.
- **AC-022-9:** A SPEC-015 v0.3 or earlier receipt does not create final buyer
  debit or positive provider settlement under enforce mode.
- **AC-022-10a:** A non-streaming request with a valid signature but
  `receipt.model_hash != route_snapshot.expected_catalog_model_hash` is
  quarantined, buyer reservation is released/refunded, and provider credit
  remains zero.
- **AC-022-10b:** A receipt that binds a different request attempt identity than
  the ledger row is quarantined, buyer reservation is released/refunded, and
  provider credit remains zero.
- **AC-022-10c:** A receipt that binds a different terminal state than the
  ledger row is quarantined, buyer reservation is released/refunded, and
  provider credit remains zero.
- **AC-022-10d:** A receipt signed by a provider receipt-key identity different
  from the one pinned in the route-time snapshot is quarantined, buyer
  reservation is released/refunded, and provider credit remains zero.
- **AC-022-11:** A hashless receipt is quarantined and cannot create buyer final
  debit, provider credit, earnings visibility, or payout readiness.
- **AC-022-12:** A completed streaming request produces an internally
  verifiable settlement-capable receipt without breaking OpenAI-compatible
  streaming clients.
- **AC-022-13:** A completed streaming request does not create final buyer debit
  or positive provider settlement until the streaming receipt verifies against
  the route-time snapshot.
- **AC-022-14:** A streaming request whose receipt never arrives remains pending
  until the configured deadline, then becomes quarantined, releases/refunds
  buyer reservation, and keeps provider credit zero.
- **AC-022-15:** Any streaming request that receives final buyer debit or
  positive provider settlement for partial work, including buyer cancel,
  provider error, gateway timeout, or upstream disconnect, has a receipt binding
  terminal state, delivered output prefix, and partial usage.
- **AC-022-16:** Pending and quarantined rows are excluded from provider credit
  aggregates, earnings APIs, settlement sweeps, `ledger_payout_ready` insertion,
  and SPEC-016 payout consumption.
- **AC-022-17:** `zero_settled` is impossible for missing, invalid, mismatched,
  legacy, hashless, or route-snapshot-mismatched receipts.
- **AC-022-18:** Observe mode emits the same verdict fields as enforce mode but
  does not change buyer debit, provider credit, earnings, payout readiness, or
  buyer-facing enforcement claims.
- **AC-022-19:** Enforce mode cannot be enabled when the settlement-capable
  receipt profile is unavailable for any covered request mode, including
  streaming.
- **AC-022-20:** Enforce mode cannot be enabled when any covered paid entrypoint
  cannot consume the effective policy or produce route snapshots.
- **AC-022-21:** Paid direct or legacy entrypoints are either SPEC-022-compliant,
  disabled for paid traffic, or excluded from the product claim and incapable of
  creating paid ledger rows.
- **AC-022-22:** Rollback from enforce to observe affects only new request
  attempts; existing enforce-mode rows retain payout exclusion and pending
  deadline behavior from their stored request-start policy version and mode.
- **AC-022-23:** Admin/operator money-positive paths cannot credit or pay
  pending/quarantined SPEC-022 rows.
- **AC-022-24:** Buyer receipt retrieval, if exposed, requires account ownership
  for the exact request attempt and never returns raw prompt or raw output.
- **AC-022-25:** `/v1/models` does not claim full model verification for mixed
  verified/unverified pools, observe-mode policies, or excluded paid
  entrypoints.
- **AC-022-26:** Recovery/backfill cannot synthesize missing route snapshots
  into verified outcomes.
- **AC-022-27:** The acceptance harness proves the race where stream completion,
  receipt arrival, settlement sweep, and payout sweep occur in every ordering;
  only the ordering with verified receipt before payout readiness may pay.
- **AC-022-28:** A provider admitted under a verified route-time snapshot that
  mid-request warm-swaps or emits a settlement receipt for a different model
  hash is quarantined, buyer reservation is released/refunded, and provider
  credit remains zero.
- **AC-022-29:** With enforce mode active, a covered service that cannot fetch
  or use the effective `verified_model_settlement` policy fails closed for paid
  traffic or holds the row pending; it does not fall back to legacy SPEC-005 or
  SPEC-006 settlement and creates no final buyer debit or provider credit.
- **AC-022-30:** Replaying a `verified` receipt for a different request attempt
  is rejected or quarantined and cannot create positive settlement.
- **AC-022-31:** Resubmitting a `verified` receipt for an already-settled row is
  idempotent and cannot create a second final buyer debit, provider credit, or
  payout-ready row.
- **AC-022-32:** A non-streaming covered request whose settlement-capable
  receipt never arrives remains pending until deadline, then becomes
  quarantined, releases/refunds buyer reservation, and keeps provider credit
  zero without fallback to provider-reported or estimated usage.
- **AC-022-33:** Internal settlement reaches `verified` and finalizes buyer
  debit and provider credit with buyer receipt retrieval disabled and with no
  buyer retrieval call.
- **AC-022-34:** A request admitted under a signature-valid, unexpired catalog
  whose `expires_at` passes before receipt settlement still settles `verified`
  from the route-time snapshot; settlement does not re-evaluate catalog
  freshness against wall-clock.
- **AC-022-35:** Buyer receipt retrieval, if exposed, returns 403 for a
  non-owning authenticated account, permits an authorized operator path, and
  defines whether pending/quarantined receipt metadata is visible to the owning
  buyer.
- **AC-022-36:** A stock OpenAI-compatible streaming client can consume a
  covered streaming request through `[DONE]` without unknown receipt-delivery
  events breaking the stream parser.
- **AC-022-37:** Each R-2.4 hash-status exclusion state
  (`uncatalogued`, `catalog_unavailable`, `hash_mismatch`, `hash_invalid`,
  missing, empty, stale, ambiguous) is excluded from covered paid routing.
- **AC-022-38:** Every settlement verdict audit event contains all R-11.1 fields
  and the aggregate counters required by R-11.3 are queryable by policy version,
  model id, entrypoint, and reason code.
- **AC-022-39:** A manually inserted money-positive payout-ready or compensation
  row with no verified route-snapshot and receipt binding is rejected from
  payout consumption.
- **AC-022-40:** A request started before enforce activation settles under its
  request-start policy and is not retroactively quarantined when enforce
  activates mid-flight.
- **AC-022-41:** `zero_settled` releases/refunds buyer reservation or finalizes
  zero buyer debit, keeps provider credit zero, remains excluded from earnings,
  settlement sweeps, and payout readiness, and increments zero-settled counters.
- **AC-022-42a:** Settlement quarantines a receipt whose prompt hash or output
  hash does not match the persisted canonical request or delivered-output hash
  for the exact request attempt.
- **AC-022-42b:** Settlement quarantines a receipt when the canonical prompt hash
  or delivered-output hash is unavailable for the exact request attempt;
  entrypoints that cannot persist those canonical hashes are excluded from paid
  traffic or cannot create `verified` rows.
- **AC-022-43:** Enforce activation failure reports the exact unmet
  precondition or preconditions from R-1.3.
- **AC-022-44:** Buyer-facing model disclosure states that SPEC-022 uses the
  provider-reported request-start model hash and does not detect a provider that
  falsifies its own hash measurement.
- **AC-022-45:** Buyer-facing usage/disclosure surfaces explain pending,
  quarantined/refunded, and zero-settled outcomes without framing receipt or
  model-integrity failures as buyer fault.
- **AC-022-46:** Buyer-facing disclosure states that cancel, timeout, provider
  error, or upstream disconnect can create a partial charge only when a receipt
  binds the delivered output prefix and partial usage.
- **AC-022-47:** SPEC-006 quota policy covers concurrent agentic reservations
  and proves terminal SPEC-022 rows do not leave stale holds that permanently
  reduce buyer available quota.
- **AC-022-48:** A signature-valid, catalog-matching receipt that arrives after
  its row was quarantined by `pending_deadline_seconds` does not resurrect the
  row; provider credit remains zero, payout readiness remains absent, and the
  buyer refund or reservation release stands.
- **AC-022-49:** A covered streaming request that fails over mid-stream and
  delivers output spanning two provider attempts settles only the per-attempt
  prefixes that each have a verified receipt binding that attempt's route-time
  snapshot; buyer final debit equals the sum of verified billable per-attempt
  prefixes, no unverified prefix is charged, and no overlapping prefix is
  credited twice.
- **AC-022-50a:** A normal completed streaming request binds terminal state
  `normal_completion` or the receipt-spec equivalent and settles according to
  the terminal-state chargeability classification.
- **AC-022-50b:** A provider-error streaming request binds terminal state
  `provider_error` or the receipt-spec equivalent and settles according to the
  terminal-state chargeability classification.
- **AC-022-50c:** A buyer-cancelled streaming request binds terminal state
  `buyer_cancel` or the receipt-spec equivalent and settles according to the
  terminal-state chargeability classification.
- **AC-022-50d:** A gateway-timeout streaming request binds terminal state
  `gateway_timeout` or the receipt-spec equivalent and settles according to the
  terminal-state chargeability classification.
- **AC-022-50e:** An upstream-transport-disconnect streaming request binds
  terminal state `upstream_transport_disconnect` or the receipt-spec equivalent
  and settles according to the terminal-state chargeability classification.
- **AC-022-51:** Enforce activation is refused when the receipt or settlement
  profile does not define chargeability classification for every R-5.5 streaming
  terminal state.
- **AC-022-52:** Two settlement workers processing the same verified row
  concurrently create exactly one final buyer debit, one provider credit, and at
  most one payout-ready insertion.
- **AC-022-53:** A deadline-quarantined row remains non-payable across
  enforce-to-observe rollback; rollback does not permit late receipts to credit
  the provider or re-debit the buyer.
- **AC-022-54:** Partial-output settlement usage is derived from or
  cross-checked against the coordinator/gateway-observed delivered prefix and
  cannot rely solely on provider-signed usage fields.
- **AC-022-55:** Buyer-facing surfaces co-locate any use of "verified" model
  language with the provider-reported-hash caveat in the same view.
- **AC-022-56:** Buyer-facing quota and usage surfaces explain that a completed
  request can briefly keep quota reserved while receipt verification is pending,
  and that non-`verified` terminal outcomes release or refund the reservation.
- **AC-022-57:** Every covered ledger and settlement row persists the
  request-start `policy_version` and `mode`; settlement and rollback decisions
  read those stored fields instead of the current effective policy.
- **AC-022-58:** A bad receipt followed by a good receipt for the same still-open
  attempt leaves the first terminal verifier outcome in force and cannot
  resurrect the row.
- **AC-022-59:** Two valid receipts for the same still-open attempt with
  different usage or hashes do not create multiple settlements; the first
  terminal verifier outcome is authoritative and later receipts are idempotent
  no-ops or rejected.
- **AC-022-60:** Pre-enforce payout-ready rows are classified outside the
  SPEC-022 policy snapshot, excluded from verified counters and enforcement
  evidence, and remain governed only by their pre-enforce policy.
- **AC-022-61:** Pending deadline calculation starts from the recorded
  terminal-state timestamp, not request start, and is verified for normal
  completion plus each partial terminal state.
- **AC-022-62:** A covered streaming failover whose final attempt ends in buyer
  cancel, gateway timeout, or upstream disconnect settles the fully verified
  prefix attempts and the final partial attempt according to per-attempt receipt
  binding, without charging or crediting overlapping output twice.
- **AC-022-63:** Normal-completion usage used for buyer debit and provider
  settlement is derived from or cross-checked against coordinator/gateway
  canonical request and output state under the settlement usage rules and cannot
  rely solely on provider-signed usage fields.
- **AC-022-64:** Provider-facing onboarding or operating docs state that receipts
  arriving after `pending_deadline_seconds` are non-settling and non-recoverable
  unless a future operator-review spec defines an exception.

## Implementation sequencing

1. Receipt-profile spec: lock SPEC-015 v0.4 or successor with the
   settlement-capable profile for non-streaming and streaming requests.
2. Gap audit: map current code against AC-022-1 through AC-022-64.
3. Policy surface: implement authoritative `verified_model_settlement` policy
   and service propagation.
4. Route snapshots: persist route-time verification snapshots for covered
   request attempts.
5. Routing enforcement: require catalog-verified provider/model pairs for
   covered paid traffic.
6. Receipt verifier integration: verify settlement-capable non-streaming and
   streaming receipts against route snapshots.
7. Settlement quarantine and buyer debit: keep buyer debit pending until
   verified; block provider credit, earnings, and payout readiness on every
   non-verified outcome.
8. Disclosure update: expose only the exact model-integrity claim earned by the
   enforced path.
9. End-to-end acceptance: run non-streaming and streaming paid request tests
   through routing, receipt verification, buyer debit, settlement, quarantine,
   and payout exclusion.

## Known limitations / carried follow-ups

These are pre-existing gaps surfaced during the `pending_deadline_seconds`
audit (2026-07). Neither is new or worsened by that change; both are carried
as documented follow-ups rather than blocking it.

- **(A) Gateway settles `route_snapshot_failed` on estimate instead of
  no-charge. — RESOLVED 2026-07-14 (runbook item 18; SPEC-006 v0.9.10 § 17.7).**
  When the coordinator fails to persist a route snapshot pre-dispatch (e.g.
  `route_snapshot_failed`), no provider invocation occurs, but the gateway
  previously read the absent settlement-finality headers as legacy and settled
  the reservation on the estimated prompt-token count — debiting the buyer for
  a request that never reached a provider. The gateway now treats a
  `route_snapshot_failed` (500, code `route_snapshot_failed`, no finality
  header) as a **no-charge refund + verbatim passthrough**
  (`coordinatorPreDispatchNoChargeError` in
  `phase5-gateway/internal/router/chat_proxy.go`) — but **only** when the
  coordinator sets the POSITIVE `X-MacProvider-Settlement-No-Prior-Dispatch`
  marker and the gateway saw no prior provider-billed retry. The coordinator
  stamps that marker centrally (`noPriorDispatchResponseWriter`) on any terminal
  response written while no provider has been **billably credited** for the
  request. "Credited" is ledger-exact, from two recorder signals: `providerCredited`
  (set inside `recordRow` when a provider-bound billable row persists —
  `providerAssignedID != "" AND status != 503`) and `dispatchedThisAttempt &&
  terminalStatus != 503` (the current terminal attempt, whose billing row lands
  after its write on the WS paths). This supersedes the earlier `attemptN == 0`
  source, which over-counted non-billed 503 rows (over-charge) and incremented
  after the terminal WS write (under-charge); an admission failure, a same-attempt
  re-route, or a queue-full 503 records no billable credit and correctly stays
  marked. The positive-marker design makes a gateway-first deploy /
  coordinator rollback safe — an unmarked response settles on the estimate.
  Two unmarked/settled cases preserve provider work credited in `observe` mode:
  (1) coordinator-internal failover (marker withheld once a provider is
  credited); (2) gateway retry of an unmarked earlier response — a provider-
  dispatched `provider_*` 502 or a `no_provider` 503 from failover exhaustion
  after a billed attempt (`priorProviderDispatch`); a cold marked 502/503 does
  not poison the refund. **Deploy the coordinator before the gateway; roll back
  in reverse.** **Carried limitation:** on the coordinator's write-before-bill
  streaming / WS-tunneled terminal paths the marker is decided from the outward
  wire status, so a non-billable `503` rendered as `502` can be left unmarked and
  a subsequent `route_snapshot_failed` settled instead of refunded. This is the
  SAME outcome as pre-item-18 (route_snapshot_failed was always settled), so the
  edge is pre-existing and not worsened; a fully ledger-exact marker on these
  paths (canonical billing status, or terminal-billing-before-write) is a tracked
  follow-up.
- **(B) `route_snapshot_policy_version` marks default-cutover, not
  runtime-reconfiguration.** The policy version literal (`spec022-prereq-v0`
  = 30s-deadline era, `spec022-prereq-v1` = 300s-deadline era) marks when the
  *default* pending-deadline changed, but does not uniquely encode a
  runtime-reconfigured deadline — an operator SIGHUP-changing
  `settlement.pending_deadline_seconds` keeps the same policy-version
  literal. Per-row settlement stays correct (each row pins and hashes its
  own deadline independent of the version string), so this only affects
  report-by-policy-version aggregation, not settlement correctness. The
  **effective per-request deadline is authoritatively captured per-row** in
  `settlement_route_snapshots.pending_deadline_seconds` (set from the runtime
  config at dispatch and included in the route-snapshot digest), so it is
  recoverable — independent of the coarse version literal — as long as the pinned
  route-snapshot row is retained (verdict and snapshot rows are co-retained; no
  repository pruning path removes a snapshot ahead of its verdict). **Reporting
  that needs the effective deadline MUST read/group by that column, not the
  version string.** Accordingly, the `settlement_verdict_counters` diagnostics
  (`/admin/ledger/summary`) now disaggregate by the effective
  `pending_deadline_seconds` (resolved from the route snapshot via
  `route_snapshot_digest`), so counters are no longer merged across deadline
  regimes under one policy version (item 19). Deadline `0` is reserved as the
  **unknown** sentinel: a verdict whose route-snapshot row is absent reports `0`
  (which itself groups all unknown regimes together — an accepted degenerate case,
  not a valid 1..900 deadline). Fully deriving a single authoritative version
  from the effective policy object (so the version literal *itself* tracks
  runtime reconfiguration) remains the unimplemented SPEC-022 R-1.1 policy
  object; carried as a follow-up.

## Open questions

None for v0.1.5. Deferred implementation details belong in the receipt-profile
spec or the SPEC-022 implementation prompt, not in the locked settlement gate.

## Decision log

- **D-022-1: Product-wide trust floor.** This SPEC is not limited to a trial
  cohort or a temporary launch phase. It defines the first paid-product trust
  floor.
- **D-022-2: Streaming included.** Streaming is a primary buyer workflow for
  agentic tooling. A gate that excludes streaming would leave the most important
  money path outside the trust model.
- **D-022-3: Attestation deferred.** Model-integrity settlement is valuable
  before hardware and runtime attestation, but product language must not
  overclaim.
- **D-022-4: No silent fallback.** Missing or invalid receipts are operational
  problems, not permission to final-debit buyers or pay providers from
  self-reported usage.
- **D-022-5: Receipt ownership stays with receipt specs.** SPEC-022 requires a
  settlement-capable receipt profile, but SPEC-015 v0.4 or a successor receipt
  spec owns the wire shape and verifier semantics.
- **D-022-6: Buyer retrieval is not the money gate.** Internal settlement
  verification is mandatory. Buyer receipt retrieval is optional and must not
  block or define provider settlement.
- **D-022-7: Provider hash reporting boundary is disclosed.** SPEC-022 earns a
  settlement claim that the provider-reported request-start model hash matched
  the signed catalog and settlement receipt. It deliberately does not claim to
  detect a provider that falsifies its own hash measurement before hardware or
  runtime attestation exists.
- **D-022-8: Streaming failover settles per attempt.** A buyer request may
  aggregate multiple provider attempts for UX, but SPEC-022 money movement is
  per attempt. Only verified per-attempt prefixes can become buyer-final or
  provider-creditable.
