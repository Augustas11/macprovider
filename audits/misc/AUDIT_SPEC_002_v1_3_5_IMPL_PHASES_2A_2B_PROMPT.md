# Mid-stream audit prompt — SPEC-002 v1.3.5 Phases 2A + 2B

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**code / security / architecture review** of the two coordinator
commits that landed Phases 2A and 2B of SPEC-002 v1.3.5 on branch
`fix/spec-002-v1-3-5-coordinator`.

Phases 2A and 2B carry:

| Commit | Phase | Scope |
|---|---|---|
| de41380 | 2A | `Provider` data-model extension — 4 new fields, no behavior |
| 11bf449 | 2B | v2 `auth_request` SPEC-010 field parsing, `AuthAttemptRetention` lifecycle, NFC+ASCII case-fold cross-stage compare, 1024-bound rejection, `Provider.SupportedModels` / `Provider.PublishesSupportedModels` population |

Full coordinator test suite is green (227 ws tests + pool tests).
Claude per-phase inline audit raised zero findings. Operator wants an
independent adversarial pass BEFORE Phase 2C (the riskiest phase —
ApplyHeartbeat REPLACEMENT) begins, so any defect in the 2A/2B
foundation is caught before 2C builds on it.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~25-40 min.
This is a **read-only** review — Codex MUST NOT modify any file. Do
not commit, do not push, do not create branches.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial mid-stream review of two commits on
branch `fix/spec-002-v1-3-5-coordinator` in the
Augustas11/macprovider repository. The branch is already checked out
at `/Users/augstar/macprovider-poc`. Phases 2C / 2D / 2E have NOT
landed yet — your scope is exclusively Phases 2A and 2B.

This is a **read-only review**. You MUST NOT edit any file, commit,
push, or modify the git state in any way. Your only output is the
structured findings report at the end.

## Context

The repository hosts the macprovider stack for AntFeed, a P2P AI
marketplace on Base. The codebase under `phase4-coordinator/` is the
Go coordinator that:
- Accepts WebSocket connections from operator-run Mac binaries
  (SPEC-001 v1.3 — already shipped in PR #5)
- Routes inference requests from buyers to providers
- Issues per-session `assigned_id` after a successful v2
  `auth_request` two-stage handshake

The branch you're reviewing implements SPEC-002 v1.3.5 §3 + §7.8 +
§7.9 only. The §7.1 ApplyHeartbeat REPLACEMENT (riskiest, semantics-
changing), §7.4 `/v1/status` opt-in echo, and §7.10 audit-log
infrastructure are Phases 2C / 2D / 2E and are explicitly out of
scope for this audit — but you SHOULD flag if 2A/2B made an
assumption that 2C/2D/2E will have to fight.

The coordinator's threat model:
- Operators / their binaries (provider side of WS) — SEMI-trusted.
  Bearer tokens authenticate pinned providers; provisional providers
  may connect without tokens but are rate-limited and Sybil-bounded.
  A malicious / buggy provider binary can lie about anything it
  sends.
- Buyers (HTTP side) — UNTRUSTED. Not in this audit's blast radius;
  2A/2B touches no buyer path.
- Other coordinator administrators — TRUSTED.

The coordinator handles money-path code (every accepted heartbeat
contributes to billing eligibility; a malformed auth handshake that
succeeds silently could route real USDC to the wrong provider).

## Required reading (in this order)

1. The two commits via `git log --oneline 5d4f69d..HEAD` and
   `git show de41380` + `git show 11bf449`. The commit messages
   contain the binding R-rules and design rationale.

2. The two BUILD prompts that produced the code:
   - `specs/BUILD_SPEC_002_v1_3_5_IMPL_PHASE_2A_PROMPT.md`
   - `specs/BUILD_SPEC_002_v1_3_5_IMPL_PHASE_2B_PROMPT.md`

3. The handoff doc for context on the methodology:
   - `specs/HANDOFF_SPEC_002_v1_3_5_IMPLEMENTATION.md`

4. The locked spec (READ-ONLY, do not edit):
   - `specs/SPEC-002-coordinator.md` v1.3.5 — focus on:
     - §3.X "Provider data model (v1.3.5 SPEC-010 extension)"
       (lines 305-378)
     - §7.8 "v2 `auth_request` provider handshake" (lines
       2630-2744)
     - §7.9 "Auth-attempt lifecycle" (lines 2746-2812)
     - §11 AC-K.0 through AC-K.5 + AC-K.15 + AC-K.16 (binding
       acceptance criteria — verify each one is satisfied by 2A/2B
       jointly)
   - `specs/SPEC-010-model-catalog.md` v1.5 — §3.1 field set,
     §3.3 Provider population rules, R-3.1.7 NFC + ASCII case-
     fold rule, R-3.1.9 validation order, R-3.1.10 retention
     clauses 1-5, AC-17 / AC-22 / AC-23 reason-text substrings
   - `specs/SPEC-001-phase3-binary.md` v1.3 §6.7.3 — the L-1
     baseline contract the coordinator side MUST NOT regress

5. The implementation files under `phase4-coordinator/`:
   - `internal/pool/provider.go` (Phase 2A struct edit)
   - `internal/pool/provider_test.go` (Phase 2A tests)
   - `internal/ws/messages.go` (Phase 2B parser extensions)
   - `internal/ws/messages_test.go` (Phase 2B parser tests)
   - `internal/ws/auth_attempts.go` (NEW in 2B — retention store +
     NFC helpers)
   - `internal/ws/auth_attempts_test.go` (NEW in 2B)
   - `internal/ws/server.go` (Phase 2B v2 auth handler edits)
   - `internal/ws/server_test.go` (Phase 2B end-to-end tests)

6. The repo's per-project guidance:
   - `CLAUDE.md` at the repo root (git identity + PR-workflow
     rules)

DO NOT inspect any file under `phase3-binary/.build/checkouts/` or
any file referenced by the strict-clean-room rule in CLAUDE.md.

## Three review dimensions

You will produce findings in three distinct categories. A single
issue may surface in multiple categories — list it once in the
PRIMARY category and cross-reference from the others.

### Dimension 1: CODE REVIEW

Focus areas (this is a Go codebase, NOT Swift):

- **L-1 byte-identical default.** The Phase 2A snapshot test pins
  `pool.Provider` JSON output for zero-new-field state. Verify the
  test snapshot actually matches what a pre-2A coordinator would
  produce — read `phase4-coordinator/internal/pool/provider.go:50-101`
  and confirm the JSON tag set produces the documented snapshot.
  Look for any new field that omits an `omitempty` or `json:"-"`
  tag and would leak a default value on the wire.
- **Validation order in `parseAuthInitial` (messages.go:382-403).**
  SPEC-010 v1.5 R-3.1.9 mandates: JSON type → per-entry byte length
  → array length → normalized duplicate check → `model_id`
  containment. Read the code and verify the ordering is exactly
  this. A different order produces wrong rejection reasons for
  edge-case input.
- **Locked test-oracle substrings (AC-K.15).** The reason strings
  are normative. Read each `fieldError{Field: "..."}` literal in the
  SPEC-010 validation block and `grep` the spec for the matching
  AC entry. The four LOCKED substrings are:
    - `"supported_models entry exceeds 256 bytes"` (AC-17)
    - `"supported_models exceeds 64 entries"` (AC-22)
    - `"supported_models contains duplicate entries"` (AC-23)
    - `"supported_models mismatch between auth_request stages"`
      (AC-K.3 / SPEC-010 AC-18(c))
  Any drift = LOCKED test oracle violation.
- **Retention store atomicity (`auth_attempts.go`).** Verify
  `tryReserve` checks `len(entries) >= maxBound` (NOT `>`) before
  insert, holding the mutex for the entire check-and-insert. An
  off-by-one or check-then-unlock-then-insert pattern admits 1025th.
- **L-1 retention-skip gate (R-7.9.8).** In `server.go` around line
  365-396, verify the `if retainSpec010 { ... }` block is the ONLY
  path that calls `tryReserve` AND `defer release`. A binary
  registering with NEITHER SPEC-010 field MUST leave
  `s.authAttempts.count()` at zero throughout the handshake.
- **Defer ordering (R-7.9.7).** The defer release MUST be installed
  AFTER `tryReserve` and BEFORE `auth_challenge` write. A defer
  after the challenge write leaks state on a challenge-write
  failure. Verify by reading the handler top-to-bottom.
- **Cross-stage compare scope.** R-7.8.7: present proof-stage
  fields are compared to retained initial-stage values after NFC +
  ASCII case-fold; absent proof fields are no-ops. Check that the
  comparison code at server.go ~445 actually reads from
  `s.authAttempts.lookup(authAttemptID)` and NOT from `initial.*`
  (the latter would defeat the retention design — though here it
  happens to be the same value, the intent matters for 2C/2D).
- **Provider field population (§3.X.1).** R-3.X.1 requires
  `Provider.SupportedModels = [ModelID]` synthesis when wire field
  absent. Verify the populator (server.go ~478) handles both
  branches and that the case-preservation rule (R-3.X.1: preserve
  entry case as operator provided) is respected for the explicit
  path.
- **Explicit-release-then-defer pattern.** Codex added an explicit
  `s.authAttempts.release(authAttemptID)` immediately before
  `registerProviderSession`, on top of the auth-attempt-scoped
  defer. This prevents retention persisting for the WS-session
  lifetime. Verify this is correct and that the defer is still
  safe (releasing an already-removed key is a no-op delete; double-
  release is harmless). Confirm there is NO code path where the
  explicit release runs but the auth handshake then fails before
  returning — that would leave the defer unable to find the entry,
  which is fine, but the symmetry should be intentional.
- **Concurrency / data races.** `authAttemptStore` uses
  `sync.Mutex` for all access. Verify no map access exists outside
  the mutex hold. `go vet` and `go test -race` results are not
  shown here — recommend running `-race` if you find any
  suspicious access pattern.
- **AuthRequest struct change.** `Hello()` converter at
  messages.go:404 is unchanged by 2B. Verify this is correct: the
  legacy `hello` path (used by SPEC-011 WS-drop reconnect) does
  NOT carry SPEC-010 fields, so the conversion stays minimal.
- **Test coverage realism.** Tests pass — but do they prove the
  invariants their names suggest? Look for any
  `TestProviderAuthV2*` test that asserts only on coarse outcomes
  (e.g., "response.Status == accepted") when the spec wants a
  finer claim (e.g., specific Provider field values). Also look for
  potential flakes from `eventually(t, ...)` timing.

Findings format:
```
[code:N.M] [SEVERITY] <short title>
  File: <path>:<line>
  What: <one-paragraph description of the issue>
  Why: <impact — what breaks, when, and how bad>
  Fix: <suggested remediation; cite the binding spec rule if
        applicable>
```

### Dimension 2: SECURITY REVIEW

Threat model recap:
- Adversary: a malicious provider binary that controls every byte
  of the `auth_request` frames (both stages). The binary's
  operator may be honest, but the binary itself may be a tampered
  build or a different program impersonating the protocol.
- High-value asset: per-session `assigned_id` (which a malicious
  actor could steer to impersonate a legitimate provider for
  billing fraud) and the retention map (which an adversary could
  try to DoS by exhausting the 1024 bound).

Focus areas:

- **Retention DoS (R-7.9.6 / AC-K.16).** The 1024 bound is the
  defensive cap. Verify:
    - A single malicious peer that opens many WS connections, sends
      valid initial-stage frames with SPEC-010 fields, and never
      sends proof CANNOT exceed 1024 entries (the bound is global
      across the coordinator). The proof-stage absence releases via
      defer on disconnect — but only when the WS actually closes.
      What if the attacker holds connections open silently?
      `cfg.ProviderWSHandshakeTimeout()` should bound this; verify
      it's actually applied between initial and proof frames at
      server.go ~387-388.
    - The 1024-bound is enforced BEFORE entry creation (verified by
      `tryReserve` semantics). The rejection path
      (`sendAuthRejection` + `s.close`) does not leak retention.
- **NFC normalization correctness.** The spec mandates NFC + ASCII
  case-fold for cross-stage compare and duplicate check. Verify:
    - `unicode/norm.NFC.String` is used (not NFD or NFKC). NFKC
      would normalize too aggressively and create false positives;
      NFD would miss compositions and create false negatives.
    - ASCII case-fold is `strings.ToLower`, not
      `strings.ToLowerSpecial` or Unicode-aware case mapping. The
      spec says ASCII specifically.
- **Substring oracle for cross-stage compare reason text.** The
  rejection at server.go ~452 emits `"supported_models mismatch
  between auth_request stages"` in `auth_response.error.message`.
  Verify this substring also appears in the WS close reason — does
  a downstream operator-side log parser see the same substring?
  Reason: the SPEC-010 AC-18(c) test oracle is grep-based; if the
  substring is only in the JSON message but not the close reason,
  it's still compliant, but operator log discipline benefits from
  symmetry.
- **`publishes_supported_models` mismatch handling.** Codex added
  a separate compare for `publishes_supported_models`. Is this
  required by the spec? Re-read R-7.8.7: "present values MUST
  match the retained initial-stage values after NFC normalization
  and ASCII case-fold". This applies primarily to
  `supported_models` (string array); for a bool, "match" is just
  `==`. Verify the rejection path is correct OR flag if the
  comparison is overzealous (spec says "MAY be optional" for the
  bool too).
- **Initial-stage frame validation BEFORE retention reserve.**
  The validation order in `parseAuthInitial` produces a `badField`
  rejection at the caller. Verify that a SPEC-010-invalid frame
  (e.g., 65 entries) NEVER reaches `tryReserve` — the parser
  rejects it first, the caller's `if err != nil` path triggers
  `sendAuthRejection`, no retention entry exists. A regression
  here would let an attacker forge garbage initials to fill the
  bound.
- **Memory safety of stored strings.** The retention state copies
  via `append([]string(nil), initial.SupportedModels...)`. Verify
  this is a deep copy (Go strings are immutable, so the slice
  copy is sufficient). An attacker can't mutate retained state
  via subsequent frames if the copy is correct.
- **Information leak via parser error strings.** The `badField`
  strings contain user-controlled input (model_id, supported_models
  values) in some error paths. Verify they don't echo arbitrary
  bytes (e.g., a `model_id` of `</script><img src=x>`) into logs
  that get rendered as HTML somewhere. The coordinator's log sink
  is structured (zerolog), so this is likely safe; flag if you
  find any `fmt.Sprintf("%s", userInput)` path that ends in an
  HTML-rendered surface.

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

- **Layering of `auth_attempts.go`.** The new file declares the
  retention store, the per-attempt state, the NFC normalizer, and
  the positional compare. Is the placement (`internal/ws`) right,
  or should the NFC helpers live in a separate package
  (e.g., `internal/spec010`) for reuse by 2C/2D when SPEC-010
  catalog values flow through other code paths?
- **`Spec010Presence` signature cascade.** `ParseAuthRequest` now
  returns 4 values (`AuthRequest, Spec010Presence, string, error`).
  Is the bool-pair struct the right abstraction, or would a
  `*[]string` / pointer-to-bool pattern have been simpler? Verify
  all call sites are updated (`grep -rn ParseAuthRequest
  phase4-coordinator/`).
- **Explicit release before `registerProviderSession`.** This is
  a Codex-added belt-and-suspenders not in the BUILD prompt. Is
  the redundancy noted in comments? Future maintainers seeing two
  release sites may delete the explicit one as "dead code" and
  reintroduce the WS-session-lifetime retention leak. Flag if
  comment discipline is insufficient.
- **L-1 gate placement.** The `retainSpec010` boolean is computed
  inside `handleV2Conn` and used in two distinct blocks (retention
  + cross-stage compare). Verify the variable is captured
  correctly across the proof-stage `return` paths between the two
  uses; a subtle scope bug here would skip the compare.
- **Test architecture.** `server_test.go` is over 1900 lines now.
  Is `TestProviderAuthV2*` cluster organized in a way that future
  contributors can navigate? Are the test fixtures (`validAuthInitial`,
  `writeAuthProof`) extended cleanly or are new helpers ad-hoc?
- **The `WithAuthAttemptRetentionBound` Option.** This is a
  test-facing knob. Is it documented as test-only? Could a
  misconfigured production deployment lower the bound and reject
  legitimate traffic?
- **Phase 2C readiness.** Phase 2C will REPLACE `ApplyHeartbeat`
  with a two-path dispatch keyed on `model_hash` presence and
  needs to write `Provider.LastLoadingState` and
  `Provider.LoadingStartedAt`. Are the Phase 2A fields ready for
  that? Specifically: is `LoadingStartedAt` a plain `time.Time`
  (not a pointer) — meaning the "never set" state is the zero
  value, which 2C will need to distinguish from "set to epoch"?
  Flag if the chosen representation is ambiguous.
- **Documentation discipline.** Are the binding spec rule
  citations in code comments adequate? A future contributor
  reading just the code without the spec — can they find the
  rule that justified a particular decision? Compare the comment
  density on `auth_attempts.go` vs `messages.go` vs the
  `server.go` insertion blocks.

Findings format:
```
[arch:N.M] [SEVERITY] <short title>
  What: <one-paragraph description>
  Trade-off: <what's gained vs lost by the current choice>
  Suggestion: <a concrete refactor or follow-up; NOT required
              for merge unless the severity says so>
```

## Severity scale (consistent across all three dimensions)

- **CRITICAL** — must be fixed before Phase 2C begins. Breaks an
  invariant that 2C will build on (L-1 byte-identical default,
  retention lifecycle correctness, AC-K acceptance criterion
  violation), creates an exploitable hole, or has zero tests for
  a normative rule.
- **MAJOR** — should be fixed before merge OR explicitly deferred
  with a follow-up. Real bug, real impact, not on the critical
  path.
- **MINOR** — would improve the code but does not block 2C or
  merge. Style, idiom drift, comment polish.

## Output format

Return your findings as a single Markdown document with the
following structure:

```
# SPEC-002 v1.3.5 Phases 2A + 2B mid-stream audit — Codex GPT-5

## Verdict

<one-line summary: PROCEED-TO-2C | FIX-THEN-PROCEED | BLOCK>

## Counts

| Dimension | CRITICAL | MAJOR | MINOR |
|---|---|---|---|
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

## AC traceability check

| AC | Where satisfied | Test name |
|---|---|---|
| AC-K.0 (L-1 baseline) | <file:line> | <test> |
| AC-K.3 (cross-stage compare locked oracle) | <file:line> | <test> |
| AC-K.4 (retention 10-min expiry) | <file:line> | <test or "deferred to 2C"> |
| AC-K.5 (release on disconnect-before-proof) | <file:line> | <test> |
| AC-K.15 (validation order + locked substrings) | <file:line> | <tests> |
| AC-K.16 (1024 bound + close 4429) | <file:line> | <test> |

A row marked "deferred to 2C/2D/2E" is fine if the spec genuinely
defers it. A row blank or marked "missing" is a finding.

## What I didn't review

<list of files/areas you intentionally skipped, with rationale>

## Cross-cutting observations

<any patterns that span multiple findings>
```

## Discipline

- Be specific. Cite `<file>:<line>` for every finding.
- Be conservative on CRITICAL. A finding is only CRITICAL if you
  can describe the concrete failure mode in one sentence.
- Be honest about uncertainty. If you suspect an issue but cannot
  confirm without running the code, mark it as MAJOR with a
  "needs verification" tag rather than CRITICAL.
- Do not invent findings to fill quota. If a dimension yields zero
  findings, report zero. Finding nothing IS a valid result.
- Cite the binding SPEC rule when claiming a violation.
- For security findings, model the attacker explicitly. Without
  the attacker model, it's just a code smell.

You may run shell commands to explore the repo (git log, grep,
find, file inspection, `go vet`, `go test -count=1 -race ./...`).
You MUST NOT modify any file. Cap shell output volume.

You may take up to 40 minutes wall-clock. If you finish earlier
with a clean report, that's fine; do not pad.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- This is a mid-stream check, not a pre-merge gate. The intent is
  to clear 2A/2B BEFORE 2C builds on them, so a defect in the
  foundation doesn't compound across phases.
- Expected wall-clock: 25-40 min. Surface is small (~150 net
  production LOC across 2 commits) but the spec citations are
  dense (5 AC-K rows, 4 locked substrings, R-7.9.x lifecycle).
- If Codex returns CRITICAL findings, draft a focused R2 fix
  prompt (one per finding) and re-dispatch. If only MAJOR/MINOR,
  triage with the operator before deciding whether to fix now or
  defer to the pre-merge audit at the end of 2E.
- A separate, broader pre-merge audit covering all five phases
  (2A-2E) will run before squash-merge to main — that's the
  pattern modeled after PR #5's `AUDIT_SPEC_001_v1_3_IMPL_PR5_PROMPT.md`.
- Result artifact lives under
  `.omc/artifacts/ask/codex-execute-the-mid-stream-audit-prompt-*`.

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7) for the SPEC-002 v1.3.5 Phase 2 implementation.
