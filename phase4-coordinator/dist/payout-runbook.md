# Payout pipeline operator runbook (SPEC-016 v0.1.21)

This document is the cutover checklist + day-2 operations
guide for the SPEC-016 USDC-on-Base payout pipeline. Every
section maps to a normative SPEC §; this file is **operational
narrative**, the SPEC body is the source of truth on contract.

> **Read order for first-time deploy.**
>
> 1. §1 Hot wallet provisioning + funding (this doc)
> 2. §2 Cap-decision worksheet (this doc, mirrors SPEC §9.3)
> 3. §3 BetterStack synthetic-alert verification (SPEC §9.7
>    prereq item 6 — required BEFORE cutover)
> 4. §4 Cutover sequence (this doc, mirrors SPEC §9 cutover)
> 5. Day-2: §5 key-rotation runbook (SPEC §6.4 steps 1–5)
> 6. Day-2: §6 SPKI pin rotation (when rotating RPC endpoint certificates)
> 7. Day-2: §7 weekly reconciliation (SPEC §7.4 queries A–F)

---

## 1. Hot wallet provisioning + funding (SPEC §9.1 + §6.1)

### 1.1 Generate a fresh hot wallet

The hot wallet is the secp256k1 keypair that signs payout
transactions. It **MUST** be generated offline on a clean
machine; never paste a key from a chat client or copy across
the network.

```bash
# On a dedicated, network-isolated machine:
# 1. Generate the keypair.
openssl ecparam -genkey -name secp256k1 -noout -out /tmp/payout.key
# 2. Derive the EIP-55 checksummed address.
PUBKEY=$(openssl ec -in /tmp/payout.key -pubout -outform der \
  | tail -c +24 | xxd -p -c 65)
# (then derive address via keccak256 of the uncompressed pubkey;
# any reputable offline tool — etherwallet, mycrypto, ethers.js
# in an air-gapped node — produces the EIP-55 form)
```

Record the address in `dist/coordinator.yaml`:

```yaml
payout:
  security:
    hot_wallet_address: "0x<EIP-55 checksummed>"
```

### 1.2 Encrypt the wallet with the KEK

The on-disk wallet file is AES-256-GCM encrypted; the KEK is
supplied at runtime via systemd LoadCredential (preferred) or
the `MACPROVIDER_PAYOUT_WALLET_KEK` env var.

```bash
# Generate a fresh 32-byte KEK on the same offline machine.
KEK=$(openssl rand -hex 32)
# Encrypt the wallet bytes with AES-256-GCM (use the helper at
# phase4-coordinator/scripts/encrypt-payout-wallet.sh OR any
# vetted AES-GCM tool with a fresh 12-byte nonce per file).
```

Transfer ONLY the encrypted file to the coordinator host.
The KEK is loaded via systemd credentials at boot; the
plaintext key file MUST be destroyed on the offline machine
immediately after encryption (`shred -u` or equivalent).

### 1.3 First-time funding

After the encrypted wallet is deployed AND `payout.enabled: false`
is still in effect, fund the hot wallet from a treasury wallet:

```
# Send a small initial amount (e.g. $50 USDC) to verify the chain
# works end-to-end before scaling up. RECORD the tx_hash.
```

Then call the §4.9 record-funding admin endpoint in
**source='manual'** mode (only legal during the bootstrap
window, before the first confirmed payout flips
`payout_bootstrap_complete=1`):

```bash
curl -X POST https://coordinator.streamvc.live/admin/payout/record-funding \
  -H "Authorization: Bearer <operator_key>" \
  -H "Idempotency-Key: <tx_hash>" \
  -H "Content-Type: application/json" \
  -d '{
    "from_address":   "<treasury wallet, EIP-55>",
    "to_address":     "<hot wallet, EIP-55>",
    "amount_base_units": 50000000,
    "tx_hash":        "<tx_hash from chain>",
    "block_number":   <block number>,
    "source":         "manual",
    "operator_note":  "initial funding"
  }'
```

After bootstrap (first confirmed payout), `source='manual'` is
**permanently forbidden**; subsequent funding records MUST use
`source='rpc-confirmed'` which two-RPC-verifies the receipt at
endpoint time.

---

## 2. Cap-decision worksheet (SPEC §5 + §9.3)

The four security caps are runtime-immutable. Pick conservatively
on first cutover; widening later requires a config edit + process
restart (NOT SIGHUP).

| Key | Default | Sizing guidance |
|-----|---------|-----------------|
| `per_payout_cap_usdc_base_units` | $500 (`500_000_000`) | Largest single payout you can afford to lose to a single-tx mishap. |
| `per_day_cap_usdc_base_units` | $5,000 (`5_000_000_000`) | Daily blast radius if the operator key is compromised. |
| `cancel_max_gas_native_wei` | 0.005 ETH | Single-cancel gas ceiling. Base sustained > 1 gwei is rare. |
| `cancel_max_gas_native_wei_per_24h` | 0.02 ETH | Rolling-24h cancel-gas budget; throttles DoS by burning operator gas via cancel spam. |

**`low_balance_threshold` constraint** (§6.5 cross-field bound):
must be `<= 2 × per_day_cap`. Set to `1 × per_day_cap` so the
WARN fires when ~1 day of headroom remains.

---

## 3. BetterStack synthetic-alert verification (SPEC §9.7 prereq)

Before flipping `payout.enabled: true`, verify EVERY §7.1
PAGE/WARN event fires a BetterStack alert (per SPEC §9 item 6,
the canonical event list lives at
`specs/SPEC-016-payout-pipeline.md` §9 item 6 — re-derive at
deploy time). The synthetic-alert harness lives at
`dist/synthetic-alerts/` (test fixtures only; never fire against
production).

Required PAGE-class events (test each by hand on a staging
coordinator):

- `payout_chain_balance_drift_negative`
- `payout_chain_balance_rpc_disagreement` (chain-balance worker; r3 rename from `payout_rpc_disagreement`)
- `payout_runner_lease_lost`
- `payout_runner_lease_taken_over`
- `payout_runner_lease_left_to_stale_out`
- `payout_invariant_violation` (e.g. `bootstrap_trigger_missing`)
- `payout_registration_paused`
- `payout_registration_resumed`
- `payout_reorg_orphan_recorded`
- `payout_cancel_self_transfer_reconfirm_stale`
- `payout_config_reloaded` / `payout_config_reload_rejected`
- `payout_rpc_chronic_outage` (NEW v0.1.22 — chronic single-RPC outage detector)

Required WARN-class events (also verified per §9 item 6):

- `payout_stale_outbox_backlog` (NEW v0.1.22 — §4.7 step 5 production capped; escalates to PAGE when `scan_ceiling_hit=true`)
- `payout_spki_drain_skipped_unsupported_client` (NEW v0.1.22 — verify SEPARATE synthetic alert per `rpc_label` value: `primary` AND `secondary`)
- `payout_stale_outbox_reaped`
- `payout_flag_audit_reaped`
- `payout_low_balance` / `payout_low_native_balance`
- `payout_nonce_gap`
- `provider_payout_address_change_rejected`
- `provider_payout_address_rejected_unknown_provider`

For each: pre-trigger the underlying state in staging, watch
BetterStack receive the alert within 60s, and tick the
prereq checklist in your local DEPLOY_LOG.

---

## 4. Cutover sequence (SPEC §9 cutover)

Run on the production coordinator host, in order:

1. ✅ All §9.1–§9.6 prereqs ticked in DEPLOY_LOG.
2. ✅ §3 BetterStack synthetic-alert verification complete.
3. ✅ `dist/check-deploy-config.sh dist/coordinator.yaml` exits 0
   (the §6.5 deploy gate; see also
   [[c2-gate-resolves-env-indirected-secrets]]).
4. ✅ Hot wallet funded ≥ `per_day_cap`, first manual
   record-funding written, no confirmed payouts yet.
5. Edit `dist/coordinator.yaml`: `payout.enabled: true`.
6. `systemctl restart macprovider-coordinator`.
7. Within 30s, check journalctl for:
   - `payout_run_started` — runner cycle began.
   - `payout_runner_lease_taken_over` is NOT present
     (would indicate a stale prior process).
   - `payout_low_balance` is NOT present (would indicate
     under-funding).
8. After the FIRST confirmed payout (watch journalctl for
   `payout_attempt_confirmed`), verify
   `payout_bootstrap_complete = 1` in DB:
   ```bash
   sqlite3 /var/lib/macprovider/coordinator.db \
     "SELECT payout_bootstrap_complete FROM payout_runner_state WHERE id=1;"
   ```
9. Tick "payout pipeline LIVE" in DEPLOY_LOG.

---

## 5. Key-rotation runbook (SPEC §6.4 steps 1–5)

When rotating the hot wallet (compromise, scheduled rotation,
or moving keys to new hardware), follow these steps **in
order**. Do NOT shortcut.

### Step 1 — Pause registration

```bash
curl -X POST https://coordinator.streamvc.live/admin/payout/pause-registration \
  -H "Authorization: Bearer <operator_key>" \
  -d '{"reason": "scheduled hot wallet rotation"}'
```

The §3.3 provider-payout-address endpoint now returns 503
`rotation_in_progress`; the runtime_flags.registration_paused
row persists across restart (SPEC §4.8a).

### Step 2 — Drain in-flight payouts

Wait for `payout_run_finished` events to show `paid=0,
failed=0, capped=0` for ≥ 2 consecutive cycles (i.e.
`2 × run_interval`). This proves no payout is mid-flight.

### Step 3 — Disable the runner

Edit `dist/coordinator.yaml`: `payout.enabled: false`. Then
`systemctl restart macprovider-coordinator`. The runner shuts
down cleanly; the lease is released.

### Step 4 — Swap the wallet

1. Generate the new hot wallet per §1.1.
2. Encrypt with a NEW KEK per §1.2 (do NOT reuse the old KEK).
3. Replace `hot_wallet_address` + `encrypted_wallet_path` in
   `dist/coordinator.yaml`.
4. Update the systemd credential `payout-wallet-kek`.
5. Fund the new wallet (transfer from old hot wallet,
   record-funding the inbound tx; manual mode is forbidden
   post-bootstrap, so use `source='rpc-confirmed'`).

### Step 5 — Resume

```bash
# Re-enable + restart.
sed -i 's/payout.enabled: false/payout.enabled: true/' dist/coordinator.yaml
systemctl restart macprovider-coordinator

# Resume the §3.3 surface.
curl -X POST https://coordinator.streamvc.live/admin/payout/resume-registration \
  -H "Authorization: Bearer <operator_key>" \
  -d '{"reason": "wallet rotation complete"}'
```

Verify provider payout addresses still resolve to the
correct downstream wallets via §7.3:

```bash
curl https://coordinator.streamvc.live/providers/<id>/payouts \
  -H "Authorization: Bearer <provider_token>"
```

---

## 6. SPKI pin rotation (SPEC §6.5 / [arch:r3-4.2])

The two RPC clients (primary + secondary) use TLS SPKI pinning.
The pinned SHA-256 fingerprint is reloadable at runtime via SIGHUP;
no process restart is required.

### When to rotate

- Planned certificate rotation on the RPC endpoint.
- Vendor notice of upcoming certificate change.
- Any incident where the RPC endpoint certificate is replaced.

### Steps

1. Obtain the new certificate's SPKI SHA-256 fingerprint as a
   **64-hex-character string** (the implementation validates exactly
   64 hex chars; base64 will be rejected):
   ```bash
   # From the DER-encoded cert on disk — outputs 64 hex chars:
   openssl x509 -in new_rpc_cert.pem -pubkey -noout \
     | openssl pkey -pubin -outform DER \
     | openssl dgst -sha256
   # Example output: SHA2-256(stdin)= a1b2c3...64hexchars
   # Copy the hex string (64 characters after the '= ').
   ```
   Cross-reference: `specs/SPEC-016-payout-pipeline.md` §6.5 (line 3654)
   specifies 64-hex-char SHA-256; base64 encoding is NOT accepted.
2. Update `dist/coordinator.yaml`:
   ```yaml
   payout:
     tuning:
       rpc_url_primary_pin_spki:   "<new 64-hex-char SHA-256 SPKI>"
       rpc_url_secondary_pin_spki: "<new 64-hex-char SHA-256 SPKI>"
   ```
3. Send SIGHUP to the coordinator process:
   ```bash
   kill -HUP "$(systemctl show -p MainPID --value macprovider-coordinator)"
   ```
4. Watch journalctl for `payout_config_reloaded` events with
   `key=payout.tuning.rpc_url_primary_pin_spki` and
   `key=payout.tuning.rpc_url_secondary_pin_spki` to confirm
   the reload was accepted.
5. The SIGHUP handler drains the HTTP idle connection pool
   (`CloseIdleConnections`) when SPKI keys change. Note:
   `CloseIdleConnections` drains idle pooled TLS connections only.
   RPCs already in flight when SIGHUP lands may complete on the old
   TLS session; the next connection after pool drain handshakes
   against the live pin. No additional action is needed for in-flight
   requests — they complete normally under the prior handshake.

   **Step 4 r3 [sec:r3-1]/[arch:r3-4.2] CONVERGENT HIGH/MEDIUM closure.**
   Previously, pooled TLS connections (90s idle TTL) would bypass
   the live-read pin for up to 90 seconds after SIGHUP. The
   `CloseIdleConnections` call on SPKI-key SIGHUP closes this window.

   **Step 4 r4 [sec:r4-2] LOW closure:** corrected SPKI encoding to
   64-hex-char (was incorrectly documented as base64); clarified
   in-flight RPC semantics.

### Rollback

If the new pin is wrong (no `payout_config_reloaded` event, or
RPC calls start failing with TLS errors), update the YAML back to
the old fingerprint and SIGHUP again. The SIGHUP handler validates
the new config before applying; an invalid pin is rejected with
`payout_config_reload_rejected`.

---

## 7. Weekly reconciliation (SPEC §7.4 queries A–F)

The §7.4 queries are checked in at
`phase4-coordinator/internal/payout/reconcile.sql`. Run
them weekly against the coordinator DB:

```bash
sqlite3 /var/lib/macprovider/coordinator.db \
  -cmd ".param set :from_utc '2026-06-18T00:00:00Z'" \
  -cmd ".param set :to_utc   '2026-06-25T00:00:00Z'" \
  -cmd ".param set :now_minus_30d '2026-05-26T00:00:00Z'" \
  -cmd ".param set :hot_wallet '<EIP-55>'" \
  < phase4-coordinator/internal/payout/reconcile.sql
```

Triage:

| Query | Triage |
|-------|--------|
| (A) stale orphans > 30d | Resolve or document each row's `operator_resolution`. |
| (B) compensation forgery | **SECURITY INCIDENT** — investigate hand-edits / compromised operator key. |
| (C) reorg-comp orphan mismatch | **SECURITY INCIDENT** — same triage as (B). |
| (D) cancel observability | Audit-only; cross-check against `cancel_gas_native_wei_24h`. |
| (E) hot-wallet self-fund | **CRITICAL** — invariant violation; halt runner + investigate. |
| (F) money-conservation delta != 0 | **SEV-1 INCIDENT** — halt runner via `payout.enabled: false`; do NOT resume until root cause found. |
| in-DB vs on-chain delta (unlabeled #1) | Per-provider attribution if (F) is non-zero. |
| NULL `payout_currency` (unlabeled #2) | IMPL bug — file ticket. |
| chain-balance recon (unlabeled #3) | Pair against on-chain `balanceOf` for ground truth. |

The chain-balance worker (§7.4 hourly cadence) emits the
signed-drift events automatically; this manual run is a
weekly cross-check + the labeled (A–F) reads.

---

## Appendix — escalation contacts + on-call

Update this section with your on-call rota. The PAGE-class
events from §3 above are wired to the on-call rotation;
WARN-class go to a slower channel.
