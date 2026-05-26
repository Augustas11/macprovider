# Audit prompt — SPEC-001 second-opinion review

This is the operator-paste prompt to get an independent audit of
`specs/SPEC-001-phase3-binary.md` after it's been written by a different
session. Intended to be run with **Codex CLI** (or any model different from
the one that wrote SPEC-001) to get a fresh-eyes second opinion before the
binary build session consumes it.

Paste everything between the `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
lines into a fresh Codex CLI session rooted at `/Users/augstar/macprovider-poc`.
Expected duration: ~45 minutes of focused autonomous audit.

The auditor's job is to **find problems**, not validate. Be skeptical.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-001 for a project you've never seen before.

Your job: read SPEC-001 and its source materials, then produce a structured
audit report that surfaces every problem a future implementer might hit.
You are NOT here to validate the spec. You are NOT here to rewrite or
improve it. You are here to find what's wrong, ambiguous, missing,
over-specified, or internally inconsistent.

The author of SPEC-001 was a different AI model. The operator wants your
independent assessment before committing this spec to a 3-5 week binary
build.

## Required reading (in this order, fully)

1. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   — the spec under audit; this is the primary artifact

2. /Users/augstar/macprovider-poc/HANDOFF.md
   — project context: what Mac Provider is, why Phase 3 exists,
   what Tier 1 vs Tier 2 means

3. /Users/augstar/macprovider-poc/results/REPORT.md
   — Phase 1 evidence; every quirk and finding the binary must handle

4. /Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md
   — read the **decision log** in particular; every row should map
   to one or more requirements in SPEC-001. If it doesn't, that's a finding.

5. /Users/augstar/macprovider-poc/beta/PHASE2_UPGRADED_PLAN.md
   — what Phase 2 was meant to find and why

6. /Users/augstar/macprovider-poc/beta/workloads_adversarial.py
   — the failure modes the binary must survive. The acceptance criteria
   in SPEC-001 § 9 should reference these directly.

7. /Users/augstar/macprovider-poc/specs/BUILD_SPEC_001_PROMPT.md
   — what the spec author was instructed to produce. Use this to check
   whether SPEC-001 actually delivered what was asked. Section 11 of
   that prompt lists output requirements; verify every one is present.

You may consult https://github.com/layr-labs/d-inference to understand
what reference material the spec author had access to. Same hygiene rules
apply: non-privacy modules only, no copying.

## Audit categories — work through each, in order

For each category below, walk through the spec and list every concrete
issue you find. Cite the spec by section number (§ N) and quote the exact
problematic text. Issues with no quote and no section number don't count.

### Category A: Completeness against source materials

A.1  Does every entry in beta/DECISION_CRITERIA.md's "Decision log"
     table map to at least one numbered requirement (FR-N) in SPEC-001 § 4?
     Walk the decision log row-by-row; mark each as covered or uncovered.

A.2  Does the spec address every "Phase 3 binary or coordinator must..."
     bullet in results/REPORT.md § "SSE quirks to handle in Phase 3 binary"?
     There should be at least 5 such items mapped.

A.3  Does the spec address every adversarial workload in
     workloads_adversarial.py as something the binary must survive?
     Specifically: retry_storm, long_context_oom_probe, concurrent_burst_8way,
     midstream_disconnect, malformed_tool_call.

A.4  Is the BUILD_SPEC_001_PROMPT.md output checklist (sections 0-11) all
     present in the actual SPEC-001? Missing sections are critical findings.

### Category B: Internal consistency

B.1  Do any FRs contradict each other? (e.g. one says "stream usage chunk
     before [DONE]" and another says "[DONE] terminates the stream
     immediately")

B.2  Does the "in scope" list (§ 2) match what § 4 functional requirements
     actually cover? Anything in scope not requirement'd is a gap;
     anything required but out of scope is a contradiction.

B.3  Do the acceptance criteria (§ 9) actually test the requirements?
     Each acceptance criterion should map to one or more FRs. Untested
     FRs are a finding.

B.4  Are the interface contracts (§ 6) consistent with the FRs that
     reference them? (e.g. if FR-7 says "synthesize usage chunk", does
     § 6's /v1/chat/completions streaming schema show that chunk?)

### Category C: Tier 1 / Tier 2 architecture

C.1  Does § 3 (Architecture overview) explicitly name the Tier 2 hook
     points, or does it gesture at "extensibility" without specifics?
     Vague extensibility = finding.

C.2  Is anything in the Tier 1 launch scope actually Tier 2 territory?
     (e.g. an attestation handshake snuck in)

C.3  Is anything required for Tier 2 readiness missing? Specifically:
     a middleware/handler chain into which a trust layer can be inserted,
     a `tier` field in the coordinator protocol, a trust-model abstraction
     in the request validation path.

C.4  Does the spec speculate about Tier 2 implementation details beyond
     hook-point names? It shouldn't — Tier 2 gets its own SPEC.

### Category D: Reference hygiene

D.1  Does the spec record the d-inference repo's actual license SPDX id?
     If not, that's a critical finding (could be GPL — would change rules).

D.2  Does the spec list d-inference paths the author consulted (per
     BUILD_SPEC_001_PROMPT.md "References used during spec writing"
     appendix requirement)? Missing appendix = finding.

D.3  Are there code samples in the spec that look like they could be
     verbatim from d-inference? The spec should be requirements-only,
     not implementation. Code blocks beyond JSON schemas and ASCII
     diagrams are a finding.

D.4  Is the "informed by, not copied" principle stated explicitly? Is
     attribution (THIRD_PARTY_NOTICES.md mention) planned?

### Category E: Interface contracts

E.1  Are the JSON schemas for /v1/chat/completions complete enough to
     build a client and server against — both stream=false and stream=true?
     Specifically: every required field named, every type given, every
     enum value listed.

E.2  Is the coordinator WebSocket protocol specified at message-shape
     level (envelope structure, field names, types) or only at intent
     level ("send capacity heartbeat")? Intent-only = finding.

E.3  Are error responses specified? (HTTP 4xx and 5xx bodies — OpenAI's
     `{"error": {"message": ..., "type": ..., "code": ...}}` shape)

E.4  Are SSE event types named (data: chunks of what)? Does the spec
     account for the keepalive-comment exclusion (Phase 1 quirk)?

### Category F: Acceptance criteria

F.1  Are acceptance criteria measurable? "Performance acceptable" is not
     measurable. "≥90% of mlx_lm.server tps baseline" is.

F.2  Is there a test command, script reference, or harness invocation
     for each criterion? Untestable criteria are a finding.

F.3  Does the spec specify the 24h soak test's metrics (memory growth %,
     crash count) and the hardware tier it runs on?

F.4  How does the spec define "passes acceptance" overall — all criteria
     must pass, or majority, or scored? Ambiguity = finding.

### Category G: Open questions

G.1  How many open questions does § 10 list? <3 is suspicious (author
     didn't think hard enough); >15 is suspicious (spec is too vague).
     Sweet spot: 5-10.

G.2  Are the open questions actually blocking, or could they be defaults?
     "Should logging be stdout or syslog?" is a default choice; flag
     these as "shouldn't be open questions, pick a default."

G.3  Are there open questions you can answer yourself from the source
     materials? If yes, the author failed to do the homework. Note these.

### Category H: Implementability

H.1  Could a competent Swift developer (or a fresh Claude/Codex session)
     build a working binary from this spec alone, without asking the
     operator for clarification? If they'd need to ask more than 3
     things, the spec isn't ready.

H.2  Is the Section 11 "Hand-off to implementer" sequence concrete enough
     to start coding from? "Implement /v1/models first" is concrete;
     "Wire up the API endpoints" is not.

H.3  Are dependencies pinned to specific versions where it matters?
     ("Swift 5.9+" is fine for a language version; "mlx-swift-lm" without
     a commit or release tag is a finding — could be a breaking version
     by build time).

### Category I: Scope discipline

I.1  Does anything in the spec belong in a different SPEC?
     - Reward distribution → SPEC-005
     - Coordinator implementation → SPEC-002
     - Public API auth → SPEC-006
     - Privacy/attestation → future Tier 2 spec
     If any of these surface in SPEC-001, that's scope creep.

I.2  Does the spec accidentally constrain SPEC-002 (coordinator)?
     SPEC-001 specifies the binary's COORDINATOR CLIENT and the protocol
     it speaks, but should not specify the coordinator's internal
     architecture. Constraint past the wire protocol = finding.

I.3  Is anything in scope that should be deferred to v1.1 of the binary?
     Initial scope should be minimum-viable-Tier-1, not maximum-Tier-1.

## Severity rubric

Categorize every finding:

  CRITICAL — would cause the build to fail or produce a non-functional
             binary. Examples: missing requirement that prevents core
             use case, internally contradictory FRs, undefined interface
             contracts that the implementer would have to guess at.

  MAJOR    — would cause the build to deliver something different from
             what the operator wanted. Examples: ambiguous requirement
             with multiple valid interpretations, Tier 2 hook missing
             that would force re-architecture later, missing acceptance
             criterion for a stated capability.

  MINOR    — would cause friction during the build but not failure.
             Examples: missing default, suboptimal phrasing, redundant
             section, version pin missing on a non-critical dependency.

  QUESTION — something the auditor cannot determine from source materials
             and wants the operator to confirm. Different from "open
             question in the spec" — this is the AUDITOR's question
             after reading.

## Output format

Write your audit to:

  /Users/augstar/macprovider-poc/specs/SPEC-001-audit.md

Structure:

  # SPEC-001 Audit Report
  Auditor: <your model name + version>
  Spec audited: SPEC-001 commit <hash>
  Audit completed: <UTC timestamp>

  ## TL;DR verdict
  One of: READY TO BUILD | NEEDS REVISION | RESTART
  One paragraph justification.

  ## Findings by severity

  ### CRITICAL (N findings)
  For each: title, severity, category (A-I), section reference (§ N),
  quoted spec text, what's wrong, what would need to change to fix.

  ### MAJOR (N findings)
  Same format.

  ### MINOR (N findings)
  Same format, briefer.

  ### QUESTIONS (N items)
  Things the auditor wasn't sure about — for operator to confirm.

  ## Coverage matrix
  Table showing:
    - Each Phase 1+2 finding (decision log entry, REPORT.md quirk)
    - Which SPEC-001 FR(s) cover it
    - Auditor's assessment: covered / partial / uncovered

  ## What the spec does well
  (Short section. The audit is critical, but a one-sided audit is biased.
  Surface 3-5 things the spec gets right so the operator can preserve
  them in revision.)

  ## Final verdict recommendation
  Concrete next step for operator:
    - "Apply N critical fixes, then proceed to build"
    - "Revise the entire X section before proceeding"
    - "Restart spec writing with these clarifications: ..."

## Hard rules for the auditor

1. Do NOT rewrite SPEC-001. Do NOT propose alternative text. Identify
   problems; the operator decides fixes.
2. Do NOT defend the spec author. If something is unclear, it's a
   finding regardless of intent.
3. Cite section numbers and quote text. Vague findings ("section 4 is
   confusing") get demoted to QUESTIONS or dropped.
4. Don't audit BUILD_SPEC_001_PROMPT.md itself unless it's relevant to
   checking whether SPEC-001 met its requirements.
5. You may inspect d-inference (https://github.com/layr-labs/d-inference)
   if needed to verify spec claims, with the same hygiene rules: no
   privacy/attestation modules, no copying.
6. If you can't determine something from source materials, put it in
   QUESTIONS — don't make it CRITICAL by default.

## Anti-rules

• Don't audit the project strategy. Phase 3 vs Phase 4 ordering, Tier 1
  vs Tier 2 priority, etc. — already decided. The spec implements the
  decisions; you audit the implementation of that.
• Don't audit prose quality. Markdown formatting, sentence variety,
  paragraph length — none of that. Focus on technical content.
• Don't ask the operator questions during the audit. Put them in the
  QUESTIONS section.
• Don't audit BUILD_SPEC_001_PROMPT.md. Audit SPEC-001 only.

## When you finish

1. Re-read your audit. Anything you'd back off from? Critical findings
   you're less sure of? Move them to MAJOR or QUESTIONS.
2. Verify every finding has: title, severity, category, section ref,
   quoted text, what's wrong, fix direction.
3. Print a < 200 word summary to stdout: TL;DR verdict + top 3 findings
   the operator should focus on first.

Begin by reading the required files in order. Take notes as you read.

=== END PROMPT ===
```

---

## How to use

```bash
cd /Users/augstar/macprovider-poc

# After SPEC-001 has been written by Claude, audit with Codex:
codex < specs/AUDIT_SPEC_001_PROMPT.md

# Or paste interactively
codex
# > [paste between BEGIN PROMPT and END PROMPT]
```

## What you'll get back

- `specs/SPEC-001-audit.md` — structured audit report
- A <200 word summary in Codex's final reply

## What to do with the audit

1. **Read the TL;DR verdict** — READY TO BUILD / NEEDS REVISION / RESTART
2. **Resolve every CRITICAL finding** — these are build-blocking
3. **Triage MAJORS** — decide which to fix vs accept as risk
4. **Skim MINORS** — fix only if cheap; document the others
5. **Answer QUESTIONS** — operator-only; the auditor couldn't determine these
6. **Commit a SPEC-001 v1.1** with the agreed fixes
7. **Re-audit (optional, ~20min)** if v1.1 has substantial changes

## Why Codex specifically

Different model family from Claude = different priors, different blind spots. If both miss the same problem, that's a stronger signal it's not actually a problem. If Codex flags something Claude wrote, that's high-value catch.

## Why not Claude auditing Claude's own output

Same model auditing its own output catches surface-level issues but tends to ratify the underlying assumptions. Cross-model audit is the project-management gold standard for high-stakes spec docs.

## Time budget

Spec writing: ~2h (Claude)
Audit: ~45min (Codex)
Operator review of audit: ~30min
SPEC-001 v1.1 edits: ~1h
Total: half a day, end-to-end, to get a hardened spec.
