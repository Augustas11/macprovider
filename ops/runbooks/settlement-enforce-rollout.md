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
   `settlement:` block). Follow `docs/runbooks/provider-cli-release-verification.md`
   deploy discipline (build from the intended commit, clean `dist/`).
   The Pearl deploy script defaults to **preserving** the live base config, so
   explicitly confirm the base file now carries the `settlement:` block before
   restarting — do not assume the deploy overwrote it.
2. **Validate BEFORE restart** (loads base + overlay exactly as the service does,
   validates, and exits non-zero on any error — a bad merge never reaches a live
   restart):
   ```
   ssh pearl "/opt/macprovider/coordinator \
     --config /opt/macprovider/coordinator.yaml \
     --config-overlay /etc/macprovider/coordinator.pearl-overlays.yaml \
     --validate-config && echo VALIDATE_OK"
   ```
   Then restart: `ssh pearl "sudo systemctl restart macprovider-coordinator"`.
3. **Confirm the EFFECTIVE mode is enforce.** There is no merged-config dump flag
   and the coordinator does not log the mode at boot, so check both layers — the
   overlay wins, so a stale overlay `observe` would silently defeat the base:
   ```
   ssh pearl "echo BASE:;    grep -A1 '^settlement:' /opt/macprovider/coordinator.yaml; \
              echo OVERLAY:; grep -A2 '^settlement:' /etc/macprovider/coordinator.pearl-overlays.yaml || echo '(no settlement stanza in overlay -> base wins)'"
   ```
   Effective mode is `enforce` only if the base shows `enforce` AND the overlay
   has no `verified_model_settlement_mode` overriding it.
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

Overlay keys win over base, so revert to `observe` via the overlay without
touching the deployed binary/base.

**Do NOT `tee -a` a `settlement:` block onto the overlay.** If the overlay
already has a `settlement:` key (or you run the rollback twice), YAML load fails
with `mapping key "settlement" already defined` *before* the coordinator can
start — the rollback would fail closed. Use this idempotent merge instead
(pyyaml 6.0.1 is present on Pearl), which loads the overlay, sets only the one
key, and writes it back atomically — safe to run any number of times:

```bash
ssh pearl 'sudo python3 - <<"PY"
import yaml, os, tempfile
p = "/etc/macprovider/coordinator.pearl-overlays.yaml"
d = yaml.safe_load(open(p)) or {}
d.setdefault("settlement", {})["verified_model_settlement_mode"] = "observe"
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p))
with os.fdopen(fd, "w") as f:
    yaml.safe_dump(d, f, default_flow_style=False, sort_keys=False)
os.replace(tmp, p)            # atomic
print("overlay set settlement.verified_model_settlement_mode=observe")
PY'
# Validate BEFORE restart (never restart on an invalid merge):
ssh pearl "/opt/macprovider/coordinator \
  --config /opt/macprovider/coordinator.yaml \
  --config-overlay /etc/macprovider/coordinator.pearl-overlays.yaml \
  --validate-config && echo VALIDATE_OK"
ssh pearl "sudo systemctl restart macprovider-coordinator"
# Confirm effective mode is now observe (overlay overrides base):
ssh pearl "grep -A2 '^settlement:' /etc/macprovider/coordinator.pearl-overlays.yaml"
```

Trigger rollback if any of: buyer 5xx rate rises, enforce-reject count is
non-trivial (> ~1%), or a new quarantine reason appears on `normal_done`.
Then investigate before re-attempting. Once the base is reverted or the issue is
fixed, remove the `settlement` key from the overlay with the same idempotent
merge (set it back, or `del d["settlement"]`) — never hand-edit to avoid the
duplicate-key trap.

## After a stable window

- Record the outcome in `beta/DECISION_CRITERIA.md`.
- SPEC-016 payout enablement (§9 prereqs) is the next and final step to actual
  USDC — separate change, separate gate.
