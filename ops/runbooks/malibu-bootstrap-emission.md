# Runbook: $MALIBU bootstrap emission (Session C)

**Version:** 0.1  
**Date:** 2026-07-08  
**Audience:** Coordinator billing + Malibu app implementers  
**Session:** **C** — new Cursor session; **money-path PR required** for all ledger changes.  
**Spec:** `docs/notes/SPEC-MALIBU-EMISSION-LEDGER.md`  
**Related:** [`mining-program-bootstrap.md`](./mining-program-bootstrap.md) (Session D), [`opoi-challenge-implementation.md`](./opoi-challenge-implementation.md) (Session A)

---

## 0. Executive path

**Goal:** Accrue **$MALIBU** for early Malibu providers with enforceable sybil defenses before any withdrawable flow.

**Prerequisite narrative (SPEC-026):** Provisional $MALIBU is **non-withdrawable until Trusted**. Per-wallet cap applies across provider_ids.

**Out of scope:** OPoI canary rollout (Session A), proof-of-weights probes (Session B), bootstrap rate policy (Session D).

---

## 1. Preconditions

- [ ] Read SPEC-026 §5.1, §5.2, §10 step 8
- [ ] Operator stance before accrual ticks:
  - **(a) Safest:** no MALIBU flow until ledger ships
  - **(b) Accrual-only:** emit with `withdrawal_hold_reason` on every provisional row
- [ ] OPoI v0 recommended on Pearl before enabling accrual ticks

---

## 2. Phase C1 — Schema + ledger (merged #480)

Ledger schema, emission worker, `rewards_writer` role, migration `012`.

---

## 3. Phase C2 — Trusted unlock (merged #486)

Unlock evaluator, dual-control promotion, migration `014`.

---

## 4. Phase C3 — Malibu app integration (merged #487)

CLI control socket + Malibu app poll `GET /v1/provider/malibu-accrual`.

---

## 5. Phase C4 — Production rollout (ops)

**Runbook:** [`malibu-pearl-deploy.md`](./malibu-pearl-deploy.md)

1. [ ] Operator stance documented (§1)
2. [ ] Deploy migrations 012+014 to Pearl (`coordinator stats-migrate`)
3. [ ] Wire `writer_dsn`; keep `malibu_emission.enabled: false` until §4 verification passes
4. [ ] Promote accrual ticks (`enabled: true`) only after read API + hold enforcement verified
5. [ ] Monitor: `wallet_daily_malibu_emission`, cap hits, unlock rate

---

## 6. Rollback

| Phase | Rollback |
|-------|----------|
| C1 | Stop emission worker; accrual rows frozen |
| C2 | Freeze tier transitions |
| C4 | `malibu_emission.enabled: false` or remove overlay drop-in |

---

*End of runbook.*
