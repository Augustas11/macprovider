# Implementation BUILD prompt — SPEC-002 v1.3.5 Phase 2A (Provider struct extension)

Operator-paste prompt for Codex GPT-5 to land the **first** of five
implementation sub-phases of SPEC-002 v1.3.5 in `phase4-coordinator/`.
This phase is purely additive, defaults preserve byte-identical
wire/JSON behavior, and unblocks Phases 2B-2E (which build on the new
struct fields).

**Scope: `Provider` data-model extension only.** No `auth_request`
parser changes, no `ApplyHeartbeat` REPLACEMENT, no `/v1/status` echo
logic, no audit-log package. Those are 2B / 2C / 2D / 2E.

**One-line summary.** Add four new fields to
`phase4-coordinator/internal/pool/provider.go` `Provider` struct —
`SupportedModels []string`, `PublishesSupportedModels bool`,
`LastLoadingState bool`, `LoadingStartedAt time.Time` — with JSON tags
chosen so that a default-initialized `Provider` (the L-1 baseline,
exactly the state a pre-SPEC-010 / pre-SPEC-011 binary produces today)
serializes byte-identically to v1.3.4. Add tests in
`phase4-coordinator/internal/pool/provider_test.go` (extend if exists,
new file otherwise) and `phase4-coordinator/internal/ws/server_test.go`
that pin (a) zero-value JSON output for `pool.Provider`, (b) `/poolz`
response shape for a registered legacy provider is unchanged. No other
production code is modified.

**Locked-spec dependencies (DO NOT contradict).**
- SPEC-002 v1.3.5 (LOCKED in PR #4 commit `b4d87b5`) — read §3
  "Provider data model (v1.3.5 SPEC-010 extension)" R-3.X.1 through
  R-3.X.6, and §11 AC-K.* matrix for the ACs that constrain this
  phase.
- SPEC-001 v1.3 §6.7.3 cell 1 — the L-1 byte-identical default that
  this phase MUST preserve on the coordinator JSON output side.
- SPEC-010 v1.5 §4.1 — observable-indistinguishability lemma the
  L-1 defaults flow from.
- SPEC-011 v0.5 §3.3 R-3.3.5 + §3.6 R-3.6.3 — source of the
  `LastLoadingState` sticky + `LoadingStartedAt` requirements.

This is a **code-only** session. No spec edits. Verify with
`git diff specs/` after edits — must be empty.

Run in **Codex CLI** via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~30-45 min
(1 production file modified, 1-2 test files extended/new).

Branch: `fix/spec-002-v1-3-5-coordinator` (already checked out by
operator). Codex MUST NOT create a new branch.

---

```
=== BEGIN PROMPT ===

You are implementing Phase 2A of SPEC-002 v1.3.5 in the Go coordinator
at /Users/augstar/macprovider-poc/phase4-coordinator/. SPEC-002 v1.3.5
is LOCKED (merged to main in PR #4 commit b4d87b5). SPEC-010 v1.5 and
SPEC-011 v0.5 are LOCKED. PR #5 (SPEC-001 v1.3 binary) merged to main
in commit 5d4f69d; the binary now emits the wire fields this phase
will eventually consume — but THIS phase only extends the struct, with
no parser, dispatch, or output changes.

You will edit/create the following files (and ONLY these):

  phase4-coordinator/internal/pool/provider.go        (extend)
  phase4-coordinator/internal/pool/provider_test.go   (extend or NEW)
  phase4-coordinator/internal/ws/server_test.go       (extend — add ONE
                                                       /poolz shape test)

You will NOT edit any file under specs/, phase3-binary/,
phase5-gateway/, or any other Go file in phase4-coordinator/. Verify
with:

  git diff --name-only origin/main \
    | grep -vE '^(phase4-coordinator/internal/pool/provider(_test)?\.go|phase4-coordinator/internal/ws/server_test\.go)$' \
    | wc -l

The output MUST be `0`.

## Critical constraints

**1. L-1 byte-identical JSON default per SPEC-001 v1.3 §6.7.3 cell 1 +
SPEC-010 v1.5 §4.1.** A `pool.Provider` instance with all four new
fields at their zero values (`SupportedModels == nil`,
`PublishesSupportedModels == false`, `LastLoadingState == false`,
`LoadingStartedAt == time.Time{}`) MUST serialize via `encoding/json`
to a JSON object that is BYTE-IDENTICAL to the same instance
serialized before this phase. This means every new field MUST be tagged
in a way that omits the zero value entirely from the output (NOT
`null`, NOT `[]`, NOT `false`, NOT the RFC3339 zero string). Tests
MUST prove this by `bytes.Equal`-comparing a snapshot of the pre-phase
serialization (paste it as a constant in the test) against the
post-phase serialization. This invariant is binding for all four new
fields without exception.

**2. The four new fields are the SPEC-002 v1.3.5 §3.X
data-model extension.** Add them, with these exact names, types, JSON
tags, and ordering (place them as a contiguous block immediately
AFTER the existing `AttestationStatus` field and BEFORE the
`Tier2Session` field — preserving the existing field order above and
below):

    SupportedModels          []string  `json:"supported_models,omitempty"`
    PublishesSupportedModels bool      `json:"publishes_supported_models,omitempty"`
    LastLoadingState         bool      `json:"-"`
    LoadingStartedAt         time.Time `json:"-"`

Field-by-field rationale (DO NOT skip — these tags are normative for
this phase):

- `SupportedModels`: SPEC-002 v1.3.5 R-3.X.1. Wire-facing field; uses
  snake_case JSON name to match the SPEC-010 v1.5 §3.1.A field name.
  `omitempty` for L-1 (a nil slice is absent from JSON output; future
  phases populate it with `[ModelID]` or the catalog).
- `PublishesSupportedModels`: SPEC-002 v1.3.5 R-3.X.2. Wire-facing.
  `omitempty` ensures `false` is absent — non-negotiable for L-1 per
  SPEC-010 v1.5 AC-21 and SPEC-001 v1.3 AC-18.0.
- `LastLoadingState`: SPEC-002 v1.3.5 R-3.X.4. Internal-only sticky
  gate for the §7.1 R-7.1.6 / §7.10 R-7.10.8 exactly-once emission
  contract. NEVER serialized; tag `json:"-"`.
- `LoadingStartedAt`: SPEC-002 v1.3.5 R-7.10.6. Internal-only;
  records the coordinator clock at the first observed
  `loading: true` transition for `loading_window_ms` computation at
  swap completion. NEVER serialized; tag `json:"-"`.

The HashStatus enum and `ModelHash` field already exist and ARE NOT
changed by this phase.

**3. Insertion point is exactly between the existing
`AttestationStatus` and `Tier2Session` fields.** Do not reorder any
existing field. Do not introduce a struct rename, an embedded helper
type, or a tag change on any existing field. The Provider struct
boundary in the diff should be one contiguous addition of four lines,
nothing else.

**4. No constructor / no defaulting.** Do not write a `NewProvider`
factory and do not initialize the four fields anywhere — they must
remain at their Go zero value unless and until a later phase sets
them. The `Registry.Register` path at
`phase4-coordinator/internal/pool/provider.go:154` MUST NOT be edited.
This phase introduces type surface only.

**5. No new methods on Provider.** Do not add helpers like
`IsLoading()`, `HasCatalog()`, `MarkLoading()`, etc. Those belong to
later phases that actually USE the fields. Keeping 2A surface-only
makes the 2B / 2C diffs reviewable.

**6. No changes to Registry struct, ApplyHeartbeat, Touch, Register,
SetTier, UpdateHashStatuses, or any other function in provider.go.**
The §7.1 ApplyHeartbeat REPLACEMENT is Phase 2C. The §7.9
`AuthAttemptRetention` plumbing is Phase 2B. Stay out of those
surfaces.

**7. Pure additive on the `pool` package public API.** No existing
exported symbol may be renamed, removed, or change signature. No
existing test may need to change (existing assertions MUST continue
to pass as-is). If an existing assertion appears to need editing,
STOP and report — that signals a non-additive change.

**8. The `time` import is already present at provider.go:8.** Do not
re-import. Do not add new imports.

**9. Per-package gofmt + go vet MUST pass cleanly.** Run:

    cd phase4-coordinator
    gofmt -l internal/pool/provider.go internal/pool/provider_test.go \
              internal/ws/server_test.go
    go vet ./internal/pool/... ./internal/ws/...

  Both MUST produce zero output / exit 0.

**10. No spec edits, no handoff-doc edits, no DECISION_CRITERIA
edits.** This phase touches only the three files listed above. Verify
with `git diff specs/ beta/` — empty.

## Required reading (in this order)

1. `specs/SPEC-002-coordinator.md` §3 "Provider data model (v1.3.5
   SPEC-010 extension)" — lines 305-378. R-3.X.1 through R-3.X.6 are
   the binding requirements for this phase.
2. `specs/SPEC-002-coordinator.md` §7.10.2 R-7.10.6 — the
   `loading_window_ms` computation that motivates `LoadingStartedAt`.
3. `specs/SPEC-001-binary.md` §6.7.3 cell 1 — the L-1 baseline you
   are preserving on the coordinator side.
4. `phase4-coordinator/internal/pool/provider.go:1-110` — current
   Provider struct shape and constants.
5. `phase4-coordinator/internal/ws/server.go:1453-1510` — the
   `/poolz` handler that serializes `pool.Provider`. (Read for
   context; do NOT edit.)

## Required edits — exact shape

### Edit 1: provider.go struct extension

In `phase4-coordinator/internal/pool/provider.go`, find this region:

    // AttestationStatus is informational unless tier2.require_attestation is
    // enabled. The zero value represents a legacy provider with no claim.
    AttestationStatus AttestationStatus `json:"attestation_status,omitempty"`

    Tier2Session *Tier2Session `json:"-"`

Insert the four new fields BETWEEN `AttestationStatus` and the blank
line that precedes `Tier2Session`. The post-edit shape MUST be:

    // AttestationStatus is informational unless tier2.require_attestation is
    // enabled. The zero value represents a legacy provider with no claim.
    AttestationStatus AttestationStatus `json:"attestation_status,omitempty"`

    // SPEC-002 v1.3.5 §3.X.1 — populated from v2 auth_request initial-stage
    // supported_models[] per SPEC-010 v1.5 R-3.3.1; nil for the L-1 baseline.
    SupportedModels []string `json:"supported_models,omitempty"`
    // SPEC-002 v1.3.5 §3.X.2 — populated from publishes_supported_models per
    // SPEC-010 v1.5 R-3.3.2; gates /v1/status echo per §7.4 R-7.4.1.
    PublishesSupportedModels bool `json:"publishes_supported_models,omitempty"`
    // SPEC-002 v1.3.5 §3.X.4 — sticky last-heartbeat loading flag for the
    // §7.1 R-7.1.6 / §7.10 R-7.10.8 exactly-once operator_model_swap gate.
    LastLoadingState bool `json:"-"`
    // SPEC-002 v1.3.5 §7.10.2 R-7.10.6 — coordinator clock at the first
    // observed loading:true heartbeat; loading_window_ms is computed at
    // swap-completion emission.
    LoadingStartedAt time.Time `json:"-"`

    Tier2Session *Tier2Session `json:"-"`

### Edit 2: provider_test.go — zero-value JSON invariant

Create or extend `phase4-coordinator/internal/pool/provider_test.go`
with a test that snapshots a representative non-zero `pool.Provider`
(matching what a v1.3.4 coordinator would have produced for a legacy
v1.2.4 binary), serializes it, and asserts the byte output equals a
hard-coded JSON snapshot — pinning that the new fields contribute
ZERO bytes when at zero.

The test name MUST be `TestProviderJSONL1ByteIdenticalDefault`.

Construct the Provider with this exact field set (every other field
left at zero; pick representative non-zero values for fields that
matter to /poolz observability):

    p := Provider{
        ProviderID:            "test-provider-1",
        AssignedID:            "p_01H000000000000000000000",
        Hostname:              "test-host",
        ModelID:               "mlx-community/Qwen2.5-7B-Instruct-4bit",
        ModelParamsB:          7.6,
        RAMGB:                 16,
        MaxContextTokens:      8192,
        MaxConcurrency:        1,
        SlotsFree:             1,
        SlotsTotal:            1,
        ThroughputTPSEstimate: 42.5,
        EndpointURL:           "",
        Tier:                  TierPinned,
        InferencePath:         InferencePathWSTunneled,
        AdmittedAt:            time.Date(2026, 6, 7, 12, 0, 0, 0, time.UTC),
        State:                 StateReady,
        LastHeartbeatAt:       time.Date(2026, 6, 7, 12, 5, 0, 0, time.UTC),
        LastActivityAt:        time.Date(2026, 6, 7, 12, 5, 0, 0, time.UTC),
        ConnectedAt:           time.Date(2026, 6, 7, 12, 0, 0, 0, time.UTC),
        BinaryVersion:         "1.2.4",
    }

Compute the expected JSON ONCE by running `go test` once to fail and
capturing the actual output, then paste it into the test as a constant
`const expected = \`{...}\``. The test then asserts
`bytes.Equal(got, []byte(expected))`. Document the snapshot regeneration
procedure in a comment ABOVE the constant: "// Regenerate by running
the test, copying the `got` value from the failure diff, and pasting
here. Any diff against this constant for a default-zero new-field set
is an L-1 regression per SPEC-001 v1.3 §6.7.3 cell 1."

Add a SECOND assertion in the same test, AFTER the byte-equal check:
parse `got` with `json.Unmarshal` into a `map[string]any` and verify
NONE of the keys `supported_models`, `publishes_supported_models`,
`last_loading_state`, `loading_started_at`, `LastLoadingState`,
`LoadingStartedAt` are present. This is belt-and-suspenders on the
omitempty + `json:"-"` tag choices.

### Edit 3: provider_test.go — non-zero serialization sanity

In the same file, add `TestProviderJSONSerializesNewFieldsWhenSet`
that constructs a Provider with the SAME baseline above PLUS:

    p.SupportedModels = []string{"mlx-community/Qwen2.5-7B-Instruct-4bit"}
    p.PublishesSupportedModels = true
    p.LastLoadingState = true
    p.LoadingStartedAt = time.Date(2026, 6, 7, 12, 4, 30, 0, time.UTC)

Serializes via `json.Marshal`, parses result, then asserts:

  - `supported_models` is a JSON array with one string element equal
    to `"mlx-community/Qwen2.5-7B-Instruct-4bit"`.
  - `publishes_supported_models` is `true`.
  - `last_loading_state` and `loading_started_at` (any case) are
    ABSENT — they must not leak via `json:"-"` regardless of value.

### Edit 4: server_test.go — /poolz shape regression

In `phase4-coordinator/internal/ws/server_test.go`, find any existing
test that exercises `/poolz` with a registered provider (the file
already has several — e.g. around line 1180). Add a new sibling test
`TestPoolzShapeUnchangedForL1Provider`. Register a provider via the
existing test harness pattern with NO new field set, fetch `/poolz`,
parse JSON, walk to the first provider entry, and assert that NONE of
the four new top-level keys (`supported_models`,
`publishes_supported_models`, `last_loading_state`,
`loading_started_at`) appear on that provider entry.

This test mirrors the existing
`default /poolz included Tier-2 hash fields` assertion pattern at
server_test.go:842 — copy the JSON-walk structure from there.

## Done criteria

1. `cd phase4-coordinator && go build ./...` exits 0.
2. `cd phase4-coordinator && go test ./internal/pool/... ./internal/ws/...`
   exits 0 with the three new tests passing and ALL existing tests
   still passing.
3. `cd phase4-coordinator && gofmt -l ./internal/...` produces empty
   output.
4. `cd phase4-coordinator && go vet ./...` exits 0 with no output.
5. `git diff --name-only origin/main` lists exactly:
   - `phase4-coordinator/internal/pool/provider.go`
   - `phase4-coordinator/internal/pool/provider_test.go`
   - `phase4-coordinator/internal/ws/server_test.go`
   (and may also include the unstaged `beta/DECISION_CRITERIA.md` +
   the new `specs/HANDOFF_SPEC_002_v1_3_5_IMPLEMENTATION.md` + this
   prompt file — those are operator-territory and MUST NOT be staged
   or edited by you.)
6. `git diff specs/` (post-edit) shows ONLY the new BUILD prompt and
   handoff doc as untracked / unchanged-modified — Codex has touched
   nothing under `specs/`.

## Out of scope (do NOT do in this phase)

- Adding `AuthAttemptState` struct type or `AuthAttemptRetention`
  map (Phase 2B).
- Parsing `supported_models` or `publishes_supported_models` from
  `AuthRequest` (Phase 2B).
- Editing `ApplyHeartbeat` (Phase 2C — this is the riskiest phase
  and gets its own prompt).
- Editing `/v1/status` (Phase 2D).
- Creating `internal/audit/` package (Phase 2E).
- Touching the v2 `auth_request` parser, the WS server lifecycle,
  the heartbeat path, or any handler.
- Renaming or refactoring existing Provider fields.
- Adding helper methods on Provider.

## Self-check before reporting done

Run, in order, from the repo root, and paste each output back to the
operator in your completion summary:

    cd phase4-coordinator && go build ./...
    cd phase4-coordinator && go vet ./...
    cd phase4-coordinator && gofmt -l ./internal/pool/ ./internal/ws/
    cd phase4-coordinator && go test ./internal/pool/... -run TestProviderJSON -v
    cd phase4-coordinator && go test ./internal/pool/...
    cd phase4-coordinator && go test ./internal/ws/... -run TestPoolzShape -v
    cd phase4-coordinator && go test ./internal/ws/...
    git diff --name-only origin/main
    git diff specs/ beta/ phase3-binary/ phase5-gateway/

The last command MUST produce empty output. If any of the others
fail, do NOT report done — diagnose and fix within the four-file
budget, or report blocked.

=== END PROMPT ===
```

---

## Operator notes (not part of the prompt)

- This phase is the smallest of the five. Sized to land in one Codex
  pass with high confidence. Audit pass for me (Claude): verify the
  four field tags exactly, confirm the L-1 snapshot test actually
  byte-equals (not just unmarshal-equals), confirm gofmt + vet are
  green, confirm `git diff specs/` is empty.
- The R2 risk for 2A is low. If anything, watch for Codex over-zealously
  adding a `NewProviderFromAuthRequest` factory or initializing the
  new fields in `Register`. Those belong to 2B.
- After 2A merges into the branch, the prompt for 2B can cite the new
  field names by exact symbol — that's the methodology compounding
  payoff the handoff predicts.

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7) for the SPEC-002 v1.3.5 Phase 2 implementation.
