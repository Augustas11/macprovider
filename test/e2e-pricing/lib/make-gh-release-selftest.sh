#!/usr/bin/env bash
# Self-test for lib/make-gh-release.sh. Local only: it never starts the VM or
# touches the real harness work dir (E2E_WORK is a temp dir). It builds a
# stand-in release for a post-cutoff scratch tag (v90.1.0, like E2E_TAG_ENABLE)
# and proves scripts/verify-pearl-runtime-release.sh accepts it in both the
# --release-dir path and the gh-shim download path, including the #1842
# provider_code_identity binding to the stand-in CLI tarball.
#   bash test/e2e-pricing/lib/make-gh-release-selftest.sh
set -euo pipefail
H="$(cd "$(dirname "$0")/.." && pwd -P)"
SRC="$(cd "$H/../.." && pwd -P)"
W="$(mktemp -d "${TMPDIR:-/tmp}/make-gh-release-selftest.XXXXXX")"
trap 'rm -rf "$W"' EXIT
fail() { printf '[make-gh-release-selftest] FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf '[make-gh-release-selftest] ok: %s\n' "$*"; }

tag=v90.1.0
export E2E_WORK="$W/work"
mkdir -p "$E2E_WORK/keys" "$E2E_WORK/bins/$tag"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
  -out "$E2E_WORK/keys/release-signing.key" >/dev/null 2>&1

# Scratch repo holding the tag's catalog inputs, plus a bare remote for the
# tag-target check.
repo="$E2E_WORK/repo"
mkdir -p "$repo/phase3-binary/catalog/autotune" "$repo/phase3-binary/dist/static"
for f in release.json trusted-keys.json tier2-catalog.json; do
  cp "$SRC/phase3-binary/catalog/autotune/$f" "$repo/phase3-binary/catalog/autotune/$f"
done
for f in autotune-candidates.json demand-rank.json rate-card.json continuous-batching-policy.json; do
  cp "$SRC/phase3-binary/dist/static/$f" "$SRC/phase3-binary/dist/static/$f.sig" "$repo/phase3-binary/dist/static/"
done
git -C "$repo" init -q
git -C "$repo" -c user.name=e2e -c user.email=e2e@example.invalid add -A
git -C "$repo" -c user.name=e2e -c user.email=e2e@example.invalid commit -q -m "e2e scratch release inputs"
git -C "$repo" tag "$tag"
commit="$(git -C "$repo" rev-parse HEAD)"
git clone -q --bare "$repo" "$W/remote.git"

for bin in coordinator coordinator-cli gateway stats-inventory-sync stats-billing-mirror stats-hardware-verifier; do
  printf 'e2e %s\n' "$bin" >"$E2E_WORK/bins/$tag/$bin-linux-amd64"
done

bash "$H/lib/make-gh-release.sh" "$tag" 2>"$W/make.err" || { cat "$W/make.err" >&2; fail "make-gh-release.sh failed"; }
release="$E2E_WORK/gh-releases/$tag"
[ -f "$release/macprovider-cli-$tag-darwin-arm64.tar.gz" ] || fail "stand-in provider CLI tarball is missing"
python3 - "$release/pearl-release.json" "$tag" <<'PY' || fail "pearl-release.json lacks a valid provider_code_identity"
import json, sys
identity = json.load(open(sys.argv[1], encoding="utf-8"))["provider_code_identity"]
tag = sys.argv[2]
assert identity["asset"] == f"macprovider-cli-{tag}-darwin-arm64.tar.gz", identity
assert identity["binary_version"] == tag[1:], identity
assert identity["signing_identifier"] == "live.malibu.provider.cli", identity
assert identity["team_id"] == "E2ETEAM001", identity
PY
ok "stand-in release carries provider_code_identity and the CLI tarball"

bash "$SRC/scripts/verify-pearl-runtime-release.sh" --tag "$tag" --expected-commit "$commit" \
  --remote "$W/remote.git" --release-dir "$release" >"$W/verify-dir.out" 2>&1 ||
  { cat "$W/verify-dir.out" >&2; fail "verify-pearl-runtime-release.sh --release-dir rejected the stand-in"; }
grep -q "ok: $tag has Pearl runtime assets" "$W/verify-dir.out" || fail "release-dir verify did not report ok"
ok "verify-pearl-runtime-release.sh --release-dir accepts the stand-in"

PATH="$H/bin:$PATH" bash "$SRC/scripts/verify-pearl-runtime-release.sh" --tag "$tag" --expected-commit "$commit" \
  --remote "$W/remote.git" >"$W/verify-gh.out" 2>&1 ||
  { cat "$W/verify-gh.out" >&2; fail "verify-pearl-runtime-release.sh via the gh shim rejected the stand-in"; }
grep -q "ok: $tag has Pearl runtime assets" "$W/verify-gh.out" || fail "gh-shim verify did not report ok"
ok "verify-pearl-runtime-release.sh via the gh shim downloads and binds the CLI tarball"

# The binding is real: a different CLI in the tarball (checksums regenerated)
# must fail on binary_sha256.
printf 'tampered\n' >"$W/macprovider-cli"
tar -czf "$release/macprovider-cli-$tag-darwin-arm64.tar.gz" -C "$W" macprovider-cli
(cd "$release" && for n in *; do case "$n" in checksums.txt*) ;; *) printf '%s  %s\n' "$(shasum -a 256 "$n" | cut -d' ' -f1)" "$n" ;; esac; done) >"$release/checksums.txt"
if PATH="$H/bin:$PATH" bash "$SRC/scripts/verify-pearl-runtime-release.sh" --tag "$tag" --expected-commit "$commit" \
  --remote "$W/remote.git" >"$W/verify-tampered.out" 2>&1; then
  fail "gh-shim verify accepted a CLI tarball that differs from binary_sha256"
fi
grep -q 'binary_sha256 does not match the shipped macprovider-cli' "$W/verify-tampered.out" ||
  { cat "$W/verify-tampered.out" >&2; fail "tampered CLI failed for the wrong reason"; }
ok "a swapped stand-in CLI fails the binary_sha256 binding"
