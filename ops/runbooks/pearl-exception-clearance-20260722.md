# Pearl exception clearance — 2026-07-22 (#615 / #609)

Read-only inventory plus **bounded** Pearl mutations for the #615 production
exception register and #609 Tier-2 hash containment. No public release, no
Pearl coordinator/binary promote, and no flip of
`tier2.require_hash_verified` or `require_autotune_hello_gate`.

Host: `coordinator.streamvc.live` / `159.223.165.194`  
Coordinator binary: **v1.8.49** (active)  
Clearance timestamp: **2026-07-22T10:45:27Z**  
Backup dir on Pearl: `/var/tmp/macprovider-ops-clearance-20260722T104527Z`

## What changed on Pearl

| Action | Result |
|--------|--------|
| Remove empty canary enable gates | Deleted `/etc/macprovider-canary-buyer/enabled` and `/etc/macprovider/canary-buyer.enabled` |
| Install canary DISABLED sentinel | `/var/lib/macprovider-canary-buyer/DISABLED` present |
| Keep canary off | `canary-buyer.timer` disabled/inactive; overlay `pool.canary_enabled: false` |
| Clear elapsed signature exemptions | `provider_auth_policy.signature_exempt_until` NULLed for 6 already-expired rows; remaining_exempt=0 |

## What did **not** change

- `proof_of_weights.require_autotune_hello_gate: false` (still live)
- `tier2.require_hash_verified: false` (still live)
- Dual catalogs still on disk (`autotune/current/*` + `tier2-catalog.json`)
- `auth.allow_tokenless_provisional_bootstrap: true` (still live)
- Referral overlay flags (Entry 172 still needs flag roll-off for `removed`)
- No `MODEL_HASH_LEGACY_UNTIL` was invented or set

## Exception notes

### onboarding-autotune-hello-gate

Live overlay:

```text
proof_of_weights.require_autotune_hello_gate: false
```

Keep **active** until #582 stranger/fresh onboarding proves admission with the
gate re-enabled.

### cli-identity-signature-exemption

Pre-clear (redacted): 6 rows with `signature_exempt_until`, **0 unexpired**.
Latest historical deadline: `2026-07-20T09:16:08Z` (`augustass-macbook-air`).

Post-clear: all `signature_exempt_until` NULL. 48h journal
`provider_auth_policy_exempt_used` count = 0.

Register status → **expired** (`expires_at=2026-07-20T09:16:08Z`). Mark
**removed** only after physical reboot/reconnect signature proof (#585/#613).

### tokenless-recovery

`admission_identity_recovery_authorizations` count = 0.  
Remaining surface: live `auth.allow_tokenless_provisional_bootstrap: true`.

### tier2-hash-mismatch-containment (#609)

Live containment is **`tier2.require_hash_verified: false`** on coordinator
v1.8.49. Deployed YAML has **no** `model_hash_legacy_until`; process environ
has **no** `MODEL_HASH_LEGACY_UNTIL`.

Settlement evidence (sqlite `settlement_route_snapshots`):

- `spec008_hash_status=hash_verified` for **all** 1109 rows
- mismatches last 7d = **0**
- Qwen reported hash prefix `10adb5da9840` matches expected catalog hash
- Autotune + Tier-2 Qwen artifact SHA-256 agree at
  `10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0`

48h journal: `model_hash_algorithm_legacy_bridge=0`, `hash_mismatch=0`.

**Do not** set `require_hash_verified: true` from this clearance. Flip only
after coordinator promote that fail-closes missing/unknown
`model_hash_algorithm` and physical providers prove
`macprovider.snapshot-manifest.v1` into buyer_serving.

### canary-disabled-enable-gate

Unexpected empty enable gates removed; DISABLED sentinel installed; timer
remains disabled. Exception stays **active** until #584 re-enable evidence.

### catalog-compatibility-bridges

Dual files remain:

- autotune: `published-2026-07-10-catalog-recovery-v1`
- Tier-2: `macprovider-tier2-model-catalog-2026-07-07-p2-qwen3-8b`

Qwen identity currently agrees; single-authority cutover still owned by #608.

### v1840-coordinator-admission-bridge

Deployed `autotune:` block exposes catalog paths/keys only (no
`enforce_provider_admission` / `provider_admission_bridge_deadline` in the
live file). Advertised `latest_binary_version=1.8.49`. Authenticated
`/poolz` `legacy_bridge` count still outstanding (canary operator token is
not a general operator health token).

## Register follow-up

`ops/exceptions/production-exceptions.json` updated in the same change set:
open questions answered; #609/#615 rows carry `partial_progress` /
`still_blocked_for_clearance` from this evidence.
