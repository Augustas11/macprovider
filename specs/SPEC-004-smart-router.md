# SPEC-004 — Smart Router

**Version:** 0.3 (2026-05-30, dispatch-rewrite audit fix)
**Extends:** SPEC-002 v1.3.3 § 5 (routing algorithm)
**Depends on:** SPEC-001 v1.2.4 (Phase 3 binary wire protocol, locked), SPEC-003 v0.7, SPEC-006 v0.7 (Pillar A gated on SPEC-006 v0.8)

SPEC-004 is additive. With every new `routing.*` key at its default value,
the coordinator MUST preserve SPEC-002 v1.3.3 routing behavior, including
deterministic equal-metric tie-breaking, one-shot F-4 failover only, exact
model ID routing, and no sticky affinity.

## Changelog

### v0.3 (2026-05-30)

- Adds FR-SR-7a after live deploy testing showed model-class aliases were
  selected correctly but forwarded unchanged to providers instead of being
  rewritten to the chosen provider's concrete model ID at dispatch time.

### v0.2 (2026-05-30)

- Resolves the v0.1 audit's R-1 critical finding: `X-MacProvider-Session`
  remains a SPEC-002 hard pin to `assigned_id` only, sticky affinity uses a
  distinct gateway-derived internal conversation field named
  `routing_internal.conversation_key`, and Pillar A implementation is gated on
  SPEC-006 v0.8.
- Resolves R-2 by defining `routing.retry_per_attempt_timeout_s`, the retry
  wall-clock budget formula, and FR-P11a C2 cancel-during-retry breaker
  attribution.
- Resolves R-3 by replacing byte-identical default wording with identical
  provider selection and buyer-visible behavior, while allowing additive
  internal routing-decision logging; default tests now cover hard pins and the
  sticky-off no-op.
- Closes OQ-SR-1 through OQ-SR-5: sticky defaults off, `balanced` has a
  normative score formula, `X-MacProvider-Retry` is public opt-in, and
  `request_log.retried` counts only explicit SPEC-004 retry attempts.
- Closes audit gaps for sticky write-on-retry, sticky map synchronization,
  sticky-vs-preference sorting, per-request breaker-degradation cap, and class
  reconfiguration invalidation of stale sticky entries.

---

## 0. Operator-paste invocation block

```
Implement SPEC-004. As you work, maintain a running
phase4-coordinator/implementation-notes.html that captures anything
I should know about how the implementation diverges from or interprets
the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise
```

---

## 1. Mission

Make the coordinator route smartly: reuse warm provider caches across a
buyer's turns, expose latency/quality-tiered model classes, spread load
evenly across equivalent providers, and recover transient failures more
aggressively than the existing one-shot failover, without breaking
reproducible audit logs, the locked SPEC-001 provider protocol, or the
current money path.

---

## 2. Scope

### In scope

- Coordinator-internal sticky session affinity keyed only by a distinct
  SPEC-006-derived internal conversation key. Pillar A is specified here but
  MUST NOT be implemented until SPEC-006 v0.8 defines that key's gateway
  derivation, lifts SPEC-006 § 1.3's sticky-caching prohibition for this
  coordinator-internal use, and refreshes the Tier 1 privacy disclosure.
- Config-driven model-class aliases such as `mlx-fast`, `mlx-balanced`, and
  `mlx-accurate`, resolved before SPEC-002 candidate filtering.
- Opt-in coordinator-managed retries across different eligible providers for
  retryable, pre-commit transient failures.
- Opt-in randomized epsilon-tolerance tiebreaking with auditable decision logs.
- Additive buyer API deltas that SPEC-006 can expose without breaking existing
  OpenAI-compatible clients.

### Out of scope

- Any SPEC-001 / phase3-binary provider wire-protocol change.
- Rewards, billing, settlement, or contributor distribution logic (SPEC-005).
- AntFeed seller integration (SPEC-007).
- Tier-2 attestation, provider-leg encryption, or model-weight verification.
- New provider binary behavior or provider-managed session caches.
- Replacing SPEC-002 § 5. SPEC-004 extends that algorithm only.
- Reading sticky affinity from raw buyer headers. In particular,
  `X-MacProvider-Session` is never a sticky key; it remains SPEC-002 FR-R3
  hard-pin input only.

---

## 3. Architecture

SPEC-004 layers onto SPEC-002 § 5 as a routing pipeline. The implementation
MUST reuse existing coordinator pool eligibility, preflight, F-4 failover, and
FR-P11a breaker primitives instead of creating a parallel router.

Ordered pipeline:

1. Parse buyer request and estimate tokens exactly as SPEC-002 § 5 does.
2. Resolve `request.model`:
   - If it is a configured model-class alias, expand it to eligible concrete
     model IDs and class objective metadata.
   - Otherwise treat it as a concrete model ID with SPEC-002's
     case-insensitive exact-match semantics.
3. Resolve explicit hard pin:
   - `X-MacProvider-Session` takes precedence over
     `X-MacProvider-Provider`, matching SPEC-002 FR-R3.
   - Any present `X-MacProvider-Session` value is resolved as an active
     `assigned_id`. If it does not match, return the SPEC-002
     `503 session_ended` error. The coordinator MUST NOT reinterpret it as a
     sticky/conversation key.
   - Hard pins bypass sticky affinity and MUST NOT fail over or retry to a
     different provider.
4. If no hard pin exists, no `X-MacProvider-Provider` exists,
   `routing.sticky_enabled` is true, and SPEC-006 v0.8 has supplied
   `routing_internal.conversation_key`, look up sticky affinity for that
   internal key. If the sticky provider is currently routable for the resolved
   model/class and remains within the `routing.tiebreak_epsilon` cohort of the
   selected objective, promote it to position 0 as a soft preference. If not,
   continue with normal selection and log `sticky_miss`.
5. Build candidates from the pool using SPEC-002 filters:
   - FR-P5 state must be `ready`.
   - `slots_free > 0`.
   - FR-P8a admission warm-up gate must have passed.
   - FR-P11a breaker/recovery holds must exclude held providers.
   - context capacity must fit the estimated token count.
   - provisional quota and admission-tier weighting still apply.
6. Sort by the applicable objective:
   - model-class objective, if a class was requested.
   - otherwise SPEC-002 `X-MacProvider-Pref` / default sort.
7. Apply randomized epsilon tiebreak only when
   `routing.tiebreak_randomize` is true. Otherwise preserve SPEC-002's stable
   deterministic order and `connected_at` tertiary behavior.
8. Run SPEC-002 preflight in sorted order.
9. On relay failure, apply F-4 one-shot dead-WS failover as SPEC-002 defines.
   If the buyer explicitly opted in with `X-MacProvider-Retry` and
   `routing.max_retries > 0`, apply SPEC-004 retry rules after any applicable
   F-4 outcome and before returning a final pre-commit error.
10. On success, update sticky affinity for the internal conversation key to the
    final committed serving stable `provider_id`, and log the routing
    decision.

---

## 4. Functional Requirements

**FR-SR-1. Default behavior preservation.**
With `sticky_enabled: false`, no `model_classes`, `max_retries: 0`,
`tiebreak_randomize: false`, and default `tiebreak_epsilon`, the coordinator
MUST make the same provider selections and return the same buyer-visible
responses and headers as SPEC-002 v1.3.3 for the same pool snapshot, request,
and headers. SPEC-004 may add internal routing-decision logs. The
default-config regression test MUST cover equal-metric providers and prove the
existing `connected_at`-driven order remains unchanged.

**FR-SR-2. Sticky affinity keying.**
When `routing.sticky_enabled` is true, the coordinator MUST key sticky affinity
only by the gateway-derived internal field
`routing_internal.conversation_key`. This field is not a buyer header and is
not part of the SPEC-001 provider protocol. SPEC-006 v0.8 owns its derivation,
privacy disclosure, and transport from gateway to coordinator.

The value namespace MUST make it impossible to collide with a SPEC-002
`assigned_id`. SPEC-004 reserves `conv:<opaque-id>` for
`routing_internal.conversation_key`; values that do not begin with `conv:` MUST
be rejected or treated as absent for sticky purposes. The opaque suffix MUST
not expose raw buyer secrets in coordinator logs.

`X-MacProvider-Session` is hard-pin input only. Any present value triggers
SPEC-002 FR-R3 assigned-session resolution, and a non-matching value MUST
return `503` with `code: "session_ended"`. It MUST NOT be used as a sticky key,
fallback conversation key, or operator-convention soft affinity value.

The precedence is wire-decidable:

1. `X-MacProvider-Session` present -> SPEC-002 FR-R3 hard pin; no sticky
   lookup/read/write and no failover/retry to another provider.
2. else `X-MacProvider-Provider` present -> SPEC-002 FR-R3 hard pin; no sticky
   lookup/read/write and no failover/retry to another provider.
3. else `routing_internal.conversation_key` present and
   `routing.sticky_enabled: true` -> sticky soft affinity may participate.
4. else default/class routing selection.

Pillar A implementation MUST NOT begin until SPEC-006 v0.8 lands the
conversation-key mechanism, lifts SPEC-006 § 1.3 for this use, and refreshes
the plaintext-to-provider/cache disclosure. Pillars B, C, and D may proceed
independently from SPEC-004 v0.2.

**FR-SR-3. Sticky affinity is a soft preference.**
A sticky entry points to a stable `provider_id`, not an `assigned_id`. The
coordinator MAY route to the provider's current active session after reconnect,
but only if the provider passes the full SPEC-002 eligibility filter. If the
sticky provider is absent, `busy`, `degraded`, `draining`, `unavailable`,
warming, breaker-held, quota-blocked, context-too-small, or serving a model
outside the requested class, the coordinator MUST ignore the sticky entry for
that request, log `reason = "sticky_miss"` with a specific miss cause, and
fall back to normal selection. Sticky affinity MUST NOT trap a session on a
dead or ineligible provider.

Sticky affinity is subordinate to the selected preference/class objective. A
sticky hit promotes the cached provider to position 0 only if that provider is
inside the `routing.tiebreak_epsilon` cohort for the objective after normal
sorting. If the cached provider is eligible but outside that cohort, the
objective sort wins, the request proceeds without promotion, and the log MUST
record a sticky miss or bypass reason such as `outside_epsilon_cohort`.

**FR-SR-4. Hard pin precedence.**
Explicit SPEC-002 hard pins have absolute precedence:

1. `X-MacProvider-Session` hard pin to an active `assigned_id`.
2. `X-MacProvider-Provider` hard pin to a stable `provider_id`.
3. Sticky soft affinity.
4. Default/class routing selection.

Hard pins retain SPEC-002 behavior: if unavailable, wrong-model, quota-blocked,
or ineligible, the coordinator returns the existing hard-pin error and MUST NOT
fall back, retry to a different provider, or rewrite the pin into sticky
affinity.

**FR-SR-5. Sticky entry lifecycle.**
Sticky entries are in-memory coordinator state. Loss on coordinator restart is
acceptable. Each entry MUST store at least `conversation_key`, `provider_id`,
`model_scope` or class scope, `created_at`, and `last_used_at`. Entries expire
after `routing.sticky_ttl_s`. The map MUST have a bounded maximum size
(`routing.sticky_max_entries`) and evict least-recently-used expired/old entries
when the bound is reached. Eviction does not affect provider state or buyer
request correctness; it only causes future cold routing.

Sticky map reads, writes, `last_used_at` updates, TTL expiry, and LRU eviction
MUST be serialized by a mutex or equivalent synchronization. Concurrent
requests for the same conversation key MUST NOT corrupt the map or lose an LRU
update.

When `routing.model_classes` is reconfigured at runtime, sticky entries whose
`model_scope` no longer names an existing class or compatible concrete model
MUST be invalidated. The next request treats the entry as a miss and falls back
to default/class selection.

**FR-SR-6. Sticky update timing.**
The coordinator MUST update a sticky entry only after a request successfully
commits to exactly one serving provider. For non-streaming, success means an
HTTP 2xx provider response returned to the buyer. For streaming, success means
response bytes were committed to the buyer and the provider was the selected
serving provider; if the stream later fails after committed bytes, the entry
MAY remain because retrying elsewhere is forbidden after commit. Failed
preflight attempts and retryable pre-commit failures MUST NOT update sticky
affinity. When an explicitly retried request eventually commits on a later
provider, the sticky entry MUST update to the final committed provider, not any
earlier failed attempt.

**FR-SR-7. Model-class alias resolution.**
`routing.model_classes` defines operator-owned aliases. A buyer may set
`model: "<class_id>"`; the coordinator resolves the class to concrete model IDs
before candidate filtering. Exact concrete model IDs MUST continue to work
unchanged and take precedence over class matching if an operator accidentally
defines a class alias identical to a currently advertised concrete model ID.
Operators SHOULD avoid such collisions; config validation SHOULD reject them
when the concrete model is known at startup or first observed.

**FR-SR-7a. Dispatch-time model field rewrite.** When a model-class alias
resolves to a chosen provider (FR-SR-7 + FR-SR-8 selection), the coordinator
MUST rewrite the `model` field of the request body forwarded to the provider
from the buyer-supplied alias to the chosen provider's actual
`pool.Provider.ModelID`. The provider never sees the alias — only concrete
model IDs it has loaded. This MUST apply to every dispatch path (WS-tunneled
streaming, WS-tunneled non-streaming, HTTP-forwarded streaming,
HTTP-forwarded non-streaming). Exact concrete model ID requests are
identity-rewritten (no-op when `req.Model == provider.ModelID`). The rewrite
MUST preserve all other body fields verbatim (messages, max_tokens,
temperature, stream, tools, anything else). It MUST happen AFTER selection
(so failover/retry attempts to a different provider get the new chosen
provider's concrete ID), NOT once at request entry.

Test discipline: any test verifying class-alias routing MUST assert on the
exact `model` field in the body delivered to the provider — not just the
chosen provider identity. Inline mock relays that ignore the body field MUST
NOT be the sole coverage. (See 2026-05-30 audit-gap notes.)

Duplicate or non-canonical case variants of the top-level `model` member
MUST be rejected before routing with `400 invalid_request`; for example,
requests containing both `model` and `Model` are invalid. This prevents the
coordinator from selecting on one parsed model while a provider or proxy with
different JSON member handling observes another.

**FR-SR-8. Model-class objectives.**
Each class MUST define:

- `models`: one or more concrete model IDs, compared with SPEC-002's
  case-insensitive model equality.
- `objective`: one of `fast`, `accurate`, or `balanced`.

Objective semantics:

- `fast`: choose the highest effective throughput
  (`throughput_tps_estimate * tier_weight`), then fewer `slots_free`, then
  SPEC-002 deterministic or SPEC-004 randomized tiebreak.
- `accurate`: choose highest `model_params_b`, then effective throughput, then
  tiebreak.
- `balanced`: choose the highest normalized score over the eligible candidate
  set:

  ```
  score(p) = 0.4 * norm(throughput_tps_estimate)
           + 0.3 * norm(model_params_b)
           + 0.2 * norm(max_context_tokens)
           + 0.1 * norm(slots_free / max(1, slots_total))
  ```

  `norm(x)` is min-max normalization across the eligible candidate set for the
  same request; if every candidate has the same value for a component, that
  component's normalized value is `1.0` for every candidate. The coordinator
  MUST log the component values and final score. The weights are normative in
  v0.2 and may be made operator-tunable only in a future minor revision.

**FR-SR-9. Model-class no-provider behavior.**
If a class exists but no eligible provider remains after SPEC-002 filters,
quota checks, context capacity, warm-up, and breaker holds, the coordinator
MUST return HTTP 503 using the same OpenAI-compatible error shape as
FR-B4/no_provider_available. The error message SHOULD name the requested class
and MAY include the count of configured concrete models. It MUST NOT expose
sensitive operator config beyond model IDs already advertised by `/v1/models`.

**FR-SR-10. /v1/models class advertisement.**
SPEC-006 SHOULD advertise model classes alongside concrete model IDs in
`GET /v1/models`, not instead of them, so existing clients and exact-ID buyers
remain compatible. Class entries SHOULD include:

- `id`: class alias, e.g. `mlx-fast`.
- `object`: `model`.
- `owned_by`: `macprovider`.
- `type`: `model_class`.
- `models`: concrete model IDs in the class that are currently known.
- `available`: true when at least one concrete model in the class has an
  eligible provider under SPEC-002 filters.
- existing aggregate fields where meaningful (`provider_count`,
  `max_context_tokens`, `total_slots`, `degraded`).

Concrete model entries remain unchanged except for any additive metadata
SPEC-006 chooses to expose.

**FR-SR-11. Coordinator-managed retry opt-in.**
Coordinator-managed retry is disabled unless both:

- `routing.max_retries > 0`; and
- the buyer sends `X-MacProvider-Retry` with an affirmative value
  (`1`, `true`, or a positive integer).

The effective retry limit is the lesser of `routing.max_retries` and any
positive integer supplied in `X-MacProvider-Retry`. `routing.max_retries: 0`
MUST preserve current SPEC-002 behavior. Retries MUST choose a different
eligible provider/session from every prior attempt for the same buyer request.

**FR-SR-12. Retryable failures.**
The coordinator MAY retry only before response bytes are committed to the buyer
and only for transient provider-side failures:

- provider disconnected before commit (`provider_disconnected`, including
  dead-WS-mid-inference);
- provider HTTP 502 before commit;
- provider HTTP 504 or relay timeout before commit;
- provider becomes breaker-degraded or unavailable during an attempt before
  commit;
- preflight timeout/rejection on the selected provider, by advancing to the
  next candidate as SPEC-002 already does.

Every retry attempt is a fresh relay and is attributed to the provider that
served that attempt for FR-P11a breaker accounting, except that FR-P11a C2
buyer/gateway cancellation attribution applies during retry attempts exactly
as it applies to the first attempt. If a buyer or gateway cancellation arrives
during retry attempt `n`, that cancellation is excluded from breaker
accounting; only provider-attributable relay faults count.

**FR-SR-13. Non-retryable failures.**
The coordinator MUST NOT retry:

- explicit hard-pinned requests;
- buyer cancellation or client hangup;
- any 4xx buyer/request validation error;
- a provider response after any HTTP or SSE bytes have been committed to the
  buyer;
- a successful provider response with application-level content the buyer may
  dislike;
- failures after the remaining coordinator/gateway timeout budget is
  insufficient for another bounded attempt;
- requests where retry would violate the no-double-emit or no-double-charge
  guarantees.

The F-4 streaming pre/post-first-byte rule is normative here: after commit,
terminate the stream with the existing error event; never replay elsewhere.

**FR-SR-14. Retry idempotency and accounting.**
Coordinator-managed retry MUST produce at most one buyer-visible terminal
response and MUST NOT double-emit. Billing/rewards are SPEC-005, but SPEC-004
must preserve the accounting invariant: only the final successful provider
attempt can be treated as the served request for buyer-visible success; failed
attempts are logged as attempts/faults and attributed to their provider for
breaker health, not as duplicate buyer completions. The reserved
`request_log.retried` column MUST be populated with the number of additional
provider attempts beyond the first caused by explicit SPEC-004
`X-MacProvider-Retry` opt-in (`0` for no explicit retry, `1` for one explicit
retry, etc.). SPEC-002 F-4 one-shot failover has its own SPEC-002 logging and
MUST NOT increment this column.

A single buyer request MUST NOT push more than
`min(routing.max_providers_faulted_per_request, routing.max_retries)` distinct
providers across the FR-P11a breaker threshold. Once that per-request cap is
reached, the coordinator MUST abort further retries and return the current
buyer-visible error.

**FR-SR-15. Retry timeout budget.**
Retries MUST respect `routing.request_timeout_s` and the SPEC-002 FR-P11a C2
timer relation with the gateway. Before starting retry `n`, the coordinator
MUST compute:

```
remaining = routing.request_timeout_s - elapsed_since_request_start
```

using wall-clock elapsed time from the coordinator's receipt of the buyer
request. If `remaining < routing.retry_per_attempt_timeout_s`, the coordinator
MUST skip that retry and return the current pre-commit provider failure without
starting an orphan attempt that cannot complete inside the coordinator budget.

`routing.retry_per_attempt_timeout_s` defaults to `60` seconds. It is the
maximum wall-clock time the coordinator will allow a single SPEC-004 retry
attempt to run, and it MUST be less than or equal to
`routing.request_timeout_s`. The total request wall-clock budget MUST still be
bounded by `routing.request_timeout_s`, which operators SHOULD keep strictly
below the gateway's `coordinator_request_seconds` per SPEC-002 FR-P11a C2 so
provider faults are observed before gateway cancellation.

**FR-SR-16. Randomized epsilon tiebreak.**
When `routing.tiebreak_randomize` is false, SPEC-002 deterministic ordering is
unchanged. When true, after sorting candidates by the selected primary metric,
the coordinator MUST identify the top epsilon cohort and choose randomly among
that cohort instead of falling through to `connected_at`.

The epsilon cohort is defined per objective:

- default utilization mode: candidates with `slots_free` equal to the best
  candidate and effective throughput within `routing.tiebreak_epsilon` of the
  best effective throughput;
- `fast`: candidates whose effective throughput is within epsilon of the best;
- `accurate`: candidates whose `model_params_b` is within epsilon of the best;
- `balanced`: candidates whose balanced score is within epsilon of the best.

The implementation MUST document whether epsilon is absolute or relative for
each metric. v0.2 config defines a single relative fraction; see § 5.

**FR-SR-17. Randomized tiebreak reproducibility.**
Randomization MUST remain audit-explainable. For every randomized decision, the
routing log MUST include:

- request id and external `X-Request-ID`, when present;
- mode/objective;
- epsilon value and whether it was relative or absolute;
- full epsilon candidate set with provider IDs, assigned IDs, metric values,
  state, slots, effective throughput, model params, `connected_at`, and tier;
- selected provider;
- RNG seed or recorded random draw value sufficient to explain the choice.

The coordinator MAY use cryptographic randomness or a per-process PRNG, but the
chosen provider MUST be explainable from the recorded candidate set and recorded
draw/seed. Randomization MUST NOT be enabled by default.

**FR-SR-18. Composition with FR-P5, FR-P8a, and FR-P11a.**
No SPEC-004 feature may route to a provider that SPEC-002 considers
ineligible. Sticky affinity, class expansion, retry, and randomized tiebreak
operate only after FR-P5 state eligibility, FR-P8a warm-up admission, capacity,
quota, context, and FR-P11a breaker/recovery-hold checks.

**FR-SR-19. Composition with F-4.**
F-4 remains the base dead-WS failover rule. SPEC-004 retry is opt-in and
bounded; it MUST NOT weaken F-4's hard-pin no-failover rule, streaming
post-commit rule, or coherent-response guarantee. If both F-4 failover and
SPEC-004 retry could apply before commit, the implementation MUST treat every
provider relay as one attempt in a single excluded-provider set so the same
dead provider is not selected again.

**FR-SR-20. Clean-room boundary.**
SPEC-004 design and implementation MUST be based only on this repo's specs and
code plus public documentation as needed. Agents MUST NOT inspect d-inference
(layr-labs) source because its license is NOASSERTION.

---

## 5. Config

The following keys extend SPEC-002's `routing:` schema by reference. Defaults
preserve SPEC-002 v1.3.3 behavior.

```yaml
routing:
  # Existing SPEC-002 keys remain unchanged:
  preflight_threshold_tokens: 4096
  preflight_timeout_s: 5
  request_timeout_s: 300
  failover_enabled: true
  failover_timeout_s: 5

  # SPEC-004 keys:
  sticky_enabled: false        # default false: no sticky behavior
  sticky_ttl_s: 1800           # 30 minutes; used only when sticky_enabled=true
  sticky_max_entries: 10000    # bounded in-memory map

  model_classes: {}            # default empty: exact model IDs only
  # Example:
  # model_classes:
  #   mlx-fast:
  #     models:
  #       - mlx-community/Llama-3.2-3B-Instruct-4bit
  #       - mlx-community/Qwen2.5-7B-Instruct-4bit
  #     objective: fast
  #   mlx-balanced:
  #     models:
  #       - mlx-community/Llama-3.2-3B-Instruct-4bit
  #       - mlx-community/Qwen2.5-7B-Instruct-4bit
  #     objective: balanced
  #   mlx-accurate:
  #     models:
  #       - mlx-community/Qwen2.5-7B-Instruct-4bit
  #       - mlx-community/Qwen2.5-14B-Instruct-4bit
  #     objective: accurate

  max_retries: 0               # default 0: no coordinator-managed retry
  retry_per_attempt_timeout_s: 60
                                # max wall-clock budget for one retry attempt
  max_providers_faulted_per_request: 2
                                # effective cap is min(this, max_retries)
  tiebreak_randomize: false    # default false: SPEC-002 connected_at behavior
  tiebreak_epsilon: 0.0        # relative fraction; 0.05 means within 5%
```

Config validation requirements:

- `sticky_ttl_s` MUST be positive when sticky is enabled.
- `sticky_max_entries` MUST be positive when sticky is enabled.
- `model_classes` aliases MUST be non-empty strings and SHOULD be limited to
  the same safe ID character class as provider IDs plus `/` only if needed.
- each class MUST contain at least one concrete model ID and a valid objective.
- `max_retries` MUST be `>= 0`; implementation SHOULD cap it to a small
  operator-safe maximum such as 3.
- `retry_per_attempt_timeout_s` MUST be positive and MUST be `<=
  routing.request_timeout_s`.
- `max_providers_faulted_per_request` MUST be positive when
  `max_retries > 0`. The configured default is `2`; the effective per-request
  cap MUST be `min(max_providers_faulted_per_request, max_retries)`.
- `tiebreak_epsilon` MUST be `>= 0`; if `tiebreak_randomize` is true and
  epsilon is `0`, only exact metric ties enter the random cohort.

---

## 6. Interface Deltas

### Buyer request headers

- `X-MacProvider-Retry`: optional opt-in for coordinator-managed retry. Values
  `1`, `true`, or a positive integer enable retry up to
  `routing.max_retries`. Missing or false-like values preserve SPEC-002
  behavior. This is a public buyer opt-in header in v0.2. SPEC-005 may later
  refine retry-cost policy; until then retry attempts settle under existing
  FR-P11a attribution and SPEC-005 accounting rules.
- `X-MacProvider-Provider`: unchanged hard pin. Takes precedence over sticky
  affinity when `X-MacProvider-Session` is absent.
- `X-MacProvider-Session`: unchanged hard-pin surface for active assigned
  sessions under SPEC-002. SPEC-004 MUST NOT reuse this value as a sticky key.
  Any present value triggers FR-R3 hard-pin semantics: match `assigned_id` or
  return `503 session_ended`; no sticky lookup/read/write, no failover, and no
  retry to a different provider.

### Gateway-derived internal fields

- `routing_internal.conversation_key`: internal gateway-to-coordinator sticky
  affinity key in the reserved `conv:<opaque-id>` namespace. This is not a raw
  buyer header and MUST NOT be accepted from direct buyer traffic. SPEC-006
  v0.8 owns derivation, transport, and disclosure for this field.

### Request body

- `model` MAY be a configured class alias. Exact concrete model IDs remain
  valid and backward compatible.

### `/v1/models`

Model classes SHOULD appear alongside concrete model IDs, marked with additive
metadata such as `type: "model_class"`. Existing concrete entries and fields
remain valid.

### Request log

- `retried`: number of additional provider attempts beyond the first. `0` means
  no coordinator-managed retry occurred. This column counts only explicit
  SPEC-004 `X-MacProvider-Retry`-driven attempts. F-4 one-shot failover remains
  invisible to this column even if the implementation shares attempt plumbing.

### Provider protocol

No SPEC-001 provider protocol field, message, or behavior changes. All
behavior is coordinator-internal or buyer-facing.

---

## 7. Observability

Every routed request SHOULD produce a structured routing-decision log. When a
request is rejected before provider selection, the log SHOULD include the
rejection reason and enough candidate counts to diagnose the filter.

Required fields where applicable:

- `event = "routing_decision"`
- `request_id`, external `x_request_id`
- `requested_model`
- `resolved_model_type`: `exact` or `class`
- `resolved_class`, when class-routed
- `class_models`, when class-routed
- `objective`: `default`, `fast`, `accurate`, `balanced`
- `hard_pin_type`: `none`, `provider`, `session`
- `sticky_result`: `disabled`, `no_key`, `hit`, `miss`, `updated`, `evicted`
- `sticky_miss_reason`
- `candidate_count_before_filters`
- `candidate_count_after_filters`
- `filtered_counts` by reason (`model_mismatch`, `not_ready`, `warming`,
  `breaker_held`, `busy`, `context_too_small`, `quota_blocked`, `excluded_retry`)
- `candidate_set` for randomized decisions and SHOULD for class decisions
- `tiebreak_mode`: `deterministic` or `random_epsilon`
- `tiebreak_epsilon`
- `random_seed` or `random_draw`, when randomized
- `chosen_provider_id`
- `chosen_assigned_id`
- `attempt_index`
- `retry_count`
- `retry_reason`
- `retried`
- `preflight_result`

State changes caused by SPEC-004 MUST use SPEC-002's `state_update.reason`
style where relevant:

- `sticky_miss` is a routing-decision reason, not a provider state change.
- retryable provider failures still use FR-P11/FR-P11a reasons such as
  `breaker_tripped`, `provider_failure`, or `http_530_observed`.
- a provider excluded from routing because of a breaker/recovery hold SHOULD be
  visible as `filtered_counts.breaker_held`.

Pillar D's reproducibility requirement is satisfied only if the randomized
candidate set, metrics, epsilon, and selected provider are present in logs for
every randomized selection.

---

## 8. Acceptance Criteria

Each acceptance test that uses timeouts, retry windows, heartbeat gaps, or
streaming completion margins MUST name the slowest-realistic-provider margin
per SPEC-002 audit category J.1. Tests MUST avoid thresholds that only pass for
fast mock providers.

**AC-SR-1. Default config preserves SPEC-002 routing.**
Given two same-model providers with identical metrics and different
`connected_at`, with all SPEC-004 keys at defaults, the coordinator selects the
earlier-connected provider exactly as SPEC-002 v1.3.3 does. The regression
asserts identical provider selection and identical buyer-visible
response/headers for default, `fast`, and `accurate` preference modes, allowing
only additive internal routing-decision logs.

The same default-config regression MUST cover the FR-R3 pin path:
`X-MacProvider-Session` and `X-MacProvider-Provider` behave exactly as
SPEC-002 v1.3.3, including the `503 session_ended` case for a non-matching
`X-MacProvider-Session`. With `sticky_enabled: false`, sticky lookup Step 4 is
a verified no-op: no sticky map read, no sticky map write, and no change to
log order before provider selection.

**AC-SR-2. Sticky hit routes to prior provider.**
With sticky enabled and SPEC-006 v0.8 supplying
`routing_internal.conversation_key: conv:S`, a first successful request routes
normally and records provider `A`. A follow-up request with the same internal
key, same concrete model or compatible class, routes to `A` while `A` remains
ready, not breaker-held, not warming, has free slots, and is inside the
objective's epsilon cohort. Logs include `sticky_hit`.

**AC-SR-3. Sticky miss falls back gracefully.**
After `conv:S` sticks to provider `A`, mark `A` `degraded`, breaker-held,
warming, unavailable, full, context-too-small, outside the requested class, or
outside the objective's epsilon cohort. The next request for `conv:S` does not
fail solely because of affinity; it selects eligible provider `B` or returns
the normal no-provider error if no provider exists. Logs include `sticky_miss`
and the specific miss reason.

**AC-SR-4. Hard pins still do not fail over.**
With `X-MacProvider-Provider: A` or hard `X-MacProvider-Session: assigned-A`,
if `A` is unavailable or fails pre-commit, the coordinator returns the existing
SPEC-002 hard-pin error/failure and does not sticky-fallback, F-4 fail over, or
SPEC-004 retry to `B`.

**AC-SR-5. Class routes to right provider.**
Configure `mlx-fast` across two concrete models where provider `A` has higher
effective throughput and provider `B` has higher parameter count. A request for
`model: "mlx-fast"` selects `A`; a request for `model: "mlx-accurate"` selects
`B`; a request for the exact concrete model still uses SPEC-002 exact-ID
routing and ignores class aliases.

Class-alias routing tests MUST also assert that the body delivered to the
provider contains the chosen provider's concrete model ID, not the alias.

Configure `mlx-balanced` over a candidate set with known throughput, parameter
count, context, and slot ratios. The test MUST compute the v0.2 normalized
balanced formula and assert the selected provider and logged component scores.

**AC-SR-6. Empty class returns clean 503.**
Configure a class whose concrete providers are all absent, warming, degraded,
breaker-held, busy, or context-too-small. A class request returns HTTP 503 with
OpenAI-compatible `no_provider_available` shape and logs the class resolution
plus filter counts.

**AC-SR-7. /v1/models advertises classes additively.**
`GET /v1/models` returns concrete model entries unchanged and includes class
entries marked as model classes. OpenAI-compatible clients that ignore
non-standard fields can still parse the response.

**AC-SR-8. Retry succeeds on retryable pre-commit failure.**
With `routing.max_retries: 1` and `X-MacProvider-Retry: 1`, provider `A`
disconnects or returns 502/504 before response bytes are committed. The
coordinator retries provider `B`, returns exactly one successful buyer response,
sets `retried = 1`, and logs both attempts with correct provider attribution.

**AC-SR-9. Retry does not run after buyer cancel or committed stream.**
For buyer cancellation, no retry occurs and no breaker fault is charged for a
genuine buyer cancel. For streaming where provider `A` emits the first SSE
bytes and then disconnects, the coordinator emits the existing
`provider_disconnected` SSE error/[DONE] and never attempts provider `B`.

**AC-SR-10. Retry does not double-emit or double-count success.**
A retry storm with one pre-commit failure followed by success produces one
buyer-visible terminal response, one final successful serving provider, failed
attempt logs for prior providers, and no duplicate success accounting.

**AC-SR-11. Retry respects timeout budget.**
With remaining coordinator request budget below the configured per-attempt
bound, the coordinator skips an otherwise allowed retry and returns the
pre-commit provider failure promptly. The test states the gateway/coordinator
timer ordering and slowest-provider margin.

The test MUST use the v0.2 formula
`remaining = routing.request_timeout_s - elapsed_since_request_start` and
assert no retry attempt starts when
`remaining < routing.retry_per_attempt_timeout_s`.

**AC-SR-12. Randomized tiebreak distributes load.**
With `tiebreak_randomize: true`, nonzero epsilon, and two equivalent eligible
providers inside the epsilon cohort, a sufficiently large mock run distributes
selections across both providers. The acceptance threshold must allow
statistical variance but fail the SPEC-002 always-first-connected behavior.

**AC-SR-13. Randomized tiebreak logs explainable decision.**
For every randomized selection, logs contain the full epsilon candidate set,
metric values, epsilon, random seed/draw, and chosen provider. A test can replay
or explain the selected provider from the log record without hidden state.

**AC-SR-14. Composition gates hold.**
For sticky, class, retry, and randomization paths, providers in `degraded`,
`draining`, `unavailable`, warming, breaker-held, full, quota-blocked, or
context-too-small states are never selected. Tests include at least one
FR-P8a warming exclusion and one FR-P11a breaker-held exclusion.

**AC-SR-15. Session hard-pin is never sticky.**
With sticky enabled and no `routing_internal.conversation_key`, send
`X-MacProvider-Session: not-an-active-assigned-id`. The coordinator MUST return
the unchanged SPEC-002 FR-R3 `503` with `code: "session_ended"` and MUST NOT
perform a sticky lookup, sticky write, class fallback, F-4 failover, or
SPEC-004 retry.

**AC-SR-16. Retry budget and cancel attribution.**
With `routing.max_retries > 0`, `X-MacProvider-Retry: 1`, and remaining budget
below `routing.retry_per_attempt_timeout_s`, the coordinator skips the retry
and no orphan provider attempt is observed after timeout. In a separate retry
attempt `N`, inject a buyer/gateway cancellation before provider-attributable
timeout; the request stops without charging an FR-P11a breaker fault to the
attempted provider.

---

## 9. Composition Guarantees

- **F-4 is not weakened.** Hard-pinned requests still do not fail over.
  Streaming requests still cannot fail over or retry after bytes are
  committed. Buyers still receive one coherent response or one clean error.
- **FR-P5 is not weakened.** Only `ready` providers with free slots are
  routable. Sticky and class aliases never override state eligibility.
- **FR-P8a is not weakened.** Warming providers are not buyer-routable for
  sticky hits, class requests, retry attempts, or randomized cohorts until the
  token-producing warm-up gate passes.
- **FR-P11a is not weakened.** Breaker-held and recovery-held providers remain
  non-routable, provider-originated state updates cannot clear coordinator
  holds, and retries charge faults to the provider whose relay produced them.
- **Audit reproducibility is not weakened.** Default routing remains
  deterministic. When randomization is explicitly enabled, the candidate set,
  metric values, epsilon, and selected provider are logged so the decision is
  explainable after the fact.
- **SPEC-001 is not changed.** Providers do not learn about sticky affinity,
  model classes, randomized tiebreaks, or coordinator-managed retry through new
  wire fields.

---

## 10. Decisions From v0.1 Open Questions

**OQ-SR-1 decided: distinct internal sticky key.**
`X-MacProvider-Session` remains SPEC-002 hard-pin-only. Sticky affinity uses
`routing_internal.conversation_key` in the `conv:<opaque-id>` namespace, owned
by SPEC-006 v0.8.

**OQ-SR-2 decided: sticky default remains off.**
`routing.sticky_enabled` defaults to `false`. Production enablement remains
operator opt-in until SPEC-006 v0.8 lands the conversation-key privacy
disclosure and caching guard update.

**OQ-SR-3 decided: balanced formula is normative.**
`balanced` uses the v0.2 normalized score formula in FR-SR-8. Operators may not
choose a different formula for v0.2 behavior; tunable weights require a future
minor revision.

**OQ-SR-4 decided: retry header is public opt-in.**
`X-MacProvider-Retry` is a public buyer opt-in header. `routing.max_retries: 0`
keeps current one-shot-only behavior unchanged. SPEC-005 may later refine
retry-cost policy.

**OQ-SR-5 decided: `retried` counts explicit SPEC-004 retries only.**
`request_log.retried` counts only additional attempts caused by
`X-MacProvider-Retry`. SPEC-002 F-4 one-shot failover remains invisible to this
column.

---

## 11. Implementation Hand-off

Primary files:

- `phase4-coordinator/internal/buyer/server.go`
  - Extend `selectProvider` / `selectProviderExcluding` into a route plan that
    can resolve model classes, apply sticky preference, expose candidate sets,
    and share excluded-provider state across F-4 and SPEC-004 retry attempts.
  - Preserve `hasPinnedRoute` semantics for hard-pin no-failover/no-retry.
  - Populate `request_log.retried` and routing-decision logs.
  - Do not implement Pillar A sticky affinity until SPEC-006 v0.8 supplies
    `routing_internal.conversation_key` and lifts the § 1.3 sticky-caching
    prohibition for this use. Pillars B, C, and D do not depend on that gate.
- `phase4-coordinator/internal/pool/provider.go`
  - Continue using `Provider.RoutingEligible()` as the final state/capacity
    eligibility gate. Do not duplicate state logic in the smart router.
  - Add helper APIs only if needed for stable provider/session lookup and
    breaker-held visibility in filter-reason logs.
- `phase4-coordinator/internal/config/config.go`
  - Add `RoutingConfig` fields for sticky, model classes, retries,
    `retry_per_attempt_timeout_s`, `max_providers_faulted_per_request`, and
    tiebreak config with default-preserving values.
  - Add validation for class aliases/objectives and safe retry/epsilon bounds.
- `phase4-coordinator/internal/testfaults` (or existing equivalent harness)
  - Add deterministic provider-disconnect, 502, 504, pre-commit stream failure,
    post-commit stream failure, buyer cancel, warm-up-held, and breaker-held
    scenarios.
- `phase4-coordinator/tools/mockprovider/`
  - Reuse mock providers for multi-provider routing, class, retry, and
    randomized-distribution acceptance tests.

Implementation gate:

1. Pillar A sticky affinity MUST NOT be implemented until SPEC-006 v0.8 lands
   the gateway-derived conversation-key mechanism, lifts SPEC-006 § 1.3 for
   coordinator-internal sticky affinity, and refreshes the Tier 1
   plaintext-to-provider/cache disclosure.
2. Pillars B (model classes), C (retry), and D (epsilon tiebreak) are
   implementable from SPEC-004 v0.2 with no further spec movement.

Test plan:

1. Default-config regression: identical pool snapshots produce the same
   provider choices as current SPEC-002 for default, `fast`, and `accurate`.
2. Sticky unit tests after SPEC-006 v0.8: hit, miss by every ineligible state,
   epsilon-cohort bypass, TTL expiry, LRU eviction, serialized map access,
   class-reload invalidation, update only after final committed success, and
   hard-pin precedence.
3. Model-class unit/integration tests: exact-ID compatibility, fast/accurate
   objective selection, balanced score logging, empty-class 503, `/v1/models`
   additive class entries.
4. Retry fault tests: retryable 502/504/disconnect before commit, no retry on
   cancel/4xx/post-commit stream, excluded-provider set, timeout budget,
   C2 cancel-during-retry no-charge, per-request breaker-degradation cap, no
   double-emit, `retried` value.
5. Randomized tiebreak tests: default deterministic behavior unchanged;
   randomization distributes over an epsilon cohort; every randomized decision
   log is replay/explanation-ready.
6. Composition tests: each smart feature excludes FR-P5-ineligible,
   FR-P8a-warming, and FR-P11a-held providers.
7. Slowest-realistic-provider audit: each timeout/window acceptance test names
   the slowest-realistic-provider margin required by SPEC-002 audit category
   J.1.

Implementation MUST wait until this spec has an independent audit pass. Do not
write coordinator code from v0.1; v0.2 resolves the audit findings and
operator-facing decisions that affect public behavior.
