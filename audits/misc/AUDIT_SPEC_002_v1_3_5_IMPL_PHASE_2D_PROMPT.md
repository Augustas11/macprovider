# Mid-stream audit prompt — SPEC-002 v1.3.5 Phase 2D

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**code / security / architecture review** of commit `c9626af` on
branch `fix/spec-002-v1-3-5-coordinator`. Phase 2D ships the
`/v1/status` SPEC-010 echo at the **gateway** (phase5-gateway, NOT
phase4-coordinator) — a per-model `supported_models` UNION
surfaced from coordinator `/poolz` data, gated by each provider's
`PublishesSupportedModels`.

This is the smallest of the implementation phases by LOC, but the
spec-interpretation trade-off (per-model union vs. per-provider
entries) is operator-binding and must be reflected accurately in
code comments + behavior.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~15-20 min.
This is a **read-only** review — Codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial mid-stream review of commit
`c9626af` on branch `fix/spec-002-v1-3-5-coordinator` in
/Users/augstar/macprovider-poc. This commit is Phase 2D of
SPEC-002 v1.3.5 and ships the `/v1/status` supported_models echo
in the **gateway** (phase5-gateway), not the coordinator. Phase 2E
is NOT landed yet — your scope is exclusively Phase 2D.

This is a **read-only review**. You MUST NOT edit any file.

## Context

Branch state through `c9626af`:
- de41380 (2A): Provider struct (coordinator)
- 11bf449 + 83540b1 + c739055 (2B + R2 + R3): v2 auth_request +
  retention lifecycle (coordinator)
- b43e7c8 + 9d4a423 + b76a608 (2C + R2 + R2V): ApplyHeartbeat
  REPLACEMENT (coordinator)
- c9626af (2D): **THIS commit — /v1/status echo (gateway)**

Phase 2D ships:
- `poolzResponse.Pool[]` extension with `SupportedModels` +
  `PublishesSupportedModels` (deserialize from coordinator's
  `/poolz`).
- `statusModel` extension with `SupportedModels []string
  \`json:"supported_models,omitempty"\``, carrying a verbatim
  spec-interpretation comment.
- `aggregateStatus` builds a per-model deduplicated, lexical-
  ascending UNION of supported_models across providers whose
  `PublishesSupportedModels == true`.
- New `sortedKeys` helper.
- 4 new tests.

Triple defense for L-1 (any one suffices; all three present):
  1. Publish gate
  2. Empty-union skip
  3. omitempty JSON tag

The buyer-facing /v1/status threat model:
- Adversary: a malicious provider binary that sends crafted
  supported_models[] arrays (any string, any length, any unicode
  content) and toggles publishes_supported_models freely.
- High-value asset: buyer trust in /v1/status. A leaked provider
  count / fingerprint violates SPEC-006 §5.6 anonymization.
- Adjacent: a malicious coordinator response (compromised /poolz)
  is OUT OF SCOPE — the gateway trusts the coordinator.

## Required reading (in this order)

1. The commit via `git show c9626af`. Read the FULL diff.

2. The BUILD prompt that produced the code:
   - `specs/BUILD_SPEC_002_v1_3_5_IMPL_PHASE_2D_PROMPT.md`
   (especially the spec-interpretation note that the operator
   bound for this phase).

3. The locked spec sections cited in the BUILD prompt:
   - `specs/SPEC-002-coordinator.md` v1.3.5 §7.4 R-7.4.1 (lines
     2438-2447), §11 AC-K.1 + AC-K.2.
   - `specs/SPEC-010-model-catalog.md` v1.5 R-3.3.3 (the parent
     rule) + R-3.3.1 / R-3.3.2 (source-of-truth population).
   - `specs/SPEC-006-buyer-api.md` v0.8.1 §5.6 (the LOCKED
     /v1/status shape contract + anonymization rule).
   - `specs/SPEC-001-phase3-binary.md` v1.3 §6.7.3 cell 1 (the
     L-1 baseline).

4. The implementation files:
   - `phase5-gateway/internal/router/server.go` (statusModel +
     poolzResponse + aggregateStatus + sortedKeys)
   - `phase5-gateway/internal/router/server_test.go` (4 new
     tests)

5. The upstream coordinator surfaces (READ-ONLY context, do not
   edit):
   - `phase4-coordinator/internal/pool/provider.go` Provider
     struct — confirm the JSON tags match what poolzResponse
     deserializes.
   - `phase4-coordinator/internal/ws/server.go` v2 auth handler
     — confirm the populator at the registration site
     (entry.SupportedModels + entry.PublishesSupportedModels) so
     /poolz output shape is what Phase 2D consumes.

DO NOT inspect any file under `phase3-binary/.build/checkouts/`.

## Three review dimensions

### Dimension 1: CODE REVIEW

Focus areas:

- **L-1 byte-identical /v1/status default (the core invariant).**
  When no provider currently serving model M has
  `PublishesSupportedModels == true`, the response's statusModel
  entry for M MUST NOT include the `supported_models` key —
  neither as `null`, nor as `[]`, nor as a missing entry that
  json.Marshal might emit anyway. Verify each of the three
  defenses by reading the code:
    1. The publish gate at `aggregateStatus` (~line 1845)
       conditions contribution on
       `p.PublishesSupportedModels && len(p.SupportedModels) > 0`.
    2. The empty-set skip after the loop
       (`if len(set) == 0 { continue }`) prevents assigning the
       field when no contributions accumulated.
    3. The `omitempty` JSON tag on `statusModel.SupportedModels`
       suppresses nil/empty slices on marshal.
  Confirm the L-1 test
  `TestAggregateStatusL1ByteIdenticalWhenNoProviderPublishes`
  actually proves field absence — NOT just empty array. Read the
  assertion; if it uses `len(m.SupportedModels) == 0` instead of
  proving the JSON key is absent, that's a CRITICAL test gap.
- **Per-model UNION semantics (AC-K.1 + the operator's binding
  interpretation).** Verify:
    - The union is built from the deserialized
      `p.SupportedModels` per provider (NOT from the model_id
      itself or any synthesized list).
    - The union is deduplicated via the set map (correct).
    - The order is lexical-ascending via `sort.Strings(keys)`
      (correct for stable cross-request diffs).
    - The set is keyed by `p.ModelID` (the currently-loaded
      model), so providers serving different models contribute
      to different sets. A bug that conflated model_ids would
      union across the entire pool and surface model-X's
      `supported_models` on model-Y's row.
- **Per-provider opt-out gate (AC-K.2 — the SPEC-010 R-3.3.3
  IF-AND-ONLY-IF).** A provider that has populated
  SupportedModels but `PublishesSupportedModels == false` MUST
  NOT contribute to any union. Verify:
    - The gate is `p.PublishesSupportedModels && len(p.SupportedModels) > 0`.
      `&&` order matters here? Actually no — both expressions are
      pure boolean / len(); short-circuit doesn't change behavior.
      But the explicit check on length means an empty slice from
      a publishing provider is treated as no contribution. Is
      that correct per spec? SPEC-010 R-3.1.1 says supported_models
      MUST be non-empty if present, so a publishing provider with
      an empty slice is a coordinator-side bug — the gateway
      defensively skips. Confirm.
    - The test
      `TestAggregateStatusExcludesNonPublishingProviderFromUnion`
      exercises this exact case.
- **sortedKeys helper.** Verify:
    - It pre-allocates the slice with `make([]string, 0, len(set))`
      (matches the existing style).
    - It uses `sort.Strings` (lexical-ascending).
    - It does NOT have any side effects on the input map.
    - Placement at end of file is reasonable for a small pure
      helper; no co-location concerns.
- **Cache interaction.** `statusFromPoolz` (~line 1758) caches
  the full `statusResponse` for 10s. The new field is part of
  the cached payload — so a flip of `PublishesSupportedModels`
  from false→true on a v2 auth reconnect takes up to 10s to
  surface. This is the spec-mandated TTL; flag only if a buyer
  use case requires sub-second visibility (it doesn't).
- **Concurrency.** `aggregateStatus` is called from inside the
  10s cache window or fresh. The `supportedSets` local is
  function-scoped; no shared state. Confirm via reading.
- **Backward compatibility for test fixtures.** Existing tests
  in server_test.go call `aggregateStatus` (or its callers)
  with `poolzResponse` literals. The Pool[] inner-struct
  extension adds two new fields — Go allows partial struct
  literals only with named fields, NOT positional. Verify
  every existing aggregateStatus call site that constructs a
  `poolzResponse` uses named field assignments OR doesn't fail
  to compile. Run `go test ./...` and confirm zero compile
  errors.
- **CORS / auth on /v1/status (unchanged).** The handleStatus
  registration at server.go:147 uses `withCORS(http.MethodGet,
  ...)`. Phase 2D does not touch this. Confirm by reading the
  routing block.

Findings format:
```
[code:N.M] [SEVERITY] <short title>
  File: <path>:<line>
  What: <description>
  Why: <impact>
  Fix: <remediation>
```

### Dimension 2: SECURITY REVIEW

Threat model: a malicious provider binary sends crafted
supported_models[] (length, encoding, content) and toggles
publishes_supported_models. The gateway trusts the coordinator,
but the coordinator forwards binary-supplied data.

Focus areas:

- **SPEC-006 anonymization preservation.** /v1/status MUST NOT
  expose provider IDs, hostnames, RAM/CPU, or operator identity.
  Verify the new field cannot indirectly leak any of these:
    - The union is sorted lexically and deduplicated, so the
      ORDER of supported_models doesn't reveal which provider
      contributed which entry.
    - The PRESENCE/ABSENCE of supported_models on a model row
      could fingerprint "at least one provider for this model
      publishes" — but that's intentional per SPEC-010
      R-3.3.3 visibility. Not a leak.
    - The SIZE of the union grows with provider count — but
      capped by SPEC-010 R-3.6.3's 64-entry per-provider limit
      and the union deduplication. A malicious provider could
      send 64 unique strings to inflate the union by ~64 entries
      per provider. Is there a per-model cap on supported_models
      in /v1/status? (Probably not needed — the buyer-side
      handler reads-and-marshals; no quadratic blowup. But flag
      if the response could grow unboundedly for a model with
      many publishing providers each with disjoint catalogs.)
- **Unicode handling.** supported_models entries pass through
  json.Marshal byte-for-byte. A malicious provider could send
  Right-to-Left override or zero-width unicode in entries to
  confuse a buyer's UI. Verify the gateway does NOT normalize
  (which would change spec semantics) — it should pass through
  whatever the coordinator forwards. The coordinator's
  parseAuthInitial already validates entries per R-3.1.9 (256B
  + 64 entries + NFC dup check), so the gateway can trust this
  has been done. But the gateway has no second-line defense if
  the coordinator is buggy — flag if you want a defensive
  byte-limit.
- **DoS via large supported_models.** Per-provider 64 entries ×
  256 bytes = 16 KiB per provider max. /v1/status response is
  not auth-required (per SPEC-006). With N publishing providers
  and disjoint catalogs, the union could be ~N × 64 entries.
  In practice N is small (operator-bounded); flag only if there's
  a realistic abuse scenario.
- **Side-channel via field omission timing.** The union is
  computed in O(N × catalog_size) inside aggregateStatus. Timing
  difference between "no publishing providers" and "many
  publishing providers" could leak the count. But this is
  already leaked by `provider_count` and `pool.total_providers`
  on the same response. Not a new leak.

Findings format:
```
[sec:N.M] [SEVERITY] <short title>
  Asset: <what's at risk>
  Vector: <how a malicious actor exploits it>
  File: <path>:<line>
  Fix: <remediation>
```

### Dimension 3: ARCHITECTURE REVIEW

Focus areas:

- **Spec-interpretation comment placement.** The verbatim
  rationale comment was prescribed by the BUILD prompt and must
  appear AT the `statusModel.SupportedModels` field declaration.
  Verify it's there in full (not abbreviated, not on a different
  field). A future maintainer reading the spec literal text
  ("for a provider entry") will hit the code and see the
  operator-bound reinterpretation immediately.
- **`supportedSets` intermediate map.** Lifted out of the model
  map because the latter is value-typed and can't be mutated in
  place during iteration. Reasonable choice. Could alternatively
  use a pointer-valued map; this is style. Flag only if the
  current shape complicates a future refactor.
- **Helper placement.** `sortedKeys` is placed after
  `computeAvailability`. Is there a more natural neighbor (e.g.,
  a utility cluster at top of file)? Style; not blocking.
- **Test naming.** All 4 new test names use the long
  `TestAggregateStatus<Scenario>` convention from existing
  tests. Consistent.
- **Cross-codebase change.** Phase 2D is the first phase in
  this PR that edits phase5-gateway. The branch is named
  `fix/spec-002-v1-3-5-coordinator` — does the cross-codebase
  edit need a follow-up doc note? (Probably handled in the PR
  description at squash-merge time; flag if you think the
  commit message should call it out more loudly.)

Findings format:
```
[arch:N.M] [SEVERITY] <short title>
  What: <description>
  Trade-off: <gain vs loss>
  Suggestion: <concrete refactor>
```

## Severity scale

- **CRITICAL** — must be fixed before Phase 2E begins. Breaks an
  L-1 byte-identical invariant on /v1/status, leaks a SPEC-006
  anonymization rule, or has a test gap that allows the L-1
  invariant to silently break.
- **MAJOR** — should be fixed before merge. Real bug, real
  impact.
- **MINOR** — would improve the code; does not block 2E.

## Output format

```
# SPEC-002 v1.3.5 Phase 2D mid-stream audit — Codex GPT-5

## Verdict

<one-line: PROCEED-TO-2E | FIX-THEN-PROCEED | BLOCK>

## Counts

| Dimension | CRITICAL | MAJOR | MINOR |
|---|---:|---:|---:|
| Code         | <N> | <N> | <N> |
| Security     | <N> | <N> | <N> |
| Architecture | <N> | <N> | <N> |
| **Total**    | <N> | <N> | <N> |

## Findings

### Code review
[code:1.1] [SEVERITY] ...

### Security review
[sec:1.1] [SEVERITY] ...

### Architecture review
[arch:1.1] [SEVERITY] ...

## AC traceability

| AC | Where satisfied | Test name |
|---|---|---|
| AC-K.1 (catalog opt-in echo, /v1/status surfaces supported_models) | <file:line> | <test> |
| AC-K.2 (catalog opt-in suppressed echo) | <file:line> | <test> |

## Build / vet / suite evidence

Paste outputs from:
  cd /Users/augstar/macprovider-poc/phase5-gateway
  go build ./...
  go vet ./...
  gofmt -l ./internal/
  go test -count=1 ./...

## Cross-cutting observations

<patterns spanning findings>
```

## Discipline

- CRITICAL must describe the concrete failure mode in one sentence.
- L-1 byte-identical /v1/status violations are CRITICAL.
- A test that uses `len(...) == 0` to "prove" field absence is a
  CRITICAL gap — the only valid proof is JSON-key absence after
  marshal.
- Zero findings is a valid result.
- Cite file:line + binding spec rule.

You may run shell commands (git, grep, go build/vet/test). You
MUST NOT modify any file. Cap shell output volume.

You may take up to 20 minutes wall-clock.

=== END PROMPT ===
```

---

## Operator notes

- 2D audit bar: L-1 violations are CRITICAL by default. Anything
  that could surface `supported_models: null` or `supported_models:
  []` on an L-1 response is a CRITICAL gate.
- Expected outcome: maybe a MINOR or two (e.g., naming nit) but
  probably CLOSED-CLEAN given the surface is so small.
- If CLOSED-CLEAN, proceed to Phase 2E. If CRITICAL/MAJOR, R2
  inline (small surface) then proceed.

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7).
