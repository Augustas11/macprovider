# SPEC-026 R9 — 3-lane codex audit results and R10 dispositions

Round 9 fired SEC + ARCH only against SPEC-026 v0.9 (CODE at
PASS since R8, skipped per repo rule).

## R9 totals

| Lane      | C | H | M | L | I |
|-----------|---|---|---|---|---|
| CODE      | *skipped — R8 PASS* |
| SECURITY  | 0 | 0 | 2 | 1 | 0 |
| ARCHITECT | 0 | 0 | 2 | 1 | 0 |
| **Combined R9** | **0** | **0** | **4** | **2** | **0** |

The two lanes converged on the same three issues, so R9's
4 blocking MEDIUMs are really 3 unique findings.

## MEDIUMs closed in v0.10

- **SEC-M1 / ARCH-M1 (Entry 102 email-active wording).** v0.9
  Entry 102 kept a residual "Wallet-swap coercion is defended
  by a REQUIRED out-of-band coordinator-authored email channel"
  sentence and a "Wallet swap MUST fail closed / HMAC-signed
  via LoadCredential" paragraph even though the rest of the
  entry said SPEC-027 owns those. v0.10 deletes both
  active-defense fragments.
- **SEC-M2 / ARCH-M2 (Entry 102 8-step vs 9-step).** v0.9 said
  "ordered, 8 steps: schema → … → Sparkle release" but §10 has
  9 steps with the MALIBU emission stance at step 8. v0.10
  enumerates step 8 explicitly.
- **SEC-L1 (§6.2 vs §9.3 alignment).** v0.9 said "SPEC-026
  makes no normative claim" in §6.2 and "MUST be avoided" in
  §9.3. Different wordings could be read differently. v0.10
  uses the identical MUST NOT wording in both sections.

## LOW addressed

- ARCH-L1 (Entry 102 audit-file inventory): "seven round audit
  files" → "eight round audit files" including
  `SPEC-026-r8-audit.md`.

## R10 plan

Fire SEC + ARCH only (CODE still PASS). If R10 lands 0 C/H/M
across both, freeze v0.10 as merge candidate. Otherwise, if
findings are still Entry-102-only cleanup, one more targeted
pass; if new HIGHs appear against the reduced surface, reassess.
