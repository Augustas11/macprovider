# SPEC-005 execution plan — billing / settlement / rewards

**Status:** ready to execute  
**Date authored:** 2026-05-31  
**Quality bar:** same as SPEC-006 arc (53 findings closed, 4 audit cycles, 9 operator pre-commitments locked)  
**Estimated sessions:** 6 sessions + 3 operator decision gates

---

## How to read this document

Each **STEP** is a separate session. Open a fresh Claude Code or Codex session, paste the prompt block exactly, let it run. Each **GATE** is a pause where YOU act before the next session starts.

Session types:
- `[CLAUDE]` — paste into a fresh Claude Code session
- `[CODEX /goal]` — paste as a `/goal` command in Codex

The two models stay independent. Codex never reads Claude's audit; Claude never reads Codex's draft until the R2 audit step. That independence is what makes the cross-model audit valuable.

---

## Pre-seeded locked constraints

These are already decided by the existing spec corpus. The SCOPE session respects them; they are NOT open questions.

1. **`request_log` table already exists.** SPEC-002 §4 FR-B9 defines coordinator SQLite `request_log` with `request_id`, `timestamp`, `provider_id`, `model`, `prompt_tokens`, `completion_tokens`, `status`. SPEC-005 builds on this schema; it does not replace it.

2. **SPEC-001 wire format is frozen at v1.2.4.** SPEC-005 cannot require new fields from the Phase 3 binary. The `usage` object in inference responses already carries `completion_tokens` and `prompt_tokens`.

3. **SPEC-006 D3 quota-settlement matrix is locked.** Quota debits only for work the provider actually performed (provider-reached vs not). SPEC-005's reward formula MUST be consistent with this matrix — do not contradict it.

4. **Billing surface lives in coordinator, not gateway.** SPEC-006 §1.8 explicitly excludes: "rewards, payouts, provider contribution economics, payment-adjacent flows remain out of scope" of the gateway.

5. **SPEC-007 boundary.** SPEC-005 owns the internal ledger and reward calculation. The AntFeed USDC payment rail is SPEC-007 scope. SPEC-005 defines what the ledger emits; SPEC-007 wires it to AntFeed.

6. **Implementation language: Go.** Per Entry 17 decision log: "prefer Go/Rust/Python over Swift" for SPEC-005+.

7. **No on-chain settlement in v1.** Reward tracking is off-chain first. SPEC-005 defines the ledger; settlement mechanics may reference AntFeed but MUST NOT require on-chain state in v1.

8. **H-005 (billing settlement fairness) must close.** SPEC-006 v0.6 notes H-005 is "partially covered by D-CROSS-1 + SPEC-001 v1.2.3 cancel-usage normative." SPEC-005 must close it fully.

---

## STEP 1 — SCOPE analysis [CLAUDE]

Open a **fresh Claude Code session** rooted at `/Users/augstar/macprovider-poc`. Paste everything between the markers.

```
=== BEGIN PROMPT ===

You are producing the SPEC-005 design exploration. SPEC-005 is
Mac Provider's billing, settlement, and provider-rewards spec. It is
the last remaining spec before public launch.

Your output is a design exploration document (NOT a normative spec
yet) and a structured operator-decisions table. A separate BUILD
session will draft the normative spec after the operator locks
pre-commitments from your output.

## Output files

1. `specs/SPEC-005-design.md` — design analysis, ~600–1000 lines
2. `specs/SPEC-005-operator-decisions.md` — blank pre-commitment table

## What to read first

Read all of these before writing anything:

- `specs/SPEC-001-phase3-binary.md` (wire format, usage reporting)
- `specs/SPEC-002-coordinator.md` (coordinator, request_log, tokens table)
- `specs/SPEC-003-open-onboarding.md` (provider onboarding, §deferred rewards)
- `specs/SPEC-004-smart-router.md` (attribution, FR-P11a, SPEC-005 references)
- `specs/SPEC-006-buyer-api.md` (quota, D3 refund matrix, §1.8 boundary, H-005)
- `specs/SPEC-008-tier2.md` (Tier 2 attestation surface)
- `beta/DECISION_CRITERIA.md` (entries 17–37, especially Entry 22 five lessons
  and Entry 36 remaining pre-public gates)

## Pre-seeded locked constraints (do not re-open these)

1. `request_log` table already exists in coordinator SQLite (SPEC-002 FR-B9).
   SPEC-005 extends it; does not replace it.
2. SPEC-001 v1.2.4 wire format is frozen. No new fields from Phase 3 binary.
3. SPEC-006 D3 quota-settlement matrix is locked. Reward formula must be
   consistent with it.
4. Billing state lives in coordinator, not gateway (SPEC-006 §1.8).
5. SPEC-007 boundary: SPEC-005 owns the internal ledger. AntFeed payment rail
   is SPEC-007.
6. Go is the implementation language.
7. No on-chain settlement in v1.
8. H-005 (billing settlement fairness) must be closed by SPEC-005.

## Design analysis structure for `SPEC-005-design.md`

The document must cover these 12 open questions. For each: state the
question, list 2–4 options with real tradeoffs, and recommend one
path given the project's north star (cheapest network access, no
frills, grow supply first). Do NOT hedge by listing options without
recommending — the operator needs one clear call per question.

Q1.  Billing model: pre-paid token bundles vs. post-paid credit-card
     vs. API key + running balance vs. donation/free with tip jar.

Q2.  Settlement cadence for provider rewards: real-time accrue +
     weekly payout vs. monthly batch vs. threshold-triggered.

Q3.  Provider reward formula: flat $/M tokens vs. dynamic market
     rate vs. reputation-weighted (uptime × quality × supply).

Q4.  Minimum payout threshold: what token-earning floor before a
     payout is logged (prevents micro-ledger noise)?

Q5.  Revenue split: what % operator takes vs. provider keeps. Is
     it per-provider configurable or a global rate?

Q6.  Currency/unit: internal token units converted at settlement vs.
     USDC micro-amounts accrued in real time vs. fiat-equivalent.

Q7.  Buyer balance enforcement: hard limit (reject when exhausted)
     vs. soft limit (warn + grace period) vs. rolling window.

Q8.  Failed/partial-request accounting: how does the SPEC-006 D3
     matrix (provider-reached vs. not) flow to provider reward
     calculation for the same request?

Q9.  Crash recovery / reconciliation: coordinator crashes after
     billing debit is recorded but before provider response
     forwarded. What is the correct recovery state?

Q10. Multi-provider attribution: SPEC-004 may route a conversation
     across providers. How is reward split for a multi-hop?

Q11. Operator dashboard: what metrics does the operator need to see
     (revenue, per-provider earnings, payout due, buyer balances)?

Q12. Fraud floor: do circuit-broken or degraded providers earn zero,
     reduced, or full rewards for requests routed to them before
     the circuit fires?

## Pre-commitment table for `SPEC-005-operator-decisions.md`

After the design analysis, produce a separate file with this exact
markdown table. Leave the Operator Decision column blank — the
operator fills it before the BUILD session runs.

```
# SPEC-005 operator pre-commitments

| # | Design question | Options (from design.md) | Operator Decision |
|---|---|---|---|
| D1 | Billing model | [summarize from Q1] | |
| D2 | Settlement cadence | [summarize from Q2] | |
| D3 | Provider reward formula | [summarize from Q3] | |
| D4 | Min payout threshold | [summarize from Q4] | |
| D5 | Revenue split | [summarize from Q5] | |
| D6 | Currency/unit | [summarize from Q6] | |
| D7 | Buyer balance enforcement | [summarize from Q7] | |
| D8 | Failed-request accounting | [summarize from Q8] | |
| D9 | Crash recovery policy | [summarize from Q9] | |
| D10 | Multi-provider attribution | [summarize from Q10] | |
| D11 | Operator dashboard scope | [summarize from Q11] | |
| D12 | Fraud floor for degraded providers | [summarize from Q12] | |
```

## Tone and depth

Same depth as `specs/SPEC-006-design.md`. Prose + tradeoff tables.
No normative language (no MUST/SHOULD yet — that comes in BUILD).
Recommend clearly. Do not defer decisions back to the operator
without a recommendation attached.

=== END PROMPT ===
```

**Expected output:** `specs/SPEC-005-design.md` + `specs/SPEC-005-operator-decisions.md`

---

## ★ GATE 1 — Operator fills pre-commitments

Open `specs/SPEC-005-operator-decisions.md`. Fill the "Operator Decision" column for all 12 rows. Commit the file when done.

**Time:** 30–60 min. Read design.md for each question before deciding.

**Before moving to Step 2, check:**
- [ ] All 12 rows have a decision
- [ ] No decision contradicts a locked constraint from the pre-seeded list above
- [ ] D8 (failed-request) is consistent with SPEC-006 D3 matrix
- [ ] File committed to git

---

## STEP 2 — Claude writes BUILD prompt [CLAUDE]

Open a **fresh Claude Code session** rooted at `/Users/augstar/macprovider-poc`. Paste everything between the markers.

```
=== BEGIN PROMPT ===

You are writing `specs/BUILD_SPEC_005_PROMPT.md` — the build prompt
that a separate Codex session will execute to draft SPEC-005 v0.1.

## What to read first

1. `specs/SPEC-005-design.md` — the full design exploration
2. `specs/SPEC-005-operator-decisions.md` — operator's locked decisions
3. `specs/BUILD_SPEC_006_PROMPT.md` — use as structural template
4. `specs/SPEC-006-buyer-api.md` — use as quality bar for depth/format
5. `specs/SPEC-002-coordinator.md` — especially §4 storage contracts,
   request_log schema, token table
6. `beta/DECISION_CRITERIA.md` Entry 22 (five lessons, especially the
   SCOPE→BUILD two-stage pattern and locked-decisions discipline)

## What the BUILD prompt must include

The prompt you write must instruct the Codex executing session to:

1. **Output file:** `specs/SPEC-005-billing.md`
2. **Target length:** 1,800–2,800 lines (comparable to SPEC-006 v0.1
   at 2,373 lines)
3. **Structure:** same as SPEC-002 and SPEC-006 — numbered sections,
   RFC 2119 MUST/SHOULD/MAY, explicit acceptance criteria with
   deterministic verification steps, change log header, § 2
   locked-decisions section (read-only; all 12 D1–D12 decisions
   encoded as normative pre-commitments, not revisited)
4. **Explicit out-of-scope guard:** list what SPEC-005 explicitly
   does NOT cover (AntFeed payment rail, on-chain settlement,
   gateway billing, Phase 3 binary changes)
5. **Interface contracts:** SPEC-005 must specify exactly which
   existing data it reads (request_log schema from SPEC-002 FR-B9,
   usage from SPEC-001, circuit state from SPEC-002 FR-P11a) and
   what new tables or endpoints it adds to coordinator
6. **Acceptance criteria:** every § must have at least one AC with a
   deterministic verification step (testable without a live network)
7. **Cross-spec dependency lines:** version-pin each upstream spec
   (SPEC-001 v1.2.4, SPEC-002 v1.3.3, SPEC-004 current version,
   SPEC-006 current version) so regressions are detectable

## What the BUILD prompt must NOT allow the executing session to do

- Relitigate any of D1–D12 (they are locked; the executing session
  has no design space)
- Add billing logic to the gateway (SPEC-006 §1.8 boundary)
- Require new fields from SPEC-001 Phase 3 binary
- Implement AntFeed payment rail (SPEC-007)
- Propose on-chain settlement

## Format of BUILD_SPEC_005_PROMPT.md

Follow the exact format of `specs/BUILD_SPEC_006_PROMPT.md`:
- Header block explaining the two-stage pattern
- Instruction to run in Claude Code or Codex
- `=== BEGIN PROMPT ===` / `=== END PROMPT ===` markers
- Paste-and-run, no context from this session needed

Do NOT draft SPEC-005 itself. Only produce the BUILD prompt file.

=== END PROMPT ===
```

**Expected output:** `specs/BUILD_SPEC_005_PROMPT.md`

**Before moving to Step 3, verify:**
- [ ] The BUILD prompt embeds all 12 locked decisions from operator-decisions.md
- [ ] Out-of-scope guards are explicit
- [ ] Interface contracts reference SPEC-002 request_log schema by field name

---

## STEP 3 — Codex: BUILD + R1 self-audit + FIX prompt draft [CODEX /goal]

Open a **fresh Codex session** rooted at `/Users/augstar/macprovider-poc`. Run this `/goal`:

```
/goal

Working directory: /Users/augstar/macprovider-poc

## Phase A — Draft the spec

Read specs/BUILD_SPEC_005_PROMPT.md in full. Execute the prompt
exactly as written. Produce specs/SPEC-005-billing.md v0.1. Do not
abbreviate or defer sections — complete every section the prompt
requires. Target: 1,800–2,800 lines.

Commit the file when done:
  git add specs/SPEC-005-billing.md
  git commit -m "feat(spec): SPEC-005 billing/settlement v0.1 draft"

## Phase B — Codex R1 self-audit

Immediately audit your own draft using the methodology from
specs/AUDIT_SPEC_006_PROMPT.md as a template. Produce a new file:
  specs/SPEC-005-r1-audit.md

Structure the audit as:
- Executive summary (verdict: READY WITH FIX PASS / NOT READY)
- CRITICAL findings (numbered C-1, C-2...)
- MAJOR findings (numbered M-1, M-2...)
- MINOR findings (numbered N-1, N-2...)
- QUESTIONS for the operator (numbered Q-1, Q-2...)

For each finding include:
  - Severity
  - Section reference (§ number)
  - Description of the gap or error
  - Proposed fix (one sentence)

Audit focus areas for SPEC-005 specifically:
1. Does the reward formula have a closed-form calculation for every
   request state in the SPEC-006 D3 matrix?
2. Are all 12 operator pre-commitments (D1–D12) encoded in § 2 and
   referenced normatively in the relevant sections?
3. Does the storage contract specify every new table/column with
   data type, constraint, and migration path?
4. Is the SPEC-002 request_log schema read-only (SPEC-005 must not
   ALTER it, only JOIN it)?
5. Does every acceptance criterion have a deterministic verification
   step that does not require a live network?
6. Are the out-of-scope guards explicit (AntFeed, on-chain, gateway)?
7. Does crash recovery (D9) have a normative recovery algorithm?

Commit the audit file:
  git add specs/SPEC-005-r1-audit.md
  git commit -m "audit(spec): SPEC-005 Codex R1 self-audit findings"

## Phase C — Draft FIX prompt (do NOT execute it)

Based on the R1 audit findings, produce:
  specs/FIX_SPEC_005_V0_2_PROMPT.md

Structure exactly like specs/FIX_SPEC_006_V0_2_PROMPT.md:
- Header explaining this is a fix prompt (not to be executed until
  operator reviews it)
- =\=\= BEGIN PROMPT === / === END PROMPT === markers
- Inside the prompt: list every CRITICAL and MAJOR finding with its
  proposed fix, ordered by section number
- Budget line: state estimated line count of changes
- Explicit guard: "Do NOT change any D1–D12 pre-commitment in § 2"

STOP after writing FIX_SPEC_005_V0_2_PROMPT.md. Do not execute it.
Commit it:
  git add specs/FIX_SPEC_005_V0_2_PROMPT.md
  git commit -m "chore(spec): SPEC-005 FIX v0.2 prompt draft (unreviewed)"
```

**Expected output:** `specs/SPEC-005-billing.md` v0.1, `specs/SPEC-005-r1-audit.md`, `specs/FIX_SPEC_005_V0_2_PROMPT.md`

---

## ★ GATE 2 — Operator reviews FIX prompt

Open `specs/FIX_SPEC_005_V0_2_PROMPT.md`. Scan for:

- [ ] Any finding that proposes changing a D1–D12 pre-commitment (reject it)
- [ ] Any fix that would require SPEC-001 wire format changes (reject it)
- [ ] Any contradiction between two findings (resolve it before execution)
- [ ] Line budget is realistic (if >600 lines of changes, flag which findings to defer)
- [ ] CRITICAL findings from R1 audit are all addressed

If edits needed: edit the file directly. Commit the edited version before Step 4.

**Time:** 10–20 min. This gate exists because: in SPEC-006, the D3 contradiction in the FIX prompt was caught here by the operator reading it — not by the executing session or a downstream audit. (Entry 22 lesson 5.)

---

## STEP 4 — Codex: Execute FIX → v0.2 [CODEX /goal]

Open a **fresh Codex session** rooted at `/Users/augstar/macprovider-poc`. Run this `/goal`:

```
/goal

Working directory: /Users/augstar/macprovider-poc

Read specs/FIX_SPEC_005_V0_2_PROMPT.md in full. Execute the prompt
exactly as written to produce specs/SPEC-005-billing.md v0.2.

Rules:
- Do not add findings not listed in the FIX prompt
- Do not change the § 2 locked-decisions section (it is read-only)
- Do not add new out-of-scope guards unless the FIX prompt explicitly
  lists them
- Update the version header to v0.2 and append a changelog entry
  summarising which findings were fixed

When done, commit:
  git add specs/SPEC-005-billing.md
  git commit -m "fix(spec): SPEC-005 v0.2 — apply R1 FIX pass"
```

**Expected output:** `specs/SPEC-005-billing.md` v0.2

---

## STEP 5 — Claude R2 audit + cross-spec coherence [CLAUDE]

Open a **fresh Claude Code session** rooted at `/Users/augstar/macprovider-poc`. Paste everything between the markers.

```
=== BEGIN PROMPT ===

You are running TWO audits on SPEC-005 v0.2, then producing a single
consolidated FIX prompt. Do not execute the FIX. Stop after the prompt
file is written.

## Audit 1 — Independent R2 per-spec audit

Read specs/SPEC-005-billing.md v0.2. This spec was drafted and
self-audited by Codex (R1 at specs/SPEC-005-r1-audit.md). You have
NOT read the R1 audit yet — read it only AFTER you complete your own
audit, to compare findings for the cross-round summary.

Audit methodology: follow specs/AUDIT_SPEC_006_PROMPT.md structure.
Produce findings at CRITICAL / MAJOR / MINOR / QUESTION severity.

Your audit focus areas (prioritise the M2.1 bug class — surfaces
implicit or unstated assumptions):

1. Does the reward formula handle the edge case where
   completion_tokens is null (failed request before provider responded)?
   SPEC-001 allows null usage fields on error paths.
2. Does the ledger-read path create a TOCTOU window if coordinator
   serves two concurrent requests to the same provider?
3. Are all SPEC-006 D3 matrix states (5+ states) explicitly handled
   in the reward formula section, or are some left implicit?
4. Does the SPEC-002 request_log join have a defined index strategy?
   coordinator SQLite + WAL mode — a full-table scan per settlement
   cycle would be a correctness risk at 10K providers.
5. Is the crash-recovery policy (D9) complete enough to verify? Can
   a test reproduce the crash-after-debit-before-forward state?
6. Does the boundary with SPEC-007 have a machine-readable interface
   definition (what the ledger emits vs what SPEC-007 consumes)?
7. Are there any implicit dependencies on gateway state (quota,
   account balance) that should be explicit coordinator-reads?

After completing your own audit, read specs/SPEC-005-r1-audit.md.
Note which findings you confirmed, which are new (R2-only), and
which you disagree with. Include a cross-round comparison section
in your audit output.

Output: specs/SPEC-005-r2-audit.md
Format: same as specs/SPEC-006-audit.md (two sections: R1 summary,
R2 findings, cross-round comparison, consolidated verdict).

## Audit 2 — Cross-spec coherence

Read SPEC-005 v0.2 alongside all locked specs:
  specs/SPEC-001-phase3-binary.md
  specs/SPEC-002-coordinator.md
  specs/SPEC-003-open-onboarding.md
  specs/SPEC-004-smart-router.md
  specs/SPEC-006-buyer-api.md
  specs/SPEC-008-tier2.md

Find gaps where SPEC-005 makes claims that conflict with, are
unanswered by, or require changes to existing specs. For each finding:
- Name which two specs conflict
- Describe the conflict precisely
- Propose the minimal patch (which spec to change, which section)

Focus cross-spec checks:
- SPEC-005 reward formula vs SPEC-006 D3 quota-settlement matrix:
  are the request-state categories in 1:1 correspondence?
- SPEC-005 storage contract vs SPEC-002 coordinator SQLite schema:
  any ALTER TABLE implied by SPEC-005 that SPEC-002 doesn't permit?
- SPEC-005 provider-earnings report vs SPEC-002 /poolz endpoint:
  does SPEC-002 need a new field or is it out-of-scope for SPEC-002?
- SPEC-005 attribution vs SPEC-004 FR-P11a: does SPEC-004's
  attribution header feed SPEC-005's multi-hop formula correctly?
- SPEC-005 circuit-broken-provider earning vs SPEC-002 FR-P11a
  circuit-breaker state: is the earning-zero rule consistent with
  how SPEC-002 defines the circuit-broken state?

Append cross-spec findings to specs/SPEC-005-r2-audit.md in a
clearly labelled section: "Cross-spec coherence findings."

## Produce the consolidated FIX prompt

Based on all R2 + cross-spec findings, produce:
  specs/FIX_SPEC_005_V0_3_PROMPT.md

Structure exactly like specs/FIX_SPEC_006_V0_2_PROMPT.md:
- Header: "FIX prompt — SPEC-005 v0.3 (Claude R2 + cross-spec pass)"
- Note: this prompt was produced by Claude R2 audit; do not execute
  until operator reviews it
- === BEGIN PROMPT === / === END PROMPT === markers
- Inside: every CRITICAL and MAJOR finding addressed, ordered by
  section number
- Budget line (estimated line count)
- Explicit guard: "Do NOT change § 2 locked decisions"
- Cross-spec patches identified: note which other spec files
  (SPEC-002, SPEC-004, etc.) the executing session may need to
  patch alongside SPEC-005, with the specific section to edit

STOP. Do not execute the FIX prompt.

Commit all output files:
  git add specs/SPEC-005-r2-audit.md specs/FIX_SPEC_005_V0_3_PROMPT.md
  git commit -m "audit(spec): SPEC-005 Claude R2 + cross-spec audit; FIX v0.3 prompt"

=== END PROMPT ===
```

**Expected output:** `specs/SPEC-005-r2-audit.md`, `specs/FIX_SPEC_005_V0_3_PROMPT.md`

---

## ★ GATE 3 — Operator reviews FIX_V0_3 prompt

Open `specs/FIX_SPEC_005_V0_3_PROMPT.md`. Check:

- [ ] Any D1–D12 pre-commitment being changed? (reject)
- [ ] Cross-spec patches: are the proposed sibling-spec edits minimal? (if a finding proposes large SPEC-002 changes, flag it — may need its own spec bump)
- [ ] Budget line: if >500 new lines, split into two FIX passes
- [ ] Any operator decision implied by a finding that wasn't in D1–D12? (lock it now before the session runs)

Edit directly if needed. Commit. Then proceed.

**Time:** 20–30 min. This is the highest-value gate — SPEC-005 touches all six existing specs; an unchecked contradiction here propagates.

---

## STEP 6 — Codex: FIX → v0.3 + regression + lock [CODEX /goal]

Open a **fresh Codex session** rooted at `/Users/augstar/macprovider-poc`. Run this `/goal`:

```
/goal

Working directory: /Users/augstar/macprovider-poc

## Phase A — Execute FIX

Read specs/FIX_SPEC_005_V0_3_PROMPT.md in full. Execute it.
Produce specs/SPEC-005-billing.md v0.3.
Also apply any cross-spec patches the FIX prompt specifies to sibling
spec files (SPEC-002, SPEC-004, etc.) — only the sections identified,
nothing more.

Update all version headers and append changelog entries.

Commit:
  git add specs/SPEC-005-billing.md [any patched sibling specs]
  git commit -m "fix(spec): SPEC-005 v0.3 — Claude R2 + cross-spec FIX pass"

## Phase B — Regression check

Run a single-pass regression audit on SPEC-005 v0.3 using the
finding format from specs/AUDIT_SPEC_006_PROMPT.md.

Focus only on: (1) did any FIX introduce a new contradiction with
the D1–D12 locked decisions? (2) did any cross-spec patch produce
a new gap with a spec not covered in the FIX prompt?

Verdict options:
  - CLEAN (0 CRITICAL, ≤3 MINOR) → proceed to Phase C
  - NEEDS ONE MORE PASS (any CRITICAL or >3 MAJOR) → produce
    FIX_SPEC_005_V0_4_PROMPT.md, stop, do not execute it

Output: append regression section to specs/SPEC-005-r2-audit.md.

## Phase C — Lock (only if CLEAN verdict)

If regression is CLEAN:

1. Produce specs/SPEC-005-audit.md as a final audit summary:
   - Four-section summary: R1 findings, R1 FIX, R2+cross-spec
     findings, regression check
   - Verdict: LOCKED at v0.3
   - Dependency line: lists all upstream spec versions this spec
     was audited against

2. Update specs/README.md:
   Add row: | SPEC-005 | Billing / settlement / rewards | v0.3 |
   Build-ready | [SPEC-005-billing.md](SPEC-005-billing.md) |

3. Append entry to beta/DECISION_CRITERIA.md:
   Follow the table format from existing entries. Include:
   - What was built (spec corpus additions)
   - Key lessons from the arc
   - What is now unlocked (SPEC-005 implementation gate open)

4. Commit everything:
   git add specs/SPEC-005-audit.md specs/README.md
   git add beta/DECISION_CRITERIA.md
   git commit -m "feat(spec): SPEC-005 v0.3 locked — billing/settlement/rewards build-ready"
```

**Expected output:** `specs/SPEC-005-billing.md` v0.3, regression section in r2-audit.md, `specs/SPEC-005-audit.md`, updated README, updated DECISION_CRITERIA.md

---

## Summary table

| Step | Model | What happens | You do |
|---|---|---|---|
| 1 | Claude | SCOPE analysis, design.md, operator-decisions.md | — |
| ★ GATE 1 | You | Fill 12 pre-commitments in operator-decisions.md | 30–60 min |
| 2 | Claude | Writes BUILD_SPEC_005_PROMPT.md | — |
| 3 | Codex /goal | BUILD v0.1 + R1 self-audit + FIX prompt draft | — |
| ★ GATE 2 | You | Scan FIX_SPEC_005_V0_2_PROMPT.md | 10–20 min |
| 4 | Codex /goal | Execute FIX → v0.2 | — |
| 5 | Claude | R2 audit + cross-spec coherence + FIX_V0_3 prompt | — |
| ★ GATE 3 | You | Review FIX_SPEC_005_V0_3_PROMPT.md | 20–30 min |
| 6 | Codex /goal | FIX → v0.3 + regression + lock | — |

**Your total active time: ~1–2 hours across three gates.**  
**Total session count: 6 sessions (3 Claude, 3 Codex).**  
**Old process equivalent: ~10–12 manual handoffs.**
