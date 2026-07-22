# Production Exception Register Runbook

## 0. Status / Scope Banner

Enforcement scaffolding lane for [#615](https://github.com/Augustas11/macprovider/issues/615).

This runbook, `ops/exceptions/production-exceptions.json`, and
`scripts/check-production-exceptions.py` make production exceptions
operator-facing, machine-readable, and release-gated for **registered rows**.
They do **not** flip Pearl production flags, discover unregistered live
exceptions, close #615, or claim physical exception-free proof.

Progress marker: register schema + inventory landed (#663); validator, operator
report, deploy/promote gates, and anti-resurrection sync-check landed in this
lane. Authenticated coordinator `/health` exposure, live Pearl reconciliation,
authoritative sync-path integration, and physical exception-free evidence remain
open.

## 1. When to Add / Extend / Remove an Exception

Add an entry before using any production security, safety, rollout, catalog,
auth, canary, referral, or recovery exception. Emergency exceptions use this
same register; there is no side channel.

Extend an entry only with fresh owner, issue, scope, expiry, rollback, and
evidence. If the expiry is not known from reviewed evidence, use
`expires_at: null` and `expiry_unknown_reason`; do not invent a date. Do not
silently move `expires_at` later on the same ID — create a new reviewed ID or
supply `--previous-register` evidence in gates that compare revisions.

Remove or expire an entry only after the strict policy is restored and the
`post_removal_validation` evidence exists. Use `status: "expired"` for elapsed
deadlines that still need physical cleanup, and `status: "removed"` only when
the exception authority is gone and validation passed. When marking `removed`,
also append the ID to
`ops/exceptions/removed-exception-tombstones.json` (required by the checker).

Required fields are enforced by
`ops/exceptions/production-exceptions.schema.json` and by
`scripts/check-production-exceptions.py validate` (stdlib schema-parity checks
including additionalProperties, calendar timestamps, and evidence string items).

Set `blocks_stable_promotion: true` when an active/planned/expired exception
would make #615, #613, #584, #585, or related rollout evidence incomplete.
Promote mode rejects those rows. Default deploy mode warns.

Exception IDs must be unique. The checker rejects duplicates, ownerless /
placeholder owners, environment mismatches, heuristic scope-widening phrases,
active rows past `expires_at`, removed rows without tombstones, and resurrection
of tombstoned IDs.

## 2. How to Edit and Validate the Register

Edit `ops/exceptions/production-exceptions.json`, then run:

```bash
python3 scripts/check-production-exceptions.py validate
python3 scripts/check-production-exceptions.py report
# or:
make check-exceptions
```

Run `git diff --check` before commit. Changes to money/auth-adjacent exceptions
require PR review.

## 3. Operator Report Surface (no secrets)

```bash
python3 scripts/check-production-exceptions.py report
python3 scripts/check-production-exceptions.py report -o /tmp/exceptions-report.json
```

The JSON report lists registered active/expired/planned rows with owner, issue,
expiry clock state, scope, and authority surface. Secret-like substrings
(including PEM blocks and password/token assignments) are redacted; the report
fails if residual secret-like material remains. This is the file/CLI health
surface for #615 until an authenticated coordinator health endpoint is wired.
It does **not** prove Pearl has no unregistered exceptions.

## 4. Deploy and Stable-Promotion Gates

### Default-safe deploy

Always invoked by:

- `phase4-coordinator/dist/check-deploy-config.sh`
- `phase5-gateway/dist/deploy-pearl-vps.sh` (runs **before** any
  `SKIP_C2_CHECK` branch; that opt-out skips only C2 timers)

```bash
python3 scripts/check-production-exceptions.py gate --mode=deploy
```

Hard-fail (even with enforcement off):

- malformed register / schema_version / environment / additional properties
- duplicate IDs
- ownerless or placeholder owners
- environment mismatch; heuristic global-widening scope phrases without an
  explicit "must not widen" bound
- `status=active` with `expires_at <= now` (fail-closed clock expiry)
- `status=removed` without a tombstone
- tombstone resurrection
- tombstone deletions vs `--base-tombstones` when that base is supplied

Warn only (default-safe):

- `status=expired`
- active rows with `expires_at=null`
- approaching expiry (within 72h)
- `blocks_stable_promotion=true`

### Enforced deploy

```bash
MACPROVIDER_EXCEPTION_ENFORCEMENT=1 \
  python3 scripts/check-production-exceptions.py gate --mode=deploy
# or:
python3 scripts/check-production-exceptions.py gate --mode=deploy --enforce
```

Promotes the warn-class findings above to hard-fail.

### Stable promotion (always fail-closed)

`.github/workflows/promote-acceptance-candidate.yml` fetches current
`origin/main` register + tombstones and runs:

```bash
python3 scripts/check-production-exceptions.py \
  --register <origin/main register> \
  --tombstones <origin/main tombstones> \
  --base-tombstones ops/exceptions/removed-exception-tombstones.json \
  --previous-register ops/exceptions/production-exceptions.json \
  gate --mode=promote
```

Promote rejects expired, unbounded-active, approaching-expiry (72h),
`blocks_stable_promotion=true` (active/planned/expired), ownerless,
scope-mismatched, missing-tombstone, resurrected, and tombstone-deletion rows.
This intentionally blocks public promotion while #615 inventory remains
blocking/unbounded/expired.

## 5. Anti-Resurrection (config sync / rollback)

Removed exception IDs belong in
`ops/exceptions/removed-exception-tombstones.json`. Before restoring configs
from backup, overlay, or rollback snapshots that might reintroduce exception
authority, run either equivalent form:

```bash
python3 scripts/check-production-exceptions.py \
  --tombstones ops/exceptions/removed-exception-tombstones.json \
  sync-check \
  --current ops/exceptions/production-exceptions.json \
  --stale /path/to/stale-or-backup-register.json

# or with --tombstones after the subcommand:
python3 scripts/check-production-exceptions.py sync-check \
  --current ops/exceptions/production-exceptions.json \
  --stale /path/to/stale-or-backup-register.json \
  --tombstones ops/exceptions/removed-exception-tombstones.json
```

The checker models stale authoritative restore and fails if a tombstoned or
previously `removed` ID would return as `active` / `planned` / `expired`.
Automated unit + CLI coverage lives in
`scripts/tests/test_production_exceptions.py` and
`scripts/test-production-exceptions.sh`.

Still open: automatic invocation from every Pearl sync/restore/rollback path,
and live discovery of unregistered production authority.

## 6. Pearl Verification Checklist

Use read-only commands and placeholders. Do not print bearer tokens, HMAC
secrets, referral codes, private keys, or full DB rows containing secret
material. Capture redacted evidence into the register's `evidence` fields or
close the relevant `open_questions` item.

Identity-signature exemptions:

```bash
ssh pearl 'sudo -u postgres psql <DB_NAME> -c "select provider_id, kind, signature_exempt_until, granted_by from provider_auth_policy where signature_exempt_until is not null order by signature_exempt_until;"'
```

Hello-gate and catalog/admission bridge config:

```bash
ssh pearl 'sudo grep -A30 "^proof_of_weights:" /etc/macprovider/coordinator.yaml'
ssh pearl 'sudo grep -A30 "^autotune:" /etc/macprovider/coordinator.yaml'
ssh pearl 'sudo grep -E "MODEL_HASH_LEGACY_UNTIL|PROVIDER_ADMISSION|AUTOTUNE" /etc/macprovider/coordinator.env'
```

Canary containment:

```bash
ssh pearl 'systemctl is-enabled canary-buyer.timer; systemctl is-active canary-buyer.timer canary-buyer.service; sudo test -e /etc/macprovider-canary-buyer/enabled && echo enable_gate_present || echo enable_gate_absent; sudo test -e /var/lib/macprovider-canary-buyer/DISABLED && echo disabled_sentinel_present || true'
```

Pool bridge state, with a placeholder token source:

```bash
ssh pearl 'curl -fsS --header "Authorization: Bearer <OPERATOR_TOKEN>" http://127.0.0.1:8444/poolz | jq ".providers[] | {provider_id, binary_version, catalog_admission_mode, model_hash_algorithm}"'
```

Entry 172 referral flags:

```bash
ssh pearl 'sudo grep -A20 "^referrals:" /etc/macprovider/coordinator.yaml'
```

Record only names, booleans, timestamps, counts, issue links, and redacted
artifact identifiers. If live Pearl confirmation is required but unavailable,
leave the relevant `open_questions` item pending. Do not invent `expires_at`
values without that evidence.

## 7. Relationship to Entry 172

The Entry 172 activation checklist lives at
[`ops/runbooks/entry-172-referral-activation.md`](./entry-172-referral-activation.md).
The corresponding register row is `exc-entry172-air-referral-activation`.

Entry 172 is currently `status: expired` after the first fresh referred-provider
journey PASS. Stable promotion rejects that row until Pearl referral flags are
rolled off, `post_removal_validation` passes, and the row moves to `removed`
(with a tombstone). Do not re-enable flags without complete #613 evidence or a
new reviewed decision.

## 8. What Is Enforced vs Still Open

| #615 item | Status in this lane |
| --- | --- |
| 1–2 Machine-readable register + required fields | Landed (#663) + stdlib schema-parity checker |
| 3 Operator-visible inventory without secrets | Landed as CLI/JSON report for **registered** rows; authenticated coordinator health API still open |
| 4 Deploy + stable-promotion rejection | Landed for **registered-row** policy (deploy default-safe; promote fail-closed on expired/unbounded/blocking/72h). Unregistered live Pearl exceptions still open |
| 5 Fail-closed expiry / pre-deadline alerts | Landed for register clock + promote 72h window; silent self-extension blocked when `--previous-register` is supplied (promote does). No Pearl expiry daemon |
| 6 Anti-resurrection on sync/restore | Landed as required tombstones + `sync-check` + unit/CLI tests. Not yet hooked into every Pearl sync/rollback path |
| 7 Removal evidence on physical providers | Still open |
| 8 Emergency exceptions use same mechanism | Register+gates cover emergencies once registered; completeness proof still open |
| Scope widening | Heuristic phrase checks only; structural scope kinds remain open |

Coordinate with #608: do not clear catalog-bridge exception rows in the same PR
as scaffolding unless live evidence justifies it.

Do **not** silently flip Pearl production flags from this lane. Keep #615 open
until physical exception-free proof exists.
