#!/usr/bin/env bash
# Build MalibuAttestSpike unsigned, embed PROFILE_PATH, and sign it once.
# Required env: PROFILE_PATH, SIGNING_IDENTITY, TEAM_ID.
# Optional env: BUNDLE_ID (default tech.malibu.app), OUT_DIR, XCODEGEN.
set +x
set -euo pipefail

die() {
  printf 'build-and-sign: %s\n' "$*" >&2
  exit 1
}

: "${PROFILE_PATH:?PROFILE_PATH is required}"
: "${SIGNING_IDENTITY:?SIGNING_IDENTITY is required}"
: "${TEAM_ID:?TEAM_ID is required}"
BUNDLE_ID="${BUNDLE_ID:-tech.malibu.app}"

[[ "$TEAM_ID" =~ ^[A-Za-z0-9]{10}$ ]] || die "TEAM_ID must be 10 alphanumeric characters"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9.][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] || die "BUNDLE_ID is malformed"
[[ -f "$PROFILE_PATH" && ! -L "$PROFILE_PATH" && -s "$PROFILE_PATH" ]] || die "PROFILE_PATH must be a non-empty regular file"
[[ -n "$SIGNING_IDENTITY" ]] || die "SIGNING_IDENTITY is empty"

script_dir="$(cd "$(dirname "$0")" && pwd)"
app_dir="$(cd "$script_dir/../app" && pwd)"
OUT_DIR="${OUT_DIR:-$script_dir/../out}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

if [[ -z "${XCODEGEN:-}" && -n "${RUNNER_TEMP:-}" && -x "$RUNNER_TEMP/xcodegen-2.45.4/xcodegen/bin/xcodegen" ]]; then
  XCODEGEN="$RUNNER_TEMP/xcodegen-2.45.4/xcodegen/bin/xcodegen"
fi
if [[ -z "${XCODEGEN:-}" ]]; then
  XCODEGEN="$(command -v xcodegen || true)"
fi
[[ -n "$XCODEGEN" && -x "$XCODEGEN" ]] || die "xcodegen 2.45.4 is not on PATH"

work="$(mktemp -d "${TMPDIR:-/tmp}/spike1840-sign.XXXXXX")"
cleanup() {
  rm -rf "$work"
  rm -rf "$app_dir/MalibuAttestSpike.xcodeproj"
}
trap cleanup EXIT

security cms -D -i "$PROFILE_PATH" > "$work/profile.plist"
python3 - "$work/profile.plist" "$work/entitlements.plist" "$TEAM_ID" "$BUNDLE_ID" "$work/appattest-environment.txt" <<'PY'
import plistlib
import sys

profile_path, entitlements_path, team, bundle, environment_path = sys.argv[1:6]
with open(profile_path, "rb") as handle:
    profile = plistlib.load(handle)
ents = profile.get("Entitlements")
print("profile entitlement keys:")
if not isinstance(ents, dict):
    print("  <missing Entitlements dict>")
    sys.exit(1)
for key in sorted(ents):
    print(f"  {key}")

keep_exact = {
    "application-identifier",
    "com.apple.application-identifier",
    "com.apple.developer.team-identifier",
    "keychain-access-groups",
}
kept = {}
for key, value in ents.items():
    if key in keep_exact or str(key).startswith("com.apple.developer.devicecheck."):
        kept[key] = value

print("kept entitlement keys:")
if not kept:
    print("  <none>")
for key in sorted(kept):
    print(f"  {key}")

attest = []
for key, value in kept.items():
    if not str(key).startswith("com.apple.developer.devicecheck."):
        continue
    if "appattest" not in str(key).lower():
        continue
    if not isinstance(value, str) or value.strip() == "":
        print(f"appattest entitlement {key} is present but empty", file=sys.stderr)
        sys.exit(1)
    attest.append((str(key), value.strip()))
if not attest:
    print(
        "profile has no com.apple.developer.devicecheck.*appattest* entitlement; refusing to sign",
        file=sys.stderr,
    )
    sys.exit(1)
print("appattest entitlements:")
for key, value in sorted(attest):
    print(f"  {key}={value}")

app_id = kept.get("application-identifier")
if not isinstance(app_id, str) or app_id == "":
    app_id = kept.get("com.apple.application-identifier")
expected = f"{team}.{bundle}"
if app_id != expected:
    print(f"profile application identifier is {app_id!r}, expected {expected!r}", file=sys.stderr)
    sys.exit(1)
team_ent = kept.get("com.apple.developer.team-identifier")
if team_ent != team:
    print(f"profile team identifier is {team_ent!r}, expected {team!r}", file=sys.stderr)
    sys.exit(1)
teams = profile.get("TeamIdentifier")
if isinstance(teams, list) and team not in teams:
    print(f"profile TeamIdentifier does not contain the requested team", file=sys.stderr)
    sys.exit(1)

with open(entitlements_path, "wb") as handle:
    plistlib.dump(kept, handle, fmt=plistlib.FMT_XML)
with open(environment_path, "w", encoding="utf-8") as handle:
    for key, value in sorted(attest):
        handle.write(f"{key}={value}\n")
PY
plutil -lint "$work/entitlements.plist" >/dev/null
cp "$work/entitlements.plist" "$OUT_DIR/entitlements.plist"
cp "$work/appattest-environment.txt" "$OUT_DIR/appattest-environment.txt"

if [[ -n "${SPIKE_KEYCHAIN_PASS_FILE:-}" ]]; then
  [[ -f "$SPIKE_KEYCHAIN_PASS_FILE" && ! -L "$SPIKE_KEYCHAIN_PASS_FILE" ]] || die "SPIKE_KEYCHAIN_PASS_FILE is not a regular file"
  security unlock-keychain -p "$(cat "$SPIKE_KEYCHAIN_PASS_FILE")" build.keychain
  security default-keychain -s build.keychain
  security set-keychain-settings -lut 3600 build.keychain
fi

(
  cd "$app_dir"
  "$XCODEGEN" generate
  xcodebuild \
    -project MalibuAttestSpike.xcodeproj \
    -scheme MalibuAttestSpike \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$work/DerivedData" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    SPIKE_BUNDLE_ID="$BUNDLE_ID" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    build
)

apps=()
while IFS= read -r found; do
  apps+=("$found")
done < <(find "$work/DerivedData/Build/Products" -type d -name 'MalibuAttestSpike.app' -print)
[[ "${#apps[@]}" -eq 1 ]] || die "expected one built app, found ${#apps[@]}"

dest="$OUT_DIR/MalibuAttestSpike.app"
rm -rf "$dest"
ditto "${apps[0]}" "$dest"
rm -f "$dest/Contents/embedded.provisionprofile"
cp "$PROFILE_PATH" "$dest/Contents/embedded.provisionprofile"
chmod 644 "$dest/Contents/embedded.provisionprofile"

# Sign the bundle once. No --deep: nested Mach-Os would each need their own signature.
codesign --force \
  --options runtime \
  --timestamp \
  --identifier "$BUNDLE_ID" \
  --entitlements "$work/entitlements.plist" \
  --sign "$SIGNING_IDENTITY" \
  "$dest"
codesign --verify --strict --verbose=2 "$dest"

echo "---- entitlements ----"
codesign -d --entitlements :- "$dest"
echo "---- signature ----"
details="$(codesign -dvvv "$dest" 2>&1 || true)"
printf '%s\n' "$details" | awk -F= '/^(Identifier|TeamIdentifier|CDHash|Signature)=/{print}'
signed_id="$(printf '%s\n' "$details" | awk -F= '/^Identifier=/{print $2; exit}')"
[[ "$signed_id" == "$BUNDLE_ID" ]] || die "signed identifier is '$signed_id', expected $BUNDLE_ID"
printf '%s\n' "$details" | awk -F= '/^CDHash=/{found=1} END{exit !found}' || die "cdhash was not printed"
echo "signed app: $dest"
