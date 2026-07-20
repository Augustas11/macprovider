#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
work="$(mktemp -d "${TMPDIR:-/tmp}/release-discovery-head.XXXXXX")"
trap 'rm -rf "$work"' EXIT

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$work/private.pem" >/dev/null 2>&1
openssl pkey -in "$work/private.pem" -pubout -out "$work/public.pem" >/dev/null 2>&1
cat > "$work/compatibility-set.json" <<'JSON'
{"schema_version":"macprovider.compatibility-set-envelope.v1","signatures":[],"signed":{"compatibility_set_id":"Augustas11/macprovider:v1.8.41@0123456789abcdef0123456789abcdef01234567"}}
JSON
printf '{"schema_version":"macprovider.compatibility-artifact-index.v1"}\n' > "$work/compatibility-artifact-index.json"

python3 "$root/scripts/build-release-discovery-head.py" \
  --sequence 610 \
  --attempt 2 \
  --compatibility-manifest "$work/compatibility-set.json" \
  --target-artifact-index "$work/compatibility-artifact-index.json" \
  --signed-policy-minimum 1.8.40 \
  --signed-policy-revoked v1.8.39 \
  --issued-at 2026-07-17T00:00:00Z \
  --expires-at 2026-07-18T00:00:00Z \
  --private-key "$work/private.pem" \
  --public-key "$work/public.pem" \
  --output "$work/macprovider-release-discovery.json" \
  --signature "$work/macprovider-release-discovery.json.sig"
python3 "$root/scripts/build-release-discovery-head.py" \
  --sequence 610 \
  --attempt 3 \
  --compatibility-manifest "$work/compatibility-set.json" \
  --target-artifact-index "$work/compatibility-artifact-index.json" \
  --signed-policy-minimum 1.8.40 \
  --signed-policy-revoked v1.8.39 \
  --issued-at 2026-07-17T00:00:00Z \
  --expires-at 2026-07-18T00:00:00Z \
  --private-key "$work/private.pem" \
  --public-key "$work/public.pem" \
  --output "$work/macprovider-release-discovery-rerun.json" \
  --signature "$work/macprovider-release-discovery-rerun.json.sig"

python3 - "$work" <<'PY'
import hashlib
import json
import pathlib
import sys

work = pathlib.Path(sys.argv[1])
data = work.joinpath("macprovider-release-discovery.json").read_bytes()
head = json.loads(data)
assert data == (json.dumps(head, sort_keys=True, separators=(",", ":")) + "\n").encode()
assert set(head) == {"schema_version", "signed"}
assert head["schema_version"] == "macprovider.release-discovery-envelope.v1"
signed = head["signed"]
assert signed == {
    "expires_at": "2026-07-18T00:00:00Z",
    "issued_at": "2026-07-17T00:00:00Z",
    "release_sequence": 39976962,
    "schema_version": "macprovider.release-discovery.v1",
    "signed_policy_minimum": "1.8.40",
    "signed_policy_revoked": ["1.8.39"],
    "target_artifact_index_sha256": hashlib.sha256(work.joinpath("compatibility-artifact-index.json").read_bytes()).hexdigest(),
    "target_compatibility_set_id": "Augustas11/macprovider:v1.8.41@0123456789abcdef0123456789abcdef01234567",
}
rerun = json.loads(work.joinpath("macprovider-release-discovery-rerun.json").read_bytes())
assert rerun["signed"]["release_sequence"] == signed["release_sequence"] + 1
assert rerun != head
work.joinpath("signed-payload.json").write_bytes(
    (json.dumps(signed, sort_keys=True, separators=(",", ":")) + "\n").encode()
)
PY

openssl dgst -sha256 -verify "$work/public.pem" \
  -signature "$work/macprovider-release-discovery.json.sig" \
  "$work/signed-payload.json" >/dev/null

printf '[test-release-discovery-head] PASS\n'
