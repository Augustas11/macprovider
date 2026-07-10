# SPEC-017 IMPL prompt — 3-lane codex audit convergence summary (v0.1.8 anchor)

**Convergence date:** 2026-06-26
**Final IMPL prompt version:** v14 (committed at `61e6a14`)
**Controlling SPEC:** v0.1.8 LOCKED at `62468cb` (codex round-10 0/0/0)
**Verdict:** **READY TO KICK OFF IMPLEMENTATION** on all three lanes.

## Per-lane lock targets

All three lanes converged at `0 CRITICAL + 0 HIGH + 0 MEDIUM`. LOW + INFO findings deferred per the user-instructed scope (`fix all issues except low info`).

| Lane | Rounds (this anchor) | Final lock round | Final result |
|---|---|---|---|
| ARCH | 6 (r6 → r12) | r12 (2026-06-26T05:59:55Z) | 0/0/0 + 3 LOW + 2 INFO |
| CODE | 7 (r7 → r13) | r13 (2026-06-26T06:04Z) | 0/0/0 + 3 LOW + 0 INFO |
| SECURITY | 3 (r4 → r6) | r6 (2026-06-26T05:00Z, on v9) | 0/0/0 + 6 INFO |

The IMPL prompt was anchored across two SPEC LOCK versions (v0.1.7 → v0.1.8) during this convergence loop because the v0.1.7-anchored IMPL audit (ARCH r6 / CODE r7) surfaced two **SPEC contradictions** that could only be fixed by a SPEC bump (§9.4 vs §7.2.2 grant mismatch, and §5.6 vs AC-8 burst). The SPEC re-locked at v0.1.8 (codex r10 0/0/0) and the IMPL prompt re-anchored to v0.1.8.

## Trajectory (v0.1.8-anchored, post-v0.1.7-LOCK)

| Lane / Round | C | H | M | L | Verdict |
|---|---|---|---|---|---|
| ARCH r6 (v7 → v8 fix) | 2 | 2 | 2 | 0 | READY WITH FIX PASS |
| ARCH r7 (v8 → SPEC v0.1.8 + IMPL v9) | 1 | 2 | 0 | 0 | ANOTHER DESIGN ROUND NEEDED |
| ARCH r8 (v9 → v10) | 1 | 1 | 1 | 1 | READY WITH FIX PASS |
| ARCH r9 (v10 → v11) | 0 | 2 | 1 | 0 | READY WITH FIX PASS |
| ARCH r10 (v11 → v12) | 1 | 1 | 1 | 1 | READY WITH FIX PASS |
| ARCH r11 (v12 → v13) | 0 | 0 | 0 | 3 | READY TO LOCK |
| **ARCH r12 (v13 → v14, confirmatory)** | **0** | **0** | **0** | **3** | **READY TO LOCK** |
| CODE r7 (v7 → v8) | 1 | 2 | 5 | 2 | NOT READY |
| CODE r8 (v8 → SPEC v0.1.8 + IMPL v9) | 0 | 2 | 2 | 1 | NOT READY |
| CODE r9 (v9 → v10) | 0 | 1 | 2 | 1 | NOT READY |
| CODE r10 (v10 → v11) | 0 | 0 | 0 | 3 | READY WITH LOW HYGIENE |
| CODE r11 (v11 → v12) | 0 | 2 | 0 | 3 | NOT READY |
| CODE r12 (v12 → v13) | 0 | 1 | 0 | 3 | NOT READY |
| **CODE r13 (v13 → v14)** | **0** | **0** | **0** | **3** | **READY FOR CODE-MECHANICS CONVERGENCE** |
| SECURITY r4 (v7 → v8) | 0 | 1 | 0 | 0 | READY WITH FIX PASS |
| SECURITY r5 (v8 → SPEC v0.1.8 + IMPL v9) | 1 | 1 | 0 | 0 | READY WITH FIX PASS |
| **SECURITY r6 (v9 — held since)** | **0** | **0** | **0** | **0** | **READY TO KICK OFF IMPLEMENTATION** |

## Distinct CRITICAL + HIGH findings absorbed across the loop

### SPEC-impacting (forced SPEC v0.1.7 → v0.1.8 bump)

1. **§9.4 vs §7.2.2 grant mismatch** (CODE r7-001 → ARCH r7 C1 → SPEC r9 absorbed). SPEC §9.4 named Shape A (TRUNCATE) and Shape B (ALTER RENAME + DROP) for nightly rebuild atomicity, but `stats_rollup` only has SELECT/INSERT/UPDATE/DELETE per locked §7.2.2. **Resolution:** SPEC v0.1.8 added Shape C (single-tx DELETE + INSERT) executable under the locked grants.
2. **§5.6 vs AC-8 burst** (CODE r8-002 → ARCH r6 C2 → SPEC r9 absorbed). §5.6 named "burst 120" for the public tier but AC-8 required the 61st request to return 429 — mechanically inconsistent. **Resolution:** SPEC v0.1.8 dropped the burst column from both tiers + added Authorization-aware nginx keying + added auth-failure tier limiter + new AC-22.
3. **Partner-key `rate_limit_burst` ambiguity** (SPEC r9 M1 absorbed in same v0.1.8 fix pass). Field was inconsistent with the new hard-limit model. **Resolution:** dropped from §5.4.1, removed `--burst` CLI flag.
4. **Auth-failure-tier under-specification** (SPEC r9 M2 absorbed). The §5.6 nginx-keying-empty-on-Authorization rule left invalid-bearer floods without a specified limiter. **Resolution:** SPEC v0.1.8 added the 300 req/min in-process pre-hash-SELECT auth-failure tier + AC-22.

### IMPL-prompt-only (resolved in IMPL prompt fix passes)

5. **Edge-cache test contradicting AC-3** (ARCH r6 C1 / CODE r7-002). Rewritten to anonymous-only equivalence + separate AC-3 nginx-tier confirmation.
6. **Path R2 operator-divergence waiver** (ARCH r6 C2 / CODE r7-003). Deleted — Step 4.B is now hard-blocked on SPEC reconciliation only.
7. **Partner-key projection ACAO never `*`** (Claude H1 absorbed in SPEC v0.1.7; IMPL-prompt explicit enforcement).
8. **AC-15 sweep step-bleed** (ARCH r6 H1). Step 3 AC-15 narrowed to handler structured logs + recover panic logs + trace spans; CLI/nginx/metrics live in Step 4.A/4.B/4.C.
9. **SPEC-014 v0.9 surface conflation** (ARCH r6 H2 / ARCH r9 H2 / ARCH r10 H1). Split into three explicit surfaces with distinct gate semantics — visibility-toggle UI (non-blocking), Q12 canonical UI (non-blocking), §6.6.2 disclosure UI (production-issuance gate, NOT PR convergence gate).
10. **SECURITY pre-auth limiter missing** (SECURITY r4 H1). Added; later refined for trusted-proxy IP allowlist (SECURITY r5 H1).
11. **nginx `proxy_no_cache` write-suppression** (SECURITY r5 C1). Added alongside `proxy_cache_bypass`.
12. **Trusted-proxy IP allowlist for limiter** (SECURITY r5 H1). Closed against spoofed-XFF flood on direct-to-coordinator surface.
13. **Auth-failure tier limiter over-scoping** (ARCH r8 C1 / CODE r9 H1). Scoped to Authorization-present requests only; reserve-then-refund on valid 200; absent Authorization short-circuits.
14. **§5.6 keyed-through-nginx bypass test missing** (ARCH r8 H1). Added Step 4.B test for 100 valid-keyed requests/min through nginx, no edge throttle.
15. **`stats_rollup_state` widening grants outside locked SPEC** (ARCH r10 C1 / CODE r11-001). Reverted to coordinator config (read-once at startup, injected via `*config.Stats` to both rollup and handler packages). No new DB table, no new grants.
16. **Step 4.C PR vs production-issuance gate distinction** (ARCH r10 H1). Rewritten: PR converges with template + checkbox + sign-off-state statement; live SPEC-014 v0.9 deployment remains a cutover prerequisite, NOT a PR merge prerequisite.
17. **Per-endpoint rate-limit keying** (CODE r11-002). Middleware buckets now keyed on `(subject, endpoint)`; nginx declares 3 separate zones (overview / leaderboard / health).
18. **CORS row-number drift** (CODE r12-001). "Rows 2/3/4" → "rows 3/4/5" with explicit reminder public row 2 still emits `ACAO: *`.

## Cross-lane convergence patterns

- **SPEC-level contradictions surfaced through IMPL audit (not the SPEC audit).** Two contradictions (#1 + #2 above) were caught by the IMPL prompt audit lanes, not by the SPEC audit lane's 8 rounds. The reason: SPEC audit looked at the contract surface in isolation; IMPL audit forced a mechanical check against the executable grant set + concrete nginx semantics, which revealed the inconsistencies. **Lesson: IMPL prompt audits earn their cost even on locked SPECs, because IMPL forces the SPEC's internal cross-references to be mechanically executable.**
- **Same finding from multiple lanes.** The Shape C grant mismatch was caught independently by ARCH r7 C1 and CODE r7-001; the Path R2 waiver was caught by ARCH r6 C2 and CODE r7-003; the auth-failure limiter over-scoping was caught by ARCH r8 C1 and CODE r9 H1; the stats_rollup_state widening was caught by ARCH r10 C1 and CODE r11-001. Cross-lane convergence is a high-confidence signal.
- **Lane conflict resolved by SPEC fidelity.** ARCH r10 C1 told the IMPL prompt to remove `stats_rollup_state` because it widened locked grants. CODE r11-001 confirmed independently. The IMPL prompt reverted to coordinator config — the SPEC remained authoritative.

## Files produced (this convergence loop)

Audit prompts (one per lane, unchanged from prior loop):

- `specs/AUDIT_SPEC_017_IMPL_PROMPT_ARCH_PROMPT.md`
- `specs/AUDIT_SPEC_017_IMPL_PROMPT_CODE_PROMPT.md`
- `specs/AUDIT_SPEC_017_IMPL_PROMPT_SECURITY_PROMPT.md`

Per-round audit files (continuing the v0.1.7-anchor file series):

- ARCH: `specs/SPEC-017-IMPL-PROMPT-arch-r{6..12}-audit.md` (7 rounds)
- CODE: `specs/SPEC-017-IMPL-PROMPT-code-r{7..13}-audit.md` (7 rounds)
- SECURITY: `specs/SPEC-017-IMPL-PROMPT-security-r{4..6}-audit.md` (3 rounds)

This convergence file: `specs/SPEC-017-IMPL-PROMPT-v0_1_8-convergence.md`.

Per-round SPEC audit files (SPEC v0.1.7 → v0.1.8 bump):

- `specs/SPEC-017-r8-audit.md` (v0.1.6 → v0.1.7 lock, Claude critic+designer)
- `specs/SPEC-017-r9-audit.md` (v0.1.8 draft, IMPL-audit-driven)
- `specs/SPEC-017-r10-audit.md` (v0.1.8 lock)

## Implementation kickoff is unblocked

`BUILD_SPEC_017_IMPL_PROMPT.md` at v14 (commit `61e6a14`) is the locked kickoff prompt. A fresh implementation session can paste it and begin Step 1 (schema + DB roles + grant inventory) without further IMPL-prompt audit rounds.

The IMPL prompt no longer carries any unresolved SPEC blockers: the §5.6/AC-8 burst inconsistency that previously blocked Step 4.B is resolved by SPEC v0.1.8; the §9.4 rebuild atomicity is executable under Shape C; the partner-key disclosure gate is split into PR-convergence and cutover-issuance halves. The remaining 3 LOW findings per lane are reference-hygiene only (stale `21 ACs` counts, stale "burst" prose in summary lines, SPEC-006 §17 → §5.4 cross-ref) and were deferred per user instruction.
