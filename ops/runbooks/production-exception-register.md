# Production Exception Register Runbook

## 0. Status / Scope Banner

Docs/schema lane for [#615](https://github.com/Augustas11/macprovider/issues/615).

This runbook and `ops/exceptions/production-exceptions.json` make production
exceptions operator-facing and machine-readable. They do not expose exceptions
through the operator health API, enforce expiry, block deploy or stable
promotion, run expiry daemons, mutate Pearl, flip flags, cut releases, or close
#615.

Progress marker: register schema + initial inventory landed; enforcement still
open.

## 1. When to Add / Extend / Remove an Exception

Add an entry before using any production security, safety, rollout, catalog,
auth, canary, referral, or recovery exception. Emergency exceptions use this
same register; there is no side channel.

Extend an entry only with fresh owner, issue, scope, expiry, rollback, and
evidence. If the expiry is not known from reviewed evidence, use
`expires_at: null` and `expiry_unknown_reason`; do not invent a date.

Remove or expire an entry only after the strict policy is restored and the
`post_removal_validation` evidence exists. Use `status: "expired"` for elapsed
deadlines that still need physical cleanup, and `status: "removed"` only when
the exception authority is gone and validation passed.

Required fields are enforced by
`ops/exceptions/production-exceptions.schema.json`: stable `id`, `status`,
`environment`, `component`, `policy_delta`, `authority_surface`, `reason`,
`owner`, `issue`, `created_at`, `expires_at`, `scope`, `removal_condition`,
`rollback_command`, `post_removal_validation`, `blocks_stable_promotion`, and
`evidence`.

Set `blocks_stable_promotion: true` when an active exception would make #615,
#613, #584, #585, or related rollout evidence incomplete. Default to true for
auth, catalog, canary, physical-journey, and campaign-critical exceptions until
a reviewed issue says otherwise.

Exception IDs must be unique. JSON Schema cannot portably enforce uniqueness by
one object property, so operators must run the duplicate-ID check in §2 before
opening the PR.

## 2. How to Edit the Register

Edit `ops/exceptions/production-exceptions.json`, then validate it against
`ops/exceptions/production-exceptions.schema.json`.

Preferred validation when `jsonschema` is installed:

```bash
python3 - <<'PY'
import json
from pathlib import Path
from jsonschema import Draft202012Validator, FormatChecker

root = Path("ops/exceptions")
schema = json.loads((root / "production-exceptions.schema.json").read_text())
doc = json.loads((root / "production-exceptions.json").read_text())
validator = Draft202012Validator(schema, format_checker=FormatChecker())
errors = sorted(validator.iter_errors(doc), key=lambda e: list(e.path))
if errors:
    for err in errors:
        print("/".join(map(str, err.path)) or "<root>", "-", err.message)
    raise SystemExit(1)
ids = [entry["id"] for entry in doc["exceptions"]]
dupes = sorted({item for item in ids if ids.count(item) > 1})
if dupes:
    raise SystemExit(f"duplicate exception ids: {dupes}")
PY
```

Dependency-free fallback:

```bash
python3 - <<'PY'
import json
import re
from pathlib import Path

doc = json.loads(Path("ops/exceptions/production-exceptions.json").read_text())
assert doc["schema_version"] == "macprovider-production-exceptions-v1"
assert doc["environment"] == "pearl-production"
assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", doc["updated_at"])
ids = []
required = {
    "id", "status", "environment", "component", "policy_delta",
    "authority_surface", "reason", "owner", "issue", "created_at",
    "expires_at", "scope", "removal_condition", "rollback_command",
    "post_removal_validation", "blocks_stable_promotion", "evidence",
}
for entry in doc["exceptions"]:
    missing = required - set(entry)
    assert not missing, (entry.get("id"), sorted(missing))
    assert entry["id"].startswith("exc-")
    assert entry["status"] in {"active", "expired", "removed", "planned"}
    assert entry["environment"] == "pearl-production"
    assert isinstance(entry["blocks_stable_promotion"], bool)
    assert isinstance(entry["evidence"], list)
    if entry["expires_at"] is None:
        assert entry.get("expiry_unknown_reason"), entry["id"]
    ids.append(entry["id"])
dupes = sorted({item for item in ids if ids.count(item) > 1})
assert not dupes, dupes
assert isinstance(doc["open_questions"], list)
PY
```

Run `git diff --check` before commit.

Changes to money/auth-adjacent exceptions require PR review. Treat this register
as ops truth: changing it is not runtime enforcement yet, but it changes what
operators rely on during release and incident decisions.

Sync hazard: config sync, rollback, or restore tooling must not resurrect a
removed exception from stale authoritative files. Until #615 implements
anti-resurrection enforcement, every removal PR must name the config/file/DB
surface and include a read-only post-sync check.

## 3. Pearl Verification Checklist

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
leave the relevant `open_questions` item pending.

## 4. Relationship to Entry 172

The Entry 172 activation checklist lives at
[`ops/runbooks/entry-172-referral-activation.md`](./entry-172-referral-activation.md).
The corresponding register row is `exc-entry172-air-referral-activation`.

Entry 172 flag enable is conceptually blocked while unregistered, expired, or
campaign-critical exceptions remain unresolved. This is operator policy in
docs only; there is no runtime gate in this lane.

## 5. Follow-up Implementation Map

The following #615 items remain out of scope for this docs/schema lane:

| #615 item | Future implementation |
| --- | --- |
| 3 | Authenticated operator health exposes active and expired exceptions without secrets. |
| 4 | Deploy and stable-promotion paths reject unregistered, expired, ownerless, or scope-mismatched exceptions. |
| 5 | Expiry fails closed or alerts before deadline and cannot silently self-extend. |
| 6 | Config sync and restore paths cannot recreate removed exceptions from stale authoritative files. |
| 7 | Removal emits durable evidence and verifies strict policy on physical providers. |
| 8 | Emergency exceptions use the same enforced mechanism. |

Do not implement these from this lane without a new #615 implementation scope.
