# Implementation BUILD prompt — SPEC-002 v1.3.5 Phase 2D (/v1/status SPEC-010 echo)

Operator-paste prompt for Codex GPT-5 to land the **fourth** of five
implementation sub-phases of SPEC-002 v1.3.5. This phase is the
smallest of the remaining four — pure gateway-side surface change to
echo SPEC-010 capability data buyer-side. Lives in
`phase5-gateway/` (NOT phase4-coordinator), because `/v1/status` is
served by the gateway in this deployment.

**Spec interpretation note (important — this is the operator's
binding decision):** SPEC-010 v1.5 R-3.3.3 + SPEC-002 v1.3.5 R-7.4.1
literally say "for a provider entry returned by /v1/status, MUST
include / OMIT". SPEC-006 v0.8.1 §5.6 (LOCKED) explicitly forbids
`/v1/status` from exposing provider IDs, hostnames, RAM, or operator
identity. The current gateway `/v1/status` shape is per-model
(`models[]`), with NO per-provider entries. To reconcile:

The operator's binding interpretation for Phase 2D is **per-model
union semantics**: extend `statusModel` with `supported_models
[]string` containing the deduplicated UNION of supported_models
across all providers currently serving that model whose
`PublishesSupportedModels == true`. When the union is empty (no
providers publish), the field is OMITTED entirely. This satisfies
the L-1 invariant (pre-SPEC-010 binaries / opted-out SPEC-010
binaries produce byte-identical `/v1/status` output) AND respects
SPEC-006's anonymization rule (no per-provider entries surface).

The interpretation MUST be reflected in code comments at the new
field declaration AND in the commit message.

**Scope: `/v1/status` model-level supported_models union echo.** No
new top-level field, no `providers[]` array, no provider_id leakage.
Coordinator already serializes the source data via Phase 2A's
`Provider.SupportedModels` + `Provider.PublishesSupportedModels` json
tags; this phase only extends the gateway's `/poolz` deserialization
and `aggregateStatus` builder.

**One-line summary.** In `phase5-gateway/internal/router/server.go`:
extend `poolzResponse.Pool[]` deserialization with the two new
SPEC-010 fields; extend `statusModel` with `SupportedModels []string
\`json:"supported_models,omitempty"\``; in `aggregateStatus`, build a
sorted+deduped union per model_id across providers whose
`PublishesSupportedModels == true`; assign the union to the model
entry only when non-empty (so omitempty drops the field for L-1).
Add 4 new tests pinning the L-1 invariant, single-provider publish,
multi-provider union, and per-provider opt-out gate.

**Locked-spec dependencies (DO NOT contradict).**
- SPEC-010 v1.5 §3.3 R-3.3.3 (the binding rule, reinterpreted per
  the operator decision above), R-3.3.1 + R-3.3.2 (source-of-truth
  population).
- SPEC-002 v1.3.5 §3.X.1 / §3.X.2 (Phase 2A data model — read-only
  here), §7.4 R-7.4.1 (this phase's mandate), §11 AC-K.1 + AC-K.2
  (acceptance criteria — re-anchored to model-level union per the
  operator interpretation).
- SPEC-006 v0.8.1 §5.6 (LOCKED — defines /v1/status shape; this
  phase preserves the existing shape + only adds the optional
  per-model field).
- SPEC-001 v1.3 §6.7.3 cell 1 (L-1 baseline).
- Coordinator commits `de41380` (Phase 2A struct) and `11bf449`
  (Phase 2B populator). Phase 2D consumes the JSON output of
  `/poolz` after both phases land; do NOT depend on field shape
  details from 2C (heartbeats).

This is a **code-only** session. No spec edits. Verify with
`git diff specs/` — must be empty.

Run in **Codex CLI** via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~35-50 min
(small surface, but in a new codebase — phase5-gateway — that Codex
hasn't touched in this branch).

Branch: `fix/spec-002-v1-3-5-coordinator` (tip `b76a608`). Despite
the branch name, this phase edits `phase5-gateway/` because that's
where `/v1/status` lives in production. Codex MUST NOT create a new
branch.

---

```
=== BEGIN PROMPT ===

You are implementing Phase 2D of SPEC-002 v1.3.5 in the Go gateway
at /Users/augstar/macprovider-poc/phase5-gateway/. The branch
`fix/spec-002-v1-3-5-coordinator` has already landed Phases 2A
through 2C R2V in the coordinator (`phase4-coordinator/`); their
JSON output on `/poolz` is the source data for this phase.

You will edit/create the following files (and ONLY these):

  phase5-gateway/internal/router/server.go      (extend)
  phase5-gateway/internal/router/server_test.go (extend)

You will NOT edit any file under `specs/`, `beta/`,
`phase3-binary/`, `phase4-coordinator/`, or any other file in
`phase5-gateway/`. Verify the edit set with:

  git diff --name-only HEAD \
    | grep -vE '^phase5-gateway/internal/router/server(_test)?\.go$' \
    | wc -l

The output MUST be `0`.

## Critical constraints

**1. L-1 byte-identical /v1/status default per SPEC-010 v1.5
R-3.3.3 + SPEC-001 v1.3 §6.7.3 cell 1.** When NO provider currently
serving a given model has `PublishesSupportedModels == true`, the
`supported_models` field MUST be ABSENT from that model's entry in
the `/v1/status` response — NOT emitted as `null` or `[]`. The L-1
case (pre-SPEC-010 binaries; SPEC-010 binaries that opted out) MUST
produce byte-identical `/v1/status` output to the v1.3.4 gateway.

**2. Spec interpretation (binding for this phase per operator
decision).** R-7.4.1's "for each provider entry" wording is
interpreted as PER-MODEL UNION semantics for the buyer-facing
`/v1/status`, because SPEC-006 v0.8.1 §5.6 forbids per-provider
identification on this endpoint. The supported_models field on a
`statusModel` row is the deduplicated UNION of supported_models
across all providers currently serving that model_id whose
`PublishesSupportedModels == true`. A code comment at the new field
declaration MUST cite this interpretation explicitly:

    // SPEC-002 v1.3.5 §7.4 R-7.4.1 / SPEC-010 v1.5 R-3.3.3 — per
    // SPEC-006 v0.8.1 §5.6 anonymization, the buyer-facing
    // /v1/status surfaces supported_models as a per-model UNION
    // across providers serving this model_id whose
    // PublishesSupportedModels == true (NOT per-provider entries,
    // which would leak provider count fingerprints). The field is
    // OMITTED when the union is empty.

**3. poolzResponse extension.** Extend `poolzResponse.Pool[]`
(the anonymous struct around server.go:1716) with exactly two new
fields placed AFTER `OperatorIdentity` and BEFORE the closing `}`:

    SupportedModels          []string `json:"supported_models,omitempty"`
    PublishesSupportedModels bool     `json:"publishes_supported_models,omitempty"`

Both `omitempty` to match the coordinator's serialization. The
deserializer accepts absent fields as zero values (nil slice; false
bool).

**4. statusModel extension.** Extend `statusModel` (around
server.go:1703) with exactly ONE new field placed AFTER
`Availability` and BEFORE the closing `}`:

    // SPEC-002 v1.3.5 §7.4 R-7.4.1 / SPEC-010 v1.5 R-3.3.3 — per
    // SPEC-006 v0.8.1 §5.6 anonymization, the buyer-facing
    // /v1/status surfaces supported_models as a per-model UNION
    // across providers serving this model_id whose
    // PublishesSupportedModels == true (NOT per-provider entries,
    // which would leak provider count fingerprints). The field is
    // OMITTED when the union is empty.
    SupportedModels []string `json:"supported_models,omitempty"`

**5. aggregateStatus union build.** Inside `aggregateStatus`
(server.go ~1803), extend the existing provider loop (around
server.go:1810-1848) to accumulate per-model supported_models
unions. Implementation guidance:

  a. Add a `supportedSets map[string]map[string]struct{}{}` local
     above the provider loop, keyed by model_id, holding the set of
     supported models contributed for that model_id.
  b. Inside the loop body, after `models[p.ModelID] = m`, gate on
     `p.PublishesSupportedModels && len(p.SupportedModels) > 0`. If
     true, ensure the inner set is initialized:
     `if supportedSets[p.ModelID] == nil { supportedSets[p.ModelID]
     = map[string]struct{}{} }`. Then `for _, s :=
     range p.SupportedModels { supportedSets[p.ModelID][s] =
     struct{}{} }`.
  c. After the loop ends (before the per-model degraded/availability
     fill at ~1860), iterate over models and assign the sorted union:

         for modelID, set := range supportedSets {
             if len(set) == 0 {
                 continue
             }
             m := models[modelID]
             m.SupportedModels = sortedKeys(set)
             models[modelID] = m
         }

  d. Implement `sortedKeys` as a small helper at the end of
     server.go (after computeAvailability):

         func sortedKeys(set map[string]struct{}) []string {
             keys := make([]string, 0, len(set))
             for k := range set {
                 keys = append(keys, k)
             }
             sort.Strings(keys)
             return keys
         }

     `sort` is already imported.

**6. Empty-union omission.** Per constraint 1, the field MUST be
absent when no providers publish for a given model. Two
defenses-in-depth ensure this:
  - The `if len(set) == 0 { continue }` guard skips assignment.
  - `json:"supported_models,omitempty"` drops nil/empty slices.
A single defense would suffice; both keep L-1 robust against a
future regression that initializes an empty slice.

**7. Sort order is lexical-ascending (`sort.Strings`).** The buyer
gets a stable order across requests; debug diffs stay readable.
Tests MUST assert the sorted order, not insertion order.

**8. Cache TTL preservation.** `statusFromPoolz` caches /poolz
results for 10 seconds (server.go:1760). Phase 2D MUST NOT change
this TTL. The cached `statusResponse` includes the new field; cache
behavior is unchanged.

**9. No new top-level fields on statusResponse.** Do NOT add a
`Providers []anything` array. Do NOT add a top-level
`supported_models`. The only new field is on `statusModel`.

**10. handleStatus is unchanged.** server.go:585 stays the same —
the handler just serializes `statusResponse`, which now has the new
field.

**11. `gofmt -l ./internal/...` and `go vet ./...` clean.**
`go test -count=1 ./...` MUST pass — both new tests + all existing
tests.

**12. No spec/handoff/DECISION_CRITERIA/BUILD/AUDIT prompt
edits.** Verify with `git diff specs/ beta/` — empty.

## Required reading (in this order)

1. `specs/SPEC-002-coordinator.md` lines 2438-2447 (§7.4.1 the
   binding rule).
2. `specs/SPEC-010-model-catalog.md` lines around R-3.3.3 (the
   parent rule).
3. `specs/SPEC-006-buyer-api.md` §5.6 (lines ~1197-1280) for the
   anonymization rule + current `/v1/status` shape contract.
4. `phase5-gateway/internal/router/server.go:1682-1736`
   (statusResponse, statusModel, poolzResponse — the targets).
5. `phase5-gateway/internal/router/server.go:1803-1902`
   (aggregateStatus + helpers).
6. `phase5-gateway/internal/router/server_test.go` — find existing
   tests using `TestStatus*` and `TestAggregateStatus*` patterns
   (around line 762+) for the test fixture style.
7. Phase 2A commit: `git show de41380 -- phase4-coordinator/internal/pool/provider.go`
   — confirm the `supported_models` / `publishes_supported_models`
   json tags on the Provider struct (these are what flow through
   /poolz).
8. Phase 2B commit: `git show 11bf449 -- phase4-coordinator/internal/ws/server.go`
   — confirm the populator at the v2 auth handler. Phase 2D consumes
   this output.

## Required tests (verbatim names — these are the AC oracles)

Place all tests in `phase5-gateway/internal/router/server_test.go`.
Use the existing `TestAggregateStatus*` pattern as the fixture
template.

  `TestAggregateStatusL1ByteIdenticalWhenNoProviderPublishes` —
    poolz response with 2 providers serving model-a, BOTH with
    PublishesSupportedModels=false (or absent). Assert the
    resulting statusResponse JSON output contains NO
    `supported_models` key anywhere when marshaled. Use
    `json.Marshal` + `bytes.Contains` (or unmarshal-to-map +
    walk) to prove field absence — NOT a snapshot test, since
    other fields can drift across spec versions.

  `TestAggregateStatusEchoesSupportedModelsWhenSingleProviderPublishes`
    — poolz response with 1 provider serving model-a with
    PublishesSupportedModels=true and SupportedModels=["model-a",
    "model-b"]. Assert the model-a entry has supported_models ==
    ["model-a", "model-b"] (sorted ASCII).

  `TestAggregateStatusUnionsSupportedModelsAcrossPublishingProviders`
    — poolz response with 2 providers serving model-a:
    - P1: PublishesSupportedModels=true, SupportedModels=["model-a",
      "model-b"]
    - P2: PublishesSupportedModels=true, SupportedModels=["model-a",
      "model-c"]
    Assert model-a entry has supported_models == ["model-a",
    "model-b", "model-c"] (sorted, no duplicates).

  `TestAggregateStatusExcludesNonPublishingProviderFromUnion` —
    poolz response with 2 providers serving model-a:
    - P1: PublishesSupportedModels=true, SupportedModels=["model-a",
      "model-b"]
    - P2: PublishesSupportedModels=false, SupportedModels=["model-a",
      "model-z"]  (operator opted-out — MUST NOT contribute to
                   the union even though the slice is populated)
    Assert model-a entry has supported_models == ["model-a",
    "model-b"] — model-z is NOT present.

Existing tests MUST continue to pass unchanged (the additions are
field-additive on statusModel; existing tests typically don't
assert field absence beyond what they already check).

## Done criteria

1. `cd phase5-gateway && go build ./...` exits 0.
2. `cd phase5-gateway && go vet ./...` exits 0 with no output.
3. `cd phase5-gateway && gofmt -l ./internal/...` produces empty
   output.
4. `cd phase5-gateway && go test -count=1 ./...` passes — 4 new
   tests + all existing tests.
5. `git diff --name-only HEAD` lists exactly the 2 files in the
   edit budget. Plus the unstaged `beta/DECISION_CRITERIA.md` and
   any untracked SPEC-002 spec/audit doc artifacts from prior
   phases — DO NOT stage any of these.
6. `git diff specs/ beta/ phase3-binary/ phase4-coordinator/` —
   empty.

## Out of scope (do NOT do in this phase)

- Adding a top-level `providers` array to `statusResponse`.
- Adding any field that exposes provider_id, hostname, or per-
  provider RAM/CPU.
- Adding rate limits / metrics / log lines for the union build.
- Touching `statusFromPoolz` or its cache logic.
- Editing the coordinator (`phase4-coordinator/`) at all.
- Creating an `internal/audit/` package (Phase 2E).
- Adding handling for the `loading: bool` field from Phase 2C
  heartbeats — that's not surfaced at the buyer API.

## Self-check before reporting done

Run, in order, from /Users/augstar/macprovider-poc/phase5-gateway:

    go build ./...
    go vet ./...
    gofmt -l ./internal/
    go test -count=1 -v -run TestAggregateStatus ./internal/router/... | tail -40
    go test -count=1 ./...
    cd /Users/augstar/macprovider-poc
    git diff --name-only HEAD
    git diff specs/ beta/ phase3-binary/ phase4-coordinator/

The last `git diff` MUST produce empty output. If any earlier
command fails, do NOT report done.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- Smallest phase by surface — ~50-80 net LOC including tests. R2
  risk is low.
- The spec-interpretation note is operator territory; once codex
  copy-pastes the code comment verbatim, the trade-off is
  documented in-tree.
- After 2D lands, dispatch the Phase 2D mid-stream Codex audit
  (smaller scope than 2C's; ~15-20 min) to confirm the L-1 byte-
  identical assertion holds and the union semantics are correct.
- After 2D audit clears, 2E (audit-log infrastructure + SQLite
  emitter) is the final implementation phase. Then the full pre-
  merge audit pattern from PR #5 runs against the squash candidate.

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7) for the SPEC-002 v1.3.5 Phase 2 implementation.
