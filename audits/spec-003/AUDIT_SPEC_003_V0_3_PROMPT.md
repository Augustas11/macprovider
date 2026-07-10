# Audit prompt — SPEC-003 v0.3 round-2 narrower review

Operator-paste prompt for **round-2** audit of the SPEC-003 corpus
after the v0.3 fix pass landed (commit `74cf00b`).

This is a NARROWER audit than round 1. The full corpus is unchanged
in 90% of content; the round-2 auditor's job is to verify that:

  1. Every round-1 finding (4 CRITICAL + 7 MAJOR + 3 MINOR + 1 QUESTION)
     was actually closed by the fix pass.
  2. New content introduced by the fixes is internally consistent and
     does not introduce regressions.
  3. The backward-compat invariant still holds for M4/M1 binaries.

Run with **Codex CLI** for cross-model independence (same model as
round 1). Expected duration: **~30-45 min** (narrower than round 1's
60-75 min).

Paste everything between the markers into a fresh Codex CLI session
rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are performing the round-2 audit of the SPEC-003 redistribution
corpus. Your round-1 audit (specs/SPEC-003-audit.md, completed
2026-05-28T05:25:44Z) identified 4 CRITICAL + 7 MAJOR + 3 MINOR + 1
QUESTION. A fix pass (commit 74cf00b) addressed all of them. Your job
is to verify the fixes hold.

Spec versions to audit:
  SPEC-001 v1.2.1 commit 74cf00b
  SPEC-002 v1.1.1 commit 74cf00b
  SPEC-003 v0.3   commit 74cf00b

Round-1 audit report (source of findings):
  specs/SPEC-003-audit.md

Fix prompt that drove the v0.3 revision:
  specs/FIX_SPEC_003_V0_2_PROMPT.md

Your output: an updated report appended to
specs/SPEC-003-audit.md as a new section "## Round 2 (v0.3) audit
report" — do NOT overwrite the round-1 report; append after it. This
preserves the audit history.

If round 2 finds zero CRITICAL and ≤3 MAJOR findings, your verdict is
READY TO BUILD and the corpus moves to build prompts. If round 2 finds
new CRITICALs or >5 MAJORs, the verdict is NEEDS REVISION and a v0.4
fix pass is required.

## Critical constraints (unchanged from round 1)

**1. Backward-compat invariant is load-bearing.** v1.1.x binaries
(M4, M1) MUST remain MANDATORY-compliant. Verify the verbatim
backward-compat statement at SPEC-001 v1.2.1 lines 20-38 is intact
and unchanged (textually identical to the round-1 spec). Any
divergence is a CRITICAL finding.

**2. d-inference clean-room.** Do not inspect d-inference source.
Clean-room paragraphs verbatim from prior versions.

**3. Buyer API stability.** Zero observable change to
POST /v1/chat/completions, GET /v1/models, GET /healthz.

**4. No invented content beyond fix directions.** Every change in
v1.2.1 / v1.1.1 / v0.3 should trace to either a round-1 audit fix
direction, the operator's Q1 answer, or a mechanical version-bump.
Anything else = MAJOR (scope creep during fix).

## Required reading (in order, fully)

1. /Users/augstar/macprovider-poc/specs/SPEC-003-audit.md
   — your round-1 report. Skim to remember each finding.

2. /Users/augstar/macprovider-poc/specs/FIX_SPEC_003_V0_2_PROMPT.md
   — what the fix agent was instructed to produce. Specifically the
   "Findings to fix" section lists each C*/M*/m* and its prescribed
   fix direction.

3. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   v1.2.1 — read the change-log header + diff against v1.2 mentally.
   Focus on § 6.6 (Request ID lifecycle section added) and the OQ list.

4. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md v1.1.1
   — focus on:
     § 3 mode resolution (Q1 operator answer applied)
     § 5 routing pseudocode (model_id_equal, check_provisional_quota)
     § 7.1 wire schemas (C1 refresh) + nak fallback paragraph (M5)
     FR-P14.1 status mapping (C2)
     FR-P18.1 request_id lifecycle coord-side (C3)
     AC-15 (M5 acceptance)
     OQ-6/8/9/10 rationale restorations (M6)
     OQ-10 split scope (M3)

5. /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md v0.3
   — focus on:
     AC-1 + AC-1a (C4 fix)
     § 7.3 clean-room reference (M4 fix)
     OQ-mapping note (M3 split documentation)
     Length-target justification (m3 fix)

6. SPEC-003 v0.1 reference (for fidelity spot-checks):
     git show 0b4bbb7:specs/SPEC-003-open-onboarding.md > /tmp/spec003-v0.1.md
   Particularly v0.1 § 11 OQ rationales for M6 verification.

7. Round-1 spec versions (for diff context):
     git show d9dcb0d:specs/SPEC-001-phase3-binary.md > /tmp/spec001-v1.2.md
     git show d9dcb0d:specs/SPEC-002-coordinator.md > /tmp/spec002-v1.1.md
     git show d9dcb0d:specs/SPEC-003-open-onboarding.md > /tmp/spec003-v0.2.md
   Use these to confirm the fix pass made the intended changes and ONLY
   the intended changes.

You may browse the rest of the repo for context. Do NOT browse
d-inference repos.

## Audit categories — round 2 (narrower than round 1)

### Category N: New content verification (round 2's primary focus)

For each piece of NEW content introduced by the fix pass, verify it's
internally consistent + doesn't introduce regressions.

N.1  SPEC-002 § 7.1 refreshed hello/hello_ack schemas — do they match
     SPEC-001 v1.2.1 § 6.5 EXACTLY? Field by field. Including:
       - hello: type, version, tier, provider_id, hostname, model_id,
         model_params_b, ram_gb, max_context_tokens, max_concurrency,
         throughput_tps_estimate, binary_version, attestation,
         endpoint_url (new optional)
       - hello_ack: type, coordinator_version, assigned_id,
         heartbeat_interval_s, tier (new optional),
         recommended_binary_version (new optional)
     Any field mismatch = CRITICAL (wire compat hazard).

N.2  SPEC-002 FR-P14.1 status mapping table — is it internally
     consistent with the FR-27 status enum in SPEC-001 v1.2.1 § 6.6?
     Every status value in the SPEC-001 enum should appear in the
     SPEC-002 mapping table. Missing = MAJOR.

N.3  SPEC-001 § 6.6 "Request ID lifecycle and error handling" +
     SPEC-002 FR-P18.1 (coord-side rules) — are they consistent?
     Specifically:
       - Provider-side: duplicate_request_id nak. Coordinator-side:
         what happens when coord receives the nak? Should it close
         the failing request and proceed?
       - Provider-side cleanup on response_end. Coordinator-side
         cleanup on response_end or timeout. Same timeout source?
     Any divergence = MAJOR.

N.4  SPEC-002 § 5 routing pseudocode — model_id_equal and
     check_provisional_quota integration:
       - Does the modified pseudocode still produce the same result
         as v1.1 pseudocode for pinned providers with case-matching
         model IDs?
       - Does check_provisional_quota fire for both pinned (header
         path) and routed (candidate path)?
       - When all candidates are quota-blocked, does buyer get HTTP
         429 with Retry-After? Specified?

N.5  SPEC-002 § 7.1 nak fallback paragraph (M5 fix) — special-case
     behavior on nak unknown_message_type in response to § 6.6:
       - Marking http_forwarding_only for the WS session — is this
         per-session or persisted across reconnect?
       - HTTP 503 to buyer — should there be a retry against a
         different provider? Or fail terminally?
     Any ambiguity = MAJOR.

N.6  SPEC-002 AC-15 — testable? Does it reference a mock provider
     setup that exists (phase4-coordinator/tools/mockprovider) or
     a new one? Test mechanics described?

N.7  SPEC-003 AC-1 + AC-1a — is the boundary clean? An installer
     that passes AC-1a but not AC-1 should fail build-complete.
     Spec explicit on this?

N.8  Q1 operator answer applied in SPEC-002 § 3 — verify:
       - Hello with non-empty endpoint_url + provider_id NOT in
         config.providers[] → coordinator logs warn + ignores
         endpoint_url + routes as WS-tunneled provisional.
       - Pseudocode comment documents anti-Sybil rationale.
     Any deviation = MAJOR.

### Category F: Round-1 fix completeness

For each round-1 finding, verify the fix actually closed it.

F.1  Walk through C1, C2, C3, C4 verdict-by-verdict. CLOSED or
     PARTIAL or UNCLOSED.
F.2  Walk through M1-M7 same. Each must be CLOSED.
F.3  Walk through m1, m2, m3 same.
F.4  Q1 — applied correctly per operator decision?

For each finding marked PARTIAL or UNCLOSED, create a finding in
the round-2 report at the same severity.

### Category R: Regression detection

R.1  Did any fix accidentally weaken a previously-clean section?
     E.g., when C2 added FR-P14.1 status mapping, did the original
     FR-P14 lose any normative content?

R.2  Did any cross-reference break? E.g., M4 fixed SPEC-003 § 7.3
     reference to SPEC-001 § 7.2 — verify it resolves and isn't
     the wrong section.

R.3  Did any version-bump-only change accidentally edit content
     that wasn't supposed to change? (Look for content drift in
     sections not flagged by round 1.)

R.4  Did the backward-compat statement preserve EXACTLY verbatim?
     Check character-by-character (no editor-introduced whitespace,
     no auto-formatter changes).

### Category I: OQ disposition (post-fix)

I.1  How many OQs total across the three specs after the fix?
     Round 1 had 7 in v0.1, redistributed to 7-10 in round 1's
     v1.2/v1.1/v0.2, and M7 closed one. Total should be 6-9 now.
I.2  For each OQ, has its rationale paragraph been restored from
     v0.1 § 11? Spot-check 2-3 against /tmp/spec003-v0.1.md.
I.3  Is OQ-3 in SPEC-001 v1.2.1 explicitly closed (per M7)?
I.4  Is OQ-5 (SPEC-001) vs OQ-10 (SPEC-002) split explicit per M3?

## Severity rubric

  CRITICAL — wire compat break, backward-compat statement altered or
             broken, new content contradicts existing FR, round-1
             finding NOT actually closed despite fix claim.

  MAJOR    — ambiguity in new content, regression introduced by fix,
             cross-spec inconsistency in new content, fix done in
             spirit but not in letter.

  MINOR    — formatting, wording, cross-reference precision.

  QUESTION — auditor cannot determine from sources.

## Output format

APPEND to /Users/augstar/macprovider-poc/specs/SPEC-003-audit.md.
Do NOT overwrite the round-1 report.

Append this structure:

  ---

  # Round 2 (v0.3) Audit Report

  Auditor: <model name + version>
  Specs audited at commit 74cf00b:
    SPEC-001 v1.2.1
    SPEC-002 v1.1.1
    SPEC-003 v0.3
  Reference: round-1 report (above) + fix prompt (specs/FIX_SPEC_003_V0_2_PROMPT.md)
  Audit completed: <UTC timestamp>

  ## TL;DR verdict
  READY TO BUILD | NEEDS REVISION
  One paragraph: round-1 closure rate (X of 15 closed), new finding
  counts, top risk if any.

  ## Round-1 finding closure matrix

  | Round-1 ID | Description | Round-2 verdict |
  |---|---|---|
  | C1 | SPEC-002 § 7.1 stale schemas | CLOSED / PARTIAL / UNCLOSED |
  | C2 | FR-A8 mapping lost | ... |
  | (etc.) | | |

  ## New findings by severity

  ### CRITICAL (N)
  ### MAJOR (N)
  ### MINOR (N)
  ### QUESTIONS (N)

  Format per finding: title, severity, category (N/F/R/I), spec ref,
  quoted text, what's wrong, fix direction.

  ## Backward-compat verification

  - Verbatim statement intact? YES/NO with line numbers verified.
  - § 6.6 normative scope intact? YES/NO.
  - SPEC-002 § 3 mode resolution still dispatches M4/M1 to HTTP-
    forwarding? YES/NO.

  ## Suggested action

  If verdict READY TO BUILD: proceed to BUILD_SPEC_001_V1_2_1_PROMPT.md,
  BUILD_SPEC_002_V1_1_1_PROMPT.md, BUILD_SPEC_003_V0_3_PROMPT.md.

  If verdict NEEDS REVISION: identify the ≤3 must-fix items for v0.4
  and recommend a focused fix prompt.

## What NOT to do

  - Do NOT re-audit content already cleared in round 1 unless a fix
    touched it.
  - Do NOT modify the specs yourself.
  - Do NOT overwrite the round-1 report — append.
  - Do NOT browse d-inference repos.
  - Do NOT add new findings on topics outside the fix scope (i.e.,
    don't expand the audit scope beyond what changed).

When done, print a 150-word summary to stdout: verdict, closure rate
(X / 15), top risk (or "none"), recommendation (proceed to build /
do v0.4 fix). Then stop.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist:

1. Check the closure matrix — every round-1 finding should be CLOSED.
   PARTIAL or UNCLOSED items become round-2 findings.
2. Read new findings (typical for round 2: 0 CRITICALs, 0-3 MAJORs,
   a handful of MINORs).
3. Verify backward-compat verification section confirms YES on all
   three items.

Then decide:

- **READY TO BUILD + ≤3 MAJORs** → write the three build prompts
  (BUILD_SPEC_001_V1_2_1, BUILD_SPEC_002_V1_1_1, BUILD_SPEC_003_V0_3)
  and start implementation. SPEC-001/002 ran 3-4 rounds total; this
  is round 2 of SPEC-003, likely the last.

- **NEEDS REVISION** → draft `FIX_SPEC_003_V0_3_PROMPT.md` covering
  only the new findings. Likely a much smaller fix pass than round 1.

Expected: round 2 closes cleanly. The round-1 fixes were narrow + the
handback's backward-compat verification was unambiguous.
