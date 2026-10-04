#!/usr/bin/env bash
# From a Developer ID signed app and child, make ad-hoc copies for the negative tests.
# MalibuAttestSpike-adhoc.app keeps the signed app's entitlements; AMFI may refuse
# to launch it at all because restricted entitlements are no longer backed by the
# profile, which is itself a refusal. MalibuAttestSpike-adhoc-noent.app drops the
# entitlements and the profile so it does launch and reaches DCAppAttestService.
# The child copy keeps its identifier so a failed SecCode check is the
# signature, not a renamed binary.
set +x
set -euo pipefail

die() {
  printf 'make-negative-copies: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'usage: %s --app APP --child CHILD --out DIR\n' "$0" >&2
  exit 2
}

app=""
child=""
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="${2:-}"; shift 2 ;;
    --child) child="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$app" && -n "$child" && -n "$out" ]] || usage
[[ -d "$app" && ! -L "$app" ]] || die "--app must be an app bundle"
[[ -f "$child" && ! -L "$child" ]] || die "--child must be a regular file"
mkdir -p "$out"
out="$(cd "$out" && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/spike1840-negative.XXXXXX")"
trap 'rm -rf "$work"' EXIT

codesign -d --entitlements :- "$app" > "$work/entitlements.plist"
plutil -lint "$work/entitlements.plist" >/dev/null

adhoc_app="$out/MalibuAttestSpike-adhoc.app"
rm -rf "$adhoc_app"
ditto "$app" "$adhoc_app"
codesign --force \
  --sign - \
  --options runtime \
  --entitlements "$work/entitlements.plist" \
  "$adhoc_app"
codesign --verify --strict --verbose=2 "$adhoc_app"

noent_app="$out/MalibuAttestSpike-adhoc-noent.app"
rm -rf "$noent_app"
ditto "$app" "$noent_app"
rm -f "$noent_app/Contents/embedded.provisionprofile"
codesign --force \
  --sign - \
  --options runtime \
  "$noent_app"
codesign --verify --strict --verbose=2 "$noent_app"

details="$(codesign -dv "$child" 2>&1 || true)"
identifier="$(printf '%s\n' "$details" | awk -F= '/^Identifier=/{print $2; exit}')"
if [[ -z "$identifier" ]]; then
  identifier="live.malibu.provider.cli"
fi
[[ "$identifier" =~ ^[A-Za-z0-9._-]+$ ]] || die "child identifier is not a safe codesign identifier"

adhoc_child="$out/child-adhoc"
rm -f "$adhoc_child"
cp "$child" "$adhoc_child"
chmod 755 "$adhoc_child"
codesign --force \
  --sign - \
  --options runtime \
  --identifier "$identifier" \
  "$adhoc_child"
codesign --verify --strict --verbose=2 "$adhoc_child"

echo "ad-hoc app: $adhoc_app"
echo "ad-hoc app without entitlements: $noent_app"
echo "ad-hoc child: $adhoc_child"
echo "ad-hoc child identifier: $identifier"
