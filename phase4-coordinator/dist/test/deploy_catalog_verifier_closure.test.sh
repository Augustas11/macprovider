#!/usr/bin/env bash
# #1688: scripts/catalog-verifier-bundle.txt is the single list of files every
# shipped copy of scripts/catalog-release.py needs beside it. Pin that
# deploy-pearl-vps.sh and the Pearl updater installer ship exactly that list,
# that deploy proves the real remote verify-directory before mutating Pearl,
# and that the listed set is sufficient for verify-directory, with every
# catalog-release.py ROOT/"scripts" dependency load-bearing. Other entries
# (scripts/autotune_window.py) ride the same shipped copy for deploy callers.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEPLOY="$REPO_ROOT/phase4-coordinator/dist/deploy-pearl-vps.sh"
INSTALLER="$REPO_ROOT/ops/pearl-updater/install-pearl-updater.sh"
VERIFIER="$REPO_ROOT/scripts/catalog-release.py"
BUNDLE="$REPO_ROOT/scripts/catalog-verifier-bundle.txt"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$BUNDLE" ] || fail "missing $BUNDLE"
bundle="$(grep -v '^#' "$BUNDLE")"
printf '%s\n' "$bundle" | grep -Eqvx 'scripts/[A-Za-z0-9._-]+' \
  && fail "catalog-verifier-bundle.txt has a non scripts/<name> entry"
[ -z "$(printf '%s\n' "$bundle" | sort | uniq -d)" ] || fail "catalog-verifier-bundle.txt has duplicate entries"
printf '%s\n' "$bundle" | grep -qx 'scripts/catalog-release.py' \
  || fail "catalog-verifier-bundle.txt must list scripts/catalog-release.py"

# Every sibling catalog-release.py resolves via ROOT / "scripts" / NAME.
deps="$(python3 - "$VERIFIER" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
print("\n".join(sorted(set(re.findall(r'ROOT / "scripts" / "([^"]+)"', src)))))
PY
)"
[ -n "$deps" ] || fail "no ROOT/scripts dependencies parsed from catalog-release.py"
for name in $deps; do
  printf '%s\n' "$bundle" | grep -qx "scripts/$name" \
    || fail "catalog-release.py depends on scripts/$name but catalog-verifier-bundle.txt omits it"
done

# Deploy and installer consume the manifest, with no hard-coded bundle names.
grep -qF 'git -C "$REPO_ROOT" show "$COORDINATOR_RELEASE_COMMIT:scripts/catalog-verifier-bundle.txt"' "$DEPLOY" \
  || fail "deploy must read the verifier bundle from the pinned release commit"
archive_block="$(awk '/git -C "\$REPO_ROOT" archive --format=tar "\$COORDINATOR_RELEASE_COMMIT"/{on=1} on{print} on&&/\| tar -xf -/{exit}' "$DEPLOY")"
[ -n "$archive_block" ] || fail "could not locate the pinned deploy-input git archive block"
printf '%s\n' "$archive_block" | grep -qE '^[[:space:]]+scripts/catalog-verifier-bundle\.txt \\$' \
  || fail "deploy git archive does not pin scripts/catalog-verifier-bundle.txt"
printf '%s\n' "$archive_block" | grep -qE '^[[:space:]]+\$CATALOG_VERIFIER_BUNDLE \\$' \
  || fail "deploy git archive does not pin the manifest entries"
grep -qF '_append_deploy_input_digest "$PINNED_SCRIPTS_DIR/${_bundle_path#scripts/}" "$_bundle_path"' "$DEPLOY" \
  || fail "deploy input digest manifest must cover the verifier bundle entries"
grep -qF '$SCP "$PINNED_SCRIPTS_DIR/${_bundle_path#scripts/}" "$VPS_USER@$VPS_HOST:$DEPLOY_TMP/$_bundle_path"' "$DEPLOY" \
  || fail "deploy must upload the verifier bundle entries"
[ "$(grep -cF 'for _bundle_path in $CATALOG_VERIFIER_BUNDLE; do' "$DEPLOY")" = 2 ] \
  || fail "deploy digest and upload must both loop over CATALOG_VERIFIER_BUNDLE"
grep -qF 'done < "$HERE/../../scripts/catalog-verifier-bundle.txt"' "$INSTALLER" \
  || fail "install-pearl-updater.sh must install from catalog-verifier-bundle.txt"
for entry in $bundle; do
  name="${entry#scripts/}"
  re="${name//./\\.}"
  printf '%s\n' "$archive_block" | grep -qE "^[[:space:]]+scripts/$re \\\\\$" \
    && fail "deploy git archive hard-codes $entry; derive it from the manifest"
  grep -qE "=scripts/$re\"" "$DEPLOY" \
    && fail "deploy digest list hard-codes $entry; derive it from the manifest"
  grep -qE "^[[:space:]]*\\\$SCP .*/scripts/$re\"" "$DEPLOY" \
    && fail "deploy upload hard-codes $entry; derive it from the manifest"
  grep -qF "\$HERE/../../scripts/$name\"" "$INSTALLER" \
    && fail "install-pearl-updater.sh hard-codes $entry; derive it from the manifest"
done

# Pre-mutation remote verify-directory over the staged release file set.
preflight='python3 -I $DEPLOY_TMP/scripts/catalog-release.py verify-directory --directory \$_preflight --tier2-public-key-file $DEPLOY_TMP/tier2-catalog.pub'
preflight_line="$(grep -nF "$preflight" "$DEPLOY" | cut -d: -f1 || true)"
digest_check_line="$(grep -nF 'shasum -a 256 -c deploy-inputs.sha256' "$DEPLOY" | head -n1 | cut -d: -f1 || true)"
backup_line="$(grep -nF '/opt/macprovider/coordinator.yaml /opt/macprovider/coordinator.yaml.bak-$BACKUP_TS' "$DEPLOY" | head -n1 | cut -d: -f1 || true)"
stage_line="$(grep -nF 'install -d -o root -g macprovider -m 0750 \$_autotune_stage' "$DEPLOY" | head -n1 | cut -d: -f1 || true)"
[ -n "$preflight_line" ] || fail "deploy lacks the remote pre-mutation verify-directory preflight"
[ "$(printf '%s\n' "$preflight_line" | wc -l | tr -d ' ')" = 1 ] || fail "expected exactly one preflight verify-directory"
[ -n "$digest_check_line" ] && [ -n "$backup_line" ] && [ -n "$stage_line" ] || fail "could not locate deploy ordering anchors"
[ "$digest_check_line" -lt "$preflight_line" ] && [ "$preflight_line" -lt "$backup_line" ] && [ "$preflight_line" -lt "$stage_line" ] \
  || fail "preflight must run after the staged digest check and before the config backup and release staging"
grep -qF 'install -d -m 0700 \$_preflight' "$DEPLOY" || fail "preflight directory must be mode 0700"
grep -qF 'for _f in $CATALOG_RELEASE_FILES; do cp $DEPLOY_TMP/\$_f \$_preflight/\$_f; done' "$DEPLOY" \
  || fail "preflight must copy the CATALOG_RELEASE_FILES set"

# Preflight and staging must see the same release file set.
release_files="$(sed -n 's/^CATALOG_RELEASE_FILES="\([^$"]*\)"$/\1/p' "$DEPLOY")"
bound_files="$(sed -n 's/^  CATALOG_RELEASE_FILES="\$CATALOG_RELEASE_FILES \([^"]*\)"$/\1/p' "$DEPLOY")"
[ -n "$release_files" ] && [ "$bound_files" = "autotune-artifacts.json autotune-artifacts.json.sig" ] \
  || fail "could not parse CATALOG_RELEASE_FILES (base and artifact-bound)"
listed="$(printf '%s\n' $release_files $bound_files | sort)"
staged="$(grep -oE 'install -o root -g macprovider -m 0640 \$DEPLOY_TMP/[A-Za-z0-9._-]+ \\\$_autotune_stage/[A-Za-z0-9._-]+' "$DEPLOY" \
  | awk '{ src=$8; dst=$9; sub(/^\$DEPLOY_TMP\//, "", src); sub(/^\\\$_autotune_stage\//, "", dst); if (src != dst) { print "MISMATCH " src " " dst } else { print src } }' | sort || true)"
[ "$listed" = "$staged" ] || fail "CATALOG_RELEASE_FILES differs from the files staged into \$_autotune_stage:
listed: $(echo $listed)
staged: $(echo $staged)"

# Functional: an isolated copy of exactly the manifest verifies the release
# the way Pearl will, and catalog-release.py plus each of its ROOT/"scripts"
# dependencies is load-bearing.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for entry in $bundle; do
  mkdir -p "$tmp/$(dirname "$entry")"
  cp "$REPO_ROOT/$entry" "$tmp/$entry"
done
STATIC="$REPO_ROOT/phase3-binary/dist/static"
CANONICAL="$REPO_ROOT/phase3-binary/catalog/autotune"
mkdir "$tmp/release"
bound="$(python3 -c 'import json,sys; print("bound" if "autotune-artifacts.json" in json.load(open(sys.argv[1]))["feeds"] else "unbound")' "$CANONICAL/release.json")"
files="$release_files"
[ "$bound" = bound ] && files="$files $bound_files"
for name in $files; do
  case "$name" in
    release.json|trusted-keys.json|tier2-catalog.json) cp "$CANONICAL/$name" "$tmp/release/$name" ;;
    *) cp "$STATIC/$name" "$tmp/release/$name" ;;
  esac
done
# Same trust root deploy uploads as tier2-catalog.pub.
awk '/^tier2:/{on=1; next} on&&/^[^[:space:]#]/{on=0} on&&$1=="catalog_public_key:"{print $2}' \
  "$REPO_ROOT/phase4-coordinator/dist/coordinator.yaml" > "$tmp/tier2-catalog.pub"
[ -s "$tmp/tier2-catalog.pub" ] || fail "could not derive tier2.catalog_public_key from coordinator.yaml"

run_verify() {
  python3 -I "$tmp/scripts/catalog-release.py" verify-directory \
    --directory "$tmp/release" --tier2-public-key-file "$tmp/tier2-catalog.pub" > "$tmp/out" 2>&1
}
if run_verify; then
  for entry in scripts/catalog-release.py $(printf 'scripts/%s\n' $deps); do
    mv "$tmp/$entry" "$tmp/held"
    if run_verify; then
      fail "verify-directory passed without $entry; drop it from catalog-verifier-bundle.txt or fix this test"
    fi
    mv "$tmp/held" "$tmp/$entry"
  done
  run_verify || fail "verify-directory did not recover after restoring the bundle"
elif grep -q 'a Go toolchain is required' "$tmp/out"; then
  echo "SKIP: no trusted Go toolchain; functional verify-directory (go run sign-catalog.go) NOT exercised" >&2
else
  cat "$tmp/out" >&2
  fail "verify-directory failed from an isolated copy of catalog-verifier-bundle.txt"
fi

echo "PASS: catalog verifier bundle is manifest-driven, dependency-closed, and preflighted"
