# SPEC-018 v0.2.1 — Round 2 Audit Narrative

**Date:** 2026-06-27
**Round:** 2
**Lanes:** architect / code / security / product-design (4-lane parallel)
**Verdict:** 3/4 lanes FIX REQUIRED (all MEDIUM-floor); 1/4 lane (Security) **READY TO LOCK**

## Aggregate tally

| Lane | C | H | M | m | Q | Δ from r1 |
|---|---|---|---|---|---|---|
| Architect | 0 | 0 | 1 | 1 | 0 | -3H / -2M / 0m / -1Q |
| Code | 0 | 1 | 2 | 0 | 0 | -3H / 0M / 0m / -1Q |
| Security | **0** | **0** | **0** | **2** | **0** | **-1C / -3H / -3M / 0m / -2Q** ← LOCKED |
| Product-Design | 0 | 0 | 1 | 0 | 0 | -4H / -2M / -1m / -2Q |
| **Total** | **0** | **1** | **4** | **3** | **0** | -1C / -13H / -7M / -1m / -6Q |

Massive convergence. From 1C+14H+11M+4m+6Q (r1, 36 total) to 0C+1H+4M+3m+0Q (r2, 8 total) — 78% reduction in 1 round. Pattern matches SPEC-017 trajectory (v0.1.7 r1 → r2 convergence ~70%).

## Security lane LOCKED

All r1 Security findings CLOSED with normative evidence:

- **C-1** (final-close settlement leak): §8.4.2 now requires terminal-arg-string + `finish_reason:"tool_calls"` + transport-completion marker + no post-incremental-open disconnect/timeout/relay-error. Absence → `FaultBreakerQualifying` → zero credits → no receipt → no sticky-route success write. Live billing primitive verified: `billing_recorder.go:176-190` + `formula.go:112-114`.
- **H-1** (§10c model-hash invariant): Path B amendment honestly narrated. AC-46 observation-only does not claim false v0.2 enforcement.
- **H-2** (prompt-echo deferral): §3.9 minimal guard closes exact-verbatim Cline attack. Transformed echo bounded as v0.3.
- **H-3** (mid-stream SSE error safety): §8.4.3 forbids `finish_reason:"tool_calls"` on terminal error. AC-48 negative test against openai-python + Cline.
- All r1 MEDIUMs closed.
- 2 fresh minors (`invalid_tools` not in stable code table; AC-46 vs §10d.0.1 unknown-hash inconsistency) carried to multi-lane absorption.

Money-path posture: trust-boundary holes closed. v0.2.1 is acceptable for narrow Cline drop-in security scope.

## Convergent findings → r3 absorption priority

1. **AC-46 unknown-hash semantics** (Code M-1 + Security m-2 + PD MEDIUM-1) — pick one shape:
   - Option A: always include the field, with sentinel `null` for unknown-hash case. Add AC-46 fixtures for both branches.
   - Option B: present-only-when-known, change AC-46 "missing field" fail condition to "missing when known."
   - PD additionally wants the field captured in AC-25a transcript schema for diagnostics + v0.3 registry prep.
2. **`prompt_echo_blocked` code-domain ambiguity** (Architect M-1) — remove from §10d.0 public v0.2 error-envelope code table OR explicitly split public codes from internal fallback reasons.

## Single-lane findings → r3 absorption mechanical

3. **Code H-3 residual** — stale `server.go:3743-3764` citation in §10a v0.2 paragraph. Live hash-routing predicates at `server.go:3291-3324` + `server.go:3873-3913`. Replace or strip the citation.
4. **Code M-2** — aggregate request caps need AC coverage: AC for each cap (4 MiB body, 1 MiB tool content, 2 MiB args, 256 messages, 128 tool calls) + linear-validation runtime assertion (e.g., bounded operation counter on 256-message adversarial fixture).
5. **Architect m-1 (§10d numbering)** — add explanatory note that §10d.X subsection numbers intentionally mirror deliverable IDs (#1 → §10d.1, #4 → §10d.4, etc.).
6. **Architect m-1 (§3.8 doc order)** — cosmetic. Add a line noting §3.8 is inserted before §3.7 to avoid moving locked content.
7. **Security m-1** (`invalid_tools` table inclusion) — add to stable code table OR add "inherited from SPEC-001/SPEC-002 request validation" note.

## Absorption plan → v0.2.2

7 edits. All mechanical or convergent. No new strategic decisions.

## Next steps

1. Write `specs/SPEC-018-v0_2-r2-absorption-prompt.md`.
2. Fire codex → v0.2.2.
3. Re-fire all 4 lanes (including Security as defensive — should return clean) for r3.
4. If 0/0/0 across all 4 → proceed to Claude blind-spot pass.
5. If not → r3 absorption → r4 (unlikely given r2 trajectory).

Confidence: r3 lands 0/0/0. The remaining work is editorial/mechanical, not strategic.
