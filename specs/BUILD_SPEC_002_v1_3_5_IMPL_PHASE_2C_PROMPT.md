# Implementation BUILD prompt — SPEC-002 v1.3.5 Phase 2C (ApplyHeartbeat REPLACEMENT)

Operator-paste prompt for Codex GPT-5 to land the **third** of five
implementation sub-phases of SPEC-002 v1.3.5 in `phase4-coordinator/`.
2C consumes Phase 2A's struct fields (commit `de41380`) and is the
**riskiest phase of the five** per the handoff §3 — it REPLACES the
semantics of a locked code path at `provider.go:411-432`. Phase 2B
(`11bf449` + R2 `83540b1` + R3 `c739055`) is unaffected.

**Scope: `Heartbeat` SPEC-011 field parsing + ApplyHeartbeat
REPLACEMENT + LastLoadingState / LoadingStartedAt maintenance + swap-
emit callback hook.** No SQLite audit-log, no `/v1/status` echo, no
operator_model_swap payload schema. Those are 2D / 2E.

**One-line summary.** Extend `Heartbeat` + `HeartbeatUpdate` with
optional `ModelHash` + `Loading`; teach `ParseHeartbeat` to surface a
`HeartbeatPresence{ModelHash, Loading}` flag pair; REPLACE the
hash-clearing block in `ApplyHeartbeat` with the §7.1 two-path
dispatch (LEGACY clear when `ModelHash` absent on the wire; SPEC-011
re-verify via injected callback when present) keyed PER-HEARTBEAT
(no sticky path inference) per R-7.1.3 / R-7.1.4 / AC-K.8; maintain
`Provider.LastLoadingState` per heartbeat and stamp
`Provider.LoadingStartedAt` on the false→true transition per R-3.X.4
/ R-7.10.6; on the true→false transition under the SPEC-011 path,
invoke an injected `SwapEventEmitter` callback (default nil =
no-op) that 2E will populate with the SQLite write. The L-1
byte-identical default (heartbeat without `model_hash` and `loading`)
MUST preserve byte-for-byte the current v1.3.4 ApplyHeartbeat
behavior per SPEC-001 v1.3 §6.7.3 cell 1 + SPEC-011 v0.5 R-3.3.0 /
AC-18.

**Locked-spec dependencies (DO NOT contradict).**
- SPEC-002 v1.3.5 §3.X.4 / R-7.10.6 (LastLoadingState + LoadingStartedAt
  semantics), §7.1 LOCKED (heartbeat field extension + ApplyHeartbeat
  REPLACEMENT R-7.1.1 through R-7.1.7), §11 AC-K.6 / AC-K.7 / AC-K.8
  (acceptance criteria).
- SPEC-011 v0.5 §3.3 R-3.3.0 / R-3.3.1 / R-3.3.2 / R-3.3.4 / R-3.3.5
  (heartbeat extension + path semantics), §3.5 R-3.5.2 / R-3.5.3
  (HashStatus from re-verification), §6.2 D2.1 fix (the LEGACY /
  SPEC-011 path split), AC-10 + AC-13 + AC-18 + AC-19.
- SPEC-008 v0.3 §5.3-§5.6 Pillar A re-verification (the existing
  `tier2.VerifyProviderHash(modelID, reportedHash) pool.HashStatus`
  at `phase4-coordinator/internal/tier2/catalog.go:335` is the
  binding implementation; 2C does NOT modify it, only calls it from
  the injected callback).
- Phase 2A commit `de41380` (the 4 Provider fields are 2C's write
  targets; field names + types are LOCKED).
- Phase 2B commits `11bf449` / `83540b1` / `c739055` are unaffected
  by 2C; the v2 auth_request handshake remains read-only here.

This is a **code-only** session. No spec edits. Verify with
`git diff specs/` — must be empty.

Run in **Codex CLI** via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~90-140 min
(parser + two-path dispatch + state maintenance + emitter hook +
exhaustive test matrix across both paths).

Branch: `fix/spec-002-v1-3-5-coordinator` (tip `c739055`). Codex MUST
NOT create a new branch and MUST NOT touch any Phase 2A/2B file
beyond the surfaces named below.

---

```
=== BEGIN PROMPT ===

You are implementing Phase 2C of SPEC-002 v1.3.5 in the Go
coordinator at /Users/augstar/macprovider-poc/phase4-coordinator/.
This phase REPLACES the semantics of the locked
ApplyHeartbeat code path at provider.go:411-432 with the §7.1
two-path dispatch and adds maintenance for the Phase 2A
LastLoadingState + LoadingStartedAt fields.

You will edit/create the following files (and ONLY these):

  phase4-coordinator/internal/pool/provider.go        (extend)
  phase4-coordinator/internal/pool/provider_test.go   (extend)
  phase4-coordinator/internal/ws/messages.go          (extend)
  phase4-coordinator/internal/ws/messages_test.go     (extend)
  phase4-coordinator/internal/ws/server.go            (extend)
  phase4-coordinator/internal/ws/server_test.go       (extend)

You will NOT edit any file under specs/, beta/, phase3-binary/,
phase5-gateway/, any Phase 2A/2B file outside the surfaces below
(auth_attempts.go is OFF LIMITS), or any other file in
phase4-coordinator/. Verify the edit set with:

  git diff --name-only HEAD \
    | grep -vE '^phase4-coordinator/internal/(pool|ws)/(provider|messages|server)(_test)?\.go$' \
    | wc -l

The output MUST be `0`.

## Critical constraints

**1. L-1 byte-identical default per SPEC-001 v1.3 §6.7.3 cell 1 +
SPEC-011 v0.5 R-3.3.0 / AC-18.** A v1.3 binary without
`--enable-warm-swap` (heartbeats lack `model_hash` AND `loading`)
MUST produce, after this phase, byte-identical Provider state to
what v1.3.4 produced:
  - `Provider.ModelHash`: cleared when `ModelID` changes (LEGACY
    behavior); preserved when `ModelID` unchanged.
  - `Provider.HashStatus`: set to `HashStatusUncatalogued` when
    `ModelID` changes (LEGACY behavior); unchanged when `ModelID`
    unchanged.
  - `Provider.LastLoadingState`: zero value (false) throughout —
    NO writes from a heartbeat that omits `loading`.
  - `Provider.LoadingStartedAt`: zero value (`time.Time{}`)
    throughout — NO writes from a heartbeat that omits `loading`.
  - `Provider.SupportedModels` / `Provider.PublishesSupportedModels`:
    Phase 2A populated these on auth; 2C does NOT touch them.
  - `/poolz` JSON output for that provider remains byte-identical
    to v1.3.4 (Phase 2A's omitempty + json:"-" tags ensure this).
This is the **non-negotiable invariant**. The first test that lands
in this phase MUST prove it (see test list below). A test that
passes today and fails after your edits is a CRITICAL bug.

**2. Heartbeat struct + parser extension.** In `messages.go`,
extend the existing `Heartbeat` struct (line ~128) with exactly two
new fields placed AFTER `ThroughputTPSSinceLast` and BEFORE the
closing `}`:

    ModelHash               string  `json:"model_hash,omitempty"`
    Loading                 bool    `json:"loading,omitempty"`

Both `omitempty` so a server-side roundtrip preserves the absent
shape if you were to round-trip a Heartbeat through json.Marshal
(this isn't a production path — Heartbeat is read-only inbound —
but the symmetry with AuthRequest matters).

Add `HeartbeatPresence` struct (mirrors `Spec010Presence` from
Phase 2B):

    type HeartbeatPresence struct {
        ModelHash bool
        Loading   bool
    }

Extend `ParseHeartbeat` signature:

    func ParseHeartbeat(payload []byte) (Heartbeat, HeartbeatPresence, string, error)

Inside the parser, AFTER the existing `requireFloat` for
`throughput_tps_since_last` (around line 580-582) and BEFORE
`return hb, "", nil`, add the optional-field block:

    presence := HeartbeatPresence{}
    if v, ok := raw["model_hash"]; ok {
        presence.ModelHash = true
        if string(v) == "null" {
            return Heartbeat{}, presence, "model_hash", fmt.Errorf("model_hash must be a string")
        }
        if err := json.Unmarshal(v, &hb.ModelHash); err != nil {
            return Heartbeat{}, presence, "model_hash", err
        }
    }
    if v, ok := raw["loading"]; ok {
        presence.Loading = true
        if string(v) == "null" {
            return Heartbeat{}, presence, "loading", fmt.Errorf("loading must be a bool")
        }
        if err := json.Unmarshal(v, &hb.Loading); err != nil {
            return Heartbeat{}, presence, "loading", err
        }
    }
    return hb, presence, "", nil

Update the `return hb, "", nil` at the original return point to
`return hb, presence, "", nil` and update every existing error
return inside the parser body to include `presence` (empty for the
fail-fast paths is fine):

    return Heartbeat{}, HeartbeatPresence{}, err.Field, err

Also extend `ParseHeartbeat`'s `Heartbeat{}` error-return zero value
to use `HeartbeatPresence{}` everywhere. Run
`gofmt -l ./internal/ws/` to confirm.

**3. HeartbeatUpdate extension + new types in provider.go.** In
`provider.go`, extend the `HeartbeatUpdate` struct (around line 412)
with exactly three new fields placed AFTER `ThroughputTPSEstimate`
and BEFORE `At`:

    // ModelHash is the raw lowercase hex hash from the heartbeat
    // when ModelHashPresent is true; ignored otherwise. Populated
    // from the SPEC-011 v0.5 optional heartbeat field per
    // SPEC-002 v1.3.5 §7.1 R-7.1.4.
    ModelHash         string
    ModelHashPresent  bool
    // Loading is the value of the heartbeat's optional `loading`
    // field; absent on the wire (= LoadingPresent false) is
    // equivalent to false per SPEC-011 v0.5 R-3.3.4.
    Loading           bool
    LoadingPresent    bool

Add the new types ABOVE the existing `HeartbeatUpdate` declaration:

    // HeartbeatHashVerifier verifies a (model_id, reported_hash)
    // pair against the SPEC-008 v0.3 §5.5 five-state enum. Injected
    // into Registry via WithHeartbeatHashVerifier so the pool
    // package stays decoupled from the tier2 catalog package; the
    // production wiring at internal/ws/server.go passes
    // tier2.VerifyProviderHash.
    type HeartbeatHashVerifier func(modelID, reportedHash string) HashStatus

    // SwapEvent carries the per-swap data needed for the
    // operator_model_swap audit event per SPEC-002 v1.3.5 §7.10.
    // Phase 2C only populates and emits this event; Phase 2E adds
    // the SQLite write + payload schema + F-1.5 invariants.
    type SwapEvent struct {
        ProviderID             string
        AssignedID             string
        FromModelID            string
        FromModelHash          string
        ToModelID              string
        ToModelHash            string
        HashVerificationResult HashStatus
        LoadingStartedAt       time.Time
        CompletedAt            time.Time
    }

    // SwapEventEmitter is called from ApplyHeartbeat when a
    // SPEC-011 PATH heartbeat completes a swap (prior heartbeat
    // had loading:true; current heartbeat has loading:false AND
    // carries model_hash). Default nil = no-op. Phase 2E
    // registers the SQLite emitter via WithSwapEmitter.
    type SwapEventEmitter func(event SwapEvent)

Extend the `Registry` struct (around line 114) with two new fields
placed AFTER `maxProvider`:

    hashVerifier HeartbeatHashVerifier
    swapEmitter  SwapEventEmitter

Add a `RegistryOption` functional pattern at the end of the file
(after all existing methods):

    type RegistryOption func(*Registry)

    // WithHeartbeatHashVerifier injects the SPEC-008 v0.3 Pillar A
    // verifier used by the SPEC-011 PATH of ApplyHeartbeat per
    // SPEC-002 v1.3.5 §7.1 R-7.1.5. If never set, the SPEC-011
    // PATH defaults to HashStatusUncatalogued (the conservative
    // fallback for an un-injected Registry — tests typically
    // either inject a stub or never exercise the SPEC-011 PATH).
    func WithHeartbeatHashVerifier(fn HeartbeatHashVerifier) RegistryOption {
        return func(r *Registry) { r.hashVerifier = fn }
    }

    // WithSwapEmitter injects the operator_model_swap callback per
    // SPEC-002 v1.3.5 §7.10. Default nil = no-op (Phase 2C ships
    // the detection logic; Phase 2E ships the SQLite writer).
    func WithSwapEmitter(fn SwapEventEmitter) RegistryOption {
        return func(r *Registry) { r.swapEmitter = fn }
    }

Extend `NewRegistry` to accept variadic options:

    func NewRegistry(providers []config.ProviderConfig, opts ...RegistryOption) *Registry {
        endpoints := make(map[string]config.ProviderConfig, len(providers))
        for _, p := range providers {
            endpoints[p.ProviderID] = p
        }
        r := &Registry{...existing fields...}
        for _, opt := range opts {
            opt(r)
        }
        return r
    }

Existing callers of `NewRegistry(providers)` continue to work
(variadic). Find every call site with
`grep -rn "NewRegistry(" phase4-coordinator/` and update none of them
unless required — they should compile unchanged.

**4. ApplyHeartbeat REPLACEMENT — the body.** Replace the existing
function body at provider.go:411-444 with the §7.1 two-path
dispatch. The new body MUST:

  a. Take the mutex (unchanged).
  b. Resolve provider entry (unchanged).
  c. Capture PRIOR state needed for transition detection AND the
     LEGACY clear behavior — BEFORE any writes:

         priorModelID := p.ModelID
         priorModelHash := p.ModelHash
         priorLoadingState := p.LastLoadingState
         priorLoadingStartedAt := p.LoadingStartedAt

  d. Run the path dispatch per R-7.1.3 / R-7.1.4 / AC-K.8 (per-
     heartbeat, NO sticky inference):

         modelIDChanged := !strings.EqualFold(priorModelID, hb.ModelID)
         if !hb.ModelHashPresent {
             // LEGACY PATH (R-7.1.3): pre-SPEC-011 binary or
             // SPEC-011 binary heartbeat that omits model_hash on
             // this frame. Locked v1.3.4 behavior.
             if modelIDChanged {
                 p.ModelHash = ""
                 p.HashStatus = HashStatusUncatalogued
             }
         } else {
             // SPEC-011 PATH (R-7.1.4 / R-7.1.5): update hash and
             // run Pillar A re-verification. The verifier is
             // injected per WithHeartbeatHashVerifier; if nil,
             // fall back to HashStatusUncatalogued.
             if modelIDChanged {
                 p.ModelHash = hb.ModelHash
                 if r.hashVerifier != nil {
                     p.HashStatus = r.hashVerifier(hb.ModelID, hb.ModelHash)
                 } else {
                     p.HashStatus = HashStatusUncatalogued
                 }
             } else if !strings.EqualFold(priorModelHash, hb.ModelHash) {
                 // Same model_id but different hash — also a
                 // re-verification trigger per SPEC-011 v0.5
                 // §3.5 R-3.5.2.
                 p.ModelHash = hb.ModelHash
                 if r.hashVerifier != nil {
                     p.HashStatus = r.hashVerifier(hb.ModelID, hb.ModelHash)
                 } else {
                     p.HashStatus = HashStatusUncatalogued
                 }
             }
             // model_id and model_hash both unchanged: no
             // re-verification, no state change.
         }

  e. Update the remaining heartbeat-derived metrics (capacity,
     state, etc.) — same as the existing function body around
     lines 419-437.

  f. Maintain LastLoadingState + LoadingStartedAt per R-3.X.4 /
     R-7.10.6. The L-1 invariant is: when `hb.LoadingPresent ==
     false`, leave both fields untouched (zero stays zero). When
     `hb.LoadingPresent == true`:

         if !priorLoadingState && hb.Loading {
             // false→true transition: stamp LoadingStartedAt.
             p.LoadingStartedAt = hb.At
         }
         p.LastLoadingState = hb.Loading

     Reset semantics: do NOT clear `LoadingStartedAt` here on
     true→false transitions; 2E reads it for the
     `loading_window_ms` computation and resets after emission.

  g. Compute `swapCompletedThisHeartbeat` per R-7.1.6 emission
     gate:

         swapCompleted := hb.ModelHashPresent &&
             priorLoadingState &&
             hb.LoadingPresent && !hb.Loading

     The gate per R-7.1.6 is "prior loading:true AND current
     SPEC-011 PATH heartbeat is post-swap". "Post-swap" = current
     loading:false on a heartbeat that carries model_hash. This is
     the exact condition above.

  h. If `swapCompleted` AND `r.swapEmitter != nil`, build the
     event and call the emitter:

         if swapCompleted && r.swapEmitter != nil {
             event := SwapEvent{
                 ProviderID:             p.ProviderID,
                 AssignedID:             p.AssignedID,
                 FromModelID:            priorModelID,
                 FromModelHash:          priorModelHash,
                 ToModelID:              p.ModelID,
                 ToModelHash:            p.ModelHash,
                 HashVerificationResult: p.HashStatus,
                 LoadingStartedAt:       priorLoadingStartedAt,
                 CompletedAt:            hb.At,
             }
             r.swapEmitter(event)
         }

     The emitter call happens INSIDE the mutex hold. This is
     intentional: it preserves atomicity of the prior-state read
     against the emit. The emitter callback MUST NOT block for
     long (2E's SQLite write is fast; 2E will document this).

  i. Build and return the snapshot copy (unchanged from the
     existing function tail).

**5. Path selection is per-heartbeat, NOT sticky.** R-7.1 prose
and AC-K.8 explicitly forbid sticky path inference. A SPEC-011
binary that emits model_hash in heartbeat #1, omits it in
heartbeat #2, and re-includes it in heartbeat #3 MUST get path
dispatch per-frame: SPEC-011, LEGACY, SPEC-011 (not all SPEC-011
because frame #1 set a sticky bit). Test
`TestApplyHeartbeatPathSelectionIsPerHeartbeatNotSticky` MUST
prove this with the exact frame interleaving.

**6. LoadingStartedAt write rule (R-7.10.6).** The first observed
heartbeat with `loading:true` (transitioning from false) stamps
`LoadingStartedAt`. Subsequent `loading:true` heartbeats do NOT
re-stamp. The transition rule applies on EITHER path (LEGACY or
SPEC-011) per R-7.10.6's "LEGACY-or-SPEC-011-PATH" wording — but
note that a LEGACY-path binary will never emit `loading:true`
because the binary side only emits `loading` when warm-swap is
enabled (which also enables model_hash). The test pins the rule
anyway to defend against future binary-side regressions.

**7. SwapEmitter timing — emit AFTER all field writes complete.**
The emitter call MUST happen after the full Provider state update
is done (capacity, state, slots, hash, LastLoadingState) so the
returned snapshot reflects the post-swap state if 2E later reads
the Provider via Registry from inside the emitter callback. Place
the emitter call IMMEDIATELY before the snapshot copy and return.

**8. No new metrics or log lines.** R-7.9.8's "no metric"
discipline applies here too — Phase 2C ships data flow only, no
observability counters. 2E adds the audit-log write, and the
SQLite write itself is the observability signal.

**9. handleHeartbeat in server.go.** Update the call site at
server.go:1299 to thread presence + new fields through:

    hb, presence, field, err := ParseHeartbeat(payload)
    ...
    entry, gap, ok := s.pool.ApplyHeartbeat(providerID, assignedID, pool.HeartbeatUpdate{
        Status:                state,
        ModelID:               hb.ModelID,
        ModelParamsB:          hb.ModelParamsB,
        ... existing fields ...,
        ThroughputTPSEstimate: hb.ThroughputTPSEstimate,
        ModelHash:             hb.ModelHash,
        ModelHashPresent:      presence.ModelHash,
        Loading:               hb.Loading,
        LoadingPresent:        presence.Loading,
        At:                    s.now(),
    })

And inject the verifier at Registry construction. Find where the
Registry is built in production code (NOT in tests) — likely in
`cmd/coordinator/main.go` or wherever the wiring happens — and add
`pool.WithHeartbeatHashVerifier(tier2.VerifyProviderHash)` as an
option. Grep `NewRegistry(` to find the wiring path. If the
production wiring is in a file outside the edit budget (e.g.,
cmd/coordinator/), STOP and report — the prompt's edit budget
needs adjustment, not a silent fork.

If the production Registry is constructed inside `server.go`,
inject the option there. Most likely the wiring is in
`NewServer` or in a startup helper.

**10. Backward-compatible test signatures.** Existing tests in
`provider_test.go` call `ApplyHeartbeat` with the 3-return form
and the legacy `HeartbeatUpdate` shape (no ModelHash/Loading
fields). They MUST continue to pass UNCHANGED — your edits to
`HeartbeatUpdate` are field-additive (struct literal with new
fields zeroed by default is fine), and `ApplyHeartbeat`'s
signature is unchanged (3 returns). Run the existing pool tests
EARLY in your work and confirm zero regressions before adding new
tests.

**11. `gofmt -l ./internal/...` and `go vet ./...` MUST be clean.**
`go test -race -count=1 ./internal/...` MUST be clean — this is
the Phase 2B R3 bar, preserved.

**12. No spec edits, no handoff-doc edits, no
DECISION_CRITERIA edits, no BUILD/AUDIT prompt edits.** Verify
with `git diff specs/ beta/` — empty.

## Required reading (in this order)

1. `specs/SPEC-002-coordinator.md` lines 1972-2056 (§7.1
   heartbeat field extension + ApplyHeartbeat REPLACEMENT) and
   lines 3648-3679 (AC-K.6 / AC-K.7 / AC-K.8 / AC-K.9). These
   are binding.
2. `specs/SPEC-011-operator-pushed-warm-swap.md` v0.5 §3.3 R-3.3.0
   through R-3.3.5 (heartbeat extension), §3.5 R-3.5.2 / R-3.5.3
   (hash re-verification), §3.6 R-3.6.3 (loading_window_ms — 2E
   computes; 2C only stamps the start timestamp), §6.2 D2.1 fix
   (the LEGACY / SPEC-011 split rationale).
3. `phase4-coordinator/internal/pool/provider.go:411-444` (the
   current ApplyHeartbeat — the REPLACEMENT target).
4. `phase4-coordinator/internal/pool/provider.go:50-101` (the
   Phase 2A Provider struct — the write targets).
5. `phase4-coordinator/internal/ws/messages.go:128-142`
   (Heartbeat struct) and `:534-585` (current ParseHeartbeat —
   the extension target).
6. `phase4-coordinator/internal/ws/server.go:1299-1330`
   (handleHeartbeat — the production caller).
7. `phase4-coordinator/internal/tier2/catalog.go:335-359`
   (VerifyProviderHash — the verifier you inject as the
   production HeartbeatHashVerifier). DO NOT edit this file;
   only read.
8. Phase 2A commit (`git show de41380 --stat`) and Phase 2B
   commits (`git show 11bf449 83540b1 c739055 --stat`). 2C
   touches neither auth_attempts.go nor the v2 auth path.

## Required tests (verbatim names — these are the AC oracles)

Place pool-level tests in `provider_test.go`, parser tests in
`messages_test.go`, end-to-end heartbeat tests in `server_test.go`.

### `provider_test.go`

  `TestApplyHeartbeatL1ByteIdenticalLegacyPath` — heartbeat
    without ModelHashPresent + without LoadingPresent; ModelID
    unchanged. Assert: Provider.ModelHash unchanged,
    Provider.HashStatus unchanged, Provider.LastLoadingState
    false, Provider.LoadingStartedAt zero. Then send a second
    heartbeat with ModelID changed: assert Provider.ModelHash
    cleared to "", Provider.HashStatus == HashStatusUncatalogued.

  `TestApplyHeartbeatSPEC011PathUpdatesHashOnModelIDChange` —
    inject a verifier returning HashStatusVerified. Send
    heartbeat with ModelHashPresent + ModelHash="ab12...", ModelID
    changed. Assert: Provider.ModelHash == new value (NOT cleared),
    Provider.HashStatus == HashStatusVerified.

  `TestApplyHeartbeatSPEC011PathReVerifiesOnHashChangeSameModelID`
    — same model_id, different model_hash. Verifier returns
    HashStatusMismatch. Assert: Provider.ModelHash updated,
    Provider.HashStatus == HashStatusMismatch.

  `TestApplyHeartbeatSPEC011PathNoChangeWhenBothModelIDAndHashUnchanged`
    — assert no verifier call, no HashStatus mutation.

  `TestApplyHeartbeatPathSelectionIsPerHeartbeatNotSticky` —
    AC-K.8. Frame #1: SPEC-011 (ModelHashPresent=true). Frame #2:
    LEGACY (ModelHashPresent=false), ModelID changed. Assert
    Frame #2 takes the LEGACY clear path (Provider.ModelHash
    cleared, HashStatus = HashStatusUncatalogued) regardless of
    Frame #1's path.

  `TestApplyHeartbeatLoadingStartedAtStampedOnFalseToTrueTransition`
    — Frame #1 with Loading=true (LoadingPresent=true), prior
    LastLoadingState=false. Assert LoadingStartedAt == frame #1's
    `At`. Frame #2 with Loading=true again — assert
    LoadingStartedAt UNCHANGED (no re-stamp).

  `TestApplyHeartbeatLastLoadingStateTracksPerHeartbeat` —
    Loading transitions: false→true→true→false→false. Assert
    Provider.LastLoadingState matches the most recent frame's
    Loading value.

  `TestApplyHeartbeatLoadingAbsentLeavesStateUntouched` — L-1
    invariant. LoadingPresent=false; assert
    Provider.LastLoadingState and Provider.LoadingStartedAt
    remain at zero across N heartbeats.

  `TestApplyHeartbeatSwapEmitterFiresOnPostSwapTransition` —
    inject a recording emitter. Frame #1: ModelHashPresent +
    Loading=true. Frame #2: ModelHashPresent + Loading=false +
    ModelID changed + new hash. Assert emitter was called once
    with SwapEvent containing the correct from/to model_id +
    from/to model_hash + the prior LoadingStartedAt + Frame #2's
    `At` as CompletedAt + the hash verification result.

  `TestApplyHeartbeatSwapEmitterDoesNotFireOnLegacyPath` —
    Frame #1: LEGACY + Loading=true (binary-side bug — shouldn't
    happen in practice, but defends against forgery). Frame #2:
    LEGACY + Loading=false. Assert emitter NOT called (R-7.1.6
    gates emission to SPEC-011 PATH).

  `TestApplyHeartbeatSwapEmitterDoesNotFireWhenNoPriorLoading` —
    Frame #1: SPEC-011 + Loading=false (first frame on a new
    session, no prior loading). Frame #2: SPEC-011 + Loading=false
    + ModelID changed. Assert emitter NOT called (R-7.10.10 WS-
    drop case: no prior `loading: true` on this session).

  `TestApplyHeartbeatSwapEmitterNilDoesNotCrash` — emitter never
    set; trigger the swap-complete transition; assert no panic.

### `messages_test.go`

  `TestParseHeartbeatL1AcceptsLegacyAbsentSPEC011Fields` — frame
    without `model_hash` or `loading`. Assert returned
    HeartbeatPresence == {false, false}, hb.ModelHash == "",
    hb.Loading == false.

  `TestParseHeartbeatAcceptsSPEC011Fields` — frame with
    `model_hash: "ab12..." (64-char lowercase hex)` and
    `loading: true`. Assert HeartbeatPresence == {true, true},
    fields populated.

  `TestParseHeartbeatRejectsModelHashWrongType` — `model_hash:
    123` (int instead of string). Assert badField == "model_hash"
    with error.

  `TestParseHeartbeatRejectsLoadingWrongType` — `loading:
    "yes"` (string instead of bool). Assert badField == "loading"
    with error.

  Existing `TestParseHeartbeatPreservesRollingMetrics` MUST
  continue to pass unchanged (the new return value will need a
  small test edit — add the empty Presence{} return capture).

### `server_test.go`

  `TestHeartbeatLegacyPathPreservesV134Behavior` — register a
    provider via the v2 auth path with NO SPEC-010 fields (L-1
    baseline from Phase 2B). Send a heartbeat that omits
    model_hash + loading. Assert via `eventually` that the
    Provider snapshot has zero LastLoadingState + zero
    LoadingStartedAt. Then send a heartbeat with a different
    model_id (still no model_hash). Assert Provider.ModelHash
    == "" and Provider.HashStatus == HashStatusUncatalogued.

  `TestHeartbeatSPEC011PathInvokesVerifier` — register provider,
    send heartbeat with model_hash + loading. The production
    wiring uses tier2.VerifyProviderHash which depends on a
    catalog; without a catalog the verifier returns
    HashStatusUncatalogued. Assert Provider.ModelHash is the
    sent value (NOT cleared), Provider.HashStatus ==
    HashStatusUncatalogued (verifier's return).

  `TestHeartbeatSwapCompletionFiresInjectedEmitter` —
    construct a test server with an emitter injected via the
    Server's Registry construction. Register, send heartbeat
    with loading=true + model_hash, then send heartbeat with
    loading=false + new model_id + new model_hash. Assert
    emitter was called exactly once with the correct SwapEvent.

If the production server wiring doesn't allow injecting a custom
emitter for tests, add a server Option `WithRegistryOptions(opts
...pool.RegistryOption) Option` that threads through to the
underlying NewRegistry call. Document it as test-facing with the
same discipline as `WithAuthAttemptRetentionBound` from Phase 2B.

## Done criteria

1. `go build ./...` exits 0.
2. `go vet ./...` exits 0 with no output.
3. `gofmt -l ./internal/...` produces empty output.
4. `go test -race -count=1 ./internal/pool/...` passes (existing
   ApplyHeartbeat tests + 12 new ones).
5. `go test -race -count=1 ./internal/ws/...` passes (existing
   tests + 3 new heartbeat end-to-end tests).
6. `git diff --name-only HEAD` lists exactly the 6 files in the
   edit budget. Plus the unstaged `beta/DECISION_CRITERIA.md`
   from the prior session — DO NOT stage.

## Out of scope (do NOT do in this phase)

- Editing `/v1/status` (Phase 2D).
- Creating `internal/audit/` package (Phase 2E).
- Implementing the operator_model_swap payload schema, F-1.5
  invariants enforcement, or SQLite write — those are 2E.
- Resetting LastLoadingState after swap emission — that's 2E's
  responsibility because the emitter callback (which Phase 2E
  registers) is what decides "emission succeeded" and only then
  should LastLoadingState reset. Phase 2C's design is: 2C
  detects the transition and calls the emitter; 2E's emitter
  handles SQLite write + LastLoadingState reset.
- Touching `Provider.SupportedModels` / `PublishesSupportedModels`
  in ApplyHeartbeat — those are set by Phase 2B at auth time and
  remain stable across heartbeats.
- Touching the legacy `hello` parser (`parseHello` /
  `ParseHello`).
- Adding new close codes or close-code registry constants.
- Changing the existing v2 auth handshake path
  (auth_attempts.go is OFF LIMITS for this phase).

## Self-check before reporting done

Run, in order, from /Users/augstar/macprovider-poc/phase4-coordinator,
and paste each output back:

    go build ./...
    go vet ./...
    gofmt -l ./internal/...
    go test -race -count=1 ./internal/pool/... | tail -10
    go test -race -count=1 -v -run TestApplyHeartbeat ./internal/pool/... | tail -60
    go test -race -count=1 -v -run TestParseHeartbeat ./internal/ws/... | tail -30
    go test -race -count=1 -v -run TestHeartbeat ./internal/ws/... | tail -40
    go test -race -count=1 ./internal/ws/... | tail -5
    cd /Users/augstar/macprovider-poc
    git diff --name-only HEAD
    git diff specs/ beta/ phase3-binary/ phase5-gateway/

The last `git diff` MUST produce empty output. If any earlier
command fails, do NOT report done.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- 2C is the riskiest phase per the handoff. Plan for an R2 round.
  The areas where I expect Codex to drift:
  - **Path-selection logic ordering.** R-7.1.3 / R-7.1.4 use
    field PRESENCE on the heartbeat as the gate, NOT field VALUE
    or prior state. Codex may try to combine ModelHashPresent
    with `hb.ModelHash != ""` (defensive double-check), which
    breaks the AC-K.8 per-heartbeat semantic if an empty model_hash
    is sent legitimately.
  - **Hash re-verification ordering.** The LEGACY clear MUST happen
    BEFORE the SPEC-011 update, so a SPEC-011 frame following a
    LEGACY-cleared state correctly re-populates. The current
    locked v1.3.4 code already has the right ordering; the
    REPLACEMENT must preserve it.
  - **SwapEvent payload completeness.** The from_model_id and
    from_model_hash must come from the PRIOR snapshot, not the
    post-update fields. Codex may accidentally use `p.ModelID`
    (post-update) instead of `priorModelID`.
  - **LoadingStartedAt zero on absent loading.** L-1 invariant —
    a heartbeat without LoadingPresent MUST NOT touch
    LoadingStartedAt. This is easy to break by mistakenly running
    the transition block unconditionally.
- After 2C lands, dispatch the Phase 2C mid-stream audit (model
  after `AUDIT_SPEC_002_v1_3_5_IMPL_PHASES_2A_2B_PROMPT.md` but
  scoped to commit-2C only). Given the locked-code-path
  semantics change, an external audit is a NON-NEGOTIABLE gate.
- After 2C R2 closes, proceed to 2D ( `/v1/status` echo) and
  2E (audit-log + emission wire).

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7) for the SPEC-002 v1.3.5 Phase 2 implementation.
