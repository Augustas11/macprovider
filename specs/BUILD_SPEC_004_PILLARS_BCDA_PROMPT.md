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

**Locked-spec dependencies (DO NOT contradict).**
- SPEC-001 v1.3 (binary protocol; no provider-facing changes from
  SPEC-004 — see §6 "Provider protocol")
- SPEC-002 v1.5.2 (coordinator base routing — SPEC-004 LAYERS on top,
  does not replace, per SPEC-004 §3)
- SPEC-004 v0.3.1 (THE FILE BEING IMPLEMENTED — read every section
  before writing any line of Go)
- SPEC-005 v0.4 (billing — `request_log.retried` semantics per
  FR-SR-14 are SPEC-005's read contract; do not bypass)
- SPEC-006 v0.8.1 (`routing_internal.conversation_key` derivation;
  Pillar A consumes this header from gateway)

Spec-text-only changes ALLOWED: the IMPL PRs MAY add additive
cross-cite paragraphs to SPEC-002 / SPEC-006 where the implementation
discovers a normative gap (e.g. "SPEC-006 v0.8 owns the
`X-MacProvider-Conversation` HMAC derivation" — if missing in
SPEC-006 v0.8, ADD the paragraph as part of the SPEC-004 IMPL PR).
SPEC-004 v0.3.1 itself stays byte-identical.

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
  /Users/augstar/macprovider-poc/phase4-coordinator/internal/pool/registry.go
  /Users/augstar/macprovider-poc/phase4-coordinator/internal/pool/provider.go
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
   v0.8.1 — `routing_internal.conversation_key` derivation +
   transport (Pillar A binding source). If §22 PG-9 production
   launch gate is satisfied (per `docs/OPEN_QUESTIONS.md` 2026-06-26
   triage) the gateway-side wiring already exists.

4. `/Users/augstar/macprovider-poc/phase4-coordinator/internal/buyer/server.go`
   — current `selectProvider` / `selectProviderExcluding` /
   `forwardRequest` / `forwardChatRequest` paths. Read end-to-end
   before refactoring.

5. `/Users/augstar/macprovider-poc/phase4-coordinator/internal/pool/registry.go`
   + `provider.go` — provider state machine, candidate filters,
   FR-P11a breaker / recovery primitives. SPEC-004 REUSES these;
   no parallel router.

6. SPEC-005 v0.4 `request_log` schema (`phase4-coordinator/internal/requestlog/`).
   Verify `retried INTEGER NOT NULL DEFAULT 0` column exists. If
   missing, that's a SPEC-002 migration prerequisite — surface
   before any pillar IMPL.

## Phase order (FOUR PRs, in this order)

### Phase B: smart-router weighting + deterministic tiebreak

**Branch:** `feat/spec-004-pillar-b`
**Config keys added:** `routing.tiebreak_epsilon` (default `0.0`)
**SPEC-004 rules implemented:** FR-SR-1 default-preservation, the
`effective_throughput = throughput_tps_estimate * tier_weight`
computation (referenced from FR-SR-8 `fast` objective and §3 step
6), default-utilization-mode tiebreak (FR-SR-16 first bullet:
"candidates with `slots_free` equal to the best candidate and
effective throughput within `routing.tiebreak_epsilon` of the best
effective throughput"). NO randomized tiebreak in this PR;
`tiebreak_randomize` parsing lands here but `true` is unimplemented
and validated as a runtime error if set.

**Files touched:**
- `internal/config/config.go` — add `Routing` substruct with
  `TiebreakEpsilon float64` + `TiebreakRandomize bool` + validation
  (epsilon >= 0; randomize=true → return validation error
  "spec_004_randomize_not_yet_implemented" until Phase D).
- `internal/routing/` (NEW package) — `Candidate` struct,
  `effectiveThroughput(provider)`, `tieBreak(epsilon, mode)` helper.
- `internal/buyer/server.go` — `selectProvider` calls
  `routing.TieBreak` BEFORE the existing `connected_at` fallback.

**ACs proven (write tests):** AC-SR-1 (default-config regression),
AC-SR-4 partial (hard pins unchanged), AC-SR-14 partial (composition
gates).

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

**ACs proven:** AC-SR-14 (composition gates hold across all SPEC-004
features), the FR-SR-18 + FR-SR-19 ordering assertions, breaker-held
provider explicit-exclude regression.

**Audit lenses:** code (does the filter helper produce the same
candidate set as the v1.5.2 inline code at epsilon=0 / no classes
/ no retry?), security (any path where a breaker-held provider
leaks into selection?), architect (is the new `routing` package
boundary right? does it correctly absorb sticky and class lookups
in Phase A/D?).

### Phase D: model-class aliases + objectives + dispatch rewrite

**Branch:** `feat/spec-004-pillar-d`
**Config keys added:** `routing.model_classes` (default empty map),
`routing.max_retries` (default 0), `routing.retry_per_attempt_timeout_s`
(default 60), `routing.max_providers_faulted_per_request` (default 2),
`routing.tiebreak_randomize` (default false — Phase D enables it
with the FR-SR-16 randomized epsilon cohort; FR-SR-17 audit
explainability fields mandatory).

**SPEC-004 rules implemented:** FR-SR-7 (alias resolution),
FR-SR-7a (dispatch-time `model` field rewrite at EVERY dispatch
path — WS streaming, WS non-streaming, HTTP streaming, HTTP
non-streaming), FR-SR-7c (1 MiB body cap — already enforced in
v0.3.1 code per `phase4-coordinator/internal/config/config.go:112`;
verify operator override hooks land), FR-SR-8 objectives (`fast`,
`accurate`, `balanced` with the v0.2 normative score formula),
FR-SR-9 (empty-class 503 with `no_provider_available` envelope),
FR-SR-10 (`/v1/models` advertises classes additively),
FR-SR-11 / FR-SR-12 / FR-SR-13 / FR-SR-14 / FR-SR-15 (retry
mechanics + budget), FR-SR-16 (randomized tiebreak), FR-SR-17
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
- `internal/buyer/server.go` — `/v1/chat/completions` wires class
  resolution + retry loop + dispatch rewrite.
- `internal/buyer/models.go` (or `/v1/models` handler) — additive
  class entry shape per FR-SR-10.

**ACs proven:** AC-SR-5 (class routes to right provider; body
assertion on the wire), AC-SR-6 (empty class 503), AC-SR-7
(`/v1/models` class advertisement), AC-SR-8 (retry success),
AC-SR-9 (no retry post-commit / buyer-cancel), AC-SR-10 (no
double-emit), AC-SR-11 (retry budget), AC-SR-12 (randomized
distribution under sufficient mock-load), AC-SR-13 (log
explainability), AC-SR-16 (retry budget + cancel attribution).

**Audit lenses:** code (does FR-SR-7a rewrite at EVERY dispatch
path — write the assertForwardedModel helper from SPEC-004 §test-
discipline?), security (does the class-objective score normalization
let an attacker game a single-component spike to dominate
selection?), architect (does Pillar D's surface area force a v0.4
SPEC bump, or stay v0.3.1-compliant?).

### Phase A: sticky affinity (SPEC-006 v0.8 PG-9 dependent)

**Branch:** `feat/spec-004-pillar-a`
**Config keys added:** `routing.sticky_enabled` (default false),
`routing.sticky_ttl_s` (default 1800), `routing.sticky_max_entries`
(default 10000).

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
enumerated in FR-SR-3 covered), AC-SR-15 (session hard-pin is
never sticky).

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
- **Composition with SPEC-005 / SPEC-007.** Pillar D's retry rules
  write `request_log.retried`; SPEC-005 v0.4 §15.2 reads that column
  via the `attempt_n` patch path. Pillar A's `routing_decision` log
  surface composes with SPEC-007 v0.4 explorer; no schema change
  needed in v0.3.1 IMPL.
- **What changes if FR-SR-7c body cap operator-override lands.**
  The 1 MiB cap is already enforced in code (per the SPEC-004
  v0.3.1 §FR-SR-7c "_RESOLVED 2026-06-26_" note). If a future PR
  adds the operator-tunable knob (`routing.request_body_bytes` or
  equivalent), the BUILD prompt is unchanged — that's a separate
  config-extension PR that doesn't touch any pillar.
- **What happens if SPEC-006 v0.8 PG-9 turns out incomplete.** Per
  SPEC-004 FR-SR-2 last paragraph: "Pillar A implementation MUST
  NOT begin until SPEC-006 v0.8 lands the conversation-key
  mechanism." If discovery during Pillar A IMPL finds the gateway
  doesn't actually forward the field, PAUSE Pillar A and surface
  the gap as a SPEC-006 follow-up issue. Pillars B/C/D proceed
  regardless (per FR-SR-2 same paragraph).
