# AUDIT_SPEC_018_v0_2_CODE_r1

## Task

Audit `specs/SPEC-018-agentic-tool-calling.md` v0.2.0 from the **code lens**: mechanical implementability, code-location citation accuracy, AC test-fixture verifiability, byte-exact wire shapes, ID regex correctness, validator-split mechanics.

This is round 1 of a codex 4-lane audit (architect / code / security / product-design) per [[feedback-three-lane-codex-audits]]. Your peer lanes audit independently.

## Scope

**Only review v0.2 additions:**
- New change-log entry at top
- Header changes
- New §3.7 (tool prompt-template profile)
- Extended §8.4.1 / §8.4.2 / §8.4.3
- New §10d (v0.2 deliverables)
- AC-25 through AC-45

**Do NOT relitigate v0.1.5 content.** v0.1.5 is LOCKED.

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` — the drafted v0.2.0 SPEC body.
2. `specs/SPEC-018-v0_2-design-synthesis.md` — design source.
3. `specs/SPEC-018-v0_2_0-DRAFT-NOTES.md` — 3 self-acknowledged issues, especially the failure-table vs AC-32 mismatch which is squarely your lens.
4. `specs/BUILD_SPEC_018_v0_2_PROMPT.md` — BUILD obligations.

You have access to the live repo for code-location verification:
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
- `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift`
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift`
- `phase3-binary/Sources/macprovider-cli/PromptCanonicalizer.swift`
- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift`
- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/buyer/billing_recorder.go`
- `phase4-coordinator/internal/billing/formula.go`

## Your code lens

Focus on:
- **Code-location citation accuracy**: every line-number citation in v0.2 sections — verify by reading the live repo. Stale citations (file moved, line shifted) are findings.
- **Wire-shape examples**: streaming SSE bytes in §10d.4; non-streaming error envelopes in §10d.1/.6/.7; tool prompt-template profile shape in §3.7. Are they byte-correct? Do JSON examples parse? Do SSE examples match openai-python v2.44.0 accumulator behavior?
- **Regex correctness**: §10d.6 provider-emitted `^call_[a-f0-9]{32}$` and request-accepted `^call_[A-Za-z0-9]{16,64}$`. Verify regex syntax + test against pass/fail cases in ACs.
- **Byte-cap arithmetic**: §10d.7 constants (1_048_576 / 2_097_152). UTF-8 byte counting. Inclusive boundary semantics. Are they internally consistent? Does any AC test the boundary incorrectly?
- **AC test-fixture mechanically verifiable**: AC-25 through AC-45 — can each be written as an executable test? Where the AC says "Cline session completes," is the criterion concretely measurable?
- **§8.4 validator split mechanics**: incremental-open vs final-close — are the inputs/outputs of each validator unambiguous? Is the transition between "buyer-visible commit" and "settlement commit" mechanically representable?
- **Failure-table vs AC-32 code mismatch** (DRAFT-NOTES flag #2): codex flagged that §10d.1 table uses `invalid_request` for missing `tool_call_id` while §10d.6/AC-32 use `invalid_tool_call_id`. Resolve.
- **Streaming validator at `server.go:2674`**: §10d.4 says it's incompatible with incremental fragments and needs replacement. Verify by reading the live code. Is the §10d.4 normative claim accurate?

## Output format

Write findings to `specs/SPEC-018-v0_2-code-r1-audit.md` with the same structure as the architect audit (verdict, tally, C/H/M/m/Q findings, verdict justification).

## Severity bar

- **CRITICAL** — wire-shape byte-incorrect, regex syntactically broken, byte-cap arithmetic wrong, AC literally untestable, money-path code citation false.
- **HIGH** — code-location citation stale (line shifted by N>5), wire-shape parses but breaks SDK contract, AC has unspecified test fixture, validator-split semantics ambiguous.
- **MEDIUM** — code-citation line off-by-few but still locatable, AC test fixture under-specified, wire-shape example missing one field.
- **minor** — polish; cite-formatting inconsistency.
- **Q** — design clarification needed.

Verify every code-line citation in v0.2 sections by reading the live repo. State which citations you verified.
