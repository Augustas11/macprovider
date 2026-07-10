# SPEC-026 R5 — 3-lane codex audit results and R6 dispositions

Round 5 re-fired all three codex lanes against SPEC-026 v0.5.

## R5 totals

| Lane      | C | H | M | L | I |
|-----------|---|---|---|---|---|
| CODE      | 0 | 0 | 6 | 1 | 0 |
| SECURITY  | 0 | 1 | 1 | 3 | 2 |
| ARCHITECT | 0 | 0 | 4 | 4 | 3 |
| **Combined R5** | **0** | **1** | **11** | **8** | **5** |
| R4 combined | 0 | 7 | 11 | 3 | 1 |
| R3 combined | 0 | 4 | 18 | 3 | 2 |

Closest yet. Progress across rounds:
`R1 26 → R2 19 → R3 22 → R4 18 → R5 12` blocking findings.
HIGHs: `9 → 5 → 4 → 7 → 1`.

## HIGH closed in v0.6

- **SEC-1 (§9.3 fresh-install email durable authority).** v0.5's
  fresh-install `confirm` transferred email authority directly.
  Attacker with bearer+identity on a fresh Mac could set their
  email, confirm, and remain authoritative even after the honest
  user later bound a wallet or accrued exposure. v0.6 introduces
  `email_authority_state` on the pending-email row with a
  `fresh_install_ratification_pending` state that MUST re-ratify
  via current-wallet EIP-712 at first wallet bind or first swap
  ≥ $500. Until ratified, the email cannot cancel high-value
  swaps.

## MEDIUMs closed in v0.6

- **CODE-M1 (§2 grounding still says initial-stage):** rewritten
  to describe the two-frame v2 handshake and place
  `identity_signature` on proof-stage.
- **CODE-M2 / ARCH-M3 (`malibu-app://` scheme not registered):**
  v0.6 §7.3 adds an explicit `CFBundleURLTypes` snippet + host
  routing table. `malibu://` remains retired.
- **CODE-M3 (`provider_email_change_requests` DDL missing):**
  v0.6 §10 Phase 1a lists the DDL.
- **CODE-M4 (`approved_by != requested_by` UNIQUE mechanism):**
  v0.6 uses a Postgres `CHECK` constraint on
  `provider_auth_policy_pending`.
- **CODE-M5 (`cap_replay_pending` on App-track-only table):**
  moved to cross-track `provider_emission_state` table.
- **CODE-M6 / ARCH-M2 (Entry 102 stale):** rewritten to v0.6
  including R4/R5 dispositions, three-path transfer,
  `provider_emission_state`, Postgres projection, `malibu-app://`
  scheme.
- **ARCH-M1 (§4.6 SPEC-016 addendum shape under-specified):**
  full `provider_wallet_swaps` DDL and state transitions
  spelled out.
- **ARCH-M2 (§5.1 Postgres/SQLite consistency):** Postgres
  `provider_payout_addresses_projection` with replication
  worker off SQLite WAL; 60s staleness alert.
- **ARCH-M4 (AC-026-12 stale column name + missing CLI-track):**
  rewritten to cover cross-track policy row semantics and both
  App-track and new CLI-track signature verification against
  their respective pubkey sources.
- **ARCH-M-LOW (EIP-712 domain shape underspecified):** full
  `EIP712Domain { name, version, chainId, verifyingContract }`
  and `EmailChangeAuthorization` primary type spelled out.
- **v0.5 changelog contradiction:** fixed the "v0.4 invented
  `.installed-by-app`" sentence to name `.malibu-owned` as the
  wrong v0.4 marker.

## LOW/INFO carry-forward or fixed inline

- SEC-L1 (§4.3 break-glass rotation cost): spec now recommends
  security-owner approval + postmortem link on break-glass path;
  full definition deferred to a follow-up ops runbook (accepted
  as LOW).
- SEC-L2 (§4.6 CSRF token TTL): spec now requires `CSRF token
  TTL <= min(URL exp, remaining cooling window)` bound to
  `swap_id`, single-use, invalidated on POST / swap state
  change / expiry.
- SEC-L3 (§4.6 observability flood on GET scans): spec adds
  dedupe by `swap_id` and source class; don't page on
  confirm-viewed volume alone.
- SEC-INFO (residual risk on old-email compromise):
  documented in §9.3.
- ARCH-L1 (§10 Phase 1a/1b ordering wording): §10 step 1 now
  says "Phase 1a schema only" and §10 step 7 explicitly runs
  Phase 1b seeding at cutover.
- ARCH-L2 (SPEC-025 §7 back-reference): v0.6 notes that
  SPEC-025 §7 needs an update in a follow-up PR to point at
  §8.4; this SPEC-026 PR does not modify SPEC-025.

## R6 plan

- Fire all three lanes against v0.6.
- If R6 lands 0 C/H/M → freeze v0.6 → push → PR ready to merge.
- Otherwise assess: if the remaining findings are still all
  cleanly targeted, R7; if not, accept-and-carry-forward with
  documented open items.
