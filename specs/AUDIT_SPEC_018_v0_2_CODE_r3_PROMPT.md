# AUDIT_SPEC_018_v0_2_CODE_r3

## Task

Round 3 code lane audit of `specs/SPEC-018-agentic-tool-calling.md` v0.2.2 after r2 absorption.

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` — v0.2.2 SPEC body.
2. `specs/SPEC-018-v0_2-code-r2-audit.md` — your r2 findings: 0C / 1H / 2M / 0m / 0Q.
3. `specs/SPEC-018-v0_2-r2-audit.md` — r2 narrative.
4. `specs/SPEC-018-v0_2-r2-absorption-prompt.md` — r2 absorption instructions.
5. `specs/SPEC-018-v0_2_2-DRAFT-NOTES.md` — codex absorption notes.

Live repo for citation re-verification:
- `phase4-coordinator/internal/buyer/server.go` — verify hash-routing range (r2 H-3 fix should now reference `:3291-3324` and/or `:3873-3913`, or strip the live-code citation entirely)

## Your tasks

1. **Confirm r2 code findings closed:**
   - H-3 residual: stale `server.go:3743-3764` citation in §10a v0.2 paragraph — verify replacement OR removal
   - M-1: AC-46 unknown-hash semantics (Option A `null` sentinel + JSON type spec + fixtures for known/unknown branches)
   - M-2: aggregate request caps need AC coverage — verify AC-50 through AC-55 are mechanically testable

2. **Fresh r3 code-lens sweep:**
   - AC-50 through AC-55 wire-shape consistency with §10d.1 cap definitions
   - HTTP code mapping (413 vs 400) correctness for each new cap
   - O(N) validation AC-55 fixture: is the "256 messages + 128 tool calls, bounded operation counter" criterion concretely testable?
   - `prompt_echo_blocked` removed cleanly from any AC referencing the public error envelope codes
   - `null` sentinel for unknown model_hash: JSON-schema-valid; openai-python v2.44.0 tolerates `usage.macprovider_model_hash_observed: null`

3. **Final lock-readiness assessment:** if r3 returns 0/0/0 from code lens, READY TO LOCK signal.

## Scope

Only v0.2.2 additions and r2 closures. Locked v0.1.5 still LOCKED.

## Output

Write `specs/SPEC-018-v0_2-code-r3-audit.md` with standard structure.

Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM = READY TO LOCK from code lens.
