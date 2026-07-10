# SPEC-026 R6 — 3-lane codex audit results and R7 (post-split) dispositions

Round 6 re-fired all three codex lanes against SPEC-026 v0.6.

## R6 totals

| Lane      | C | H | M | L | I |
|-----------|---|---|---|---|---|
| CODE      | 0 | 0 | 5 | 2 | 0 |
| SECURITY  | 0 | 1 | 1 | 1 | 0 |
| ARCHITECT | 0 | 2 | 2 | 2 | 0 |
| **Combined R6** | **0** | **3** | **8** | **5** | **0** |

Progression across six rounds: **26 → 19 → 22 → 18 → 12 → 11**
blocking; HIGHs `9 → 5 → 4 → 7 → 1 → 3`.

## The turning finding

**ARCH HIGH-2 (spec scope too large).** Six rounds of audit
progressively tightened the spec but also grew its surface area:
identity + register + auth-policy + verified-email channel +
GET/POST cancel + SPEC-016 addendum + Postgres projection + WAL
replication + rewards-ledger extension + per-wallet aggregate.
Each subsystem introduced attack surface for the next round.
R6 architect explicitly said: split.

**Decision.** v0.7 accepts the split. SPEC-026 shrinks to
App-track identity + `/register` + `provider_auth_policy` +
sybil-defense narrative + App Attest + migration matrix. Three
follow-up SPECs own the moved-out surface:

- **SPEC-016 §3 addendum** — `provider_wallet_swaps` state
  machine + atomic commit into `provider_payout_addresses`.
  Owned by SPEC-016 team.
- **SPEC-027 (App-track wallet-swap coercion defense)** —
  everything R4/R5/R6 introduced around the email out-of-band
  channel: `notification_email`, `provider_email_change_requests`,
  `malibu-app://` scheme, three-path channel-authority transfer,
  GET/POST cancel split, EIP-712 `EmailChangeAuthorization`
  domain, fresh-install re-ratification. The R6 SEC HIGH
  (opaque-hash EIP-712 display) and ARCH HIGH-1 ("currently-bound
  wallet" ambiguity during in-flight rotation) are inherited by
  SPEC-027, MUST be closed there before SPEC-027 merges.
- **SPEC-028 (MALIBU rewards emission ledger)** —
  `provider_rewards_ledger` MALIBU extension,
  `wallet_daily_malibu_emission` aggregate under SERIALIZABLE,
  `provider_emission_state` cross-track table, Postgres
  projection of SPEC-016 `provider_payout_addresses`, WAL
  replication worker + staleness monitoring, replay-through-cap.
  The R6 CODE MEDIUMs about WAL not being row-level CDC and
  wrong staleness measurement carry over to SPEC-028.

## What SPEC-026 v0.7 still covers

Same as v0.6 minus the extracted surface. Key remaining
sections:
- §0-3: terminology, goal, identity model (unchanged)
- §4.1: `POST /v1/providers/register` (unchanged from v0.6)
- §4.2: Payout binding delegates to SPEC-016 §3 (unchanged)
- §4.3: proof-stage `identity_signature` + cross-track
  `provider_auth_policy` (v0.6 shape, all fixes preserved)
- §4.4: portal OAuth retirement
- §4.5: **new pointer** to SPEC-027 for the wallet-swap
  coercion defense
- §5: Sybil resistance narrative + Trust unlock criteria
  (economic + additional). Enforcement primitives now say
  "deferred to SPEC-028."
- §6: user flow (unchanged from v0.6)
- §7: Swift impl (unchanged from v0.6; malibu-app:// scheme
  registration moves to SPEC-027)
- §8: migration matrix (unchanged)
- §9: recovery / multi-Mac / **§9.3 pointer** to SPEC-027 /
  §9.4 lost-wallet
- §10: deploy checklist trimmed to Phase 1a schemas for
  identity + register + auth-policy only. SPEC-027 and SPEC-028
  own their own deploy gates.
- §11: sybil risk narrative
- §12: AC (subset - all AC-026-XX tests that don't depend on
  moved-out surface stay; wallet-swap notification ACs move
  to SPEC-027)
- §13: open questions

## R7 plan

Fire all three lanes against v0.7. If R7 lands 0 C/H/M against
the reduced surface → push → PR ready to merge. The findings
that carried over to SPEC-027 / SPEC-028 are documented above
and start those specs' own audit backlogs.
