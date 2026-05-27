# Final re-audit prompt — SPEC-002 v1.0.2

Last audit before binary + coordinator builds start. Focused diff-aware
verification: did the v1.0.2 patches actually resolve the joint audit's
findings, and did they introduce new cross-spec drift?

Run with **Codex CLI** (same auditor as the joint audit, for continuity).
Expected duration: ~20 minutes.

Paste everything between the markers into a fresh Codex CLI session
rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You previously conducted the joint SPEC-001 + SPEC-002 audit at
specs/JOINT-SPEC-001-002-audit.md, which returned REVISE SPEC-002 ONLY
with 6 MAJOR + 2 MINOR + 1 QUESTION findings. The operator has applied
in-place patches in SPEC-002 v1.0.2. Your job is a focused re-audit:
verify each prior finding is addressed and catch any regressions
introduced by the patches.

This is the LAST audit before builds begin. Be thorough on regressions;
they're the only remaining risk.

## Required reading (in order)

1. /Users/augstar/macprovider-poc/specs/JOINT-SPEC-001-002-audit.md
   — your prior joint audit. Memorize the findings:
     MAJOR: M-J1 (preflight.purpose), M-J2 (C→P nak), M-J3 (header table),
            M-J4 (HTTP 530 OQ-1), M-J5 (YAML schema), M-J6 (retry_on_502)
     MINOR: m-J1 (header namespace), m-J2 (AC-8b degraded routing)
     QUESTION: Q-J1 (HTTP 530 normative answer)

2. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md
   v1.0.2 — the spec under audit. Verify the version metadata says
   "v1.0.2 (2026-05-27, post-joint-audit patches)".

3. /Users/augstar/macprovider-poc/phase4-coordinator/implementation-notes.html
   — top "v1.0.2 patches" section records what the patch round claims
   to have done. Use as a CROSS-CHECK: every claim there should be
   reflected in the spec body. Claims without spec evidence are
   findings ("claimed but not visible").

4. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   v1.1.1 — UNCHANGED. The binary spec is locked. Reference only to
   verify SPEC-002 v1.0.2 doesn't break the wire compatibility you
   already validated in the joint audit.

You do NOT need to re-read HANDOFF.md, the decision log, or the harness
unless a specific check forces it. This is a targeted patch verification,
not a fresh audit.

## Audit structure — two parts only

### Part 1 — Per-finding patch verification

For each of the 9 prior joint-audit findings (M-J1..M-J6, m-J1, m-J2,
Q-J1), produce a one-line verdict with section reference.

Format:

| Finding | Severity | Status | SPEC-002 v1.0.2 § ref | One-line justification |
|---|---|---|---|---|
| M-J1 | MAJOR | ADDRESSED | FR-P11 recovery preflight | `purpose` field removed; subset of SPEC-001 § 6.5 |
| ... | | | | |

Use ADDRESSED / PARTIAL / NOT ADDRESSED / RESOLVED in uppercase for
grep-ability.

For each ADDRESSED: confirm a concrete spec change is visible (not
just a claim in implementation-notes.html).

For each PARTIAL or NOT ADDRESSED: this is a finding. Cite what's
missing.

### Part 2 — Regression check

The 8 patches modified specific sections. Walk each modified section
and look for new problems introduced by the patch itself.

#### 2.1 Recovery preflight (FR-P11) — patch removed `purpose`
- Verify the new recovery preflight body is exactly:
  `{type, request_id, estimated_tokens}` — no extra fields.
- Verify SPEC-002's text doesn't still say "purpose field is additive
  metadata" or similar contradictory text.
- Verify the `recovery-probe-` request_id prefix is documented as the
  sole discriminator.

#### 2.2 WebSocket close codes (FR-P13) — patch replaced C→P `nak`
- Verify all coordinator-initiated rejections use close codes, not nak.
- Verify the close-code table is complete (4001–4005 + 4429) and that
  the reason text format is specified.
- Verify § 7.1 "nak (P->C only)" text is consistent — no remaining
  references to coordinator sending nak.
- Spot-check: search the spec for the string "sends a nak" or "send nak"
  in coordinator-acting contexts. There should be none.

#### 2.3 Header tables (§ 7.2) — patch normalized headers
- Verify request-header table contains: X-MacProvider-Pref,
  X-MacProvider-Provider (stable provider_id), X-MacProvider-Session
  (session assigned_id).
- Verify response-header table contains: X-MacProvider-Provider,
  X-MacProvider-Route.
- Verify FR-R3 routing pseudocode handles X-MacProvider-Session with
  precedence over X-MacProvider-Provider.
- Spot-check: search for "assigned_id" near "X-MacProvider-Provider"
  — should not co-occur (only X-MacProvider-Session uses assigned_id).

#### 2.4 HTTP 530 normative (FR-P11) — patch promoted OQ-1
- Verify FR-P11's failure-mode table includes an HTTP 530 row with
  action "unavailable immediately + WebSocket liveness probe."
- Verify § 12 has zero open questions (`grep -c "^\*\*OQ-[0-9]"` = 0).
- Verify the explanatory paragraph about literal HTTP 530 is normative,
  not hedged with "should the operator decide" wording.

#### 2.5 YAML schema (§ 13) — patch added providers map
- Verify the YAML schema includes a `providers:` block with
  provider_id, endpoint_url, display_name? fields.
- Verify the 5 startup validation rules are listed (non-empty,
  unique IDs, HTTPS URLs, ID regex, operator_key required).
- Verify the example YAML actually populates `providers:` with at
  least one example entry.
- Spot-check: search for "static config" or "static map" elsewhere
  in the spec — should now point to § 13 for the schema.

#### 2.6 Config rename (§ 13) — patch renamed retry_on_502
- Verify `routing.retry_on_502` is gone from the config schema.
- Verify `pool.degraded_probe_after_502` is present.
- Spot-check: search for "retry_on_502" — should only appear in
  explanatory note documenting the rename, not as an active config key.

#### 2.7 AC-8b — patch rewrote degraded routing assertion
- Verify AC-8b step 6 (or equivalent) asserts NO routing to a degraded
  provider, returning 503 if no other ready provider exists.
- Spot-check: search for "ONLY if no other ready" — should not appear.

#### 2.8 AC-10 — patch aligned with two-phase blacklist
- Verify AC-10 has steps for both phases: immediate `draining`
  transition + deferred WebSocket close + entry removal.
- Verify 404 case for unknown provider_id is asserted.
- Verify the response shape `{status, provider_id, assigned_id,
  drain_sent}` matches § 7.4.

## Severity rubric

  CRITICAL — a v1.0.2 patch introduced a regression that breaks build
             or wire compat. Or a prior finding is genuinely NOT
             ADDRESSED.

  MAJOR    — patch is incomplete; spec still has the prior contradiction
             in a less prominent location. Or a new internal
             inconsistency between sections.

  MINOR    — formatting, wording drift, trivially fixable in-place.

  QUESTION — auditor cannot determine from spec content alone.

Expected: 0 CRITICAL, 0–2 MAJOR, 0–5 MINOR. If you find more, the patch
round did not converge and a v1.0.3 may be needed.

## Output format

Write to:
  /Users/augstar/macprovider-poc/specs/SPEC-002-v1-0-2-audit.md

Structure:

  # SPEC-002 v1.0.2 Final Re-audit Report
  Auditor: <model + version>
  Spec audited: SPEC-002 v1.0.2 (commit c024f8c or current HEAD)
  Audit completed: <UTC timestamp>
  Prior audit: JOINT-SPEC-001-002-audit.md

  ## TL;DR verdict
  One of:
    READY TO BUILD BOTH — all 9 prior findings addressed, no regressions.
                          Builds may start.
    PATCH AGAIN — N findings remain or regressions detected. List ≤5
                  items for a v1.0.3 in-place patch round.
    REVISE — substantive issues; a fix prompt cycle is needed.

  One paragraph with finding counts and confidence statement.

  ## Part 1 — Per-finding verification table

  (9 rows, one per joint-audit finding.)

  ## Part 2 — Regression findings

  ### CRITICAL (N)
  ### MAJOR (N)
  ### MINOR (N)

  Per-finding format:
    - Title
    - Severity
    - Subsection (2.1 through 2.8)
    - Section ref in SPEC-002 v1.0.2
    - Quoted text showing the regression
    - Fix direction

  ## What this patch round did well

  3-5 specific patches that landed cleanly. (Anti-bias calibration.)

  ## Final verdict recommendation

  Concrete next step:
    - READY → "Commit no further; SPEC-002 v1.0.2 is build-ready."
    - PATCH AGAIN → list patches, recommend in-place.
    - REVISE → list issues, recommend fix prompt.

## Hard rules

1. Do NOT re-explore the joint-audit categories (2.1-2.10). Only verify
   the 8 patched sections and the 9 prior findings.
2. Do NOT re-audit SPEC-001. It's unchanged and locked.
3. Cite section numbers and quote text for every regression finding.
4. If a Part 1 row would say ADDRESSED but the spec evidence is weak,
   downgrade to PARTIAL with explanation. Better to flag than rubber-stamp.
5. You MAY check that markdown table syntax parses (find malformed
   tables introduced by the patches).

## Anti-rules

- Don't audit JOINT_AUDIT_PROMPT.md or AUDIT_SPEC_002_V1_0_2_PROMPT.md
  themselves.
- Don't speculate about SPEC-003+ work.
- Don't ask the operator questions during the audit; this audit shouldn't
  produce QUESTIONS unless you really cannot determine something.
- Don't propose alternative designs. v1.0.2 design choices are locked
  by operator confirmation in the prior round.

## When you finish

1. Re-read the audit. Anything marginal should move to MINOR.
2. Print to stdout:
   - TL;DR verdict (one of 3)
   - Per-severity counts
   - "Builds may start: YES / NO / NOT YET"

If the verdict is READY TO BUILD BOTH, the operator will commit no spec
changes and proceed directly to building. This is the meaningful
gate — be honest.

Begin by reading the required files in order.

=== END PROMPT ===
```

---

## How to use

```bash
cd /Users/augstar/macprovider-poc
codex < specs/AUDIT_SPEC_002_V1_0_2_PROMPT.md
```

Expected wall time: ~20 minutes.

## What you'll get back

- `specs/SPEC-002-v1-0-2-audit.md` — focused re-audit report
- A `<200 word` summary in Codex's final reply with the 3-state verdict

## Expected outcomes

| Outcome | Action |
|---|---|
| **READY TO BUILD BOTH** | Commit no further; draft build prompts and start parallel binary + coordinator builds |
| **PATCH AGAIN** | ≤5 items, apply in-place to v1.0.3 (~15 min), then optionally re-re-audit |
| **REVISE** | Unlikely; would mean v1.0.2 introduced new issues bigger than it solved. Draft FIX_SPEC_002_V1_0_3_PROMPT.md if it surfaces. |

**Most likely outcome: READY TO BUILD BOTH.** The patches are mechanical and the joint audit's findings were narrowly scoped. A fourth audit round catching new substantive issues would be surprising.

## Why this audit is shorter than the others

Previous audits were exploratory. This one is verification of 8 specific patches against 9 specific findings. No new categories, no fresh exploration. The 20-min budget reflects that scope.

## After this audit

If READY → I draft the two build prompts (`BUILD_PHASE3_BINARY_PROMPT.md`, `BUILD_PHASE4_COORDINATOR_PROMPT.md`), you commit the audit report, and parallel builds start tomorrow morning.
