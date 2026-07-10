# Audit prompt — SPEC-010 v1.2 (narrow scope, round 3)

Operator-paste prompt to audit SPEC-010 v1.2
(`specs/SPEC-010-model-catalog.md`).

**Round 3.** Round 1 (Codex on v1.0) found 0 CRITICAL / 3 MAJOR /
1 MINOR. Round 2 (Codex on v1.1) found 0 CRITICAL / 3 MAJOR / 2
MINOR. v1.2 is a contract-tightening pass that claims to close
all 5 round-2 findings:
- B.1 round 2 + B2.1 (cluster) — §3.1.A new self-contained field
  table; §6.1/§6.2 reframed as "MUST ADD" not "extend existing"
- B2.2 — new R-3.1.10 proof-stage parser/retention contract
- E2.1 — §9 references fixed (§7.1 + §7.3, no §7.2)
- E2.2 — change log AC numbering corrected

Round 3 has two jobs:

1. **Round-2 fix verification (R2V)** — for each round-2 finding,
   cite the v1.2 rule/AC and mark PASS / PARTIAL / FAIL.
2. **Audit the v1.2-new normative surface** — §3.1.A field table
   correctness against actual `AuthRequest` Go struct, §3.1.B
   example completeness, R-3.1.10 5-clause proof-stage contract,
   AC-18 three-sub-case update, §6.1/§6.2 "MUST ADD" reframing.

The round-2 prompt (`specs/AUDIT_SPEC_010_V1_1_PROMPT.md`) and
round-1 prompt (`specs/AUDIT_SPEC_010_PROMPT.md`) are background;
this is the active prompt for v1.2.

Append round-3 findings to the existing
`specs/SPEC-010-audit.md` as a new top-level section after the
round-2 report. Do not overwrite rounds 1 or 2.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-010 v1.2 at /Users/augstar/macprovider-poc/
specs/SPEC-010-model-catalog.md. This is round 3 of the audit on
the post-split narrow scope.

Round 2 (Codex GPT-5 on v1.1) produced 0 CRITICAL / 3 MAJOR / 2
MINOR / 0 QUESTION findings at /Users/augstar/macprovider-poc/
specs/SPEC-010-audit.md. v1.2 is a contract-tightening pass that
claims to close all 5 round-2 findings:
- B.1 round 2 + B2.1 (cluster): §3.1.A new compact normative
  field table for v2 `auth_request` initial-stage; §3.1.B real
  example without hidden `"..."`; §6.1/§6.2 reframed as "MUST ADD
  v2 `auth_request` contract" instead of "extend existing v2
  text" (because no locked text describes v2)
- B2.2: new R-3.1.10 five-clause proof-stage parser/retention
  contract (initial-stage retention; absent = OK; present =
  case-fold compare; mismatch = reject; retention cleanup)
- E2.1: §9 reference list now cites §7.1 + §7.3, not §7.2
- E2.2: change log AC numbering corrected

You are NOT here to validate, rewrite, or extend the spec. Two
explicit jobs:

  J-1. **Round-2 fix verification (R2V).** For each round-2
       finding, cite the v1.2 rule/section/AC and mark PASS /
       PARTIAL / FAIL.

  J-2. **Audit the v1.2-new normative surface.** Specifically:
       - §3.1 framing rewrite (locked-spec source-of-truth
         acknowledgement)
       - §3.1.A compact field table (18 existing fields + 2
         SPEC-010 fields) — does the table accurately reflect
         the `AuthRequest` Go struct?
       - §3.1.B example with full real field set (no `"..."`
         placeholders)
       - R-3.1.10 five-clause proof-stage parser contract
       - AC-18 three-sub-case rewrite
       - §6.1 SPEC-001 v1.2.5 candidate annotation reframe
         ("MUST ADD new normative section for v2 auth_request")
       - §6.2 SPEC-002 v1.3.5 candidate annotation reframe
         (same)
       - §9 reference list correction

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-010-audit.md

APPEND a new top-level section to the existing file:
  `## Round 3 — Codex GPT-5 — 2026-06-06`
followed by category-organized findings. Do NOT touch round-1 or
round-2 sections.

## Severity definitions

Unchanged from rounds 1-2.
- **CRITICAL** — production failure, locked-spec scope creep
  (SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-004 v0.3.1, SPEC-008
  v0.3), or L-1..L-6 violation.
- **MAJOR** — implementer confusion, contract precision gap,
  back-compat that doesn't hold, or scope expansion.
- **MINOR** — quality only.
- **QUESTION** — unresolved design choice.

## Critical constraints

**1. Locked decisions (§2 L-1..L-6) are READ-ONLY.**

**2. SPEC-001 v1.2.4, SPEC-002 v1.3.4 are LOCKED.** v1.2's §6.1
and §6.2 candidate annotations now explicitly say SPEC-001
v1.2.5 and SPEC-002 v1.3.5 MUST ADD a new v2 `auth_request`
normative section (since the v2 contract exists only in code).
Verify this framing doesn't accidentally claim authority over
the locked specs.

**3. v1.2's narrow scope is unchanged.** Verify v1.2 didn't
smuggle in SPEC-011 warm-swap or SPEC-012 demand-pull surface.

**4. §3.1.A field table is the new load-bearing artifact.**
Walk every field in the table against the actual `AuthRequest`
Go struct at
phase4-coordinator/internal/ws/messages.go lines 37-57. Any
field missing, mistyped, or marked incorrectly as
required/optional = MAJOR.

**5. R-3.1.10 introduces NEW coordinator implementation
machinery** (per-`auth_attempt_id` retention map for initial-
stage values). Verify this machinery is bounded (no unbounded
state), securely cleaned up (no leak path), and consistent with
the existing auth-attempt timeout in SPEC-002 §7.3.

**6. Clean-room.** Do NOT inspect d-inference source.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.2 — the spec under audit. Read the v1.2 change log first.
   Then read §3.1 (rewritten + §3.1.A field table + §3.1.B
   example), R-3.1.10 (in §3 rules block), AC-18 (rewritten),
   §6.1 + §6.2 (reframed), §9 (references) carefully.

2. `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md` —
   rounds 1 and 2. R2V target: find `### B.1 ... [PARTIAL]`,
   `### B2.1`, `### B2.2`, `### E2.1`, `### E2.2` in the round-2
   section.

3. `/Users/augstar/macprovider-poc/CLAUDE.md` — conventions.

4. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.2.4 — focus on §6.5 (legacy `hello` handshake). v1.2 §6.1
   correctly says SPEC-001 v1.2.5 MUST ADD a NEW v2
   `auth_request` section. Confirm §6.5 indeed documents `hello`,
   not `auth_request`.

5. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.4 — focus on §7.1 (provider WS, legacy hello), §7.3
   (token/auth). v1.2 §6.2 says SPEC-002 v1.3.5 MUST ADD a new
   v2 section. Confirm §7.1/§7.3 indeed document the legacy
   flow.

6. Code spot-checks:
   - `phase4-coordinator/internal/ws/messages.go` lines 37-57
     (`AuthRequest` Go struct — definitive source for §3.1.A
     field table)
   - `phase4-coordinator/internal/ws/messages.go` lines 302-329
     (initial-stage `auth_request` parser)
   - `phase4-coordinator/internal/ws/messages.go` lines 391-401
     (proof-stage `auth_request` parser — R-3.1.10 needs to
     extend this)
   - `phase4-coordinator/internal/pool/provider.go` lines 50-88
     (Provider struct)
   - `phase4-coordinator/internal/buyer/server.go` lines
     1027-1030 (ModelKnown caller — v1.0/v1.1/v1.2 §3.3.4 note
     still accurate?)

7. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md` v0.3 —
   confirm v1.2 still has zero interaction with §5.7 hash block.

8. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   — confirm no SPEC-011 scope creep into v1.2.

## Audit categories — work through each

### Category R2V: Round-2 fix verification (HIGHEST PRIORITY)

Table format. Mark PASS / PARTIAL / FAIL with v1.2 location and
1-sentence evidence.

- **R2V-B.1 round 2** (cited locked sources don't support
  `auth_request`) → v1.2 §3.1 framing rewrite + §3.1.A self-
  contained field table + §6.1/§6.2 reframed
- **R2V-B2.1** (`auth_request` field contract still code-
  dependent; example hides required fields behind `"..."`) →
  v1.2 §3.1.A field table + §3.1.B real example
- **R2V-B2.2** (proof-stage mismatch lacks parser/retention
  contract) → v1.2 R-3.1.10 + updated AC-18
- **R2V-E2.1** (§9 still cited §7.2) → v1.2 §9 references list
  fixed
- **R2V-E2.2** (change log AC numbering off-by-one) → v1.2
  change log corrected

### Category A3: Locked-decision preservation (v1.2 re-verification)

A3.1  Walk L-1 through L-6 against v1.2's new surface. Specifically:
      - L-1 byte-identical: does R-3.1.10's per-`auth_attempt_id`
        retention map produce any new log line, metric, or public
        field for legacy providers (no SPEC-010 fields sent)?
        Should be NO. If yes = CRITICAL.
      - L-3 one active model: §3.1.A field table includes
        `model_id` and `model_hash` — both single. L-3 still
        holds.
      - L-6 F-1.5: R-3.1.10's retention map is per-auth-attempt,
        not per-session or per-buyer. No sticky derivation input.

A3.2  R-3.1.10 retention bound: the rule says retention is
      released on (a) successful pool admission, (b) failure,
      (c) auth-attempt timeout. Is the auth-attempt timeout
      actually bounded in SPEC-002 §7.3? If unbounded =
      MAJOR (unbounded coordinator state).

### Category B3: §3.1.A field table accuracy

B3.1  Walk every row in the §3.1.A field table against the
      actual `AuthRequest` Go struct at messages.go lines
      37-57. Verify:
      - Each row's JSON name matches a struct tag
      - Each row's type matches the Go type (string ↔ string,
        int ↔ int/int64, float ↔ float64, etc.)
      - REQUIRED rows correspond to fields without `omitempty`
        OR fields the parser at messages.go:302-329 actively
        validates (e.g. `type`, `version`, `stage`)
      - "optional" rows correspond to fields with `omitempty`
      - No struct field is missing from the table
      - No table row is missing from the struct (i.e. spec
        doesn't invent fields)
      Any mismatch = MAJOR per row.

B3.2  §3.1.A says `type` is "exactly `auth_request`", `version`
      "exactly 2", `stage` "exactly initial/proof". Verify the
      parser at messages.go:302-329 actually enforces these
      values (rejects with `bad_request` or similar otherwise).
      If parser is more permissive = MAJOR (spec overclaims
      strictness).

B3.3  Tier-2 fields (`provider_ecdh_public_key`,
      `tier2_capabilities`, `attestation_token`): the table
      marks them optional. SPEC-008 §5/§7 may have them as
      REQUIRED-when-Tier-2-active. Is the table's "optional"
      marker accurate for the SPEC-010 audit's purpose, or
      does it mislead about SPEC-008-side requirements? If
      misleading = MINOR (cross-reference to SPEC-008 needed).

B3.4  §3.1.B example: "minimally-valid SPEC-010 initial-stage
      frame contains {`type`, `version`, `stage`, `provider_id`}
      plus the SPEC-010-added fields." Verify the parser
      actually admits this minimal set. If parser requires
      additional fields not in the minimum = MAJOR.

### Category C3: R-3.1.10 proof-stage parser contract

C3.1  Walk R-3.1.10 clauses 1-5 against current parser at
      messages.go:391-401. Clause 2 says "the proof-stage
      `auth_request` parser MUST be extended to read
      `supported_models` and `publishes_supported_models` if
      present." Verify the current parser is structurally
      amenable to this extension. If the parser uses a strict
      struct unmarshal that would silently drop unknown
      fields without a clear extension point = MINOR.

C3.2  Clause 1 retention scope: "per `auth_attempt_id` for the
      duration of the auth attempt." Verify `auth_attempt_id`
      is actually carried on the initial-stage frame (per
      §3.1.A it's optional; per
      `AuthRequest.AuthAttemptID` Go field). If the initial
      stage doesn't reliably have an `auth_attempt_id`, the
      retention key is undefined = MAJOR.

C3.3  Clause 4 case-fold comparison: NFC + ASCII fold per
      R-3.1.7. Set comparison: two normalized sets are equal
      iff same cardinality AND same membership. Is "different
      cardinality" testable in the spec's intended
      implementation? Yes — straightforward. No finding.

C3.4  Clause 5 retention cleanup: three trigger points (success,
      failure, timeout). Are there any code paths where an
      auth attempt could leak the retention entry — e.g. WS
      disconnect mid-handshake? If yes = MAJOR (leak class).

C3.5  R-3.1.10 doesn't define WHO retains: coordinator-side
      only? Or does the provider need to retain the
      initial-stage values too? It's clearly coordinator-side
      from context, but explicit is better. If unclear =
      MINOR.

### Category D3: AC quality (AC-18 update + AC-1 through AC-23)

D3.1  AC-18's three sub-cases: walk each against R-3.1.10.
      Sub-case (a) tests clause 3 absent-is-OK. Sub-case (b)
      tests clause 4 case-fold-match-is-OK. Sub-case (c) tests
      clause 4 mismatch-rejected. Coverage of R-3.1.10 clauses
      1, 2, 5 (retention, parser extension, cleanup)? If any
      clause has no AC = MAJOR.

D3.2  AC-13 normalized log comparison: round-2 confirmed
      feasible against coordinator's zerolog JSON. Still
      feasible with the new R-3.1.10 surface? Specifically:
      does R-3.1.10's retention/cleanup produce any new log
      events that would need to be in the "no SPEC-010-related
      entries on legacy path" assertion? If yes, AC-13 needs
      to enumerate them.

D3.3  New rules without ACs: R-3.1.10 has 5 clauses. AC-18 (a/b/c)
      covers clauses 3-4 (absent OK, present match/mismatch).
      What about clause 1 (retention scope), clause 2 (parser
      extension), clause 5 (cleanup)? If clauses 1-2 are
      implementation-detail-not-observable, no AC needed. If
      clause 5 cleanup could be tested via retention-leak
      assertion (auth attempts that fail don't accumulate
      state), it warrants an AC = MINOR.

### Category E3: Companion-spec annotation framing (§6.1/§6.2)

E3.1  §6.1 says SPEC-001 v1.2.5 MUST ADD a NEW v2
      `auth_request` section. Read SPEC-001 v1.2.4 §6.5
      carefully. Does §6.5 indeed document `hello` and NOT
      `auth_request`? Confirm. If §6.5 does have v2 content,
      §6.1 framing is wrong = MAJOR.

E3.2  §6.2 says SPEC-002 v1.3.5 MUST ADD a NEW v2
      `auth_request` section. Read SPEC-002 v1.3.4 §7.1 and
      §7.3 carefully. Confirm same. If §7.1 has v2 content,
      §6.2 framing is wrong = MAJOR.

E3.3  §6.1 / §6.2 both say the new sections are SPEC-NNN
      v1.X.5 candidate additions, not SPEC-010 normative
      commitments. Verify the framing actually preserves the
      scope split — SPEC-010 doesn't claim authority over
      SPEC-001/SPEC-002 normative content; it just identifies
      the gap. If §6.1/§6.2 wording slips into "SPEC-010
      requires SPEC-001 to..." prescriptive language = MAJOR.

### Category F3: Anything else

F3.1  Documentation drift checks.

F3.2  Naming nits.

F3.3  Hidden surfaces v1.2 exposes that round-2 didn't probe.

F3.4  Decision-log entry should be added when v1.2 locks. Note
      for executive summary; not a finding yet.

## Output structure

APPEND to `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md`.
Start your section with:

```
---

## Round 3 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-010 v1.2 (specs/SPEC-010-model-catalog.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 3 of N
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

### Round-3 executive summary

[2-3 paragraphs. State whether v1.2 is ready to LOCK directly,
ready after the round-3 findings are closed, or needs another
revision. Specifically note whether the round-2 fixes actually
closed in substance.]

### Round-2 fix verification (R2V)

[Table: round-2 finding ID, PASS / PARTIAL / FAIL, v1.2 location
verified, 1-sentence evidence.]
```

Then for each category R2V, A3-F3 write a section. For each
finding: severity, location, what/why/recommendation.

If a category has zero findings, write `(no findings)`.

## Out of scope

- Inspecting d-inference source
- Rewriting the spec
- Implementing the spec
- Auditing SPEC-001, SPEC-002, SPEC-004, SPEC-008 themselves
- Auditing SPEC-011 outline (separate cycle)
- Re-litigating round-1 or round-2 findings marked PASS

## Done criteria

You are done when:

- Round-3 section APPENDED to SPEC-010-audit.md (rounds 1-2
  intact)
- Every round-2 finding has PASS / PARTIAL / FAIL in R2V
- Every category R2V, A3-F3 has a section (even if "(no findings)")
- Every finding has severity, location, what/why/recommendation
- Round-3 executive summary states a clear verdict

=== END PROMPT ===
```

---

## Operator notes

- Expected wall-clock: 15-25 min (small surface increment).
- Convergence target: 0 CRITICAL / 0 MAJOR → lock SPEC-010 v1.2
  directly.
- If ≥1 CRITICAL or >1 MAJOR, draft v1.3, re-audit round 4.
- After lock, append decision-log entry to
  `beta/DECISION_CRITERIA.md`.
