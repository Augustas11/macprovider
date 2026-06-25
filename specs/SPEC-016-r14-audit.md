# SPEC-016 v0.1.12 Codex Round 14 audit

**Audit target:** `specs/SPEC-016-payout-pipeline.md` v0.1.12 at commit `4ad3e1a` on branch `spec/016-payout-pipeline-v0.1`.
**Auditor:** codex (via `/ask codex` per [[feedback-codex-only-audits]]).
**Fix pass:** v0.1.13.
**Date:** 2026-06-25.

---

## Codex verdict

Not converged. Verdict: 0 CRITICAL, 1 MAJOR, 0 MEDIUM, plus the 4 known deferred LOWs.

**MAJOR-1 — Cancel self-transfer rows can be treated as provider payout attempts**

File: [SPEC-016-payout-pipeline.md](/Users/augstar/macprovider-poc-spec016/specs/SPEC-016-payout-pipeline.md:1885)

Issue: §4.3 step 5 says to “Load any non-abandoned `payout_attempts` row” and if it is “confirmed-and-non-abandoned, jump to step 8.” But §4.6 inserts non-abandoned `is_cancel_self_transfer=1` rows for abandon recovery, and §4.3 step 8 then calls `ClaimPayoutReady`. A cold IMPL could confirm the hot-wallet self-transfer, then consume the provider’s `ledger_payout_ready` row using the cancel tx hash even though the provider was not paid.

Attacker/confusion path: compromised operator key, or a mistaken operator, stops the runner and calls `/admin/payout/abandon-attempt` with `broadcast_cancel_self_transfer=true`. The cancel row confirms. On the next cycle, literal §4.3 step 5 loads the confirmed non-abandoned cancel row and jumps to step 8. Reconciliation won’t clearly catch it because §7.4 excludes `is_cancel_self_transfer=1` rows from payout/outflow sums at lines 4093-4095 and 4131-4135.

Paste-ready fix wording:

```md
In §4.3 step 5, provider-payout attempt lookup MUST filter to
`abandoned_at_utc IS NULL AND is_cancel_self_transfer = 0`.
Cancel self-transfer rows (`is_cancel_self_transfer = 1`) are nonce-gap
recovery records only; they MUST NEVER advance to §4.3 step 8 and MUST
NEVER be passed to `ClaimPayoutReady`.

Before allocating a fresh non-cancel attempt after an abandon, the runner
MUST separately handle any live cancel self-transfer row for the same
`payout_id`: if unconfirmed, rebroadcast/poll the persisted cancel bytes
using cancel-specific verification (`from_address = to_address =
payout.security.hot_wallet_address`, `amount_base_units = 1`) and halt
fresh payout allocation until the cancel confirms or operator resolves the
gap. If confirmed, the nonce gap is filled; the runner may then allocate a
fresh non-cancel attempt with a new nonce. Confirmed cancel rows remain
audit/gas records only and do not consume `ledger_payout_ready`.
```

Round-13 closure checks passed: §4.6 now gates the abandon `UPDATE` on `confirmed_at_utc IS NULL AND abandoned_at_utc IS NULL`, disambiguates zero-row results into 404/409 bodies, and gates cancel-row insertion to exactly one live unconfirmed non-abandoned row.

Hygiene checks: markdown fences are balanced, `git diff --check` is clean, no revived `§9.6` references found, and the 4 known round-11 LOWs remain explicitly deferred.

---

## Cross-reference

- Raw codex CLI artifact (full prompt + transcript):
  `.omc/artifacts/ask/codex-audit-spec-016-v0-1-12-commit-4ad3e1a-branch-spec-016-payout-2026-06-25T05-05-11-507Z.md`
- Fix pass commit message: see `git log 4ad3e1a..HEAD --oneline -- specs/SPEC-016-payout-pipeline.md`
  for the v0.1.13 commit that absorbed these findings.
- Audit-loop discipline: [[feedback-spec-audit-loop-before-pr]] + [[feedback-codex-only-audits]].
