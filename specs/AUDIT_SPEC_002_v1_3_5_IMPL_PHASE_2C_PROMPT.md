# Mid-stream audit prompt — SPEC-002 v1.3.5 Phase 2C

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**code / security / architecture review** of commit `b43e7c8` on
branch `fix/spec-002-v1-3-5-coordinator`. Phase 2C REPLACES the
semantics of a locked code path at
`phase4-coordinator/internal/pool/provider.go:411-432` with the §7.1
two-path dispatch and maintains the Phase 2A
`LastLoadingState` / `LoadingStartedAt` fields per heartbeat.

The Phase 2C BUILD prompt
(`specs/BUILD_SPEC_002_v1_3_5_IMPL_PHASE_2C_PROMPT.md`) called this
the **riskiest phase** of the five. The R1 / R2 / R2V cycle for
Phase 2B caught 6 findings (1 CRITICAL, 3 MAJOR, 2 MINOR) — this
audit holds Phase 2C to the same bar. Money-path code (heartbeats
gate billing eligibility) — adversarial review is non-negotiable.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~25-40 min.
This is a **read-only** review — Codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial mid-stream review of commit
`b43e7c8` on branch `fix/spec-002-v1-3-5-coordinator` in
/Users/augstar/macprovider-poc. This commit is Phase 2C of SPEC-002
v1.3.5 and REPLACES the semantics of a locked code path. Phases 2D
+ 2E are NOT landed yet — your scope is exclusively Phase 2C.

This is a **read-only review**. You MUST NOT edit any file.

## Context

Branch state:
- de41380 (2A): Provider data-model extension
- 11bf449 (2B): v2 auth_request SPEC-010 + retention lifecycle
- 83540b1 (R2): close 2B audit findings
- c739055 (R3): close 2B R2V finding (exact-match catalog gate)
- b43e7c8 (2C): **THIS commit — under audit**

Phase 2C ships:
- Heartbeat + ParseHeartbeat extended with optional `model_hash`
  + `loading` + presence flags
- HeartbeatUpdate field-additive (ModelHash, ModelHashPresent,
  Loading, LoadingPresent)
- New types: HeartbeatHashVerifier, SwapEvent, SwapEventEmitter,
  RegistryOption + 3 functional-option setters
- ApplyHeartbeat body REPLACED with two-path dispatch keyed PER-
  HEARTBEAT on `hb.ModelHashPresent` (LEGACY clear / SPEC-011
  re-verify)
- Provider.LastLoadingState + Provider.LoadingStartedAt
  maintenance per heartbeat (gated on hb.LoadingPresent)
- SwapEventEmitter callback hook fired on R-7.1.6 swap-completion
  transition; Phase 2E will register the SQLite writer
- handleHeartbeat threaded with presence flags
- NewServer auto-installs tier2.VerifyProviderHash on the
  Registry so production stays correct by default

The coordinator's threat model is unchanged from the 2A+2B audit:
- Operator binaries: SEMI-trusted (token-authenticated for pinned;
  rate-limited for provisional)
- Buyers (HTTP side): UNTRUSTED — but 2C touches no buyer path
- Adversary model: a malicious or buggy provider binary that
  controls every byte of every heartbeat frame

This is money-path code. An accepted heartbeat contributes to
billing eligibility. A misclassified hash, a swap event that fires
when it shouldn't (or doesn't fire when it should), a buyer routed
to a stale model — all have real USDC blast radius.

## Required reading (in this order)

1. The commit via `git show b43e7c8`. Read the FULL diff.

2. The BUILD prompt that produced the code:
   - `specs/BUILD_SPEC_002_v1_3_5_IMPL_PHASE_2C_PROMPT.md`

3. The locked spec (READ-ONLY, do not edit):
   - `specs/SPEC-002-coordinator.md` v1.3.5 — §3.X (Provider data
     model, lines 305-378), §7.1 (heartbeat extension +
     ApplyHeartbeat REPLACEMENT, lines 1972-2056), §11 AC-K.6 /
     AC-K.7 / AC-K.8 / AC-K.9 (lines 3648-3679). The
     LEGACY-vs-SPEC-011 split rationale is at SPEC-011 v0.5 §6.2
     D2.1.
   - `specs/SPEC-011-operator-pushed-warm-swap.md` v0.5 §3.3
     R-3.3.0 through R-3.3.5 (heartbeat extension), §3.5 R-3.5.2
     / R-3.5.3 (hash re-verification), §3.6 R-3.6.3
     (loading_window_ms semantics), §3.6 R-3.6.6 (conditional
     emission per AC-K.12).
   - `specs/SPEC-001-phase3-binary.md` v1.3 §6.7.3 cell 1 (L-1
     baseline contract).

4. The implementation files:
   - `phase4-coordinator/internal/pool/provider.go` (the
     REPLACEMENT target + new types + 2 new options)
   - `phase4-coordinator/internal/pool/provider_test.go` (12 new
     ApplyHeartbeat tests)
   - `phase4-coordinator/internal/ws/messages.go` (Heartbeat +
     ParseHeartbeat extension)
   - `phase4-coordinator/internal/ws/messages_test.go` (4 new
     parser tests)
   - `phase4-coordinator/internal/ws/server.go` (handleHeartbeat
     threading + WithRegistryOptions + auto-install of verifier)
   - `phase4-coordinator/internal/ws/server_test.go` (3 new end-
     to-end heartbeat tests)

5. The verifier callee (READ-ONLY):
   - `phase4-coordinator/internal/tier2/catalog.go:335-359`
     (VerifyProviderHash) — Phase 2C invokes this; 2C does NOT
     edit it.

DO NOT inspect any file under `phase3-binary/.build/checkouts/` or
any third-party clean-room code per the CLAUDE.md rule.

## Three review dimensions

### Dimension 1: CODE REVIEW

Focus areas — be especially adversarial on these because 2C is the
riskiest phase:

- **L-1 byte-identical default (the core non-negotiable invariant).**
  A heartbeat without `model_hash` AND without `loading` MUST
  produce, after this commit, byte-identical Provider state to
  what v1.3.4 produced. Verify by reading the ApplyHeartbeat body:
    - When `hb.ModelHashPresent == false`: the only state mutation
      should be the existing LEGACY clear-on-model-id-change
      behavior. Anything else (a stray write to ModelHash,
      HashStatus, LastLoadingState, LoadingStartedAt) is a CRITICAL
      L-1 regression.
    - When `hb.LoadingPresent == false`: LastLoadingState AND
      LoadingStartedAt MUST remain untouched.
    - The `swapCompleted` gate MUST require `hb.ModelHashPresent`
      AND `priorLoadingState` AND `hb.LoadingPresent` AND
      `!hb.Loading`. If any of these can be elided in any code
      path, the emitter fires for an L-1 frame — CRITICAL.
- **AC-K.6 LEGACY PATH semantics.** R-7.1.3 says: heartbeat lacks
  model_hash + model_id changed → clear ModelHash, set HashStatus
  = HashStatusUncatalogued. Verify the new code preserves this
  exactly. Watch for: `strings.EqualFold` vs `==` (the v1.3.4
  code used EqualFold for case-insensitive matching per
  SPEC-002 §11 D9; verify the new code preserves this).
- **AC-K.7 SPEC-011 PATH semantics.** R-7.1.4 / R-7.1.5: heartbeat
  has model_hash + model_id changed → update ModelHash, run Pillar
  A verifier, populate HashStatus from result. Verify:
    - The verifier is invoked with `(hb.ModelID, hb.ModelHash)`,
      NOT `(p.ModelID, hb.ModelHash)` (after the assignment,
      p.ModelID is the new value; before, it's the old). Read the
      ApplyHeartbeat body — is the verifier called BEFORE or AFTER
      `p.ModelID = hb.ModelID`?
    - The hash UPDATE happens regardless of whether the verifier
      returns hash_verified, hash_mismatch, hash_invalid, etc.
      That is: even on hash_mismatch, ModelHash is set to the new
      (mismatched) value. Verify this is intentional per
      SPEC-011 R-3.5.3 (the verifier result is informational; the
      reported hash is what's stored).
- **AC-K.8 per-heartbeat path selection (no stickiness).** Verify
  the dispatch gate is *only* `hb.ModelHashPresent` and nothing
  else. A defensive `&& hb.ModelHash != ""` would break the
  contract if a binary legitimately sends an empty hash with
  presence=true (though that's a binary-side bug). Confirm the
  test `TestApplyHeartbeatPathSelectionIsPerHeartbeatNotSticky`
  actually exercises a SPEC-011→LEGACY→SPEC-011 sequence and
  asserts the LEGACY behavior on frame 2.
- **AC-K.9 exactly-once emission gate.** The swapCompleted boolean
  fires the emitter. Verify:
    - The gate is `hb.ModelHashPresent && priorLoadingState &&
      hb.LoadingPresent && !hb.Loading`. NOT `priorLoadingState &&
      !p.LastLoadingState` (which would be a post-update read).
    - LastLoadingState is updated BEFORE the swap check is
      computed — verify the read of `priorLoadingState` is from the
      captured prior state, not from `p.LastLoadingState` post-
      update.
    - There is NO sticky-reset logic in 2C — Phase 2E owns the
      LastLoadingState reset semantics per R-7.1.6. Confirm 2C
      neither does nor blocks the reset.
- **SwapEvent payload correctness.**
    - FromModelID == priorModelID (NOT p.ModelID — that's been
      overwritten).
    - FromModelHash == priorModelHash (NOT p.ModelHash — same).
    - ToModelID == p.ModelID (post-update is correct).
    - ToModelHash == p.ModelHash (post-update is correct).
    - HashVerificationResult == p.HashStatus (post-update).
    - LoadingStartedAt == priorLoadingStartedAt (NOT
      p.LoadingStartedAt — though 2C never resets
      LoadingStartedAt, so they're equal here; verify the prior
      capture is correct anyway).
    - CompletedAt == hb.At.
    Read each line of the SwapEvent struct literal and verify.
- **LoadingStartedAt write rule (R-7.10.6).** Stamped on
  false→true transition only. Verify:
    - The condition is `!priorLoadingState && hb.Loading` — gated
      by `hb.LoadingPresent`.
    - Subsequent loading:true heartbeats do NOT re-stamp (because
      priorLoadingState is now true).
    - true→false transition does NOT clear LoadingStartedAt (2E
      reads it for loading_window_ms; clearing here would lose
      data).
- **Concurrency: emitter held under mutex.** The emitter callback
  is invoked while r.mu is held. Verify:
    - The emitter MUST NOT call back into Registry methods that
      would re-acquire r.mu (deadlock). For Phase 2C, the emitter
      is nil in production wiring; tests use a recording emitter
      that just appends to a slice. For Phase 2E, the emitter will
      write to SQLite — verify the BUILD prompt's documented
      "MUST NOT block for long" contract is captured in a comment
      on the SwapEventEmitter type.
    - If a panic in the emitter would crash the heartbeat handler
      and drop the WS, is that desired? Probably yes (loud failure
      > silent corruption), but flag if you have a different view.
- **NewServer verifier auto-install.** server.go ~149 calls
  `pool.WithHeartbeatHashVerifier(tier2.VerifyProviderHash)(registry)`
  on a non-nil registry. Verify:
    - The nil-check on `registry` is correct — does any production
      path pass nil? `NewServer` is called from `cmd/coordinator/`
      with a real registry. Tests construct via `newProviderServer`
      which threads a non-nil registry.
    - The verifier is applied BEFORE the `for _, opt := range opts`
      loop — so a test that uses `WithRegistryOptions` to inject
      a custom verifier OVERRIDES the auto-install. Verify this
      ordering matches the design intent.
- **Parser optional-field placement.** ParseHeartbeat: the
  optional `model_hash` / `loading` block runs AFTER all required
  fields parse. Verify:
    - A frame with required fields all present but with
      `model_hash: 123` (int instead of string) gets badField =
      "model_hash" — verifier-style error message.
    - The legacy v1.3.4 ParseHeartbeat behavior is preserved for
      frames that omit the new fields entirely.
- **Existing test regression check.** Run
  `go test -race -count=1 ./internal/...` (you may run go test;
  you MUST NOT modify any file). The full coordinator suite MUST
  pass.

Findings format:
```
[code:N.M] [SEVERITY] <short title>
  File: <path>:<line>
  What: <one-paragraph description of the issue>
  Why: <impact — what breaks, when, and how bad>
  Fix: <suggested remediation; cite the binding spec rule>
```

### Dimension 2: SECURITY REVIEW

Threat model: a malicious provider binary controls every byte of
every heartbeat frame. The binary may:
- Lie about ModelID
- Lie about model_hash (claim hash_verified when the actual model
  weights differ)
- Omit `loading` when actually loading
- Send `loading: true` repeatedly without ever sending `loading:
  false` (DoS via never-completing swap)
- Send `loading: false` with a never-set LoadingStartedAt (forge
  a zero loading_window_ms)
- Fire spurious swap events to pollute the audit log

Focus areas:

- **Heartbeat-driven hash status escalation.** Can a malicious
  binary trick the coordinator into setting HashStatus =
  HashStatusVerified when the binary should be HashStatusMismatch?
  The Pillar A verifier is the only source of truth — it consults
  the locked catalog. If the binary sends model_hash = (the
  catalog's expected hash for ModelID-X) but the actual served
  weights are different, the verifier still returns hash_verified
  (it can't verify the weights, only the claimed hash). Is this a
  Phase 2C bug or an inherent limitation? (Likely the latter, but
  flag if the Phase 2C wiring makes it worse.)
- **SwapEvent forgery / amplification.** A malicious binary that
  alternates loading:true and loading:false rapidly could spam the
  audit log when Phase 2E hooks the emitter. Phase 2C has no rate
  limit on swap-event emission. Should 2C add a per-provider rate
  limit, or defer to 2E? (Probably defer — 2E owns the audit-log
  write semantics — but flag if 2C's design forecloses 2E's
  options.)
- **LoadingStartedAt forgery.** The binary doesn't directly
  control LoadingStartedAt — the coordinator stamps it from
  `hb.At` (which IS `s.now()`, NOT a binary-supplied timestamp,
  per server.go ~1336). Verify this is the case — if hb.At ever
  derived from a binary-supplied field, the binary could forge
  arbitrarily small or negative loading_window_ms values.
- **Verifier crash propagation.** The injected verifier
  (tier2.VerifyProviderHash) is called inside the mutex hold. If
  the verifier panics, the deferred unlock fires, but the
  panic propagates up the heartbeat handler and crashes the
  goroutine. Is this acceptable? Phase 2C doesn't recover panics
  inside ApplyHeartbeat — neither does v1.3.4. Confirm symmetry.
- **Path-confusion via case-folded ModelID.** The code uses
  `strings.EqualFold` to compare model IDs. A binary that sends
  `MODEL-A` then `model-a` then `MODEL-A` would NOT trigger
  modelIDChanged on either heartbeat 2 or 3 (per EqualFold). Is
  this the L-1 expected behavior or a regression? Read v1.3.4's
  original code at the same line — was EqualFold there too?
  (Yes — it's preserved verbatim — but confirm.)

Findings format:
```
[sec:N.M] [SEVERITY] <short title>
  Asset: <what's at risk>
  Vector: <how a malicious provider binary exploits it>
  File: <path>:<line>
  Fix: <suggested remediation>
```

### Dimension 3: ARCHITECTURE REVIEW

Focus areas:

- **Decoupling pool from tier2.** The HeartbeatHashVerifier
  callback decouples the pool package from tier2. NewServer
  auto-installs `tier2.VerifyProviderHash` as the production
  verifier. Is this the right place for the wiring, or should
  cmd/coordinator (the main entry) install it? Trade-off:
  NewServer-installed = production-safe-by-default; main-
  installed = explicit + testable but burdens every caller.
- **Variadic options on NewRegistry.** Adding `...RegistryOption`
  is field-additive for callers but creates a small API surface.
  Are there existing callers in cmd/coordinator that should also
  use the new options pattern (e.g., for the swap emitter that 2E
  will register)?
- **WithRegistryOptions on Server.** This Option threads pool-
  level options through the Server. Is the naming clear? A
  reader seeing `WithRegistryOptions(pool.WithSwapEmitter(...))`
  in test code understands the indirection; a production caller
  using `WithRegistryOptions(pool.WithHeartbeatHashVerifier(...))`
  would be redundant with the auto-install — is that documented?
- **SwapEvent struct shape.** The struct carries ProviderID +
  AssignedID + all hash/model fields. Phase 2E will build the
  operator_model_swap payload from this. Verify the SwapEvent has
  ENOUGH fields for 2E's R-7.10.4 / R-7.10.5 / R-7.10.6 / R-7.10.7
  payload requirements:
    - provider_assigned_id (R-7.10.5): yes, AssignedID
    - from_model_id, to_model_id: yes
    - from_model_hash (OPTIONAL): yes
    - to_model_hash (REQUIRED): yes
    - loading_window_ms: 2E will compute from LoadingStartedAt +
      CompletedAt. SwapEvent carries both — sufficient.
    - hash_verification_result (REQUIRED): yes,
      HashVerificationResult
    - ts (REQUIRED): 2E can derive from CompletedAt — sufficient.
    - drain_inflight_count_estimate (OPTIONAL): NOT in SwapEvent.
      Will 2E compute this from elsewhere, or is this a gap? Flag.
- **Test architecture growth.** `provider_test.go` grew by 273
  lines. Are the new tests organized by AC or by behavior? Are
  there fixtures / helpers that could be shared across the 12
  ApplyHeartbeat tests? (Pragmatism over purity — tight tests
  with some duplication beat clever indirection — but flag if you
  see a pattern that could become a fixture.)
- **Locked-code-path REPLACEMENT documentation.** The commit
  message documents the change but the code itself uses inline
  comments per spec rule. Are the spec citations in code comments
  sufficient for a future maintainer to understand WHY the dispatch
  is shaped this way? Compare to the Phase 2B comment density.

Findings format:
```
[arch:N.M] [SEVERITY] <short title>
  What: <description>
  Trade-off: <what's gained vs lost>
  Suggestion: <concrete refactor or follow-up>
```

## Severity scale (same as 2A/2B audit)

- **CRITICAL** — must be fixed before Phase 2D begins. Breaks an
  L-1 byte-identical invariant, breaks an AC-K acceptance
  criterion, creates an exploitable hole, OR forecloses Phase 2E's
  emission contract (e.g., SwapEvent missing a R-7.10.4 REQUIRED
  field with no recovery path).
- **MAJOR** — should be fixed before merge. Real bug, real impact,
  not on the critical path.
- **MINOR** — would improve the code; does not block 2D.

## Output format

```
# SPEC-002 v1.3.5 Phase 2C mid-stream audit — Codex GPT-5

## Verdict

<one-line: PROCEED-TO-2D | FIX-THEN-PROCEED | BLOCK>

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
| AC-K.6 (LEGACY PATH) | <file:line> | <test> |
| AC-K.7 (SPEC-011 PATH) | <file:line> | <test> |
| AC-K.8 (per-heartbeat path selection) | <file:line> | <test> |
| AC-K.9 (exactly-once emission) | <file:line> | <test (2C portion); 2E owns full closure> |

## Build / vet / race / suite evidence

Paste outputs from:
  cd /Users/augstar/macprovider-poc/phase4-coordinator
  go build ./...
  go vet ./...
  gofmt -l ./internal/
  go test -race -count=1 ./internal/pool/...
  go test -race -count=1 ./internal/ws/...

## Cross-cutting observations

<any patterns spanning multiple findings>
```

## Discipline

- CRITICAL must describe the concrete failure mode in one sentence.
- L-1 byte-identical violations are CRITICAL by default — no
  hedging.
- A SwapEvent payload completeness gap that forces a 2E hack is
  CRITICAL.
- Cite file:line + binding spec rule for every finding.
- Zero findings is a valid result. Don't pad.

You may run shell commands (git log, grep, go build/vet/test
including -race). You MUST NOT modify any file.

You may take up to 40 minutes wall-clock.

=== END PROMPT ===
```

---

## Operator notes

- 2C audit bar: CRITICAL for L-1 violations, AC-K breaches, or
  Phase-2E foreclosures. The MAJORs from Phase 2B's audit (empty-
  array gap, race-broken helper) had the same severity even though
  they weren't show-stoppers — keep the bar consistent.
- Expected outcome: at minimum a few MINORs (SwapEvent
  `drain_inflight_count_estimate` is an OPTIONAL R-7.10.4 field
  not in the current SwapEvent — likely flagged as MINOR
  arch).
- If CRITICAL, draft R2 prompt; otherwise proceed to 2D.

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7) for the SPEC-002 v1.3.5 Phase 2 implementation.
