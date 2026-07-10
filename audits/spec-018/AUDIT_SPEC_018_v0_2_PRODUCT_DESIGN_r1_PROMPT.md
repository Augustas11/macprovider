# AUDIT_SPEC_018_v0_2_PRODUCT_DESIGN_r1

## Task

Audit `specs/SPEC-018-agentic-tool-calling.md` v0.2.0 from the **product-design lens**: Cline-user experience, release-gate criterion realism, framework-compatibility narrative, deferral-to-v0.3 honesty, operator kill-switch UX, buyer-visible diagnostics, narrative coherence for SPEC reviewers and Cline integrators.

This is round 1 of a codex 4-lane audit per [[feedback-three-lane-codex-audits]]. Your peer lanes audit independently.

## Scope

**Only review v0.2 additions** (new change-log, §3.7, §8.4.1/.2/.3, §10d, AC-25 through AC-45). v0.1.5 LOCKED.

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` — drafted v0.2.0.
2. `specs/SPEC-018-v0_2-design-synthesis.md` — design source.
3. `specs/SPEC-018-v0_2_0-DRAFT-NOTES.md` — self-acknowledged issues. Note especially DRAFT-NOTE #3: §10a still names #2/#3/#5 as v0.2 targets — does the SPEC handle this contradiction honestly with the v0.2 narrowing?
4. `specs/BUILD_SPEC_018_v0_2_PROMPT.md` — BUILD obligations.
5. Cline reference: https://github.com/cline/cline — the v0.2 anchor framework. Read the Cline tools reference and SDK integration docs for realism checks.

## Your product-design lens

Focus on:
- **Cline integration realism**: the Cline session pass criteria (§10d / AC-25) — ≥20 turns, ≥30 tool calls, ≥3 file edits across ≥2 files, ≥2 commands with one failure+recovery, ≥1 history echo + matching tool result, ≥1 write_to_file ≥64 KiB with incremental stream visibility (first delta <1500ms, ≥3 deltas). Is this realistic? Can a Cline user produce this evidence in a normal coding session? Is the 1500ms TTFMO bound achievable with a Mac M2/M3/M4 running Qwen3-32B-4bit? Or is it too aggressive?
- **Operator kill switch UX**: §10d.4 mentions operator kill switch + per-provider auto-downgrade. From a Cline-user perspective, what's the experience when streaming is killed for them? Do they see a graceful degradation, or do they get cryptic errors? Should the SPEC require buyer-visible signaling of "this response is buffered, not streaming"?
- **Wire-shape diagnostics**: v0.3 defers structured `usage.macprovider_malformed_tool_call`. In v0.2, when a failure happens (cap exceeded, parse failure), Cline gets a terminating SSE error frame or HTTP 4xx/5xx. Is the error envelope shape sufficient for Cline to display an actionable message to the user? Does Cline know whether to retry, re-prompt, or fail the session?
- **Release-gate honesty**: §10d.X "v0.2 release gate" — is this aligned with what we can actually observe? Are there release-gate items that depend on Cline collaboration (recorded session), and is that operationally feasible by v0.2 IMPL ship date?
- **Framework-compatibility narrative**: §1 (v0.1.5 locked) lists 9 OpenAI-wire frameworks. v0.2 narrowed to Cline-only release gate. Does the SPEC body honestly explain why Cline is the gate vs the others (size of installed base, depth of tool-call workload, multi-turn iteration count)? Or does the narrowing read as arbitrary/silent?
- **Deferral-to-v0.3 honesty**: §10d mentions #2/#3/#5 as v0.3. But §10a v0.1.5 LOCKED still names them as "v0.2 normative targets." Is the contradiction handled honestly with a v0.2 change-log entry that explicitly says "scope narrowed from 7 to 4"? Or does the SPEC read as if v0.2 silently shipped less than promised?
- **Strategic positioning**: v0.2 is the "Cline drop-in works" release. Does the SPEC convey this product framing clearly enough for a future SPEC reviewer or external Cline integrator? Or does it read as a technical bugfix without product intent?
- **AC-25 multi-turn definition vs Cline reality**: AC-25 requires ≥20 provider turns. A typical Cline coding session can hit 20-50 turns easily, but a "20 turns" criterion needs a recorded fixture for CI. Is this CI-amenable, or is it manual-only release evidence?

## Output format

Write findings to `specs/SPEC-018-v0_2-product-design-r1-audit.md` with the standard structure.

## Severity bar

- **CRITICAL** — v0.2 release gate impossible to verify, Cline integration narrative contradicts Cline reality, deferral-to-v0.3 reads as undisclosed scope cut.
- **HIGH** — operator kill switch UX leaves Cline users confused, error envelope under-specified for Cline to act on, release-gate criterion too aggressive or too loose, framework narrative arbitrary.
- **MEDIUM** — product framing weak, deferral honesty imperfect, narrative gap that costs reviewer time.
- **minor** — polish.
- **Q** — product trade-off needing explicit closure.

Be opinionated about Cline-user experience. v0.2's whole product thesis is "Cline drop-in works" — if Cline UX is degraded in any v0.2 failure mode, that's HIGH minimum.
