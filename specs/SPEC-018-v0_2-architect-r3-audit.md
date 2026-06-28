# SPEC-018 v0.2.2 — Architect Lane r3 Audit

**Date:** 2026-06-27
**Reviewer:** codex architect lane
**Verdict:** READY TO LOCK from architect lens

## Tally: C/H/M/m/Q

C=0 CRITICAL / H=0 HIGH / M=0 MEDIUM / m=0 minor / Q=0 questions

## Scope

This r3 audit reviewed only v0.2.2 additions and round-2 closure evidence:

- `specs/SPEC-018-agentic-tool-calling.md` v0.2.2
- `specs/SPEC-018-v0_2-architect-r2-audit.md`
- `specs/SPEC-018-v0_2-r2-audit.md`
- `specs/SPEC-018-v0_2-r2-absorption-prompt.md`
- `specs/SPEC-018-v0_2_2-DRAFT-NOTES.md`

Locked v0.1.5 content remains out of scope except where v0.2.2 notes explicitly preserve or reference the lock boundary.

## r2 architect finding closure status

### M-1: `prompt_echo_blocked` code-domain ambiguity

Status: CLOSED.

Evidence: v0.2.2 explicitly states in the buyer-visible delta summary that `prompt_echo_blocked` is internal plain-content fallback/log reason, not a buyer-visible HTTP/SSE error-envelope code (`specs/SPEC-018-agentic-tool-calling.md:9-14`). §3.9 now says prompt-echo guard firing produces no buyer-visible HTTP/SSE error envelope and only normal plain assistant content with no synthesized `tool_calls[]`; implementations may log internal code `prompt_echo_blocked` (`:299-305`). AC-49 matches that behavior and makes buyer-visible `prompt_echo_blocked` an explicit fail condition (`:612`). §10d.0 scopes its table to buyer-visible HTTP/SSE error-envelope codes and explicitly excludes internal plain-content fallback reasons (`:682-705`); the stable code table does not include `prompt_echo_blocked` (`:707-724`). §10d.1 maps the complete native echo case to plain-content fallback with no buyer-visible error and internal log code only (`:773`).

Architect assessment: the r2 wire-shape ambiguity is resolved. There is now one domain for `prompt_echo_blocked`: internal diagnostics for a successful plain-content fallback response.

### m-1: §10d subsection numbering explanatory note

Status: CLOSED.

Evidence: §10d now explains that non-sequential subsections mirror design-deliverable identifiers and gives the reader mapping for §10d.1, §10d.4, §10d.6, and §10d.7 (`specs/SPEC-018-agentic-tool-calling.md:672-680`).

### m-1 cosmetic: §3.8 document-order note

Status: CLOSED.

Evidence: §3.8 now includes an editorial note that the v0.2 additive §3.8 physically precedes locked §3.7 to avoid moving locked v0.1.5 content, and gives the logical reading order (`specs/SPEC-018-agentic-tool-calling.md:226-230`). Locked §3.7 remains distinct after §3.9 (`:307`).

## Fresh r3 architect sweep

### AC-50 through AC-55 numbering and dependency-chain integrity

PASS.

AC-50 through AC-55 are appended after AC-49 without renumbering prior acceptance criteria (`specs/SPEC-018-agentic-tool-calling.md:612-624`). Their deliverable labels are coherent with §10d: aggregate raw body, tool-result content, assistant-history arguments, message count, and assistant-history tool-call count are #1 multi-turn request-acceptance constraints; linear `tool_call_id` validation is #6 validation-performance coverage. §10d.1 repeats the same aggregate caps and validation-order requirements before prompt rendering (`:744-752`) and maps each failure to the same public code used by the ACs (`:758-771`). §10d.0 enumerates the new public error-envelope codes as non-retryable invalid-request errors (`:713-719`).

No dependency-cycle or release-gate contradiction found. The raw-body cap notes SPEC-006 deployments may be stricter while preserving the v0.2 maximum bound (`:746`), which is architecturally acceptable because stricter gateway admission happens before the SPEC-018 provider path rather than weakening the v0.2 cap.

### `prompt_echo_blocked` consistency across §3.9 / §10d.1 / §10d.0

PASS.

All three sections now agree:

- §3.9 defines exact-verbatim full-block guard behavior as normal plain assistant content with no synthesized `tool_calls[]` and no buyer-visible error envelope (`specs/SPEC-018-agentic-tool-calling.md:301-305`).
- AC-49 requires the same behavior and fails any buyer-visible `prompt_echo_blocked` error code (`:612`).
- §10d.0 excludes internal fallback reasons from the buyer-visible code table (`:703`) and omits `prompt_echo_blocked` from the table (`:707-724`).
- §10d.1 records the prompt-echo row as plain-content fallback with internal log code only (`:773`).

### `invalid_tools` inheritance note placement

PASS.

The inheritance note is placed immediately after the v0.2-specific public code table, where readers would otherwise expect `invalid_tools` to appear (`specs/SPEC-018-agentic-tool-calling.md:705-726`). §5 still says malformed assistant-history `tool_calls[]` request validation is governed by SPEC-001 / SPEC-002 and uses HTTP 400 `invalid_tools` (`:380`), and §10d.1 uses that same inherited code for malformed assistant `tool_calls[]` shape failures (`:765`). The placement preserves cross-SPEC ownership without leaving an unexplained missing-code gap.

### v0.2.2 absorption-note alignment

PASS.

The draft notes accurately describe the seven r2 absorptions: prompt-echo code-domain resolution, AC-50 through AC-55 additions, §10d numbering note, §3.8 doc-order note, and `invalid_tools` inheritance note (`specs/SPEC-018-v0_2_2-DRAFT-NOTES.md:10-16`). No mismatch found between the absorption notes and the SPEC body.

## Findings

No CRITICAL, HIGH, MEDIUM, minor, or open-question findings from the architect lens.

## Final lock-readiness assessment

READY TO LOCK from architect lens.

The r2 architect MEDIUM is closed, both r2 architect minors are closed, and the v0.2.2 additions do not introduce a new architect-level contradiction or dependency-chain gap. The SPEC can proceed to the Claude blind-spot pass from this lane.
