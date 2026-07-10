# Build prompt — SPEC-001 v1.2.4 → v1.3 (v2 `auth_request` + operator-pushed warm swap)

Operator-paste prompt to revise the locked SPEC-001 v1.2.4 into
v1.3, folding in the binary-side surface of two now-LOCKED specs:

- **SPEC-010 v1.5** (Provider Model Catalog, LOCKED 2026-06-06 — see
  `beta/DECISION_CRITERIA.md` Entry 54)
- **SPEC-011 v0.5** (Operator-Pushed Warm Swap, LOCKED 2026-06-06 —
  see `beta/DECISION_CRITERIA.md` Entry 55)

This is a **revision-in-place** of an already-locked spec, not a
from-scratch draft. The mission of SPEC-001 (the Mac Provider Swift
binary) is unchanged; v1.3 adds normative sections and CLI surface
that the binary must implement to satisfy SPEC-010 v1.5 §3.6 +
SPEC-011 v0.5 §3.1 / §3.2 / §3.3 / §3.4 / §3.5 / §3.7 / §3.8 / §3.9
as the binding source-of-truth for binary-side behavior.

**One-line scope summary.** Add `--supported-models`,
`--publish-supported-models`, `--enable-warm-swap`, and three
companion flags to the binary; add the `models` subcommand with
`list / switch / status` actions; add a normative v2 `auth_request`
handshake section (locked SPEC-001 §6.5 currently only documents
the legacy `hello` handshake); add normative sections for the
warm-swap runtime state machine, the control socket protocol, the
heartbeat extension, and the concurrent-switch / WS-drop policies.

**Locked-spec dependencies (DO NOT contradict).**
- SPEC-001 v1.2.4 (the file being edited — change-log carries forward)
- SPEC-002 v1.3.4
- SPEC-004 v0.3.1
- SPEC-005 (current locked version)
- SPEC-006 v0.8.1
- SPEC-008 v0.3
- **SPEC-010 v1.5** (binding source for §3.1.A field table, §3.6 CLI flags, R-3.1.10 retention)
- **SPEC-011 v0.5** (binding source for §3.1 CLI subcommand, §3.2 state machine, §3.3 heartbeat extension, §3.4 drain, §3.5 SPEC-008 re-verification, §3.7 concurrent switch, §3.8 WS drop, §3.9 config)

Spec-text-only revision. **No Swift code changes in this session.**
The implementation pass that consumes SPEC-001 v1.3 is a separate
future session (matching the SPEC-001 v1.2.x discipline). Verify
with `git diff phase3-binary/` after edits — should be empty.

Run in **Claude Code** or **Codex CLI**. Expected duration:
~90-120 min (4 NEW normative sections + §6.2 / §6.5 edits + change-log
+ AC additions + companion-spec annotations).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are revising SPEC-001 v1.2.4 in place to v1.3, folding in the
binary-side surface of SPEC-010 v1.5 (Provider Model Catalog,
LOCKED) and SPEC-011 v0.5 (Operator-Pushed Warm Swap, LOCKED).

You will edit ONE file in place:
  /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
  v1.2.4 → v1.3

You will NOT write any code. This is a spec-text-only revision.
Verify with `git diff phase3-binary/` after edits — must be empty.
Verify with `git diff specs/SPEC-002-coordinator.md
specs/SPEC-004-coordinator-dispatch.md specs/SPEC-006-buyer-api.md
specs/SPEC-008-tier2-attestation.md specs/SPEC-010-model-catalog.md
specs/SPEC-011-operator-pushed-warm-swap.md` after edits — must be
empty.

## Critical constraints

**1. SPEC-010 v1.5 and SPEC-011 v0.5 are LOCKED and READ-ONLY.**
Both audited to 0 CRITICAL / 0 MAJOR / 0 MINOR. Do not edit either
file. If your draft of SPEC-001 v1.3 would require a change to
either spec, STOP and surface the conflict in a comment near the
top of the SPEC-001 v1.3 change log — do not invent a contradiction
under the SPEC-001 banner.

**2. Locked SPEC-001 v1.2.4 backward-compat clauses READ-ONLY.**
The verbatim backward-compat statement near the top of SPEC-001
must stay byte-identical. The v1.2.x change-log entries already
present must stay byte-identical (you APPEND a new v1.3 change-log
entry; do not edit prior entries).

**3. L-1 byte-identical default MUST be preserved literally.**
SPEC-011 L-1 requires that a binary built from SPEC-001 v1.3 but
invoked WITHOUT `--enable-warm-swap` MUST exhibit byte-identical
on-the-wire behavior to a SPEC-001 v1.2.4 binary. Your spec text
MUST make this gating explicit in every section that introduces a
new wire field, heartbeat field, or socket. The phrasing pattern is:
"emitted by the binary ONLY when `--enable-warm-swap` is enabled
(per R-3.1.0 of SPEC-011 v0.5); in disabled mode, the field MUST
be omitted from the wire entirely." Mirror SPEC-011 R-3.1.0 +
R-3.3.0 wording.

**4. SPEC-010 fields are independently gated.** The two SPEC-010
fields (`supported_models[]` and `publishes_supported_models`) are
controlled by `--supported-models` / `--publish-supported-models`
flags per SPEC-010 R-3.6.1 / R-3.6.4 — NOT by `--enable-warm-swap`.
A SPEC-001 v1.3 binary may publish model catalog (SPEC-010 opt-in)
WITHOUT enabling warm swap (SPEC-011 opt-in), and vice versa. The
two opt-ins are orthogonal. Both default to OFF.

**5. Buyer API stability.** `POST /v1/chat/completions`,
`GET /v1/models`, `GET /v1/health` semantics unchanged. No
binary-side `/v1/models` change in v1.3 — the local-only
single-entry response stays as today (per SPEC-010 §6.1 note).

**6. v2 `auth_request` handshake is a NEW normative section.**
Locked SPEC-001 v1.2.4 §6.5 documents the legacy `hello` handshake
only. SPEC-001 v1.3 MUST ADD a new normative section (numbered
§6.7, not §6.5.2, to leave the existing §6.5 byte-identical) that
documents the v2 two-stage `auth_request` handshake (`initial` +
`proof` stages). This is a normative addition driven by SPEC-010
v1.5 §6.1 — the v2 contract has been in code since SPEC-001 v1.2.x
but was never normatively documented; v1.3 closes that gap. The
SPEC-010-added fields (`supported_models[]`,
`publishes_supported_models`) are documented as part of this new
v2 section, NOT under legacy §6.5.

**7. §6 numbering — use §6.7 onwards.** SPEC-001 v1.2.4's §6
currently has §6.0 through §6.6 occupied. SPEC-011's §6.1
explicitly directs new sections to §6.7+ (per E.2 round-1 fix in
SPEC-011 audit history). Concretely:
  - §6.7 — v2 `auth_request` handshake (NEW, normative)
  - §6.8 — Warm-swap opt-in gate + runtime state machine (NEW, normative)
  - §6.9 — Control socket protocol (NEW, normative)
  - §6.10 — Heartbeat extension (NEW, normative, additive-when-opt-in)
  - §6.11 — Concurrent switch + WS drop policies (NEW, normative)

**8. Surgical scope.** Add sections; do not rewrite existing ones.
Three categories of edits:
  (a) **APPEND** a v1.3 change-log entry at the top of the file.
  (b) **EXTEND** §6.2 (or the CLI flag section, locate via grep
      `--model` and `--provider-id`) with the new flags from
      SPEC-010 R-3.6.1, R-3.6.4 and SPEC-011 R-3.1.0, R-3.1.3,
      R-3.1.4, R-3.1.5 in additive-only form. Do NOT rewrite
      existing flag descriptions; add new ones at the end of the
      flag list with cross-cites to the binding spec rule.
  (c) **ADD** NEW normative sections §6.7-§6.11 per constraint 7.
  (d) **APPEND** new acceptance criteria at the end of §9 (do not
      renumber existing ACs).

**9. Locked-spec citations are normative, not informational.**
Every new R-rule in §6.7-§6.11 MUST cite the binding SPEC-010 v1.5
or SPEC-011 v0.5 rule. Example:
  "R-6.8.1 The binary MUST refuse to open the control socket
   unless `--enable-warm-swap` was passed to `serve` per
   SPEC-011 v0.5 R-3.1.0."
Avoid restating the locked rule's body — cite it and add only the
binary-side specifics (file paths, Swift type names, default
values) that belong in SPEC-001.

**10. macOS-native platform conventions.** All filesystem paths
MUST be macOS-native per SPEC-011 v0.5 R-3.1.5 / R-3.1.4:
  - Control socket default: `$TMPDIR/macprovider-cli/ctl.sock`
    (NOT `$XDG_RUNTIME_DIR/...`; that variable is unset on stock
    macOS, verified empirically in SPEC-011 v0.5 R-3.1.5 "Why not"
    block). Swift code resolves via
    `FileManager.default.temporaryDirectory`.
  - Cooldown state file default:
    `$HOME/Library/Application Support/macprovider-cli/last-switch.ts`.
  - Socket parent dir mode `0700`; socket mode `0600`.
If any v1.3 section accidentally references `$XDG_RUNTIME_DIR` as
a default, that is a FAIL — re-read SPEC-011 R-3.1.5.

**11. Two opt-ins, three matrix cells matter.**
  | `--supported-models` | `--enable-warm-swap` | Behavior cell |
  |---|---|---|
  | unset | unset | LEGACY: byte-identical to SPEC-001 v1.2.4 (L-1 default) |
  | set | unset | SPEC-010 only: provider publishes catalog; no warm swap; no `model_hash`/`loading` heartbeat fields |
  | unset | set | SPEC-011 only: warm swap enabled; heartbeat carries `model_hash`/`loading`; catalog is `[model_id]` (single-entry, per SPEC-010 R-3.6.2) |
  | set | set | BOTH: catalog published AND warm swap enabled |
Your v1.3 spec text MUST document all four cells explicitly,
either inline in §6.7/§6.8 or as a dedicated table in a new §6.7.0
or appendix subsection. AC-9 (below) verifies this matrix.

**12. d-inference clean-room.** Do not inspect d-inference source.

**13. No Tier-2 expansion in v1.3.** The Tier-2 (SPEC-008) story
is unchanged. v1.3 does NOT add any encrypted-leg, attestation, or
TEE behavior beyond what SPEC-001 v1.2.4 already specifies.
Tier-2 fields (`provider_ecdh_public_key`, `tier2_capabilities`,
`attestation_token`) remain documented in the v2 `auth_request`
section per SPEC-010 §3.1.A but their handling rules are unchanged
from current code (cite SPEC-008 v0.3 by reference; do not restate).

## Required reading (in this order — read fully before writing
anything)

1. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.2.4 — read full document. Focus on:
   - Top change-log block (lines ~3-15) — you APPEND a v1.3 entry
   - §6.0 through §6.6 — these stay byte-identical
   - §6.5 (Coordinator WebSocket envelope) — your NEW §6.7 will
     reference but not modify this
   - §9 (Acceptance criteria) — you APPEND new ACs at the end
   - §2 (Scope) — locate "In Tier 1 launch scope (build now)" and
     append two bullet items for SPEC-010 capability advertisement
     (operator opt-in) and SPEC-011 warm swap (operator opt-in)
   - The verbatim backward-compat clause — must stay byte-identical

2. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.5 (LOCKED) — read full document. Focus on:
   - §3.1.A (parser-required field table for v2 `auth_request`
     initial-stage) — this is the SOURCE for your NEW §6.7 field
     table
   - §3.1.B (wire example with all parser-required fields +
     SPEC-010 additions) — copy structure into your §6.7
   - §3.1.C (proof-stage field table) — source for your §6.7
     proof-stage subsection
   - §3.1 rules R-3.1.1 through R-3.1.10 — cite normatively from
     SPEC-001 §6.7
   - §3.6 (Provider binary CLI) — rules R-3.6.1 through R-3.6.4
     are the binding source for your §6.2 CLI flag additions
   - §6.1 (SPEC-001 v1.2.5 candidate) — read for guidance on what
     SPEC-010 expects SPEC-001 to add (v1.5 calls the target
     "v1.2.5"; this BUILD prompt overrides to v1.3 to bundle with
     SPEC-011 — the section guidance is otherwise correct)

3. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   v0.5 (LOCKED) — read full document. Focus on:
   - §2 (Locked design decisions L-1 through L-7) — L-1
     byte-identical default is the constraint that governs every
     new normative section
   - §3.1 (Provider binary `models` CLI subcommand) — full text;
     rules R-3.1.0 through R-3.1.6 + R-3.1.5.x are the binding
     source for your §6.2 CLI additions + NEW §6.9 control socket
     protocol
   - §3.2 (Provider binary runtime state machine) — full text;
     rules R-3.2.1 through R-3.2.7 are the binding source for your
     NEW §6.8 state machine section. INCLUDE the state-transition
     diagram from SPEC-011 §3.2 in your §6.8 by reference (do not
     redraw — cite "see SPEC-011 v0.5 §3.2 state machine
     diagram").
   - §3.3 (Heartbeat extension) — rules R-3.3.0 through R-3.3.x
     are the binding source for your NEW §6.10 heartbeat extension
   - §3.4 (Drain semantics)
   - §3.5 (SPEC-008 Pillar A re-verification)
   - §3.7 (Concurrent operator-pushed switch)
   - §3.8 (WS drop mid-load) — note the C.2 round-1 fix on
     `hello.model_hash` source-of-truth
   - §3.9 (Config additions) — flag defaults + env names
   - §6.1 (SPEC-001 v1.3 candidate) — this is the explicit
     guidance from the LOCKED spec on how SPEC-001 v1.3 should
     map. Follow the §6.7-§6.11 numbering it prescribes.

4. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.4 (LOCKED) — read §3 (provider state machine) and §7.1
   (provider WebSocket protocol) to verify your §6.7-§6.11 text
   does not contradict locked coordinator behavior. Do NOT edit
   this file.

5. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2-attestation.md`
   v0.3 (LOCKED) — read §5.3-5.7 (Pillar A pipeline + five-state
   hash enumeration) so that your §6.10 heartbeat extension text
   citing the post-swap re-verification path matches the locked
   pipeline shape. Do NOT edit this file.

6. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md`
   Entries 54 (SPEC-010 v1.5 lock) and 55 (SPEC-011 v0.5 lock).
   These give the strategic context: the scope-split decision that
   produced two narrow LOCKABLE specs out of a wide-scope spec
   that wouldn't converge, and the four-pain arm64golf canary
   that triggered the work.

7. `/Users/augstar/macprovider-poc/CLAUDE.md` — repo conventions.

8. Code spot-check (READ-ONLY, for grounding only):
   - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
     lines 7-15 — existing subcommands (`serve`, `status`,
     `self-test`, `update`, `uninstall`); SPEC-011 adds `models`
     as the sixth.
   - `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
     lines 25-68, 86-147 — the immutable-actor architecture that
     SPEC-011 R-3.2.1 mandates refactoring to mutable
     actor-isolated `current_container`. Your §6.8 text MUST be
     consistent with this refactor (cite SPEC-011 R-3.2.1).
   - `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
     lines 675-697 — existing `helloMessage` emits `model_hash`.
     Note for your §6.10: the `hello` path (legacy reconnect) and
     the v2 `auth_request` path both have a `model_hash` field;
     they MUST agree at any given moment. SPEC-011 §3.8.3 C.2 fix
     spells out the source-of-truth rule on reconnect.
   - `phase4-coordinator/internal/ws/messages.go` lines 37-57
     (AuthRequest struct), 302-329 (frame validator), 333-388
     (parseAuthInitial), 391-401 (parseAuthProof). These are the
     parser truth for your §6.7 field tables.
   - `phase4-coordinator/internal/ws/server.go` line 354
     (`authAttemptID := "auth-" + s.newUUID()`). Your §6.7 v2
     handshake section MUST cite the coordinator-generated
     `auth_attempt_id` semantics correctly (provider does NOT
     generate it; provider echoes it on proof-stage frame).
   - `phase4-coordinator/internal/pool/provider.go` lines 411-432
     (`ApplyHeartbeat`). Your §6.10 heartbeat extension MUST
     note that the coordinator-side hash-clearing REPLACEMENT
     for SPEC-011 heartbeats is the COORDINATOR's responsibility
     (SPEC-002 v1.3.5 candidate per SPEC-011 §6.2); SPEC-001
     v1.3 only specifies what the BINARY emits.

DO NOT inspect d-inference source (clean-room per CLAUDE.md).

## Required edits

### A. Top-of-file change-log

APPEND a v1.3 change-log entry directly under the existing v1.2.4
entry. Use the existing change-log format. Content:

- **v1.3 (2026-06-06, SPEC-010 v1.5 + SPEC-011 v0.5 absorption):**
  Adds binary-side surface for two now-LOCKED companion specs.
  SPEC-010 v1.5 adds `--supported-models` /
  `--publish-supported-models` flags, gains the two optional v2
  `auth_request` initial-stage fields, gains local pre-flight
  validation per R-3.6.3. SPEC-011 v0.5 adds `--enable-warm-swap`
  opt-in gate, `--swap-drain-timeout-seconds`, `--ctl-socket-path`,
  `--switch-state-path` flags on `serve`; adds the `models`
  subcommand with `list / switch / status` actions; mandates a
  `ModelRuntime` refactor from immutable `let container` to
  actor-isolated mutable `current_container` with an atomic-swap
  state machine; adds an opt-in heartbeat extension carrying
  `model_hash` (raw lowercase hex) and `loading: bool`; adds a
  newline-delimited JSON control socket protocol on a macOS-native
  `$TMPDIR`-based path. ALSO adds a new normative §6.7 v2
  `auth_request` handshake section — the v2 contract has been in
  code since v1.2.x but was never normatively documented in
  SPEC-001; v1.3 closes that gap. L-1 byte-identical default
  preserved literally: with neither flag set, a v1.3 binary's
  on-the-wire behavior is byte-identical to a v1.2.4 binary.

### B. §2 Scope — extend "In Tier 1 launch scope (build now)"

Locate "In Tier 1 launch scope (build now)" and APPEND two bullets
at the end of that list:

- Operator-opt-in capability advertisement per SPEC-010 v1.5 §3.6
  (`--supported-models`, `--publish-supported-models`). Default
  OFF; when on, the v2 `auth_request` initial-stage frame carries
  `supported_models[]` and `publishes_supported_models: true`.
- Operator-opt-in warm model swap per SPEC-011 v0.5 §3.1-§3.9
  (`--enable-warm-swap`). Default OFF; when on, enables the
  `models switch <id>` operator workflow, the in-process runtime
  state machine, the control socket, and the extended heartbeat
  fields. Closes arm64golf canary operator pains #1 (multi-minute
  restart loop to change served model) and #2 (red-dashboard / WS
  reconnect on swap).

### C. §6.2 — add new CLI flags (additive only)

Locate the §6.2 CLI flag section (or wherever `--provider-id` and
`--model` are normatively defined; grep `--provider-id` to find).
APPEND the following flag descriptions at the end of the flag
list. Do NOT rewrite existing flag text.

Two flags from SPEC-010 v1.5:
- `--supported-models <ids>` — comma-separated list of HuggingFace
  model IDs (or local paths) per SPEC-010 R-3.6.1. Resolution
  priority CLI > ENV (`MACPROVIDER_SUPPORTED_MODELS`) > config key
  `supported_models: [string]`. Default unset; when unset, the
  binary sends `supported_models: [model_id]` (single-entry) on
  the v2 `auth_request` initial-stage frame per SPEC-010 R-3.6.2.
  Local pre-flight per SPEC-010 R-3.6.3: validates
  `model_id ∈ supported_models` (case-folded), array length ≤ 64,
  each entry ≤ 256 UTF-8 bytes. Validation failures exit code 2
  with specific stderr per SPEC-010 R-3.6.3 / R-3.1.9.
- `--publish-supported-models <bool>` — opt-in flag per SPEC-010
  R-3.6.4. Default `false`. When `true`, populates the
  `publishes_supported_models: true` field on the v2
  `auth_request` initial-stage frame.

Four flags from SPEC-011 v0.5:
- `--enable-warm-swap` — opt-in gate per SPEC-011 R-3.1.0.
  Boolean (presence enables; explicit `=true` / `=false`
  supported). Default DISABLED. When disabled, the binary MUST
  NOT open the control socket, MUST NOT host the §6.8 state
  machine (legacy synchronous load path remains), MUST NOT emit
  `loading` or `model_hash` heartbeat fields. Preserves L-1
  byte-identical default. This flag is exclusive to `serve`; it
  is not valid on `models <subcommand>`.
- `--swap-drain-timeout-seconds <N>` — drain budget per SPEC-011
  §3.4 / §3.9. Default per SPEC-011 §3.9 config block. Only
  meaningful when `--enable-warm-swap` is set.
- `--ctl-socket-path <path>` — override the macOS-native default
  per SPEC-011 R-3.1.5. Default
  `$TMPDIR/macprovider-cli/ctl.sock` (resolved via
  `FileManager.default.temporaryDirectory`). Socket parent dir
  mode `0700`; socket mode `0600`. Only meaningful when
  `--enable-warm-swap` is set.
- `--switch-state-path <path>` — override the cooldown state file
  per SPEC-011 R-3.1.4. Default
  `$HOME/Library/Application Support/macprovider-cli/last-switch.ts`.

ALSO add the `models` subcommand to the §6.2 subcommand list (or
the appropriate top-of-CLI inventory). Subcommands `models list`,
`models switch <model-id> [--force]`, `models status` per SPEC-011
§3.1. `--force` suppresses ONLY the CLI-side cooldown soft guard
per SPEC-011 R-3.1.3.

### D. NEW §6.7 — v2 `auth_request` handshake (NORMATIVE)

Add as a new top-level subsection after the existing §6.6. The
section title is "6.7. v2 `auth_request` handshake (NEW in v1.3)".

Content requirements:

D.1 Opening paragraph: state explicitly that locked SPEC-001
v1.2.4 §6.5 documents the legacy `hello` handshake, and that the
v2 `auth_request` two-stage handshake has been in code since
SPEC-001 v1.2.x but was never normatively documented in SPEC-001.
This section closes that gap. The legacy `hello` handshake at
§6.5 remains the back-compat reconnect path; the v2
`auth_request` handshake is the modern path that supports the
SPEC-010 fields and the SPEC-008 Tier-2 attestation hooks.

D.2 Subsection §6.7.1: "Initial-stage frame (P→C)". Reproduce the
SPEC-010 v1.5 §3.1.A field table verbatim (or by reference with a
cross-cite "see SPEC-010 v1.5 §3.1.A for the parser-required field
table; SPEC-001 v1.3 is consistent with that table"). Include the
wire example from SPEC-010 §3.1.B. Document that the binary
populates this frame from the same flag resolution as the legacy
`hello` (provider_id from CLI > ENV > config; model_id from
`--model`) PLUS the new SPEC-010 fields per §6.2 above.

D.3 Subsection §6.7.2: "Proof-stage frame (P→C)". Reproduce the
SPEC-010 v1.5 §3.1.C proof-stage field table (verbatim or by
reference). Document the contract clearly: the coordinator
generates `auth_attempt_id` (see
`phase4-coordinator/internal/ws/server.go:354`); the binary does
NOT generate it; the binary ECHOES the value from the prior
`auth_challenge` on the proof-stage frame. If the binary chooses
to re-send `supported_models[]` or `publishes_supported_models`
on the proof stage, the values MUST be byte-identical to the
initial-stage values (per SPEC-010 R-3.1.10).

D.4 Subsection §6.7.3: "Two opt-ins, four matrix cells". Document
all four cells of the SPEC-010 × SPEC-011 opt-in matrix per
constraint 11 above. This is the canonical place for the matrix.

D.5 Subsection §6.7.4: "Back-compat with legacy hello".
- A v1.3 binary uses v2 `auth_request` for the FIRST connection
  attempt with a coordinator (whether or not either opt-in is
  set; v2 is the default handshake for v1.3+ binaries).
- The legacy `hello` handshake at §6.5 remains the reconnect-mid-
  session path per SPEC-011 §3.8.3 (WS drop reconnect after
  warm-swap-in-flight).
- A pre-v1.3 (v1.2.x) binary uses legacy `hello` on first
  connect; the coordinator accepts both paths per its locked
  `MessageType` switch.

### E. NEW §6.8 — Warm-swap opt-in gate + runtime state machine (NORMATIVE)

Add as "6.8. Warm-swap opt-in gate + runtime state machine (NEW
in v1.3)".

Content requirements:

E.1 Opening paragraph: cite SPEC-011 v0.5 §2 L-1 (byte-identical
default) and L-2 (opt-in gate). Restate the gate: the §6.8
state machine, the §6.9 control socket, and the §6.10 heartbeat
extension activate ONLY when the operator invokes `serve` with
`--enable-warm-swap`. In disabled mode, the binary follows the
SPEC-001 v1.2.4 synchronous-load path (single `let container`
populated at boot per the current `ModelRuntime` actor).

E.2 Subsection §6.8.1: "ModelRuntime refactor (REQUIRED when
warm swap enabled)". Cite SPEC-011 R-3.2.1. State that the
existing immutable `let container` / `let modelID` / `let
modelHash` fields in `ModelRuntime`
(`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
lines 25-68, 86-147) MUST be refactored to actor-isolated
mutable state when warm swap is enabled. The actor MUST expose:
- `currentContainer() -> ModelContainer` — snapshot read for
  inference dispatch
- `swap(new: ModelContainer, newID: String, newHash: String)` —
  atomic four-step replacement per SPEC-011 R-3.2.4

E.3 Subsection §6.8.2: "State enumeration". Reproduce SPEC-011
§3.2 state values (`ready` / `loading` / `draining` / `failed`)
with the SPEC-011 R-3.2.3 semantics. Include the SPEC-011 state
machine diagram by reference (see SPEC-011 v0.5 §3.2). Do NOT
redraw the diagram.

E.4 Subsection §6.8.3: "Inference-while-loading rejection".
Cite SPEC-011 R-3.2.3. State that in `loading` or `draining`
states, NEW HTTP inference requests to the binary MUST be
rejected with HTTP 503 + OpenAI envelope
`{error: {type: "service_unavailable", code: "provider_loading"}}`.
In-flight requests started in `ready` state MUST continue to
completion using their snapshot reference per R-3.2.2.

E.5 Subsection §6.8.4: "No-starve rule". Cite SPEC-011 R-3.2.5
and SPEC-002 §11 J.1 (v1.1.6 35s heartbeat-miss kill incident).
Async load task MUST run on a Swift task isolation distinct from
the WebSocket receive loop, the WebSocket send loop (including
heartbeat emission), and the HTTP inference server's accept
loop. Heartbeat MUST continue at the negotiated cadence
throughout `loading` and `draining` states.

E.6 Subsection §6.8.5: "Rollback semantics". Cite SPEC-011
R-3.2.6 and reproduce the rollback contract.

E.7 Subsection §6.8.6: "Boot path unchanged". Cite SPEC-011
R-3.2.7. The startup-time synchronous load (`--model X` at boot)
populates `current_container` once and transitions directly to
`ready` without going through `loading`. This preserves existing
boot semantics and L-1 back-compat.

### F. NEW §6.9 — Control socket protocol (NORMATIVE)

Add as "6.9. Control socket protocol (NEW in v1.3)".

Content requirements:

F.1 Opening paragraph: cite SPEC-011 R-3.1.5. State the macOS-
native default path (`$TMPDIR/macprovider-cli/ctl.sock`) and the
"Why not `$XDG_RUNTIME_DIR`" rationale (Linux/freedesktop
convention, unset on stock macOS, verified empirically).

F.2 Subsection §6.9.1: "Wire format". Newline-delimited JSON.
Every frame MUST include a REQUIRED `type` field (cite SPEC-011
R-3.1.5 B.1 round-1 fix). Reproduce the SPEC-011 R-3.1.5 field
reference table (or include by reference).

F.3 Subsection §6.9.2: "Frame types". Reproduce or cite the
SPEC-011 R-3.1.5 schemas for `switch_request`, `status_request`,
`switch_ack`, `switch_progress`, `status_response`. Include the
typed `switch_ack` shape with REQUIRED `type` field per SPEC-011
v0.5 R-3.7.3.

F.4 Subsection §6.9.3: "Detection precedence". Reproduce or
cite SPEC-011 R-3.1.5.x three-case detection precedence (ENOENT
→ fresh start exit 4; ECONNREFUSED → stale socket exit 4;
handshake timeout → wedged-process exit 4) with the specific
stderr messages.

F.5 Subsection §6.9.4: "Permissions and lifecycle". Cite
SPEC-011 R-3.1.5. Socket parent dir mode `0700`; socket mode
`0600`. Socket is opened on `serve` startup when
`--enable-warm-swap` is set; socket is closed on `serve`
shutdown. Stale-socket reclaim (ECONNREFUSED case) requires
operator removal of the file before restart (per R-3.1.5.x case
2 stderr).

### G. NEW §6.10 — Heartbeat extension (NORMATIVE, additive-when-opt-in)

Add as "6.10. Heartbeat extension (NEW in v1.3, additive when
warm-swap opt-in is enabled)".

Content requirements:

G.1 Opening paragraph: state that §6.10 specifies what the
BINARY emits. The COORDINATOR-side handling (including the
hash-clearing REPLACEMENT for `ApplyHeartbeat` at
`phase4-coordinator/internal/pool/provider.go:411-432`) is
covered by the SPEC-002 v1.3.5 candidate per SPEC-011 §6.2 and
is NOT in scope for SPEC-001 v1.3.

G.2 Subsection §6.10.1: "Opt-in gating". Cite SPEC-011 R-3.3.0.
The `model_hash` and `loading` heartbeat fields MUST be emitted
ONLY when the operator started `serve` with `--enable-warm-swap`.
In disabled mode, both fields MUST be omitted from the wire
entirely. Preserves L-1 byte-identical default.

G.3 Subsection §6.10.2: "Field definitions". Cite SPEC-011
R-3.3.1. `model_hash` is a raw 64-character lowercase hex string
(matching `hexString()` at
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:294-325`).
`loading: bool` reflects the §6.8 state machine (`true` when
state is `loading` or `draining`; `false` when state is `ready`).

G.4 Subsection §6.10.3: "Emission cadence". Cite SPEC-011
R-3.2.5. Heartbeat continues at the SPEC-002 §7.1 negotiated
cadence throughout all state machine states. The `loading: true`
transition is communicated by the FIRST heartbeat after state
enters `loading`; the new `model_hash` is communicated by the
FIRST heartbeat after the atomic swap into `ready` (per SPEC-011
R-3.2.4 step 4 "signal heartbeat task to emit a new heartbeat
with the new fields").

G.5 Subsection §6.10.4: "Hash source-of-truth on reconnect (WS
drop)". Cite SPEC-011 §3.8.3 (C.2 round-1 fix). After a WS drop
mid-swap, the binary reconnects via legacy `hello` (per SPEC-011
§3.8). The `hello.model_hash` field MUST carry the hash of the
container currently referenced by `current_container` at the
moment of reconnect — NOT the hash of the in-progress load
target. If the swap was mid-`loading` when the WS dropped, the
in-process state stays as it was (the load continues
independently of the WS); on reconnect, `hello.model_hash` is
the OLD hash; the binary's next post-reconnect heartbeat will
carry the new hash once the swap completes per the normal §6.10
emission rule.

### H. NEW §6.11 — Concurrent switch + WS drop policies (NORMATIVE)

Add as "6.11. Concurrent switch + WS drop policies (NEW in
v1.3)".

Content requirements:

H.1 Subsection §6.11.1: "Concurrent operator-pushed switch".
Cite SPEC-011 §3.7. Reproduce the contract: if a `models switch
<Y>` arrives while a prior `models switch <X>` is still in
`loading` or `draining` state, the serve process MUST reply with
typed `switch_ack` `{accepted: false, reason:
"loading_in_progress", current_target: "X"}`. The CLI MUST exit
code 3. The serve process does NOT queue the second switch.

H.2 Subsection §6.11.2: "WS drop mid-load". Cite SPEC-011 §3.8.
Reproduce the rules: WS drop does NOT abort an in-flight load;
the in-process state machine continues independently of WS
connectivity. Reconnect uses legacy `hello` per §3.8.3 with the
G.5 source-of-truth rule above. v2 `auth_request` is NOT used
on the reconnect path; reconnect carries `provider_id` (same
identity) and the OLD `model_hash` (per G.5).

H.3 Subsection §6.11.3: "Cooldown soft guard". Cite SPEC-011
R-3.1.4. CLI tracks last-switch timestamp at the macOS-native
state file path per §6.2 `--switch-state-path`. Default 10s
cooldown window per L-7. `--force` suppresses ONLY the
CLI-side soft guard.

### I. §9 Acceptance criteria — APPEND new ACs

APPEND new ACs at the end of §9 (do not renumber existing ACs;
the SPEC-001 v1.2.4 AC numbering is locked). Number the new ACs
starting at the next available integer in the existing
sequence. Each new AC MUST cite the binding SPEC-010 v1.5 AC or
SPEC-011 v0.5 AC it traces to.

Required new ACs (minimum):

- AC-N.0 **L-1 byte-identical default.** A v1.3 binary built
  per this spec, invoked with neither `--supported-models` nor
  `--enable-warm-swap`, MUST exhibit byte-identical on-the-wire
  behavior (v2 `auth_request` initial-stage frame, heartbeat
  frame, no control socket file at `$TMPDIR/...`) to a SPEC-001
  v1.2.4 binary. Traces to SPEC-011 v0.5 AC-22 + SPEC-010 v1.5
  AC-2.

- AC-N.1 **SPEC-010 opt-in.** A v1.3 binary invoked with
  `--supported-models A,B,C --publish-supported-models=true
  --model A` MUST send v2 `auth_request` initial-stage with
  `supported_models: [A, B, C]`, `publishes_supported_models:
  true`, `model_id: A`. Traces to SPEC-010 v1.5 AC-1.

- AC-N.2 **SPEC-010 pre-flight.** A v1.3 binary invoked with
  `--supported-models A,B --model C` MUST exit code 2 BEFORE
  opening the coordinator WS with stderr containing
  `"--model C not in --supported-models"`. Traces to SPEC-010
  v1.5 R-3.6.3.

- AC-N.3 **SPEC-011 opt-in gate — disabled mode.** A v1.3
  binary `serve` started without `--enable-warm-swap` MUST NOT
  create any file at `$TMPDIR/macprovider-cli/ctl.sock`. A
  `macprovider-cli models list` invocation against that binary
  MUST exit code 4 with stderr containing `"warm swap not
  enabled"`. Traces to SPEC-011 v0.5 AC-22.

- AC-N.4 **SPEC-011 opt-in gate — enabled mode.** A v1.3
  binary `serve --enable-warm-swap` MUST create the control
  socket with mode `0600` and parent dir mode `0700`. Traces
  to SPEC-011 v0.5 R-3.1.5.

- AC-N.5 **macOS-native socket path.** The default control
  socket path resolves to `$TMPDIR/macprovider-cli/ctl.sock`
  via `FileManager.default.temporaryDirectory`. The path
  `$XDG_RUNTIME_DIR/...` MUST NOT appear anywhere in the
  binary's runtime path resolution (it is a Linux convention;
  unset on macOS). Traces to SPEC-011 v0.5 R-3.1.5.

- AC-N.6 **Atomic swap.** Under `models switch <Y>` while
  serving an in-flight inference request, the in-flight
  request MUST complete using the OLD weights; a NEW request
  arriving AFTER atomic swap completion MUST be served by the
  NEW weights. No caller observes mixed state. Traces to
  SPEC-011 v0.5 R-3.2.2 + R-3.2.4 + AC-7.

- AC-N.7 **No-starve heartbeat.** Heartbeat cadence MUST NOT
  pause during `loading` or `draining`. A SPEC-002 §7.1
  heartbeat-miss threshold MUST NOT be triggered by a model
  swap. Traces to SPEC-011 v0.5 R-3.2.5 + AC-8.

- AC-N.8 **Heartbeat hash format.** When `--enable-warm-swap`
  is set, `model_hash` on heartbeat frames MUST be a 64-char
  lowercase hex string with no `sha256:` prefix and no
  uppercase characters. Traces to SPEC-011 v0.5 R-3.3.1 +
  AC-14.

- AC-N.9 **Four matrix cells.** Test matrix exercises all
  four cells of the SPEC-010 × SPEC-011 opt-in matrix per
  §6.7.3. Each cell's expected wire behavior is verified by
  capturing the v2 `auth_request` frame + first heartbeat.
  Traces to constraint 11 above.

- AC-N.10 **NEW §6.7 v2 handshake documented.** The
  SPEC-001 v1.3 §6.7 v2 `auth_request` handshake section is
  consistent with the SPEC-010 v1.5 §3.1.A field table by
  byte-for-byte field comparison. No field appears in one and
  not the other. Traces to SPEC-010 v1.5 §6.1 normative-
  addition requirement.

- AC-N.11 **No drift in §6.5.** SPEC-001 v1.3 §6.5 (Coordinator
  WebSocket envelope — legacy `hello` handshake) is byte-
  identical to SPEC-001 v1.2.4 §6.5. v1.3 adds the v2
  handshake as a new §6.7; it does NOT modify the legacy
  `hello` documentation. Verifiable by `diff` of the two
  versions' §6.5 sections.

(Optional: more granular ACs covering `models list`, `models
status`, switch exit codes 2/3/4/5/6, `--force` bypass, cooldown
soft guard, WS drop reconnect path, rollback on load failure.
Each MUST cite the binding SPEC-010 / SPEC-011 AC.)

### J. §11 Implementation hand-off — extend

If SPEC-001 v1.2.4 has a §11 (Implementation hand-off / File
structure) section listing expected Swift source files, APPEND
new entries for:

- `phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift`
  — implements `models list`, `models switch`, `models status`
  per §6.2, §6.9.
- `phase3-binary/Sources/macprovider-cli/ControlSocket.swift`
  — implements the §6.9 newline-delimited JSON control socket
  protocol on the macOS-native `$TMPDIR/...` path.
- `phase3-binary/Sources/macprovider-cli/RuntimeStateMachine.swift`
  — implements the §6.8 4-state machine + atomic swap +
  no-starve isolation.
- `phase3-binary/Sources/MacProviderCore/SupportedModels.swift`
  — implements §6.2 `--supported-models` resolution and
  pre-flight validation per SPEC-010 R-3.6.1 / R-3.6.3.

Existing files modified (note in §11):
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
  — REFACTORED per §6.8.1 from immutable `let` to actor-
  isolated mutable `current_container`.
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
  — extended `helloMessage` and v2 `auth_request` builder to
  emit SPEC-010 fields when opt-in flags are set; heartbeat
  builder gains opt-in-gated `model_hash` / `loading` fields
  per §6.10.
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
  — adds `models` subcommand to the existing subcommand list
  (lines 7-15).

## Done criteria

You are done when:

- `git diff specs/SPEC-001-phase3-binary.md` shows ONLY the
  changes prescribed above (new change-log entry, §2 bullets,
  §6.2 flag additions, §6.7-§6.11 NEW sections, §9 NEW ACs,
  §11 file structure extension if applicable). No other
  sections modified.
- `git diff phase3-binary/` is empty.
- `git diff specs/SPEC-002-coordinator.md
  specs/SPEC-004-coordinator-dispatch.md
  specs/SPEC-006-buyer-api.md
  specs/SPEC-008-tier2-attestation.md
  specs/SPEC-010-model-catalog.md
  specs/SPEC-011-operator-pushed-warm-swap.md` is empty.
- The verbatim backward-compat clause near the top of SPEC-001
  is byte-identical to v1.2.4.
- The change-log carries forward all prior entries (v1.2.4,
  v1.2.3, v1.2.2, etc.) byte-identical; only the new v1.3
  entry is added.
- §6.5 (legacy `hello` handshake) is byte-identical to v1.2.4
  (verifiable per AC-N.11).
- Every new R-rule in §6.7-§6.11 cites the binding SPEC-010
  v1.5 or SPEC-011 v0.5 rule.
- No occurrence of `$XDG_RUNTIME_DIR` anywhere in the new spec
  text (except in a "Why not" rationale block mirroring
  SPEC-011 R-3.1.5).
- The four-cell opt-in matrix is documented in §6.7.3.
- All new ACs trace to a SPEC-010 v1.5 AC or SPEC-011 v0.5 AC.
- Version line at top reads `**Version:** 1.3 (2026-06-06,
  SPEC-010 v1.5 + SPEC-011 v0.5 absorption)`.

## Out of scope

- Swift code changes (deferred to implementation pass)
- Editing SPEC-002, SPEC-004, SPEC-005, SPEC-006, SPEC-008,
  SPEC-010, SPEC-011 (all LOCKED at the versions cited above)
- Editing SPEC-001 v1.2.4 sections §0-§6.6, §7, §8, §10 (lock
  preserved — only the change-log, §2 scope additions, §6.2
  flag additions, NEW §6.7-§6.11, NEW §9 ACs, and §11
  hand-off extension are in scope)
- Re-litigating the SPEC-010 / SPEC-011 audit verdicts
- The arm64golf canary pain #3 (buyer-picker visibility) and
  pain #4 (HF ID discovery) — both deferred to SPEC-012 per
  Entry 54 / 55 followups
- Tier-2 expansion (SPEC-008 v0.4 is a separate future spec)

## Audit follow-up

After SPEC-001 v1.3 draft completes, the planned next step is a
Codex GPT-5 audit pass (`AUDIT_SPEC_001_v1_3_PROMPT.md`)
mirroring the SPEC-010 / SPEC-011 audit discipline:
- Verify every new R-rule cites a binding locked-spec rule
- Verify L-1 byte-identical default is literal (gate text in
  every new section that introduces wire surface)
- Verify the §6.7 v2 handshake field table matches SPEC-010
  v1.5 §3.1.A by byte-for-byte comparison
- Verify §6.5 (legacy `hello`) is byte-identical to v1.2.4
- Verify the four-cell opt-in matrix is complete and consistent
- Verify the macOS-native path constraint (no
  `$XDG_RUNTIME_DIR` leakage)
- Verify the §6.10 heartbeat extension correctly delegates
  coordinator-side handling to the SPEC-002 v1.3.5 candidate

Target verdict: 0 CRITICAL / 0 MAJOR per round before LOCK.
Decision-log Entry 56 will summarize the SPEC-001 v1.3 lock.

=== END PROMPT ===
```

---

## Operator notes

- Expected wall-clock: 90-120 min (4 NEW normative sections + §6.2 / §6.5 edits + change-log + AC additions + companion-spec annotations).
- This is a **revision-in-place** of locked SPEC-001 v1.2.4 → v1.3, mirroring the FIX_SPEC_001_V1_2_4_PROMPT.md discipline at a larger scope.
- After draft completion, run `AUDIT_SPEC_001_v1_3_PROMPT.md` (to be drafted in the same session) for Codex GPT-5 audit. Target: 0 CRITICAL / 0 MAJOR per round.
- Pair this BUILD prompt with `BUILD_SPEC_002_v1_3_5_PROMPT.md` (coordinator-side counterpart, to be drafted next per Entry 55 followups).
- After SPEC-001 v1.3 LOCKS, append Entry 56 to `beta/DECISION_CRITERIA.md` mirroring Entry 54 / 55 format.
- DO NOT proceed to implementation (Swift code in `phase3-binary/`) until SPEC-001 v1.3 + SPEC-002 v1.3.5 are BOTH LOCKED — the two specs are tightly coupled on the heartbeat hash-clearing REPLACEMENT (SPEC-011 §6.2 D2.1 fix).
