# Build prompt — SPEC-004 v0.3.1 Pillars B, C, D, A (coordinator smart router)

Operator-paste prompt to implement the four SPEC-004 v0.3.1 pillars in
the coordinator. SPEC-004 v0.3.1 is locked and READ-ONLY; this prompt
drives the **implementation cycle** that consumes it.

- **SPEC-004 v0.3.1** (Smart Router, LOCKED — `specs/SPEC-004-smart-router.md`)
- **SPEC-006 v0.8** prerequisite for Pillar A (LOCKED; PG-9 in §22
  satisfies the gate per `docs/OPEN_QUESTIONS.md` 2026-06-26 triage)

**One-line scope summary.** Ship Pillar B (smart-router weighting +
deterministic tiebreak), Pillar C (breaker composition + recovery
gating), Pillar D (model-class aliases + `fast` / `accurate` /
`balanced` objectives + dispatch-time `model` rewrite), and Pillar A
(sticky affinity keyed on `routing_internal.conversation_key`) in
the coordinator. Default config preserves SPEC-002 v1.3.3 behavior;
every pillar ships behind a default-off config flag. The IMPL
cycle is THREE TO FOUR PRs (one per pillar; Pillar D may bundle
FR-SR-7 + FR-SR-7a). Each PR runs the locked three-lane codex
audit (code / security / architect) to 0 CRITICAL / 0 HIGH / 0
MEDIUM before merge.

**Phase-letter regrouping (read before any PR scope discussion).**
This BUILD prompt deliberately regroups SPEC-004's pillar letters
into IMPLEMENTATION PHASES of the same letter that map differently.
SPEC-004's own §11 uses B = model classes, C = retry, D = epsilon
tiebreak. THIS prompt uses B = weighting + tiebreak scaffolding,
C = breaker composition, D = classes + retry + randomized tiebreak
activation. Treat the names below ("Phase B", "Phase C", etc.) as
IMPLEMENTATION-PHASE labels owned by this BUILD prompt, NOT as
references to SPEC-004's pillar letters. When opening a PR or
audit, name the branch/PR by the implementation phase letter from
THIS file; the spec-side R-rules each phase covers are explicit
in the per-phase "SPEC-004 rules implemented" lines.

**Locked-spec dependencies (DO NOT contradict).** Versions below
reflect current `origin/main` headers as of the BUILD prompt
landing. Verify against each spec file's line 3 before starting an
IMPL session.

- SPEC-001 v1.6 (binary protocol; no provider-facing changes from
  SPEC-004 — see §6 "Provider protocol")
- SPEC-002 v1.5.2 (coordinator base routing — SPEC-004 LAYERS on top,
  does not replace, per SPEC-004 §3)
- SPEC-004 v0.3.1 (THE FILE BEING IMPLEMENTED — read every section
  before writing any line of Go; SPEC-004's own change-log cites
  older dependency versions, which are historical)
- SPEC-005 v0.4 (billing — `request_log.retried` semantics per
  FR-SR-14 are SPEC-005's read contract; do not bypass; v0.4
  preserves the `request_log.retried` read contract relevant to
  Phase D. v0.4 added the force-void quarantine-resolution admin
  surface — that surface is OUT OF SCOPE for this build cycle; see
  "What this prompt does NOT cover")
- SPEC-006 v0.9.1 (`routing_internal.conversation_key` derivation;
  Pillar A consumes this gateway-derived field — NOT a buyer header)

Spec-text changes: the IMPL PRs MUST surface any discovered
normative gap (e.g. SPEC-006 not specifying a behavior Pillar A
needs) as a separate FOLLOW-UP ISSUE filed against the appropriate
spec. The IMPL PRs MUST NOT inline additive paragraphs to SPEC-002
/ SPEC-006 mid-cycle — that creates a spec churn surface this
build cycle is not authorized for. Exception: if the operator
explicitly authorizes a separate spec-text PR before the IMPL PR
opens, that's fine. SPEC-004 v0.3.1 itself stays byte-identical.

Run in **Claude Code**, **Codex CLI**, or another LLM IDE session.
Expected duration: ~4–6 weeks across the four pillars + audit loops
(matches issue #170's estimate). Each pillar is its own session.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are implementing SPEC-004 v0.3.1 Pillars B / C / D / A in the
coordinator (Go). This is a multi-PR implementation cycle, not a
single PR.

You will edit (in priority order):
  /Users/augstar/macprovider-poc/phase4-coordinator/internal/buyer/server.go
  /Users/augstar/macprovider-poc/phase4-coordinator/internal/pool/provider.go
    (the pool Registry type currently lives in `provider.go`; do NOT
     look for `pool/registry.go` — it does not exist on origin/main)
  /Users/augstar/macprovider-poc/phase4-coordinator/internal/config/config.go
  /Users/augstar/macprovider-poc/phase4-coordinator/internal/routing/   (NEW package, see Phase B-1)
  /Users/augstar/macprovider-poc/phase4-coordinator/internal/routing/sticky/  (NEW package, Pillar A only)

You MAY add new Go files under `internal/routing/`. You MUST NOT
edit `specs/SPEC-004-smart-router.md` — that file is locked.

## Critical constraints

**C1. SPEC-004 v0.3.1 is LOCKED and READ-ONLY.** Every R-rule and AC
in `specs/SPEC-004-smart-router.md` is normative. If your
implementation cannot satisfy a clause, STOP and post a comment on
the in-flight PR with the conflict — do NOT silently relax the
clause.

**C2. SPEC-002 v1.3.3 default behavior is byte-identical with all
SPEC-004 defaults.** Per FR-SR-1: with `sticky_enabled: false`, no
`model_classes`, `max_retries: 0`, `tiebreak_randomize: false`,
default `tiebreak_epsilon: 0.0`, the coordinator MUST select the
same providers and return the same buyer-visible responses /
headers as before SPEC-004 landed. The AC-SR-1 default-config
regression test is non-negotiable.

**C3. Every pillar ships behind a default-off config key.** Per
SPEC-004 §5: `routing.sticky_enabled: false`, `routing.model_classes: {}`,
`routing.max_retries: 0`, `routing.tiebreak_randomize: false`,
`routing.tiebreak_epsilon: 0.0`. Production binaries are safe to
deploy without operator config changes.

**C4. SPEC-001 provider protocol is unchanged.** Per SPEC-004 §6
"Provider protocol": no new WS messages, no new heartbeat fields,
no new auth-frame fields. The router is coordinator-internal.

**C5. SPEC-005 `request_log.retried` semantics.** Per FR-SR-14: the
column counts ONLY additional attempts caused by an explicit
`X-MacProvider-Retry` header. SPEC-002 F-4 one-shot failover MUST
NOT increment it. The hot path that writes `request_log` already
exists; you wire `retried` from the SPEC-004 retry attempt counter,
not from any other source.

**C6. F-4 / FR-P5 / FR-P8a / FR-P11a composition (§9).** Sticky
affinity, class expansion, retry, and randomized tiebreak ALL run
ONLY after SPEC-002 state eligibility (FR-P5), warm-up admission
(FR-P8a), capacity, quota, context, AND FR-P11a breaker/recovery-
hold checks. Order matters: filter FIRST, then sort/select.

**C7. Three-lane audit per pillar PR.** Each pillar PR runs the
locked codex audit (code / security / architect lenses) and
iterates until 0 CRITICAL / 0 HIGH / 0 MEDIUM. The convention is in
the user memory `feedback-three-lane-codex-audits`. Audit prompts
go in `specs/AUDIT_SPEC_004_PILLAR_<X>_R<N>_<LENS>_PROMPT.md`.

**C8. d-inference clean-room (FR-SR-20).** Do NOT inspect
d-inference (layr-labs) source. License is NOASSERTION.

**C9. macOS-native config paths.** SPEC-004 keys live under the
existing `routing:` block in coordinator config; the YAML loader
already handles macOS-native paths.

**C10. Worktree-per-pillar.** Each pillar is a fresh worktree:
`git worktree add ../macprovider-spec004-<pillar> -b feat/spec-004-<pillar> origin/main`.
Never edit in the canonical checkout (user memory
`feedback-always-fresh-worktree-for-code-work`).

## Required reading (read fully before writing)

1. `/Users/augstar/macprovider-poc/specs/SPEC-004-smart-router.md`
   v0.3.1 — full document. Anchor sections:
   - §3 architecture (10-step pipeline)
   - §4 FR-SR-1 through FR-SR-20 (each is binding)
   - §5 config (defaults preserve SPEC-002)
   - §6 interface deltas
   - §7 observability (`routing_decision` log shape)
   - §8 AC-SR-1 through AC-SR-16 (each maps to a test you write)
   - §9 composition guarantees (F-4 / FR-P5 / FR-P8a / FR-P11a not
     weakened — this is the audit's #1 question)
   - §11 implementation hand-off

2. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.5.2 — §5 routing algorithm (SPEC-004 LAYERS on this), §7.1 v2
   auth, FR-P5 / FR-P8a / FR-P11a normative sections.

3. `/Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md`
   v0.9.1 — `routing_internal.conversation_key` derivation +
   transport (Pillar A binding source). If §22 PG-9 production
   launch gate is satisfied (per `docs/OPEN_QUESTIONS.md` 2026-06-26
   triage) the gateway-side wiring already exists.

4. `/Users/augstar/macprovider-poc/phase4-coordinator/internal/buyer/server.go`
   — current `selectProvider` / `selectProviderExcluding` plus
   the `forwardStreamSequence` / `forwardWSNonStreamSequence` /
   `forwardHTTPSequence` dispatch helpers (the exact set on
   `origin/main` — verify with `grep -n "^func .*forward" server.go`).
   Read end-to-end before refactoring.

5. `/Users/augstar/macprovider-poc/phase4-coordinator/internal/pool/provider.go`
   — Registry type + provider state machine + candidate filters
   + FR-P11a breaker / recovery primitives. There is NO
   `pool/registry.go` on origin/main; the Registry currently
   lives in `provider.go`. SPEC-004 REUSES these primitives;
   no parallel router.

6. SPEC-005 v0.4 `request_log` schema (`phase4-coordinator/internal/requestlog/`).
   Verify `retried INTEGER NOT NULL DEFAULT 0` column exists. If
   missing, that's a SPEC-002 migration prerequisite — surface
   before any pillar IMPL. SPEC-005 v0.4's force-void quarantine-
   resolution admin surface (OQ-5 partial) does NOT alter the
   `request_log.retried` read contract Phase D writes; v0.4 only
   adds a separate admin endpoint + table + audit event.

## Phase order (FOUR PRs, in this order)

### Phase B: smart-router weighting + deterministic tiebreak

**Branch:** `feat/spec-004-pillar-b`
**Config keys added:** `routing.tiebreak_epsilon` (default `0.0`)
**SPEC-004 rules implemented:** FR-SR-1 default-preservation; the
`effective_throughput = throughput_tps_estimate * tier_weight`
helper (referenced from FR-SR-8 `fast` objective and §3 step 6);
the helper data structures for FR-SR-16 (epsilon-cohort
identification). NO randomized tiebreak active in this PR;
`tiebreak_randomize` parsing lands here as a VALID config value
(true or false per SPEC-004 §5) but does NOT activate randomized
selection — Phase B leaves the active comparator unchanged. The
runtime randomization wiring lands in Phase D per FR-SR-16. Phase
B MUST NOT reject `tiebreak_randomize=true` with a load-time or
runtime validation error; doing so would violate SPEC-004 §5.

**Critical default-preservation invariant.** Per SPEC-004 FR-SR-16:
"When `routing.tiebreak_randomize` is false, SPEC-002 deterministic
ordering is unchanged." Phase B MUST NOT change the comparator that
runs when `tiebreak_randomize=false` (the default). The
`effective_throughput` helper exists as a building block for Phase
D; Phase B does NOT install it as part of the active selection
path. The candidate-set order remains SPEC-002 v1.3.3 byte-identical
in Phase B regardless of `tiebreak_epsilon` value.

**Files touched:**
- `internal/config/config.go` — reconcile (NOT add) `Routing`
  substruct: ensure `TiebreakEpsilon float64` (default `0.0`) +
  `TiebreakRandomize bool` (default `false`) fields exist with
  validation `epsilon >= 0`. `randomize=true` is a VALID config
  per SPEC-004 §5 (it defines exact-tie-only random cohort when
  epsilon=0); do NOT add a Phase-B validation error for it.
  Phase B accepts the flag in config but leaves the active
  selection path unchanged — the runtime randomization wiring
  lands in Phase D per FR-SR-16. Some `routing.*` fields already
  exist on origin/main with potentially stale defaults — verify
  against SPEC-004 §5 BEFORE adding new fields.
- `internal/routing/` (NEW package) — `Candidate` struct,
  `effectiveThroughput(provider)` helper, `inEpsilonCohort(epsilon,
  metric)` helper. NOT yet wired into the selection path.
- `internal/buyer/server.go` — NO change to `selectProvider`
  candidate-ordering in Phase B; only ensure the helpers are
  importable from the new `routing` package.

**ACs proven (write tests):** AC-SR-1 (default-config regression
— this is the LOAD-BEARING test for Phase B; it MUST pass after
Phase B lands and prove the candidate order is byte-identical
for two same-model providers with identical metrics and different
`connected_at`). AC-SR-4 partial (hard pins unchanged). AC-SR-14
is "composition gates hold" per SPEC-004 §8 — Phase B proves the
helper-layer subset (Candidate / effectiveThroughput helpers DO
NOT alter the F-4 / FR-P5 / FR-P8a / FR-P11a composition surface).
Phase C and Phase D each extend AC-SR-14 with their own feature-
addition leg; Phase A adds the sticky leg. The "per-request
breaker fault cap" assertion is FR-SR-14 regression coverage,
NOT AC-SR-14 — see Phase D below.

**Audit lenses:** code (does the tiebreak code preserve SPEC-002
ordering at epsilon=0?), security (does an oversized epsilon ever
let a degraded provider sneak in?), architect (is this the right
home for `Candidate`? does it cleanly host Pillar C/D additions
next?).

### Phase C: breaker composition + recovery gating

**Branch:** `feat/spec-004-pillar-c`
**Config keys added:** none new (Phase C composes existing FR-P11a
flags).
**SPEC-004 rules implemented:** FR-SR-18 (composition with FR-P5 +
FR-P8a + FR-P11a — explicit filter ORDER), FR-SR-19 (F-4
composition: same dead provider not selected twice).

**Files touched:**
- `internal/routing/filter.go` (NEW) — `EligibleCandidates(pool,
  request)` returns the candidate set AFTER all SPEC-002
  composition gates. Existing buyer/server.go logic refactored into
  this helper.
- `internal/buyer/server.go` — `selectProvider` becomes:
  `filter → sort → tiebreak → preflight`.
- `internal/routing/exclusion.go` (NEW) — `Excluded(providers)` set
  threading for F-4 + retry composition.

**ACs proven:** AC-SR-14 leg-2 (composition gates: Phase C proves
the filter helper + FR-P11a recovery-gating composition leg of
"composition gates hold" — sticky / class / retry / randomization
legs are proven in their own phases, not here), the FR-SR-18 +
FR-SR-19 ordering assertions, breaker-held provider explicit-
exclude regression.

**Audit lenses:** code (does the filter helper produce the same
candidate set as the v1.5.2 inline code at epsilon=0 / no classes
/ no retry?), security (any path where a breaker-held provider
leaks into selection?), architect (is the new `routing` package
boundary right? does it correctly absorb sticky and class lookups
in Phase A/D?).

### Phase D: model-class aliases + objectives + dispatch rewrite

**Branch:** `feat/spec-004-pillar-d`
**Config keys reconciled / added:** `routing.model_classes` (default
empty map), `routing.max_retries` (default 0; if already present
on origin/main with a different default, RECONCILE to 0),
`routing.retry_per_attempt_timeout_s` (default 60),
`routing.max_providers_faulted_per_request` (default 2 per
SPEC-004 §5; on origin/main `config.Default()` currently has
`MaxProvidersFaultedPerRequest: 0` and validation allows `>= 0`
— Phase D MUST reconcile the default to `2` AND tighten validation
to require a positive integer whenever `routing.max_retries > 0`.
Validation failure mode: load-time error naming the offending key
and the SPEC-004 §5 minimum),
`routing.tiebreak_randomize` (default false — Phase D enables it
with the FR-SR-16 randomized epsilon cohort; FR-SR-17 audit
explainability fields mandatory).

**Retry invariants (top of Phase D — implement these FIRST).**
Before writing the retry loop, encode these as Go-level invariants
in `internal/routing/retry.go`:
1. **`max_retries=0` short-circuits the loop.** Per FR-SR-11: if
   `routing.max_retries == 0` OR `X-MacProvider-Retry` is missing
   or false-like, the coordinator MUST NOT enter the retry loop
   even once. The first attempt's result is the buyer-visible
   result; `request_log.retried = 0`. Write a regression test that
   sends `X-MacProvider-Retry: 1` with `max_retries: 0` and
   asserts a single provider attempt + `retried=0`.
2. **Never retry after commit (FR-SR-13).** Once response bytes
   are committed to the buyer, the request is terminal.
3. **Never double-emit (FR-SR-14).** A buyer request produces
   AT MOST one terminal buyer-visible response.
4. **Never double-count success (FR-SR-14).** Only the final
   successful provider attempt writes the `ledger_request_credits`
   success row; failed attempts are logged but do NOT produce
   duplicate buyer completions.
5. **`request_log.retried` increments ONLY on explicit SPEC-004
   retries (FR-SR-14).** Sharing attempt-counter plumbing with F-4
   one-shot failover is FORBIDDEN. Phase D MUST add a separate
   counter for the SPEC-004 retry path; F-4 must not touch it.
6. **Per-request breaker fault cap (FR-SR-14).** A single buyer
   request MUST NOT push more than
   `min(routing.max_providers_faulted_per_request, routing.max_retries)`
   distinct providers across the FR-P11a breaker threshold. Once
   the per-request cap is reached, the coordinator MUST abort
   further retries and return the current buyer-visible error.
   Phase D MUST emit a regression test that drives N+1 retries
   into N pre-commit failures and asserts the (N+1)-th attempt is
   skipped (no new breaker fault charged).

**Hostile-body invariant (FR-SR-7a).** The request body's top-level
`model` field is BUYER input. The coordinator MUST reject
duplicate or non-canonical case variants (e.g., a body containing
both `model` and `Model`) with HTTP 400 `invalid_request` BEFORE
candidate selection or alias resolution. This is a SECURITY
boundary: the coordinator's parsed `model` MUST match what the
provider observes after dispatch rewrite.

**SPEC-008 / SPEC-010 additive-only invariant (FR-SR-10
composition rules — read before editing `/v1/models`).** The
FR-SR-10 class entries Phase D adds to `/v1/models` MUST be
PURELY ADDITIVE to the existing SPEC-008 / SPEC-010 surface. They
MUST NOT alter Tier-2 hash disclosure (SPEC-008 §5.7 hash block
is unaffected per SPEC-010 v1.5 §6.3), MUST NOT alter any
concrete-model entry's existing fields, and MUST NOT change how
`model_hash` flows through the heartbeat or auth-frame contracts.
SPEC-010 cold-supported-model behavior is unchanged. Phase D MUST
write a regression test that captures the pre-Pillar-D
`/v1/models` body shape for an existing concrete model and asserts
the post-Pillar-D shape contains the identical concrete entry
verbatim (alongside any new class entries).

**SPEC-004 rules implemented:** FR-SR-7 (alias resolution),
FR-SR-7a (dispatch-time `model` field rewrite at EVERY dispatch
path — see §11 implementation hand-off; current dispatch is split
across `forwardStreamSequence`, `forwardWSNonStreamSequence`,
`forwardHTTPSequence`, and the streaming helpers; verify the
function set against current `server.go` before starting Phase D),
FR-SR-7c (1 MiB body cap — already enforced in v0.3.1 code; the
operator-tunable override knob is OUT OF SCOPE for Pillar D —
Phase D verifies the existing 1 MiB cap remains enforced and does
NOT relax it or add a new knob; that's a separate config-extension
PR if/when needed), FR-SR-8 objectives (`fast`, `accurate`,
`balanced` with the v0.2 normative score formula), FR-SR-9
(empty-class 503 with `no_provider_available` envelope), FR-SR-10
(`/v1/models` advertises classes additively), FR-SR-11 / FR-SR-12
/ FR-SR-13 / FR-SR-14 / FR-SR-15 (retry mechanics + budget),
FR-SR-16 (randomized tiebreak), FR-SR-17
(reproducibility-of-randomized-decision logging).

**Files touched:**
- `internal/routing/class.go` (NEW) — alias resolution +
  `balanced` score formula (FR-SR-8). Score components MUST log
  individually per FR-SR-8 last paragraph.
- `internal/routing/objective.go` (NEW) — `fast` / `accurate` /
  `balanced` sort comparator.
- `internal/routing/dispatch.go` (NEW) — `RewriteModel(body, target)`
  function applied at every dispatch path.
- `internal/routing/retry.go` (NEW) — retry loop with budget +
  exclusion + buyer-cancel attribution (FR-P11a C2).
- `internal/routing/log.go` (NEW) — `LogRoutingDecision(ctx, dec)`
  emits the FR-SR-17 reproducibility-of-randomized-decision log
  row. Fields (every field below is REQUIRED on every routing
  decision when `tiebreak_randomize=true` is active, suppressed-
  with-zero when not): `candidate_set` (ordered list of
  `peer_id`s post-filter pre-sort), `objective_metric_per_candidate`
  (parallel array of the score driving the cohort), `epsilon`
  (the active `routing.tiebreak_epsilon`), `cohort_size`,
  `random_seed` (the per-request seed used; SPEC-004 §7
  reproducibility contract — MUST be derivable from request id +
  daily key, NEVER from `time.Now()` alone), `random_draw` (the
  cohort index chosen), `chosen_peer_id`. The call site lives in
  `internal/buyer/server.go::selectProvider` (or its Phase B
  refactored equivalent) and fires AFTER candidate selection,
  BEFORE dispatch.
- `internal/buyer/server.go` — `/v1/chat/completions` wires class
  resolution + retry loop + dispatch rewrite, AND calls
  `LogRoutingDecision` per request when randomization is active.
- `internal/buyer/server.go::handleModels` (the existing
  `/v1/models` handler — on `origin/main` there is no separate
  `models.go` file; extend the handler in place) — additive
  class entry shape per FR-SR-10.

**ACs proven:** AC-SR-5 (class routes to right provider; body
assertion on the wire), AC-SR-6 (empty class 503), AC-SR-7
(`/v1/models` class advertisement), AC-SR-8 (retry success),
AC-SR-9 (no retry post-commit / buyer-cancel), AC-SR-10 (no
double-emit), AC-SR-11 (retry budget), AC-SR-12 (randomized
distribution under sufficient mock-load), AC-SR-13 (log
explainability), AC-SR-14 leg-3/4 (composition gates: Phase D
proves the class + retry + randomization legs of "composition
gates hold"), AC-SR-16 (retry budget + cancel attribution).
**FR-SR-14 regression coverage (NOT AC-SR-14):** assert the
`min(max_providers_faulted_per_request, max_retries)` per-request
breaker fault cap is honored — drive N+1 retries into N pre-commit
failures and assert the (N+1)-th attempt is skipped (no new
breaker fault charged).

**Audit lenses:** code (does FR-SR-7a rewrite at EVERY dispatch
path — write the assertForwardedModel helper from SPEC-004 §test-
discipline?), security (does the class-objective score normalization
let an attacker game a single-component spike to dominate
selection?), architect (does Pillar D's surface area force a v0.4
SPEC bump, or stay v0.3.1-compliant?).

### Phase A: sticky affinity (SPEC-006 v0.9.1 dependent)

**Branch:** `feat/spec-004-pillar-a`
**Config keys added:** `routing.sticky_enabled` (default false),
`routing.sticky_ttl_s` (default 1800), `routing.sticky_max_entries`
(default 10000).

**Sticky source invariant (Phase A — implement this FIRST).** The
sticky-affinity key MUST come ONLY from gateway-authenticated
internal metadata, specifically the gateway-derived
`routing_internal.conversation_key` field. This is NOT a buyer
header. Pillar A MUST NOT read any `X-MacProvider-Conversation`
(or similarly-named) buyer-supplied request header. Per SPEC-004
FR-SR-2: values that do not begin with `conv:` MUST be REJECTED or
treated as absent for sticky purposes. Treat any direct-buyer-
traffic path (i.e. requests arriving without the gateway's
authenticated forwarding) as carrying NO conversation key. This
is a SECURITY boundary: accepting buyer-supplied sticky keys
would let a hostile buyer pin themselves to a specific provider
or steal another buyer's sticky session.

**Sticky bounded-map SECURITY / DoS boundary (Phase A — read before
implementing).** The `routing.sticky_max_entries` cap is NOT
ordinary cache hygiene; it is a SECURITY / DoS boundary. A buggy
eviction path, unbounded growth, or missing mutex coverage on any
of the five FR-SR-5 paragraph 2 operations (read, write,
`last_used_at` update, TTL expiry, LRU eviction) is a release
blocker, not a perf nit. The audit and AC layers below treat any
unbounded-growth or race-condition class as HIGH severity.

**Sticky-disabled allocation allowance (Phase A — C2 clarification).**
With `routing.sticky_enabled: false`, sticky storage MAY be
constructed in an inert state at startup (zero-value `Map`, empty
mutex), but request handling MUST perform no sticky read, no
sticky write, no `last_used_at` update, no TTL expiry sweep, no
LRU eviction, and no sticky-log mutation. AC-SR-1 byte-identity
holds against allocation OR inert-construction; SPEC-004 AC-SR-1
requires no lookup/write/log-order change, not necessarily zero
allocation.

**SPEC-004 rules implemented:** FR-SR-2 (sticky keying on
`routing_internal.conversation_key`; reject values not in
`conv:<opaque-id>` namespace), FR-SR-3 (sticky is soft preference;
subordinate to objective epsilon cohort), FR-SR-4 (hard pin
precedence over sticky), FR-SR-5 (lifecycle: in-memory, TTL +
LRU eviction, bounded map, mutex-serialized, invalidate on class
reconfig), FR-SR-6 (update only on committed success;
update-on-retry-final-provider rule).

**Files touched:**
- `internal/routing/sticky/sticky.go` (NEW package) — `Map` type
  with TTL + LRU + mutex; `Lookup(conversationKey)`,
  `Update(conversationKey, providerID, modelScope)`,
  `InvalidateClass(className)`.
- `internal/buyer/server.go` — sticky lookup at §3 step 4 (after
  hard-pin precedence resolution per FR-SR-4); sticky update at
  §3 step 10 (post-commit per FR-SR-6).
- `internal/routing/promote.go` (NEW or extension of `class.go`) —
  promote sticky hit to position 0 ONLY when inside
  `tiebreak_epsilon` cohort (FR-SR-3 second paragraph).

**ACs proven:** AC-SR-2 (sticky hit routes to prior provider),
AC-SR-3 (sticky miss falls back gracefully — every miss reason
enumerated in FR-SR-3 covered), AC-SR-14 leg-1 (composition gates:
Phase A proves the sticky leg of "composition gates hold"),
AC-SR-15 (session hard-pin is never sticky).
**Sticky lifecycle / concurrency regression tests (FR-SR-5
SECURITY / DoS boundary — these are gating, not optional):**
(a) bounded-map eviction at `routing.sticky_max_entries` — insert
N+1 distinct keys, assert oldest evicted (LRU); (b) TTL expiry —
advance synthetic clock past `routing.sticky_ttl_s`, assert prior
entry no longer returned by `Lookup`; (c) concurrent mixed
operation race coverage — N goroutines hammering `Lookup` /
`Update` / `last_used_at` / TTL-sweep / eviction simultaneously,
asserting no panic, no double-free of LRU positions, no entry
count exceeding `routing.sticky_max_entries`, no read-after-evict;
(d) `InvalidateClass` under concurrent reads — asserts class
removal is mutex-serialized with active `Lookup` calls.

**Audit lenses:** code (does the mutex protect ALL of the
operations FR-SR-5 paragraph 2 enumerates: read, write,
`last_used_at` update, TTL expiry, LRU eviction?), security (does
the `conv:<opaque-id>` namespace gate REJECT any non-prefixed
value, including an attacker-crafted `assigned_id` collision?
does the opaque suffix appear in coordinator logs unredacted?),
architect (does the in-memory loss-on-restart policy per FR-SR-5
need an operator runbook note for SPEC-006 v0.8 PG-9 cutover, or
is the existing fallback to default routing sufficient?).

## Per-pillar audit discipline (locked)

For each pillar PR:

1. Write the IMPL.
2. Write three audit prompts:
   - `specs/AUDIT_SPEC_004_PILLAR_<X>_R1_CODE_PROMPT.md`
   - `specs/AUDIT_SPEC_004_PILLAR_<X>_R1_SECURITY_PROMPT.md`
   - `specs/AUDIT_SPEC_004_PILLAR_<X>_R1_ARCH_PROMPT.md`
3. Fire each as `omc ask codex -p "$(cat <PROMPT>)"` in parallel.
4. Capture results in `specs/SPEC-004-PILLAR_<X>-r1-audit.md`.
5. Fix findings; bump round; re-audit; iterate until 0 CRITICAL /
   0 HIGH / 0 MEDIUM across all three lanes.
6. Open the PR with the locked three-lane audit table in the body
   (see PR #247 / #244 templates for shape).
7. After merge, mirror local `main`:
   `git checkout main && git fetch origin && git reset --hard origin/main`
   (user memory `pr-merge-workflow-rule`).

## What this prompt does NOT cover

- **SPEC-004 v0.4 amendments.** v0.3.1 is the target; no v0.4 work
  in this cycle.
- **Operator green-light to flip flags `true`.** Implementation
  ships with defaults OFF. Phase 2 of issue #170 (operator flip)
  is OUT OF SCOPE for the IMPL cycle.
- **SPEC-001 provider-side work.** No provider binary changes; all
  SPEC-004 behavior is coordinator-internal.
- **Gateway-side `routing_internal.conversation_key` derivation.**
  That's SPEC-006 v0.8 PG-9; the coordinator only CONSUMES the
  header in Pillar A.
- **SPEC-005 OQ-5 quarantine-resolution admin surface.** SPEC-005
  v0.4 added the force-void quarantine-resolution admin endpoint
  + table + audit event (and v0.5 will add force-credit). Pillar D
  touches retry / accounting paths adjacent to that surface but
  MUST preserve existing quarantine behavior verbatim — no new
  admin endpoints, no resolution-row writes, no quarantine-table
  schema changes in this build cycle.
- **SPEC-008 hash-disclosure changes.** SPEC-008 §5.7 hash block
  is unaffected; Phase D's `/v1/models` edits are PURELY ADDITIVE
  class entries (see Phase D body).
- **SPEC-010 cold-supported-model behavior changes.** SPEC-010
  v1.5+ cold-supported-model surface is unchanged; Phase D's
  `/v1/models` edits MUST NOT alter concrete-model entry fields.

## Pillar-completion checklist (gate to next pillar)

A pillar is "done" only when ALL of these are true:

- [ ] All SPEC-004 R-rules in the pillar's scope (listed above per
      phase) have an AC test asserting them.
- [ ] All three audit lanes returned 0 CRITICAL / 0 HIGH / 0 MEDIUM
      on the final round.
- [ ] The PR is merged into `origin/main` via squash-merge.
- [ ] Local `main` is reset to `origin/main`; pillar branch deleted.
- [ ] AC-SR-1 default-config regression test still passes — verify
      with `go test -count=1 -run TestSPEC004DefaultConfigRegression ./...`.
- [ ] **Pillar D additional money-path gate:** focused requestlog +
      billing reconciliation tests pass — assert (a) explicit
      `X-MacProvider-Retry` increments `request_log.retried`,
      (b) F-4 one-shot failover does NOT increment it, (c) the
      `attempt_n` monotonic ordinal (SPEC-002 v1.5.2) writes
      correctly under retry, (d) the SPEC-005 quarantine path
      behaves identically pre/post-Pillar-D.
- [ ] **Pillar A additional money-path gate:** verify the
      gateway-authenticated `routing_internal.conversation_key` path
      is the ONLY input to the sticky map; assert with a direct-
      buyer-traffic test that an `X-MacProvider-Conversation`
      header (or similar) DOES NOT populate the map.
- [ ] Issue #170 has a comment naming the pillar PR + audit-rounds-
      to-convergence count.

When all four pillars ship, close issue #170 with a final comment
linking the four PR URLs and the operator green-light note (Phase 2
remains operator-owned).

=== END PROMPT ===
```

---

## Operator notes (do not paste into the implementer session)

- **Sequencing.** B → C → D → A is intentional. Pillar D requires
  Pillar C's filter helper; Pillar A requires Pillars B/C/D for the
  epsilon-cohort + class-invalidation hooks. Sticky on top of an
  unfinished tiebreak engine produces nondeterministic regressions.
- **Estimated wall-clock.** 4–6 weeks across the four pillars per the
  issue #170 estimate. The Pillar D session is the longest (most
  R-rules, most ACs, most dispatch paths).
- **Composition with SPEC-005.** Pillar D's retry rules write
  `request_log.retried`; SPEC-005 §15.2 reads that column via the
  `attempt_n` patch path. SPEC-002 v1.5.2's monotonic `attempt_n`
  column is the canonical ordinal — verify it remains correct
  under SPEC-004 retry attempts (the Phase D money-path gate test
  list above pins this).
- **Composition with SPEC-007.** SPEC-007 explorer reads
  `request_log` + ledger rows + gateway `audit_events`; it does
  NOT consume `routing_decision` structured logs. Pillar A's
  `routing_decision` log surface lands in the coordinator log
  stream and is operator-visible there; integration into SPEC-007
  explorer is OUT OF SCOPE for this IMPL cycle and requires a
  separate durable-event contract (deferred).
- **Composition with SPEC-008 / SPEC-010.** No SPEC-008 hash-
  verification behavior changes. SPEC-008 §5.7 hash block is
  unaffected (per SPEC-010 v1.5 §6.3). SPEC-010 cold-supported-
  model behavior is unchanged. The FR-SR-10 `/v1/models` class
  entries MUST be ADDITIVE only — they MUST NOT alter Tier-2 hash
  disclosure, alter concrete-model entry fields, or change how
  `model_hash` flows through the heartbeat/auth-frame contracts.
- **FR-SR-7c body cap is OUT OF SCOPE for Pillar D.** The 1 MiB
  cap is already enforced in code as `Limits.MaxChatRequestBodyBytes`
  in `phase4-coordinator/internal/config/config.go` (see SPEC-004
  v0.3.1 §FR-SR-7c "_RESOLVED 2026-06-26_" note for the exact
  closure). Pillar D MUST verify this cap remains enforced and
  MUST NOT add a new operator-tunable knob or relax the existing
  default in any pillar PR. If/when an operator-tunable knob is
  desired, it ships as a separate config-extension PR outside this
  build cycle.
- **What happens if SPEC-006 v0.8 PG-9 turns out incomplete.** Per
  SPEC-004 FR-SR-2 last paragraph: "Pillar A implementation MUST
  NOT begin until SPEC-006 v0.8 lands the conversation-key
  mechanism." If discovery during Pillar A IMPL finds the gateway
  doesn't actually forward the field, PAUSE Pillar A and surface
  the gap as a SPEC-006 follow-up issue. Pillars B/C/D proceed
  regardless (per FR-SR-2 same paragraph).
