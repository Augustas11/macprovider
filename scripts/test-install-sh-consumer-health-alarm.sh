#!/usr/bin/env bash
# Hermetic structural + behavioral checks for the install.sh consumer-surface
# health alarm. Must not depend on live GitHub or get.malibu.tech.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
alarm="$root/.github/workflows/install-sh-consumer-health-alarm.yml"
checker="$root/scripts/check-install-sh-consumer-health.sh"
parity_alarm="$root/.github/workflows/install-sh-parity-alarm.yml"
parity_checker="$root/scripts/check-install-sh-parity.sh"
install_sh="$root/phase3-binary/dist/install.sh"
runbook="$root/docs/runbooks/provider-cli-release-verification.md"

for path in "$alarm" "$checker" "$parity_alarm" "$parity_checker" "$install_sh" "$runbook"; do
  [[ -f "$path" ]] || {
    printf '[test-install-sh-consumer-health-alarm] ERROR: missing %s\n' "$path" >&2
    exit 1
  }
done

python3 - "$alarm" "$checker" "$parity_alarm" "$parity_checker" "$runbook" <<'PY'
import pathlib
import sys

alarm, checker, parity_alarm, parity_checker, runbook = (
    pathlib.Path(p).read_text(encoding="utf-8") for p in sys.argv[1:]
)
CHECKOUT = "uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
CHECKER = "bash scripts/check-install-sh-consumer-health.sh"

for requirement in (
    "name: Install.sh consumer-surface health alarm",
    "workflow_dispatch:",
    "permissions:",
    "contents: read",
    CHECKOUT,
    "persist-credentials: false",
    "fetch-depth: 1",
    CHECKER,
    "unset GITHUB_TOKEN GH_TOKEN GH_ENTERPRISE_TOKEN",
    'INSTALL_SH_URL="https://get.malibu.tech/install.sh"',
    "timeout-minutes: 10",
    "runs-on: ubuntu-latest",
    'cron: "0 */6 * * *"',
    "group: install-sh-consumer-health-alarm",
    "cancel-in-progress: true",
    "latest_release_tag()",
    "unauthenticated",
):
    if requirement not in alarm:
        raise SystemExit(f"alarm workflow omits: {requirement}")

if alarm.count(CHECKER) != 1:
    raise SystemExit("alarm must invoke the checker exactly once")
if "GH_TOKEN: ${{" in alarm or "GITHUB_TOKEN: ${{" in alarm or "github.token" in alarm:
    raise SystemExit("alarm must not map GH_TOKEN/GITHUB_TOKEN (authenticated probe is unfaithful)")
for forbidden in (
    "secrets.",
    "environment: production-release",
    "contents: write",
    "gh release",
    "PEARL_SSH",
    "INSTALL_SH_FILE",
):
    if forbidden in alarm:
        raise SystemExit(f"alarm workflow must not contain {forbidden!r}")

for requirement in (
    "latest_release_tag()",
    "unauthenticated",
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "GH_ENTERPRISE_TOKEN",
    "checksums.txt",
    "checksums.txt.sig",
    "darwin-arm64",
    "get.malibu.tech/install.sh",
    "no secrets, no writes, no deploy",
    "Augustas11/macprovider",
    "--proto '=https'",
    "--proto-redir '=https'",
    "--tlsv1.2",
    "--netrc-file /dev/null",
):
    if requirement not in checker:
        raise SystemExit(f"checker omits: {requirement}")
if "gh release" in checker:
    raise SystemExit("checker must not use gh (authenticated, different resolver)")
if "/releases/latest" in checker:
    raise SystemExit("checker must not use /releases/latest (installer deliberately avoids it)")

if "check-install-sh-consumer-health.sh" not in runbook:
    raise SystemExit("runbook must mention the consumer-health checker")
if "install-sh-consumer-health-alarm.yml" not in runbook:
    raise SystemExit("runbook must mention the consumer-health alarm workflow")
if "check-install-sh-consumer-health.sh" not in parity_checker:
    raise SystemExit("parity checker must point at the sibling consumer-health gate")
PY

bash -n "$checker"
bash -n "$alarm" 2>/dev/null || true

# Extraction of HEAD install.sh must keep the paginated parser (many '}' in awk)
# and must not swallow download_release.
extracted="$(mktemp "${TMPDIR:-/tmp}/extracted-latest-release-tag.XXXXXX")"
awk '
  /^latest_release_tag\(\)/ { emit = 1; print; next }
  emit && /^[A-Za-z_][A-Za-z0-9_]*\(\)/ { exit }
  emit { print }
' "$install_sh" > "$extracted"
grep -q 'releases?per_page=100&page=' "$extracted" || {
  printf '[test-install-sh-consumer-health-alarm] ERROR: extraction dropped pagination\n' >&2
  rm -f "$extracted"
  exit 1
}
grep -q 'max_pages=10' "$extracted" || {
  printf '[test-install-sh-consumer-health-alarm] ERROR: extraction dropped max_pages\n' >&2
  rm -f "$extracted"
  exit 1
}
grep -q 'function finalize_literal' "$extracted" || {
  printf '[test-install-sh-consumer-health-alarm] ERROR: extraction truncated the awk parser\n' >&2
  rm -f "$extracted"
  exit 1
}
if grep -q '^download_release()' "$extracted"; then
  printf '[test-install-sh-consumer-health-alarm] ERROR: extraction leaked download_release\n' >&2
  rm -f "$extracted"
  exit 1
fi
rm -f "$extracted"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/install-sh-consumer-health-test.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT
MOCK_BIN="$WORKDIR/bin"
mkdir -p "$MOCK_BIN"

write_curl_mock() {
  local mode="$1"
  cat > "$MOCK_BIN/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
out="/dev/null"
write_fmt=""
url=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -w) write_fmt="\$2"; shift 2 ;;
    http*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
echo "\$url" >> "$WORKDIR/curl-urls.log"
case "\$url" in
  */checksums.txt.sig)
    if [ "$mode" = "checksums-404" ]; then
      [ -n "\$write_fmt" ] && printf '404'
      exit 22
    fi
    if [ "\$out" != "/dev/null" ]; then
      printf 'sig' > "\$out"
    fi
    [ -n "\$write_fmt" ] && printf '200'
    exit 0
    ;;
  */checksums.txt)
    if [ "$mode" = "checksums-404" ]; then
      [ -n "\$write_fmt" ] && printf '404'
      exit 22
    fi
    if [ "\$out" != "/dev/null" ]; then
      printf 'deadbeef  macprovider-cli-v1.8.123-darwin-arm64.pkg\\n' > "\$out"
    fi
    [ -n "\$write_fmt" ] && printf '200'
    exit 0
    ;;
  *.pkg)
    if [ "$mode" = "pkg-404-tar-200" ]; then
      [ -n "\$write_fmt" ] && printf '404'
      exit 22
    fi
    if [ "$mode" = "assets-404" ]; then
      [ -n "\$write_fmt" ] && printf '404'
      exit 22
    fi
    [ -n "\$write_fmt" ] && printf '200'
    exit 0
    ;;
  *.tar.gz)
    if [ "$mode" = "pkg-404-tar-200" ] || [ "$mode" = "ok" ]; then
      [ -n "\$write_fmt" ] && printf '200'
      exit 0
    fi
    [ -n "\$write_fmt" ] && printf '404'
    exit 22
    ;;
  *)
    printf 'unexpected curl URL: %s\\n' "\$url" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "$MOCK_BIN/curl"
}

write_fixture() {
  local path="$1"
  local body="$2"
  printf '%s\n' "$body" > "$path"
}

run_checker() {
  local name="$1"
  local want="$2"
  shift 2
  local log="$WORKDIR/${name}.out"
  local rc=0
  local python_dir
  python_dir="$(dirname "$(command -v python3)")"
  # Token values below are fake probe credentials for the unauth-isolation test.
  env -u INSTALL_SH_URL \
    PATH="$MOCK_BIN:$python_dir:/usr/bin:/bin" \
    HOME="$WORKDIR/home-$name" \
    GH_TOKEN="fake-gh-token-unauth-probe" \
    GITHUB_TOKEN="fake-github-token-unauth-probe" \
    GH_ENTERPRISE_TOKEN="fake-enterprise-token-unauth-probe" \
    INSTALL_SH_RESOLVER_TIMEOUT_SEC=15 \
    INSTALL_SH_ASSET_TIMEOUT_SEC=5 \
    "$@" \
    bash "$checker" >"$log" 2>&1 || rc=$?
  if [ "$rc" -ne "$want" ]; then
    printf '[test-install-sh-consumer-health-alarm] FAIL %s: want exit %s got %s\n' "$name" "$want" "$rc" >&2
    cat "$log" >&2
    exit 1
  fi
  printf '[test-install-sh-consumer-health-alarm] PASS %s (exit %s)\n' "$name" "$rc"
}

# Happy path: fixture resolver prints a stable tag; mock curl 200s assets.
write_curl_mock ok
write_fixture "$WORKDIR/ok.sh" "$(cat <<'EOF'
#!/usr/bin/env bash
echo "SOURCED_MAIN" >&2
latest_release_tag() {
  if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}${GH_ENTERPRISE_TOKEN:-}" ]; then
    printf '%s' 'AUTHENTICATED'
    return 0
  fi
  printf '%s' 'v1.8.123'
}
download_release() { echo leaked; }
EOF
)"
: > "$WORKDIR/curl-urls.log"
run_checker happy-path 0 INSTALL_SH_FILE="$WORKDIR/ok.sh"
if grep -q SOURCED_MAIN "$WORKDIR/happy-path.out"; then
  printf '[test-install-sh-consumer-health-alarm] FAIL happy-path sourced install.sh main\n' >&2
  exit 1
fi
grep -q 'resolved v1.8.123' "$WORKDIR/happy-path.out" || {
  printf '[test-install-sh-consumer-health-alarm] FAIL happy-path missing resolved tag\n' >&2
  cat "$WORKDIR/happy-path.out" >&2
  exit 1
}
if grep -q AUTHENTICATED "$WORKDIR/happy-path.out"; then
  printf '[test-install-sh-consumer-health-alarm] FAIL happy-path leaked GitHub credentials into the resolver\n' >&2
  cat "$WORKDIR/happy-path.out" >&2
  exit 1
fi

# die 3 from the served resolver is an ALARM, not a probe error.
write_fixture "$WORKDIR/die3.sh" "$(cat <<'EOF'
latest_release_tag() {
  die 3 "no non-prerelease macprovider-cli release (tag ^v[0-9]) found in recent GitHub Releases"
}
EOF
)"
run_checker die3 1 INSTALL_SH_FILE="$WORKDIR/die3.sh"
grep -q 'ALARM:' "$WORKDIR/die3.out" || {
  printf '[test-install-sh-consumer-health-alarm] FAIL die3 did not alarm\n' >&2
  cat "$WORKDIR/die3.out" >&2
  exit 1
}

# Non-stable tag.
write_fixture "$WORKDIR/badtag.sh" "$(cat <<'EOF'
latest_release_tag() { printf '%s' 'verify-v1.0.0'; }
EOF
)"
run_checker bad-tag 1 INSTALL_SH_FILE="$WORKDIR/badtag.sh"

# Missing function.
write_fixture "$WORKDIR/missing.sh" $'#!/usr/bin/env bash\necho hi\n'
run_checker missing-fn 1 INSTALL_SH_FILE="$WORKDIR/missing.sh"

# checksums.txt 404.
write_curl_mock checksums-404
write_fixture "$WORKDIR/ok2.sh" "$(cat <<'EOF'
latest_release_tag() {
  printf '%s' 'v1.8.123'
}
EOF
)"
run_checker checksums-404 1 INSTALL_SH_FILE="$WORKDIR/ok2.sh"
grep -q 'checksums.txt' "$WORKDIR/checksums-404.out" || {
  printf '[test-install-sh-consumer-health-alarm] FAIL checksums-404 did not mention checksums.txt\n' >&2
  cat "$WORKDIR/checksums-404.out" >&2
  exit 1
}

# Both platform assets 404.
write_curl_mock assets-404
run_checker assets-404 1 INSTALL_SH_FILE="$WORKDIR/ok2.sh"
grep -q 'platform asset' "$WORKDIR/assets-404.out" || {
  printf '[test-install-sh-consumer-health-alarm] FAIL assets-404 did not mention platform asset\n' >&2
  cat "$WORKDIR/assets-404.out" >&2
  exit 1
}

# pkg 404, tarball 200 still counts as installable.
write_curl_mock pkg-404-tar-200
run_checker pkg-fallback 0 INSTALL_SH_FILE="$WORKDIR/ok2.sh"
grep -q 'tar.gz' "$WORKDIR/pkg-fallback.out" || {
  printf '[test-install-sh-consumer-health-alarm] FAIL pkg-fallback did not accept tarball\n' >&2
  cat "$WORKDIR/pkg-fallback.out" >&2
  exit 1
}

# Old-style function with many '}' in an embedded awk program must extract whole.
write_curl_mock ok
write_fixture "$WORKDIR/braces.sh" "$(cat <<'EOF'
latest_release_tag() {
  tag="$(
    printf '%s' '{"x":1}' | awk '{
      if (c == "}") { found = 1 }
      if (c == "{") { depth++ }
    }'
  )"
  if [ -n "${GH_TOKEN:-}" ]; then
    printf '%s' 'AUTHENTICATED'
    return 0
  fi
  printf '%s' 'v1.8.123'
}
version_at_least() { return 0; }
EOF
)"
run_checker braces-extract 0 INSTALL_SH_FILE="$WORKDIR/braces.sh"

# Fetch error against a non-https URL is a probe error (exit 2), not an ALARM.
run_checker bad-url 2 INSTALL_SH_FILE="" INSTALL_SH_URL="http://example.invalid/install.sh"

printf '[test-install-sh-consumer-health-alarm] ok: structural + hermetic consumer-health checks passed\n'
