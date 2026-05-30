# Build prompt — SPEC-004 (Smart Router)

Operator-paste prompt to write **SPEC-004 — Smart Router**, the routing-
intelligence layer that sits on top of the SPEC-002 coordinator's basic
eligibility+preference routing. SPEC-004 is purely a coordinator concern; it
is invisible to providers (no SPEC-001 wire change) and additive to the buyer
API (no breaking SPEC-006 change).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===` into a
fresh session rooted at `/Users/augstar/macprovider-poc`. Run the spec-writing
pass first; implement only after the spec is audited.

---

```
=== BEGIN PROMPT ===

You are writing SPEC-004 (Smart Router) for the Mac Provider coordinator.
SPEC-004 collects the four routing concerns SPEC-002 explicitly deferred to it.
It EXTENDS SPEC-002 §5 (routing algorithm); it does NOT replace it. Every
SPEC-004 behavior must be additive and default to preserving current v1
routing so the live money path cannot regress.

## Locked corpus (do NOT modify spec text in this phase)
  SPEC-001 v1.2.4  — phase3-binary provider WS protocol (LOCKED; no wire change)
  SPEC-002 v1.3.3  — coordinator request router (you EXTEND its §5 routing)
  SPEC-003 v0.7    — open onboarding / distribution
  SPEC-006 v0.7    — buyer API gateway

## Required reading (read fully before writing)
1. `specs/SPEC-002-coordinator.md`:
   - §5 routing algorithm (the basis you extend)
   - the exact deferred-to-SPEC-004 passages: line ~1080 (visible retry /
     `X-MacProvider-Retry`), ~1113 (`retried` column reserved), ~1467 +
     ~2650 (randomized ε-tiebreak, and WHY v1 deliberately does not randomize
     — audit-log reproducibility), ~2619 (model-class abstraction / `mlx-fast`
     `mlx-balanced` `mlx-accurate`, the broader D4 cross-family tradeoff),
     line 161 (sticky single-tenant caching)
   - FR-P5 (routing eligibility / state machine), F-4 (dead-WS failover),
     FR-P8a (warm-up gate), FR-P11a (circuit-breaker) — SPEC-004 must compose
     correctly with ALL of these
   - existing pin headers `X-MacProvider-Provider` / `X-MacProvider-Session`
     (sticky affinity should build on the session-pin mechanism, not reinvent it)
2. Coordinator code SPEC-004 will touch:
   - `phase4-coordinator/internal/buyer/server.go` — `selectProvider` /
     `selectProviderExcluding` (the candidate filter + preference sort + the
     `connected_at` tertiary tiebreak), `hasPinnedRoute`, the failover loop
   - `phase4-coordinator/internal/pool/provider.go` — registry, `RoutingEligible`
   - `phase4-coordinator/internal/config/config.go` — `RoutingConfig`
3. `beta/DECISION_CRITERIA.md` — Phase 2 D4 (model-family tradeoff) and the
   routing-reproducibility decisions.

## Mission (1 paragraph)
Make the coordinator route *smartly*: reuse warm provider caches across a
buyer's turns, expose latency/quality-tiered model classes, spread load
evenly across equivalent providers, and recover transient failures more
aggressively than the existing one-shot failover — without breaking
reproducible audit logs, the locked SPEC-001 protocol, or the current money
path.

## Scope — the four pillars (each a numbered FR block, testable)

### Pillar A — Sticky session affinity (cache reuse)
- A buyer's follow-up requests SHOULD route to the SAME provider that served
  the prior turn, so the provider's KV/prompt cache stays warm. Keyed by the
  buyer-supplied `X-MacProvider-Session` (reuse the existing pin header; do
  NOT invent a new one) or a derived session id where SPEC-006 supplies one.
- Affinity is a PREFERENCE, not a hard pin: if the sticky provider is
  `degraded`/`unavailable`/full (FR-P5), or breaker-held (FR-P11a), or warming
  (FR-P8a), the request MUST fall back to normal selection and log a
  `sticky_miss` reason — it MUST NOT fail or trap the session on a dead box.
- Affinity entries expire (`routing.sticky_ttl_s`); define eviction + max-map
  size. State is in-memory (lost on coordinator restart — acceptable; sessions
  re-warm).
- Distinguish from the existing HARD pins (`X-MacProvider-Provider`/`-Session`
  per F-4): hard pins MUST NOT fail over; sticky affinity is soft and DOES
  fall back. Specify the precedence (explicit hard pin > sticky affinity >
  default selection).

### Pillar B — Model-class aliases (cross-family routing)
- Operator-defined classes (e.g. `mlx-fast`, `mlx-balanced`, `mlx-accurate`)
  map to a set of real model ids + a selection objective (fast = max
  throughput_tps; accurate = max model_params_b; balanced = a documented
  blend). Config-driven (`routing.model_classes`).
- A buyer requesting `model: "mlx-fast"` routes to the best eligible provider
  in that class. Exact model ids MUST still work unchanged (backward compat).
- `/v1/models` (SPEC-006) SHOULD advertise available classes; specify whether
  classes appear alongside or instead of concrete ids.
- Specify behavior when a class has no eligible provider (clean 503, same shape
  as FR-B4/no_provider_available).

### Pillar C — Coordinator-managed retry
- Beyond F-4's one-shot dead-WS failover: an opt-in, bounded retry across
  DIFFERENT eligible providers on transient failure (`X-MacProvider-Retry`
  header, max from `routing.max_retries`). Populate the reserved `retried`
  column (SPEC-002 ~line 1113).
- MUST be idempotency-safe: define exactly which failures are retryable
  (provider_disconnected / 502 / 504 / breaker-degrade mid-attempt) vs NOT
  (buyer cancel, 4xx, a request that already emitted committed stream bytes —
  reuse the F-4 streaming pre/post-first-byte rule). MUST NOT double-charge or
  double-emit. Each retry attempt is a fresh relay charged per FR-P11a
  attribution.
- Bound total wall time so retries cannot exceed the gateway/coordinator
  request timeout (respect the FR-P11a C2 timer relation).

### Pillar D — Randomized ε-tolerance tiebreak (load distribution)
- Among candidates within tolerance ε on the primary sort metric, pick
  randomly instead of the deterministic `connected_at` tiebreak (which
  hot-spots the first-connected provider — SPEC-002 ~line 2650). Config:
  `routing.tiebreak_randomize` (default the SPEC-002 deterministic behavior),
  `routing.tiebreak_epsilon`.
- CRITICAL — preserve audit reproducibility (the explicit v1 reason for NOT
  randomizing): when randomized, the routing log MUST record the full
  candidate set, the metric values, ε, and the chosen provider, so a decision
  is explainable after the fact (a seeded/recorded choice, not an opaque one).
  State this as a normative requirement.

## What SPEC-004 must contain (sections, in order)
0. Operator-paste invocation block (verbatim, at top — mirror SPEC-002 §0).
1. Mission (1 para).
2. Scope (in/out). Out: anything requiring a SPEC-001 wire change; rewards/
   billing (SPEC-005); AntFeed seller integration (SPEC-007); Tier-2 attestation.
3. Architecture: how SPEC-004 layers onto SPEC-002 §5 (a routing pipeline:
   resolve model-class → apply hard pin OR sticky affinity → filter eligible
   (FR-P5/P8a/P11a) → preference sort → ε-tiebreak → preflight → on failure,
   coordinator retry). One diagram/ordered list.
4. Functional requirements (FR-SR-1 … numbered, testable) covering pillars A–D
   + their compositions with FR-P5, F-4, FR-P8a, FR-P11a.
5. Config (new `routing.*` keys, with defaults that preserve current behavior):
   `sticky_enabled` (default ?), `sticky_ttl_s`, `model_classes`,
   `max_retries` (default 0 = current one-shot only), `tiebreak_randomize`
   (default false), `tiebreak_epsilon`. Add to the SPEC-002 config schema by
   reference; do not duplicate-divergently.
6. Interface deltas: buyer headers (`X-MacProvider-Retry`), `model` field
   accepting class aliases, `/v1/models` class advertisement, the `retried`
   column semantics. NO change to the SPEC-001 provider protocol.
7. Observability: routing-decision log fields (candidate set, reason:
   sticky_hit/sticky_miss/class_resolved/tiebreak_random/retry_n), and a
   `state_update.reason`-style marker where relevant. This is how Pillar D's
   reproducibility requirement is satisfied and how P2 monitoring sees it.
8. Acceptance criteria (AC-SR-1…): sticky hit + graceful fallback when sticky
   box is degraded/breaker-held; class routes to the right provider + exact-id
   still works + empty-class 503; retry succeeds on a retryable failure, does
   NOT retry on buyer-cancel/committed-stream, never double-emits; randomized
   tiebreak distributes load AND logs an explainable decision. Each AC names
   the slowest-realistic-provider margin per SPEC-002 audit category J.1.
9. Composition guarantees (dedicated): SPEC-004 must NOT weaken F-4 (hard pins
   still don't fail over), FR-P8a (warming providers not routed), FR-P11a
   (breaker-held providers not routed; retries respect the breaker), or the
   reproducibility guarantee. State each as a MUST.
10. Open questions for operator.
11. Implementation hand-off (files, test plan against mock providers +
    `internal/testfaults`).

## Hard rules
- Additive only. With ALL new keys at default, routing behavior MUST be
  byte-identical to SPEC-002 v1.3.3 (prove it: a default-config routing test
  matches current decisions). Smart features are opt-in.
- No SPEC-001 / phase3-binary / wire change. Sticky affinity, classes, retry,
  and tiebreak are all coordinator-internal + existing buyer headers.
- Preserve audit reproducibility: every routing decision, including randomized
  ones, MUST be explainable from logs (Pillar D normative requirement).
- Compose correctly with FR-P5, F-4, FR-P8a, FR-P11a — never route to an
  ineligible/held/warming provider; never trap a session on a dead box.
- Clean-room: do NOT inspect d-inference (layr-labs) source — NOASSERTION
  license; design from public specs + this repo only.
- No double-charge / double-emit on retry (idempotency rules explicit).

## Anti-rules
- Do not implement rewards/billing (SPEC-005), AntFeed integration (SPEC-007),
  Tier-2 attestation, or any provider-protocol change.
- Do not make randomization the default (breaks current reproducible logs).
- Do not turn sticky affinity into a hard pin (that's F-4's job and would
  trap sessions on failed providers).

## Output files
- `specs/SPEC-004-smart-router.md` (the normative spec; version 0.1).
- A short note in `specs/SPEC-002-coordinator.md` is NOT in scope here (locked);
  reference SPEC-004 from SPEC-002 only when SPEC-002 is next opened.

## When you finish (spec pass)
Produce `specs/SPEC-004-smart-router.md` + a 1-paragraph summary of the open
questions for the operator. Do NOT write code in the spec pass. Then hand off
to an audit (AUDIT_SPEC_004_PROMPT-style) before implementation.

=== END PROMPT ===
```

## How to use
1. Paste the BEGIN/END block into a fresh Claude/Codex session at the repo root.
2. Spec-writing pass first → `specs/SPEC-004-smart-router.md` (v0.1).
3. Independent audit pass (mirror `AUDIT_SPEC_002_PROMPT.md`).
4. Only then implement, with a code-review pass and verification against mock
   providers + `internal/testfaults`, never against the operator's own Mac.

## Priority note (for the operator)
SPEC-004 is routing *optimization* — highest value at scale (many providers,
demanding paying buyers). At the current Tier-1 cooperative scale it is lower
leverage than the economic layer (SPEC-007 AntFeed integration → SPEC-005
rewards) or front-door/onboarding polish. Sequence accordingly.
