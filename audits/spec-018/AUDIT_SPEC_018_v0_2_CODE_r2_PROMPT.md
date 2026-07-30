# AUDIT_SPEC_018_v0_2_CODE_r2

## Task

Round 2 code lane audit of `specs/SPEC-018-agentic-tool-calling.md` v0.2.1 after r1 absorption.

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` — v0.2.1 SPEC body.
2. `specs/SPEC-018-v0_2-code-r1-audit.md` — your prior round findings: 4 HIGH + 2 MEDIUM + 1 Q.
3. `specs/SPEC-018-v0_2-r1-audit.md` — r1 narrative.
4. `specs/SPEC-018-v0_2-r1-absorption-prompt.md` — absorption instructions.
5. `specs/SPEC-018-v0_2_1-DRAFT-NOTES.md` — codex absorption notes.

Live repo for code-citation verification (regenerated in r1 absorption):
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` — verify `:353` and `:403` call sites are correct (r1 found `:344` and `:395` were function starts).
- `phase4-coordinator/internal/buyer/server.go` — verify `:2103` and `:2149` for `forwardWSStreaming` (r1 found `:2119` was off), and `:1241-1245` for `tool_call_id/tool_calls` preservation (r1 found `:1234` was off).
- Plus all other live-repo paths cited in v0.2 sections.

## Your tasks

1. **Confirm or reject each prior code r1 finding** as CLOSED or NOT CLOSED with v0.2.1 citation:
   - H-1: §3.7→§3.8 family-renderer byte-specifiable (Qwen3/Llama-3.3 golden fixtures or structural spec + upstream refs)
   - H-2: missing tool_call_id two-code mismatch
   - H-3: code-citation drift (verify NEW citations in v0.2.1 by reading live repo)
   - H-4: AC-25 / AC-44 / AC-45 reproducibility (split into AC-25a/AC-25b, instrumented timing, kill-switch header)
   - M-1: §10d.4 SSE example concrete ID
   - M-2: AC-39 vs AC-43 success vs error scope clarification
   - Q-1: final-close requires `finish_reason:"tool_calls"` (Q-1 + Security C-1 converge — verify §8.4.2 tightened)

2. **Look for fresh code-lens findings** in v0.2.1 edits: AC-46 through AC-49 mechanical verifiability, error envelope shape (item 18 in r1 absorption — 8 fields, retryable per code), aggregate request caps numeric values, linear validation requirement testability, kill-switch header three-value enum coverage.

3. **Verify §8.4.2 tightening (Security C-1 fix)**: re-read the new §8.4.2 normative text. Does the four-condition requirement (terminal arg string + finish_reason:"tool_calls" + transport completion marker + no disconnect/timeout/relay error) translate into unambiguous IMPL semantics? Are the cited code locations (`server.go:2239-2255`, `:2476-2487`, `:2469-2471`) consistent with current live behavior?

## Scope

Round 2 focus: r1 closure verification + fresh-finding sweep on v0.2.1 additions only. Locked v0.1.5 still LOCKED.

## Output format

Write to `specs/SPEC-018-v0_2-code-r2-audit.md` with standard structure.

Be especially aggressive on §8.4.2 (Security C-1 lock-blocker fix) and AC-46/AC-49 (new ACs from r1 absorption). Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM = READY TO LOCK from code lens.
