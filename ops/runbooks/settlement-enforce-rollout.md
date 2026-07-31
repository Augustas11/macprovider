# Runbook: flip `verified_model_settlement_mode` to `enforce` on Pearl

**Owner:** coordinator / settlement money-path
**Change:** `settlement.verified_model_settlement_mode: observe → enforce`
**Config source:** `phase4-coordinator/dist/coordinator.yaml` (base) → deploys to
`/opt/macprovider/coordinator.yaml` on Pearl. Overlay
`/etc/macprovider/coordinator.pearl-overlays.yaml` is the instant-rollback lever.

## Why now (readiness evidence, 2026-07-31)

`enforce` was unsafe before PR #833 (commit `f9c5db19`) because the coordinator
capped the settlement evidence tuple's `billable_input_tokens` at `len(body)/4`,
quarantining token-dense chat templates on `usage_mismatch`. Post-fix, a live
Pearl DB sweep (`/var/lib/macprovider/coordinator.db`, window ≥ 2026-07-31 05:30 UTC):

| Signal | Result |
|---|---|
| `usage_mismatch` network-wide | **0** (was 59% for Provider #4) |
| `normal_done` receipts verified | **260 / 260 (100%)** — all providers/models |
| Provider #4 (Llama-3.2-3B) | 203 / 203 verified |
| Air5 (Qwen3-8B) | 29 / 29 verified |
| M5 (Qwen3-Coder-30B) | 28 / 28 verified |
| Non-verified receipts | 7 total, all `buyer_cancel`/`provider_error` (nothing to settle) |
| Enforce-dispatch rejection risk | **1 / 267 successful requests (0.4%)** lacked a route snapshot; that path is no-charge/refund, not a user-facing 500 |

Sample caveat: ~267 requests over ~11h, Qwen families only ~30 each; green signal,
not a long soak. The watched-rollout window below closes that gap.

## What `enforce` changes (code: `internal/buyer/route_snapshot.go:44-49`)

1. **Dispatch:** if a route-snapshot prereq fails (missing/invalid provider
   receipt key, provider model identity ≠ signed admission row, or catalog
   material not `HashStatusVerified`), enforce returns an error instead of
   silently skipping. First-attempt `route_snapshot_failed` is treated by the
   gateway as no-charge (reservation refunded, body passed through verbatim —
   no provider billed). Buyers are **not** charged for a rejected dispatch.
2. **Credit upgrade:** the verified-receipt → billable-credit path
   (`internal/billing/settlement_receipts.go:296-360`) requires
   `settled=verified`. Since `normal_done` is 100% verified post-#833, no
   legitimate revenue is lost.

`enforce` alone does **not** move USDC — SPEC-016 payout
(`payout.enabled`, `ledger_payout_ready`) is a separate downstream gate.

## Pre-flight

- [ ] PR merged to `origin/main` (this config change + runbook).
- [ ] 3-lane codex audit (code/security/architect) at 0 C/H/M.
- [ ] Confirm Pearl still shows 0 `usage_mismatch` in the trailing 2h (re-run the
      sweep query below) — do not proceed if a new mismatch source appeared.
- [ ] Note the current running coordinator version/commit for rollback parity.

## Rollout (watched, single window)

1. **Deploy the base config** to Pearl per the coordinator deploy runbook
   (build from the merged commit; `/opt/macprovider/coordinator.yaml` picks up the
   `settlement:` block). Coordinator restart applies it. Follow
   `docs/runbooks/provider-cli-release-verification.md` deploy discipline (build
   from the intended commit, clean `dist/`).
2. **Confirm the mode is live:**
   ```
   ssh pearl "grep -A1 '^settlement:' /opt/macprovider/coordinator.yaml"
   ssh pearl "journalctl -u macprovider-coordinator -n 50 | grep -i settlement"
   ```
3. **Watch for 30–60 min** (fire keep-warm + organic traffic across all models):
   - Buyer-facing errors / 5xx rate on `api.streamvc.live` — must not rise.
   - `route_snapshot_failed` / enforce-reject count — expect ~0.
   - New `usage_mismatch` or other quarantine reasons — expect 0 on `normal_done`.
   - Watch query (run every ~10 min):
     ```sql
     SELECT settlement_outcome, reason, COUNT(*)
     FROM settlement_receipt_verdicts
     WHERE received_at_unix_ms > (strftime('%s','now','-30 minutes')*1000)
     GROUP BY 1,2 ORDER BY 3 DESC;
     ```
4. **Success criteria:** over the window, `normal_done` stays 100% verified,
   enforce-reject stays ≈0, no buyer-visible error increase. Then the flip stands.

## Rollback (instant, no redeploy)

Overlay keys win over base, so revert without touching the deployed binary/base:

```bash
# on Pearl
sudo tee -a /etc/macprovider/coordinator.pearl-overlays.yaml >/dev/null <<'YAML'
settlement:
  verified_model_settlement_mode: observe
YAML
# validate then restart (Pearl launches base + this overlay)
sudo systemctl restart macprovider-coordinator
ssh pearl "journalctl -u macprovider-coordinator -n 30 | grep -i settlement"
```

Trigger rollback if any of: buyer 5xx rate rises, enforce-reject count is
non-trivial (> ~1%), or a new quarantine reason appears on `normal_done`.
Then investigate before re-attempting. Remove the overlay stanza once the base
is reverted or the issue is fixed.

## After a stable window

- Record the outcome in `beta/DECISION_CRITERIA.md`.
- SPEC-016 payout enablement (§9 prereqs) is the next and final step to actual
  USDC — separate change, separate gate.
