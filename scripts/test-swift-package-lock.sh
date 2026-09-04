#!/usr/bin/env bash
# Contract coverage for the #1360 locked SwiftPM resolve gate.
#
# Regular `swift test` uses automatic resolution and stays green on a newer
# default Xcode even when Package.resolved is incomplete for the release
# toolchain. This test locks the CI wiring so a future dep bump cannot merge
# without a Xcode 16.4 `-onlyUsePackageVersionsFromResolvedFile` check.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ci_workflow="$root/.github/workflows/ci.yml"
verify="$root/scripts/verify-swift-package-lock.sh"
makefile="$root/Makefile"
resolved="$root/phase3-binary/Package.resolved"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$verify" ]] || fail "missing $verify"
bash -n "$verify"

python3 - "$ci_workflow" "$verify" "$makefile" "$resolved" <<'PY'
import json
import pathlib
import sys

ci_path, verify_path, makefile_path, resolved_path = map(pathlib.Path, sys.argv[1:])
ci = ci_path.read_text(encoding="utf-8")
verify = verify_path.read_text(encoding="utf-8")
makefile = makefile_path.read_text(encoding="utf-8")
resolved = json.loads(resolved_path.read_text(encoding="utf-8"))

if "scripts/test-swift-package-lock.sh" not in makefile:
    raise SystemExit("Makefile test-dist must run scripts/test-swift-package-lock.sh")

if "swift-package-lock:" not in ci:
    raise SystemExit("ci.yml is missing the swift-package-lock job")
if "phase3-binary (locked SwiftPM resolve)" not in ci:
    raise SystemExit("ci.yml must name the locked-resolve job for ci-required matching")

lock_job = ci.split("swift-package-lock:", 1)[1].split("\n  spec-015-acceptance:", 1)[0]
if "runs-on: macos-15" not in lock_job:
    raise SystemExit("locked-resolve job must run on macos-15")
if "needs: changes" not in lock_job:
    raise SystemExit("locked-resolve job must be path-gated by the changes detector")
if "needs.changes.outputs.swift == 'true'" not in lock_job:
    raise SystemExit("locked-resolve job must share the swift path gate")
if "/Applications/Xcode_16.4.app/Contents/Developer" not in lock_job:
    raise SystemExit("locked-resolve job must select the reviewed Xcode 16.4 path")
if "/Applications/Xcode.app/Contents/Developer" in lock_job:
    raise SystemExit("locked-resolve job must not use the default/latest Xcode.app")
if "scripts/verify-swift-package-lock.sh" not in lock_job:
    raise SystemExit("locked-resolve job must invoke scripts/verify-swift-package-lock.sh")
if "|| true" in lock_job:
    raise SystemExit("locked-resolve job must not swallow resolve failures")

required = ci.split("ci-required:", 1)[1]
if "- swift-package-lock" not in required:
    raise SystemExit("ci-required must depend on swift-package-lock")
if "SWIFT_PACKAGE_LOCK_RESULT" not in required:
    raise SystemExit("ci-required must consume the locked-resolve job result")
if (
    'allow_skip "phase3-binary (locked SwiftPM resolve)" '
    '"$SWIFT_PACKAGE_LOCK_RESULT" "$SWIFT_GATE"'
) not in required:
    raise SystemExit("ci-required must allow-skip locked-resolve only when the swift gate is false")

if "/Applications/Xcode_16.4.app/Contents/Developer" not in verify:
    raise SystemExit("verify-swift-package-lock.sh must require Xcode 16.4")
if "-onlyUsePackageVersionsFromResolvedFile" not in verify:
    raise SystemExit("verify script must use the locked candidate/release resolve flag")
if "|| true" in verify:
    raise SystemExit("verify script must not swallow resolve failures")
if "-resolvePackageDependencies" not in verify:
    raise SystemExit("verify script must resolve packages without a full Release build")
if "cmp -s" not in verify or "Package.resolved.before" not in verify:
    raise SystemExit("verify script must fail if locked resolve rewrites Package.resolved")

pins = resolved.get("pins")
if resolved.get("version") not in (2, 3) or not isinstance(pins, list) or not pins:
    raise SystemExit("phase3-binary/Package.resolved is not a valid SwiftPM lock")
identities = {pin.get("identity") for pin in pins if isinstance(pin, dict)}
if "async-http-client" not in identities:
    raise SystemExit(
        "Package.resolved is missing async-http-client; Xcode 16.4 locked "
        "resolve requires it after the #1336 swift-transformers bump (#1360)"
    )
PY

echo "swift-package-lock CI contract checks passed"
