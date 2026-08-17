# BUILD_SPEC_022_VERIFIED_MODEL_SETTLEMENT_IMPL_PROMPT

You are starting a fresh implementation session for MacProvider in
`/Users/augstar/macprovider-poc`. Read this prompt end-to-end before writing
code.

Your job is to implement **SPEC-022 v0.1.4**:

- Normative spec: `specs/SPEC-022-verified-model-settlement.md`
- Status at prompt write time: Draft, lock-ready after round-4 closure
- Branch carrying the spec: `spec/022-verified-model-settlement`

SPEC-022 is the paid-traffic trust floor:

> Final buyer debit and positive provider settlement require a route-time
> catalog-verified provider/model snapshot and a settlement-capable
> provider-signed receipt that matches that snapshot.

This is money-path and trust-path work. Follow `CLAUDE.md`: do not develop on
local `main`; use a feature branch or an isolated implementation worktree; do
not touch clean-room `d-inference` source.

## Hard gates

1. **Do not implement enforce mode against SPEC-015 v0.3 receipts.**
   SPEC-015 v0.3 receipts are useful evidence, but SPEC-022 explicitly says
   they are not settlement-capable because they do not bind request attempt,
   terminal state, or route-time verification snapshot.

2. **Before any SPEC-022 enforce-mode money movement can ship, a locked
   settlement-capable receipt profile must exist for both non-streaming and
   streaming requests.** This is expected to be SPEC-015 v0.4 or a successor
   receipt spec. If it is not present and locked when you start, make the first
   deliverable the receipt-profile spec/implementation plan and stop before
   wiring enforce mode.

3. **Streaming is first-class.** A non-streaming-only implementation is not a
   valid SPEC-022 implementation. Streaming receipts must support normal
   `[DONE]`, provider error, buyer cancel, gateway timeout, and upstream
   transport disconnect terminal states without breaking standard
   OpenAI-compatible streaming clients.

4. **No buyer final debit and no positive provider credit from unverified
   receipts.** Missing, malformed, unsigned, legacy, hashless, request-
   mismatched, terminal-state-mismatched, catalog-mismatched, route-snapshot-
   mismatched, or wrong-receipt-key outcomes must remain pending, quarantine,
   or zero-settle exactly as SPEC-022 defines.

5. **No buyer-facing overclaim.** SPEC-022 does not attest hardware, provider
   binaries, private prompts, malicious-output resistance, or a provider that
   falsifies its own loaded-model hash measurement.

## Required reading

Read these files before coding:

1. `specs/SPEC-022-verified-model-settlement.md` v0.1.4 end-to-end.
2. `specs/SPEC-022-r3-r4-audit.md` for the closure history and recurring
   pitfalls.
3. The locked settlement-capable receipt profile, once available
   (`specs/SPEC-015-receipts.md` v0.4 or successor). If only v0.3 exists,
   stop before enforce-mode implementation.
4. `specs/SPEC-005-billing.md` and current billing implementation:
   `phase4-coordinator/internal/billing/{hotpath,settlement,store,quarantine,recovery,endpoints}.go`.
5. `phase4-coordinator/internal/requestlog/store.go`.
6. `phase4-coordinator/internal/buyer/{server,billing_recorder,forward_with_failover,forward_loop,streaming_timing}.go`.
7. `phase4-coordinator/internal/tier2/catalog.go` and routing hash-status
   code in `phase4-coordinator/internal/buyer/server.go`.
8. `phase5-gateway/internal/router/{chat_proxy,disclosure,server}.go`.
9. Provider receipt code:
   `phase3-binary/Sources/macprovider-cli/{ReceiptBuilder,HTTPServer,ModelRuntime,CoordinatorClient}.swift`.
10. Verifier code under `phase7-verify/internal/{receipt,verify,catalog,cli}`.

## Implementation shape

Create an implementation branch/worktree from the branch that contains the
locked SPEC-022 text. Example:

```bash
git fetch origin
git worktree add ../macprovider-impl-spec-022 -b impl/spec-022-verified-model-settlement spec/022-verified-model-settlement
cd ../macprovider-impl-spec-022
```

If the SPEC branch has already merged, base the implementation branch on
`origin/main` instead.

## Deliverable 0 - Receipt-profile prerequisite

If a locked settlement-capable receipt profile is absent, do not start
SPEC-022 enforce-mode code. Produce the prerequisite implementation plan for
the receipt profile first.

The settlement-capable receipt profile must define, for both streaming and
non-streaming:

- wire shape and versioning;
- delivery/storage path;
- verifier semantics;
- timestamp policy;
- retention;
- request attempt identity binding;
- provider receipt-key identity binding;
- route-snapshot binding;
- model id and non-null model hash binding;
- prompt and output hash binding;
- usage-field binding;
- terminal-state binding;
- streaming terminal-state chargeability classification;
- late receipt behavior;
- replay/idempotency behavior.

Do not treat this deliverable as complete until it has its own tests and audit
closure.

## Deliverable 1 - Coordinator policy surface

Add one authoritative coordinator policy surface named
`verified_model_settlement`.

Minimum policy fields:

- `policy_version`
- `mode`: `observe` or `enforce`
- `enabled_at`
- `model_ids` or explicit model classes
- `entrypoints`
- `receipt_profile`
- `pending_deadline_seconds` default 300, maximum 900
- `require_hash_verified` true in enforce mode
- `catalog_policy`

Requirements:

- Default mode is `observe`.
- Startup/reload must fail closed for `enforce` unless SPEC-022 R-1.3
  prerequisites are satisfied.
- Every covered request, ledger row, settlement row, audit event, and retrieval
  surface must persist or expose request-start `policy_version` and `mode`.
- Rollback from `enforce` to `observe` affects only new request attempts.
  Existing attempts settle under their persisted request-start policy.

Likely files:

- `phase4-coordinator/internal/config/config.go`
- coordinator startup/reload wiring under `phase4-coordinator/cmd/...`
- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/billing/settlement.go`

## Deliverable 2 - Route-time verification snapshot

For every covered provider attempt, persist an immutable route-time verification
snapshot before provider dispatch.

Snapshot minimum fields:

- account scope or account id as allowed by privacy policy;
- request id;
- attempt number or route attempt id;
- provider id and provider assigned id;
- provider session id or generation id when available;
- model id;
- provider-reported request-start model hash;
- expected catalog hash;
- SPEC-008 hash status at route time;
- catalog id;
- catalog body digest computed from the exact signed catalog bytes accepted by
  the coordinator;
- catalog signature key id or public-key fingerprint;
- route-time catalog expiry;
- route decision timestamp;
- policy version and mode;
- entrypoint;
- provider receipt-key identity expected for the attempt;
- route snapshot digest.

Settlement must use this snapshot, not current catalog state. Catalog rotation,
catalog expiry after route time, provider warm-swap after admission, or policy
reload must not rewrite the snapshot.

Likely files:

- `phase4-coordinator/internal/tier2/catalog.go`
- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/buyer/billing_recorder.go`
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/requestlog/store.go`

## Deliverable 3 - Receipt verification and receipt-selection state machine

Add a settlement receipt-verification state machine tied to
`(account/request_id/attempt_n/provider_id)` or the repository's equivalent
attempt identity.

Canonical outcomes:

- `pending`
- `verified`
- `quarantined`
- `zero_settled`

Rules:

- First terminal receipt outcome closes the row. Later receipts for the same
  attempt are idempotent no-ops or rejected audit events; they cannot resurrect
  quarantine, re-debit the buyer, or credit the provider.
- `verified` is the only outcome that can permit final buyer debit or positive
  provider credit.
- `zero_settled` is only for verified non-creditable terminal states.
- Missing receipts past deadline quarantine.
- Canonical prompt/output hash unavailable must quarantine, distinct from
  canonical hash mismatch.
- Provider-signed usage alone is not authority. Debit/settlement usage must be
  derived or cross-checked against coordinator/gateway-observed canonical
  request/output state under SPEC-005 rules.

Likely files:

- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/billing/hotpath.go`
- `phase4-coordinator/internal/billing/settlement.go`
- new billing verifier/state-machine package if warranted
- `phase4-coordinator/internal/buyer/billing_recorder.go`
- `phase4-coordinator/internal/buyer/server.go`
- `phase7-verify/internal/receipt/receipt.go`
- `phase7-verify/internal/verify/verify.go`

## Deliverable 4 - Money-path gating

Change the current hot paths so covered enforce-mode traffic does not create
final buyer debit, payout-ready provider-positive credit, or positive provider
credit until receipt verification succeeds.

The current implementation writes `ledger_request_credits` and
`ledger_operator_credits` synchronously from `billing.WriteHotPath`. SPEC-022
requires a covered enforce-mode row to start as pending/reserved and become
positive only after verified receipt matching. The gateway also owns buyer
quota/usage reservation and settlement paths; this deliverable must update both
coordinator provider-credit paths and gateway buyer-debit paths.

Required behavior:

- buyer quota/balance is reserved while verification is pending;
- final buyer debit happens only on `verified`;
- provider positive credit happens only on `verified`;
- quarantine releases buyer reservation and remains terminal;
- pending past deadline releases buyer reservation and quarantines;
- payout-ready aggregation ignores pending, quarantined, zero-settled, and any
  non-verified row;
- earnings/admin/provider-credit APIs never count non-verified outcomes as
  positive provider compensation;
- operator/admin money-positive bypasses are forbidden for non-verified covered
  rows.
- coordinator receipt verification is the authority for final debit outcome;
  gateway usage/quota storage must consume the verified/quarantined/
  zero-settled/pending outcome instead of independently finalizing covered
  traffic on a local timer or stream-completion event.

Likely files:

- `phase4-coordinator/internal/billing/hotpath.go`
- `phase4-coordinator/internal/billing/settlement.go`
- `phase4-coordinator/internal/billing/payout.go`
- `phase4-coordinator/internal/billing/endpoints.go`
- `phase4-coordinator/internal/billing/quarantine.go`
- `phase4-coordinator/internal/billing/recovery.go`
- `phase4-coordinator/internal/buyer/server.go`
- `phase5-gateway/internal/router/chat_proxy.go`
- `phase5-gateway/internal/storage/sqlite/store.go`
- `phase5-gateway/internal/storage/types.go`

## Deliverable 5 - Streaming receipt support

Implement streaming receipt handling for covered paid traffic.

Required behavior:

- normal `[DONE]`, provider error, buyer cancel, gateway timeout, and upstream
  transport disconnect each map to an explicit terminal state;
- terminal-state timestamp anchors the pending-deadline timer;
- delivered output prefix and usage for partial terminal states are canonical
  and verifiable;
- streaming receipt delivery does not require non-standard SSE events that
  break OpenAI-compatible clients;
- internal settlement verification does not depend on buyer retrieval;
- current streaming failover is transparent only before response bytes are
  committed; after the first buyer-visible SSE event, provider disconnect
  terminates the stream with `provider_disconnected`;
- any future resume or failover protocol spanning multiple provider attempts
  bills only verified billable per-attempt prefixes;
- unverified prefixes are not charged or paid;
- overlapping prefixes are not double charged.

Likely files:

- `phase4-coordinator/internal/buyer/forward_with_failover.go`
- `phase4-coordinator/internal/buyer/forward_loop.go`
- `phase4-coordinator/internal/buyer/streaming_timing.go`
- `phase4-coordinator/internal/buyer/server.go`
- `phase5-gateway/internal/router/chat_proxy.go`
- provider streaming code under `phase3-binary/Sources/macprovider-cli/`

## Deliverable 6 - Gateway and buyer disclosure surfaces

Update buyer-facing, provider-facing, and gateway surfaces so they describe
only the claims and money outcomes that are actually enforce-active.

Requirements:

- `/v1/models` and docs distinguish provider-reported, catalog-known, and
  settlement-enforced model identity.
- If the word `verified` is used, co-locate the provider-reported-hash caveat.
- Buyer-facing disclosure must not imply hardware attestation, runtime binary
  attestation, provider-private prompts, malicious-output prevention, or
  detection of a provider that falsifies its own loaded-model hash measurement.
- Mixed pools are not described as fully verified.
- Observe mode cannot claim verified model integrity.
- Excluded paid entrypoints are named, or the claim is limited to included
  entrypoints.
- Usage/quota surfaces explain pending verification reservations and late
  receipt outcomes.
- Buyer receipt/status surfaces expose pending, verified, quarantined, and
  zero-settled states without raw prompts or raw outputs.
- Buyer-facing labels must explain that `quarantined` means not charged because
  model-integrity or receipt verification failed, and that `zero_settled` means
  not charged because no billable verified work was produced. These labels must
  not frame receipt or model-integrity failures as buyer fault.
- Buyer-facing disclosure must state that buyer cancel, gateway timeout,
  provider error, or upstream disconnect can still produce a partial charge only
  when a settlement-capable receipt binds the delivered output prefix and
  partial usage.
- Buyer-facing disclosure must state that streaming failover is transparent
  only before response bytes are committed; after the first buyer-visible SSE
  event, provider disconnect terminates the stream with `provider_disconnected`
  and the buyer may retry as a new request. That retry must be disclosed as a
  separate billable request with its own reservation and settlement, and
  cross-request overlapping output must be disclosed as not deduplicated. Any
  future resume or failover protocol spanning multiple provider attempts must
  not double-charge overlapping output.
- Provider-facing onboarding and operating docs must disclose that receipts
  arriving after `pending_deadline_seconds` are non-settling and
  non-recoverable unless a future exception spec changes that rule.

Likely files:

- `phase5-gateway/internal/router/disclosure.go`
- `phase5-gateway/internal/router/pages.go`
- `phase5-gateway/internal/router/templates/docs.md`
- `phase4-coordinator/internal/buyer/server.go`
- any `/v1/models`, usage, quota, or receipt retrieval handlers

## Deliverable 7 - Audit and observability

Every covered request attempt must emit structured audit/telemetry without raw
prompts, raw outputs, receipt signatures, receipt public keys, bearer tokens,
or provider private state. Receipt-key identity in audit/telemetry must be a
fingerprint or digest, not a raw public key, unless another locked spec
explicitly permits the exact public surface.

Minimum event fields must reproduce every field required by SPEC-022 R-11.1.
Do not implement a subset. The list is:

- request id;
- account scope;
- attempt id;
- provider id;
- provider session/generation id when available;
- model id;
- entrypoint;
- policy version and mode;
- route snapshot digest;
- catalog id;
- catalog body digest;
- route-time model hash status;
- route-time provider model hash;
- expected catalog model hash;
- receipt version/profile;
- provider receipt-key identity fingerprint;
- terminal state;
- receipt verification outcome;
- quarantine/zero-settle reason if any;
- pending deadline;
- buyer debit outcome;
- provider settlement outcome;
- payout exclusion outcome.

Expose aggregate counters for verified, pending, quarantined, zero-settled,
legacy receipt, missing receipt, catalog mismatch, model-hash null, and
receipt-key mismatch outcomes.

Buyer/admin display surfaces may derive short hash prefixes from the persisted
full hashes, but audit events and settlement-verdict records must retain the
full route-time provider model hash and expected catalog model hash required by
SPEC-022 R-11.1.

## Tests and acceptance gate

Map and test every `AC-022-1` through `AC-022-64`. The final PR is not ready
until every AC has a deterministic automated test or an explicitly named
operator/manual gate.

Minimum test sets:

- coordinator policy default, reload, enforce startup failure, rollback, and
  policy-version persistence;
- route-time snapshot immutability under catalog rotation and policy reload;
- non-streaming verified receipt positive path;
- legacy/hashless/missing/malformed/wrong-key/wrong-attempt/wrong-terminal/
  wrong-snapshot receipts quarantine;
- prompt/output canonical hash unavailable vs mismatch;
- canonical usage cross-check vs provider-only usage;
- receipt replay and multiple-receipt selection;
- concurrent settlement worker idempotency;
- missing receipt deadline measured from terminal-state timestamp;
- streaming normal/provider-error/buyer-cancel/gateway-timeout/upstream-
  disconnect terminal states;
- future streaming resume/failover protocols that span multiple provider
  attempts: per-attempt debit/settlement and no double charge;
- stream-completion, receipt-arrival, settlement-sweep, and payout-sweep race
  harness covering every ordering; only the ordering with verified receipt
  before payout readiness may pay;
- payout-ready and earnings exclusions for non-verified rows;
- buyer quota reservation/release/final debit behavior;
- buyer, provider, gateway, disclosure text and `/v1/models` state transitions;
- audit event redaction and required-field completeness;
- backfill/recovery does not invent positive credit for rows missing required
  SPEC-022 fields.

Run at minimum:

```bash
cd phase4-coordinator && go test ./...
cd phase5-gateway && go test ./...
cd phase7-verify && go test ./...
cd phase3-binary && swift test
```

If a module cannot be tested because the prerequisite receipt profile is not
locked yet, report that as a blocker and stop before shipping enforce mode.

## Output expectation

Produce a reviewable implementation branch with:

- schema migrations and rollback-safe additive columns;
- implementation code;
- AC coverage table mapping AC-022-1..64 to tests;
- updated operator docs/disclosures;
- test results;
- no SPEC-022 text edits unless the user explicitly starts a spec-fix round.

Commit messages must follow the Lore Commit Protocol in `AGENTS.md`.
