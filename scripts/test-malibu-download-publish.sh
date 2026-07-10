#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/scripts/setup-malibu-download-pearl.sh"
PUBLISH="$ROOT/scripts/publish-malibu-latest-dmg.sh"
INSTALL_PUBLICATION="$ROOT/scripts/install-malibu-publication.sh"
VERIFY_SET="$ROOT/scripts/verify-malibu-publication-set.sh"
VERIFY="$ROOT/scripts/verify-malibu-download.sh"
SSH_HELPER="$ROOT/scripts/malibu-download-ssh.sh"
KNOWN_HOSTS="$ROOT/scripts/dist/malibu-download-known_hosts"
NGINX="$ROOT/scripts/dist/nginx-download.malibu.tech.conf"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for file in "$SETUP" "$PUBLISH" "$INSTALL_PUBLICATION" "$VERIFY_SET" "$VERIFY" "$SSH_HELPER"; do
  [[ -f "$file" ]] || fail "missing $file"
  bash -n "$file" || fail "bash -n $file"
done
[[ -f "$KNOWN_HOSTS" ]] || fail "missing $KNOWN_HOSTS"
[[ -f "$NGINX" ]] || fail "missing $NGINX"

grep -q 'malibu-download-known_hosts' "$SSH_HELPER" ||
  fail 'ssh helper should pin Pearl host key via known_hosts'
grep -q 'StrictHostKeyChecking=yes' "$SSH_HELPER" ||
  fail 'ssh helper should enforce StrictHostKeyChecking=yes'
grep -q 'MALIBU_DOWNLOAD_WEBROOT' "$PUBLISH" ||
  fail 'publish script should use MALIBU_DOWNLOAD_WEBROOT'
grep -q '/root/\.malibu-publish/stage\.XXXXXXXX' "$PUBLISH" ||
  fail 'publish script must use an unpredictable root-only staging directory'
grep -q "stat -c '%u:%g:%a:%h:%F'" "$PUBLISH" ||
  fail 'publish script must verify transferred ownership, mode, link count, and type'
grep -q 'sha256sum' "$PUBLISH" ||
  fail 'publish script must verify transferred content before the helper runs'
if grep -qE 'gh release download|/tmp/malibu' "$PUBLISH"; then
  fail 'publish script must not redownload a tag or use predictable /tmp staging'
fi
grep -q '/root/\.malibu-setup/stage\.XXXXXXXX' "$SETUP" ||
  fail 'setup script must use an unpredictable root-only staging directory'
grep -q "stat -c '%u:%g:%a:%h:%F'" "$SETUP" ||
  fail 'setup script must verify nginx config ownership, mode, link count, and type'
grep -q 'sha256sum' "$SETUP" ||
  fail 'setup script must verify staged nginx config bytes before installation'
grep -q 'cleanup_remote_stage' "$SETUP" ||
  fail 'setup script must remove root staging on success and failure'
if grep -q '/tmp/nginx-malibu-download' "$SETUP"; then
  fail 'setup script must not use a predictable remote /tmp path'
fi
grep -q 'same-tag publication drift refused' "$INSTALL_PUBLICATION" ||
  fail 'publication installer must permanently bind a tag to one manifest'
grep -q 'versioned pointer retarget refused' "$INSTALL_PUBLICATION" ||
  fail 'publication installer must never retarget a versioned URL'
grep -q 'single same-filesystem rename is the public transaction boundary' "$INSTALL_PUBLICATION" ||
  fail 'publication installer must atomically switch the shared current pointer'

work="$(mktemp -d "${TMPDIR:-/tmp}/malibu-publication-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/input" "$work/webroot"
printf 'old dmg\n' > "$work/webroot/latest.dmg"
printf 'old appcast\n' > "$work/webroot/appcast.xml"
printf 'new dmg\n' > "$work/input/Malibu-v1.2.3.dmg"
printf 'new appcast\n' > "$work/input/appcast.xml"

create_manifest() {
  python3 - "$@" <<'PY'
import hashlib
import json
import pathlib
import sys

output, dmg_name, appcast_name, release_id, dmg_asset_id, appcast_asset_id = sys.argv[1:]
dmg = pathlib.Path(dmg_name).read_bytes()
appcast = pathlib.Path(appcast_name).read_bytes()
dmg_hash = hashlib.sha256(dmg).hexdigest()
appcast_hash = hashlib.sha256(appcast).hexdigest()
publication_id = hashlib.sha256(json.dumps(
    {"appcast_sha256": appcast_hash, "dmg_sha256": dmg_hash},
    sort_keys=True,
    separators=(",", ":"),
).encode()).hexdigest()
manifest = {
    "schema_version": 1,
    "repository": "Augustas11/macprovider",
        "tag": "v1.2.3",
        "commit": "a" * 40,
        "prerelease": False,
        "release_id": int(release_id),
    "publication_id": publication_id,
    "assets": {
        "Malibu-v1.2.3.dmg": {"id": int(dmg_asset_id), "sha256": dmg_hash},
        "appcast.xml": {"id": int(appcast_asset_id), "sha256": appcast_hash},
    },
}
pathlib.Path(output).write_text(
    json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
print(publication_id)
PY
}

publication_id="$(create_manifest \
  "$work/input/publication-manifest.json" \
  "$work/input/Malibu-v1.2.3.dmg" "$work/input/appcast.xml" 101 201 202)"
dmg_hash="$(shasum -a 256 "$work/input/Malibu-v1.2.3.dmg" | awk '{print $1}')"
printf '%s  Malibu-v1.2.3.dmg\n' "$dmg_hash" > "$work/input/Malibu-v1.2.3.dmg.sha256"

MALIBU_PUBLICATION_TESTING=1 bash "$INSTALL_PUBLICATION" \
  "$work/webroot" v1.2.3 "$publication_id" \
  "$work/input/publication-manifest.json" \
  "$work/input/Malibu-v1.2.3.dmg" \
  "$work/input/appcast.xml" \
  "$work/input/Malibu-v1.2.3.dmg.sha256"

[[ -L "$work/webroot/.malibu-current" ]] || fail 'current publication pointer must be a symlink'
[[ -L "$work/webroot/latest.dmg" ]] || fail 'latest.dmg must resolve through current pointer'
[[ -L "$work/webroot/appcast.xml" ]] || fail 'appcast.xml must resolve through current pointer'
[[ "$(cat "$work/webroot/latest.dmg")" == 'new dmg' ]] || fail 'latest.dmg did not switch'
[[ "$(cat "$work/webroot/appcast.xml")" == 'new appcast' ]] || fail 'appcast.xml did not switch'
[[ "$(cat "$work/webroot/Malibu-v1.2.3.dmg")" == 'new dmg' ]] || fail 'versioned dmg is missing'
[[ -f "$work/webroot/.malibu-tag-manifests/v1.2.3.json" ]] || fail 'permanent tag manifest is missing'

python3 - "$work/input/publication-manifest.json" "$work/input/prerelease-manifest.json" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
value["prerelease"] = True
pathlib.Path(sys.argv[2]).write_text(json.dumps(value), encoding="utf-8")
PY
if MALIBU_PUBLICATION_TESTING=1 bash "$INSTALL_PUBLICATION" \
  "$work/webroot" v1.2.3 "$publication_id" \
  "$work/input/prerelease-manifest.json" \
  "$work/input/Malibu-v1.2.3.dmg" \
  "$work/input/appcast.xml" \
  "$work/input/Malibu-v1.2.3.dmg.sha256" >"$work/prerelease.out" 2>&1; then
  fail 'publication installer accepted prerelease=true for the stable feed'
fi
grep -q 'prerelease must not publish the stable Malibu feed' "$work/prerelease.out" ||
  fail 'prerelease rejection was unclear'
[[ "$(cat "$work/webroot/latest.dmg")" == 'new dmg' ]] || fail 'prerelease changed stable latest.dmg'
[[ "$(cat "$work/webroot/appcast.xml")" == 'new appcast' ]] || fail 'prerelease changed stable appcast.xml'
mode_of() {
  python3 - "$1" <<'PY'
import pathlib
import stat
import sys
print(oct(stat.S_IMODE(pathlib.Path(sys.argv[1]).lstat().st_mode))[2:])
PY
}
[[ "$(mode_of "$work/webroot")" == 755 ]] || fail 'webroot must be mode 0755'
[[ "$(mode_of "$work/webroot/.malibu-releases/$publication_id/latest.dmg")" == 644 ]] ||
  fail 'published files must be read-only mode 0644'

printf 'changed appcast\n' > "$work/input/appcast-drift.xml"
drift_id="$(create_manifest \
  "$work/input/publication-manifest-drift.json" \
  "$work/input/Malibu-v1.2.3.dmg" "$work/input/appcast-drift.xml" 102 203 204)"
if MALIBU_PUBLICATION_TESTING=1 bash "$INSTALL_PUBLICATION" \
  "$work/webroot" v1.2.3 "$drift_id" \
  "$work/input/publication-manifest-drift.json" \
  "$work/input/Malibu-v1.2.3.dmg" \
  "$work/input/appcast-drift.xml" \
  "$work/input/Malibu-v1.2.3.dmg.sha256" >"$work/drift.out" 2>&1; then
  fail 'publication installer accepted same-tag content drift'
fi
grep -q 'same-tag publication drift refused' "$work/drift.out" ||
  fail 'same-tag drift did not fail at the permanent manifest binding'
[[ "$(cat "$work/webroot/appcast.xml")" == 'new appcast' ]] || fail 'failed drift changed appcast.xml'

rm "$work/webroot/Malibu-v1.2.3.dmg"
ln -s .malibu-releases/evil/latest.dmg "$work/webroot/Malibu-v1.2.3.dmg"
if MALIBU_PUBLICATION_TESTING=1 bash "$INSTALL_PUBLICATION" \
  "$work/webroot" v1.2.3 "$publication_id" \
  "$work/input/publication-manifest.json" \
  "$work/input/Malibu-v1.2.3.dmg" \
  "$work/input/appcast.xml" \
  "$work/input/Malibu-v1.2.3.dmg.sha256" >"$work/retarget.out" 2>&1; then
  fail 'publication installer accepted a retargeted versioned pointer'
fi
grep -q 'versioned pointer retarget refused' "$work/retarget.out" ||
  fail 'retargeted versioned pointer did not fail closed'

mkdir "$work/writable-webroot"
chmod 0777 "$work/writable-webroot"
if MALIBU_PUBLICATION_TESTING=1 bash "$INSTALL_PUBLICATION" \
  "$work/writable-webroot" v1.2.3 "$publication_id" \
  "$work/input/publication-manifest.json" \
  "$work/input/Malibu-v1.2.3.dmg" \
  "$work/input/appcast.xml" \
  "$work/input/Malibu-v1.2.3.dmg.sha256" >"$work/writable.out" 2>&1; then
  fail 'publication installer accepted a group/world-writable webroot'
fi
grep -q 'group/world-writable' "$work/writable.out" || fail 'writable webroot rejection was unclear'

ln -s "$work/webroot" "$work/symlink-webroot"
if MALIBU_PUBLICATION_TESTING=1 bash "$INSTALL_PUBLICATION" \
  "$work/symlink-webroot" v1.2.3 "$publication_id" \
  "$work/input/publication-manifest.json" \
  "$work/input/Malibu-v1.2.3.dmg" \
  "$work/input/appcast.xml" \
  "$work/input/Malibu-v1.2.3.dmg.sha256" >"$work/symlink.out" 2>&1; then
  fail 'publication installer accepted a symlinked webroot'
fi
grep -q 'symlinked publication path component' "$work/symlink.out" || fail 'symlink rejection was unclear'

ln "$work/input/Malibu-v1.2.3.dmg" "$work/input/hardlinked.dmg"
if MALIBU_PUBLICATION_TESTING=1 bash "$INSTALL_PUBLICATION" \
  "$work/fresh-webroot" v1.2.3 "$publication_id" \
  "$work/input/publication-manifest.json" \
  "$work/input/hardlinked.dmg" \
  "$work/input/appcast.xml" \
  "$work/input/Malibu-v1.2.3.dmg.sha256" >"$work/hardlink.out" 2>&1; then
  fail 'publication installer accepted a hardlinked staged input'
fi
grep -q 'unsafe staged publication input' "$work/hardlink.out" || fail 'hardlink rejection was unclear'

grep -q 'name.com' "$SETUP" || fail 'setup script should document name.com DNS'
grep -q -- '-o root -g root -m 0755 /var/www/malibu-download' "$SETUP" ||
  fail 'setup script must provision a root-owned publication graph'
grep -q 'malibu-download' "$NGINX" || fail 'nginx config should serve /var/www/malibu-download'
grep -q "'/appcast.xml'" "$VERIFY" || fail 'verify script should probe appcast.xml'

echo "PASS: Malibu publication security regression checks"
