# AUDIT_SPEC_018_v0_2_SECURITY_r2

## Task

Round 2 security lane audit of `specs/SPEC-018-agentic-tool-calling.md` v0.2.1 after r1 absorption.

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` — v0.2.1 SPEC body.
2. `specs/SPEC-018-v0_2-security-r1-audit.md` — your prior round findings: **1 CRITICAL** + 3 HIGH + 3 MEDIUM + 2 minor + 2 Q.
3. `specs/SPEC-018-v0_2-r1-audit.md` — r1 narrative (Path B decision recorded).
4. `specs/SPEC-018-v0_2-r1-absorption-prompt.md` — absorption instructions.
5. `specs/SPEC-018-v0_2_1-DRAFT-NOTES.md` — codex absorption notes.

Live repo for money-path tracing:
- `phase4-coordinator/internal/buyer/billing_recorder.go:176-190` (FaultFlag carrier)
- `phase4-coordinator/internal/billing/formula.go:112-114` (zero-credit on FaultBreakerQualifying)
- `phase4-coordinator/internal/buyer/server.go:2239-2255` (WS post-commit disconnect handling)
- `phase4-coordinator/internal/buyer/server.go:2469-2471` (direct-HTTP clean EOF — r1 noted current behavior may need patching)
- `phase4-coordinator/internal/buyer/server.go:2476-2487` (direct-HTTP post-commit disconnect)

## Your tasks (HIGH PRIORITY)

1. **C-1 closure verification (Final-close settlement leak)**: re-read v0.2.1 §8.4.2 and AC-47. Does the new normative text force every missing-terminal path (provider EOF without `finish_reason:"tool_calls"`, transport disconnect after incremental-open, timeout, missing `[DONE]`) to set `FaultBreakerQualifying`? Trace through both `forwardWSStreaming` and `forwardStreaming` paths conceptually. Is the money-path leak closed?

2. **H-1 closure verification (§10c model-hash invariant)**: v0.2.1 took Path B — explicit amendment of locked §10c. Audit whether the amendment is honest (rationale stated, precedent named, NOT a silent scope cut). Audit whether AC-46 `usage.macprovider_model_hash_observed` field provides the v0.2 observation channel that prepares for v0.3 registry without claiming false security.

3. **H-2 closure verification (Prompt-echo guard deferral)**: v0.2.1 added minimal v0.2 prompt-echo guard (item 4 in absorption: complete native sentinel+body+close sequence verbatim match → fail closed). Audit whether the minimal guard actually closes the realistic Cline attack (untrusted repo file or tool output containing native tool-call block). Is "complete native sequence" specified precisely enough that an attacker cannot bypass by inserting whitespace/characters mid-sequence?

4. **H-3 closure verification (Mid-stream SSE error safety)**: v0.2.1 added §8.4.3 "MUST NOT carry `finish_reason:"tool_calls"`" and AC-48 (post-error stream with openai-python + Cline, no dispatchable tool_calls reach framework). Is the negative AC sufficient?

5. **MEDIUM closures**: M-1 (aggregate request caps), M-2 (buyer-fabricated history provenance language), M-3 (kill-switch buyer-visibility header).

6. **Fresh security-lens findings** on v0.2.1 edits: aggregate caps numeric values, error envelope `request_id`/`inference_ran`/`settlement_ran` field security semantics, `X-MacProvider-Streaming-Mode` header information-disclosure analysis (does it leak attacker-useful state?), minimal echo guard byte-match semantics for adversarial bypass paths.

## Scope

Round 2 focus: prior-round closure + fresh-finding sweep on v0.2.1 additions. Locked v0.1.5 still LOCKED.

## Output format

Write to `specs/SPEC-018-v0_2-security-r2-audit.md` with standard structure.

Money-path settlement and trust-boundary findings remain TOP priority. Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM = READY TO LOCK from security lens. If C-1 remains open after v0.2.1, that's automatic FIX REQUIRED.
