# SPEC-012 — Coordinator Demand-Pull Model Swap and Buyer Cold-Model Visibility

**Version:** 0.3
**Status:** Draft (round-three audit failed; not ready to lock)
**Owner:** @Augustas11
**Authority:** The still-unique normative requirements in §4 own coordinator-initiated
`set_model`, demand-pull cold wake and parked-request bounds, buyer-visible cold
model aggregation/`model_not_warm`, and coordinator loading-state visibility.
SPEC-010 owns model capability/catalog identity, SPEC-011 owns operator-pushed
binary-local warm swap, and SPEC-013 owns autotune recommendations. This draft
remains canonical because those SPEC-012 surfaces are not defined by a successor;
its superseded split narrative is archived under `docs/spec-history/`.
The retained authority is pending, not locked: the round-three record at
`audits/spec-012/SPEC-012-source-audit-history.md` reports 1 CRITICAL and 12
MAJOR findings and a NOT READY TO LOCK verdict, so `CONFORMANCE.json` records
`DECISION_REQUIRED` rather than implementation or conformance.
**Date drafted:** 2026-06-06
**Companion to (LOCKED):** SPEC-001 v1.2.4, SPEC-002 v1.3.4,
SPEC-004 v0.3.1, SPEC-008 v0.3, SPEC-006 v0.8.1.

**Trigger:** arm64golf canary run (2026-06-05). Operator reported four
concrete pains, three of them operator-facing: (1) no CLI to change
active model on a running provider; (2) restart causes WS reconnect +
cold load + red dashboard; (3) buyer console picker shows only loaded
model; (4) no discovery of expected HF IDs.

Historical split, changelog, and audit-response narrative is preserved in
[`docs/spec-history/SPEC-012-v0.3-history.md`](../docs/spec-history/SPEC-012-v0.3-history.md)
and `audits/spec-012/SPEC-012-source-audit-history.md`. This document retains
only the current draft contract, compatibility analysis, acceptance criteria,
and unresolved gaps.

---

## 1. Problem statement

### 1.1 Symptom (arm64golf canary, 2026-06-05)

Operator tried to switch the served MLX model mid-run and observed:

1. No CLI command to change the active model on a running provider.
2. Restarting with `--model <new-id>` worked, but caused WS
   reconnect + admission round-trip + cold model load (multi-minute
   total) — dashboard went red.
3. Buyer console "model picker" showed only the single loaded model,
   with no indication that the provider could serve other MLX models.
4. Operator had no in-app discovery of which MLX HF IDs the network
   expects, or which models would earn them traffic.

Operator framing: "the MLX model catalog doesn't support all MLX
available models, so providers cannot select different models easily."

### 1.2 Root cause (investigation 2026-06-06)

The phrasing is misleading. The binary's `LLMModelFactory`
(mlx-swift-examples checkout) accepts any MLX model whose `config.json`
matches one of 38 supported architectures. There is **no allowlist**
at the binary layer. The real gaps:

| Gap | Location | Effect |
|---|---|---|
| G-1 | Provider binary: 1 model per process, chosen at startup ([SPEC-001 §6.2](SPEC-001-phase3-binary.md), [MalibuCLI.swift:18](../phase3-binary/Sources/malibu-cli/MalibuCLI.swift)) | Operator must restart to change model |
| G-2 | WS auth: single `model_id`, no `supported_models[]` ([messages.go:8](../phase4-coordinator/internal/ws/messages.go)) | Coordinator only knows what is warm |
| G-3 | Coordinator `Provider` struct: same — single `ModelID` ([provider.go:50](../phase4-coordinator/internal/pool/provider.go)) | Router cannot match "find a provider that supports X" |
| G-4 | Gateway dispatch rewrites `body.model` (SPEC-004 Entry 35 workaround) | Class-alias workaround for the missing capability negotiation |
| G-5 | No discoverability surface for operators | Operators guess HF IDs |

SPEC-010 owns G-2/G-3 capability advertisement, SPEC-011 owns the local
operator-side CLI, and SPEC-013 owns recommendation discovery. This spec owns
only the coordinator-driven use of those capabilities.

---

## 2. Locked design decisions (operator-set)

Non-negotiable inputs. Not subject to audit revision.

| Lock | Decision |
|---|---|
| L-1 | **Backward compatible.** With all SPEC-010 fields absent AND `publish_unwarm_models: false`, coordinator behavior MUST be byte-identical to pre-SPEC-010 production. `/v1/models`, `/v1/status`, log lines, routing decisions, error envelopes — all identical. |
| L-2 | **No closed allowlist.** Coordinator consumes the SPEC-010 model identity set without adding a server-side whitelist. Curation remains guidance under SPEC-010/SPEC-013, never a hard rule. Permissionless onboarding stays. |
| L-3 | **One *active* model per provider process at a time.** Multi-model serving (parallel loaded weights) is OUT OF SCOPE. A provider declares `supported_models` (willing) and `loaded_model` (warm now). The set of warm models on a provider is always exactly `{loaded_model}` while `state == ready`, and `{}` while `state == loading_model`. |
| L-4 | **Pillar A hash semantics unchanged.** `model_hash` continues to refer ONLY to `loaded_model`. `supported_models` entries are unverified. SPEC-008 §5.5's five hash states are not extended. During the `loading_model` sub-state the provider is not routable (per L-3), so the hash predicate does not apply. |
| L-5 | **No paid-tier gating.** Per Entry 21, advertising more models or using warm-swap does not change earnings. SPEC-005 billing is untouched. |
| L-6 | **F-1.5 survivability invariants preserved.** No SPEC-010 wire field, message type, or routing path may feed into sticky-key derivation, expose `conv:` to the provider, hand a sticky lifecycle message to the provider, or extend sticky TTL. Cross-check: SPEC-008 §2.1–2.5. |

---

## 3. Retained demand-pull scope

The retained coordinator-driven phase closes operator pain points #1, #2, and
#3 from §1.1. The superseded operator-CLI and recommendation phases are owned
by SPEC-011 and SPEC-010/SPEC-013 respectively and are preserved only in the
linked history document.

### Coordinator demand-pull and buyer cold-model visibility

Closes G-1 (warm-swap mechanism), G-2 and G-3 (capability protocol).

- Provider declares `supported_models[]` at `auth`.
- Coordinator stores it on `Provider`; router uses it as a candidate
  filter.
- New WS message `set_model` (coordinator → provider) triggers a warm
  swap. Provider transitions `ready → loading_model → ready` with the
  new model warm. In-flight requests drain within a configurable
  timeout.
- Buyer request for a cold-but-supported model triggers an automatic
  `set_model` to a candidate provider, subject to per-provider
  cooldown and per-request ETA budget. If budget exceeds, falls
  through to existing error semantics.
- Gateway `/v1/models` aggregates the union of `supported_models`
  across `Ready` providers, with `warm: bool` per entry — surfaced
  to buyer pickers ONLY when `[catalog] publish_unwarm_models =
  true` (operator opt-in; default `false`).

**Canary pain-point closure (honest accounting):**

| Pain | Who | Phase 1 closure |
|---|---|---|
| #1 No CLI to change active model | Operator | Demand-pull provides the coordinator mechanism; SPEC-011 owns the local operator UI/CLI. |
| #2 Restart causes red dashboard | Operator | Closed: warm swap avoids restart entirely. §4.10 defines `loading` (amber) status — bounds the operator-visible regression during swap window. |
| #3 Buyer picker shows only loaded model | Buyer/Operator | **Closed only when `publish_unwarm_models: true`** (operator opt-in). Default deployment preserves byte-identical `/v1/models`; SPEC-010 owns catalog identity. |
| #4 No HF ID discovery | Operator | Owned by SPEC-010/SPEC-013, outside this contract. |

---

## 4. Demand-pull wire spec (NORMATIVE)

SPEC-010 is authoritative for `supported_models`,
`publishes_supported_models`, model-ID normalization, and the coordinator
capability fields consumed below. SPEC-011 is authoritative for local
operator-pushed swap control. This section defines only coordinator
`set_model`, demand-pull parking/routing, buyer cold-model visibility, and
loading-state integration.

### 4.4 Coordinator → provider: `set_model` (warm swap)

The `set_model` message is the wire primitive that closes G-1.

```json
{
  "type": "set_model",
  "request_id": "swap_01HK4Z3VYE...",
  "target_model_id": "mlx-community/Llama-3.1-8B-Instruct-4bit",
  "drain_timeout_seconds": 20,
  "swap_reason": "demand_pull"
}
```

Provider ack:

```json
{
  "type": "set_model_ack",
  "request_id": "swap_01HK4Z3VYE...",
  "state": "loading_model",
  "estimated_load_seconds": 18
}
```

Or reject:

```json
{
  "type": "set_model_ack",
  "request_id": "swap_01HK4Z3VYE...",
  "state": "rejected",
  "reason_code": "not_in_supported_models" | "already_loaded" | "load_in_progress" | "cooldown" | "other"
}
```

Final notification (post-load), pushed by provider:

```json
{
  "type": "set_model_complete",
  "request_id": "swap_01HK4Z3VYE...",
  "result": "succeeded",
  "loaded_model": "mlx-community/Llama-3.1-8B-Instruct-4bit",
  "model_hash": "sha256:...",
  "load_duration_ms": 17243,
  "drained_inflight_count": 1,
  "drain_timed_out_count": 0
}
```

On failure:

```json
{
  "type": "set_model_complete",
  "request_id": "swap_01HK4Z3VYE...",
  "result": "failed",
  "reason_code": "weights_not_found" | "config_invalid" | "oom" | "other",
  "rolled_back_to_model": "mlx-community/Qwen2.5-7B-Instruct-4bit"
}
```

Note: `drain_timeout` is intentionally NOT in the failure
`reason_code` enum. See R-4.4.6.

#### Rules

- **R-4.4.0** **`request_id` format and uniqueness (B2.1 fix).** The
  coordinator MUST generate `request_id` as `swap_<ULID>` where ULID
  follows Crockford's 26-character base32 encoding. The `swap_`
  prefix namespaces these IDs separately from buyer inference
  `request_id` values (which follow SPEC-001 §6.5's `req_<ULID>`
  shape) — implementations MUST NOT correlate the two namespaces.
  Each `set_model` MUST have a `request_id` that is unique among
  swaps currently in flight AND swaps completed within the prior
  `swap_request_id_retention_seconds` (default 600s, configurable
  via §4.7). Provider MUST echo the exact `request_id` in
  `set_model_ack` and `set_model_complete`; mismatched or missing
  `request_id` on a response MUST be discarded by the coordinator
  with an audit-log warning. Coordinator MUST drop unsolicited
  `set_model_complete` messages whose `request_id` was retired
  past the retention window.
- **R-4.4.1** Coordinator MUST NOT send `set_model` unless
  `target_model_id` is in the provider's `SupportedModels`
  (case-folded per SPEC-010's model-ID normalization contract). Sending a non-supported model is a
  coordinator bug; provider MUST reject with
  `"not_in_supported_models"`.
- **R-4.4.2** Coordinator MUST NOT initiate `set_model` to a
  provider whose `SwapState` is `loading_model` or whose last
  `set_model_complete` was within `swap_cooldown_seconds` (default
  60s; configurable via `[catalog] swap_cooldown_seconds`). Per-
  provider, not global.
- **R-4.4.3** Upon emitting `set_model`, coordinator MUST set the
  provider's `SwapState` to `swap_pending`. Upon receiving
  `set_model_ack{state: "loading_model"}`, MUST transition to
  `loading_model`. Upon `set_model_complete{result: "succeeded"}`,
  MUST transition to `ready` with the new `ModelID` and `ModelHash`.
  Upon `set_model_complete{result: "failed"}`, MUST transition to
  `ready` with the rolled-back `ModelID` (provider preserves the
  prior weights until the new ones successfully load).
- **R-4.4.4** While `SwapState ∈ {swap_pending, loading_model}`,
  the provider MUST be routing-ineligible (treated as `state !=
  ready` for purposes of SPEC-004 candidate selection).
- **R-4.4.5** In-flight requests on the provider at the time
  `set_model` is sent MUST be allowed to complete on the OLD model.
  Provider MUST refuse new inference requests during the swap
  window. Coordinator MUST NOT route to this provider while
  `SwapState ∈ {swap_pending, loading_model}`.
- **R-4.4.6** **Drain timeout — per-in-flight-request outcome only
  (B2.2 fix).** `drain_timeout_seconds` (default 20, configurable per
  coordinator) bounds how long the provider waits for in-flight
  requests to finish on the OLD model before forcing the swap. After
  timeout, any still-in-flight requests MUST receive a provider-side
  `503` with OpenAI envelope `{type: "service_unavailable", code:
  "swap_drain_timeout"}` and the swap MUST proceed to
  `loading_model`. **Drain timeout does NOT fail the swap.** The
  provider MUST emit `set_model_complete{result: "succeeded"}` with
  `drain_timed_out_count` reflecting how many in-flight requests were
  killed, allowing the coordinator to surface partial-impact metrics.
  The `set_model_complete{result: "failed"}` enum therefore does NOT
  include `drain_timeout`; load failures use `weights_not_found`,
  `config_invalid`, `oom`, or `other`.
- **R-4.4.7** **SPEC-008 / Pillar A interaction (L-4, L-6).**
  - During `SwapState ∈ {swap_pending, loading_model}`, the
    provider's previously-reported `model_hash` is for the
    OLD model. Because the provider is not routing-eligible
    (R-4.4.4), the hash predicate does not apply during this
    window — SPEC-008 §5.6 routing exclusion only fires on
    candidates, and the provider is not a candidate.
  - On `set_model_complete{result: "succeeded"}`, the provider
    MUST include `model_hash` for the NEW model. Coordinator MUST
    run normal Pillar A verification (SPEC-008 §5.3–5.6) before
    marking the provider routing-eligible for the new model. If
    verification fails per `tier2.require_hash_verified: true`,
    the provider remains routing-ineligible with the new model;
    the swap is "loaded but not verified" and the coordinator
    SHOULD record an audit-log event (SPEC-008 audit-log
    namespace).
  - No new `hash_status` value is introduced. SPEC-008 §5.5's
    five states remain authoritative. (Audit fix F1.)
- **R-4.4.8** **F-1.5 invariants (L-6).** `set_model`,
  `set_model_ack`, and `set_model_complete` MUST NOT include
  `conv:`, `account_id`, sticky session identifiers, or any input
  that could be used as a sticky-derivation source. `swap_reason`
  is a closed enum (`demand_pull` | `operator_push`), not a buyer-
  or session-identifying string. Future swap_reason values (e.g.
  `policy`) MUST be added only when an actual code path uses them,
  per Entry 21's "no premium positioning until enforcement is live"
  principle applied here as "no enum values until a producer exists."
  (B2.3 / OQ-5 closure: `policy` removed from v0.3 enum.)
- **R-4.4.9** **Audit-log event types and payloads (G2.3 / H2.2
  fix).** Each swap MUST emit the events below under the existing
  SPEC-002 §11 audit-log namespace. SPEC-002 v1.3.5 candidate per
  §8.2 will incorporate these payload schemas by reference.

  `model_swap_started` — emitted by coordinator on `set_model` send:
  ```json
  {
    "event": "model_swap_started",
    "ts": "2026-06-06T14:23:09.123Z",
    "swap_request_id": "swap_01HK4Z3VYE...",
    "provider_assigned_id": "p_01HK...",
    "from_model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "to_model_id": "mlx-community/Llama-3.1-8B-Instruct-4bit",
    "swap_reason": "demand_pull",
    "drain_timeout_seconds": 20,
    "parked_request_count": 3
  }
  ```

  `model_swap_completed` — emitted by coordinator on
  `set_model_complete{succeeded}`:
  ```json
  {
    "event": "model_swap_completed",
    "ts": "2026-06-06T14:23:31.456Z",
    "swap_request_id": "swap_01HK4Z3VYE...",
    "provider_assigned_id": "p_01HK...",
    "loaded_model": "mlx-community/Llama-3.1-8B-Instruct-4bit",
    "load_duration_ms": 17243,
    "drained_inflight_count": 1,
    "drain_timed_out_count": 0,
    "hash_verification": "hash_verified" | "hash_mismatch" |
                         "hash_invalid" | "uncatalogued" |
                         "catalog_unavailable",
    "parked_requests_released": 3,
    "total_swap_duration_ms": 22333
  }
  ```

  `model_swap_failed` — emitted by coordinator on
  `set_model_complete{failed}` OR on `set_model_ack{rejected}`:
  ```json
  {
    "event": "model_swap_failed",
    "ts": "2026-06-06T14:23:14.789Z",
    "swap_request_id": "swap_01HK4Z3VYE...",
    "provider_assigned_id": "p_01HK...",
    "target_model_id": "mlx-community/Llama-3.1-8B-Instruct-4bit",
    "rolled_back_to_model": "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "failure_stage": "rejected" | "load_failed",
    "reason_code": "not_in_supported_models" | "already_loaded" |
                   "load_in_progress" | "cooldown" |
                   "weights_not_found" | "config_invalid" |
                   "oom" | "other",
    "parked_requests_drained_to_other": 2,
    "parked_requests_5xx": 1
  }
  ```

  `cold_wake_queued` — emitted by coordinator when a buyer request
  is parked on a cold-wake queue:
  ```json
  {
    "event": "cold_wake_queued",
    "ts": "2026-06-06T14:23:09.111Z",
    "buyer_request_id": "req_01HK...",
    "swap_request_id": "swap_01HK4Z3VYE...",
    "req_model": "mlx-community/Llama-3.1-8B-Instruct-4bit",
    "queue_position": 1,
    "queue_depth_after_enqueue": 1,
    "remaining_eta_seconds": 87
  }
  ```

  `cold_wake_drained` — emitted by coordinator when a parked
  request exits the queue (dispatched, retried, or 503):
  ```json
  {
    "event": "cold_wake_drained",
    "ts": "2026-06-06T14:23:31.456Z",
    "buyer_request_id": "req_01HK...",
    "swap_request_id": "swap_01HK4Z3VYE...",
    "outcome": "dispatched" | "retried_on_other_candidate" |
               "503_eta_expired" | "503_swap_failed" |
               "503_queue_overflow",
    "queue_dwell_ms": 22330
  }
  ```

  All redaction rules from SPEC-006 §F-1.5 apply: NO `conv:`
  identifier, NO raw `account_id`, NO buyer prompt text in any
  event payload.

### 4.5 Router: candidate filter + cold-supported wake path

Three changes to SPEC-004 v0.3.1 §4 dispatch, all additive.

#### 4.5.1 Candidate filter

```
candidates(req_model) :=
    {p in pool |
        p.State == Ready AND
        p.SwapState ∈ {ready, ∅} AND
        p.SlotsFree > 0 AND
        req_model ∈ p.SupportedModels  (case-folded per SPEC-010)}
```

Note: `req_model in p.SupportedModels` subsumes the prior
`req_model == p.ModelID` predicate, because SPEC-010 requires
`ModelID ∈ SupportedModels`.

#### 4.5.2 Warm-first ranking (NORMATIVE for Phase 1)

(Audit fix C2.)

Within the candidate set, the dispatcher MUST partition by:

```
warm_candidates := {p in candidates | p.ModelID == req_model (case-folded)}
cold_candidates := candidates \ warm_candidates
```

The dispatcher MUST select from `warm_candidates` if non-empty,
applying the existing SPEC-004 v0.3.1 §4 ranking among the warm set
unchanged. If `warm_candidates` is empty AND `cold_candidates` is
non-empty, the dispatcher proceeds to §4.5.3 (cold-wake path).

Sticky-affinity (SPEC-004 §4) and hard-pin (SPEC-008 §5.6 hard-pin)
predicates apply to the warm subset first, then the cold subset.
If sticky-affinity points at a provider whose loaded model is no
longer `req_model` (e.g. the sticky provider hot-swapped after the
sticky was established), the dispatcher MUST break sticky and
re-rank within `warm_candidates`; if no warm candidate remains, the
cold-wake path runs. (Audit fix C3.)

Hard-pin to a cold-supported provider triggers a swap on that
provider (subject to §4.4 cooldown). If swap is on cooldown,
hard-pin request fails with `tier2_hard_pin_predicate_failed` per
SPEC-008 §5.6.

#### 4.5.3 Cold-wake path (the closure of G-1's UX value)

When `warm_candidates == {}` AND `cold_candidates != {}`:

- **R-4.5.3.1** Dispatcher MUST select ONE cold candidate via the
  existing SPEC-004 §4 ranking among the cold subset.
- **R-4.5.3.2** Dispatcher MUST send `set_model{target_model_id:
  req_model, swap_reason: "demand_pull"}` to the selected provider
  per §4.4.
- **R-4.5.3.3** The buyer request MUST be parked in a per-swap
  request queue for up to `cold_wake_request_eta_seconds` (default
  90s, configurable). During this window, additional buyer requests
  for the same `req_model` MAY join the queue, subject to the
  bounds in R-4.5.3.8.
- **R-4.5.3.4** Upon `set_model_complete{result: "succeeded"}` AND
  hash verification per R-4.4.7, the parked requests MUST be
  dispatched in FIFO order to the now-warm provider.
- **R-4.5.3.5** If the swap fails (`set_model_complete{result:
  "failed"}`) OR ETA expires before completion OR the provider
  responds with `set_model_ack{state: "rejected"}` for any
  `reason_code` (including `cooldown`, `not_in_supported_models`,
  `already_loaded`, `load_in_progress`, `other`):
  - For each parked request: if other cold candidates remain that
    are not currently swapping and not on cooldown, the dispatcher
    MAY retry on the next-ranked cold candidate (one retry maximum
    per buyer request, to bound latency). The retry path MUST emit
    `cold_wake_drained{outcome: "retried_on_other_candidate"}` for
    the parked request before re-enqueuing on the new swap.
  - Otherwise, parked requests MUST receive the existing
    `503 model_not_warm` error envelope per §4.6.
- **R-4.5.3.6** ETA budget is per-buyer-request, not per-swap. A
  request that joins a swap queue with 40s elapsed gets 50s
  remaining of its 90s budget, not a fresh 90s. Retry per R-4.5.3.5
  consumes from the same per-request budget.
- **R-4.5.3.7** **Cold-wake attempt accounting (C2.1 fix).** A
  cold-wake swap is NOT a billable inference attempt. Specifically:
  - The cold-wake attempt MUST NOT write a SPEC-005 X-2
    `request_log` row. The buyer's eventual successful dispatch
    (or 503) writes exactly one row per buyer request, regardless
    of how many cold-wake swap attempts intervened.
  - SPEC-004 `provider_retry_attempts` counter is unaffected by
    cold-wake retries; per-attempt rows are reserved for actual
    inference dispatches per SPEC-005 §3 / X-2.
  - Swap-side audit (the events in R-4.4.9, plus `cold_wake_queued`
    and `cold_wake_drained`) is the authoritative record of
    cold-wake activity for incident review. The buyer's
    `request_log.swap_request_ids: []text` SHOULD list any
    `swap_<ULID>` values the request queued behind, for
    correlation; this is informational, not billable.
  - Coordinator MUST NOT charge SPEC-005 settlement for a buyer
    request that 503s out of cold-wake without ever reaching a
    provider for inference.
- **R-4.5.3.8** **Parked-queue bounds (C2.2 fix).** The coordinator
  MUST enforce three queue bounds, applied in order:
  1. **Per-swap queue depth**: `[catalog]
     cold_wake_queue_depth_per_swap` (default 64). Overflow MUST
     immediately 503 the incoming buyer request with
     `model_not_warm` envelope per §4.6.2 (no parking).
  2. **Per-account in-flight**: `[catalog]
     cold_wake_max_inflight_per_account` (default 8). Buyer
     requests whose account already has ≥ N parked requests across
     any swap MUST immediately 503 (no parking).
  3. **Coordinator-global**: `[catalog]
     cold_wake_total_inflight_max` (default 512). Hard ceiling
     across all swaps. Overflow MUST 503 immediately.

  Overflow events MUST emit `cold_wake_drained{outcome:
  "503_queue_overflow"}`. These bounds protect the coordinator
  from thundering-herd OOM during a popular cold-model surge.

#### 4.5.4 Disabling cold-wake (operator escape valve)

Coordinator config `[catalog] cold_wake_enabled` (default `true`).
When `false`, cold-supported requests MUST return
`503 model_not_warm` per §4.6 immediately, with no `set_model`
dispatched. Useful for operators who want pure capability
advertisement without warm-swap behavior.

### 4.6 Gateway: `/v1/models` and error envelopes

#### 4.6.1 `/v1/models` aggregation

Post-SPEC-010, gateway `/v1/models` ([server.go:143](../phase5-gateway/internal/router/server.go))
returns the union of `SupportedModels` across all `Ready`
(non-swapping) providers, deduplicated case-folded.

Each entry gains optional field `warm: bool`:

```json
{
  "id": "mlx-community/Llama-3.1-8B-Instruct-4bit",
  "object": "model",
  "warm": false,
  "owned_by": "macprovider"
}
```

- **R-4.6.1.1** `warm: true` iff at least one `Ready` provider has
  this model as `ModelID` (i.e. it is in `warm_candidates` for some
  request right now).
- **R-4.6.1.2** Config flag `[catalog] publish_unwarm_models`:
  - When `false` (DEFAULT): only warm models appear in
    `/v1/models`. The `warm` field is omitted from response
    entries. Behavior is byte-identical to pre-SPEC-010
    `/v1/models` output. (Audit fix D1, OQ-1 resolution.)
  - When `true`: union of warm + cold-supported models appears,
    with `warm: bool` populated.
- **R-4.6.1.3** When `publish_unwarm_models: true`, response is no
  longer byte-identical to pre-SPEC-010. Operator opt-in only.
- **R-4.6.1.4** **Pillar A interaction for cold-supported entries
  (E2.1 fix).** When SPEC-008 Pillar A observation or enforcement
  is active AND `publish_unwarm_models: true`, cold-supported
  entries (entries with `warm: false`) MUST be emitted in
  `/v1/models` WITHOUT the SPEC-008 §5.7 `hash_verified` field and
  WITHOUT the `hash_verification` block. Concretely:
  - A cold-supported entry's JSON object contains only the existing
    SPEC-001 §6.1 fields plus `warm: false`. No hash-related field
    appears.
  - SPEC-008 §5.7 `verified_provider_count`,
    `uncatalogued_provider_count`, `mismatch_provider_count`,
    `invalid_provider_count`, and `catalogued` MUST NOT count
    providers that merely list the model in `supported_models`
    without it being `loaded_model`. These counts are exclusively
    over providers in `warm_candidates(req_model)` per §4.5.1.
  - Rationale: L-4 binds Pillar A semantics to the loaded model
    only. Surfacing hash counts for cold-supported entries would
    create the false impression that a not-yet-loaded model has
    integrity provenance.

**Default flipped from v0.1.** v0.1 had `publish_unwarm_models:
true` as default. Round-1 audit OQ-1 raised that a default-true
ships a visible behavior change to every existing buyer client.
v0.2 defaults to `false` (safer) and lets operators opt in.

#### 4.6.2 Error envelope: `model_not_warm`

When cold-wake is disabled (§4.5.4), times out (R-4.5.3.5), or
exhausts retries, return:

```http
HTTP/1.1 503 Service Unavailable
Retry-After: 30
Content-Type: application/json

{
  "error": {
    "type": "service_unavailable",
    "code": "model_not_warm",
    "message": "Model 'mlx-community/Llama-3.1-8B-Instruct-4bit' is supported by the provider pool but is not currently loaded. Retry after the indicated interval.",
    "param": "model",
    "retry_after_seconds": 30
  }
}
```

- **R-4.6.2.1** `Retry-After` header MUST be set. Value is the
  estimated time-to-warm based on either (a) the longest
  outstanding swap for this model in the queue or (b) a coordinator
  default (`[catalog] model_not_warm_retry_after_seconds`, default
  30s) when no swap is in flight.
- **R-4.6.2.2** `error.code` MUST be exactly `"model_not_warm"`.
- **R-4.6.2.3** OpenAI-SDK compatibility: `error.type =
  "service_unavailable"` matches the OpenAI Python SDK's mapping
  to `RateLimitError`/`APIStatusError`; clients see a 503 with a
  `Retry-After`, no schema-validation crash. (Audit fix D2.)

#### 4.6.3 Error envelope: `model_not_found` (unchanged)

When the request's `model` is in NO provider's `SupportedModels`,
return existing `404 model_not_found` per SPEC-001 §6.1. Unchanged
from current behavior.

### 4.7 Config additions

```toml
[catalog]
# Max entries accepted in supported_models. Default 64.
max_supported_models_per_provider = 64

# Whether /v1/models exposes cold-supported models. Default false (v0.2 change).
# When true, response gains a `warm: bool` field per entry.
publish_unwarm_models = false

# Whether cold-supported requests trigger an automatic warm swap.
# Default true. When false, cold-supported = immediate 503 model_not_warm.
cold_wake_enabled = true

# Per-buyer-request ETA budget for cold-wake path. v0.3: retuned from 60s
# to 90s so that drain (20s) + load (~20s typical) + retry path has runway.
cold_wake_request_eta_seconds = 90

# Per-provider minimum interval between coordinator-initiated set_model calls.
swap_cooldown_seconds = 60

# Default drain timeout in set_model dispatch. v0.3: retuned from 30s to 20s.
# Combined with typical MLX load (~15-25s), gives a realistic retry margin
# under the 90s buyer ETA budget.
swap_drain_timeout_seconds = 20

# Default Retry-After when no in-flight swap exists.
model_not_warm_retry_after_seconds = 30

# Cold-wake parked-queue bounds (R-4.5.3.8, C2.2 fix).
cold_wake_queue_depth_per_swap = 64
cold_wake_max_inflight_per_account = 8
cold_wake_total_inflight_max = 512

# Swap request_id retention window for de-dup and out-of-order ack handling.
# Coordinator drops set_model_complete messages whose request_id was retired.
swap_request_id_retention_seconds = 600
```

- **R-4.7.1** Defaults preserve L-1: with `publish_unwarm_models =
  false` AND no `set_model` ever issued (e.g. legacy providers only),
  coordinator behavior is byte-identical to pre-SPEC-010.
- **R-4.7.2** `cold_wake_enabled = true` plus `publish_unwarm_models
  = false` is the recommended "see operator pain fixed, see no
  visible buyer change" configuration. Cold-wakes still fire when
  buyers request models they happen to know about (e.g. via
  out-of-band catalog), they just don't get advertised in
  `/v1/models`.
- **R-4.7.3** **Default timing budget (C2.3 fix).** Under default
  values, a single-attempt cold-wake budget breakdown for a typical
  7-8B 4-bit MLX model: drain ≤ 20s + load 15-25s = 35-45s total,
  leaving 45-55s of the 90s buyer ETA for one retry attempt on
  another candidate. This makes the R-4.5.3.5 retry path
  realistically exercisable, not theoretical. Operators MAY tune
  `swap_drain_timeout_seconds` downward (less mercy on long
  generations) or `cold_wake_request_eta_seconds` upward (more
  patient buyers) per their workload profile.

### 4.10 Provider state visibility during swap (F2.2 fix)

The arm64golf canary "red dashboard during restart" pain (§1.1 #2)
is closed mechanically by avoiding the restart. But the swap itself
introduces a new transient state (`swap_pending`, `loading_model`)
that operator-facing dashboards might naively render as "down" (red),
re-creating the same visual regression. §4.10 defines a minimal
status contract that bounds this risk.

- **R-4.10.1** Coordinator `/v1/status` per-provider entry MUST
  include a `state` field with one of the following string values:
  - `"ready"` — provider is `State == Ready` and `SwapState ∈
    {ready, ∅}`. Idiomatic dashboard render: green.
  - `"loading"` — provider is `State == Ready` and `SwapState ∈
    {swap_pending, loading_model}`. Idiomatic render: amber. The
    provider is alive, healthy, and intentionally not routable.
  - `"down"` — provider is `State != Ready` for reasons OTHER
    than swap (disconnect, hash_mismatch under
    `require_hash_verified: true`, recovery hold, etc.).
    Idiomatic render: red.
- **R-4.10.2** The `state` field is NEW in v0.3. To preserve L-1
  byte-identical for legacy deployments, the field appears in
  `/v1/status` ONLY when at least one provider in the response has
  ever transitioned through a SPEC-010 swap state. If the field is
  absent, dashboard implementations MUST fall back to existing
  per-provider state semantics (no behavior change).
- **R-4.10.3** Coordinator MUST also include `swap_pending_since`
  (ISO-8601 timestamp) on entries where `state == "loading"`, so
  dashboards can render an elapsed-time indicator. Absent on
  `ready` / `down` entries.
- **R-4.10.4** AC-22's "no red dashboard" assertion is satisfied
  iff `/v1/status` returns `state: "loading"` (not `state: "down"`)
  for the duration of a typical 20-30s warm swap. Dashboard
  rendering policy (color choice, transition animations) is out of
  scope — SPEC-010 only commits to the underlying status value.

---

## 7. Backward compatibility

### 7.1 Legacy provider against SPEC-010 coordinator

Defined as a provider that sends `auth` with no
`supported_models`, no `publishes_supported_models`.

- Coordinator synthesizes `SupportedModels: [ModelID]` per SPEC-010.
- `PublishesSupportedModels = false` per SPEC-010.
- `/v1/status` for this provider is byte-identical to pre-SPEC-010
  (SPEC-010 gates it on `PublishesSupportedModels`).
- `/v1/models` aggregation includes the model as warm (it's in
  `SupportedModels` AND is the loaded model).
- With `publish_unwarm_models: false` (default), this provider
  contributes one entry to `/v1/models`, byte-identical to today.
- Coordinator will NEVER send `set_model` to this provider for a
  model outside `[ModelID]`, because R-4.4.1 limits targets to
  `SupportedModels`. A demand-pull for a different model finds no
  candidate among legacy providers, falls through to other
  candidates or `model_not_warm`.

### 7.2 SPEC-010 provider against legacy coordinator

- Provider sends `supported_models` and `publishes_supported_models`;
  legacy coordinator's `json.Decoder` ignores unknown fields by
  default (verify: no `DisallowUnknownFields()` in
  `phase4-coordinator/internal/ws/messages.go` parsers; standard Go
  behavior). Provider is admitted with `model_id` only.
- Legacy coordinator never sends `set_model`. Provider never
  receives swap messages. Provider's swap capability lies dormant.
- Operator UX vs legacy coordinator: identical to today. No
  regression.

### 7.3 What's visible to buyers with all defaults

- `/v1/models`: byte-identical to today (R-4.6.1.2 default false).
- `/v1/chat/completions`: behavior identical when buyer asks for a
  model that some provider has warm.
- New: when buyer asks for a cold-supported model AND
  `cold_wake_enabled = true` (default), the request may take up to
  90s extra latency for the swap (per v0.3 retuned default).
  This is a new behavior. Operators who reject this set
  `cold_wake_enabled = false`.

(Audit fix D3 → resolution: defaults preserve `/v1/models` shape and
404 vs 503 semantics, but introduce a latency-budget for cold-wake.
Operators can opt out via `cold_wake_enabled = false`.)

---

## 9. Acceptance criteria

Phase 1 (gates v0.2 implementation):

### Routing

- **AC-10** Two providers, both with `supported_models: [A]`,
  one with `model_id: A` (warm), one with `model_id: B` (cold-for-A).
  Buyer request for A always routes to the warm provider. The cold
  provider is NOT swapped to A on demand because warm_candidates is
  non-empty.
- **AC-11** Two providers, both with `supported_models: [A, B]`.
  Provider P1 has `model_id: A` (warm-for-A, cold-for-B). Provider
  P2 has `model_id: A` (warm-for-A, cold-for-B). Buyer request for
  B with `cold_wake_enabled: true`: dispatcher sends `set_model`
  to one of P1/P2, parks the request, dispatches when swap
  completes and Pillar A verification passes.
- **AC-12** Same setup as AC-11 but `cold_wake_enabled: false`.
  Buyer request for B returns `503 model_not_warm` immediately;
  no `set_model` is sent.
- **AC-13** Buyer request for model Z (in no provider's
  `SupportedModels`) returns `404 model_not_found`. Unchanged from
  pre-SPEC-010.

### Warm-swap

- **AC-14** Coordinator issues `set_model` to provider P with
  `target_model_id: B`. Provider acks with
  `state: "loading_model"`. Coordinator marks P
  routing-ineligible. Existing in-flight requests on P with
  `model_id: A` complete normally within drain timeout.
- **AC-15** Coordinator issues `set_model` for a target NOT in
  the provider's `SupportedModels`. Provider responds with
  `set_model_ack{state: "rejected", reason_code:
  "not_in_supported_models"}`. Coordinator transitions provider
  back to `ready` with original `model_id`. This MUST NOT happen
  in normal operation per R-4.4.1; the test verifies the safety
  path.
- **AC-16** Coordinator issues `set_model` to provider P. Provider
  fails to load (e.g. simulated OOM): `set_model_complete{result:
  "failed", reason_code: "oom", rolled_back_to_model: A}`.
  Coordinator marks P routing-eligible for A again with no data
  loss.
- **AC-17** Swap cooldown: after a successful swap on P, a second
  `set_model` to P within `swap_cooldown_seconds` is NOT issued by
  the coordinator. Parked requests fall through to other candidates
  or `503 model_not_warm` per §4.5.3.5.
- **AC-18** Drain timeout: in-flight requests on P that don't
  complete within `drain_timeout_seconds` receive
  `503 swap_drain_timeout`. Swap proceeds.

### SPEC-008 / Pillar A interaction

- **AC-19** Provider P with `model_id: A`, `model_hash: hash(A)`
  (verified per Pillar A). Coordinator issues `set_model` for B.
  During swap window, the prior `hash_verified` status is
  irrelevant because P is routing-ineligible. On
  `set_model_complete` with new `model_hash: hash(B)`, coordinator
  re-runs Pillar A verification. If `hash(B)` matches the
  catalogued entry for B, P becomes `hash_verified` for B and
  routing-eligible. (Audit fix F1.)
- **AC-20** SPEC-008 `tier2.require_hash_verified: true` config:
  swap completes with an unverified `model_hash` (mismatch or
  uncatalogued). P remains routing-ineligible for B.
  `tier2_hash_verified_required` error path fires for buyer
  requests for B if no other warm verified provider exists.

### Error envelopes

- **AC-21** `503 model_not_warm` response includes `Retry-After`
  header, `error.code: "model_not_warm"`, `error.type:
  "service_unavailable"`, `retry_after_seconds` field. JSON
  validates against OpenAI SDK error envelope schema. (Audit fix
  D2.)

### G2.2 — Cold-wake rejection branches (new in v0.3)

- **AC-31** Cold-wake retry on `cooldown` rejection: pool has two
  cold candidates P1, P2 for model B. P1 was successfully swapped
  to a different model 30s ago (within `swap_cooldown_seconds`).
  Buyer request for B: dispatcher tries P1 first; P1 replies
  `set_model_ack{state: "rejected", reason_code: "cooldown"}`.
  Coordinator MUST retry on P2 within the buyer's remaining ETA
  budget per R-4.5.3.5. If P2 swap succeeds, buyer request
  dispatches. Cold_wake_drained event for the buyer MUST record
  `outcome: "retried_on_other_candidate"` for the P1 leg, then
  `outcome: "dispatched"` after P2 serves.

### G2.3 — Audit-log event emission (new in v0.3)

- **AC-32** End-to-end swap emits the full event sequence with
  payload schemas per R-4.4.9. For a successful demand-pull swap
  with 1 parked buyer request: events `model_swap_started`,
  `cold_wake_queued`, `model_swap_completed`, `cold_wake_drained
  {outcome: "dispatched"}` are emitted in that order with the
  fields specified in R-4.4.9. For a swap that fails with `oom`:
  `model_swap_started`, `cold_wake_queued`, `model_swap_failed
  {failure_stage: "load_failed", reason_code: "oom"}`,
  `cold_wake_drained{outcome: "503_swap_failed"}`. Test asserts
  every required field present and no buyer prompt text or
  `conv:` identifier appears in any event.

### Queue-bound enforcement (new in v0.3, C2.2 coverage)

- **AC-33** R-4.5.3.8 per-swap queue depth: with
  `cold_wake_queue_depth_per_swap: 4`, send 5 simultaneous buyer
  requests for the same cold model B. First 4 are parked
  (`cold_wake_queued` events emitted with `queue_position: 1..4`).
  The 5th is immediately 503'd with `model_not_warm` envelope and
  `cold_wake_drained{outcome: "503_queue_overflow"}` event.
- **AC-34** R-4.5.3.8 per-account in-flight: with
  `cold_wake_max_inflight_per_account: 2`, account X sends 3
  requests for cold model B. First 2 park; 3rd is immediately
  503'd with `outcome: "503_queue_overflow"`.

### Phase 1 ↔ SPEC-005 billing isolation (new in v0.3, C2.1 coverage)

- **AC-35** Cold-wake swap attempts are not billable. Buyer
  account starts at 0 billed requests. Send 1 request for cold
  model B that ultimately 503s (swap fails + no retry candidate).
  Account's billed request count remains 0; SPEC-005 X-2
  `request_log` table contains zero rows for this buyer request
  (no provider attempted inference). Swap-side audit-log events
  per R-4.4.9 ARE present.

---

## 10. Open gap from round-three audit

- **OQ-4** `set_model_ack.estimated_load_seconds`: v0.3 specifies
  optional (provider can return 0 if unknown), coordinator falls
  back to `model_not_warm_retry_after_seconds` for `Retry-After`.
  Is this the right policy or should the provider be required to
  return an estimate?

---

## 11. Out of scope

- Multi-model serving in a single provider process (parallel
  loaded weights). Single warm model per process remains the rule
  (L-3).
- GPU/CPU memory accounting per advertised supported model.
  Provider self-reports `supported_models`; coordinator does not
  audit memory feasibility.
- Catalog signing; model catalog identity is owned by SPEC-010.
- Billing or earnings differences per model (L-5).
- Buyer-side model recommendation ("you might also try …").
- Operator UI/dashboard for swap monitoring.

---

## 12. References

- [SPEC-001 v1.2.4](SPEC-001-phase3-binary.md) §6.1, §6.2
- [SPEC-002 v1.3.4](SPEC-002-coordinator.md) §3, §5, §7.2, §11
- [SPEC-004 v0.3.1](SPEC-004-smart-router.md) §4
- [SPEC-008 v0.3](SPEC-008-tier2.md) §5 (Pillar A), §2 (F-1.5)
- [SPEC-006 v0.8.1](SPEC-006-buyer-api.md) §F-1.5
- [SPEC-010 round-1 audit](../audits/spec-010/SPEC-010-audit.md) (Codex GPT-5,
  2026-06-06)
- [phase3-binary/Sources/malibu-cli/MalibuCLI.swift](../phase3-binary/Sources/malibu-cli/MalibuCLI.swift)
- [phase3-binary/Sources/malibu-cli/ModelRuntime.swift](../phase3-binary/Sources/malibu-cli/ModelRuntime.swift)
- [phase4-coordinator/internal/ws/messages.go](../phase4-coordinator/internal/ws/messages.go)
- [phase4-coordinator/internal/pool/provider.go](../phase4-coordinator/internal/pool/provider.go)
- [phase5-gateway/internal/router/server.go](../phase5-gateway/internal/router/server.go)
- Decision-log Entry 21 (no premium positioning), Entry 35
  (SPEC-004 Pillar B dispatch-rewrite)
- arm64golf canary run, 2026-06-05 (trigger)
