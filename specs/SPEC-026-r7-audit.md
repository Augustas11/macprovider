# SPEC-026 R7 — 3-lane codex audit results and R8 dispositions

Round 7 fired against SPEC-026 v0.7 (the R6 scope-reduction pass).

## R7 totals

| Lane      | C | H | M | L | I |
|-----------|---|---|---|---|---|
| CODE      | 0 | 1 | 4 | 0 | 0 |
| SECURITY  | 0 | 1 | 1 | 1 | 2 |
| ARCHITECT | 0 | 2 | 3 | 2 | 0 |
| **Combined R7** | **0** | **4** | **8** | **3** | **2** |

Progression: `R1 26 → R2 19 → R3 22 → R4 18 → R5 12 → R6 11 → R7 12`.

The scope reduction closed the "spec too big" ARCH HIGH from R6
but introduced text drift (AC-026-06 still described email flow,
§7.3 still required registering `malibu-app://`, §6.2 still
described pending-swap Cancel UI). v0.8 sweeps that drift and
fixes a real CODE HIGH (rotate-on-duplicate HMAC using cleartext
token as key when only `token_hash` is stored).

## HIGHs closed in v0.8

- **CODE-1 (§4.1 `current_token_proof` HMAC unverifiable).**
  Coordinator can't recompute HMAC without the cleartext token,
  which the store doesn't retain. v0.8 requires the raw bearer
  via `Authorization: Bearer` header OR body field; coordinator
  SHA-256 hashes and compares against `token_hash`.
- **ARCH-1 (AC-026-06 requires moved-out email flow).** v0.8
  rescopes AC-026-06 to SPEC-016 preservation only; email
  channel ACs live in SPEC-027.
- **ARCH-2 (§7.3 requires `malibu-app://` registration).** v0.8
  deletes the requirement; SPEC-027 owns any deep-link scheme.
- **SEC-1 (production MALIBU before SPEC-028 = sybil vector).**
  v0.8 §10 step 8 gates the App flag flip on either SPEC-028
  shipping OR an operator hold mode that prevents withdrawable
  MALIBU. §11 gets a "prerequisite" qualifier.

## MEDIUMs closed in v0.8

- **CODE-M1 (§4.1 SQLite `SELECT ... FOR UPDATE`).** Replaced
  with `BEGIN IMMEDIATE` + partial unique index.
- **CODE-M2 (§4.3 version field type).** `"version": "2"` (string)
  → `"version": 2` (int) to match SPEC-001 v1.6 §6.7.
- **CODE-M3 (Entry 102 stale).** Rewritten for v0.8 with
  SPEC-027 / SPEC-028 pointers.
- **ARCH-M1 (§6.2 pending-swap UI backend contract missing).**
  v0.8 §6.2 defers UI to SPEC-027; no SPEC-026 normative claim.
- **ARCH-M2 (§10 no MALIBU gate).** Same as SEC-1.
- **SEC-M1 (App-track wallet coercion before SPEC-027).**
  v0.8 §9.3 already stated this as accepted risk; Entry 102
  updated to match.

## LOW / INFO addressed inline

- ARCH-L1 (§8.4 AC-026-15 missing): AC-026-15 added for the
  import dialog outcomes.
- ARCH-L2 (§1.2 wallet-signing wording ambiguity): reworded to
  "wallet-signing UX DURING onboarding is a non-goal;
  post-onboarding wallet binding IS supported via SPEC-016 §3."
- SEC-L1 (Entry 102 wallet-swap description drift): rewritten.
- SEC-INFO / CODE-INFO: no change required.

## R8 plan

Fire all three lanes against v0.8. If R8 lands 0 C/H/M against
the reduced scope with SPEC-027 / SPEC-028 pointers, freeze
v0.8 as the merge candidate. Otherwise, one more targeted round
or accept-and-carry-forward.
