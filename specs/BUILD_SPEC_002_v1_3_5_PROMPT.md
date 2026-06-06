# Build prompt — SPEC-002 v1.3.4 → v1.3.5 (coordinator-side absorption of SPEC-010 v1.5 + SPEC-011 v0.5)

Operator-paste prompt to revise the locked SPEC-002 v1.3.4 into
v1.3.5, folding in the coordinator-side surface of three now-LOCKED
specs:

- **SPEC-010 v1.5** (Provider Model Catalog, LOCKED 2026-06-06 — see
  `beta/DECISION_CRITERIA.md` Entry 54)
- **SPEC-011 v0.5** (Operator-Pushed Warm Swap, LOCKED 2026-06-06 —
  see Entry 55)
- **SPEC-001 v1.3** (Phase 3 Binary, LOCKED 2026-06-06 — see
  Entry 56). SPEC-001 v1.3 is the binary-side counterpart; SPEC-002
  v1.3.5 must be consistent with it at every wire-protocol point of
  contact (v2 `auth_request`, heartbeat extension, control-socket
  semantics — note that the control socket itself is binary-local and
  has no coordinator presence).

This is a **revision-in-place** of an already-locked spec, not a
from-scratch draft. The mission of SPEC-002 (the Phase 4 coordinator)
is unchanged; v1.3.5 adds normative sections, an `ApplyHeartbeat`
REPLACEMENT semantics block, a new audit-log infrastructure
section, a coordinator `Provider` data-model extension, and new ACs
that the coordinator must implement to satisfy SPEC-010 v1.5 §3.3 /
§6.2 + SPEC-011 v0.5 §3.3 / §3.6 / §6.2 as the binding source-of-
truth for coordinator-side behavior.

**One-line scope summary.** Add v2 `auth_request` two-stage
handshake (initial + proof, with R-3.1.10 retention contract); add
auth-attempt lifecycle (10-min timer, per-attempt state release);
extend `Provider` data model with `SupportedModels[]`,
`PublishesSupportedModels`, hash-status enum; extend `/v1/status`
with opt-in `supported_models` echo; extend heartbeat parsing
with optional `model_hash` + `loading: bool`; **REPLACE**
`ApplyHeartbeat` hash-clearing behavior with a two-path
(legacy clear vs SPEC-011 re-verify) semantics; add NEW audit-log
infrastructure section + normative `operator_model_swap` event
schema; add new ACs.

**Locked-spec dependencies (DO NOT contradict).**
- SPEC-002 v1.3.4 (the file being edited — change-log carries forward)
- SPEC-001 v1.3 (LOCKED — binary-side counterpart; wire-level coupling)
- SPEC-004 v0.3.1
- SPEC-005 (current locked version)
- SPEC-006 v0.8.1
- SPEC-008 v0.3
- **SPEC-010 v1.5** (binding source for §3.1.A field table,
  §3.1.C proof-stage table, §3.3 Provider struct, R-3.1.10 retention,
  R-3.3.3 /v1/status echo)
- **SPEC-011 v0.5** (binding source for §3.3 heartbeat extension,
  §3.5 SPEC-008 Pillar A re-verification, §3.6 operator_model_swap
  audit event, §6.2 ApplyHeartbeat REPLACEMENT)

Spec-text-only revision. **No Go code changes in this session.**
The implementation pass that consumes SPEC-002 v1.3.5 is a separate
future session (matching the SPEC-002 v1.3.x discipline). Verify
with `git diff phase4-coordinator/` after edits — should be empty.

Run in **Claude Code** or **Codex CLI**. Expected duration:
~120-180 min (this is a larger surface than SPEC-001 v1.3 — NEW
§7.8 v2 `auth_request`, NEW §7.9 auth-attempt lifecycle, NEW §7.10
audit-log infrastructure, EXTEND §7.1 heartbeat, REPLACE
`ApplyHeartbeat` semantics, EXTEND §3 data model, EXTEND §7.4
/v1/status, EXTEND §11 ACs, change-log, §2 scope, §13 hand-off).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are revising SPEC-002 v1.3.4 in place to v1.3.5, folding in the
coordinator-side surface of LOCKED SPEC-010 v1.5 (Provider Model
Catalog), LOCKED SPEC-011 v0.5 (Operator-Pushed Warm Swap), and
LOCKED SPEC-001 v1.3 (Phase 3 Binary — binary-side counterpart).

You will edit ONE file in place:
  /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md
  v1.3.4 → v1.3.5

You will NOT write any code. This is a spec-text-only revision.
Verify with `git diff phase4-coordinator/` after edits — must be
empty. Verify with `git diff specs/SPEC-001-phase3-binary.md
specs/SPEC-004-coordinator-dispatch.md specs/SPEC-006-buyer-api.md
specs/SPEC-008-tier2-attestation.md specs/SPEC-010-model-catalog.md
specs/SPEC-011-operator-pushed-warm-swap.md` after edits — must be
empty.

## Critical constraints

**1. SPEC-001 v1.3, SPEC-010 v1.5, and SPEC-011 v0.5 are LOCKED and
READ-ONLY.** All three audited to 0 CRITICAL / 0 MAJOR / 0 MINOR.
Do not edit any of them. If your SPEC-002 v1.3.5 draft would require
a change to any of them, STOP and surface the conflict in a comment
near the top of the SPEC-002 v1.3.5 change log — do not invent a
contradiction under the SPEC-002 banner.

**2. Locked SPEC-002 v1.3.4 sections READ-ONLY where unchanged.**
The verbatim sections that v1.3.5 does not extend MUST stay
byte-identical. Specifically: §1, §3 (Architecture overview) where
not extended, §5 (Routing algorithm), §6 (Non-functional), §7.2
(Buyer HTTP API), §7.3 (Auth), §7.5, §7.6, §7.7, §8, §9, §10, §12,
§13 except hand-off extension. Existing FR-P1 through FR-P21
numbering MUST NOT change; new FRs MUST start at the next available
integer. Existing AC numbering MUST NOT change; new ACs MUST be
appended at the end.

**3. L-1 byte-identical default MUST be preserved literally on the
coordinator side.** The coordinator MUST handle the v1.3 binary's
unset/unset (L-1 baseline) frame shape correctly:
- v2 `auth_request` initial-stage with `supported_models: [model_id]`
  (single-entry per SPEC-010 R-3.6.2 / AC-19) MUST be accepted and
  registered as functionally indistinguishable from a pre-SPEC-010
  binary's `hello` registration per SPEC-010 v1.5 §4.1.
- Heartbeat without `model_hash` and `loading` fields MUST be
  processed exactly as the locked v1.3.4 `ApplyHeartbeat` does today
  (legacy path of the REPLACEMENT).
- `publishes_supported_models` absent or `false` MUST cause
  `/v1/status` to OMIT the `supported_models` field per SPEC-010
  R-3.3.3 / AC-21.

Every new R-rule and AC that touches wire-observable behavior MUST
state the L-1 baseline expectation explicitly.

**4. SPEC-010 + SPEC-011 opt-ins are orthogonal.** The four-cell
opt-in matrix is documented in SPEC-001 v1.3 §6.7.3 (LOCKED). SPEC-002
v1.3.5 MUST handle all four cells correctly. The coordinator's
SPEC-010 surface (Provider struct extension, /v1/status echo) is
controlled by the binary's `--supported-models` /
`--publish-supported-models` opt-ins; the coordinator's SPEC-011
surface (heartbeat new fields, ApplyHeartbeat REPLACEMENT, audit
event) is controlled by the binary's `--enable-warm-swap` opt-in.

**5. Buyer HTTP API stability.** §7.2 stays byte-identical. v1.3.5
does NOT add, remove, or modify any buyer HTTP endpoint. The buyer
sees no behavioral change in this revision.

**6. v2 `auth_request` is a NEW normative section.** Locked SPEC-002
v1.3.4 §7.1 documents the legacy `hello` handshake (server side of
SPEC-001 v1.2.4 §6.5). SPEC-002 v1.3.5 MUST ADD a new normative
section (NEW §7.8) that documents the v2 two-stage `auth_request`
handshake (`initial` + `proof` stages), mirroring SPEC-001 v1.3 §6.7
(LOCKED) and using SPEC-010 v1.5 §3.1.A + §3.1.C as the binding
source-of-truth for the field tables. The v2 contract has been in
code since SPEC-002 v1.2.x but was never normatively documented; v1.3.5
closes that gap on the coordinator side (the matching SPEC-001 v1.3
§6.7 closed it on the binary side).

**7. § numbering — use §7.8 onwards for NEW §7 subsections, and
§3.x for the data-model extension.**

NEW SECTIONS:
  - §3.X (locate the most appropriate subsection — likely after the
    existing "Request forwarding model" subsection) — Provider data
    model extension (SupportedModels[], PublishesSupportedModels,
    hash-status enum, retention map). SPEC-002 v1.3.4 does not
    currently document the `Provider` Go struct; v1.3.5 ADDS this
    normative documentation.
  - §7.8 — v2 `auth_request` provider handshake (NEW, normative)
  - §7.9 — Auth-attempt lifecycle (NEW, normative)
  - §7.10 — Audit-log infrastructure + `operator_model_swap` event
    (NEW, normative — SPEC-002 v1.3.4 does NOT currently have an
    audit-log normative section; v1.3.5 creates it)

EXTENDED SECTIONS:
  - §2 — scope bullets (operator-pushed warm-swap absorption,
    capability-advertisement absorption)
  - §7.1 — heartbeat field extension (optional `model_hash` +
    `loading: bool` parsing) + ApplyHeartbeat REPLACEMENT
    sub-section (the most consequential v1.3.5 change)
  - §7.4 — /v1/status opt-in echo extension
  - §11 — new ACs appended at end
  - §13 — implementation hand-off list extension

**8. Surgical scope.** Add sections; do not rewrite existing ones.
- APPEND a v1.3.5 change-log entry at the top of the file using its
  OWN `**Change log v1.3.5:**` header (matching the file's
  convention — see v1.3.4 / v1.3.3 / v1.3.2 etc. each have their
  own header).
- EXTEND §2 "In Tier 1 launch scope (build now)" with bullets for
  SPEC-010 capability advertisement (operator opt-in) and SPEC-011
  warm swap (operator opt-in). Do NOT rewrite existing scope bullets.
- ADD §3.X Provider data model extension (cite SPEC-010 v1.5 §3.3
  R-3.3.1 / R-3.3.2 / R-3.3.4).
- EXTEND §7.1 with: (a) a heartbeat field-table extension showing
  new optional `model_hash` + `loading: bool` per SPEC-011 v0.5
  R-3.3.0 / R-3.3.1; (b) a sub-section titled "ApplyHeartbeat
  hash-clearing REPLACEMENT (v1.3.5, per SPEC-011 v0.5 §6.2)" with
  the two-path normative contract spelled out unmissably. This is
  THE most consequential change in v1.3.5.
- ADD §7.4 sub-section for opt-in `/v1/status.supported_models`
  echo (cite SPEC-010 v1.5 R-3.3.3 / AC-21).
- ADD §7.8 v2 `auth_request` provider handshake (initial + proof
  + R-3.1.10 proof-stage retention/comparison contract).
- ADD §7.9 auth-attempt lifecycle (timer source-of-truth =
  `s.now().Add(10 * time.Minute)` at
  `phase4-coordinator/internal/ws/server.go:355`; per-attempt state
  release on (i) successful completion, (ii) proof-stage rejection,
  (iii) expiry timeout, (iv) WebSocket disconnect-before-proof;
  defensive bound on aggregate retention map size).
- ADD §7.10 audit-log infrastructure + `operator_model_swap` event
  type with full payload schema per SPEC-011 v0.5 §3.6 (operator
  identity, old/new model IDs, old/new hashes, transition
  timestamps, outcome). The audit-log infrastructure itself is a
  NEW SPEC-002 normative surface (no prior locked spec defines an
  audit-log table in SPEC-002).
- EXTEND §11 with new ACs appended at the end of the existing
  category list.
- EXTEND §13 implementation hand-off file structure.

**9. Locked-spec citations are normative, not informational.**
Every new R-rule / FR / AC MUST cite the binding SPEC-001 v1.3,
SPEC-010 v1.5, or SPEC-011 v0.5 rule. Example:
  "R-7.8.4 The coordinator MUST GENERATE `auth_attempt_id` at
   the initial-stage acceptance point per SPEC-010 v1.5 §3.1.A
   (the `auth_attempt_id` note), matching the current
   implementation at server.go:354."
Avoid restating the locked rule's body — cite it and add only the
coordinator-side specifics (file paths, Go type names, default
values, registry-method signatures) that belong in SPEC-002.

**10. ApplyHeartbeat REPLACEMENT MUST be flagged unmissably.**
This is the D2.1 outline-audit fix from SPEC-011 v0.5 §6.2 and is
the single most consequential change in v1.3.5. The REPLACEMENT
must be presented as a normative two-path contract:

LEGACY PATH (heartbeat lacks `model_hash` field):
  - On `ModelID` change, coordinator MUST CLEAR `Provider.ModelHash`
    and SET `Provider.HashStatus = HashStatusUncatalogued` (current
    behavior at `phase4-coordinator/internal/pool/provider.go:420-432`).

SPEC-011 PATH (heartbeat carries `model_hash` field):
  1. Coordinator MUST UPDATE `Provider.ModelHash` to the new value
     (NOT clear).
  2. Coordinator MUST RUN SPEC-008 v0.3 §5.3-§5.6 Pillar A
     re-verification using the new hash.
  3. Coordinator MUST POPULATE `Provider.HashStatus` from the
     verification result (one of SPEC-008's 5 hash states).
  4. Coordinator MUST EMIT `operator_model_swap` audit event IF the
     prior heartbeat on the current session had `loading: true`
     (i.e. a swap completed; the heartbeat is the post-swap one).

The REPLACEMENT MUST be written as part of §7.1 (not §7.8 or §7.9)
because heartbeat handling is §7.1's domain. The §7.1 ApplyHeartbeat
REPLACEMENT sub-section MUST include a code-anchor reference to
`phase4-coordinator/internal/pool/provider.go:411-432` (the
`ApplyHeartbeat` function range that is being normatively
re-specified).

**11. Auth-attempt lifecycle source-of-truth.** SPEC-010 v1.5
§6.2 explicitly notes that "Until SPEC-002 v1.3.5 lands, SPEC-010
R-3.1.10 clauses 1 and 5 ARE the source of truth for the
auth-attempt retention lifecycle as it interacts with SPEC-010."
v1.3.5 §7.9 is the section that TAKES OVER as the source of truth.
Document this transition explicitly in §7.9 opening paragraph.

**12. d-inference clean-room.** Do not inspect d-inference source.

**13. No Tier-2 expansion.** v1.3.5 does NOT add any encrypted-leg,
attestation, or TEE behavior beyond what SPEC-002 v1.3.4 already
specifies. Tier-2 fields handled in the v2 `auth_request` flow
(`provider_ecdh_public_key`, `tier2_capabilities`,
`attestation_token`) are documented in the new §7.8 per SPEC-010
v1.5 §3.1.A / §3.1.C, but their handling rules are unchanged from
current code (cite SPEC-008 v0.3 by reference; do not restate).

## Required reading (in this order — read fully before writing
anything)

1. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.4 — read full document (this is the file being edited).
   Focus on:
   - Top change-log block (lines ~3-50) — you APPEND a v1.3.5 entry
     with its own header
   - §1, §2, §3, §5, §6, §7.1, §7.2, §7.3, §7.4, §7.5, §7.6, §7.7,
     §8, §9, §10, §11, §13 — these stay byte-identical except for
     the scoped extensions in §2, §7.1, §7.4, §11, §13
   - §7.1 (Provider WebSocket) — your NEW §7.8 will reference but
     not modify the legacy `hello` documentation; your §7.1 heartbeat
     extension + ApplyHeartbeat REPLACEMENT sub-section is the
     in-scope extension
   - §11 (Acceptance criteria) — you APPEND new ACs at the end
   - §13 (Implementation hand-off / file structure) — extend with
     the new Go files implied by v1.3.5

2. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.3 (LOCKED) — read full document. v1.3 is the binary-side
   counterpart; SPEC-002 v1.3.5 MUST be consistent with it at every
   wire-protocol point of contact:
   - §6.7 (v2 `auth_request` handshake) — mirror the field tables
     in your NEW §7.8
   - §6.7.3 (four-cell opt-in matrix) — your §7.1 heartbeat REPLACE
     and §7.4 echo MUST handle all four cells correctly
   - §6.10 (heartbeat extension) — your §7.1 heartbeat-field
     extension is the coordinator-side counterpart
   - §6.11.4 (WS-drop reconnect uses legacy `hello`) — note that
     reconnect-via-hello means the coordinator's existing §7.1
     legacy `hello` parser handles reconnect; no new path
   - AC-18.0 through AC-18.16 — your new ACs MUST be consistent
     with the binary-side ACs (the binary asserts what it emits;
     SPEC-002 v1.3.5 asserts what the coordinator does in response)

3. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.5 (LOCKED) — focus on:
   - §3.1.A (initial-stage field table) — the SOURCE for your §7.8.1
   - §3.1.C (proof-stage field table) — the SOURCE for your §7.8.2
   - §3.1 rules R-3.1.1 through R-3.1.10 — cite normatively
   - §3.3 (coordinator Provider struct extension) — the SOURCE for
     your NEW §3.X Provider data model extension
   - §3.3.3 (/v1/status opt-in echo) — the SOURCE for your §7.4
     extension
   - §3.4 (router candidate filter) — semantically unchanged; note
     in v1.3.5 that v1.3.5 may add the `req_model ∈ SupportedModels`
     predicate internally per R-3.4.1 but produces no dispatch
     outcome change in v1.3.5
   - §6.2 (SPEC-002 v1.3.5 candidate guidance) — this is the LOCKED
     spec's explicit view of what SPEC-002 v1.3.5 should add. Follow
     the structure it prescribes.

4. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   v0.5 (LOCKED) — focus on:
   - §2 L-1 through L-7 (locked design decisions)
   - §3.3 heartbeat extension (cite from your §7.1 extension)
   - §3.5 SPEC-008 Pillar A re-verification (cite from your §7.1
     ApplyHeartbeat REPLACEMENT)
   - §3.6 `operator_model_swap` audit event with payload schema
     (the SOURCE for your NEW §7.10)
   - §6.2 (SPEC-002 v1.3.5 candidate guidance) — this is the LOCKED
     spec's explicit view of what SPEC-002 v1.3.5 should add,
     including the D2.1 ApplyHeartbeat REPLACEMENT call-out.
     Follow this structure.

5. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2-attestation.md`
   v0.3 (LOCKED) — read §5.3-§5.7 (Pillar A pipeline + five-state
   hash enumeration) so your §7.1 ApplyHeartbeat REPLACEMENT
   correctly cites the re-verification pipeline shape.

6. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md`
   Entries 54, 55, 56 — strategic context for the arm64golf-fix
   build arc.

7. `/Users/augstar/macprovider-poc/CLAUDE.md` — repo conventions.

8. Code spot-check (READ-ONLY, for grounding only):
   - `phase4-coordinator/internal/ws/messages.go` lines 37-57
     (AuthRequest struct), 302-329 (frame validator), 333-388
     (parseAuthInitial), 391-401 (parseAuthProof). These are the
     parser truth for your §7.8 field tables.
   - `phase4-coordinator/internal/ws/server.go` line 354
     (`authAttemptID := "auth-" + s.newUUID()`) and line 355
     (`challengeExpiresAt := s.now().Add(10 * time.Minute)`). These
     are the timer/ID source-of-truth for your §7.9.
   - `phase4-coordinator/internal/pool/provider.go` lines 50-88
     (Provider struct) and lines 411-432 (`ApplyHeartbeat`,
     including the legacy clear at line 421). The Provider struct
     is the truth for your NEW §3.X data-model extension; the
     ApplyHeartbeat range is the code anchor your §7.1 REPLACEMENT
     sub-section MUST cite.
   - `phase4-coordinator/internal/config/config.go` line 269
     (`MaxUnauthenticatedConn: 64`) for context on existing
     coordinator config.

DO NOT inspect d-inference source (clean-room per CLAUDE.md).

## Required edits

### A. Top-of-file change-log

APPEND a v1.3.5 change-log entry ABOVE the existing v1.3.4 entry,
using its own `**Change log v1.3.5:**` header (matching the file's
one-header-per-version convention). Content:

- **v1.3.5 (2026-06-06, SPEC-010 v1.5 + SPEC-011 v0.5 + SPEC-001
  v1.3 absorption):** Adds coordinator-side surface for three
  now-LOCKED companion specs. SPEC-010 v1.5 adds the `Provider`
  data-model extension (`SupportedModels[]`,
  `PublishesSupportedModels`); opt-in `/v1/status.supported_models`
  echo per R-3.3.3 / AC-21. SPEC-011 v0.5 adds heartbeat parsing
  for optional `model_hash` + `loading: bool` per R-3.3.0 / R-3.3.1;
  REPLACES the locked `ApplyHeartbeat` hash-clearing semantics with
  a two-path (legacy clear / SPEC-011 re-verify) contract at
  `phase4-coordinator/internal/pool/provider.go:411-432`; adds NEW
  §7.10 audit-log infrastructure + normative `operator_model_swap`
  event schema. ALSO adds a new normative §7.8 v2 `auth_request`
  provider handshake section — the v2 contract has been in code
  since SPEC-002 v1.2.x but was never normatively documented in
  SPEC-002; v1.3.5 closes that gap on the coordinator side (matching
  SPEC-001 v1.3 §6.7 binary-side closure). ALSO adds a new normative
  §7.9 auth-attempt lifecycle section (10-minute timeout per
  `s.now().Add(10 * time.Minute)` at server.go:355; per-attempt
  state release on success/reject/expiry/disconnect); takes over as
  the source of truth from SPEC-010 v1.5 R-3.1.10 clauses 1 and 5
  per SPEC-010 §6.2 transition note. L-1 baseline preserved
  literally: a v1.3 binary in the unset/unset cell continues to be
  accepted and processed exactly as a pre-SPEC-010/SPEC-011 binary
  per SPEC-001 v1.3 §6.7.3 cell 1 and SPEC-010 §4.1 back-compat
  analysis. NO new buyer HTTP surface; NO routing-behavior change;
  NO Tier-2 (SPEC-008) expansion; NO change to existing FR-P*
  numbering or AC numbering.

### B. §2 Scope — extend "In Tier 1 launch scope (build now)"

Locate "In Tier 1 launch scope (build now)" and APPEND two bullets
at the end of that list:

- Operator-opt-in coordinator-side capability advertisement per
  SPEC-010 v1.5 §3.3 / §3.6: extend `Provider` data model with
  `SupportedModels[]` and `PublishesSupportedModels`; extend
  `/v1/status` to opt-in echo `supported_models` when the provider
  set `publishes_supported_models: true` on the v2 `auth_request`
  initial-stage frame.
- Operator-opt-in coordinator-side warm-swap handling per SPEC-011
  v0.5 §3.3 / §3.5 / §3.6: extend heartbeat parser to accept
  optional `model_hash` (raw lowercase hex) + `loading: bool`;
  REPLACE the `ApplyHeartbeat` hash-clearing semantics with the
  two-path (legacy clear / SPEC-011 re-verify) contract; emit
  `operator_model_swap` audit-log event when a swap completes.

### C. NEW §3.X Provider data model extension (NORMATIVE)

Locate an appropriate insertion point in §3 (Architecture overview),
likely after the existing "Request forwarding model (v1.1 — two
paths)" sub-section or at the end of §3. Title the new sub-section
"Provider data model (v1.3.5 SPEC-010 extension)". Content:

C.1 Opening paragraph: cite that SPEC-002 v1.3.4 does not currently
document the `Provider` Go struct normatively (the struct exists
in code at `phase4-coordinator/internal/pool/provider.go:50-88` but
SPEC-002 has not enumerated its fields as a normative contract).
v1.3.5 ADDS this normative documentation, scoped to the fields
that v1.3.5 extends. Existing fields (provider_id, model_id,
heartbeat-state-related) remain documented operationally via
FR-P1 through FR-P21 and are not re-specified here.

C.2 NEW fields (cite SPEC-010 v1.5 §3.3):
  - **`SupportedModels []string`** — Per SPEC-010 v1.5 §3.3
    R-3.3.1, populated from the v2 `auth_request` initial-stage
    `supported_models[]` field. When absent on the wire,
    synthesized as `[model_id]` per SPEC-010 R-3.1.5.
  - **`PublishesSupportedModels bool`** — Per SPEC-010 v1.5
    R-3.3.2. Defaults to `false` when the wire field is absent or
    `false`. Controls whether `/v1/status` echoes the
    `supported_models` field per §7.4 extension.
  - **`HashStatus` enum** — Per SPEC-008 v0.3 §5.5 five-state
    enumeration (existing; this v1.3.5 entry just normatively
    documents it as part of the data model since §7.1 ApplyHeartbeat
    REPLACEMENT now references it explicitly).

C.3 NEW retention map (cite SPEC-010 v1.5 R-3.1.10 + SPEC-002 v1.3.5
§7.9):
  - **`AuthAttemptRetention map[string]AuthAttemptState`** — Per
    SPEC-010 R-3.1.10 (proof-stage retention contract) and §7.9
    (auth-attempt lifecycle). Keyed on coordinator-generated
    `auth_attempt_id` (see §7.9). Entries are released per §7.9
    release contract. Aggregate map size MUST be bounded
    defensively per §7.9.

### D. §7.1 EXTENSION — heartbeat field extension + ApplyHeartbeat REPLACEMENT (NORMATIVE)

Locate §7.1 and ADD sub-sections at the end of §7.1 (do NOT modify
existing §7.1 content). Title the first new sub-section "Heartbeat
field extension (v1.3.5 SPEC-011 absorption)".

D.1 Sub-section: heartbeat field extension. Add an extension to the
existing §7.1 heartbeat documentation showing the two new optional
fields per SPEC-011 v0.5 R-3.3.0 / R-3.3.1:

| Field | JSON name | Type | Optionality | Notes |
|---|---|---|---|---|
| Model hash | `model_hash` | string, raw 64-char lowercase hex | optional, added by SPEC-011 v1.3.5 | per SPEC-011 R-3.3.1; "raw" means no `sha256:` prefix and no uppercase characters |
| Loading | `loading` | bool | optional, added by SPEC-011 v1.3.5 | per SPEC-011 R-3.3.0 / R-3.3.3; `true` when the binary's state machine is `loading` or `draining`, `false` when `ready` |

R-7.1.X The coordinator's heartbeat parser MUST tolerate both fields
being absent (legacy path) and both being present (SPEC-011 path).
A heartbeat with `loading: true` MUST exclude the provider from
routing candidates via the existing non-`Ready` exclusion path per
SPEC-011 v0.5 §6.4 routing-interaction note (no new routing
predicate is introduced).

D.2 Sub-section: ApplyHeartbeat hash-clearing REPLACEMENT
(v1.3.5, per SPEC-011 v0.5 §6.2). This is THE most consequential
change in v1.3.5. Title the sub-section unmissably and structure as:

R-7.1.Y The coordinator's `ApplyHeartbeat` function at
`phase4-coordinator/internal/pool/provider.go:411-432` MUST implement
TWO PATHS depending on whether the incoming heartbeat carries a
`model_hash` field. v1.3.5 REPLACES the locked v1.3.4 behavior
that unconditionally clears `Provider.ModelHash` and sets
`Provider.HashStatus = HashStatusUncatalogued` on any `ModelID`
change.

**LEGACY PATH (heartbeat lacks `model_hash` field):**
- On `ModelID` change, coordinator MUST CLEAR `Provider.ModelHash`
- On `ModelID` change, coordinator MUST SET `Provider.HashStatus =
  HashStatusUncatalogued`
- This preserves the current `provider.go:420-432` semantics
  for pre-SPEC-011 binaries

**SPEC-011 PATH (heartbeat carries `model_hash` field):**
- Coordinator MUST UPDATE `Provider.ModelHash` to the new value
  (NOT clear)
- Coordinator MUST RUN SPEC-008 v0.3 §5.3-§5.6 Pillar A
  re-verification using the new hash
- Coordinator MUST POPULATE `Provider.HashStatus` from the
  verification result (one of SPEC-008's 5 hash states per §5.5)
- Coordinator MUST EMIT `operator_model_swap` audit event per
  §7.10 IF the prior heartbeat on the current session had
  `loading: true` (i.e. this heartbeat is the post-swap one
  signalling completion)

R-7.1.Z The two paths MUST be selected based on field presence,
NOT based on any flag or per-provider state. A SPEC-011 binary
that omits `model_hash` from a heartbeat (e.g. transient bug,
config error) MUST be handled by the LEGACY PATH — there is no
"sticky" mode. This protects against partial-rollout failure
modes where the binary stops sending `model_hash` mid-session.

R-7.1.W The `operator_model_swap` emission gate ("IF the prior
heartbeat on the current session had `loading: true`") MUST be
implemented using a per-session sticky `LastLoadingState bool` on
the `Provider` struct, reset to `false` on session close. The
event MUST be emitted EXACTLY ONCE per swap completion (not
once per heartbeat after swap), enforced by the LastLoadingState
sticky transitioning `true → false` on the first post-swap
heartbeat.

### E. §7.4 EXTENSION — /v1/status opt-in echo (NORMATIVE)

Locate §7.4 (Operator endpoints) and ADD a sub-section at the end
titled "/v1/status SPEC-010 echo (v1.3.5)". Content:

R-7.4.X For each provider entry returned by `/v1/status`, the
coordinator MUST INCLUDE the `supported_models` field IF the
provider's `PublishesSupportedModels` is `true` (per §3.X data
model), per SPEC-010 v1.5 R-3.3.3. When `PublishesSupportedModels`
is `false` or absent, the `supported_models` field MUST be OMITTED
entirely (not emitted as `null` or `[]`). This preserves
byte-identical `/v1/status` output for pre-SPEC-010 binaries and
for SPEC-010 binaries that opt out per SPEC-010 v1.5 AC-21.

### F. NEW §7.8 — v2 `auth_request` provider handshake (NORMATIVE)

Add as "7.8. v2 `auth_request` provider handshake (NEW in v1.3.5)".

F.1 Opening paragraph: state explicitly that locked SPEC-002 v1.3.4
§7.1 documents the legacy `hello` handshake, and that the v2
`auth_request` two-stage handshake has been in code since SPEC-002
v1.2.x (server.go frame-validator gates on `type == "auth_request"`,
`version == 2`, `stage ∈ {"initial", "proof"}`) but was never
normatively documented in SPEC-002. This section closes that gap on
the coordinator side, matching SPEC-001 v1.3 §6.7 binary-side
closure.

F.2 Sub-section §7.8.1 "Initial-stage frame (P→C)". Reproduce or
cite the SPEC-010 v1.5 §3.1.A field table. Document the
coordinator's processing:
- `parseAuthInitial` at
  `phase4-coordinator/internal/ws/messages.go:333-388` is the parser
- 11 fields are parser-REQUIRED per SPEC-010 v1.5 §3.1.A
- The two SPEC-010 optional fields (`supported_models[]`,
  `publishes_supported_models`) are accepted and populate the
  `Provider` data-model fields per §3.X above
- Validation order MUST be the order the parser enforces (cite
  SPEC-010 R-3.1.x for specific rejection reason strings)

F.3 Sub-section §7.8.2 "Proof-stage frame (P→C)". Reproduce or cite
the SPEC-010 v1.5 §3.1.C field table. Document the coordinator's
processing:
- `parseAuthProof` at `messages.go:391-401` is the parser
- `auth_attempt_id` is REQUIRED on the proof stage; the coordinator
  MUST verify it matches the value generated at initial-stage
  acceptance per §7.9
- `provider_id` MUST match the initial-stage value (server.go:398
  enforces this in code)
- `attestation_token` is handled per SPEC-008 v0.3 (conditional on
  Tier-2 negotiation)
- SPEC-010 fields (`supported_models[]`,
  `publishes_supported_models`) ON the proof stage MUST be handled
  per SPEC-010 v1.5 R-3.1.10 proof-stage retention/comparison
  contract: absent = OK (no comparison); present MUST match the
  initial-stage value byte-identical after NFC normalization +
  ASCII case-fold per R-3.1.7

F.4 Sub-section §7.8.3 "Auth-attempt ID source-of-truth". The
coordinator GENERATES `auth_attempt_id` at server.go:354
(`authAttemptID := "auth-" + s.newUUID()`) AFTER successful
initial-stage parse. The coordinator MUST attach this ID to the
outgoing `auth_challenge` frame and MUST expect it echoed verbatim
on the subsequent proof-stage `auth_request`. Implementations MUST
NOT trust any client-supplied `auth_attempt_id` on the initial
stage (the parser ignores it there).

### G. NEW §7.9 — Auth-attempt lifecycle (NORMATIVE)

Add as "7.9. Auth-attempt lifecycle (NEW in v1.3.5)".

G.1 Opening paragraph: note that SPEC-010 v1.5 §6.2 explicitly
designated "SPEC-010 R-3.1.10 clauses 1 and 5 ARE the source of
truth for the auth-attempt retention lifecycle as it interacts with
SPEC-010" until SPEC-002 v1.3.5 lands. This section (NEW §7.9)
takes over as the source of truth. SPEC-010 R-3.1.10 clauses 1
and 5 remain valid as the SPEC-010 wire-side contract; §7.9 is the
coordinator-side state-management contract.

G.2 Sub-section §7.9.1 "Lifecycle events". The auth-attempt
lifecycle has 4 lifecycle events:
1. **Initial-stage parse success** — coordinator generates
   `authAttemptID` at server.go:354 + computes
   `challengeExpiresAt := s.now().Add(10 * time.Minute)` at
   server.go:355
2. **Coordinator emits `auth_challenge`** — frame carries the
   generated `auth_attempt_id` and an explicit expiry timestamp
3. **Coordinator retains per-attempt state** — includes (a)
   SPEC-010 R-3.1.10 retention entries when applicable, (b) the
   challenge details, (c) the generated `auth_attempt_id`, (d)
   the timestamp for expiry enforcement; keyed by the generated
   ID in the `AuthAttemptRetention` map (per §3.X data model)
4. **Per-attempt state release** — MUST occur on ANY of:
   (a) successful proof-stage completion (provider registered),
   (b) proof-stage rejection (any reason),
   (c) expiry timeout (`s.now() >= challengeExpiresAt`),
   (d) WebSocket disconnect-before-proof

G.3 Sub-section §7.9.2 "Timeout bound". 10 minutes, matching the
current `challengeExpiresAt` computation at server.go:355.
Implementations MUST bound aggregate retention map size as a
defensive safeguard (recommendation: max 1024 in-flight
auth-attempts per coordinator instance; exceeded → reject new
initial-stage attempts with `auth_response.error.code =
"too_many_auth_attempts"` and a 503-class WS close code per
existing close-code registry).

G.4 Sub-section §7.9.3 "Release implementation". The release MUST
be implemented via a `defer releaseRetention(authAttemptID)`
pattern that fires regardless of which lifecycle event triggers
release. Code-anchor: the release call MUST be installed at the
auth-attempt scope (between initial-stage parse acceptance and
final session registration), NOT at the session-level
`handleDisconnect`, to ensure correct cleanup on pre-proof failures
that don't go through `handleDisconnect`.

### H. NEW §7.10 — Audit-log infrastructure + `operator_model_swap` event (NORMATIVE)

Add as "7.10. Audit-log infrastructure (NEW in v1.3.5)".

H.1 Opening paragraph: SPEC-002 v1.3.4 does not currently have a
normative audit-log infrastructure section. SPEC-005 v0.3
documents the `request_log` table (separate concern: per-request
accounting / billing). v1.3.5 ADDS a normative section for an
operator-action audit log, scoped to events that document
coordinator-observed operator-side actions.

H.2 Sub-section §7.10.1 "Audit-log table requirement". The
coordinator MUST persist audit-log entries to a durable store.
Implementations SHOULD use SQLite (matching `request_log`'s
existing storage), with the following schema:

```sql
CREATE TABLE audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    event_type TEXT NOT NULL,
    provider_id TEXT,
    payload_json TEXT NOT NULL
);
CREATE INDEX idx_audit_log_ts_utc ON audit_log(ts_utc);
CREATE INDEX idx_audit_log_provider_id ON audit_log(provider_id);
CREATE INDEX idx_audit_log_event_type ON audit_log(event_type);
```

`ts_utc` MUST be RFC3339 in UTC. `payload_json` MUST be a
well-formed JSON object whose schema depends on `event_type`. The
table retention policy follows SPEC-002 §7.7 `storage.audit_log_
retention_days` (default 90 days, mirroring `request_log_retention_
days` per Entry 52 / locked SPEC-002 v1.3.x).

H.3 Sub-section §7.10.2 "`operator_model_swap` event type
(NORMATIVE)". Per SPEC-011 v0.5 §3.6, the coordinator MUST emit
this event when a SPEC-011 warm-swap completes (per the §7.1
ApplyHeartbeat REPLACEMENT emission gate). Payload schema:

```json
{
  "event_type": "operator_model_swap",
  "provider_id": "<string ULID>",
  "old_model_id": "<string, HF ID or local path>",
  "new_model_id": "<string, HF ID or local path>",
  "old_model_hash": "<string, raw 64-char lowercase hex>",
  "new_model_hash": "<string, raw 64-char lowercase hex>",
  "swap_started_at_utc": "<RFC3339 UTC, timestamp of first heartbeat with loading: true>",
  "swap_completed_at_utc": "<RFC3339 UTC, timestamp of the post-swap heartbeat>",
  "outcome": "<string enum: succeeded | failed | unknown>",
  "new_model_hash_status": "<string, SPEC-008 5-state enum value>"
}
```

R-7.10.X The `operator_model_swap` event MUST be emitted EXACTLY
ONCE per completed swap (enforced by the §7.1
`LastLoadingState` sticky reset). Emission MUST be best-effort
(audit-log write failure MUST NOT block heartbeat processing or
trigger a provider drop; failures MUST be logged at WARN level
with the payload available in process logs for forensic recovery).

H.4 Sub-section §7.10.3 "Future event types". The audit-log
infrastructure is scoped to support additional event types in
future revisions (out of scope for v1.3.5). The schema above is
the MVP and is normative for v1.3.5.

### I. §11 EXTENSION — new ACs (NORMATIVE)

APPEND new ACs at the end of §11, after the existing audit-
category I / J sections. Number them starting at the next available
integer in the §11 sequence. Each AC MUST cite the binding SPEC-010
v1.5 AC, SPEC-011 v0.5 AC, or SPEC-001 v1.3 AC it traces to. Use
the pattern "AC-K.X" where K is the next available group letter
after the existing categories (e.g. if the existing categories are
I and J, the new group is K).

Required new ACs (minimum):

- **AC-K.0 L-1 baseline coordinator handling.** A v1.3 binary
  invoked with neither `--supported-models` nor `--enable-warm-swap`
  registers with the v1.3.5 coordinator and is processed
  byte-identical to a pre-SPEC-010/SPEC-011 binary: v2
  `auth_request` initial-stage frame with single-entry
  `supported_models: [model_id]` is accepted; `Provider` struct
  has `SupportedModels = [model_id]` and
  `PublishesSupportedModels = false`; `/v1/status` for this
  provider OMITS the `supported_models` field; heartbeat without
  `model_hash` / `loading` triggers the LEGACY PATH of
  ApplyHeartbeat (clear hash on ModelID change). Traces to
  SPEC-010 v1.5 AC-2 + AC-21 and SPEC-011 v0.5 AC-18 and SPEC-001
  v1.3 AC-18.0.

- **AC-K.1 SPEC-010 catalog opt-in echo.** A v1.3 binary
  registered with `supported_models: [A, B, C]` and
  `publishes_supported_models: true` MUST cause `/v1/status` for
  this provider to include `"supported_models": ["A", "B", "C"]`.
  Traces to SPEC-010 v1.5 AC-1 + AC-21 and SPEC-001 v1.3 AC-18.1.

- **AC-K.2 SPEC-010 catalog opt-in suppressed echo.** A v1.3
  binary registered with `supported_models: [A, B, C]` but without
  `publishes_supported_models: true` MUST cause `/v1/status` for
  this provider to OMIT the `supported_models` field. Traces to
  SPEC-010 v1.5 R-3.3.3 / AC-21.

- **AC-K.3 v2 `auth_request` proof-stage retention.** A v1.3
  binary's proof-stage frame that omits `supported_models[]` MUST
  be accepted (no comparison performed). A proof-stage frame that
  includes `supported_models[]` MUST be compared byte-identical to
  the initial-stage value (after NFC + ASCII case-fold per SPEC-010
  R-3.1.7). Mismatch MUST be rejected with `auth_response.error.code
  = "bad_request"` and reason text containing
  `"supported_models mismatch between initial and proof stages"`.
  Traces to SPEC-010 v1.5 R-3.1.10.

- **AC-K.4 Auth-attempt expiry.** A binary that completes the
  initial-stage handshake but disconnects before sending the
  proof-stage frame MUST cause the coordinator to release the
  auth-attempt retention state within 10 minutes (matching
  server.go:355 `challengeExpiresAt`). Traces to SPEC-010 v1.5
  R-3.1.10 clauses 1 and 5 + SPEC-002 v1.3.5 §7.9.

- **AC-K.5 Auth-attempt release on disconnect-before-proof.** A
  binary that completes initial-stage and then drops the WebSocket
  before sending proof-stage MUST cause IMMEDIATE release of the
  auth-attempt retention (not wait for the 10-minute timeout).
  Traces to SPEC-002 v1.3.5 §7.9.

- **AC-K.6 ApplyHeartbeat LEGACY PATH.** A v1.3 binary without
  `--enable-warm-swap` (emits heartbeat without `model_hash` field)
  that changes `ModelID` between heartbeats MUST cause the
  coordinator to clear `Provider.ModelHash` and set
  `Provider.HashStatus = HashStatusUncatalogued` per the locked
  v1.3.4 behavior at `provider.go:420-432`. Traces to SPEC-011
  v0.5 §6.2 D2.1 fix (LEGACY PATH).

- **AC-K.7 ApplyHeartbeat SPEC-011 PATH.** A v1.3 binary with
  `--enable-warm-swap` (emits heartbeat with `model_hash` field)
  that changes `ModelID` between heartbeats MUST cause the
  coordinator to: (a) UPDATE `Provider.ModelHash` to the new value
  (not clear); (b) run SPEC-008 v0.3 §5.3-§5.6 Pillar A
  re-verification; (c) populate `Provider.HashStatus` from the
  verification result; (d) emit `operator_model_swap` audit-log
  event per §7.10 IF the prior heartbeat had `loading: true`.
  Traces to SPEC-011 v0.5 §6.2 D2.1 fix (SPEC-011 PATH).

- **AC-K.8 ApplyHeartbeat path selection by field presence.** A
  SPEC-011 binary that omits `model_hash` from a single heartbeat
  (e.g. transient bug) MUST be handled by the LEGACY PATH for
  that heartbeat. There is no "sticky" path; path selection is
  per-heartbeat based on field presence. Traces to SPEC-002 v1.3.5
  R-7.1.Z.

- **AC-K.9 `operator_model_swap` exactly-once emission.** A
  completed warm swap MUST cause EXACTLY ONE `operator_model_swap`
  audit-log row, not one per heartbeat after swap completion.
  Traces to SPEC-002 v1.3.5 R-7.1.W (`LastLoadingState` sticky).

- **AC-K.10 `operator_model_swap` payload schema.** Every emitted
  `operator_model_swap` row MUST have a `payload_json` field that
  parses as a JSON object containing exactly the 10 keys listed in
  §7.10.2 schema. Traces to SPEC-011 v0.5 §3.6.

- **AC-K.11 Audit-log write failure tolerance.** A simulated
  SQLite write failure during `operator_model_swap` emission MUST
  NOT block heartbeat processing OR cause a provider drop; the
  failure MUST be logged at WARN level with the full payload.
  Traces to SPEC-002 v1.3.5 R-7.10.X.

- **AC-K.12 Audit-log retention.** Rows older than
  `storage.audit_log_retention_days` (default 90) MUST be pruned
  by the existing coordinator pruner (extend the §7.7 pruner per
  Entry 52 pattern). Traces to SPEC-002 v1.3.5 §7.10.1.

(Optional: more granular ACs covering Tier-2 negotiation
unchanged from SPEC-008 v0.3, `seenModels` index expansion if
v1.3.5 introduces it, defensive bound on aggregate retention map
size. Each MUST cite the binding SPEC-010 / SPEC-011 / SPEC-008
rule.)

### J. §13 Implementation hand-off — extend

If SPEC-002 v1.3.4 has a §13 (Implementation hand-off / File
structure) section listing expected Go source files, APPEND new
entries for:

- `phase4-coordinator/internal/pool/provider_swap.go` — implements
  the §7.1 ApplyHeartbeat SPEC-011 PATH branch (new file to keep
  the REPLACEMENT semantics isolated for review and testing); the
  existing `provider.go:411-432` `ApplyHeartbeat` gains a
  branch-on-field-presence dispatch.
- `phase4-coordinator/internal/ws/auth_attempt_retention.go` —
  implements the §7.9 auth-attempt lifecycle (retention map,
  release machinery, expiry timer).
- `phase4-coordinator/internal/audit/log.go` — implements the
  §7.10 audit-log infrastructure (table create, write API,
  retention pruner).
- `phase4-coordinator/internal/audit/events.go` — defines the
  normative event types and payload schemas; v1.3.5 ships with
  exactly one event: `operator_model_swap`.

Existing files modified (note in §13):
- `phase4-coordinator/internal/ws/server.go` — auth flow extended
  to install `defer releaseRetention(authAttemptID)` at the
  auth-attempt scope per §7.9.3; v2 `auth_request` flow remains
  unchanged in structure.
- `phase4-coordinator/internal/ws/messages.go` — `parseAuthInitial`
  extended to parse the two SPEC-010 optional fields into the
  `AuthRequest` struct; `parseAuthProof` extended to parse the
  same two fields conditionally per R-3.1.10.
- `phase4-coordinator/internal/pool/provider.go` — `Provider`
  struct gains `SupportedModels []string`,
  `PublishesSupportedModels bool`, `LastLoadingState bool`;
  `ApplyHeartbeat` gains the branch-on-field-presence dispatch
  with the SPEC-011 PATH delegated to `provider_swap.go`.
- `phase4-coordinator/internal/api/status.go` (or wherever
  /v1/status is served) — extended to conditionally include
  `supported_models` per §7.4 extension.
- `phase4-coordinator/internal/config/config.go` — add
  `storage.audit_log_retention_days` config key (default 90,
  mirroring `request_log_retention_days`).
- `phase4-coordinator/dist/coordinator.yaml` (or
  `dist/coordinator.yaml.template`) — add comment-out line for
  `storage.audit_log_retention_days: 90` matching the new config
  key.

## Done criteria

You are done when:

- `git diff specs/SPEC-002-coordinator.md` shows ONLY the changes
  prescribed above (new change-log entry with its own header, §2
  bullets, NEW §3.X data-model sub-section, §7.1 extensions,
  §7.4 extension, NEW §7.8/§7.9/§7.10, new §11 ACs, §13 file
  structure extension). No other sections modified.
- `git diff phase4-coordinator/` is empty.
- `git diff specs/SPEC-001-phase3-binary.md
  specs/SPEC-004-coordinator-dispatch.md
  specs/SPEC-006-buyer-api.md
  specs/SPEC-008-tier2-attestation.md
  specs/SPEC-010-model-catalog.md
  specs/SPEC-011-operator-pushed-warm-swap.md` is empty.
- The change-log carries forward all prior entries (v1.3.4, v1.3.3,
  ...) byte-identical, each under its own header; only the new
  v1.3.5 entry is added with its own header.
- §7.1 EXISTING content (lines ~1571-1894) is byte-identical to
  v1.3.4 — the v1.3.5 extension is purely an APPEND of two new
  sub-sections at the END of §7.1.
- §7.2 (Buyer HTTP API) is byte-identical to v1.3.4.
- §7.3 (Auth) is byte-identical to v1.3.4.
- §5 (Routing algorithm) is byte-identical to v1.3.4.
- Every new R-rule in §7.1 extension, NEW §3.X, §7.4 extension,
  §7.8, §7.9, §7.10 cites the binding SPEC-001 v1.3, SPEC-010
  v1.5, SPEC-011 v0.5, or SPEC-008 v0.3 rule.
- Every new AC-K.X cites a binding SPEC-010, SPEC-011, or SPEC-001
  v1.3 AC by number.
- The ApplyHeartbeat REPLACEMENT sub-section in §7.1 is flagged
  unmissably (clear title, two-path structure, code anchor).
- Version line at top reads `**Version:** 1.3.5 (2026-06-06,
  SPEC-010 v1.5 + SPEC-011 v0.5 + SPEC-001 v1.3 absorption)`.

## Out of scope

- Go code changes (deferred to implementation pass)
- Editing SPEC-001 v1.3, SPEC-004, SPEC-005, SPEC-006, SPEC-008,
  SPEC-010, SPEC-011 (all LOCKED)
- Modifying SPEC-002 v1.3.4 §1, §5, §6, §7.2, §7.3, §7.5, §7.6,
  §7.7, §8, §9, §10, §12, §13 except hand-off list extension
- Re-litigating the SPEC-010 / SPEC-011 / SPEC-001 v1.3 audit
  verdicts
- Buyer-API additions (the arm64golf pain #3 buyer-picker
  visibility is deferred to SPEC-012)
- Tier-2 expansion (SPEC-008 v0.4 is a separate future spec)

## Audit follow-up

After SPEC-002 v1.3.5 draft completes, the planned next step is a
Codex GPT-5 audit pass (`AUDIT_SPEC_002_v1_3_5_PROMPT.md`)
mirroring the SPEC-001 v1.3 audit discipline:
- Verify every new R-rule cites a binding locked-spec rule
- Verify L-1 baseline is literal (gate text in every new section
  that introduces parser surface or state transition)
- Verify the §7.8 v2 handshake field tables match SPEC-010 v1.5
  §3.1.A / §3.1.C by byte-for-byte comparison
- Verify §7.1 existing content is byte-identical to v1.3.4 (only
  APPENDED extensions)
- Verify §7.2 / §7.3 / §5 byte-identical to v1.3.4
- Verify the §7.1 ApplyHeartbeat REPLACEMENT correctly distinguishes
  LEGACY PATH from SPEC-011 PATH and cites the code anchor
- Verify §7.9 takes over as source of truth from SPEC-010 R-3.1.10
  clauses 1 and 5 (with explicit transition note)
- Verify §7.10 audit-log schema matches SPEC-011 v0.5 §3.6 payload
- Verify the exactly-once emission gate is explicit (no
  per-heartbeat re-emission)

Target verdict: 0 CRITICAL / 0 MAJOR per round before LOCK.
Decision-log Entry 57 will summarize the SPEC-002 v1.3.5 lock.

After Entry 57 lands, the implementation pipeline is FULLY
UNBLOCKED — both implementation sessions (Swift in `phase3-binary/`
per SPEC-001 v1.3 + Go in `phase4-coordinator/` per SPEC-002 v1.3.5)
can run in parallel or sequentially.

=== END PROMPT ===
```

---

## Operator notes

- Expected wall-clock: 120-180 min (this is a larger surface than SPEC-001 v1.3 — 3 NEW top-level sections, 2 EXTENSIONS to locked sections, ~12 new ACs, NEW data-model sub-section, NEW audit-log infrastructure section).
- This is a **revision-in-place** of locked SPEC-002 v1.3.4 → v1.3.5, mirroring the SPEC-001 v1.3 BUILD prompt discipline at coordinator-side scope.
- After draft completion, run `AUDIT_SPEC_002_v1_3_5_PROMPT.md` (to be drafted in the same session) for Codex GPT-5 audit. Target: 0 CRITICAL / 0 MAJOR per round.
- Pair this BUILD prompt with `BUILD_SPEC_001_v1_3_PROMPT.md` (already LOCKED 2026-06-06).
- After SPEC-002 v1.3.5 LOCKS, append Entry 57 to `beta/DECISION_CRITERIA.md` mirroring Entry 54 / 55 / 56 format.
- DO NOT proceed to implementation (Go code in `phase4-coordinator/`) until SPEC-002 v1.3.5 LOCKS. Once it locks, both implementation sessions are fully unblocked.
- The methodology pipeline (locked-dependency citations + pre-audit polish + R1V closure-audit format) has been validated at 2-round convergence on SPEC-001 v1.3. Target the same trajectory for SPEC-002 v1.3.5.
- The single highest-prior-probability MAJOR for the round-1 audit is **the §7.1 ApplyHeartbeat REPLACEMENT contract**: it touches a locked code path (`provider.go:411-432`) that is heavily covered by existing tests, and any spec text that under-specifies the two-path dispatch (LEGACY vs SPEC-011) will surface as a contract-correctness finding. Pre-flag this as the most likely round-1 finding when launching the audit.
