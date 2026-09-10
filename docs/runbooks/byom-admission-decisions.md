# BYOM admission decisions (SPEC-047 v0.1.5 operator runbook)

This runbook is the production procedure for deciding on a provider's BYOM
candidates: pricing a catalog-matched candidate (`catalog_priced`) and
granting the money path (`settlement_capable`, dual control). It is the only
sanctioned way to append an operator-origin admission event; nothing here is
a provider-facing surface.

Governing text: `specs/SPEC-047-network-model-admission.md` R001 (decision
request, precedence, dual control, listing), R003 (preconditions, session
binding), R006 (drift), and `specs/SPEC-010-model-catalog.md` R004/R007
(composite proof, identity sets). Read them before acting on anything the
listing shows.

## Prerequisites

- A **per-actor** operator credential: an entry in the coordinator's
  `auth.operator_keys` map (the same class `/admin/hardware-trust/*` uses).
  The shared `auth.operator_key` is refused with `invalid_operator_token`.
- Two distinct actors are configured. With fewer than two, every
  `settlement_capable` request fails synchronously with
  `dual_control_unavailable` and nothing is recorded.
- The coordinator runs with the artifact-bound catalog release (candidate
  catalog + `autotune-artifacts.json` feed) and Tier-2 material loaded; a
  candidate can only be priced while its row is `recommendable` and the
  Tier-2 material for the row is present.
- Requests are bounded and rate-limited per operator credential and source
  address (independent of any provider window). A bearer that matches more
  than one `operator_keys` entry is refused: two entries sharing a secret are
  one principal and cannot dual-control.
- The `MODEL_ADMISSION_SUBMISSIONS` kill switch stops new provider offers
  only; these operator endpoints stay live (no new candidate can appear, but
  an existing one can still be decided).
- The artifact feed's 14-day freshness (SPEC-023 §3.7.6) is load-bearing:
  once it lapses, feed-member sessions stop verifying and the next reload
  revokes their decided candidates (`runtime_identity_drift` /
  `catalog_artifact_feed_changed`, re-entry = fresh offer). Renew the feed
  before it expires (`docs/runbooks/autotune-feed-renewal.md`).

Set once per shell (never print the key; read it from the operator secret
store):

```bash
COORD=https://127.0.0.1:8443   # from the coordinator host, or a tunnel
OP_TOKEN="$(cat "$HOME/.config/macprovider/operator-key-<actor>")"
```

## 1. List a provider's candidates

The operator decides on RECORDED state only — the coordinator's offer-time
match, never the provider's claim.

```bash
curl -sS -H "Authorization: Bearer $OP_TOKEN" \
  "$COORD/admin/model-admission/offers?provider_id=<provider_id>" | jq .
```

`model_admission_offer_list.v1` lists every candidate ordered by
`candidate_id` with:

- `admission_state`, `coordinator_event_id` (the HEAD every decision must
  name), `reason_code`, `last_event_actor`;
- `catalog_match_state` / `catalog_match_reason` — only `catalog_matched`
  candidates can be priced. Reasons for `unmatched`: `no_artifact_match`,
  `catalog_model_key_disagrees`, `artifact_hashes_span_keys`,
  `catalog_artifact_feed_integrity_failure`, `primary_row_ambiguous`,
  `runtime_source_not_allowed`. An unmatched candidate needs a fresh offer
  from the provider; there is nothing to repair operator-side;
- the resolved row tuple (`catalog_model_key`, `catalog_row_model_id`,
  `catalog_row_model_sha256`), the release it was evaluated under
  (provenance only), and `catalog_members` — the admissible members, each
  tagged `candidate_row` (row-bound primary, no artifact id) or
  `artifact_feed` (artifact id + feed provenance);
- `session` — the live-session facts a settlement decision evaluates:
  `bound` (the coordinator-derived session-to-candidate binding),
  `bound_coordinator_event_id`, `validated_release_generation`,
  `verified_member` (the pinned, hash-verified member) and
  `receipt_key_present`.

## 2. Price a candidate (`catalog_priced`)

```bash
curl -sS -H "Authorization: Bearer $OP_TOKEN" -H 'Content-Type: application/json' \
  -X POST "$COORD/admin/model-admission/decisions" -d '{
    "schema": "model_admission_decision_request.v1",
    "provider_id": "<provider_id>",
    "candidate_id": "<candidate_id>",
    "next_state": "catalog_priced",
    "reason_code": "operator_priced_<ticket>",
    "expected_coordinator_event_id": "<head from the listing>",
    "idempotency_key": "<unique per intent, e.g. ticket-1>"
  }' | jq .
```

Rules the endpoint enforces (first failure wins, nothing appended):

1. `idempotency_conflict` — the same key with a different body. An identical
   retry answers the original result with `replayed: true`, whatever the head.
2. `stale_head` — the candidate's head moved (a heartbeat drift, a
   withdrawal, another operator). Re-list and decide on the new head.
3. `invalid_transition` — the edge is not in the R001 table from the current
   state.
4. Preconditions, in order: `catalog_match_required`, `catalog_match_stale`
   (a recorded member no longer resolves under the current release: content
   changed — needs a fresh offer), `catalog_row_not_recommendable`
   (`listed`/`candidate`/`blocked` row), `runtime_source_not_allowed`,
   `catalog_material_unavailable` (no trusted Tier-2 material for the row).

The response (`model_admission_decision.v1`) carries `decided_by` (your
actor), the new `coordinator_event_id`, and `bound_member: null`.

## 3. Grant the money path (`settlement_capable`, dual control)

Actor A requests; actor B approves. Both must be distinct entries in
`auth.operator_keys`.

**A — request** (same endpoint, `next_state: settlement_capable`). Besides
the checks above it evaluates R003(iv): the provider's single live session
must be bound to this candidate at its current head, hash-verified and pinned
for one of the recorded admissible members (resolved in the session's OWN
release), with its receipt key present; otherwise `no_verified_session`.
Until the runtime path reports another source, a session presents
`mlx_cache` and only an `mlx_safetensors` member binds — a GGUF candidate
cannot reach `settlement_capable` yet.

The request appends NO event. The response repeats the current state twice,
`coordinator_event_id` = the evaluated head, `decided_by` = actor A, and a
non-null `pending_decision_id`. The record expires after 24 hours and dies
with any event appended for the candidate (drift, withdrawal, a decision).

**B — approve**:

```bash
curl -sS -H "Authorization: Bearer $OP_TOKEN_B" -H 'Content-Type: application/json' \
  -X POST "$COORD/admin/model-admission/decisions/<pending_decision_id>/approve" -d '{
    "schema": "model_admission_decision_approve_request.v1",
    "provider_id": "<provider_id>",
    "candidate_id": "<candidate_id>",
    "pending_decision_id": "<pending_decision_id>",
    "expected_coordinator_event_id": "<the head the request evaluated>",
    "idempotency_key": "<unique per approval>"
  }' | jq .
```

Approval precedence: `invalid_request` (path/body id or bound fields
disagree), `idempotency_conflict`, `pending_consumed` / `pending_expired` /
`no_pending_decision`, `dual_control_required` (same actor), `stale_head`
(the record is invalidated), then the R003 preconditions re-evaluated in
full, then the append. The committed response carries `bound_member`
(`source`, `artifact_id`, `hash_algorithm`, `hash`) — the exact identity the
session settles under.

## 4. Demote or revoke

`network_admitted_unsettled`, `network_visible_unpriced` and `revoked` are
plain single-operator edges through the same request (reason
`operator_<...>`). A revocation is terminal: re-entry is a fresh signed offer
from the provider.

## 5. What happens without you

The coordinator revokes on its own (actor `coordinator`, reason readable in
`models admission status` and the listing):

- `runtime_identity_drift` — the bound session serves another model id, is
  no longer hash-verified for a recorded member, or the provider's candidates
  became ambiguous for the served row;
- `receipt_key_unavailable` — a `settlement_capable` session no longer
  presents its receipt key at hello/heartbeat;
- after every catalog/feed reload (the weekly renewal included):
  `catalog_artifact_feed_changed`, `catalog_row_changed`,
  `catalog_row_ineligible`, `catalog_runtime_source_disallowed`.

A scheduled release **re-stamp** (new release id, digest and feed signature;
unchanged rows and members) revokes nothing and invalidates nothing: identity
is content-anchored. A disconnect clears the session binding (unroutable)
without a durable transition; the next hello rebinds.

## Verification

- `GET /admin/model-admission/offers?provider_id=…` shows the new
  `admission_state`, `last_event_actor: operator:<you>`, and for a settled
  candidate `session.bound: true` with `validated_release_generation` equal
  across the provider's candidates after the last reload.
- Coordinator log lines `admin_action=model_admission_decision` /
  `model_admission_decision_approved` carry the actor, candidate and event id.
- The provider sees the state through `malibu-cli models admission status
  <candidate> --json` (`model_admission_status.v1`, field set unchanged;
  `catalog_model_key` is the coordinator-resolved key or null).

## Do not

- Do not use the shared `operator_key`; do not share one `operator_keys`
  entry between two people (dual control is per actor id).
- Do not retry a failed request with a NEW idempotency key unless you intend
  a new decision; re-list first and decide on the current head.
- Do not edit admission rows in SQLite. The event log is append-only; every
  correction is a new event with an `operator_` reason.
