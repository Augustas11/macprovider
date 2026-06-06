# Audit prompt — SPEC-002 v1.3.5 (round 1, normative)

Operator-paste prompt to audit SPEC-002 v1.3.5
(`specs/SPEC-002-coordinator.md`) — the round-1 normative audit of
the v1.3.4 → v1.3.5 revision that absorbed LOCKED SPEC-010 v1.5 +
LOCKED SPEC-011 v0.5 + LOCKED SPEC-001 v1.3 on the coordinator side.

The v1.3.5 revision was authored by Codex GPT-5 via
`specs/BUILD_SPEC_002_v1_3_5_PROMPT.md` (2026-06-06), then received
a 3-MAJOR + cross-reference polish pass by Claude to close three
pre-audit findings caught on a deep read of §7.8 / §7.9 / §7.10:

- **M.1 (MAJOR)** — §7.10.2 `operator_model_swap` payload schema
  was invented from the BUILD prompt's hallucinated example
  (`event_type`, `provider_id`, `old_model_id`, `new_model_id`,
  `swap_started_at_utc`, `swap_completed_at_utc`, `outcome`,
  `new_model_hash_status`). The BINDING schema per SPEC-011 v0.5
  §3.6 (LOCKED) is `event`, `ts`, `provider_assigned_id`,
  `from_model_id`, `to_model_id`, `to_model_hash`,
  `loading_window_ms`, `hash_verification_result`,
  `from_model_hash`, `drain_inflight_count_estimate` (8 REQUIRED
  + 2 OPTIONAL). Polish rewrote §7.10.2 byte-for-byte from the
  locked source + added R-7.10.5 (provider_assigned_id semantics),
  R-7.10.6 (loading_window_ms coordinator-clock calculation),
  R-7.10.7 (hash_verification_result 5-state enum).
- **M.2 (MAJOR)** — R-3.6.5 F-1.5 invariants (no `conv:`, no raw
  `account_id`, no sticky session identifiers, no buyer prompt
  text) was missing from §7.10. Polish added R-7.10.9 + AC-K.11
  test oracle.
- **M.3 (MAJOR)** — R-3.6.6 conditional emission rule (WS-drop
  during loading + reconnect after swap = NO event fires) was
  missing from §7.1 R-7.1.6 and §7.10. Polish added R-7.10.10
  + cross-reference from §7.1 R-7.1.6 + AC-K.12 covering both
  reconnect-after-swap and reconnect-during-load behaviors.

Cross-reference drift from renumbering was fixed: §7.10 rules
renumbered 1-11 (no duplicates), AC-K renumbered 0-14 (was 0-12;
added 2 new ACs).

Round 1 target: confirm L-1 baseline is literal, verify every new
R-rule cites a binding SPEC-001 v1.3 / SPEC-010 v1.5 / SPEC-011
v0.5 / SPEC-008 v0.3 rule, verify §5 / §7.2 / §7.3 are byte-
identical to v1.3.4, verify code citations are line-accurate,
verify the §7.1 ApplyHeartbeat REPLACEMENT two-path dispatch is
unmissable and correct.

Trajectory target:
- v1.3.5 round 1: 0 / 0 / 0-2 MINOR (LOCK-confirmation or
  LOCK-READY pending narrow polish — given 3 MAJORs already closed
  pre-audit, expect 0/0/0 or close to it)
- v1.3.5 round 2 (if needed): polish pass to 0/0/0 → LOCK

Append round-1 findings to a NEW file
`specs/SPEC-002-v1-3-5-audit.md` (since v1.3.5 is a major revision
of v1.3.4, this gets its own audit-history file).

Paste everything between `=== BEGIN PROMPT ===` and
`=== END PROMPT ===` into a fresh Codex CLI session rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-002 v1.3.5 at
/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md.
This is round 1 of the v1.3.5 normative audit cycle.

v1.3.5 is a revision-in-place of LOCKED SPEC-002 v1.3.4 that
absorbs the coordinator-side surface of LOCKED SPEC-010 v1.5
(Provider Model Catalog), LOCKED SPEC-011 v0.5 (Operator-Pushed
Warm Swap), and LOCKED SPEC-001 v1.3 (Phase 3 Binary — binary-side
counterpart). It adds 3 NEW top-level sub-sections (§7.8, §7.9,
§7.10), 1 NEW data-model sub-section in §3, 2 EXTENSIONS to §7.1
(heartbeat field extension + ApplyHeartbeat REPLACEMENT), 1
EXTENSION to §7.4 (/v1/status echo), 15 new acceptance criteria
(AC-K.0 through AC-K.14), §2 scope extensions, and a §13
implementation hand-off extension.

The v1.3.5 draft was authored by Codex GPT-5 via
`specs/BUILD_SPEC_002_v1_3_5_PROMPT.md`, then received a 3-MAJOR
polish pass by Claude to close pre-audit findings caught on a deep
read of §7.8 / §7.9 / §7.10:
1. M.1 — §7.10.2 `operator_model_swap` payload schema rewritten
   byte-for-byte from SPEC-011 v0.5 §3.6 (correct 8 REQUIRED + 2
   OPTIONAL field names, replacing the BUILD prompt's invented
   schema).
2. M.2 — R-7.10.9 added enforcing R-3.6.5 F-1.5 payload-content
   invariants (no `conv:`, no raw `account_id`, no sticky session
   identifiers, no buyer prompt text).
3. M.3 — R-7.10.10 added enforcing R-3.6.6 conditional-emission
   rule (WS-drop-during-loading + reconnect-after-swap = NO event
   fires); §7.1 R-7.1.6 cross-references R-7.10.10.

Renumbering after polish: §7.10 rules now go 1-11; AC-K renumbered
0-14.

Your job: round-1 normative audit. Categories below. Append
findings to a NEW file (this file does not yet exist; create it).

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-002-v1-3-5-audit.md

CREATE this file with a top-level section:
  `## Round 1 — Codex GPT-5 — 2026-06-06 — Normative audit`

## Severity definitions

- **CRITICAL** — spec text directly contradicts a LOCKED spec
  (SPEC-001 v1.3, SPEC-002 v1.3.4 backward-compat clauses,
  SPEC-004 v0.3.1, SPEC-005, SPEC-006 v0.8.1, SPEC-008 v0.3,
  SPEC-010 v1.5, SPEC-011 v0.5) such that a coordinator built per
  v1.3.5 would violate L-1 baseline OR reject a v1.3 binary's
  L-1 cell frame OR violate a locked AC.
- **MAJOR** — spec text introduces ambiguity, a missing citation
  to a binding rule, a code-grounding error (line citation off
  by more than the function-body range, cited function does not
  exist, struct field doesn't exist), or — given the 3 MAJORs
  already closed pre-audit — any new payload-schema, F-1.5
  invariant, or conditional-emission contradiction.
- **MINOR** — editorial drift, ordering, formatting, single-word
  ambiguity, citation imprecision that does not change
  implementability.
- **QUESTION** — request for clarification.

## Critical constraints

**1. LOCKED specs READ-ONLY.** Do NOT edit SPEC-001 v1.3,
SPEC-004, SPEC-005, SPEC-006, SPEC-008, SPEC-010, SPEC-011.
Verify with `git diff specs/SPEC-001-phase3-binary.md
specs/SPEC-004*.md specs/SPEC-006*.md specs/SPEC-008*.md
specs/SPEC-010*.md specs/SPEC-011*.md` — must be empty.

**2. §7.1 EXISTING content + §5 + §7.2 + §7.3 byte-identity.**
Spot-checks:
```
git show HEAD:specs/SPEC-002-coordinator.md > /tmp/spec002-head.md
diff <(awk '/^## 5\./,/^## 6\./' /tmp/spec002-head.md) \
     <(awk '/^## 5\./,/^## 6\./' specs/SPEC-002-coordinator.md)
diff <(awk '/^### 7\.2/,/^### 7\.3/' /tmp/spec002-head.md) \
     <(awk '/^### 7\.2/,/^### 7\.3/' specs/SPEC-002-coordinator.md)
diff <(awk '/^### 7\.3/,/^### 7\.4/' /tmp/spec002-head.md) \
     <(awk '/^### 7\.3/,/^### 7\.4/' specs/SPEC-002-coordinator.md)
```
For §7.1, byte-identity applies ONLY to the EXISTING content
(lines ~1648-1894 in HEAD; the v1.3.5 extensions are APPENDED at
the END of §7.1). Verify that the existing §7.1 sub-sections
(connection lifecycle, provider authentication mode, hello, etc.)
are byte-identical to v1.3.4 — only the new "Heartbeat field
extension" and "ApplyHeartbeat hash-clearing REPLACEMENT"
sub-sections at the END of §7.1 are in scope for v1.3.5. If any
existing §7.1 content was modified = CRITICAL.

**3. Spec-text-only revision.** Spot-check:
`git diff --stat phase4-coordinator/` must be empty.

**4. ApplyHeartbeat REPLACEMENT correctness.** The §7.1
ApplyHeartbeat REPLACEMENT sub-section is the most consequential
change in v1.3.5. Verify:
- (a) The sub-section title contains "REPLACEMENT" unmissably.
- (b) The opening paragraph identifies the locked code path being
  replaced (`phase4-coordinator/internal/pool/provider.go:411-432`).
- (c) The two-path dispatch (LEGACY PATH / SPEC-011 PATH) is
  per-heartbeat based on `model_hash` field presence, NOT sticky.
- (d) The exactly-once emission gate uses `LastLoadingState`
  sticky reset.
- (e) R-7.1.6 cross-references R-7.10.10 (the conditional-emission
  rule).
Any deviation = MAJOR.

**5. `operator_model_swap` payload schema correctness.** The
§7.10.2 schema MUST match SPEC-011 v0.5 §3.6 byte-for-byte:
- 8 REQUIRED fields: `event`, `ts`, `provider_assigned_id`,
  `from_model_id`, `to_model_id`, `to_model_hash`,
  `loading_window_ms`, `hash_verification_result`.
- 2 OPTIONAL fields: `from_model_hash`,
  `drain_inflight_count_estimate`.
- NO other top-level keys.
If any field is renamed, missing, or added beyond this contract =
MAJOR. (The BUILD pass had this wrong; verify the polish fix
landed correctly.)

**6. F-1.5 invariants enforcement.** R-7.10.9 + AC-K.11 MUST
prohibit `conv:`, raw `account_id`, sticky session identifiers,
and buyer prompt text from the payload. If R-7.10.9 is missing or
references a wrong SPEC-011 rule = MAJOR.

**7. Conditional emission rule correctness.** R-7.10.10 + AC-K.12
MUST document the two WS-drop scenarios per SPEC-011 v0.5 R-3.6.6:
- Reconnect AFTER swap completed: NO event fires.
- Reconnect DURING load (first post-reconnect heartbeat has
  `loading: true` with OLD `model_id`): event fires normally on
  subsequent swap completion.
§7.1 R-7.1.6 MUST cross-reference R-7.10.10.

**8. Code-grounding citations are normative.** Spot-check the
cited line numbers against actual source:
- `phase4-coordinator/internal/ws/server.go:354`
  (`authAttemptID := "auth-" + s.newUUID()`)
- `phase4-coordinator/internal/ws/server.go:355`
  (`challengeExpiresAt := s.now().Add(10 * time.Minute)`)
- `phase4-coordinator/internal/ws/server.go:398`
  (provider-ID match enforcement at proof stage)
- `phase4-coordinator/internal/ws/messages.go:333-388`
  (`parseAuthInitial`)
- `phase4-coordinator/internal/ws/messages.go:391-401`
  (`parseAuthProof`)
- `phase4-coordinator/internal/pool/provider.go:411-432`
  (`ApplyHeartbeat` function range)
- `phase4-coordinator/internal/pool/provider.go:420-432`
  (LEGACY PATH hash-clearing range cited in R-7.1.3)
- `phase4-coordinator/internal/config/config.go:269`
  (`MaxUnauthenticatedConn: 64`)
Any miscite = MAJOR.

**9. Auth-attempt lifecycle source-of-truth handover.** §7.9
opening paragraph MUST explicitly state that v1.3.5 §7.9 takes
over from SPEC-010 v1.5 R-3.1.10 clauses 1+5 (which were
designated as the interim source-of-truth in SPEC-010 v1.5 §6.2).

**10. v2 `auth_request` field tables.** §7.8.1 initial-stage
table and §7.8.2 proof-stage table MUST match SPEC-010 v1.5
§3.1.A and §3.1.C row-by-row. Any field present in one but not
the other, or with mismatched type/requiredness = MAJOR.

**11. R-rule numbering sanity.** §7.10 rules MUST be 1-11
sequential (no duplicates, no gaps). AC-K MUST be 0-14
sequential (no duplicates, no gaps).

**12. Clean-room.** No d-inference inspection.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.5 — full document. Focus on:
   - Top change-log block — verify v1.3.5 header structure +
     v1.3.5 bullet
   - §2 Scope additions
   - §3 NEW data-model sub-section (Provider struct extension)
   - §5 (Routing) — byte-identical to v1.3.4
   - §7.1 EXISTING content byte-identical to v1.3.4 + NEW
     extensions APPENDED at end (heartbeat field extension +
     ApplyHeartbeat REPLACEMENT sub-section)
   - §7.2 / §7.3 byte-identical to v1.3.4
   - §7.4 with /v1/status echo extension
   - §7.8 (v2 `auth_request` provider handshake) — verify field
     tables match SPEC-010 §3.1.A and §3.1.C
   - §7.9 (auth-attempt lifecycle) — verify source-of-truth
     handover from SPEC-010 R-3.1.10 clauses 1+5; verify 4
     lifecycle events; verify 10-min timeout citation
   - §7.10 (audit-log infrastructure) — verify §7.10.2 payload
     schema correctness, R-7.10.9 F-1.5 invariants, R-7.10.10
     conditional emission
   - §11 AC-K.0 through AC-K.14 — verify each cites binding AC
   - §13 hand-off file structure extensions

2. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.3 (LOCKED) — focus on §6.7 (v2 `auth_request` handshake),
   §6.10 (heartbeat extension), §6.11.4 (WS-drop reconnect uses
   legacy `hello`), AC-18.0 through AC-18.16. Verify SPEC-002
   v1.3.5 is consistent at every wire-protocol point of contact.

3. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.5 (LOCKED) — focus on §3.1.A, §3.1.C, §3.3, §3.6, R-3.1.10,
   §6.2 (SPEC-002 v1.3.5 candidate guidance).

4. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   v0.5 (LOCKED) — focus on §3.3 heartbeat extension, §3.5 SPEC-008
   Pillar A re-verification, §3.6 `operator_model_swap` event
   (R-3.6.1 through R-3.6.6 inclusive), §6.2 (SPEC-002 v1.3.5
   candidate guidance including D2.1 ApplyHeartbeat REPLACEMENT
   call-out).

5. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2-attestation.md`
   v0.3 (LOCKED) — focus on §5.3-§5.7 (Pillar A pipeline +
   five-state hash enumeration) for §7.1 ApplyHeartbeat
   REPLACEMENT R-7.1.5 + R-7.10.7 citations.

6. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md`
   Entries 54, 55, 56 — strategic context.

7. `/Users/augstar/macprovider-poc/CLAUDE.md` — repo conventions.

8. Code spot-check files for the citations enumerated in critical
   constraint 8.

DO NOT inspect d-inference source.

## Audit categories

### Category A: L-1 baseline coordinator handling

A.1  AC-K.0 asserts the L-1 baseline cell is processed byte-
     identical to a pre-SPEC-010/SPEC-011 binary. Verify that the
     spec text supports this — specifically that the LEGACY PATH
     of ApplyHeartbeat (R-7.1.3) is invoked for v1.3 binaries
     without `--enable-warm-swap` and processes hash-clearing
     exactly as the locked v1.3.4 behavior.

A.2  §7.8.1 R-7.8.3 explicitly states the L-1 baseline accepts a
     single-entry `supported_models: [model_id]` frame as
     functionally indistinguishable from a pre-SPEC-010 binary
     per SPEC-010 v1.5 §4.1. Verify.

A.3  §7.9 R-7.9.8 explicit L-1 presence gate: if initial-stage
     frame has neither `supported_models` nor
     `publishes_supported_models`, no SPEC-010 retention state is
     created. Verify this matches SPEC-010 v1.5 R-3.1.10 clause 1.

### Category B: Locked-spec citations and accuracy

B.1  For each new R-rule in §3.X data-model, §7.1 extensions,
     §7.4 extension, §7.8, §7.9, §7.10, verify the cited SPEC-001
     v1.3, SPEC-010 v1.5, SPEC-011 v0.5, or SPEC-008 v0.3 rule
     (a) exists in the locked spec and (b) actually says what
     the cite implies. Sample at least 15 rules across the new
     sections.

B.2  §7.8.1 field table row-by-row against SPEC-010 v1.5 §3.1.A.
     Any field present in one but not the other, or with
     mismatched type/requiredness = MAJOR.

B.3  §7.8.2 proof-stage field table row-by-row against SPEC-010
     v1.5 §3.1.C. Same rule = MAJOR.

B.4  §7.10.2 payload schema match SPEC-011 v0.5 §3.6 byte-for-byte
     (the M.1 polish target). Verify the 8 REQUIRED + 2 OPTIONAL
     contract is correct.

### Category C: Code-grounding accuracy

C.1  Run each line-citation spot-check enumerated in critical
     constraint 8. Any miscite = MAJOR.

C.2  R-7.1.3 cites `provider.go:420-432` for the LEGACY PATH
     hash-clearing range. Verify the actual code range matches.

C.3  R-7.10.6 says `loading_window_ms` is computed from coordinator
     clock, NOT provider-reported. Verify this matches SPEC-011
     v0.5 R-3.6.3.

### Category D: ApplyHeartbeat REPLACEMENT correctness

D.1  Run the 5-point check in critical constraint 4 (a-e). Any
     deviation = MAJOR.

D.2  Verify that R-7.1.6 + R-7.10.10 together correctly describe
     the conditional-emission contract. The "current session"
     qualifier in R-7.1.6 + the "no event on reconnect-after-swap"
     + "event on reconnect-during-load + subsequent completion"
     must be internally consistent.

### Category E: New AC coverage

E.1  Each AC-K.0 through AC-K.14 cites a binding SPEC-001 v1.3,
     SPEC-010 v1.5, SPEC-011 v0.5, or SPEC-008 v0.3 AC by number.
     Verify each cite by reading the named AC. Cite that doesn't
     trace = MAJOR.

E.2  AC-K.10 (payload schema) lists all 8 REQUIRED + 2 OPTIONAL
     keys with the correct names — verify against SPEC-011 v0.5
     R-3.6.1 / R-3.6.2.

E.3  AC-K.11 (F-1.5 invariants) test oracle: "static grep
     against payload-building code AND a runtime regression test."
     Verify this is operationally testable (i.e., the spec gives
     a future implementer enough to write the test).

E.4  AC-K.12 (conditional emission) covers both WS-drop
     scenarios per R-3.6.6. Verify.

E.5  AC coverage gaps: does v1.3.5 introduce a normative behavior
     (R-rule) not covered by any AC-K.X? Examples to check:
     - R-7.8.4 SPEC-010 field validation order — covered by
       AC-K.X?
     - R-7.9.6 retention map size bound (1024 default) — covered?
     - R-7.10.1 SQLite schema — covered?
     - R-7.10.2 `ts_utc` RFC3339 format — covered?
     - R-7.10.6 `loading_window_ms` coordinator-clock — covered?
     - R-7.10.7 `hash_verification_result` 5-state enum — covered?
     Each gap = MINOR.

### Category F: §3.X Provider data-model extension

F.1  §3.X correctly enumerates the SPEC-010-added fields
     (`SupportedModels[]`, `PublishesSupportedModels`) per
     SPEC-010 v1.5 §3.3.

F.2  §3.X documents `HashStatus` (SPEC-008 5-state enum) and
     `AuthAttemptRetention` map per §7.9 + §7.10.

F.3  `LastLoadingState` field (per R-7.1.6 + R-7.10.8) — is it
     documented in §3.X? If not, MINOR (data-model
     under-specification).

### Category G: §7.4 /v1/status echo extension

G.1  R-7.4.X correctly conditional on `PublishesSupportedModels`.

G.2  When `PublishesSupportedModels` is `false`, the field is
     OMITTED (not emitted as `null` or `[]`) — verify spec text.

### Category H: Change-log + §13 hand-off

H.1  Change-log v1.3.5 header present with own bullet (not
     grouped under v1.3.4).

H.2  Prior change-log entries (v1.3.4, v1.3.3, ...) byte-identical.

H.3  §13 file structure lists the 4 new Go files + 6 modified
     files from the BUILD prompt edit J.

### Category I: Anything else

I.1  Documentation drift not covered above.

I.2  Internal cross-references between §7.8 / §7.9 / §7.10 / §7.1
     correct (especially R-7.1.6 ↔ R-7.10.10).

I.3  Renumbering sanity: §7.10 rules 1-11 sequential, AC-K 0-14
     sequential, no duplicates.

I.4  Tier-2 (SPEC-008) handling unchanged from v1.3.4 — no v1.3.5
     surface accidentally re-specs Tier-2 beyond citing SPEC-008
     v0.3.

## Output structure

CREATE `/Users/augstar/macprovider-poc/specs/SPEC-002-v1-3-5-audit.md`
with the following top-of-file structure:

```
# SPEC-002 v1.3.5 audit history

## Round 1 — Codex GPT-5 — 2026-06-06 — Normative audit

**Audited:** SPEC-002 v1.3.5 (specs/SPEC-002-coordinator.md)
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
- Rewriting the spec
- Implementing the spec
- Editing SPEC-001 v1.3, SPEC-004, SPEC-005, SPEC-006, SPEC-008,
  SPEC-010, SPEC-011 (all LOCKED)
- Re-litigating Claude's pre-audit M.1 / M.2 / M.3 polish (verify
  closure, do not re-open)

## Done criteria

You are done when:

- `specs/SPEC-002-v1-3-5-audit.md` created with the round-1 section
- Every category A-I has a section
- Every R-rule in §3.X, §7.1 extensions, §7.4 extension, §7.8,
  §7.9, §7.10 has been sampled at least once for citation accuracy
- §5 / §7.2 / §7.3 byte-identity spot-checks executed and result
  reported
- All 8 line citations enumerated in critical constraint 8 spot-
  checked against actual source
- ApplyHeartbeat REPLACEMENT 5-point check (constraint 4) reported
- Payload schema match check (constraint 5) reported
- F-1.5 invariants check (constraint 6) reported
- Conditional emission check (constraint 7) reported
- Executive summary states the explicit verdict
- `git diff phase4-coordinator/` confirmed empty
- `git diff specs/SPEC-001-phase3-binary.md specs/SPEC-004*.md
  specs/SPEC-006*.md specs/SPEC-008*.md specs/SPEC-010*.md
  specs/SPEC-011*.md` confirmed empty

=== END PROMPT ===
```

---

## Operator notes

- Expected wall-clock: 30-50 min (larger surface than SPEC-001
  v1.3 audit: 3 NEW sections + 15 ACs + ApplyHeartbeat REPLACEMENT
  + payload schema verification).
- Pre-audit polish closed 3 MAJORs (M.1 payload schema, M.2 F-1.5,
  M.3 conditional emission); round 1 should find 0/0/0-2 MINOR.
- If verdict is LOCK CONFIRMED: lock SPEC-002 v1.3.5, draft Entry
  57, commit + push (PR #3 updates with the new SPEC-002 v1.3.5
  content).
- If LOCK-READY pending polish: apply polish, run round-2
  LOCK-confirmation audit.
- If unexpected MAJOR/CRITICAL: revise + round 2.
