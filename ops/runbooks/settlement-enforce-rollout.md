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
| Enforce-dispatch rejection risk | **1 / 267 successful requests (0.4%)** lacked a route snapshot; that path is no-charge/refund but the buyer may see a transient HTTP 500 |

Sample caveat: ~267 requests over ~11h, Qwen families only ~30 each; green signal,
not a long soak. The watched-rollout window below closes that gap.

## What `enforce` changes (code: `internal/buyer/route_snapshot.go:44-49`)

1. **Dispatch:** if a route-snapshot prereq fails (missing/invalid provider
   receipt key, provider model identity ≠ signed admission row, or catalog
   material not `HashStatusVerified`), enforce returns an error instead of
   silently skipping. First-attempt `route_snapshot_failed` is treated by the
   gateway as no-charge (reservation refunded, body passed through verbatim, but
   the buyer may see a transient HTTP 500 —
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

**Step 1 — Install the `settlement:` block into the live Pearl base config.** The
tracked `phase4-coordinator/dist/coordinator.yaml` is the reviewed source of
truth (and any future clean deploy carries it), but `deploy-pearl-vps.sh`
defaults to `preserve-live` and its `apply-tracked` mode **aborts on tracked/live
base drift** — which already exists — so a normal deploy will NOT push this
one-field change. Use the idempotent base merge below, which preserves the live
file's owner/group/mode (same shape as the rollback, safe to re-run). The heredoc
body must stay column-aligned as shown (unindented) — Python is whitespace-sensitive:

```bash
ssh pearl 'sudo python3 - <<"PY"
import yaml, os, stat, tempfile
p = "/opt/macprovider/coordinator.yaml"
st = os.stat(p)
d = yaml.safe_load(open(p)) or {}
d.setdefault("settlement", {})["verified_model_settlement_mode"] = "enforce"
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p))
os.fchown(fd, st.st_uid, st.st_gid); os.fchmod(fd, stat.S_IMODE(st.st_mode))
with os.fdopen(fd, "w") as f:
    yaml.safe_dump(d, f, default_flow_style=False, sort_keys=False)
os.replace(tmp, p)
print("base set settlement.verified_model_settlement_mode=enforce")
PY'
```

**Step 2 — Validate BEFORE restart** (loads base + overlay exactly as the service
does, validates, exits non-zero on any error — a bad merge never reaches a live
restart). Validation MUST run as the `macprovider` service user WITH the service
env file sourced, or it fails on unresolved `env:OPERATOR_KEY` (the coordinator
resolves `env:` refs from `/etc/macprovider/coordinator.env`, loaded by the
unit's `EnvironmentFile`):

```bash
ssh pearl 'sudo -u macprovider bash -lc "set -a; . /etc/macprovider/coordinator.env; set +a; \
  /opt/macprovider/coordinator \
    --config /opt/macprovider/coordinator.yaml \
    --config-overlay /etc/macprovider/coordinator.pearl-overlays.yaml \
    --validate-config && echo VALIDATE_OK"'
ssh pearl "sudo systemctl restart macprovider-coordinator"
```

**Step 3 — Confirm the EFFECTIVE mode is enforce.** There is no merged-config
dump flag and the coordinator does not log the mode at boot, so check both layers
— the overlay wins, so a stale overlay `observe` would silently defeat the base:

```bash
ssh pearl "echo BASE:;    grep -A1 '^settlement:' /opt/macprovider/coordinator.yaml; \
           echo OVERLAY:; grep -A2 '^settlement:' /etc/macprovider/coordinator.pearl-overlays.yaml || echo '(no settlement stanza in overlay -> base wins)'"
```

Effective mode is `enforce` only if the base shows `enforce` AND the overlay has
no `verified_model_settlement_mode` overriding it.

**Step 4 — Watch for 30–60 min** (keep-warm + organic traffic across all models):
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

**Success criteria:** over the window, `normal_done` stays 100% verified,
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
import yaml, os, stat, tempfile
p = "/etc/macprovider/coordinator.pearl-overlays.yaml"
st = os.stat(p)                                   # preserve owner/group/mode
d = yaml.safe_load(open(p)) or {}
d.setdefault("settlement", {})["verified_model_settlement_mode"] = "observe"
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p))
os.fchown(fd, st.st_uid, st.st_gid)               # keep root:macprovider ...
os.fchmod(fd, stat.S_IMODE(st.st_mode))           # ... and 0640 (mkstemp is 0600 root:root)
with os.fdopen(fd, "w") as f:
    yaml.safe_dump(d, f, default_flow_style=False, sort_keys=False)
os.replace(tmp, p)                                # atomic
print("overlay set settlement.verified_model_settlement_mode=observe")
PY'
# Validate BEFORE restart (as the service user, with env sourced — never
# restart on an invalid merge, and note plain root/no-env validation fails on
# env:OPERATOR_KEY):
ssh pearl 'sudo -u macprovider bash -lc "set -a; . /etc/macprovider/coordinator.env; set +a; \
  /opt/macprovider/coordinator \
    --config /opt/macprovider/coordinator.yaml \
    --config-overlay /etc/macprovider/coordinator.pearl-overlays.yaml \
    --validate-config && echo VALIDATE_OK"'
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

## Base blast radius (non-Pearl deployments)

The `settlement:` block lives in the base `dist/coordinator.yaml`, so any OTHER
deployment that layers an overlay on this base and does not itself set
`settlement.verified_model_settlement_mode` inherits `enforce`. Committed
OPoI / Malibu-emission / PoW staging overlays currently do not set it. This is
harmless to Pearl and to any environment whose providers are settlement-capable,
but a staging/local environment with non-settlement-capable providers would see
pre-dispatch `route_snapshot_failed` (buyer-visible transient 500) until it opts
out with `settlement: { verified_model_settlement_mode: observe }` in its overlay.

## After a stable window

- Record the outcome in `beta/DECISION_CRITERIA.md`.
- SPEC-016 payout enablement (§9 prereqs) is the next and final step to actual
  USDC — separate change, separate gate.
