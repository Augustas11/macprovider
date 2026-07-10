# SPEC-018 v0.2.2 — Claude Blind-Spot Pass Narrative

**Date:** 2026-06-27
**Lanes:** Critic (adversarial-verifier) + Narrative analyst (3 reader tests)
**Verdict:** FIX REQUIRED — critic lane found 3 lock-blocking HIGH issues codex's 4 lanes ALL missed across 3 rounds. Same pattern as v0.1.5 precedent.

## Aggregate tally

| Lane | C | H | M | m | Q |
|---|---|---|---|---|---|
| Critic | 0 | 3 | 4 | 3 | 2 |
| Narrative | 0 | 1 | 3 | 2 | 1 |
| **Total** | **0** | **4** | **7** | **5** | **3** |

Codex 4-lane (architect/code/security/product-design × 3 rounds = 12 codex audit passes) converged 0/0/0 across all 4 lanes at r3. Claude blind-spot pass found 3 critic HIGHs + 1 narrative HIGH the codex lanes missed entirely. This validates the v0.1.5 pattern: codex's lane-discipline blinds it to claim-vs-reality + cross-section consistency issues.

## Critic HIGH findings (3 lock-blockers)

### H-1: AC-48/AC-43/AC-39 assume openai-python — Cline doesn't use it

Critic verified against Cline `main@92806c60`, VS Code extension v4.0.0 (`saoudrizwan.claude-dev` — the exact pin AC-25a names): Cline's `sdk/packages/llms/src/providers/vendors/openai-compatible.ts` imports `createOpenAICompatible` from **`@ai-sdk/openai-compatible`** (Vercel AI SDK), NOT openai-python.

AC-48 specifies a fixture combining "openai-python v2.44.0+ streaming reader AND Cline integration" — these are mutually exclusive stacks. The actual money-path question (does Vercel AI SDK surface a terminal SSE error frame as an exception or dispatch a partial assistant message into Cline's AgentRuntime?) is **ungated**.

This is a "claim-vs-reality" blind spot codex can't catch — codex audits internal consistency, not whether real frameworks behave as the SPEC assumes.

**Resolution: mechanical, no strategic call.** Split the ACs:
- AC-23 + AC-43 (forward-compat regression): stays openai-python-baseline. Represents broad SDK ecosystem.
- AC-39 + AC-48 (Cline-specific terminal-error behavior): split into openai-python verification (SDK-side, ecosystem) + Cline-direct verification using actual Cline SDK / `@ai-sdk/openai-compatible` (Cline-specific).

### H-2: §3.9 prompt-echo guard trivially bypassed AND self-DoS

Three problems:
1. **Whitespace bypass**: SPEC §3.9 says "different whitespace does not trigger" → one-newline mutation by the model defeats the entire defense.
2. **Scope hole**: Guard doesn't cover `tools[].description`, `tools[].function.parameters`, or assistant-history `function.arguments` — all common prompt-injection vectors.
3. **Self-DoS**: Asking Cline to `read_file` SPEC-018.md (which contains `<tool_call>{...}</tool_call>` examples in AC-1 at line 506) triggers the guard against legitimate follow-up tool calls. Same anti-pattern as v0.1.5 H-3 mixed-sentinel DoS we dropped in v0.1.3.

**Resolution decision (user 2026-06-27): Path (a) — drop the v0.2 minimal echo guard entirely.** Document residual same-family echo risk in §10c amendment as the SECOND v0.2 Path-B-style lock-amendment. v0.3 delivers the full guard with whitespace normalization + tool-description scope + Cline-shaped false-positive testing.

Rationale: minimal guard is worse than no guard because it creates a self-DoS more reproducible than the attack it closes. Same honesty pattern as model-hash registry: ship narrow, defer mitigation, name the residual risk.

### H-3: §10d.4 per-provider auto-downgrade is buyer-vs-buyer DoS

Malicious buyer engineers prompts that elicit malformed Qwen3 streams from Provider X → all OTHER buyers sticky-routed to X lose incremental streaming UX. SPEC defines no threshold, attribution model, recovery path, or per-buyer rate limit.

**Resolution: mechanical.** Bound by per-buyer attribution: "N malformed streams in M minutes from same buyer → downgrade for THAT buyer's future requests to that provider only, not for all buyers." Plus recovery path (downgrade lifts after K minutes of clean streams). Concrete: N=3, M=5 minutes, recovery after 10 minutes clean.

## Critic MEDIUM findings

| Finding | Resolution |
|---|---|
| M-1: AC-44 timing instrument crosses Mac↔Pearl clock domains, no skew bound (p95 unverifiable) | Bound by NTP-anchored skew assumption: `\|t_provider - t_gateway\| ≤ 100 ms` at request start. p95 measured with skew correction. |
| M-2: Aggregate caps don't compose to bound total decoded prompt | Add total-decoded-prompt cap: 6 MiB (sum of all `messages[].content` decoded UTF-8 + assistant-history args + tool results). |
| M-3: AC-46 `null when known` fail condition unverifiable externally | Reframe AC-46 as provider self-test only (provider-side log assertion); buyer-visible behavior is just "field present, type null or hex." |
| M-4: Path B amendment precedent under-specified | Promote lock-amendment discipline to new §10c.1 named section with concrete rule (mirrors narrative M-2). |

## Critic minor + Q (polish)

m-1: AC numbering jumps preserved across versions (already done; just name it).
m-2: Cline reality check on `messages[]` > 256 entries (Cline can hit this in long sessions; cap is fine, but acknowledge as user-actionable HTTP 400).
m-3: Mac-clock vs Pearl-clock as inputs to AC-44 (subset of M-1).
Q-1: Should AC-25a additionally cover a Cline workspace that includes SPEC-018.md as a read target? (Validates H-2 self-DoS is closed by guard removal.)
Q-2: Path B precedent extension — can v0.3 amend OTHER v0.2 invariants? Add to §10c.1.

## Narrative HIGH (polish, but high-impact reader-experience)

### H-1: Quick orientation block missing at top of SPEC

A first-time Cline integrator reading the top 100 lines cannot tell that v0.2 IS the "Cline drop-in" release. Seven stacked change-log entries push §1 product framing to line 54. v0.2.2 buyer-visible bullets are edge cases, not the v0.2 product thesis.

**Resolution: mechanical.** Insert a "Quick orientation" block immediately after Status, before the change log:
- 4-6 lines covering: what v0.2 ships (Cline drop-in), what's locked from v0.1.5, what's deferred to v0.3.
- Solves first-time-reader + PR-reviewer + future-Claude-IMPL reader tests at once.

## Narrative MEDIUM findings

| Finding | Resolution |
|---|---|
| M-1: v0.2.2 buyer-visible deltas bury v0.2.2's role as codex-converged lock candidate | Rework buyer-visible deltas to lead with "v0.2.2 is the codex-converged lock candidate" then enumerate the edits. |
| M-2: §10c carries AMENDED paragraph but lock-amendment discipline rule lives only in change-log prose | Promote to §10c.1 (converges with Critic M-4). |
| M-3: §10a stale 7-item commitment list — reader hitting §10a cold sees outdated state | Add 1-line reader-note at §10a heading: "Historical locked v0.1.5 content. For v0.2.0+ active scope, see §10d.0 reader note." |

## Narrative minor + Q

m-1: §3.8/§3.9 v0.2 additive content precedes locked §3.7. (NOTE: with H-2 Path (a) removing §3.9, this is only §3.8 — slightly better.)
m-2: AC-22 removed-placeholder — name "AC numbers stable across versions" explicitly.
Q-1: Confirm lock-finalization updates the stale "pending round-3" Status string.

## Absorption plan → v0.2.3

19 absorptions. Two are LOAD-BEARING:

1. **Path (a) §3.9 echo-guard deletion + §10c amendment narrative** (H-2 path a) — the SECOND v0.2 Path-B-style amendment.
2. **§10c.1 lock-amendment discipline rule** (Critic M-4 + Narrative M-2) — converging finding; promote to named section.

Remaining 17 are mechanical/editorial.

## Path B precedent: SECOND amendment

v0.2.1 set the precedent. v0.2.3 invokes it for the second time. The lock-amendment discipline rule (§10c.1) must define:
- When amendment is acceptable (scope-vs-invariant tension)
- What MUST appear in the change-log entry (explicit name + rationale + replacement mitigation or honest residual-risk doc)
- The precedent set (locked invariants are not immutable but require explicit amendment, not silent scope cuts)

Each amendment in v0.2.X SHOULD be explicitly enumerated in §10c.1's amendment log. v0.2.3 enumerates:
- Amendment 1: §10c v0.1.3-locked model-hash registry → deferred to v0.3 (v0.2.1, Path B, with AC-46 observation channel).
- Amendment 2: §3.9 v0.2.1-introduced minimal prompt-echo guard → deferred to v0.3 (v0.2.3, Path a, with residual-risk documentation).

## Next steps

1. Write `specs/SPEC-018-v0_2-blindspot-absorption-prompt.md`.
2. Fire codex → v0.2.3.
3. Re-fire codex 4-lane r4 (defensive — confirm no regression).
4. Re-fire Claude critic + narrative blind-spot pass r2 (defensive — confirm both lanes now READY TO LOCK).
5. If both passes 0/0/0 → declare v0.2.3 LOCKED → open SPEC PR.

Confidence: v0.2.3 is the lock candidate. Round trajectory pattern: r1 36 findings → r2 8 findings → r3 0 codex findings + 11 blind-spot findings (4H/7M/5m/3Q) → r4 expected near-zero.
