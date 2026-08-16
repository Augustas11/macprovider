#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[install-agent-onboarding-publication] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 4 ]] || die "usage: WEBROOT SKILL INDEX VALIDATOR"
webroot="$1"
skill_source="$2"
index_source="$3"
validator="$4"

[[ "$webroot" == /* ]] || die "webroot must be an absolute path"
[[ "$webroot" =~ ^/[A-Za-z0-9._/-]+$ && "$webroot" != *'/../'* && "$webroot" != */.. ]] ||
  die "unsafe webroot"

testing="${MALIBU_PUBLICATION_TESTING:-0}"
if [[ "$testing" == 1 ]]; then
  trusted_uid="$(id -u)"
  trusted_gid="$(id -g)"
else
  [[ "$(id -u)" == 0 ]] || die "production publication helper must run as root"
  trusted_uid=0
  trusted_gid=0
fi

for path in "$skill_source" "$index_source" "$validator"; do
  [[ -f "$path" && ! -L "$path" ]] || die "expected regular staged input: $path"
done

PYTHONDONTWRITEBYTECODE=1 python3 "$validator" \
  --skill "$skill_source" --index "$index_source" --no-reference-existence

publication_id="$(python3 - "$testing" "$trusted_uid" "$skill_source" "$index_source" "$validator" <<'PY'
import hashlib
import json
import pathlib
import stat
import sys

testing, trusted_uid, skill_name, index_name, validator_name = sys.argv[1:]
trusted_uid = int(trusted_uid)
paths = [pathlib.Path(value) for value in (skill_name, index_name, validator_name)]
for path in paths:
    row = path.lstat()
    if not stat.S_ISREG(row.st_mode) or row.st_uid != trusted_uid or row.st_nlink != 1:
        raise SystemExit(f"unsafe staged input: {path}")
    if stat.S_IMODE(row.st_mode) & 0o022:
        raise SystemExit(f"staged input is group/world-writable: {path}")
    if testing != "1" and stat.S_IMODE(row.st_mode) != 0o600:
        raise SystemExit(f"staged input mode is not 0600: {path}")
identity = {
    "skill_sha256": hashlib.sha256(paths[0].read_bytes()).hexdigest(),
    "index_sha256": hashlib.sha256(paths[1].read_bytes()).hexdigest(),
}
print(hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()).hexdigest())
PY
)"

releases_dir="$webroot/.agent-onboarding-releases"
release_dir="$releases_dir/$publication_id"
stage="$releases_dir/.${publication_id}.stage.$$"
current="$webroot/.agent-onboarding-current"
temporary_links=()

cleanup() {
  rm -rf "$stage"
  if ((${#temporary_links[@]})); then
    rm -f "${temporary_links[@]}"
  fi
}
trap cleanup EXIT

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
        raise SystemExit(f"publication file is not regular mode 0644: {path}")
elif kind == "link":
    if not stat.S_ISLNK(row.st_mode):
        raise SystemExit(f"publication pointer is not a symlink: {path}")
else:
    raise SystemExit("invalid validation kind")
PY
}

preflight_current_pointer() {
  if [[ -L "$current" ]]; then
    validate_node "$current" link
    local target
    target="$(readlink "$current")"
    [[ "$target" =~ ^\.agent-onboarding-releases/[0-9a-f]{64}$ ]] ||
      die "$current has an unexpected symlink target"
    local target_dir="$webroot/$target"
    [[ -d "$target_dir" && ! -L "$target_dir" ]] || die "current target is not an immutable release directory"
    validate_node "$target_dir" dir
    validate_node "$target_dir/skill.md" file
    validate_node "$target_dir/.well-known" dir
    validate_node "$target_dir/.well-known/skills" dir
    validate_node "$target_dir/.well-known/skills/index.json" file
  elif [[ -e "$current" ]]; then
    die "$current is not a symlink"
  fi
}

preflight_public_link() {
  local path="$1" expected_target="$2"
  if [[ -L "$path" ]]; then
    validate_node "$path" link
    [[ "$(readlink "$path")" == "$expected_target" ]] ||
      die "$path has an unexpected symlink target"
  elif [[ -e "$path" ]]; then
    die "$path is not a symlink"
  fi
}

preflight_existing_webroot() {
  [[ -e "$webroot" ]] || return 0
  validate_node "$webroot" dir
  if [[ -e "$releases_dir" || -L "$releases_dir" ]]; then
    validate_node "$releases_dir" dir
  fi
  if [[ -e "$webroot/.well-known" || -L "$webroot/.well-known" ]]; then
    validate_node "$webroot/.well-known" dir
  fi
  if [[ -e "$webroot/.well-known/skills" || -L "$webroot/.well-known/skills" ]]; then
    validate_node "$webroot/.well-known/skills" dir
  fi
  preflight_current_pointer
  preflight_public_link "$webroot/skill.md" ".agent-onboarding-current/skill.md"
  preflight_public_link "$webroot/.well-known/skills/index.json" \
    "../../.agent-onboarding-current/.well-known/skills/index.json"
}

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

preflight_existing_webroot
install -d -o "$trusted_uid" -g "$trusted_gid" -m 0755 \
  "$webroot" "$releases_dir" "$webroot/.well-known" "$webroot/.well-known/skills"
validate_node "$webroot" dir
validate_node "$releases_dir" dir
validate_node "$webroot/.well-known" dir
validate_node "$webroot/.well-known/skills" dir

install -d -o "$trusted_uid" -g "$trusted_gid" -m 0755 "$stage" "$stage/.well-known" "$stage/.well-known/skills"
install -o "$trusted_uid" -g "$trusted_gid" -m 0644 "$skill_source" "$stage/skill.md"
install -o "$trusted_uid" -g "$trusted_gid" -m 0644 "$index_source" "$stage/.well-known/skills/index.json"

if [[ -d "$release_dir" && ! -L "$release_dir" ]]; then
  validate_node "$release_dir/skill.md" file
  validate_node "$release_dir/.well-known/skills/index.json" file
  cmp -s "$stage/skill.md" "$release_dir/skill.md" ||
    die "immutable agent skill release differs"
  cmp -s "$stage/.well-known/skills/index.json" "$release_dir/.well-known/skills/index.json" ||
    die "immutable agent index release differs"
  rm -rf "$stage"
elif [[ -e "$release_dir" || -L "$release_dir" ]]; then
  die "agent release path is not an immutable directory: $release_dir"
else
  mv "$stage" "$release_dir"
fi

replace_symlink ".agent-onboarding-releases/$publication_id" "$current"
replace_symlink ".agent-onboarding-current/skill.md" "$webroot/skill.md"
replace_symlink "../../.agent-onboarding-current/.well-known/skills/index.json" \
  "$webroot/.well-known/skills/index.json"

printf '[install-agent-onboarding-publication] ok: %s -> %s\n' "$current" "$publication_id"
