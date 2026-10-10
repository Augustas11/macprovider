#!/usr/bin/env bash
# Fail-closed checks for the freshness-only renewal target resolver. A renewal
# must re-sign the target the CURRENT head already points at (even when GitHub
# "latest" has diverged forward), and must reject any malformed/off-repository
# target rather than silently drift onto a different release.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
resolver="$root/scripts/resolve-discovery-renewal-target.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/resolve-renewal-target.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  printf '[test-resolve-discovery-renewal-target] ERROR: %s\n' "$*" >&2
  exit 1
}

repository="Augustas11/macprovider"
commit="$(printf 'e%.0s' {1..40})"

write_head() {
  local path="$1" set_id="$2"
  python3 - "$path" "$set_id" <<'PY'
import json
import pathlib
import sys

path, set_id = sys.argv[1:]
signed = {
    "expires_at": "2026-09-04T23:14:00Z",
    "issued_at": "2026-08-28T23:14:00Z",
    "release_sequence": 2176955688681473,
    "schema_version": "macprovider.release-discovery.v1",
    "signed_policy_minimum": None,
    "signed_policy_revoked": [],
    "target_artifact_index_sha256": "a" * 64,
    "target_compatibility_set_id": set_id,
}
envelope = {"schema_version": "macprovider.release-discovery-envelope.v1", "signed": signed}
pathlib.Path(path).write_bytes(
    (json.dumps(envelope, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
)
PY
}

# 1) A well-formed head whose target (v1.8.111) is BEHIND GitHub "latest"
#    (v1.8.117) still resolves cleanly — this is the divergent-latest case the
#    Monday cron must survive.
write_head "$work/diverged.json" "$repository:v1.8.111@$commit"
result="$(python3 "$resolver" "$work/diverged.json" "$repository")"
[[ "$result" == "v1.8.111 $commit" ]] || fail "divergent-latest target did not resolve: '$result'"

expect_reject() {
  local label="$1"
  shift
  if "$@" >"$work/$label.out" 2>&1; then
    fail "$label was accepted: $(cat "$work/$label.out")"
  fi
}

# 2) A malformed set id must fail closed.
write_head "$work/malformed.json" "not-a-valid-set-id"
expect_reject malformed python3 "$resolver" "$work/malformed.json" "$repository"

# 3) A short (non-40-hex) commit must fail closed.
write_head "$work/shortcommit.json" "$repository:v1.8.111@abc123"
expect_reject shortcommit python3 "$resolver" "$work/shortcommit.json" "$repository"

# 4) A non-semantic tag must fail closed.
write_head "$work/badtag.json" "$repository:latest@$commit"
expect_reject badtag python3 "$resolver" "$work/badtag.json" "$repository"

# 5) A target bound to a DIFFERENT repository must fail closed (no cross-repo drift).
write_head "$work/otherrepo.json" "attacker/macprovider:v1.8.111@$commit"
expect_reject otherrepo python3 "$resolver" "$work/otherrepo.json" "$repository"

# 6) A head missing the signed object must fail closed.
printf '{"schema_version":"macprovider.release-discovery-envelope.v1"}\n' > "$work/nosigned.json"
expect_reject nosigned python3 "$resolver" "$work/nosigned.json" "$repository"

# 7) A duplicate key must fail closed (canonical-JSON hardening parity).
printf '{"signed":{"target_compatibility_set_id":"%s:v1.8.111@%s"},"signed":{}}\n' \
  "$repository" "$commit" > "$work/dupkey.json"
expect_reject dupkey python3 "$resolver" "$work/dupkey.json" "$repository"

printf '[test-resolve-discovery-renewal-target] ok: freshness-only target resolver fails closed\n'
