# SPEC-018 v0.2.0 — Architect Lane r1 Audit

**Date:** 2026-06-27
**Reviewer:** codex architect lane
**Verdict:** FIX REQUIRED

## Tally: C/H/M/m/Q

C=0 CRITICAL / H=3 HIGH / M=3 MEDIUM / m=1 minor / Q=1 question

## Findings

### CRITICAL findings

(none)

### HIGH findings

H-1: v0.2.0 has two incompatible scope narratives for #2/#3/#5

Location: `specs/SPEC-018-agentic-tool-calling.md:514-524`, `:536-550`, `:733-741`, `:765-767`; header dependency note at `:4`.

Concern: The v0.2 additions correctly encode the design synthesis narrow scope (#1/#4/#6/#7 only) in the change log and §10d.8, but locked §10a still says all seven items are "v0.2 deliverables" and §10c still carries a "v0.2 model-hash → family registry MUST" invariant. That leaves model-hash registry (#2), prompt-echo guard (#3), and structured malformed signal (#5) simultaneously deferred to v0.3 and required for v0.2. This also makes the SPEC-008/SPEC-011 dependency story unstable: they are referenced-only under the synthesis, but §10a/§10c still read like binding v0.2 implementation dependencies. This CONFIRMS the DRAFT-NOTES §10a contradiction as HIGH, not merely editorial.

Recommended fix: Add an explicit v0.2.0 overlay note, without rewriting locked v0.1.5 prose, stating that §10a is historical v0.1.5 target language and that §10d is the authoritative v0.2.0 scope. State that §10a #2/#3/#5 and the §10c model-hash registry invariant are carried forward as v0.3-or-later requirements unless a later SPEC rev re-promotes them. Adjust the header dependency note if needed so SPEC-008/SPEC-011 remain referenced, not newly binding for v0.2.0.

H-2: AC-14 remains a v0.2 acceptance contradiction

Location: `specs/SPEC-018-agentic-tool-calling.md:444`, `:470-474`, `:590`.

Concern: AC-14 still says `role:"tool"` and assistant-history `tool_calls[]` fail with `unsupported_tool_messages`, while §10d.1 says AC-14 transitions to success and AC-26/AC-27 require acceptance/rendering. Because the document header is now v0.2.0, an implementer reading the AC list has both a required fail condition and required pass condition for the same request class.

Recommended fix: Add a v0.2 acceptance-criteria applicability note near AC-14 or before AC-25: AC-14 is the locked v0.1.x ratification criterion and is superseded for v0.2.0 by AC-26/AC-27. Do not renumber ACs; make the version boundary explicit.

H-3: Missing `tool_call_id` has two normative error codes

Location: failure table at `specs/SPEC-018-agentic-tool-calling.md:577-579`; §10d.6 at `:698-703`; AC-32 at `:484`.

Concern: §10d.1 says a missing `tool_call_id` returns HTTP 400 `invalid_request`, while §10d.6 defines `invalid_tool_call_id` as "ID missing or format invalid" and AC-32 constrains cross-message validation failures to the four §10d.6 codes. That makes AC-32 unverifiable and invites divergent provider/coordinator behavior. This CONFIRMS the DRAFT-NOTES failure-table vs AC-32 mismatch as HIGH.

Recommended fix: Canonicalize missing `tool_call_id` to `invalid_tool_call_id` in the §10d.1 table, matching §10d.6 and the build prompt's four-code enum. Keep `content:null` as `invalid_request` if that remains the desired generic content-shape error.

### MEDIUM findings

M-1: Duplicate §3.7 headings make normative cross-references ambiguous

Location: new tool prompt-template profile at `specs/SPEC-018-agentic-tool-calling.md:208`; locked "Adding a new family" at `:227`; prior §3.6 reference to "future family additions per §3.7" at `:199`.

Concern: There are now two `### 3.7` sections with different purposes. The old §3.6 cross-reference intended "Adding a new family"; new §10d.1 references §3.7 intending the prompt-template profile. A reviewer or implementer cannot resolve `§3.7` mechanically. This CONFIRMS the DRAFT-NOTES duplicate-heading issue.

Recommended fix: Give the v0.2 additive section a non-colliding identifier, for example `### 3.7a Tool prompt-template profile` or `### 3.8 ...`, and add a one-line note that locked v0.1.5 numbering is preserved except for this additive suffix. If strict numeric sequencing is required, renumber only via an explicit lock-breaking editorial decision.

M-2: Buffered-to-end streaming language needs explicit v0.2 applicability override

Location: locked §4 at `specs/SPEC-018-agentic-tool-calling.md:245-255`; AC-8/AC-9 at `:432-434`; v0.2 streaming additions at `:592-622`, `:500-506`.

Concern: §4 and AC-8 still normatively say a streaming tool-call response emits one complete `delta.tool_calls[]` event after generation completes. §10d.4 and AC-40/AC-41 require token-incremental fragments. §4 does mention v0.2 promotion, but it does not explicitly say the v0.1 complete-delta MUSTs are version-scoped and superseded for v0.2 streaming.

Recommended fix: Add a v0.2 note near §4 or before AC-40: §4/AC-8 describe v0.1.x buffered-to-end behavior; for v0.2.0 streaming, §10d.4 and AC-40 through AC-45 are authoritative.

M-3: `AC-23s` is referenced but not an actual AC identifier

Location: §10d.4 at `specs/SPEC-018-agentic-tool-calling.md:622`; actual streaming regression AC at `:506`.

Concern: §10d.4 says "AC-23s extends AC-23", but the acceptance criteria list does not contain `AC-23s`; the relevant criterion is AC-43. That breaks mechanical cross-reference checks and leaves two names for one release gate.

Recommended fix: Replace the prose with "AC-43 is the streaming extension to AC-23" or add an explicit alias sentence: "`AC-23s` in design notes is encoded as AC-43 in this SPEC."

### Minor findings

m-1: §10d subsection numbering is structurally surprising

Location: `specs/SPEC-018-agentic-tool-calling.md:560`, `:592`, `:624`, `:711`, `:733`.

Concern: §10d jumps from .1 to .4 to .6 to .7, then adds .8 for out-of-scope items. The intent is understandable because the numbers mirror deliverable IDs, but it is inconsistent with the surrounding section style and with the audit prompt's §10d.1-.7 wording.

Recommended fix: Either add a short note that §10d subsection numbers intentionally mirror deliverable numbers, or renumber the subsections sequentially while keeping deliverable tags in headings.

### Open questions

Q-1: What is the canonical disposition of the locked model-hash registry invariant?

Location: `specs/SPEC-018-agentic-tool-calling.md:550`, with deferral at `:737`.

Question: Should the v0.1.3-locked unknown-hash fail-closed invariant be treated as a v0.3 registry invariant now that v0.2.0 is narrow, or must a v0.2.x follow-up still satisfy it before v0.2 is considered fully ratified? This needs an explicit sentence because it affects SPEC-008/SPEC-011 dependency-chain interpretation.

## Verdict justification

FIX REQUIRED. The v0.2 additions mostly encode the synthesis correctly, and AC-25 through AC-45 are present with the intended #1/#4/#6/#7 coverage. The lock blockers are structural/versioning issues: the document simultaneously says v0.2 is narrow and that all seven original §10a targets are required, and it keeps AC-14's v0.1 failure criterion active beside v0.2 success criteria.

The fixes should be additive editorial overlays, not a relitigation of locked v0.1.5 behavior. Once the version-applicability notes, error-code mismatch, and duplicate §3.7 cross-reference are cleaned up, the architect lane should be able to reassess for READY TO LOCK.
