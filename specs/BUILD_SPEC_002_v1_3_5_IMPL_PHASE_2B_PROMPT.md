# Implementation BUILD prompt — SPEC-002 v1.3.5 Phase 2B (v2 auth_request SPEC-010 + retention lifecycle)

Operator-paste prompt for Codex GPT-5 to land the **second** of five
implementation sub-phases of SPEC-002 v1.3.5 in `phase4-coordinator/`.
2B consumes Phase 2A's struct extension (commit `de41380`) and wires
SPEC-010 v1.5 §3.1.A / §3.1.C field parsing on the v2 `auth_request`
handshake, the §7.9 `AuthAttemptRetention` lifecycle with 1024-bound
defensive rejection and defer-based release, and the populator that
moves the parsed values onto the `Provider` entry that Phase 2A added
fields for.

**Scope: v2 `auth_request` SPEC-010 fields + auth-attempt retention.**
No `ApplyHeartbeat` REPLACEMENT, no `/v1/status` echo logic, no
audit-log package. Those are 2C / 2D / 2E.

**One-line summary.** Extend `AuthRequest` with `SupportedModels
[]string` + `PublishesSupportedModels bool`; teach `parseAuthInitial`
to validate them in SPEC-010 R-3.1.9 order with verbatim AC-K.15
substrings; teach `parseAuthProof` to accept-and-cross-stage-compare
the same fields after NFC + ASCII case-fold; introduce
`AuthAttemptState` + a coordinator-scoped retention store keyed by
`authAttemptID`, with R-7.9.6 1024-bound rejection (`too_many_auth_attempts`
+ close 4429), R-7.9.7 defer-based release installed between retention
creation and `auth_challenge` emission, and R-7.9.8 L-1 baseline gate
(no retention entry, no defer, no metric when neither SPEC-010 field
is present on the initial stage); on proof-stage acceptance populate
the Phase 2A `Provider.SupportedModels` (single-entry `[ModelID]`
fallback when SPEC-010 fields absent, per R-3.X.1) and
`Provider.PublishesSupportedModels`.

**Locked-spec dependencies (DO NOT contradict).**
- SPEC-002 v1.3.5 §3.X.1 / §3.X.2 / §3.X.5, §7.8.1 / §7.8.2 / §7.8.3,
  §7.9.1 / §7.9.2 / §7.9.3, AC-K.3 / AC-K.4 / AC-K.5 / AC-K.15 /
  AC-K.16 (LOCKED, PR #4 b4d87b5).
- SPEC-010 v1.5 §3.1.A field set, §3.1.C proof-stage field set,
  R-3.1.7 NFC + ASCII case-fold comparison rule, R-3.1.9 validation
  order, R-3.1.10 retention/comparison clauses 1-5, R-3.3.1 / R-3.3.2
  Provider population rules, AC-17 / AC-22 / AC-23 reason-text
  substrings.
- SPEC-001 v1.3 §6.7.3 cell 1 L-1 baseline (a v1.3 binary's
  single-entry catalog frame must be observably indistinguishable
  from a pre-SPEC-010 binary).
- Phase 2A commit `de41380` is the floor for this work — the four
  Provider fields it added are populated by THIS phase; the
  ApplyHeartbeat REPLACEMENT remains untouched.

This is a **code-only** session. No spec edits. Verify with
`git diff specs/` after edits — must be empty.

Run in **Codex CLI** via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~75-120 min
(parser + state + lifecycle + tests across 2 production files + 1 new
file + 2 test files; small dependency add).

Branch: `fix/spec-002-v1-3-5-coordinator` (Phase 2A commit `de41380`
is the tip; Codex MUST NOT create a new branch and MUST NOT touch any
already-landed Phase 2A file beyond the four-field Provider struct
edits already merged).

---

```
=== BEGIN PROMPT ===

You are implementing Phase 2B of SPEC-002 v1.3.5 in the Go coordinator
at /Users/augstar/macprovider-poc/phase4-coordinator/. SPEC-002 v1.3.5
is LOCKED (merged to main in PR #4 commit b4d87b5). Phase 2A landed on
this branch as commit de41380 — its four new Provider fields
(`SupportedModels`, `PublishesSupportedModels`, `LastLoadingState`,
`LoadingStartedAt`) are the consumers for this phase's populator
hooks.

You will edit/create the following files (and ONLY these):

  phase4-coordinator/internal/ws/messages.go          (extend)
  phase4-coordinator/internal/ws/messages_test.go     (extend)
  phase4-coordinator/internal/ws/auth_attempts.go     (NEW)
  phase4-coordinator/internal/ws/auth_attempts_test.go (NEW)
  phase4-coordinator/internal/ws/server.go            (extend)
  phase4-coordinator/internal/ws/server_test.go       (extend)
  phase4-coordinator/go.mod                           (extend — add x/text)
  phase4-coordinator/go.sum                           (auto-update on mod tidy)

You will NOT edit any file under specs/, beta/, phase3-binary/,
phase5-gateway/, the four Phase 2A files outside the strict surfaces
named below, or any other file in phase4-coordinator/. Verify the
edit set with:

  git diff --name-only HEAD~1 \
    | grep -vE '^(phase4-coordinator/internal/ws/(messages|messages_test|auth_attempts|auth_attempts_test|server|server_test)\.go|phase4-coordinator/go\.(mod|sum))$' \
    | wc -l

The output MUST be `0`.

## Critical constraints

**1. L-1 byte-identical default per SPEC-001 v1.3 §6.7.3 cell 1 +
SPEC-010 v1.5 §4.1.** A v1.3 binary's initial-stage frame with
`supported_models: ["mlx-community/Qwen2.5-7B-Instruct-4bit"]` (single
entry equal to `model_id`, lower-case) and `publishes_supported_models`
ABSENT must, after this phase lands, produce:
  - `Provider.SupportedModels == []string{"mlx-community/Qwen2.5-7B-Instruct-4bit"}`
  - `Provider.PublishesSupportedModels == false`
  - `/poolz` output for that provider OMITS `supported_models` and
    `publishes_supported_models` keys entirely (Phase 2A's omitempty
    tags ensure this — DO NOT regress).
  - `/v1/status` output is byte-identical to v1.3.4 (the §7.4 echo
    logic is Phase 2D, NOT in this phase).
This is the binary's actual emission shape per SPEC-001 v1.3 R-6.7.3
and SPEC-010 v1.5 R-3.6.2 — a single-entry `[model_id]` array is the
default-on emission, NOT field absence. Both the present-single-entry
case AND the historically-absent case (pre-SPEC-010 binaries, legacy
hello path) MUST resolve to `SupportedModels = []string{ModelID}` per
SPEC-002 v1.3.5 R-3.X.1 fallback synthesis.

**2. Initial-stage parser additions (R-7.8.3 + R-7.8.4).** In
`parseAuthInitial` at messages.go:333, add OPTIONAL handling for
`supported_models` (array of strings) and `publishes_supported_models`
(bool), placed AFTER the existing `tier2_capabilities` block at
messages.go:381-387 and BEFORE the closing `return req, "", nil`.
Validation order MUST be exactly the order mandated by SPEC-010 v1.5
R-3.1.9 (this is also AC-K.15 from SPEC-002 §11):

  a. JSON type check — `supported_models` must unmarshal as a JSON
     array of strings; `publishes_supported_models` must unmarshal as
     bool. Type errors return `badField = "supported_models"` (or
     `"publishes_supported_models"`) with the JSON-unmarshal error.
  b. Per-entry byte length: each entry's UTF-8 byte length MUST be
     ≤ 256. If any entry exceeds, return badField =
     `"supported_models entry exceeds 256 bytes"` with a
     `fieldError`. This substring is the LOCKED AC-K.15 / AC-17 test
     oracle — type it literally, no paraphrase.
  c. Array length: total entry count MUST be ≤ 64. If exceeded,
     return badField = `"supported_models exceeds 64 entries"`. Locked
     AC-K.15 / AC-22 substring.
  d. Normalized duplicate check: after NFC normalization + ASCII
     case-fold, no two entries may compare equal. If duplicates,
     return badField = `"supported_models contains duplicate entries"`.
     Locked AC-K.15 / AC-23 substring.
  e. `model_id` containment: after the same normalization, the
     resolved catalog MUST contain `req.ModelID`. If absent, return
     badField = `"supported_models missing model_id"`. (No
     locked-substring constraint — but the substring MUST appear in
     the rejection reason text for grep-based test oracles.)

If `supported_models` is absent on the wire entirely, the field is
left at the Go zero value (`nil`); no error. If
`publishes_supported_models` is absent, the field is left at zero
(`false`); no error.

For NFC normalization use `golang.org/x/text/unicode/norm` (Form NFC).
Add `golang.org/x/text` to `go.mod` via `go get golang.org/x/text@latest`
inside `phase4-coordinator/`. ASCII case-fold is `strings.ToLower` on
the NFC-normalized string. Do NOT use Unicode-aware case folding
beyond ASCII — the spec mandates ASCII case-fold specifically.

**3. Proof-stage parser additions (R-7.8.7).** In `parseAuthProof` at
messages.go:391, add OPTIONAL handling for `supported_models` and
`publishes_supported_models` AFTER the existing
`attestation_token` block (messages.go:398-400) and BEFORE
`return req, "", nil`. Absent fields → zero values, no error. Present
arrays MUST pass the same JSON-type check from constraint 2a, but the
length / duplicate / containment checks are NOT re-applied in the
parser (they ran on the initial stage and the cross-stage compare in
the server logic handles divergence per constraint 5).

**4. New `AuthAttemptState` type + retention store
(R-3.X.5, R-7.9.1, R-7.9.3, R-7.9.5).** Create a new file
`phase4-coordinator/internal/ws/auth_attempts.go` with:

    package ws

    import (
        "sync"
        "time"
    )

    // AuthAttemptState retains the per-attempt SPEC-010 v1.5 R-3.1.10
    // values across the v2 auth_request initial→proof handshake.
    // Populated only when at least one of supported_models /
    // publishes_supported_models is present on the initial-stage frame
    // (R-7.9.8 L-1 baseline gate).
    type AuthAttemptState struct {
        AuthAttemptID            string
        ProviderID               string
        SupportedModels          []string
        PublishesSupportedModels bool
        SupportedModelsPresent   bool // initial-stage carried supported_models key
        PublishesPresent         bool // initial-stage carried publishes_supported_models key
        StartedAt                time.Time
        ExpiresAt                time.Time
    }

    // authAttemptStore implements the §7.9 lifecycle with a max-bound
    // defensive cap per R-7.9.6. Concurrent-safe via a single mutex.
    type authAttemptStore struct {
        mu       sync.Mutex
        entries  map[string]AuthAttemptState
        maxBound int
    }

    func newAuthAttemptStore(maxBound int) *authAttemptStore {
        if maxBound <= 0 {
            maxBound = 1024
        }
        return &authAttemptStore{
            entries:  make(map[string]AuthAttemptState),
            maxBound: maxBound,
        }
    }

    // tryReserve attempts to insert a new retention entry. Returns
    // false if the store is at maxBound — caller MUST reject the
    // initial-stage frame BEFORE creating any other state, per
    // R-7.9.6 and AC-K.16 ("rejection MUST occur BEFORE creating a
    // new retention entry").
    func (s *authAttemptStore) tryReserve(state AuthAttemptState) bool {
        s.mu.Lock()
        defer s.mu.Unlock()
        if len(s.entries) >= s.maxBound {
            return false
        }
        s.entries[state.AuthAttemptID] = state
        return true
    }

    // release removes a retention entry. Safe to call on an unknown
    // ID (the defer pattern in the server may release after the
    // proof-stage acceptance has already cleared it).
    func (s *authAttemptStore) release(authAttemptID string) {
        s.mu.Lock()
        defer s.mu.Unlock()
        delete(s.entries, authAttemptID)
    }

    // lookup returns a copy of the retention entry for the given ID
    // and a boolean indicating whether it was found.
    func (s *authAttemptStore) lookup(authAttemptID string) (AuthAttemptState, bool) {
        s.mu.Lock()
        defer s.mu.Unlock()
        st, ok := s.entries[authAttemptID]
        return st, ok
    }

    // len returns the current in-flight retention count. Test-facing
    // only; the production code MUST NOT condition behavior on this.
    func (s *authAttemptStore) count() int {
        s.mu.Lock()
        defer s.mu.Unlock()
        return len(s.entries)
    }

The `maxBound` MUST default to `1024` per SPEC-002 v1.3.5 R-7.9.6.

**5. Server lifecycle integration (R-7.9.7 + R-7.9.8 + R-7.8.7).** In
`internal/ws/server.go`, the v2 auth path lives at lines ~270-460. The
edits are surgical:

  a. Add `authAttempts *authAttemptStore` as a new field on the
     `Server` struct (find the struct definition, append the new field
     at the end of the field list with comment
     `// SPEC-002 v1.3.5 §7.9 — auth-attempt retention store, 1024 bound`).
     Initialize in `NewServer` (or whatever constructor exists) with
     `s.authAttempts = newAuthAttemptStore(1024)`.

  b. In the v2 auth handler between `authAttemptID := "auth-" + s.newUUID()`
     (server.go:354) and the `challenge := AuthChallenge{...}` literal
     (server.go:356), insert the §7.9 retention/L-1 gate block:

         // SPEC-002 v1.3.5 §7.9 + R-7.9.8 — L-1 baseline gate:
         // create retention state only if the initial-stage frame
         // carried at least one SPEC-010 field. Absence of both means
         // a pre-SPEC-010 (or single-entry-default v1.3) binary —
         // no retention entry, no defer, no metric.
         _, supportedModelsPresent := /* parse helper: was supported_models present on the wire? see step (c) */
         _, publishesPresent := /* parse helper: was publishes_supported_models present on the wire? */
         retainSpec010 := supportedModelsPresent || publishesPresent
         if retainSpec010 {
             state := AuthAttemptState{
                 AuthAttemptID:            authAttemptID,
                 ProviderID:               initial.ProviderID,
                 SupportedModels:          append([]string(nil), initial.SupportedModels...),
                 PublishesSupportedModels: initial.PublishesSupportedModels,
                 SupportedModelsPresent:   supportedModelsPresent,
                 PublishesPresent:         publishesPresent,
                 StartedAt:                s.now(),
                 ExpiresAt:                challengeExpiresAt,
             }
             // R-7.9.6 / AC-K.16 — defensive 1024 bound. Reject
             // BEFORE creating the entry; tryReserve does the test +
             // insert atomically.
             if !s.authAttempts.tryReserve(state) {
                 s.sendAuthRejection(conn, "too_many_auth_attempts", "auth-attempt retention bound exceeded")
                 s.close(conn, ClosePoolFull, "too_many_auth_attempts")
                 return "", ""
             }
             // R-7.9.7 — defer-based release scoped to the
             // auth-attempt, installed AFTER reserve and BEFORE
             // auth_challenge write. Any terminal path (proof success,
             // proof reject, expiry, disconnect-before-proof, read/
             // parse error, challenge write failure) hits this defer.
             defer s.authAttempts.release(authAttemptID)
         }

     The wire-presence detection (the two `supportedModelsPresent` /
     `publishesPresent` bools) MUST come from `parseAuthInitial` — see
     step (c). Do not re-parse the raw JSON here.

  c. To plumb wire-presence from parser to caller without breaking
     other call sites, extend `parseAuthInitial`'s return signature.
     Current:

         func parseAuthInitial(raw map[string]json.RawMessage, req AuthRequest) (AuthRequest, string, error)

     New (add a separate return value for presence flags):

         type Spec010Presence struct {
             SupportedModels          bool
             PublishesSupportedModels bool
         }

         func parseAuthInitial(raw map[string]json.RawMessage, req AuthRequest) (AuthRequest, Spec010Presence, string, error)

     `ParseAuthRequest` MUST be extended to return `Spec010Presence`
     too, so the caller in server.go has access. Update the
     `switch req.Stage` block to thread the flags through. The proof
     path's `Spec010Presence` is irrelevant — return zero value.

     Audit the entire codebase (`grep -n "ParseAuthRequest\|parseAuthInitial" phase4-coordinator/`)
     to update every call site for the new signature. Existing tests
     that consume `ParseAuthRequest` MUST be updated accordingly —
     this is the one allowed cross-cutting touch.

  d. After successful proof-stage acceptance — that is, AFTER
     server.go:411 sets `entry.AttestationStatus` and BEFORE
     server.go:421 calls `registerProviderSession` — populate the
     Phase 2A Provider fields on `entry`:

         // SPEC-002 v1.3.5 §3.X.1 / §3.X.2 + SPEC-010 v1.5 R-3.3.1 /
         // R-3.3.2 — populate the catalog onto Provider. The fallback
         // synthesis [ModelID] applies when supported_models was
         // absent on the wire OR when the parsed slice is empty
         // (pre-SPEC-010 binary, defensive guard).
         if len(initial.SupportedModels) > 0 {
             entry.SupportedModels = append([]string(nil), initial.SupportedModels...)
         } else {
             entry.SupportedModels = []string{entry.ModelID}
         }
         entry.PublishesSupportedModels = initial.PublishesSupportedModels

  e. Proof-stage cross-stage compare (R-7.8.7 + AC-K.3). AFTER
     `proof, badField, err := ParseAuthRequest(proofPayload)` at
     server.go:389 succeeds and AFTER the existing
     `proof.AuthAttemptID != authAttemptID` guard at server.go:398
     passes, BEFORE the Tier-2 attestation verification at
     server.go:403, add:

         // SPEC-002 v1.3.5 §7.8 R-7.8.7 + AC-K.3 — when proof carries
         // SPEC-010 fields, they MUST byte-identical-compare to the
         // retained initial-stage values after NFC + ASCII case-fold.
         // Absent proof fields = no comparison (accept). The locked
         // test oracle is the exact substring
         // "supported_models mismatch between auth_request stages".
         if retainSpec010 {
             retained, ok := s.authAttempts.lookup(authAttemptID)
             if ok && proofPresence.SupportedModels {
                 if !supportedModelsEqualUnderNFCASCIIFold(retained.SupportedModels, proof.SupportedModels) {
                     s.sendAuthRejection(conn, "bad_request", "supported_models mismatch between auth_request stages")
                     s.close(conn, CloseInvalidHello, "supported_models mismatch between auth_request stages")
                     return "", ""
                 }
             }
             if ok && proofPresence.PublishesSupportedModels {
                 if proof.PublishesSupportedModels != retained.PublishesSupportedModels {
                     s.sendAuthRejection(conn, "bad_request", "publishes_supported_models mismatch between auth_request stages")
                     s.close(conn, CloseInvalidHello, "publishes_supported_models mismatch between auth_request stages")
                     return "", ""
                 }
             }
         }

     `proofPresence` is the second return from `ParseAuthRequest`
     applied to the proof payload.

     Implement `supportedModelsEqualUnderNFCASCIIFold` as a free
     function in `auth_attempts.go`:

         func supportedModelsEqualUnderNFCASCIIFold(a, b []string) bool {
             if len(a) != len(b) {
                 return false
             }
             for i := range a {
                 if normalizeSupportedModelEntry(a[i]) != normalizeSupportedModelEntry(b[i]) {
                     return false
                 }
             }
             return true
         }

         func normalizeSupportedModelEntry(s string) string {
             return strings.ToLower(norm.NFC.String(s))
         }

     Order-preserving compare (NOT set compare) is correct here —
     SPEC-010 R-3.1.7 says "byte-identical after normalization",
     which is positional.

**6. R-7.9.8 L-1 baseline gate is non-negotiable.** When
`retainSpec010 == false` (neither SPEC-010 field on initial), the
coordinator MUST NOT:
  - call `s.authAttempts.tryReserve`
  - install the defer-release
  - emit any new metric or log line specific to retention
The store stays empty. `s.authAttempts.count()` returns 0 throughout
the legacy path. Test this in `auth_attempts_test.go` AND in
`server_test.go`.

**7. Initial-stage SPEC-010 validation MUST run BEFORE retention
reserve.** The validation-order chain in step 2a-2e produces a
`badField` rejection; the caller then triggers the existing
rejection path (`s.sendAuthRejection` + `s.close`). Do NOT create a
retention entry first and then validate — invalid SPEC-010 fields
result in NO retention entry created (a half-failed initial leaves
the store empty). The defer-release in step (b) is installed AFTER
`tryReserve`, so a failed reserve means no defer either.

**8. The `Provider` struct edits from Phase 2A are READ-ONLY in this
phase.** Do not add, remove, or modify any field on `Provider`. Do
not change Phase 2A's `provider_test.go` snapshot test or the
`/poolz` shape test. Run the Phase 2A tests after your edits to
confirm zero regression:

    go test ./internal/pool/... -run TestProviderJSON -v
    go test ./internal/ws/... -run TestPoolzShape -v

Both MUST pass.

**9. Existing v2 auth tests MUST continue to pass.** The test fleet
at server_test.go uses `validAuthInitial`, `writeAuthProof`,
`readAuthChallenge`, `readAuthResponse`. After your edits, every
existing test (`TestProviderAuthV2RegistersEncryptedSession`,
`TestProviderAuthV2AcceptsMockAttestationToken`, etc.) MUST still
pass without modification — they don't set SPEC-010 fields, so they
exercise the L-1 path with `retainSpec010 == false`. If you find an
existing test needs editing to keep passing, STOP and report — that's
a regression in the L-1 path, not a test that needs updating.

**10. `gofmt -l ./internal/ws/` and `go vet ./internal/ws/...` MUST
both produce zero output.** `go mod tidy` after the x/text add MUST
leave a clean tree. Do NOT vendor; the module is non-vendored.

**11. No spec edits, no handoff-doc edits, no DECISION_CRITERIA
edits, no BUILD-prompt edits.** Verify with `git diff specs/ beta/` —
empty.

**12. The defer-release lifecycle is `auth-attempt-scoped`, not
`session-scoped`.** The existing `handleDisconnect` /
`registerProviderSession` lifecycle is for AFTER admission. Phase 2B's
defer lives in the same function frame as `authAttemptID`, so it fires
on every terminal path within the v2 auth handler — including the
proof-stage rejection paths at server.go:391-395, server.go:398-402,
and server.go:404-407. Verify by reading the handler and confirming
every `return` after the defer installs goes through the defer chain
(Go semantics guarantee this if the defer is correctly placed).

## Required reading (in this order)

1. `specs/SPEC-002-coordinator.md` §3.X (lines 305-378), §7.8 (lines
   2630-2744), §7.9 (lines 2746-2812). These are the binding rules
   for this phase.
2. `specs/SPEC-002-coordinator.md` §11 AC-K.3 / AC-K.4 / AC-K.5 /
   AC-K.15 / AC-K.16 (the binding acceptance criteria). The
   reason-text substrings in AC-K.15 are LOCKED test oracles —
   match verbatim, do not paraphrase.
3. `phase4-coordinator/internal/ws/messages.go:37-57` (current
   AuthRequest), `:286-330` (ParseAuthRequest dispatcher), `:333-388`
   (parseAuthInitial), `:391-401` (parseAuthProof), `:404-422`
   (AuthRequest.Hello). The shape you're extending.
4. `phase4-coordinator/internal/ws/server.go:265-460` (v2 auth path),
   `:30-41` (close codes — note ClosePoolFull = 4429 is the 503-class
   close used for `too_many_auth_attempts`).
5. `phase4-coordinator/internal/pool/provider.go:50-101` (Phase 2A
   Provider struct — the populator target).
6. Phase 2A commit (`git show de41380 --stat`) to see what landed.

## Required edits — exact shape

The four code constraints (#2, #3, #4, #5) above ARE the exact-shape
specification; treat them as the literal blueprint. The remaining
mechanics (struct field add on AuthRequest, populator code, presence
plumbing) are described inline.

### AuthRequest struct extension

In `messages.go`, extend `AuthRequest` (around line 37-57) with
exactly two new fields placed AFTER `AttestationToken` and BEFORE
the closing `}`:

    SupportedModels          []string `json:"supported_models,omitempty"`
    PublishesSupportedModels bool     `json:"publishes_supported_models,omitempty"`

No other field on AuthRequest changes. `Hello()` (messages.go:404)
is NOT extended in this phase — the legacy `hello` path does not
carry SPEC-010 fields, and the v2 path populates Provider via the
direct-set in server.go (constraint 5d).

### Tests — `messages_test.go`

Add at minimum these tests (more if needed for coverage):

  - `TestParseAuthInitialAcceptsLegacyAbsentSpec010`: parses a frame
    without `supported_models` / `publishes_supported_models`,
    asserts the returned `Spec010Presence` is `{false, false}` and
    `req.SupportedModels == nil`, `req.PublishesSupportedModels == false`.

  - `TestParseAuthInitialAcceptsSingleEntryCatalog`: parses a frame
    with `supported_models: ["mlx-community/Qwen2.5-7B-Instruct-4bit"]`
    (matching ModelID) and `publishes_supported_models: false` ABSENT,
    asserts presence `{true, false}` and the parsed slice equals the
    input.

  - `TestParseAuthInitialRejectsOverlongEntry`: parses a frame with a
    257-byte entry, asserts the badField string
    EQUALS `"supported_models entry exceeds 256 bytes"` (LOCKED
    substring per AC-K.15 / AC-17).

  - `TestParseAuthInitialRejectsOverlongCatalog`: parses a frame with
    65 entries, asserts badField EQUALS `"supported_models exceeds
    64 entries"` (LOCKED per AC-K.15 / AC-22).

  - `TestParseAuthInitialRejectsDuplicateUnderNFCASCIIFold`: parses
    a frame with `["Model-A", "MODEL-A"]`, asserts badField EQUALS
    `"supported_models contains duplicate entries"` (LOCKED per
    AC-K.15 / AC-23).

  - `TestParseAuthInitialRejectsMissingModelID`: parses a frame with
    `model_id: "X"` and `supported_models: ["Y"]`, asserts badField
    CONTAINS the substring `"missing model_id"` (no locked oracle —
    pre-flight guard).

  - `TestParseAuthProofAcceptsAbsentSpec010`: parses a proof-stage
    frame without SPEC-010 fields, asserts the returned
    `Spec010Presence` is `{false, false}` (proof stage does not
    re-validate; absence is a no-op).

  - `TestParseAuthProofRetainsSpec010WhenPresent`: parses a proof
    frame with `supported_models: ["X"]`, asserts the parsed slice
    surfaces via the returned AuthRequest.

### Tests — `auth_attempts_test.go` (NEW)

  - `TestAuthAttemptStoreTryReserveAndRelease`: reserve, lookup
    returns ok=true with stored state; release, lookup returns
    ok=false.

  - `TestAuthAttemptStoreEnforces1024Bound`: pre-load 1024 entries
    via direct map writes (for speed), assert `tryReserve` of a
    1025th returns false. Assert `count()` returns 1024 unchanged.
    Then release one, `tryReserve` returns true.

  - `TestNormalizeSupportedModelEntry`: assert
    `normalizeSupportedModelEntry("Model-Ç")` produces the NFC-
    composed lowercase form. (Pick a string where NFD vs NFC differ
    and assert NFC is selected. Example:
    `string([]byte{0x43, 0xCC, 0xA7})` (C + combining cedilla) vs
    `"Ç"` (precomposed Ç) should normalize to the same NFC
    output before case-fold.)

  - `TestSupportedModelsEqualUnderNFCASCIIFoldHandlesCaseAndForm`:
    `["Model-A"]` equals `["model-a"]` returns true; `["Model-A"]`
    equals `["Model-B"]` returns false; `["A","B"]` equals
    `["B","A"]` returns false (positional compare).

### Tests — `server_test.go`

Add at minimum:

  - `TestProviderAuthV2L1NoRetentionEntry`: connect, send initial
    frame with NO supported_models and NO
    publishes_supported_models, send proof, assert successful
    registration AND `s.authAttempts.count() == 0` throughout AND
    Provider entry has `SupportedModels = [ModelID]` (single-entry
    fallback per R-3.X.1) and `PublishesSupportedModels == false`.

  - `TestProviderAuthV2Spec010RetentionEntryCreatedAndReleased`:
    connect, send initial with `supported_models: [ModelID]` AND
    `publishes_supported_models: true`, mid-handshake assert
    `count() == 1`, complete proof, after successful registration
    assert `count() == 0` (defer fired). Provider entry has
    `SupportedModels` == the sent catalog and
    `PublishesSupportedModels == true`.

  - `TestProviderAuthV2RetentionReleasedOnDisconnectBeforeProof`
    (AC-K.5): connect, send initial with SPEC-010 fields, receive
    challenge, abruptly close the connection without sending proof,
    assert `count() == 0` within a short eventually() window. The
    defer fires when the server's auth handler returns due to read
    error.

  - `TestProviderAuthV2Retention1024BoundRejection` (AC-K.16):
    pre-load the store with 1024 entries (test helper accesses the
    private store via a build-tag-free test-only accessor — or
    expose a tiny test helper on `Server` like
    `func (s *Server) testHookSetAuthAttempts(store *authAttemptStore)`
    only if avoidable; preferred is to construct the server with
    `newAuthAttemptStore(1)` via a test-only knob). Send an initial
    frame with SPEC-010 fields, assert the server responds with an
    `auth_response.error.code == "too_many_auth_attempts"` and
    closes with code 4429. Then release the slot and confirm the
    next initial-stage frame succeeds.

  - `TestProviderAuthV2ProofMismatchRejectedWithLockedSubstring`
    (AC-K.3): initial has `supported_models: ["model-a"]`, proof has
    `supported_models: ["model-b"]`, assert
    `auth_response.error.code == "bad_request"` AND
    `auth_response.error.message` contains the EXACT substring
    `"supported_models mismatch between auth_request stages"`.

  - `TestProviderAuthV2ProofAbsentSpec010Accepted` (AC-K.3): initial
    has SPEC-010 fields, proof omits them, assert successful
    registration with no comparison performed.

## Done criteria

1. `cd phase4-coordinator && go mod tidy` exits 0 and only modifies
   `go.mod` / `go.sum` (no unrelated module shifts).
2. `cd phase4-coordinator && go build ./...` exits 0.
3. `cd phase4-coordinator && go vet ./...` exits 0 with no output.
4. `cd phase4-coordinator && gofmt -l ./internal/ws/` produces empty
   output.
5. `cd phase4-coordinator && go test ./internal/ws/... -count=1` passes
   with the new tests AND all existing tests.
6. `cd phase4-coordinator && go test ./internal/pool/... -count=1`
   still passes (Phase 2A regression check).
7. `git diff --name-only HEAD~1` lists exactly the eight files in the
   edit budget (six Go files + go.mod + go.sum). Plus the unstaged
   `beta/DECISION_CRITERIA.md` from the prior session — DO NOT stage
   that.

## Out of scope (do NOT do in this phase)

- Editing `ApplyHeartbeat` (Phase 2C — riskiest, gets its own prompt).
- Editing `/v1/status` (Phase 2D).
- Creating `internal/audit/` package (Phase 2E).
- Touching the legacy `hello` path or `parseHello`.
- Adding SPEC-010 fields to `Hello()` converter.
- Modifying any of the four Phase 2A Provider fields beyond the
  read-only populator that sets them.
- Adding `model_id` containment validation to the proof-stage parser
  (the spec only re-applies the comparison; length / duplicate /
  containment checks live on the initial stage per R-3.1.9).
- Adding rate-limit metrics for the retention bound — R-7.9.8 says
  no metrics; only the rejection path is binding.
- Editing close codes or close-code registry.

## Self-check before reporting done

Run, in order, from /Users/augstar/macprovider-poc/phase4-coordinator,
and paste each output back to the operator:

    go mod tidy
    git diff go.mod go.sum
    go build ./...
    go vet ./...
    gofmt -l ./internal/ws/
    go test ./internal/pool/... -count=1
    go test ./internal/ws/... -count=1 -v -run TestProviderAuthV2 | tail -40
    go test ./internal/ws/... -count=1 -v -run TestParseAuth | tail -40
    go test ./internal/ws/... -count=1 -v -run TestAuthAttempt | tail -30
    go test ./internal/ws/... -count=1
    cd /Users/augstar/macprovider-poc
    git diff --name-only HEAD~1
    git diff specs/ beta/

The last `git diff specs/ beta/` MUST produce empty output. If any
of the others fail, do NOT report done — diagnose and fix within
the eight-file edit budget, or report blocked with the failure mode.

=== END PROMPT ===
```

---

## Operator notes (not part of the prompt)

- 2B is larger than 2A (estimated 75-120 min vs 30-45). The retention
  store + lifecycle + cross-stage compare + dependency add stretches
  the surface; the L-1 gate keeps it auditable.
- The `x/text` dependency is well-known and low-risk. Alternatives:
  defer NFC and ASCII case-fold separately (fail closed on raw bytes
  difference instead) — but the spec explicitly mandates NFC per
  R-3.1.7, so this is the right place to add it.
- Audit risks to watch in R1:
  - **Defer position.** If Codex puts the `defer release` AFTER the
    challenge write, a challenge-write failure leaks state.
  - **L-1 gate path coverage.** A defer installed unconditionally
    against `retainSpec010 == false` violates R-7.9.8.
  - **1024-bound off-by-one.** `tryReserve` MUST check `len(entries)
    >= maxBound` BEFORE insert; if it checks `> maxBound` we admit
    1025th.
  - **Locked substrings.** AC-K.15 / AC-K.3 substrings are
    grep-asserted in tests. Any paraphrase = R2.
  - **Parser signature cascade.** Changing `ParseAuthRequest` signature
    forces edits to every caller — Codex MUST find them all
    (`grep -rn ParseAuthRequest phase4-coordinator/`).
- After 2B audit passes, the surface for 2C (ApplyHeartbeat
  REPLACEMENT) is the riskiest of the five phases. Plan time for an
  R2 round on 2C.

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7) for the SPEC-002 v1.3.5 Phase 2 implementation.
