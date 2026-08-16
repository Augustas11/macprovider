# Build prompt — SPEC-004 Smart Router (all four pillars, code implementation)

Operator-paste prompt to implement **all four SPEC-004 pillars** in one
integrated build: A (sticky session affinity, gateway+coordinator+nginx), B
(model-class aliases), C (coordinator-managed retry), D (randomized
ε-tolerance tiebreak). Supersedes `BUILD_SPEC_004_A_IMPL_PROMPT.md` (the A-only
prompt) — keep it as a historical artifact, do NOT execute it.

Spec-side preconditions are met:
- **SPEC-004 v0.2** — independently audited ACCEPT (zero CRITICAL/MAJOR).
- **SPEC-006 v0.8.1** — independently audited; 1 MAJOR + 2 MINOR + 1 CRITICAL
  closed in-session per the audit's prescribed text.
- **SPEC-001 v1.2.4** — LOCKED. No wire change in this build.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===` into a
fresh Codex session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are implementing all four SPEC-004 Smart Router pillars (A sticky, B
classes, C retry, D ε-tiebreak) as one integrated coordinator+gateway change.
This is implementation work, not spec-writing. Spec text is authoritative; do
NOT modify any locked spec in this build. Three independent audit rounds on
prior work have each caught one defect the implementer's self-audit missed
(HIGH/CRITICAL/MAJOR), so follow the discipline below precisely: per-pillar
commits, default-off behavior at install, comprehensive composition tests,
and a structured hand-off for an independent code-review pass.

## Locked specs (read; do NOT modify)
  SPEC-001 v1.2.4   — phase3-binary provider WS protocol (LOCKED; no wire change)
  SPEC-002 v1.3.3   — coordinator request router (you EXTEND its §5; no spec edit)
  SPEC-003 v0.7    — open onboarding
  SPEC-004 v0.2    — smart router (THIS is what you implement)
  SPEC-006 v0.8.1  — buyer API gateway (THIS is what you implement on the gateway side)

## Required reading (in order, fully)
1. `specs/SPEC-004-smart-router.md` v0.2 — the routing-side contract for all
   four pillars. Pay special attention to:
   - §3 routing pipeline (the ordered steps your selectProvider replacement
     must follow)
   - FR-SR-1 default-preserving rule (every new key at default → identical
     provider selection + buyer-visible response vs SPEC-002 v1.3.3)
   - FR-SR-2 + §6 + AC-SR-15: `X-MacProvider-Session` is HARD-PIN ONLY; sticky
     keys off the gateway-derived `routing_internal.conversation_key`
   - FR-SR-8 `balanced` model-class formula (concrete; testable)
   - FR-SR-12/13/14/15 retry semantics (per-attempt timeout, C2 carve-out,
     idempotency, retried column = explicit retries only)
   - FR-SR-17 randomized tiebreak audit-reproducibility (candidate set +
     metrics + ε + seed/draw + choice in logs)
   - §9 composition guarantees (MUST NOT weaken FR-P5, F-4, FR-P8a, FR-P11a)
2. `specs/SPEC-006-buyer-api.md` v0.8.1 — gateway-side contract:
   - § 1.3 satisfaction clauses (5 preconditions): the HMAC algorithm
     (§ 1.3 steps 1–7) is the source of truth — DO NOT restate in code
     comments; reference the spec.
   - § 1.6 5th plaintext-to-provider property + `tier1_disclosure.sticky_affinity`
   - § 5.4.1 buyer-header surface (`X-MacProvider-Conversation`,
     `X-MacProvider-Internal-Conv`, the **before-authentication** strip MUST
     and WARN audit-event MUST)
   - DELETE /v1/sticky semantics ({purged, entries}, account-scoped,
     idempotent, silent-ignore on default-off)
   - § 22 PG-9 conditional disclosure parity gate
3. `specs/SPEC-002-coordinator.md` v1.3.3:
   - FR-R3 `X-MacProvider-Session` hard-pin contract (returns 503
     `session_ended` on miss; MUST NOT fail over) — your code MUST preserve
     this exactly; AC-SR-15 enforces it.
   - F-4 dead-WS one-shot failover + hard pins don't fail over
   - FR-P5 routing eligibility / state machine
   - FR-P8a admission warm-up gate (a sticky provider in warmup is NOT
     routable — sticky must miss gracefully)
   - FR-P11a circuit-breaker, with the **C2 cancel-vs-timeout attribution**
     rule (a buyer/gateway cancellation arriving with zero chunks received
     for streaming → provider-attributable; non-streaming buyer cancel before
     `inference_response_end` → buyer-attributable, NEVER charges the
     provider). Retry attempts MUST follow the same C2 rule per pillar.
4. Coordinator code you extend:
   - `phase4-coordinator/internal/buyer/server.go` — pin resolution path
     (≈977–1008), `selectProvider`/`selectProviderExcluding`, `hasPinnedRoute`
   - `phase4-coordinator/internal/pool/provider.go` — registry, RoutingEligible,
     the existing breaker/recovery-hold maps
   - `phase4-coordinator/internal/config/config.go` — RoutingConfig, defaults
   - `phase4-coordinator/internal/ws/server.go` — for the new admin/internal
     listener if you reuse it (or wire a new one — see Pillar A)
5. Gateway code you extend:
   - `phase5-gateway/internal/router/server.go` — handler registration; the
     existing `/v1/chat/completions` path; how upstream requests are built
   - `phase5-gateway/internal/config/config.go` — existing `coordinator_*`
     and timeout fields
   - existing `MACPROVIDER_KEY_HASH_SECRET` plumbing (verify it's a single
     source you can reuse for the sticky HMAC)
6. Observability: `phase4-coordinator/dist/monitor/macprovider-monitor.py` —
   so new alert-worthy events (e.g. `warmup_failed`, `breaker_tripped`,
   `sticky_purged_account`) appear via existing transitions, no new monitor
   needed.

## Critical constraints (carry over from spec; restate so you can self-check)
- **NO SPEC-001 / phase3-binary / wire change.** All work is server-side
  (coordinator + gateway). Provider binaries v1.2.4 in the live pool stay
  unchanged.
- **Additive at default.** With every new key at its spec default
  (`sticky_enabled: false`, `max_retries: 0`, `tiebreak_randomize: false`,
  empty `model_classes`), routing produces **identical provider selection
  and identical buyer-visible response/headers** vs SPEC-002 v1.3.3. The
  only allowed delta at default is the additive internal `routing_decision`
  log. Prove this with the default-config regression test (AC below).
- **Strip BEFORE authentication, not before forwarding.** The gateway's
  buyer-supplied `X-MacProvider-Internal-Conv` MUST be stripped before
  ANY auth/rate-limit/routing code reads request headers (SPEC-006 v0.8.1
  § 5.4.1 — this was the v0.8 → v0.8.1 audit MAJOR; do not re-introduce it).
  WARN-log an audit event on observed injection attempts.
- **Hard pin stays hard pin.** `X-MacProvider-Session` non-empty triggers
  FR-R3 (match `assigned_id`, else 503 `session_ended`, no failover, no
  sticky lookup). Sticky NEVER reads this header.
- **Sticky key never accepted as a buyer header at the coordinator.** The
  coordinator MUST refuse `X-MacProvider-Internal-Conv` from any
  externally-reachable path. Two-layer defense: nginx strip on the
  buyer-facing vhost AND a coordinator-side guard on the buyer port.
- **Cross-account `conv:` collision MUST be structurally impossible** (HMAC
  account_id-in-message, gateway-held secret per SPEC-006 § 1.3 steps 1–7).
- **C2 cancel attribution applies to retries too.** A buyer cancel during
  retry attempt N MUST NOT charge a breaker fault to provider N. Mirror
  FR-P11a's streaming/non-streaming rule per attempt.
- **No double-emit, no double-charge on retry.** Streaming post-first-byte
  is NOT retryable (same rule as F-4). Each retry attempt is a fresh relay
  charged independently per FR-P11a attribution.
- **Audit-reproducibility on randomized routes.** Every routing decision —
  especially randomized ε-tiebreak picks — MUST be reconstructible from
  logs: candidate set, metric values, ε, seed/draw, choice. FR-SR-17.
- **Clean-room d-inference.** Do NOT inspect layr-labs/d-inference source
  (NOASSERTION license). Design from this repo + public OpenAI/MLX docs
  only.
- **Do NOT touch the operator's local Mac (`augustass-macbook-air`).** It
  was removed from the launchd rotation by deliberate decision. Live
  inference tests use `air5` / `air8gb` (operator wakes on request).

## Recommended implementation order (one branch, structured commits)

Build the pillars in this order and land each as its OWN commit on a
single branch so the independent code-review pass can review per-pillar
diffs cleanly. After all four, land a final "composition + cross-cutting
tests" commit.

### Pillar D — randomized ε-tolerance tiebreak (smallest surface; fixes a real current bug)

**Why first:** SPEC-002 §5's deterministic `connected_at` tertiary tiebreak
hot-spots the first-connected provider on equal metrics — a measurable
current bug. D's surface is small (sort-cohort logic + a logged choice) and
de-risks the routing pipeline change you'll re-touch in B and C.

**Scope.**
- Add `routing.tiebreak_randomize` (default `false`), `routing.tiebreak_epsilon`
  (default `0.0`) to RoutingConfig.
- In `selectProviderExcluding`, after the preference sort, when
  `tiebreak_randomize: true`: identify candidates within `tiebreak_epsilon`
  (relative) of the top score on the active preference metric; pick one at
  random (seeded per-request).
- Emit a `routing_decision` structured log entry on every routed request:
  `request_id`, `candidate_set` (provider_id + metric value for each),
  `epsilon`, `seed`, `chosen_provider_id`, `reason` (one of
  `deterministic`/`randomized`/`sticky_hit`/`sticky_miss`/`class_resolved`/
  `retry_n` — extend as later pillars land).

**Acceptance.**
- Default (`tiebreak_randomize: false`) → identical selection to SPEC-002
  v1.3.3 on equal-metric provider sets (regression test).
- With `tiebreak_randomize: true` + 3+ equal-metric providers + ε=0.05 over
  many requests, load distributes (chi-square sanity at p≥0.05 over N≥50
  requests).
- Decision log allows replay: given the recorded candidate set + ε + seed,
  the chosen provider is deterministic.

### Pillar B — model-class aliases (visible API surface polish)

**Why second:** B adds the `routing.model_classes` config and lets buyers
ask for `mlx-fast`/`mlx-balanced`/`mlx-accurate`. It's API-visible (good
recruitment story) and orthogonal to C/A.

**Scope.**
- Config: `routing.model_classes: {<alias>: {members: [model_id,...], objective: fast|balanced|accurate}}`.
  Defaults: empty (no aliases active). Operator-tunable.
- Implement the `balanced` formula per SPEC-004 v0.2 FR-SR-8 exactly:
  `score(p) = 0.4·norm(tps) + 0.3·norm(params_b) + 0.2·norm(max_ctx) +
  0.1·norm(slots_free/slots_total)`, min-max normalized over the candidate
  set; zero-variance component → 1.0.
- In the routing pipeline, resolve class alias → set of eligible providers
  matching ANY of `members`; if exact model_id is requested, route as today
  (backward compat). If a class has zero eligible providers, return 503
  `no_provider_available` (existing shape).
- Extend `/v1/models` (gateway): list available classes alongside concrete
  ids per SPEC-006 v0.8.1 `/v1/models` extension. Each class entry includes
  the objective and member model_ids; do NOT obscure existing concrete-id
  entries.

**Acceptance.**
- Exact `model_id` requests behave exactly as SPEC-002 v1.3.3 (regression).
- A class with one eligible provider routes there; a class with multiple
  picks per its `objective` (fast = highest tps; accurate = largest
  params_b; balanced = the formula).
- An empty class returns 503 `no_provider_available` (same shape as
  exact-id misses today).
- `/v1/models` advertises both concrete ids AND classes; existing
  OpenAI-client SDKs reading by exact `id` still work.

### Pillar C — coordinator-managed retry

**Why third:** C adds a retry loop on top of the routing pipeline D+B refined.
Highest interaction risk with FR-P11a — get the C2 carve-out right.

**Scope.**
- Config: `routing.max_retries` (default `0` = current one-shot only),
  `routing.retry_per_attempt_timeout_s` (default `60`),
  `routing.max_providers_faulted_per_request` (default `min(2, max_retries)`).
- Buyer-visible header: `X-MacProvider-Retry: <bool>` opt-in. Default off.
  Cap effective `max_retries` to the spec's value regardless of header.
- Pipeline: on retryable failure, select a DIFFERENT provider (extend the
  failover excluded set per SPEC-004 §3 Step 9 + FR-SR-19 — F-4 and SPEC-004
  retry share one excluded set, but F-4 attempts do NOT consume the
  `max_retries` budget per FR-SR-14).
- **Retryable failures:** `provider_disconnected`, HTTP 502/504, breaker-
  degrade mid-attempt **before commit**. **Non-retryable:** buyer cancel,
  any 4xx response, post-commit streaming failures (same rule as F-4 §6).
- **Budget formula (FR-SR-15):** `remaining = request_timeout_s − elapsed`;
  skip retry N when `remaining < retry_per_attempt_timeout_s`.
- **C2 carve-out:** during a retry attempt, a buyer/gateway cancellation
  follows the SAME streaming/non-streaming attribution rule as FR-P11a —
  zero received chunks during streaming → provider; non-streaming cancel
  before `inference_response_end` → buyer, NEVER charges the provider.
- **Per-request breaker cap:** abort retries when `max_providers_faulted_per_request`
  is reached; return the buyer error.
- **`retried` column** (SPEC-002 reserved at line ~1113): populate with the
  number of explicit SPEC-004 retry attempts; F-4 failover does NOT
  increment it.

**Acceptance.**
- `max_retries: 0` (default) → behavior identical to SPEC-002 v1.3.3
  (regression).
- A retryable failure with `max_retries: 2` → at most 2 additional attempts
  on different providers; success commits cleanly.
- A buyer cancel during retry attempt N → NO breaker fault charged to that
  provider (test under both streaming and non-streaming).
- A post-first-byte streaming failure during retry → NOT retried (returns
  the SSE error per F-4).
- `retried` column reflects only explicit SPEC-004 attempts; F-4 failover
  doesn't bump it.

### Pillar A — sticky session affinity (largest surface; cross-component)

**Why last:** A touches coordinator + gateway + the nginx vhost + a new
coordinator-internal listener for purge. C2/breaker/warmup composition is
non-trivial. Best landed once D/B/C's routing pipeline is stable.

**Scope (coordinator).**
- Sticky map in `pool.Registry`: `map[conversation_key]stickyEntry{
  provider_id, account_id, model_scope, last_used_at}` with mutex; LRU
  eviction at `routing.sticky_max_entries` (default 10_000);
  `routing.sticky_ttl_s` (default 1800) for TTL expiry.
- Config: `routing.sticky_enabled` (default `false`), `routing.sticky_ttl_s`,
  `routing.sticky_max_entries`.
- Pipeline Step 4 (per SPEC-004 §3): when `sticky_enabled: true` AND the
  coordinator receives `X-MacProvider-Internal-Conv: conv:<id>` from the
  gateway (NOT from a buyer-reachable path; see two-layer defense below),
  look up sticky → if hit AND the provider is `RoutingEligible` AND within
  `tiebreak_epsilon` of the pref-sort objective → promote to position 0;
  else sticky miss + log `sticky_miss` reason; fall back to normal
  selection.
- Sticky write happens AFTER commit, to the FINAL committed provider (NOT
  any failed early retry attempt — FR-SR-6).
- Sticky entries invalidated on: provider permanently removed from pool;
  `routing.model_classes` reload changes a `model_scope`; explicit purge.
- **New coordinator-internal listener endpoint:** `DELETE /internal/sticky?account_id=<id>`
  on the coordinator's internal listener (NOT the public buyer port).
  Gated by network boundary (loopback-bind OR operator bearer auth — match
  the existing /poolz auth model). Iterates the sticky map and removes
  every entry for the given `account_id`. Returns `{purged: true, entries: N}`.
  Document the chosen auth in `phase4-coordinator/implementation-notes.html`.
- **Two-layer defense against buyer-supplied `X-MacProvider-Internal-Conv`:**
  the coordinator MUST refuse this header on any externally-reachable port.
  Wire a guard in the buyer-port handler.

**Scope (gateway).**
- `X-MacProvider-Conversation` parsing on `POST /v1/chat/completions`:
  - Sanitize per SPEC-006 v0.8.1: ASCII trim, length 1..128, charset
    `[A-Za-z0-9._:-]`, reject invalid with HTTP 400
    `invalid_conversation_tag`.
  - When `routing.sticky_enabled: false`: **silently ignore** (200 OK, no
    error, no derivation, no forward) — SPEC-006 v0.8.1 M1 fix; portable
    SDK compatibility.
  - When `sticky_enabled: true` AND tag valid AND account authenticated:
    derive `conv:<digest>` via SPEC-006 v0.8.1 § 1.3 steps 1–7 (HMAC-SHA256
    over scope || account_id || buyer_tag, gateway secret, unpadded
    base64url). Forward as `X-MacProvider-Internal-Conv: conv:<digest>` on
    the gateway→coordinator hop.
- **Strip BEFORE authentication** any buyer-supplied
  `X-MacProvider-Internal-Conv` or `X-MacProvider-Internal-*` headers in
  the public ingress path. Emit WARN audit event on observation. This
  MUST run before any auth/rate-limit/routing code reads request headers
  (SPEC-006 v0.8.1 § 5.4.1; do NOT re-introduce the v0.8 weakening).
- `DELETE /v1/sticky` handler: authenticated, account-scoped, idempotent.
  Calls the coordinator's `DELETE /internal/sticky?account_id=<id>` and
  returns `{purged: true, entries: N}`.
- `/v1/models tier1_disclosure.sticky_affinity` — render conditionally per
  SPEC-006 v0.8.1 § 5.3.1: when `sticky_enabled: true`, emit
  `{enabled: true, ttl_seconds: <from coordinator>, description: "..."}`.
  When `false`, OMIT the field entirely (clients see no field, not
  `enabled: false`, to match the "no new disclosure required at default"
  rule).

**Scope (nginx — for the operator's deploy runbook, not in this code build).**
The operator will update the nginx vhost on Pearl to strip
`X-MacProvider-Internal-*` on the public buyer-facing path. Document this
in `phase5-gateway/dist/nginx-api.malibu.tech.conf` with a normative
comment block; the code build's gateway strip is the primary defense,
nginx is defense-in-depth.

**Acceptance.**
- `sticky_enabled: false` (default) → no sticky map I/O, no
  `X-MacProvider-Internal-Conv` ever emitted, behavior identical to
  SPEC-002 v1.3.3 + Pillars D/B/C with defaults.
- `X-MacProvider-Session: <unknown-id>` → 503 `session_ended` regardless
  of `sticky_enabled` state (AC-SR-15 regression — proves hard pin is
  never sticky).
- Buyer-supplied `X-MacProvider-Internal-Conv` → stripped before auth,
  WARN audit event emitted, never reaches sticky lookup.
- HMAC-derived `conv:` for account A with tag `t1` ≠ HMAC-derived `conv:`
  for account B with same tag `t1` (cross-account collision impossible).
- Sticky hit with a degraded/breaker-held/warming provider → graceful miss
  (no trap on a dead box).
- Sticky write happens to the FINAL committed provider after retry, not
  any failed early attempt.
- `DELETE /v1/sticky` purges only the caller's account's entries; no
  cross-account purge possible.
- `tier1_disclosure.sticky_affinity` absent at default; present and
  correct when `sticky_enabled: true`.

## Cross-cutting tests (the FINAL commit)

After all four pillars land, this commit adds tests that verify the pillars
COMPOSE correctly (the highest audit-risk surface, per SPEC-004 §9):

- **Default-preservation regression** (FR-SR-1 + AC-SR-1): with EVERY
  SPEC-004 key at default, route N test requests against a mock pool and
  assert identical provider selection + identical buyer-visible response/
  headers vs a SPEC-002 v1.3.3 baseline harness. Include the FR-R3 pin
  path: `X-MacProvider-Session: <bad-id>` → 503 `session_ended`; sticky
  lookup Step 4 is a verified NO-OP.
- **C2 carve-out across retries** (FR-SR-12 + FR-P11a C2): for both
  streaming and non-streaming, prove a buyer cancel during retry attempt N
  does NOT charge a breaker fault to provider N.
- **Sticky-vs-breaker** (§9): a sticky hit on a breaker-held provider
  gracefully misses (no FR-P11a regression).
- **Sticky-vs-warmup** (§9): a sticky hit on a warming provider (FR-P8a)
  gracefully misses.
- **Sticky-vs-hard-pin** (AC-SR-15): hard pin precedence absolute; sticky
  never activates when `X-MacProvider-Session` is set.
- **Randomized tiebreak reproducibility** (FR-SR-17): replay a logged
  decision and re-derive the chosen provider from candidate set + ε +
  seed.
- **Retry idempotency**: post-commit streaming failure during retry → NOT
  retried (SSE error). Buyer cancel after first chunk → NOT a fault.
- **HMAC structural impossibility**: forge a tag in account A's namespace
  to attempt to hit account B's sticky entry; assert impossible.
- **All tests run under `-race`.** No new flakes.

## Hard rules
- Default-off for every new key. The build at install MUST produce
  byte-identical money-path behavior to v1.3.3 + the live coordinator.
- No SPEC-001 / phase3-binary / wire change.
- No spec text changes in this build. If you find spec text wrong,
  STOP and surface it; do NOT edit specs during code work.
- Strip headers BEFORE auth (do NOT weaken to "before forwarding" — the
  v0.8 audit MAJOR).
- Hard pin (`X-MacProvider-Session`) MUST stay hard pin.
- C2 attribution applies to retries.
- Audit-reproducibility on randomized decisions.
- Do NOT live-test against `augustass-macbook-air` (operator's local Mac
  is out of the pool).
- Clean-room d-inference (NOASSERTION).

## Output structure (single branch, structured commits)

Branch name: `phase7-p1-smart-router` (or similar). Commits in this order:

1. `coord+gw: SPEC-004 Pillar D — randomized epsilon tiebreak`
2. `coord+gw: SPEC-004 Pillar B — model-class aliases`
3. `coord+gw: SPEC-004 Pillar C — coordinator-managed retry`
4. `coord+gw: SPEC-004 Pillar A — sticky session affinity (gateway HMAC,
   coordinator sticky map, DELETE /v1/sticky, DELETE /internal/sticky)`
5. `coord+gw: SPEC-004 cross-cutting composition tests + default regression`
6. (optional) `docs: phase4-coordinator/implementation-notes.html — Pillar A
   coordinator-internal listener auth, sticky map invalidation rules,
   model_classes reload behavior`

Each commit MUST:
- Build clean (`go build ./...`) and pass tests for both modules.
- Run under `-race` on the touched packages.
- Include the tests for that pillar (not deferred to the final commit
  except for the cross-cutting/composition tests, which are by design
  consolidated in commit 5).
- Reference the spec section it implements in the commit body
  (FR-SR-N / AC-SR-N / SPEC-006 § ref).

## Self-verification checklist (before declaring the branch ready for review)
- [ ] All commits build clean + `go test ./...` green on both modules.
- [ ] `-race` clean on `internal/pool ./internal/ws ./internal/buyer
      ./internal/router`.
- [ ] Default-preservation regression actually PASSES against an unmodified
      SPEC-002 v1.3.3 baseline (mock provider harness).
- [ ] AC-SR-15 (`session_ended` regression) PASSES with sticky_enabled
      both true and false.
- [ ] C2 retry carve-out test PASSES for streaming AND non-streaming.
- [ ] Sticky composition tests (vs FR-P5/F-4/FR-P8a/FR-P11a) PASS.
- [ ] HMAC cross-account collision test PASSES (forge attempt fails).
- [ ] Randomized tiebreak replay test PASSES (deterministic from logs).
- [ ] No `X-MacProvider-Internal-Conv` accepted on coordinator buyer-facing
      port (two-layer defense verified).
- [ ] Gateway WARN audit event fires on observed internal-header injection.
- [ ] DELETE /v1/sticky purges only the caller's account; cross-account
      attempt rejected.
- [ ] No SPEC-001 / wire change introduced; provider binary v1.2.4
      compatibility verified by mock provider in tests.
- [ ] `tier1_disclosure.sticky_affinity` absent at default; present and
      correct when sticky_enabled: true.
- [ ] Implementation-notes.html updated for Pillar A coordinator-internal
      endpoint design + auth choice.

When done: report the branch name, the per-pillar commits, and a 1-paragraph
summary of any decisions that affect public behavior (e.g. exact
coordinator-internal endpoint shape, any audit findings from your own
verification). DO NOT push to main; the next step is an independent
multi-dimensional code-review pass before deploy.

=== END PROMPT ===
```

## After running this prompt

1. **Independent code-review pass.** Use a multi-dimensional audit (the
   pattern that's caught HIGH/CRITICAL/MAJOR on the last three rounds):
   - **Per-pillar correctness** (Codex's commits 1–4) — one critic pass per
     pillar against its FR-SR/AC-SR.
   - **Composition correctness** (commit 5) — verify FR-P5/F-4/FR-P8a/
     FR-P11a are NOT weakened; the C2 retry carve-out is correct; sticky
     never traps on a dead provider.
   - **Security pass on the Pillar A gateway side** — HMAC implementation
     matches SPEC-006 § 1.3 byte-for-byte; strip happens before
     authentication (NOT before forwarding); two-layer defense (gateway
     strip + coordinator buyer-port guard); DELETE /v1/sticky is
     account-scoped.
   - **Test adequacy** — every audit finding from the SPEC-004 v0.2 +
     SPEC-006 v0.8.1 audits has a regression test that would FAIL pre-fix.
2. **Resolve findings** in-session (per the discipline that's working) or
   route back to Codex if scope is bigger than a few lines.
3. **Staged deploy to Pearl** (Phase 7 P1 pattern):
   - Ship with ALL flags at default — Pillars D/B/C/A all OFF behavior.
     Verify money path unchanged on live providers.
   - Flip `tiebreak_randomize: true` first (D — smallest blast radius;
     fixes load-spread bug). Watch the monitor.
   - Define a real `routing.model_classes` config and verify
     `/v1/models` advertises them; route a test request via
     `model: mlx-fast` against `air5`. (B)
   - Enable `max_retries: 1` in a controlled window with `air5`/`air8gb`
     (C). Verify the breaker C2 carve-out holds on a real cancel.
   - Flip `sticky_enabled: true` last; route a multi-turn test through
     `air5` and verify the provider stays warm. (A)
4. **Log DECISION_CRITERIA Entry 33** with the live verification results.

## Priority note (operator)
This build delivers all four pillars. The visible API-surface wins are D
(load spread) and B (`mlx-fast`/`mlx-accurate` aliases) — those go on a
landing-page bullet list directly. C (retry) is a reliability/UX boost; A
(sticky) is the cache-reuse story that becomes valuable as buyers start
doing multi-turn conversations. Staged deploy lets you turn each one on
when the visibility matters, without betting the live pool.
