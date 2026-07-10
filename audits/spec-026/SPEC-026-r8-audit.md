# SPEC-026 R8 — 3-lane codex audit results and R9 dispositions

Round 8 against v0.8 was the first round to land 0 HIGH after
seven prior rounds. 5 MEDIUM total.

## R8 totals

| Lane      | C | H | M | L | I |
|-----------|---|---|---|---|---|
| CODE      | 0 | 0 | 0 | 2 | 0 |
| SECURITY  | 0 | 0 | 2 | 1 | 0 |
| ARCHITECT | 0 | 0 | 3 | 1 | 2 |
| **Combined R8** | **0** | **0** | **5** | **4** | **2** |

Progression:
`R1 26 → R2 19 → R3 22 → R4 18 → R5 12 → R6 11 → R7 12 → R8 5`.

**CODE lane at PASS 0/0/0** — per repo rule
[feedback-skip-accepted-audit-lanes], CODE does not need to
re-fire in R9 unless subsequent fixes touch CODE-scoped
concerns.

## MEDIUMs closed in v0.9

- **ARCH-M1 (§6.1 step 7j opens EIP-712 signing inline).** v0.9
  removes the optional wallet field from the launch window and
  removes step 7j. Wallet binding lives only on the post-success
  card / dashboard "Add wallet" affordance.
- **ARCH-M2 (§9.3 pre-SPEC-027 Cancel action).** v0.9 removes the
  Cancel-action bullet; only read-only display of a pending swap
  is acceptable. In-app Cancel MUST NOT be added before SPEC-027.
- **ARCH-M3 (Entry 102 stale email-active wording).** v0.9 Entry
  102 reformulates every moved-out primitive as
  "SPEC-027 will own …". No active-defense wording remains.
- **SEC-M1 (AC missing for bearer-proof mechanic).** v0.9 adds
  AC-026-16 covering three duplicate-register scenarios.
- **SEC-M2 (Entry 102 8-step vs 9-step).** v0.9 updates to
  9-step + explicit MALIBU-until-SPEC-028 gate wording.

## LOW addressed inline

- ARCH-L1 (v0.7/8-step labels stale): §10 step 1 label bumped
  to v0.9; Entry 102 fixed.
- CODE-L: no change required (both LOWs were style-level).
- SEC-L: same as ARCH-M3 (Entry 102 wording).

## R9 plan

Fire SEC + ARCH only (CODE at PASS). If R9 lands 0 C/H/M on
both, freeze v0.9 as merge candidate. Otherwise one more
targeted round.
