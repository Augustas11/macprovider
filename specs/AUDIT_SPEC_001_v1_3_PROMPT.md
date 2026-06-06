# Audit prompt — SPEC-001 v1.3 (round 1, normative)

Operator-paste prompt to audit SPEC-001 v1.3
(`specs/SPEC-001-phase3-binary.md`) — the round-1 normative audit
of the v1.2.4 → v1.3 revision that absorbed LOCKED SPEC-010 v1.5
and LOCKED SPEC-011 v0.5.

The v1.3 revision was authored by Codex GPT-5 via
`specs/BUILD_SPEC_001_v1_3_PROMPT.md` (2026-06-06), then received
a 3-edit polish pass by Claude to close 3 MINORs identified in a
local pre-audit spot-check:
1. Change-log header grouping drift (v1.3 bullet under v1.2.4 header)
2. Stale `Revision:` line still describing v1.2.4
3. `hexString()` line citation drift in R-6.10.2

Round 1 target: confirm L-1 byte-identical default is literal,
verify every new R-rule cites a binding SPEC-010 v1.5 / SPEC-011
v0.5 rule, verify §6.5 (legacy `hello`) is byte-identical to
v1.2.4, verify code citations are line-accurate, verify the four-
cell opt-in matrix is complete and consistent.

Trajectory target:
- v1.3 round 1: 0 / 0 / 0-3 MINOR (LOCK-confirmation or
  LOCK-READY pending narrow polish)
- v1.3 round 2 (if needed): polish pass to 0 / 0 / 0 → LOCK

Append round-1 findings to a NEW file
`specs/SPEC-001-v1-3-audit.md` (since v1.3 is a major revision
of v1.2.4, this gets its own audit history file — matches the
`specs/SPEC-001-v1-1-audit.md` precedent).

Paste everything between `=== BEGIN PROMPT ===` and
`=== END PROMPT ===` into a fresh Codex CLI session rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-001 v1.3 at
/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md.
This is round 1 of the v1.3 normative audit cycle.

v1.3 is a revision-in-place of LOCKED SPEC-001 v1.2.4 that
absorbs the binary-side surface of LOCKED SPEC-010 v1.5
(Provider Model Catalog) and LOCKED SPEC-011 v0.5
(Operator-Pushed Warm Swap). It adds 5 new top-level sections
(§6.7-§6.11), 6 new CLI flags + `models` subcommand in §6.2,
12 new acceptance criteria (AC-18.0 through AC-18.11), §2 scope
extensions, and a §11 implementation hand-off extension.

The v1.3 draft was authored by Codex GPT-5 via
`specs/BUILD_SPEC_001_v1_3_PROMPT.md`, then received a 3-edit
polish pass to close 3 MINORs identified in a Claude pre-audit
spot-check:
1. Change-log header grouping (v1.3 now has its own
   `**Change log v1.3:**` header above v1.2.4 — matches file
   convention)
2. Stale `Revision:` line (now describes v1.3)
3. R-6.10.2 cited `hexString()` at `ModelRuntime.swift:294-325`
   when `hexString()` is actually at line 340; lines 294-325 are
   `modelWeightArtifactManifestHash` (the function that produces
   the emitted hash string). Now cites the producer function
   correctly, with parenthetical pointer to the helper.

Your job: round-1 normative audit. Categories below. Append
findings to a NEW file (this file does not yet exist; create it).

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-001-v1-3-audit.md

CREATE this file with a top-level section:
  `## Round 1 — Codex GPT-5 — 2026-06-06 — Normative audit`

## Severity definitions

- **CRITICAL** — spec text directly contradicts a LOCKED spec
  (SPEC-001 v1.2.4 backward-compat clause, SPEC-002 v1.3.4,
  SPEC-004 v0.3.1, SPEC-005, SPEC-006 v0.8.1, SPEC-008 v0.3,
  SPEC-010 v1.5, SPEC-011 v0.5) such that a binary built per
  v1.3 would violate L-1 byte-identical default OR refuse a
  request a v1.2.4 binary accepts OR violate a locked AC.
- **MAJOR** — spec text introduces ambiguity, a missing
  citation to a binding rule, or a code-grounding error
  (line citation off by more than the function-body range,
  cited function does not exist, struct field doesn't exist)
  such that a future implementer would write incorrect code
  OR a contract surface is left under-specified.
- **MINOR** — editorial drift, ordering, formatting, single-
  word ambiguity, citation imprecision that does not change
  implementability.
- **QUESTION** — request for clarification; not a defect, but
  the auditor wants the author's explicit position before
  marking PASS.

## Critical constraints

**1. LOCKED specs READ-ONLY.** Do NOT edit SPEC-002, SPEC-004,
SPEC-005, SPEC-006, SPEC-008, SPEC-010, SPEC-011. Verify with
`git diff specs/SPEC-002*.md specs/SPEC-004*.md specs/SPEC-006*.md
specs/SPEC-008*.md specs/SPEC-010*.md specs/SPEC-011*.md` — must
be empty.

**2. SPEC-001 v1.2.4 sections §0-§6.6, §7, §8, §10 READ-ONLY.**
Only the change-log block, §2 scope additions, §6.2 flag
additions, NEW §6.7-§6.11, NEW §9 AC-18.x criteria, and §11
hand-off extension are in v1.3's scope per BUILD prompt edit
constraint 8. The verbatim backward-compat clause near the top
must stay byte-identical.

**3. §6.5 byte-identity is a hard invariant.** Spot-check:
```
git show HEAD:specs/SPEC-001-phase3-binary.md > /tmp/spec001-head.md
diff <(awk '/^### 6\.5/,/^### 6\.6/' /tmp/spec001-head.md) \
     <(awk '/^### 6\.5/,/^### 6\.6/' specs/SPEC-001-phase3-binary.md)
```
If non-empty = CRITICAL (per AC-18.11).

**4. L-1 byte-identical default is the most-important invariant.**
Every new section that introduces wire surface (§6.7, §6.10,
§6.11.2 reconnect) MUST gate the new behavior on
`--enable-warm-swap` OR `--supported-models` AND state explicitly
that the field/socket/state is absent in the default opt-in-off
cell. Mirror the gating wording at SPEC-011 v0.5 R-3.1.0 +
R-3.3.0 and SPEC-010 v1.5 R-3.6.2.

**5. macOS-native paths only.** Spot-check:
```
grep -n 'XDG_RUNTIME_DIR' specs/SPEC-001-phase3-binary.md
```
Every match MUST fall in the §6.9 "Why not" rationale block
(currently line 1805). Any other location = MAJOR.

**6. Code-grounding citations are normative.** Every line-anchor
citation MUST be accurate. Spot-check the cited line numbers
against actual source:
- `phase4-coordinator/internal/ws/server.go:354`
  (`authAttemptID := "auth-" + s.newUUID()`)
- `phase4-coordinator/internal/ws/messages.go:333`
  (`func parseAuthInitial`)
- `phase4-coordinator/internal/ws/messages.go:391`
  (`func parseAuthProof`)
- `phase4-coordinator/internal/pool/provider.go:411`
  (`func (r *Registry) ApplyHeartbeat`)
- `phase4-coordinator/internal/pool/provider.go:421`
  (`p.ModelHash = ""` — clearing line)
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:25-68`
  (immutable `actor ModelRuntime` with `private let` fields)
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:294-325`
  (`modelWeightArtifactManifestHash`, which produces the hash
  string used as `model_hash`)
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:340`
  (`hexString()` byte→hex helper)
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:7-15`
  (existing subcommand list)

If any cited line number does not match the actual file content
(function signature on that line, struct field on that line) =
MAJOR.

**7. Four-cell opt-in matrix is normative.** §6.7.3 must
document all 4 cells of `--supported-models` × `--enable-warm-swap`
explicitly. Each cell's expected wire behavior must match
SPEC-010 v1.5 R-3.6.1 / R-3.6.4 and SPEC-011 v0.5 R-3.1.0 /
R-3.3.0. Any inconsistency = MAJOR.

**8. AC tracing is normative.** Every new AC-18.x must cite a
binding SPEC-010 v1.5 AC or SPEC-011 v0.5 AC by number. An AC
without a trace = MAJOR (per BUILD prompt edit I).

**9. Spec-text-only revision.** Spot-check:
```
git diff --stat phase3-binary/
```
Must be empty. Non-empty = CRITICAL.

**10. Clean-room.** No d-inference inspection.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.3 — full document. Focus on:
   - Top change-log block (verify v1.3 header structure +
     `Revision:` line + v1.3 bullet)
   - §2 Scope additions (lines 29-34)
   - §6.2 CLI additions (lines ~960-1015) — verify all 6 new
     flags + `models` subcommand documented
   - §6.5 (Coordinator WebSocket envelope) — must be byte-
     identical to v1.2.4 (run the diff spot-check above)
   - §6.7 v2 `auth_request` handshake — verify field tables
     match SPEC-010 v1.5 §3.1.A (initial) and §3.1.C (proof)
     by row-by-row comparison
   - §6.8 runtime state machine — verify R-6.8.1 through
     R-6.8.7 each cite a SPEC-011 v0.5 rule
   - §6.9 control socket protocol — verify the
     `$TMPDIR` default + "Why not `$XDG_RUNTIME_DIR`" rationale +
     detection precedence + permissions
   - §6.10 heartbeat extension — verify R-6.10.2 line citations
     for `modelWeightArtifactManifestHash` and `hexString` are
     accurate (post-polish)
   - §6.11 concurrent switch + WS drop
   - §9 new AC-18.0 through AC-18.11 — verify each cites a
     binding SPEC-010/SPEC-011 AC

2. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.5 (LOCKED) — focus on:
   - §3.1.A initial-stage field table (the SOURCE for §6.7.1)
   - §3.1.C proof-stage field table (the SOURCE for §6.7.2)
   - §3.6 binary CLI rules R-3.6.1 through R-3.6.4
   - §6.1 (SPEC-001 candidate guidance — SPEC-010's own view of
     what SPEC-001 should add)

3. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   v0.5 (LOCKED) — focus on:
   - §2 L-1 through L-7 (locked design decisions)
   - §3.1 CLI subcommand + control socket rules
   - §3.2 state machine rules R-3.2.1 through R-3.2.7
   - §3.3 heartbeat extension rules
   - §3.4 drain semantics
   - §3.7 concurrent switch
   - §3.8 WS drop
   - §6.1 (SPEC-001 v1.3 candidate guidance — SPEC-011's own
     view of what SPEC-001 should add)

4. `/Users/augstar/macprovider-poc/specs/BUILD_SPEC_001_v1_3_PROMPT.md`
   — the build prompt that authored v1.3. Use as the "ground
   truth" for what was supposed to land. Verify each of the 13
   critical constraints is satisfied.

5. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md`
   Entries 54 (SPEC-010 v1.5 lock) and 55 (SPEC-011 v0.5 lock)
   — strategic context.

6. `/Users/augstar/macprovider-poc/CLAUDE.md` — repo conventions.

7. Code spot-check files (READ-ONLY, line-by-line verification
   only for the citations enumerated in critical constraint 6).

## Audit categories

### Category A: L-1 byte-identical default preservation

A.1  §6.7.3 row 1 (the unset/unset cell): is the wire behavior
     truly byte-identical to v1.2.4? Consider FIRST-CONNECT frame
     type: v1.2.4 binaries use legacy `hello` on first connect;
     §6.7.4 R-6.7.8 says "v1.3 binary uses v2 `auth_request` for
     the first connection attempt with a coordinator ... whether
     or not either opt-in is set." This is a WIRE-OBSERVABLE
     change from v1.2.4 default. Is this a violation of L-1, or
     is L-1 scoped narrowly to "absence of new fields / absence
     of new behavior when both opt-ins off" rather than "full
     wire-frame identity"? If the spec is ambiguous, raise as
     QUESTION; if R-6.7.8 + R-6.7.10 contradict each other (one
     says v1.3 uses v2, the other says pre-v1.3 uses hello),
     raise as MAJOR.

A.2  §6.10.1 opt-in gating: confirm `model_hash` and `loading`
     fields are gated correctly per SPEC-011 v0.5 R-3.3.0.

A.3  §6.9 socket absence in disabled mode: confirm R-6.9.1
     gates correctly per SPEC-011 v0.5 R-3.1.0.

A.4  Backward-compat clause near the top of SPEC-001
     (lines 33-51) byte-identical to v1.2.4.

### Category B: Locked-spec citations and accuracy

B.1  For each R-rule in §6.7-§6.11, verify the cited SPEC-010
     v1.5 or SPEC-011 v0.5 rule (a) exists in the locked spec
     and (b) actually says what the cite implies. Sample at
     least 10 rules across the 5 sections. Flag any cite that
     references a non-existent or unrelated rule = MAJOR.

B.2  §6.7.1 field table: compare row-by-row against SPEC-010
     v1.5 §3.1.A. Any field present in one but not the other,
     or with mismatched type / requiredness, = MAJOR.

B.3  §6.7.2 proof-stage field table: compare row-by-row against
     SPEC-010 v1.5 §3.1.C. Same rule = MAJOR.

B.4  §6.11.4 R-6.11.4 reconnect uses `hello` not v2 — verify
     this matches SPEC-011 v0.5 §3.8.3 (which is the binding
     source).

### Category C: Code-grounding accuracy

C.1  Run each line-citation spot-check enumerated in critical
     constraint 6. Any miscite = MAJOR (an inherited miscite
     from SPEC-011 v0.5 is still SPEC-001's responsibility to
     get right).

C.2  §6.8.1 R-6.8.1 cites
     `ModelRuntime.swift` lines 25-68, 86-147 for the immutable
     `let` fields. Verify the actual file has `actor ModelRuntime`
     starting at line 25 with `private let modelID`,
     `private let container`, `private let modelHash` fields.

C.3  R-6.10.2 (post-polish) cites `modelWeightArtifactManifestHash`
     at lines 294-325 AND `hexString` at line 340. Verify both
     line numbers against the actual source.

### Category D: Four-cell opt-in matrix correctness

D.1  Read §6.7.3 four-cell matrix (lines 1713-1718). For each
     of the 4 cells, verify:
     - Cell 1 (unset/unset): "no `supported_models`,
       `publishes_supported_models`, `model_hash`, or `loading`
       fields are emitted" — matches SPEC-010 R-3.6.2 (which
       says `[model_id]` is sent when unset) and SPEC-011 R-3.3.0
       (which says fields omitted in disabled mode). The §6.7.3
       cell text says fields are NOT emitted — is this consistent
       with SPEC-010 R-3.6.2 which says single-entry IS sent?
       Re-read both: SPEC-010 R-3.6.1 priority resolution says
       unset → no `--supported-models`, then R-3.6.2 says "If
       `supported_models` is unset after resolution, the provider
       MUST send `supported_models: [model_id]` (single-entry)."
       So unset/unset MUST emit `supported_models: [model_id]`.
       The §6.7.3 row 1 text says "No `supported_models` ... are
       emitted." This may be a CONTRADICTION = MAJOR. Or it may
       be a scoping issue (R-3.6.2 applies only when
       `publishes_supported_models: true`?). Read SPEC-010 R-3.6.2
       and R-3.6.4 together carefully and report.

D.2  Cell 2 (set/unset): documented behavior matches SPEC-010
     R-3.6.1 + R-3.6.4? (catalog published, no warm swap).

D.3  Cell 3 (unset/set): documented behavior matches? (warm
     swap heartbeat fields present; catalog is `[model_id]`
     single-entry per SPEC-010 R-3.6.2). Same D.1 ambiguity
     applies — when does single-entry get sent?

D.4  Cell 4 (set/set): documented behavior matches both opt-ins
     active.

### Category E: AC-18.x tracing and coverage

E.1  Each AC-18.0 through AC-18.11 cites a binding SPEC-010
     v1.5 AC or SPEC-011 v0.5 AC by number. Verify each cite
     by reading the named AC in the locked spec. Cite that
     doesn't trace = MAJOR.

E.2  AC coverage gaps: does v1.3 introduce a normative behavior
     (R-rule) not covered by any AC-18.x? Examples to check:
     - Detection precedence (R-6.9.5) — covered?
     - Cooldown soft guard + `--force` (R-6.11.5) — covered?
     - WS drop reconnect uses `hello` not v2 (R-6.11.4) —
       covered?
     - State machine state values (R-6.8.3) — covered?
     - No-starve rule (R-6.8.5) — AC-18.7 partial coverage;
       is the "distinct task isolation" claim testable?
     Each gap = MINOR (this is a NEW spec; AC drift is
     expected to be polished round-2).

### Category F: §6.2 CLI additions

F.1  All 6 new flags (`--supported-models`,
     `--publish-supported-models`, `--enable-warm-swap`,
     `--swap-drain-timeout-seconds`, `--ctl-socket-path`,
     `--switch-state-path`) documented with: default value,
     env var name (when applicable), priority order (where
     applicable), exit code on validation failure, valid range.

F.2  `models` subcommand documented with all 3 actions
     (list/switch/status) and the `--force` flag scope.

F.3  Exit code enumeration consistent across §6.2 + §6.9.3
     + §6.11 + AC-18.x.

### Category G: §2 scope additions

G.1  Two new bullets in §2 "In Tier 1 launch scope (build now)"
     correctly summarize the SPEC-010 + SPEC-011 absorption.

G.2  No bullet added in §2 "Out of scope" that should be there
     (e.g., SPEC-012 buyer-picker visibility — is it explicitly
     out-of-scope in §2 for v1.3?).

### Category H: Change-log + §11 hand-off

H.1  Change-log v1.3 header present above v1.2.4 header
     (post-polish). Prior change-log entries (v1.2.4, v1.2.3,
     v1.2.2, v1.2.1, v1.2, v1.1.x) byte-identical to v1.2.4.

H.2  `Revision:` line at top describes v1.3 (post-polish).

H.3  §11 file structure section lists 4 new Swift files
     (`ModelsSubcommand.swift`, `ControlSocket.swift`,
     `RuntimeStateMachine.swift`, `SupportedModels.swift`)
     and 3 modified files (`ModelRuntime.swift`,
     `CoordinatorClient.swift`, `MacProviderCLI.swift`).

### Category I: Anything else

I.1  Documentation drift not covered above.

I.2  Internal cross-references between §6.7-§6.11 sections
     correct (e.g., §6.10.4 cites §6.10 emission rule; §6.11.4
     cites §6.10.4 source-of-truth).

I.3  Tier-2 fields (`provider_ecdh_public_key`,
     `tier2_capabilities`, `attestation_token`) handling
     unchanged from SPEC-008 v0.3 — no v1.3 surface accidentally
     re-specs Tier-2.

I.4  Buyer API surface (`POST /v1/chat/completions`,
     `GET /v1/models`, `GET /v1/health`) unchanged.

## Output structure

CREATE `/Users/augstar/macprovider-poc/specs/SPEC-001-v1-3-audit.md`
with the following top-of-file structure:

```
# SPEC-001 v1.3 audit history

## Round 1 — Codex GPT-5 — 2026-06-06 — Normative audit

**Audited:** SPEC-001 v1.3 (specs/SPEC-001-phase3-binary.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 1 of N (normative)
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

### Round-1 executive summary

[2-3 sentences. State the verdict explicitly:
- "LOCK CONFIRMED" (0/0/0)
- "LOCK-READY pending narrow polish" (0/0/N with N ≤ 3 and
  MINORs are non-blocking)
- "POLISH ROUND REQUIRED" (0/N-MAJOR/N-MINOR with N-MAJOR ≥ 1)
- "REVISION REQUIRED" (any CRITICAL)]
```

Then for each category A-I, write a section. For each finding:
severity, location (§ / line / R-rule), what/why/recommendation.

If a category has zero findings, write `(no findings)`.

## Out of scope

- d-inference inspection
- Rewriting the spec (you may suggest edits but do not apply)
- Implementing the spec (no Swift code changes)
- Editing SPEC-002, SPEC-004, SPEC-005, SPEC-006, SPEC-008,
  SPEC-010, SPEC-011 (all LOCKED)
- Re-litigating the SPEC-010 / SPEC-011 audit verdicts
- The arm64golf canary pain #3 (buyer-picker visibility) and
  pain #4 (HF ID discovery) — both deferred to SPEC-012

## Done criteria

You are done when:

- `specs/SPEC-001-v1-3-audit.md` created with the round-1 section
- Every category A-I has a section
- Every R-rule in §6.7-§6.11 has been sampled at least once for
  citation accuracy
- §6.5 byte-identity spot-check executed and result reported
  (PASS or FAIL with diff output)
- `grep -n 'XDG_RUNTIME_DIR' specs/SPEC-001-phase3-binary.md`
  spot-check executed and result reported
- All 8 line citations enumerated in critical constraint 6
  spot-checked against actual source
- Executive summary states the explicit verdict
- `git diff phase3-binary/` confirmed empty
- `git diff specs/SPEC-002*.md specs/SPEC-004*.md specs/SPEC-006*.md
  specs/SPEC-008*.md specs/SPEC-010*.md specs/SPEC-011*.md`
  confirmed empty

=== END PROMPT ===
```

---

## Operator notes

- Expected wall-clock: 20-40 min (5 new sections + 12 ACs +
  citation accuracy spot-checks).
- If verdict is LOCK CONFIRMED (0/0/0): lock SPEC-001 v1.3,
  draft Entry 56 to `beta/DECISION_CRITERIA.md`, proceed to
  `BUILD_SPEC_002_v1_3_5_PROMPT.md` (coordinator-side counterpart
  per Entry 55 followups).
- If verdict is LOCK-READY pending polish (0/0/1-3 MINOR):
  apply polish edits, run a round-2 LOCK-confirmation audit
  (mirroring SPEC-010 v1.5 round 6 + SPEC-011 v0.5 round 4
  shape).
- If verdict surfaces MAJORs: revise v1.3 → v1.3.1 and re-run.
  Mirror SPEC-011 v0.5 trajectory (round 1: 2/5/3 → round 2:
  0/2/4 → round 3: 0/0/2 → round 4: 0/0/0 LOCK).
- The D.1 finding category (SPEC-010 R-3.6.2 single-entry
  emission vs §6.7.3 cell-1 "fields not emitted") is the
  highest-prior-probability MAJOR; pre-flag it to the operator
  if the audit raises it.
