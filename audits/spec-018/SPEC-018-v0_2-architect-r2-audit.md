# SPEC-018 v0.2.1 — Architect Lane r2 Audit

**Date:** 2026-06-27
**Reviewer:** codex architect lane
**Verdict:** FIX REQUIRED

## Tally: C/H/M/m/Q

C=0 CRITICAL / H=0 HIGH / M=1 MEDIUM / m=1 minor / Q=0 questions

## Prior r1 finding closure status

### H-1: §10a/§10c contradictions with v0.2 narrowing

Status: CLOSED.

Evidence: v0.2.1 explicitly records Path B in the change log, naming the §10c model-hash registry amendment, rationale, precedent, and replacement mitigations (`specs/SPEC-018-agentic-tool-calling.md:18`). §10c now carries the explicit `AMENDED v0.2.0/v0.2.1` paragraph deferring unknown-`model_hash` registry enforcement to v0.3 and naming the v0.2 mitigations (`:641-643`). §10d now states that the narrow v0.2.0 scope is #1/#4/#6/#7 and that §10d supersedes §10a's earlier seven-item target list for v0.2.0 scope determination (`:649-653`).

Architect assessment: the contradiction that made #2/#3/#5 both required and deferred is resolved for v0.2.1. §10a remains historical locked text, but §10d and §10c now define the active version boundary clearly enough.

### H-2: AC-14 v0.2 acceptance contradiction

Status: CLOSED.

Evidence: AC-14 itself now says that for v0.2.0+ it is superseded by AC-26 and AC-27 and that the v0.1.x error path is no longer desired (`specs/SPEC-018-agentic-tool-calling.md:521`). A second applicability note before the v0.2 AC block repeats the same version boundary (`:547`). §10d.1 also explains the AC-14 transition as an additive request-shape expansion (`:741`).

### H-3: missing `tool_call_id` two-code mismatch

Status: CLOSED.

Evidence: the §10d.1 request-side failure table now maps missing `role:"tool"` `tool_call_id` to HTTP 400 `invalid_tool_call_id` (`specs/SPEC-018-agentic-tool-calling.md:721-728`). AC-32 uses the same four-code failure set, including `invalid_tool_call_id` for missing/malformed IDs (`:567`). §10d.6 defines `invalid_tool_call_id` as "ID missing or format invalid" (`:853-855`).

### M-1: duplicate §3.7 headings

Status: CLOSED.

Evidence: the v0.2 additive tool prompt-template section is now `### 3.8` (`specs/SPEC-018-agentic-tool-calling.md:219`), and locked `### 3.7 Adding a new family` remains distinct (`:296`). The renumbering is explicitly called out as a v0.2.1 lock amendment (`:221`), and v0.2 references now point to §3.8 (`:288`, `:555-557`, `:705`, `:734`).

No stale v0.2-sense `§3.7` reference was found in the r2 sweep. The surviving `§3.7` reference at `:210` correctly targets "Adding a new family."

### M-2: §4/AC-8 buffered-streaming applicability

Status: CLOSED.

Evidence: §4 now states that it describes v0.1.x buffered-to-end behavior, and that for v0.2.0+ §10d.4 plus AC-40 through AC-45 are authoritative for tool-call streaming (`specs/SPEC-018-agentic-tool-calling.md:306-308`). AC-8 and AC-9 carry the same applicability boundary (`:509-511`).

### M-3: AC-23s alias

Status: CLOSED.

Evidence: §10d.4 now defines the alias explicitly: design notes call it `AC-23s`, while the SPEC body encodes the streaming forward-compat regression as AC-43 (`specs/SPEC-018-agentic-tool-calling.md:777`). AC-43 remains the actual acceptance criterion and scopes its no-parse-error obligation to successful streams (`:589`).

### m-1: §10d subsection numbering

Status: NOT CLOSED (minor).

Evidence: §10d still jumps by deliverable number and now includes pre-deliverable subsections `10d.0` and `10d.0.1` before `10d.1`, `10d.4`, `10d.6`, `10d.7`, and `10d.8` (`specs/SPEC-018-agentic-tool-calling.md:657`, `:695`, `:699`, `:743`, `:779`, `:868`, `:890`). The heading text makes the deliverable mapping understandable, but the requested explanatory note that subsection numbers intentionally mirror deliverable IDs is still absent.

Impact: minor only. This is structurally surprising, not a normative contradiction.

### Q-1: model-hash registry disposition

Status: CLOSED.

Evidence: §10c explicitly amends the locked v0.2 registry requirement to defer registry enforcement to v0.3 (`specs/SPEC-018-agentic-tool-calling.md:641-643`). §10d's reader note repeats that deliverable #2 is deferred (`:653`). v0.2.1 adds only passive `usage.macprovider_model_hash_observed` observation, with AC-46 stating it is observation-only and must not drive v0.2 parser selection or settlement (`:595`), and §10d.0.1 repeats that it is non-canonicalized and observation-only (`:695-697`).

## Fresh r2 architect findings

### MEDIUM findings

M-1: `prompt_echo_blocked` is both an error-envelope code and a plain-content fallback/internal reason

Location: `specs/SPEC-018-agentic-tool-calling.md:290-294`, `:678-693`, `:721-735`, `:601`.

Concern: §3.9 defines the minimal prompt-echo guard as parser-side synthesis failing closed to plain assistant content. AC-49 also expects no `tool_calls[]` and plain-content fallback. §10d.1's failure table agrees, saying a complete echoed native tool-call block produces "Plain-content fallback; internal code `prompt_echo_blocked`." But §10d.0 lists `prompt_echo_blocked` in the "Stable v0.2 error codes" table under the v0.2 error-envelope section, whose scope is "HTTP and terminal SSE errors." That creates a wire-shape ambiguity: one reader can implement prompt echo as an HTTP/SSE error envelope, while another can implement it as internal telemetry attached to a successful plain-content response.

Recommended fix: remove `prompt_echo_blocked` from the public v0.2 error-envelope code table, or split §10d.0 into public error codes vs internal fallback reasons and state explicitly that `prompt_echo_blocked` is not buyer-visible in v0.2 except through the absence of synthesized `tool_calls[]` and normal plain assistant content.

### Minor findings

m-1: §3.8 now appears before §3.7 in document order

Location: `specs/SPEC-018-agentic-tool-calling.md:219`, `:296`.

Concern: the duplicate heading is fixed, and cross-references are clean, but the additive §3.8 section physically precedes locked §3.7. That is acceptable under the lock-amendment narrative, yet it remains mildly awkward for readers and generated TOCs.

Recommended fix: none required for lock. If a later editorial unlock touches §3, either move locked §3.7 before additive §3.8 without changing text, or add a one-line note that §3.8 is intentionally inserted before the locked §3.7 body to avoid moving locked content.

## Fresh sweep notes

- §10c amendment narrative coherence: PASS. The amendment is named in the change log with rationale and precedent (`specs/SPEC-018-agentic-tool-calling.md:18`) and repeated in §10c (`:643`).
- §3.7 → §3.8 renumber cleanliness: PASS for cross-references. No stale v0.2-sense `§3.7` reference was found; the remaining §3.7 reference targets the locked "Adding a new family" section (`:210`, `:296`).
- AC-46 through AC-49 numbering/dependency chain: PASS. AC-46 ties to the §10c registry disposition (`:595`), AC-47/AC-48 tie to final-close/no-dispatch safety (`:597-599`), and AC-49 ties to §3.9 (`:601`).
- New error envelope wire-shape consistency: FAIL, see fresh M-1.
- Kill-switch header integration: PASS. §10d.4 defines `X-MacProvider-Streaming-Mode` as non-negotiating observation (`:745-747`), and AC-45 requires every v0.2 response to include one of the three values with state/log correlation (`:593`).

## Path B precedent audit

PASS.

v0.2.1 narrates the precedent honestly. The change log states that the §10c locked registry invariant is amended, not silently ignored; gives the strategic rationale; states that a binary-baked stub registry lacks real security value without curation governance; and names the precedent that locked invariants are not immutable but require explicit named amendment with rationale (`specs/SPEC-018-agentic-tool-calling.md:18`). The body repeats the actual amendment in §10c (`:643`). This satisfies the Path B requirement.

## Verdict justification

FIX REQUIRED from the architect lane because the fresh v0.2.1 error-envelope text introduces one MEDIUM wire-shape ambiguity around `prompt_echo_blocked`. The r1 HIGH findings are closed, the r1 MEDIUM findings are closed, and Path B is narrated honestly. The only remaining prior item is minor structural numbering in §10d.

Once `prompt_echo_blocked` is unambiguously either a public error-envelope code or an internal plain-content fallback reason, this lane should be ready to lock aside from minor editorial cleanup.
