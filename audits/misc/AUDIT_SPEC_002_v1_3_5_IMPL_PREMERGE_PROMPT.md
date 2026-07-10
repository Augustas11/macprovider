# Pre-merge audit prompt — SPEC-002 v1.3.5 Phase 2A-2E full-branch review

Operator-paste prompt for Codex GPT-5 to perform an end-to-end
**code / security / architecture review** of branch
`fix/spec-002-v1-3-5-coordinator` (12 commits ahead of main) BEFORE
squash-merge to main. This is the **non-negotiable gate** per the
handoff §4.3 methodology — the per-phase mid-stream audits caught
3 substantive defects that inline review missed; this broader pass
catches cross-phase interactions and surface drift that per-phase
audits couldn't see.

Modeled after PR #5's
[`AUDIT_SPEC_001_v1_3_IMPL_PR5_PROMPT.md`](AUDIT_SPEC_001_v1_3_IMPL_PR5_PROMPT.md)
but scaled for ~3500 LOC and a cross-codebase surface
(phase4-coordinator + phase5-gateway).

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~60-90 min.
This is a **read-only review** — Codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial pre-merge review of branch
`fix/spec-002-v1-3-5-coordinator` in the Augustas11/macprovider
repository (already checked out at /Users/augstar/macprovider-poc).
The branch ships SPEC-002 v1.3.5 across five implementation phases
(2A-2E) plus their R2 + R2V audit-fix commits, for a total of 12
commits / ~3500 LOC vs main (5d4f69d).

This is the **external adversarial pass** that complements the
per-phase Claude inline audits and the per-phase Codex mid-stream
audits. Your scope is wider: cross-phase interactions, cross-
codebase coupling, and any drift the narrower audits couldn't see.

This is a **read-only review**. You MUST NOT edit any file,
commit, push, or modify the git state. Your only output is the
structured findings report at the end.

## Context

The branch implements SPEC-002 v1.3.5 — the coordinator-side
absorption of SPEC-010 v1.5 (provider model catalog) + SPEC-011
v0.5 (operator-pushed warm swap) + SPEC-001 v1.3 (binary-side,
shipped in PR #5).

The 12 commits:

| Commit | Phase | Scope |
|---|---|---|
| de41380 | 2A | Provider data-model extension (4 new fields) |
| 11bf449 | 2B | v2 auth_request SPEC-010 fields + AuthAttemptRetention lifecycle |
| 83540b1 | 2B R2 | close mid-stream audit findings (AC-K.15 wire surfacing CRITICAL + 2 MAJOR + 2 MINOR) |
| c739055 | 2B R3 | close R2V finding (exact-match catalog gate) |
| b43e7c8 | 2C | ApplyHeartbeat REPLACEMENT + SPEC-011 PATH + LastLoadingState + LoadingStartedAt |
| 9d4a423 | 2C R2 | close mid-stream audit findings (same-model forgery MAJOR + 2 MINOR) |
| b76a608 | 2C R2V | closure-verification CLEAN audit artifact |
| c9626af | 2D | /v1/status SPEC-010 echo (per-model union, gateway-side) |
| 58defb0 | 2D | mid-stream audit CLEAN (0/0/0) |
| c8aba39 | 2E | audit_log SQLite + operator_model_swap emitter + F-1.5 + pruner |
| 9bfc4a8 | 2E R2 | close mid-stream audit findings (4 MINOR) |
| 70a5876 | 2E R2V | closure-verification CLEAN audit artifact |

Most of the branch lives in `phase4-coordinator/`. Phase 2D
(`c9626af`) is the ONLY commit that edits `phase5-gateway/`.

The coordinator's threat model:
- Operators / their binaries (provider side of WS) — SEMI-trusted
  (bearer tokens authenticate pinned; provisional tier rate-limited)
- Buyers (HTTP side) — UNTRUSTED (gateway-side only; 2D is the only
  buyer-visible change)
- A malicious or buggy provider binary can lie about every byte
  of every frame (initial-stage, proof-stage, heartbeat).

Money-path code: every accepted heartbeat contributes to billing
eligibility (SPEC-005); a forged `operator_model_swap` audit row
pollutes the forensic record; a missing audit row hides real
operator-side action. Adversarial review discipline is the gate.

## Required reading (in this order)

1. The 12 commits via `git log --oneline 5d4f69d..HEAD` and
   `git show <commit>` for each. The commit messages contain the
   binding R-rules and design rationale. Skim them all; deep-read
   the 5 feat commits (de41380, 11bf449, b43e7c8, c9626af,
   c8aba39).

2. The five BUILD prompts:
   - `specs/BUILD_SPEC_002_v1_3_5_IMPL_PHASE_2A_PROMPT.md`
   - `specs/BUILD_SPEC_002_v1_3_5_IMPL_PHASE_2B_PROMPT.md`
   - `specs/BUILD_SPEC_002_v1_3_5_IMPL_PHASE_2B_R2_PROMPT.md` (R2 fix)
   - `specs/BUILD_SPEC_002_v1_3_5_IMPL_PHASE_2C_PROMPT.md`
   - `specs/BUILD_SPEC_002_v1_3_5_IMPL_PHASE_2D_PROMPT.md`
   - `specs/BUILD_SPEC_002_v1_3_5_IMPL_PHASE_2E_PROMPT.md`

3. The five mid-stream audit prompts + their R2V variants (for
   context on what's already been adversarially verified):
   - `specs/AUDIT_SPEC_002_v1_3_5_IMPL_PHASES_2A_2B_PROMPT.md`
   - `specs/AUDIT_SPEC_002_v1_3_5_IMPL_PHASES_2A_2B_R2V_PROMPT.md`
   - `specs/AUDIT_SPEC_002_v1_3_5_IMPL_PHASE_2C_PROMPT.md`
   - `specs/AUDIT_SPEC_002_v1_3_5_IMPL_PHASE_2C_R2V_PROMPT.md`
   - `specs/AUDIT_SPEC_002_v1_3_5_IMPL_PHASE_2D_PROMPT.md`
   - `specs/AUDIT_SPEC_002_v1_3_5_IMPL_PHASE_2E_PROMPT.md`
   - `specs/AUDIT_SPEC_002_v1_3_5_IMPL_PHASE_2E_R2V_PROMPT.md`

4. The handoff doc for methodology context:
   - `specs/HANDOFF_SPEC_002_v1_3_5_IMPLEMENTATION.md`

5. The LOCKED specs (READ-ONLY, do not edit):
   - `specs/SPEC-002-coordinator.md` v1.3.5 — full file, but
     especially §3 (Provider data model), §7.1 (heartbeat
     extension + ApplyHeartbeat REPLACEMENT), §7.4 (/v1/status
     echo), §7.8 (v2 auth_request handshake), §7.9 (auth-attempt
     lifecycle), §7.10 (audit-log infrastructure), §11 AC-K.0
     through AC-K.17.
   - `specs/SPEC-010-model-catalog.md` v1.5 — R-3.1.1 through
     R-3.1.10, R-3.3.1 through R-3.3.4, R-3.6.1 through R-3.6.4,
     AC-17 / AC-21 / AC-22 / AC-23.
   - `specs/SPEC-011-operator-pushed-warm-swap.md` v0.5 — §3.3
     heartbeat extension, §3.5 hash re-verification, §3.6 audit
     event payload (LOCKED schema), §6.2 D2.1 fix.
   - `specs/SPEC-001-phase3-binary.md` v1.3 — §6.7.3 L-1 baseline,
     §6.7 v2 auth_request, §6.10 heartbeat extension. (The binary
     ships these; this PR consumes them coordinator-side.)
   - `specs/SPEC-006-buyer-api.md` v0.8.1 — §5.6 /v1/status
     contract + anonymization rules.
   - `specs/SPEC-008-coordinator-trust.md` v0.3 §5.5 (the 5-state
     hash_verification_result enum).

6. The implementation files (read in this dependency order):
   - `phase4-coordinator/internal/pool/provider.go` — 2A struct +
     2C ApplyHeartbeat REPLACEMENT + 2C SwapEvent/SwapEventEmitter
   - `phase4-coordinator/internal/pool/provider_test.go`
   - `phase4-coordinator/internal/ws/messages.go` — 2B AuthRequest
     extension + 2B parsers + 2C Heartbeat extension
   - `phase4-coordinator/internal/ws/messages_test.go`
   - `phase4-coordinator/internal/ws/auth_attempts.go` — 2B
     retention store + isSpec010CatalogBadField gate + NFC compare
   - `phase4-coordinator/internal/ws/auth_attempts_test.go`
   - `phase4-coordinator/internal/ws/server.go` — 2B v2 auth handler
     + 2C heartbeat threading + 2E NewServer auto-install
   - `phase4-coordinator/internal/ws/server_test.go`
   - `phase4-coordinator/internal/audit/store.go` — 2E SQLite Store
   - `phase4-coordinator/internal/audit/store_test.go`
   - `phase4-coordinator/internal/audit/swap_event.go` — 2E payload +
     F-1.5
   - `phase4-coordinator/internal/audit/swap_event_test.go`
   - `phase4-coordinator/internal/config/config.go` — 2E
     AuditLogRetentionDays
   - `phase4-coordinator/internal/config/config_test.go`
   - `phase4-coordinator/cmd/coordinator/main.go` — 2E audit store
     open + emitter closure + pruner
   - `phase5-gateway/internal/router/server.go` — 2D poolzResponse
     extension + statusModel + aggregateStatus union builder
   - `phase5-gateway/internal/router/server_test.go`

DO NOT inspect any file under `phase3-binary/.build/checkouts/` or
any third-party clean-room code (CLAUDE.md rule).

## Three review dimensions

You will produce findings in three distinct categories. A single
issue may surface in multiple categories — list it once in the
PRIMARY category and cross-reference from the others.

### Dimension 1: CODE REVIEW

Focus areas — adversarial discipline appropriate for money-path-
adjacent code and a locked-code-path REPLACEMENT:

- **L-1 byte-identical default across the full SPEC-001 v1.3 §6.7.3
  matrix.** A pre-SPEC-010 binary (no `supported_models`, no
  `publishes_supported_models`, no `--enable-warm-swap` so no
  `model_hash` or `loading` on heartbeats) MUST produce
  byte-identical observable behavior to v1.3.4. Spot-check:
    - Phase 2A: TestProviderJSONL1ByteIdenticalDefault asserts
      via bytes.Equal against a hardcoded JSON snapshot. Verify
      the snapshot is correct.
    - Phase 2B: TestProviderAuthV2L1NoRetentionEntry asserts no
      retention created when SPEC-010 fields absent on initial
      stage.
    - Phase 2C: TestApplyHeartbeatL1ByteIdenticalLegacyPath asserts
      hash-clear behavior matches v1.3.4 when ModelHashPresent ==
      false.
    - Phase 2D: TestAggregateStatusL1ByteIdenticalWhenNoProviderPublishes
      asserts /v1/status omits the supported_models key entirely.
    - Phase 2E: not L-1 relevant (only fires on SPEC-011 swap).
  Now look for INTERACTION DRIFT: does the legacy path through
  ALL of these phases stay byte-identical? E.g., a v1.3.4 binary
  reconnects via legacy hello, never opts into v2 auth_request,
  never sets model_hash on heartbeats. Trace the full request path
  and verify zero new SPEC-010 fields appear in any wire frame
  emitted to that binary OR in any observable buyer-facing
  response.

- **Cross-phase interactions.**
  - 2C's ApplyHeartbeat REPLACEMENT consumes 2A's
    Provider.LastLoadingState + LoadingStartedAt fields. Verify
    the data flow:
    - 2C reads priorLastLoadingState from Provider.
    - 2C maintains LastLoadingState per heartbeat (write at
      provider.go:516).
    - 2C's swapCompleted gate at provider.go:518-541 (R2)
      requires priorLoadingState=true AND modelIDChanged.
    - 2E's swapEmitter closure (main.go) is invoked with the
      SwapEvent built inside the mutex hold.
  - 2B's v2 auth_request populator at server.go:478 sets
    entry.SupportedModels = [ModelID] when wire field absent
    (R-3.X.1 fallback). 2D's union builder gates on
    PublishesSupportedModels. Verify: does the fallback
    [ModelID] synthesis trigger 2D's union? Read 2D's
    aggregateStatus gate at server.go:1845
    (PublishesSupportedModels && len(SupportedModels) > 0). The
    synthesis produces a non-empty slice, but the gate also
    requires PublishesSupportedModels=true. For an L-1 binary
    (publishes_supported_models absent on auth_request),
    PublishesSupportedModels = false (Phase 2B sets it from
    initial). Gate doesn't fire. Confirm.
  - 2E's loading_window_ms reads event.LoadingStartedAt which is
    stamped by 2C only when ModelHashPresent && !priorLoadingState
    && hb.Loading. Verify the LoadingStartedAt stamp doesn't
    re-fire on subsequent loading:true heartbeats (the !priorLoadingState
    guard at provider.go:513 enforces this).
  - 2B R2's CRITICAL fix surfaced AC-K.15 substrings via
    isSpec010CatalogBadField. 2B R3 changed prefix-match to
    exact-match. Does any new badField path in 2C/2D/2E need to
    be considered? E.g., 2C's parseHeartbeat extension may
    produce badField = "model_hash" or "loading" — these don't
    match isSpec010CatalogBadField (they're not in the exact-match
    allowlist). Verify these are routed correctly through the
    heartbeat error path (not the auth_request rejection path).

- **AC-K.0 through AC-K.17 traceability (CRITICAL).** Each AC-K
  acceptance criterion MUST be traced to one or more passing tests.
  Build the table in the Output section below. A row that says
  "deferred to 2C/2D/2E" must reference a test that IS landed in
  that phase. A row with no test is a CRITICAL gap.

- **Locked test-oracle substrings (AC-K.15 + AC-K.3).** These
  appear verbatim:
    - "supported_models cannot be empty" (R-3.1.1)
    - "supported_models entry exceeds 256 bytes" (AC-17)
    - "supported_models exceeds 64 entries" (AC-22)
    - "supported_models contains duplicate entries" (AC-23)
    - "supported_models missing model_id" (R-3.6.3)
    - "supported_models mismatch between auth_request stages"
      (AC-K.3 / SPEC-010 AC-18(c))
  Grep the repository:
    grep -rn '"supported_models entry exceeds 256 bytes"' \
      phase4-coordinator/ specs/SPEC-010-model-catalog.md \
      specs/SPEC-002-coordinator.md
  Every substring MUST appear in: (a) the parser at messages.go,
  (b) at least one end-to-end test, (c) the spec. Any drift = AC
  violation.

- **F-1.5 invariant enforcement (R-7.10.9).** The audit payload
  builder enforces "conv:" + "account_id" rejection. Verify:
    - assertNoForbiddenSubstrings runs BEFORE the SQLite Insert.
    - On match, the row is NOT written (only logged WARN via
      the main.go emitter closure).
    - Tests verify the count stays 0 after a rejected EmitSwap.

- **Backward-compatible signatures.**
  - 2C's ApplyHeartbeat signature is unchanged (3 returns). 2B
    extended ParseAuthRequest to 4 returns; verify all call sites
    in production code (NOT tests) are updated.
  - 2C extended ParseHeartbeat to 4 returns; same check.
  - 2B added Spec010Presence + AuthAttemptState + authAttemptStore.
  - 2C added HeartbeatPresence + HeartbeatHashVerifier + SwapEvent +
    SwapEventEmitter + RegistryOption.
  - Verify no breakage in cmd/coordinator/main.go or the gateway
    side.

- **Concurrency / data races.**
  - 2B's authAttemptStore uses sync.Mutex for all map access.
  - 2C's swapEmitter is invoked while Registry.mu is held.
  - 2E's audit Store has its own *sql.DB which is safe for concurrent
    use, but the emitter callback fires under Registry.mu — so a
    blocked SQLite Insert blocks heartbeat processing for up to
    busy_timeout (5s). Acceptable per R-7.10.8.
  - Run `go test -race -count=1 ./...` for both phase4-coordinator
    and phase5-gateway. Confirm exit 0 for both.

- **Test quality realism.** Tests pass — but do they prove the
  invariants their names suggest? Look for:
  - Tests that assert on coarse outcomes when the spec wants finer
    claims.
  - Tests that use `len(...) == 0` instead of proving JSON-key
    absence (the trap explicitly flagged in the 2D audit prompt
    — already verified clean).
  - Tests that have timing assumptions (eventually with arbitrary
    waits) that could flake under load.
  - Tests that bypass production code (e.g., `Store.DB()` in
    audit) and could miss a production bug.

Findings format:
```
[code:N.M] [SEVERITY] <short title>
  File: <path>:<line>
  What: <description>
  Why: <impact>
  Fix: <remediation; cite the binding spec rule>
```

### Dimension 2: SECURITY REVIEW

Threat model recap:
- A malicious provider binary controls every byte of every frame
  (auth_request, hello, heartbeat).
- A malicious operator may run a tampered binary.
- Buyers are UNTRUSTED but 2D is the only buyer-visible surface.
- High-value assets: audit_log integrity (forensic record);
  Provider.HashStatus (gates routing-eligibility);
  per-session assigned_id (billing identity).

Focus areas (cross-phase):

- **AC-K.15 / AC-K.3 evasion vectors.** The locked substrings
  surface on the wire when validation fails. Can a malicious
  binary AVOID the surfacing by crafting a frame that fails an
  earlier check? E.g., a frame missing both supported_models AND
  a required field — the required-field check fires first, no
  catalog rejection. Acceptable per R-3.1.9 (validation order is
  binding); confirm the order matches the spec.

- **Same-model loading-pulse forgery (the 2C R2 fix).** The
  2C R2 added modelIDChanged conjunct to the swapCompleted gate.
  Are there OTHER paths in 2D/2E that could be tricked into
  emitting a spurious event? E.g., can a buyer-side request
  trigger any state transition that affects audit_log? (Probably
  not — 2D is read-only, 2E only fires from 2C's gate. But
  verify.)

- **Retention bound (R-7.9.6 / AC-K.16) DoS.** A malicious peer
  could open 1024 WS connections, send 1024 initial-stage frames
  with SPEC-010 fields, and never send proof. Verify the
  retention store survives 1024 concurrent attempts AND the
  handshake-timeout (cfg.ProviderWSHandshakeTimeout) bounds the
  hold time AND there's no off-by-one in tryReserve (the 2B
  fix verified `>= bound`).

- **Audit_log integrity attacks.**
  - F-1.5 evasion: a malicious binary sends `model_id:
    "my-prefix-conv:bad"` — the F-1.5 check rejects. Sends
    `model_id: "my-prefix-conv%3Abad"` (URL-encoded colon) — F-1.5
    does NOT reject (literal byte-match only). Acceptable per
    R-3.6.5 wording, but flag if you'd recommend a broader rule.
  - DoS via audit_log floods: a malicious operator toggles
    warm-swap rapidly. Each completed swap writes one row.
    Bounded by the heartbeat interval (~5s) and the 24h pruner.
    Acceptable.
  - Row injection: SQL injection via crafted payload_json? The
    Insert uses parameterized statements; verify by reading
    store.go around line 96.

- **Verifier trust boundary.** 2C wires
  `tier2.VerifyProviderHash` as the production verifier. The
  verifier consults the locked catalog. A malicious binary
  sending model_hash = (the catalog's expected hash for ModelID-X)
  but actually serving different weights still gets
  HashStatusVerified (the coordinator can't verify the weights,
  only the claimed hash). This is the inherent SPEC-008 Pillar A
  limitation — flag if anything in this PR makes it worse.

- **Cross-phase secret leakage.** Verify no secret (operator key,
  bearer token, ECDH private key) lands in any new field, log
  line, or audit row.
  - 2E's WARN log on EmitSwap failure includes the full payload.
    Verify the payload doesn't carry any of these (it's built
    from SwapEvent which has model_id, model_hash, etc. — no
    secrets).
  - 2D's /v1/status doesn't expose provider_id, hostname, etc.
    per SPEC-006 §5.6. Verified by 2D's audit; spot-check.

- **Provider impersonation / replay.**
  - The v2 auth_request handshake's auth_attempt_id is server-
    generated. A replay of a proof-stage frame from a prior
    session would fail the auth_attempt_id check at server.go:398.
  - 2B's retention map ensures only one attempt per ID can
    succeed. Confirm by reading the lifecycle.

Findings format:
```
[sec:N.M] [SEVERITY] <short title>
  Asset: <what's at risk>
  Vector: <how a malicious actor exploits it>
  File: <path>:<line>
  Fix: <remediation>
```

### Dimension 3: ARCHITECTURE REVIEW

Focus areas (cross-phase):

- **Package boundaries.**
  - `internal/audit/` imports `internal/pool` for SwapEvent +
    HashStatus types. Correct direction (audit consumes pool).
  - `internal/ws` imports `internal/pool` and `internal/tier2`.
    Unchanged; 2E doesn't introduce new ws→audit imports
    (the emitter closure lives in main.go).
  - `cmd/coordinator/main.go` imports `internal/audit`.
    Production-only path.
  - `phase5-gateway/internal/router` deserializes coordinator's
    /poolz output. Verify the deserialization struct field
    types match the coordinator's serialization tags exactly
    (any mismatch = silent loss of supported_models).

- **Surface area discipline.** Count the exported symbols added
  across the branch:
    - pool.HeartbeatHashVerifier, SwapEvent, SwapEventEmitter,
      RegistryOption, WithHeartbeatHashVerifier, WithSwapEmitter
    - ws.HeartbeatPresence, Spec010Presence, AuthAttemptState,
      ParseAuthRequest's new return, ParseHeartbeat's new return,
      WithAuthAttemptRetentionBound, WithRegistryOptions,
      AuthAttemptCount, isSpec010CatalogBadField
    - audit.Store, OpenStore, SwapEvent (just a type alias?
      check), buildSwapPayload, loadingWindowMillis,
      assertNoForbiddenSubstrings
  Is the API surface bigger than needed? Could WithRegistryOptions
  be marked test-only via a tag/comment? Should AuthAttemptCount
  be unexported with a TestSetter?

- **Backward-compatible Option pattern.** NewRegistry accepts
  ...RegistryOption variadic; NewServer accepts ...Option
  variadic. Existing callers compile unchanged. Future callers
  thread new options. Good.

- **Spec-interpretation comments preservation.** Phase 2D ships
  a verbatim spec-interpretation rationale comment on statusModel.
  Phase 2C ships a mutex-held contract on SwapEventEmitter.
  Phase 2E ships an F-1.5 citation on buildSwapPayload. Verify
  these comments survived the R2 fix cycles and weren't
  inadvertently removed during polish.

- **Test architecture growth.** Branch adds ~1500 LOC of tests.
  - phase4-coordinator: pool, ws, audit, config tests grew.
  - phase5-gateway: router_test.go grew.
  - Are the new tests organized navigably by AC or behavior?
  - Are there fixtures / helpers that could be shared across
    similar tests? (Pragmatism over purity — flag only if a
    pattern emerges that begs for fixture extraction.)
  - The new integration test in internal/ws/server_test.go
    (TestHeartbeatSwapEmitterWritesAuditLogRow) crosses the
    ws→audit boundary. Reasonable placement.

- **Cross-codebase awareness.** 2D edits phase5-gateway; the rest
  edits phase4-coordinator. The squash-merge to main will produce
  a single commit touching both subtrees. Reviewers should be
  aware. The PR description (not yet written) should call this
  out explicitly.

- **Documentation / discoverability.** For a future contributor
  reading just the code without the spec, are the binding spec
  rule citations visible in code comments? Verify density across:
    - provider.go's two-path dispatch + LastLoadingState block
    - auth_attempts.go's NFC compare + isSpec010CatalogBadField
    - server.go's v2 auth handler retention block
    - swap_event.go's F-1.5 assertion
    - aggregateStatus's union builder
  Density should be ENOUGH for a maintainer to find the rule
  but NOT so dense that the code is hard to read.

- **Squash-merge readiness.** When the 12 commits squash to a
  single main commit, the diff will be ~3500 LOC. Is the change
  set coherent enough to review in one pass? Or would a series
  of smaller PRs (e.g., one per phase) have been more
  reviewable? Trade-off: per-phase PRs would have stretched
  total time and complicated cross-phase verification. Single
  PR with per-phase commits visible in git log is the chosen
  balance — flag if you'd recommend otherwise.

Findings format:
```
[arch:N.M] [SEVERITY] <short title>
  What: <description>
  Trade-off: <gain vs loss>
  Suggestion: <concrete refactor or follow-up; NOT required for
              merge unless severity says so>
```

## Severity scale (consistent across all three dimensions)

- **CRITICAL** — must be fixed before merge. Breaks an L-1
  byte-identical invariant, breaks an AC-K acceptance criterion,
  creates an exploitable hole that a realistic adversary can
  reach, OR crashes the coordinator on a happy path.
- **MAJOR** — should be fixed before merge OR explicitly deferred
  with a tracked follow-up. Real bug, real impact, not on the
  critical path; OR a security finding that requires unusual
  conditions to exploit.
- **MINOR** — would improve the code but does not block merge.
  Style, idiom drift, test polish, comment improvement.

## Output format

Return your findings as a single Markdown document:

```
# SPEC-002 v1.3.5 Phase 2A-2E pre-merge audit — Codex GPT-5

## Verdict

<one-line: MERGE-READY | MERGE-WITH-FIXES | BLOCK-MERGE>

## Counts

| Dimension    | CRITICAL | MAJOR | MINOR |
|---           |     ---: |  ---: |  ---: |
| Code         | <N> | <N> | <N> |
| Security     | <N> | <N> | <N> |
| Architecture | <N> | <N> | <N> |
| **Total**    | <N> | <N> | <N> |

## Findings

### Code review

[code:1.1] [SEVERITY] ...
[code:1.2] [SEVERITY] ...

### Security review

[sec:1.1] [SEVERITY] ...

### Architecture review

[arch:1.1] [SEVERITY] ...

## AC traceability (all 18 acceptance criteria)

| AC | Where satisfied | Test name(s) |
|---|---|---|
| AC-K.0  (L-1 baseline coordinator handling)        | <file:line> | <tests> |
| AC-K.1  (SPEC-010 catalog opt-in echo)             | <file:line> | <tests> |
| AC-K.2  (SPEC-010 catalog opt-in suppressed echo)  | <file:line> | <tests> |
| AC-K.3  (v2 auth_request proof-stage retention)    | <file:line> | <tests> |
| AC-K.4  (auth-attempt expiry)                      | <file:line> | <tests> |
| AC-K.5  (auth-attempt release on disconnect-before-proof) | <file:line> | <tests> |
| AC-K.6  (ApplyHeartbeat LEGACY PATH)               | <file:line> | <tests> |
| AC-K.7  (ApplyHeartbeat SPEC-011 PATH)             | <file:line> | <tests> |
| AC-K.8  (ApplyHeartbeat path selection per-heartbeat) | <file:line> | <tests> |
| AC-K.9  (operator_model_swap exactly-once emission) | <file:line> | <tests> |
| AC-K.10 (operator_model_swap payload schema)       | <file:line> | <tests> |
| AC-K.11 (F-1.5 invariants enforced)                | <file:line> | <tests> |
| AC-K.12 (conditional emission, WS-drop case)       | <file:line> | <tests> |
| AC-K.13 (audit-log write failure tolerance)        | <file:line> | <tests> |
| AC-K.14 (audit-log retention)                      | <file:line> | <tests> |
| AC-K.15 (SPEC-010 validation order + locked substrings) | <file:line> | <tests> |
| AC-K.16 (1024 retention-bound rejection)           | <file:line> | <tests> |
| AC-K.17 (audit-log table schema + ts_utc format)   | <file:line> | <tests> |

A row marked "deferred" must reference an out-of-scope phase or
spec section. A blank or "missing" row is a CRITICAL finding by
default.

## Build / vet / race / suite evidence

Paste outputs from BOTH codebases:

  cd /Users/augstar/macprovider-poc/phase4-coordinator
  go build ./...
  go vet ./...
  gofmt -l ./internal/ ./cmd/
  go test -race -count=1 ./...

  cd /Users/augstar/macprovider-poc/phase5-gateway
  go build ./...
  go vet ./...
  gofmt -l ./internal/
  go test -count=1 ./...

## What I didn't review

<list of files/areas you intentionally skipped, with rationale>

## Cross-cutting observations

<patterns spanning multiple findings; cross-phase interactions;
post-merge follow-up suggestions>
```

## Discipline

- Cite `<file>:<line>` for every finding.
- CRITICAL must describe the concrete failure mode in one
  sentence. Otherwise it's a MAJOR.
- L-1 byte-identical violations are CRITICAL by default.
- AC-K traceability gaps are CRITICAL by default.
- F-1.5 enforcement silent failures are CRITICAL.
- Mutex-held emitter calling back into Registry is CRITICAL
  (deadlock).
- Spec rule citations beat "this looks wrong" by a mile.
- Adversary models for security findings must be concrete:
  "A local UID-0 attacker..." or "A buyer-side X-Demo-Token
  holder..." or "A malicious provider binary sending..."
- Do not invent findings to fill quota. Zero in any dimension
  is a valid result.

You may run shell commands (git log, grep, find, file inspection,
go build/vet/test with -race). You MUST NOT modify any file. Cap
shell output at a reasonable volume; if you find a large file,
read the specific lines you need rather than dumping the whole
thing.

You may take up to 90 minutes wall-clock.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- Expected wall-clock: 60-90 min for Codex GPT-5 reading 12
  commits / ~3500 LOC across two Go modules plus 4 specs.
- This audit is the FINAL GATE before squash-merge. If it
  returns CRITICAL findings, draft per-finding R3 prompts and
  re-dispatch through the same Claude-drafts-Codex-implements
  loop. If only MAJOR/MINOR, triage with the operator before
  deciding fix-now vs. defer-to-followup.
- The per-phase mid-stream audits caught 3 substantive defects
  (1 CRITICAL + 2 MAJOR). The R2V rounds caught 1 more (MINOR).
  This broader pass is the safety net for cross-phase drift.
- If MERGE-READY, the next step is operator-driven: push branch,
  open PR, squash-merge, deploy coordinator + gateway, tag
  v1.3.0 binary release per the handoff §6.5 sequencing rule.
- Result artifact lives under
  `.omc/artifacts/ask/codex-execute-the-pre-merge-audit-prompt-*`.

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7) for the SPEC-002 v1.3.5 Phase 2 implementation.
