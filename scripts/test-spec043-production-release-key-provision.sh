#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
provisioner="$root/scripts/provision-spec043-production-release-key.sh"
register="$root/scripts/register-spec043-production-release-key.py"

fail() {
  printf '[test-spec043-production-release-key-provision] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -f "$provisioner" && ! -L "$provisioner" ]] || fail "provisioner is absent or unsafe"
[[ -f "$register" && ! -L "$register" ]] || fail "register script is absent or unsafe"

python3 - "$provisioner" "$register" <<'PY'
from pathlib import Path
import sys

provisioner = Path(sys.argv[1]).read_text(encoding="utf-8")
register = Path(sys.argv[2]).read_text(encoding="utf-8")

if "openssl genpkey" not in provisioner:
    raise SystemExit("provisioner must generate the operator P-256 key outside the worktree")
if "mktemp -d" not in provisioner:
    raise SystemExit("provisioner must keep the private key in a temporary directory")
if "gh secret set MACPROVIDER_SPEC043_PRODUCTION_RELEASE_SIGNING_KEY_PEM" not in provisioner:
    raise SystemExit("provisioner does not target the dedicated production-release environment secret")
if "--env production-release" not in provisioner:
    raise SystemExit("provisioner must set the secret on the production-release environment")
if "< \"$private_key\"" not in provisioner or "cat \"$private_key\"" in provisioner:
    raise SystemExit("provisioner does not pipe private bytes directly to gh")
if "MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM" in provisioner:
    raise SystemExit("SPEC-043 provisioner must not reuse the acceptance candidate signing key")
if "printf" in "\n".join(line for line in provisioner.splitlines() if "private_key" in line and "printf" in line):
    raise SystemExit("provisioner prints private key material")
if "register-spec043-production-release-key.py" not in provisioner:
    raise SystemExit("provisioner must register the derived public key")
if "openssl genpkey" in register or "genpkey" in register:
    raise SystemExit("register script must not generate a production-release key")
if "never generates a key" not in register:
    raise SystemExit("register script must remain a non-generating registrar")
print("[test-spec043-production-release-key-provision] ok: provisioner keeps the private key out of the worktree")
PY
