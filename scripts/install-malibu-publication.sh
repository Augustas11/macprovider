#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[install-malibu-publication] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 7 ]] || die "usage: WEBROOT TAG PUBLICATION_ID MANIFEST DMG APPCAST SHA256"
webroot="$1"
tag="$2"
release_id="$3"
manifest_source="$4"
dmg_source="$5"
appcast_source="$6"
sha_source="$7"

[[ "$webroot" == /* ]] || die "webroot must be an absolute path"
[[ "$webroot" =~ ^/[A-Za-z0-9._/-]+$ && "$webroot" != *'/../'* && "$webroot" != */.. ]] || die "unsafe webroot"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag must be vX.Y.Z"
[[ "$tag" == v1.8.39 ]] || die "legacy Malibu publication is frozen to v1.8.39"
[[ "$release_id" =~ ^[0-9a-f]{64}$ ]] || die "publication id must be a full content digest"

testing="${MALIBU_PUBLICATION_TESTING:-0}"
if [[ "$testing" == 1 ]]; then
  trusted_uid="$(id -u)"
  trusted_gid="$(id -g)"
else
  [[ "$(id -u)" == 0 ]] || die "production publication helper must run as root"
  trusted_uid=0
  trusted_gid=0
fi

python3 - "$testing" "$trusted_uid" "$manifest_source" "$dmg_source" "$appcast_source" "$sha_source" "$tag" "$release_id" <<'PY'
import hashlib
import json
import os
import pathlib
import stat
import sys

testing, trusted_uid, manifest_name, dmg_name, appcast_name, sha_name, tag, publication_id = sys.argv[1:]
trusted_uid = int(trusted_uid)
paths = [pathlib.Path(value) for value in (manifest_name, dmg_name, appcast_name, sha_name)]
for path in paths:
    row = path.lstat()
    if not stat.S_ISREG(row.st_mode) or row.st_uid != trusted_uid or row.st_nlink != 1:
        raise SystemExit(f"unsafe staged publication input: {path}")
    if stat.S_IMODE(row.st_mode) & 0o022:
        raise SystemExit(f"staged publication input is group/world-writable: {path}")
    if testing != "1" and stat.S_IMODE(row.st_mode) != 0o600:
        raise SystemExit(f"staged publication input mode is not 0600: {path}")

manifest = json.loads(paths[0].read_text(encoding="utf-8"))
if manifest.get("schema_version") != 1 or manifest.get("tag") != tag or manifest.get("publication_id") != publication_id:
    raise SystemExit("publication manifest identity mismatch")
if manifest.get("prerelease") is not False:
    raise SystemExit("prerelease must not publish the stable Malibu feed")
assets = manifest.get("assets")
expected_names = [f"Malibu-{tag}.dmg", "appcast.xml"]
for path, name in zip(paths[1:3], expected_names):
    row = assets.get(name) if isinstance(assets, dict) else None
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if not isinstance(row, dict) or row.get("sha256") != digest or type(row.get("id")) is not int:
        raise SystemExit(f"publication manifest does not bind {name}")
expected_checksum = f"{hashlib.sha256(paths[1].read_bytes()).hexdigest()}  {expected_names[0]}\n"
if paths[3].read_text(encoding="utf-8") != expected_checksum:
    raise SystemExit("versioned DMG checksum file is invalid")
PY

dmg_name="Malibu-${tag}.dmg"
releases_dir="$webroot/.malibu-releases"
manifests_dir="$webroot/.malibu-tag-manifests"
release_dir="$releases_dir/$release_id"
stage="$releases_dir/.${release_id}.stage.$$"
tag_manifest="$manifests_dir/${tag}.json"
current="$webroot/.malibu-current"
temporary_links=()

cleanup() {
  rm -rf "$stage"
  if ((${#temporary_links[@]})); then
    rm -f "${temporary_links[@]}"
  fi
}
trap cleanup EXIT

validate_chain() {
  python3 - "$testing" "$trusted_uid" "$trusted_gid" "$1" <<'PY'
import os
import pathlib
import stat
import sys

testing, trusted_uid, trusted_gid, raw_path = sys.argv[1:]
trusted_uid, trusted_gid = int(trusted_uid), int(trusted_gid)
path = pathlib.Path(raw_path)
if not path.is_absolute():
    raise SystemExit(f"path is not absolute: {path}")
parts = path.parts
current = pathlib.Path(parts[0])
for part in parts[1:]:
    current /= part
    if not current.exists() and not current.is_symlink():
        continue
    # Test fixtures live below host-managed ancestors (for example macOS
    # /var -> /private/var). Production still validates every component.
    if testing == "1" and current != path:
        continue
    row = current.lstat()
    if stat.S_ISLNK(row.st_mode):
        raise SystemExit(f"symlinked publication path component: {current}")
    if not stat.S_ISDIR(row.st_mode):
        raise SystemExit(f"publication path component is not a directory: {current}")
    if row.st_uid != trusted_uid or row.st_gid != trusted_gid:
        raise SystemExit(f"publication directory has wrong owner: {current}")
    if stat.S_IMODE(row.st_mode) & 0o022:
        raise SystemExit(f"publication directory is group/world-writable: {current}")
PY
}

validate_node() {
  python3 - "$trusted_uid" "$trusted_gid" "$1" "$2" <<'PY'
import pathlib
import stat
import sys

uid, gid, raw_path, kind = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
path = pathlib.Path(raw_path)
row = path.lstat()
if row.st_uid != uid or row.st_gid != gid:
    raise SystemExit(f"publication node has wrong owner: {path}")
if kind == "dir":
    if not stat.S_ISDIR(row.st_mode) or stat.S_IMODE(row.st_mode) != 0o755:
        raise SystemExit(f"publication directory is not mode 0755: {path}")
elif kind == "file":
    if not stat.S_ISREG(row.st_mode) or row.st_nlink != 1 or stat.S_IMODE(row.st_mode) != 0o644:
        raise SystemExit(f"publication file is not root-owned regular mode 0644: {path}")
elif kind == "link":
    if not stat.S_ISLNK(row.st_mode):
        raise SystemExit(f"publication pointer is not a symlink: {path}")
else:
    raise SystemExit("invalid validation kind")
PY
}

validate_chain "$webroot"
install -d -o "$trusted_uid" -g "$trusted_gid" -m 0755 "$webroot" "$releases_dir" "$manifests_dir"
validate_chain "$webroot"
validate_node "$webroot" dir
validate_node "$releases_dir" dir
validate_node "$manifests_dir" dir

replace_symlink() {
  local target="$1" destination="$2" temporary
  temporary="${destination}.next.$$"
  temporary_links+=("$temporary")
  rm -f "$temporary"
  ln -s "$target" "$temporary"
  chown -h "$trusted_uid:$trusted_gid" "$temporary"
  if mv --help 2>&1 | grep -q -- '--no-target-directory'; then
    mv -Tf "$temporary" "$destination"
  else
    mv -fh "$temporary" "$destination"
  fi
}

ensure_immutable_link() {
  local target="$1" destination="$2"
  if [[ -L "$destination" ]]; then
    validate_node "$destination" link
    [[ "$(readlink "$destination")" == "$target" ]] || die "versioned pointer retarget refused: $destination"
  elif [[ -e "$destination" ]]; then
    die "versioned publication path is not its immutable pointer: $destination"
  else
    replace_symlink "$target" "$destination"
  fi
}

install -d -o "$trusted_uid" -g "$trusted_gid" -m 0755 "$stage"
install -o "$trusted_uid" -g "$trusted_gid" -m 0644 "$dmg_source" "$stage/latest.dmg"
install -o "$trusted_uid" -g "$trusted_gid" -m 0644 "$appcast_source" "$stage/appcast.xml"
install -o "$trusted_uid" -g "$trusted_gid" -m 0644 "$sha_source" "$stage/${dmg_name}.sha256"
install -o "$trusted_uid" -g "$trusted_gid" -m 0644 "$manifest_source" "$stage/publication-manifest.json"

if [[ -d "$release_dir" && ! -L "$release_dir" ]]; then
  validate_chain "$release_dir"
  validate_node "$release_dir" dir
  for name in latest.dmg appcast.xml "${dmg_name}.sha256" publication-manifest.json; do
    validate_node "$release_dir/$name" file
    cmp -s "$stage/$name" "$release_dir/$name" || die "immutable release differs: $release_dir/$name"
  done
  rm -rf "$stage"
elif [[ -e "$release_dir" || -L "$release_dir" ]]; then
  die "release path is not an immutable directory: $release_dir"
else
  mv "$stage" "$release_dir"
fi

if [[ -e "$tag_manifest" || -L "$tag_manifest" ]]; then
  validate_node "$tag_manifest" file
  cmp -s "$manifest_source" "$tag_manifest" || die "same-tag publication drift refused: $tag"
else
  temporary_manifest="${tag_manifest}.next.$$"
  install -o "$trusted_uid" -g "$trusted_gid" -m 0644 "$manifest_source" "$temporary_manifest"
  mv "$temporary_manifest" "$tag_manifest"
fi

if [[ -e "$current" && ! -L "$current" ]]; then
  die "atomic current pointer is not a symlink: $current"
fi

# A legacy pair may be migrated only after an operator has made it part of the
# root-owned, read-only graph. Non-root or writable files fail validation.
if [[ -f "$webroot/latest.dmg" && ! -L "$webroot/latest.dmg" &&
      -f "$webroot/appcast.xml" && ! -L "$webroot/appcast.xml" &&
      ! -e "$current" && ! -L "$current" ]]; then
  validate_node "$webroot/latest.dmg" file
  validate_node "$webroot/appcast.xml" file
  bootstrap_id="bootstrap-${release_id}"
  bootstrap_dir="$releases_dir/$bootstrap_id"
  install -d -o "$trusted_uid" -g "$trusted_gid" -m 0755 "$bootstrap_dir"
  install -o "$trusted_uid" -g "$trusted_gid" -m 0644 "$webroot/latest.dmg" "$bootstrap_dir/latest.dmg"
  install -o "$trusted_uid" -g "$trusted_gid" -m 0644 "$webroot/appcast.xml" "$bootstrap_dir/appcast.xml"
  replace_symlink ".malibu-releases/$bootstrap_id" "$current"
fi

ensure_public_entry() {
  local name="$1" path="$webroot/$1" expected_target=".malibu-current/$1"
  if [[ -L "$path" ]]; then
    validate_node "$path" link
    [[ "$(readlink "$path")" == "$expected_target" ]] || die "$path has an unexpected symlink target"
  elif [[ -f "$path" ]]; then
    validate_node "$path" file
    [[ -L "$current" && -f "$current/$name" ]] || die "cannot safely migrate regular file: $path"
    cmp -s "$path" "$current/$name" || die "regular file disagrees with current publication: $path"
    replace_symlink "$expected_target" "$path"
  elif [[ -e "$path" ]]; then
    die "public entry is neither a regular file nor symlink: $path"
  else
    replace_symlink "$expected_target" "$path"
  fi
}

ensure_public_entry latest.dmg
ensure_public_entry appcast.xml
ensure_immutable_link ".malibu-releases/$release_id/latest.dmg" "$webroot/$dmg_name"
ensure_immutable_link ".malibu-releases/$release_id/${dmg_name}.sha256" "$webroot/${dmg_name}.sha256"

# This single same-filesystem rename is the public transaction boundary for
# both latest.dmg and appcast.xml. nginx has read/execute access only.
replace_symlink ".malibu-releases/$release_id" "$current"

printf '[install-malibu-publication] ok: %s -> %s\n' "$current" "$release_id"
