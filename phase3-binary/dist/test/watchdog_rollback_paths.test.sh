#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
STANDALONE="$REPO_ROOT/ops/macprovider-watchdog/watchdog.sh"
INSTALLER="$REPO_ROOT/phase3-binary/dist/install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

extract_inline_watchdog() {
  awk '
    /cat <<.WATCHDOG_EOF. > "\$WATCHDOG_PATH"/ { inside=1; next }
    inside && /^WATCHDOG_EOF$/ { exit }
    inside { print }
  ' "$INSTALLER"
}

INLINE="$TMP/watchdog-inline.sh"
extract_inline_watchdog > "$INLINE"
[ -s "$INLINE" ] || { echo "failed to extract installer watchdog" >&2; exit 1; }
chmod +x "$INLINE"

make_fixture() {
  root="$1"
  mkdir -p "$root/home/.local/share/macprovider/autoupdate" "$root/bin" "$root/logs"
  printf "new-binary" > "$root/bin/macprovider-cli"
  printf "old-binary" > "$root/bin/.macprovider-cli.rollback-123e4567-e89b-42d3-a456-426614174000"
  chmod 755 "$root/bin/macprovider-cli" "$root/bin/.macprovider-cli.rollback-123e4567-e89b-42d3-a456-426614174000"
  hash="$(shasum -a 256 "$root/bin/.macprovider-cli.rollback-123e4567-e89b-42d3-a456-426614174000" | awk '{print $1}')"
  cat > "$root/home/.local/share/macprovider/autoupdate/pending.json" <<EOF
{"update_id":"123e4567-e89b-42d3-a456-426614174000","target_version":"1.8.10","target_path":"$root/bin/macprovider-cli","backup_path":"$root/bin/.macprovider-cli.rollback-123e4567-e89b-42d3-a456-426614174000","size":10,"mode":493,"sha256":"$hash","marker_deadline":"2000-01-01T00:00:00Z"}
EOF
  : > "$root/launchctl.log"
  cat > "$root/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MACPROVIDER_FAKE_LAUNCHCTL_LOG"
if [ "${1:-}" = "print" ]; then
  printf 'pid = 123\nlast exit status = 0\n'
fi
EOF
  chmod +x "$root/bin/launchctl"
}

add_full_release_fixture() {
  root="$1"
  python3 - "$root" <<'PY'
import hashlib
import json
import os
import stat
import sys

root = sys.argv[1]
binary_dir = os.path.join(root, "bin")
pending = os.path.join(root, "home/.local/share/macprovider/autoupdate/pending.json")
update_id = "123e4567-e89b-42d3-a456-426614174000"
release_backup = os.path.join(binary_dir, f".macprovider-cli.release-rollback-{update_id}")

def write(path, body):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(body)
    os.chmod(path, 0o644)

for relative, body in {
    "mlx.metallib": "old-metal",
    "THIRD-PARTY-NOTICES.txt": "old-notices",
    "Runtime.bundle/resource": "old-bundle",
    "catalog-release/release.json": "old-catalog",
}.items():
    write(os.path.join(release_backup, relative), body)
for current, directories, _ in os.walk(release_backup):
    os.chmod(current, 0o700 if current == release_backup else 0o755)

for relative, body in {
    "mlx.metallib": "new-metal",
    "THIRD-PARTY-NOTICES.txt": "new-notices",
    "Runtime.bundle/resource": "new-bundle",
    "NewOnly.bundle/resource": "new-only",
    "catalog-release/release.json": "new-catalog",
}.items():
    write(os.path.join(binary_dir, relative), body)

def file_sha(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

records = []
for current, directories, files in os.walk(release_backup):
    directories.sort()
    files.sort()
    for name in directories + files:
        path = os.path.join(current, name)
        item = os.lstat(path)
        relative = os.path.relpath(path, release_backup)
        mode = stat.S_IMODE(item.st_mode)
        if stat.S_ISDIR(item.st_mode):
            record = f"d\0{relative}\0{mode}\0"
        else:
            record = f"f\0{relative}\0{mode}\0{item.st_size}\0{file_sha(path)}\0"
        records.append((relative, record.encode()))
digest = hashlib.sha256()
for _, record in sorted(records):
    digest.update(record)

with open(pending, encoding="utf-8") as handle:
    marker = json.load(handle)
marker["release_backup_path"] = release_backup
marker["release_backup_sha256"] = digest.hexdigest()
with open(pending, "w", encoding="utf-8") as handle:
    json.dump(marker, handle, sort_keys=True, separators=(",", ":"))
PY
}

run_reconcile() {
  script="$1"
  root="$2"
  HOME="$root/home" \
  MACPROVIDER_BINARY_PATH="$root/bin/macprovider-cli" \
  MACPROVIDER_LOG_DIR="$root/logs" \
  MACPROVIDER_FAKE_LAUNCHCTL_LOG="$root/launchctl.log" \
  PATH="$root/bin:$PATH" \
  bash "$script" --reconcile-autoupdate
  cmp -s "$root/bin/macprovider-cli" <(printf "old-binary")
  [ ! -e "$root/home/.local/share/macprovider/autoupdate/pending.json" ]
  grep -F "bootstrap gui/" "$root/launchctl.log" >/dev/null
  grep -F "kickstart -k gui/" "$root/launchctl.log" >/dev/null
}

make_fixture "$TMP/standalone"
run_reconcile "$STANDALONE" "$TMP/standalone"

make_fixture "$TMP/inline"
run_reconcile "$INLINE" "$TMP/inline"

make_fixture "$TMP/full-standalone"
add_full_release_fixture "$TMP/full-standalone"
run_reconcile "$STANDALONE" "$TMP/full-standalone"
cmp -s "$TMP/full-standalone/bin/mlx.metallib" <(printf "old-metal")
cmp -s "$TMP/full-standalone/bin/THIRD-PARTY-NOTICES.txt" <(printf "old-notices")
cmp -s "$TMP/full-standalone/bin/Runtime.bundle/resource" <(printf "old-bundle")
cmp -s "$TMP/full-standalone/bin/catalog-release/release.json" <(printf "old-catalog")
[ ! -e "$TMP/full-standalone/bin/NewOnly.bundle" ]
[ ! -e "$TMP/full-standalone/bin/.macprovider-cli.release-rollback-123e4567-e89b-42d3-a456-426614174000" ]

make_fixture "$TMP/full-inline"
add_full_release_fixture "$TMP/full-inline"
run_reconcile "$INLINE" "$TMP/full-inline"
cmp -s "$TMP/full-inline/bin/mlx.metallib" <(printf "old-metal")
cmp -s "$TMP/full-inline/bin/catalog-release/release.json" <(printf "old-catalog")
[ ! -e "$TMP/full-inline/bin/NewOnly.bundle" ]

echo "watchdog rollback paths ok"
