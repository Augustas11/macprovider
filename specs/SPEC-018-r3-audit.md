# SPEC-018 v0.1.2 — Round 3 audit narrative (lock confirmation)

## Round summary

Four codex audit lanes re-fired against `specs/SPEC-018-agentic-tool-calling.md` v0.1.2 (commit `4cc4f9f`) for lock confirmation. **All four lanes returned READY TO LOCK** with 0 CRITICAL + 0 HIGH + 0 MEDIUM across the board.

| Lane | CRITICAL | HIGH | MEDIUM | MINOR | QUESTIONS | Verdict |
|---|---|---|---|---|---|---|
| Product-Design | 0 | 0 | 0 | 0 | 0 | READY TO LOCK |
| Security | 0 | 0 | 0 | 0 | 0 | READY TO LOCK |
| Architect | 0 | 0 | 0 | 1 | 0 | READY TO LOCK |
| Code | 0 | 0 | 0 | 0 | 0 | READY TO LOCK |
| **Totals** | **0** | **0** | **0** | **1** | **0** | **READY TO LOCK** |

## r2-absorption fidelity

All 12 r2 findings (Arch M-1, M-2, m-1; Code M-1, M-2, M-3, Q-1, Q-2, Q-3; Sec m-1, m-2, Q-1; PD m-1, m-2, Q-1, Q-2) absorbed correctly in v0.1.2. Per-lane confirmations:

- **Arch M-1** (Qwen-row ambiguity): "§3.1 has one Qwen row matching `qwen2.5` OR `qwen3`; Qwen2.5-Coder and Qwen3 variants select the same family. No new body-grammar boundary issue found."
- **Arch M-2** (§2.3 SDK obligation): "§2.3 no longer contains 'SDKs MUST'; JSON string arguments are provider-side validation/canonicalization only, with downstream validation pointed to §1 + AC-20."
- **Arch m-1** (§7 voice): "§7 no longer imposes RFC-2119 requirements in SPEC-018's voice; it refers normative timeout authority back to SPEC-002 / SPEC-006."
- **Code M-1, M-2, M-3, Q-1, Q-2, Q-3**: all confirmed clean; §1 IMPL deltas enumeration is mechanically traceable; §10a #2 citations land on ModelHash field + heartbeat update; §8.4 source labeled as "current commit-signal path to patch"; AC-19 traces to IMPL prompt; AC-20 enumerates exact files + phrase; Qwen3 detection works.
- **Sec m-1, m-2, Q-1**: all confirmed clean; §8.4 + AC-21 require JSON-object `arguments`; §5 disambiguated; §10a #2 includes v0.2 unknown-hash fail-closed requirement.
- **PD m-1, m-2, Q-1, Q-2**: all confirmed clean; "certificate" narrowly defined; §10a #2 includes buyer-facing sentence; §10c forward compatibility invariant + AC-23; §11 Q1 product-decision framing.

## The single residual finding

**Arch m-1 r3 (deferrable polish):** Body parsing precedence (JSON-first then Python-style fallback) lives primarily inside the §3.1 table cell. The Qwen row is coherent today, but table-cell prose is a weaker maintenance surface than §3.3 for parser precedence. **Recommendation:** move the rule into §3.3 and let the table reference it.

This is a deferrable cleanup, not a lock blocker. Two options:
- (a) Lock v0.1.2 as-is; absorb in v0.1.3 polish or v0.2 design.
- (b) Apply a tiny v0.1.3 pre-lock polish (5-line edit) and skip the cost of running r4.

## Convergence trajectory

| Round | C | H | M | m | Q | Verdict |
|---|---|---|---|---|---|---|
| r1 | 2 | 5 | 13 | 5 | 7 | FIX REQUIRED |
| r2 | 0 | 0 | 5 | 5 | 6 | FIX REQUIRED |
| r3 | 0 | 0 | 0 | 1 | 0 | **READY TO LOCK** |

Three rounds vs the SPEC-017 trajectory of 10 rounds. The post-hoc ratification framing of v0.1 reduced design surface area dramatically — most "design questions" were already resolved by what cf2f135 + c823a96 + 7b8b1be shipped.

## What's NOT covered by codex four-lane

Per [[audit-cycles-are-design-discovery]] and the SPEC-017 v0.1.7 precedent (where Claude critic + product-designer found 5 HIGH + 7 MEDIUM that codex's three lanes missed), four-lane codex convergence is necessary but not sufficient for lock. Codex blind spots include:
- Cross-cutting consistency between distant SPEC sections (architect lane checks adjacent sections; not far-apart contradictions)
- Product narrative coherence as a single read-through (PD lane checks against the anchor example; not whether the SPEC reads as one document)
- Adversarial verification: every claim could be wrong; Claude critic tries to refute each one rather than accept
- Real-world buyer mental model: what would a CTO evaluating macprovider actually believe after reading this SPEC?

The optional Claude blind-spot pass (critic + designer) typically returns 5-15 findings — most MINOR, some MEDIUM. Absorbing them produces a stronger lock.

## Next-step decision

v0.1.2 is codex-lock-ready. Two paths forward:

1. **Run Claude blind-spot pass (critic + designer)** before declaring v0.1.2 LOCKED → likely produces v0.1.3 with minor polish, ~3-5 days of additional audit work, stronger lock.
2. **Declare v0.1.2 LOCKED now**, optionally apply Arch m-1 polish to v0.1.3, write BUILD_SPEC_018_IMPL_PROMPT.md, open PR. Faster lock, slightly weaker (codex-only) baseline.

Operator decision pending.
