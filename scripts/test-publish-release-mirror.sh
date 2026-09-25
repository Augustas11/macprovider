#!/usr/bin/env bash
# Hermetic tests for scripts/publish-release-mirror.sh (issue #1737): the
# updater index contract, byte identity against GitHub's asset digests, the
# immutable and unsafe-name guards, and --promote-latest gating. gh, curl, ssh,
# and scp are PATH stubs; nothing touches the network or Pearl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PUBLISH="$REPO_ROOT/scripts/publish-release-mirror.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/publish-release-mirror-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() { printf '[test-publish-release-mirror] FAIL: %s\n' "$*" >&2; exit 1; }
pass=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }

bash -n "$PUBLISH"

TAG="v1.8.200"
FIXTURE="$TMP/fixture"
BIN="$TMP/bin"
mkdir -p "$FIXTURE/assets" "$BIN"

# Pinned python tarball served by the curl stub must match install.sh's pin, so
# the stub serves a file whose hash we substitute into a copy of the repo layout.
PY_BYTES="$TMP/python.tar.gz"
printf 'pinned python bytes\n' > "$PY_BYTES"
PY_SHA="$(sha256sum "$PY_BYTES" | awk '{print $1}')"
FAKE_ROOT="$TMP/repo"
mkdir -p "$FAKE_ROOT/scripts" "$FAKE_ROOT/phase3-binary/dist"
cp "$PUBLISH" "$FAKE_ROOT/scripts/publish-release-mirror.sh"
cat > "$FAKE_ROOT/phase3-binary/dist/install.sh" <<EOF
BOOTSTRAP_PYTHON_RELEASE="20260901"
BOOTSTRAP_PYTHON_ASSET="cpython-3.12.14+20260901-aarch64-apple-darwin-install_only_stripped.tar.gz"
BOOTSTRAP_PYTHON_SHA256="$PY_SHA"
EOF

write_asset() { printf '%s\n' "$2" > "$FIXTURE/assets/$1"; }
write_asset "macprovider-cli-$TAG-darwin-arm64.tar.gz" "tarball bytes"
write_asset "checksums.txt" "abc  macprovider-cli-$TAG-darwin-arm64.tar.gz"
write_asset "checksums.txt.sig" "signature"
write_asset "Malibu-$TAG.dmg" "dmg bytes"
write_asset "compatibility-artifact-index.json" "{}"
# Real releases ship an asset named release.json (the autotune feed, v1.8.123).
# It must be mirrored verbatim, which is why the updater index lives elsewhere.
write_asset "release.json" '{"feed": "autotune"}'

# write_release_api [prerelease] [draft] [extra python edit]
write_release_api() {
  python3 - "$FIXTURE/assets" "$TAG" "${1:-false}" "${2:-false}" "$FIXTURE/release.json" "${3:-}" <<'PY'
import hashlib, json, os, sys
assets_dir, tag, prerelease, draft, out, edit = sys.argv[1:]
assets = []
for name in sorted(os.listdir(assets_dir), reverse=True):
    data = open(os.path.join(assets_dir, name), "rb").read()
    assets.append({"name": name, "size": len(data), "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
                   "browser_download_url": f"https://github.com/Augustas11/macprovider/releases/download/{tag}/{name}"})
release = {"tag_name": tag, "draft": draft == "true", "prerelease": prerelease == "true", "assets": assets}
if edit:
    exec(edit)
json.dump(release, open(out, "w"))
PY
}

cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\$1 \$2" in
  "api -H")
    [ "\$4" = "repos/Augustas11/macprovider/releases/tags/$TAG" ] || exit 1
    cat "$FIXTURE/release.json"
    ;;
  "release download")
    dir=""
    while [ \$# -gt 0 ]; do [ "\$1" = "--dir" ] && dir="\$2"; shift; done
    cp "$FIXTURE/assets/"* "\$dir"/
    if [ -n "\${MOCK_DOWNLOAD_TAMPER:-}" ]; then printf 'tampered\n' >> "\$dir/\$MOCK_DOWNLOAD_TAMPER"; fi
    if [ -n "\${MOCK_DOWNLOAD_EXTRA:-}" ]; then printf 'x\n' > "\$dir/\$MOCK_DOWNLOAD_EXTRA"; fi
    ;;
  *) echo "unexpected gh \$*" >&2; exit 1 ;;
esac
EOF
cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
out=""; url=""
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out="\$2"; shift ;; https://*) url="\$1" ;; esac
  shift
done
case "\$url" in
  https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.12.14+20260901-aarch64-apple-darwin-install_only_stripped.tar.gz)
    cp "$PY_BYTES" "\$out" ;;
  https://coordinator.malibu.tech/healthz)
    printf '{"recommended_binary_version":"%s"}' "\${MOCK_ADVERTISED:-1.8.200}" ;;
  https://download.malibu.tech/releases/latest.json)
    [ -n "\${MOCK_SERVED_LATEST:-}" ] || exit 22
    printf '{"tag_name":"%s"}' "\$MOCK_SERVED_LATEST" ;;
  *) echo "unexpected curl \$url" >&2; exit 2 ;;
esac
EOF
for tool in ssh scp; do
  printf '#!/usr/bin/env bash\necho "%s must not run in --stage-only" >&2\nexit 99\n' "$tool" > "$BIN/$tool"
done
chmod +x "$BIN"/*

run_stage() { # <out-dir> [args...]
  local dir="$1"; shift
  PATH="$BIN:$PATH" GITHUB_REPOSITORY="Augustas11/macprovider" \
    bash "$FAKE_ROOT/scripts/publish-release-mirror.sh" --tag "$TAG" --stage-only "$dir" "$@"
}

# 1 — happy path: exact updater index contract (outside the tag directory) and
# byte-identical assets, including a GitHub asset that is itself named release.json.
write_release_api false
run_stage "$TMP/out1" >/dev/null
python3 - "$TMP/out1/releases/index/$TAG.json" "$TAG" "$FIXTURE/assets" <<'PY' || fail "release.json contract"
import json, os, sys
path, tag, assets_dir = sys.argv[1:]
raw = open(path, encoding="utf-8").read()
doc = json.loads(raw)
names = sorted(os.listdir(assets_dir))
expected = {
    "tag_name": tag,
    "draft": False,
    "prerelease": False,
    "assets": [{"name": n, "browser_download_url": f"https://download.malibu.tech/releases/{tag}/{n}"} for n in names],
}
assert doc == expected, doc
assert raw == json.dumps(expected, indent=2, sort_keys=True) + "\n", "updater index is not deterministic"
PY
ok "updater-index-contract"
cmp -s "$FIXTURE/assets/release.json" "$TMP/out1/releases/$TAG/release.json" ||
  fail "the GitHub asset named release.json was not mirrored verbatim"
ok "release-json-asset-mirrored-verbatim"
for asset in "$FIXTURE/assets"/*; do
  cmp -s "$asset" "$TMP/out1/releases/$TAG/$(basename "$asset")" || fail "mirrored $(basename "$asset") differs"
done
[ "$(find "$TMP/out1/releases/$TAG" -type f | wc -l | tr -d ' ')" -eq 6 ] || fail "mirror tree has extra files"
ok "assets-byte-identical"
cmp -s "$PY_BYTES" "$TMP/out1/python/cpython-3.12.14+20260901-aarch64-apple-darwin-install_only_stripped.tar.gz" ||
  fail "pinned python tarball not staged"
ok "python-pin-staged"
[ ! -e "$TMP/out1/releases/latest.json" ] || fail "latest.json written without --promote-latest"
ok "no-latest-without-promotion"

# 2 — prerelease flag carries through verbatim.
write_release_api true
run_stage "$TMP/out2" >/dev/null
python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["prerelease"] is True' \
  "$TMP/out2/releases/index/$TAG.json" || fail "prerelease flag not preserved"
ok "prerelease-preserved"

expect_refusal() { # <name> <out-dir> [env assignments...] -- [args...]
  local name="$1" dir="$2"; shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" != "--" ] || shift
  if env "${envs[@]}" PATH="$BIN:$PATH" GITHUB_REPOSITORY="Augustas11/macprovider" \
    bash "$FAKE_ROOT/scripts/publish-release-mirror.sh" --tag "$TAG" --stage-only "$dir" "$@" >/dev/null 2>&1; then
    fail "$name: expected refusal"
  fi
  [ ! -e "$dir/releases/index/$TAG.json" ] || fail "$name: updater index written despite refusal"
  ok "$name"
}

# 3 — byte identity: a downloaded asset that differs from GitHub's digest.
write_release_api false
expect_refusal "tampered-download-refused" "$TMP/out3" MOCK_DOWNLOAD_TAMPER="Malibu-$TAG.dmg"
# 4 — the downloaded set must equal the release's asset list exactly.
expect_refusal "extra-download-refused" "$TMP/out4" MOCK_DOWNLOAD_EXTRA="unlisted.bin"
# 5 — drafts, missing digests, and unsafe names are refused.
write_release_api false true
expect_refusal "draft-refused" "$TMP/out5"
write_release_api false false 'release["assets"][0].pop("digest")'
expect_refusal "missing-digest-refused" "$TMP/out6"
write_release_api false false 'release["assets"][0]["name"] = "../escape"'
expect_refusal "unsafe-name-refused" "$TMP/out7"
write_release_api false false 'release["tag_name"] = "v1.8.199"'
expect_refusal "tag-mismatch-refused" "$TMP/out9"

# 6 — --promote-latest: only a stable tag the coordinator advertises, never a
# regression of the served pointer.
write_release_api false
run_stage "$TMP/out10" --promote-latest >/dev/null
[ "$(cat "$TMP/out10/releases/latest.json")" = '{"tag_name": "v1.8.200"}' ] || fail "latest.json content"
ok "promote-latest-writes-pointer"
expect_refusal "promote-unadvertised-refused" "$TMP/out11" MOCK_ADVERTISED=1.8.199 -- --promote-latest
expect_refusal "promote-regression-refused" "$TMP/out12" MOCK_SERVED_LATEST=v1.8.201 -- --promote-latest
write_release_api true
expect_refusal "promote-prerelease-refused" "$TMP/out13" -- --promote-latest

# 7 — only the canonical repository and canonical tags are accepted.
write_release_api false
if PATH="$BIN:$PATH" GITHUB_REPOSITORY="someone/fork" \
  bash "$FAKE_ROOT/scripts/publish-release-mirror.sh" --tag "$TAG" --stage-only "$TMP/out14" >/dev/null 2>&1; then
  fail "fork repository accepted"
fi
ok "fork-refused"
rc=0
PATH="$BIN:$PATH" bash "$FAKE_ROOT/scripts/publish-release-mirror.sh" --tag "v1.8" --stage-only "$TMP/out15" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "non-canonical tag must be a usage error (got $rc)"
ok "bad-tag-usage-error"

# 8 — upload path. ssh/scp run the Pearl-side script locally with /root/ mapped
# into $TMP and root ownership stubbed; curl serves the fake webroot back so the
# served-byte verification runs for real.
UP="$TMP/upload"
REMOTE_BIN="$UP/remote-bin"
WEBROOT="$UP/www"
mkdir -p "$UP/bin" "$REMOTE_BIN" "$WEBROOT" "$UP/root"
cp "$BIN/gh" "$UP/bin/gh"
cat > "$REMOTE_BIN/chown" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$REMOTE_BIN/install" <<'EOF'
#!/usr/bin/env bash
# Minimal `install` without ownership changes: -d DIR... or SRC DST.
set -euo pipefail
dirs=0; mode=""; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -d) dirs=1 ;;
    -o|-g) shift ;;
    -m) mode="$2"; shift ;;
    *) args+=("$1") ;;
  esac
  shift
done
if [ "$dirs" = 1 ]; then mkdir -p "${args[@]}"; [ -z "$mode" ] || chmod "$mode" "${args[@]}"; exit 0; fi
cp "${args[0]}" "${args[1]}"
[ -z "$mode" ] || chmod "$mode" "${args[1]}"
EOF
cat > "$UP/bin/ssh" <<EOF
#!/usr/bin/env bash
cmd="\${@: -1}"
printf '%s\n' "\$cmd" >> "$UP/ssh.log"
cmd="\${cmd//\/root\//$UP/root/}"
set -o pipefail
PATH="$REMOTE_BIN:\$PATH" bash -c "\$cmd" | sed "s#$UP/root/#/root/#g"
EOF
cat > "$UP/bin/scp" <<EOF
#!/usr/bin/env bash
src="\${@: -2:1}"; dst="\${@: -1}"
dst="\${dst#*:}"
cp "\$src" "\${dst/\/root\//$UP/root/}"
EOF
cat > "$UP/bin/curl" <<EOF
#!/usr/bin/env bash
orig=("\$@"); out=""; url=""
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out="\$2"; shift ;; https://*) url="\$1" ;; esac
  shift
done
case "\$url" in
  https://download.malibu.tech/*)
    path="$WEBROOT/\${url#https://download.malibu.tech/}"
    [ -f "\$path" ] || exit 22
    if [ -n "\$out" ]; then cp "\$path" "\$out"; else cat "\$path"; fi ;;
  *) exec "$BIN/curl" "\${orig[@]}" ;;
esac
EOF
chmod +x "$UP/bin"/* "$REMOTE_BIN"/*
printf 'dummy key\n' > "$UP/key"

run_upload() {
  PATH="$UP/bin:$PATH" GITHUB_REPOSITORY="Augustas11/macprovider" \
    MALIBU_DOWNLOAD_SSH_KEY="$UP/key" MALIBU_DOWNLOAD_WEBROOT="$WEBROOT" \
    MALIBU_DOWNLOAD_KNOWN_HOSTS="$REPO_ROOT/scripts/dist/malibu-download-known_hosts" \
    bash "$FAKE_ROOT/scripts/publish-release-mirror.sh" --tag "$TAG" "$@"
}
mkdir -p "$FAKE_ROOT/scripts/dist"
cp "$REPO_ROOT/scripts/malibu-download-ssh.sh" "$FAKE_ROOT/scripts/"

write_release_api false
run_upload --promote-latest >/dev/null || fail "upload publish failed"
for asset in "$FIXTURE/assets"/*; do
  cmp -s "$asset" "$WEBROOT/releases/$TAG/$(basename "$asset")" || fail "published $(basename "$asset") differs"
done
cmp -s "$TMP/out1/releases/index/$TAG.json" "$WEBROOT/releases/index/$TAG.json" || fail "updater index not published"
[ "$(cat "$WEBROOT/releases/latest.json")" = '{"tag_name": "v1.8.200"}' ] || fail "latest.json not published"
cmp -s "$PY_BYTES" "$WEBROOT/python/cpython-3.12.14+20260901-aarch64-apple-darwin-install_only_stripped.tar.gz" ||
  fail "python tarball not published"
ok "upload-publishes-tree"

run_upload >/dev/null || fail "identical republish must be a no-op success"
ok "upload-idempotent"

printf 'changed\n' >> "$WEBROOT/releases/$TAG/checksums.txt"
if run_upload >/dev/null 2>&1; then fail "a differing published release must not be overwritten"; fi
grep -q changed "$WEBROOT/releases/$TAG/checksums.txt" || fail "immutable release was modified"
ok "upload-refuses-to-patch-published-release"

printf '[test-publish-release-mirror] all %d checks passed\n' "$pass"
