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
    "fetch-depth: 0",
    CHECKER,
    "INSTALL_SH_RELEASE_TAG: ${{ steps.pin.outputs.tag }}",
    "select(.isDraft==false and .isPrerelease==false)",
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
# Only the tag-pin step may read the Actions token; the probe step that runs
# the checker must carry none (an authenticated probe is unfaithful, #1588).
steps = alarm.split("\n      - name: ")
probe_steps = [step for step in steps if CHECKER in step]
pin_steps = [step for step in steps if "gh release list" in step]
if len(probe_steps) != 1 or len(pin_steps) != 1 or probe_steps[0] is pin_steps[0]:
    raise SystemExit("alarm must pin the release tag and run the checker in separate steps")
for step in probe_steps:
    if "GH_TOKEN: ${{" in step or "GITHUB_TOKEN: ${{" in step or "github.token" in step or "gh release" in step:
        raise SystemExit("the probe step must not map GH_TOKEN/GITHUB_TOKEN (authenticated probe is unfaithful)")
for step in steps:
    if "github.token" in step and step is not pin_steps[0]:
        raise SystemExit("only the tag-pin step may read github.token")
for forbidden in (
    "secrets.",
    "environment: production-release",
    "contents: write",
    "PEARL_SSH",
    "INSTALL_SH_FILE",
    "INSTALL_SH_REFERENCE_FILE",
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
    "never executes its bytes",
    "cmp -s \"$SERVED\" \"$REFERENCE\"",
    "install_sh_vs_release",
    "ulimit -f",
):
    if requirement not in checker:
        raise SystemExit(f"checker omits: {requirement}")
# #2036: every function the checker runs comes from the repository copy.
probe = checker[checker.index('INSTALLER="$REFERENCE"'):]
if '"$SERVED"' in probe:
    raise SystemExit("checker must not read the served bytes after the parity check")
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
FIXTURES="$WORKDIR/fixtures"
mkdir -p "$MOCK_BIN" "$FIXTURES"

# A throwaway P-256 release key: fixtures embed its public half the way
# install.sh embeds the production key, so the checker's signature check runs.
openssl ecparam -name prime256v1 -genkey -noout -out "$FIXTURES/test-release.key" 2>/dev/null
openssl ec -in "$FIXTURES/test-release.key" -pubout -out "$FIXTURES/test-release.pub" 2>/dev/null
printf '%s  %s\n' \
  "1111111111111111111111111111111111111111111111111111111111111111" "macprovider-cli-v1.8.123-darwin-arm64.pkg" \
  "2222222222222222222222222222222222222222222222222222222222222222" "macprovider-cli-v1.8.123-darwin-arm64.tar.gz" \
  > "$FIXTURES/checksums.txt"
openssl dgst -sha256 -sign "$FIXTURES/test-release.key" -out "$FIXTURES/checksums.txt.sig" "$FIXTURES/checksums.txt"
printf 'tampered\n' >> "$FIXTURES/checksums-tampered.txt"
cat "$FIXTURES/checksums.txt" >> "$FIXTURES/checksums-tampered.txt"
TEST_KEY_FUNCTION="write_checksum_public_key() {
  cat <<'KEY'
$(cat "$FIXTURES/test-release.pub")
KEY
}"

# write_curl_mock "<flag> ...": flags select per-host failures.
#   checksums-404 assets-404 pkg-404-tar-200 github-downloads-404 bad-sig
#   coordinator-down api-rate-limited
write_curl_mock() {
  local mode=" $* "
  cat > "$MOCK_BIN/curl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
mode="$mode"
fixtures="$FIXTURES"
out="/dev/null"
headers=""
write_fmt=""
url=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -D) headers="\$2"; shift 2 ;;
    -w) write_fmt="\$2"; shift 2 ;;
    http*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
echo "\$url" >> "$WORKDIR/curl-urls.log"
has() { case "\$mode" in *" \$1 "*) return 0 ;; esac; return 1; }
# A response body goes to -o when the caller names a file, else to stdout.
body() { if [ "\$out" != "/dev/null" ]; then printf '%s' "\$1" > "\$out"; else printf '%s' "\$1"; fi; }
# Render curl's -w format: the status code, and no redirect.
wout() {
  local f="\$write_fmt"
  f="\${f//%\{http_code\}/\$1}"
  f="\${f//%\{redirect_url\}/}"
  printf '%s' "\$f"
}
miss() { [ -n "\$write_fmt" ] && wout 404; exit 22; }
hit() {
  if [ -n "\${1:-}" ] && [ "\$out" != "/dev/null" ]; then cp "\$1" "\$out"; fi
  [ -n "\$write_fmt" ] && wout 200
  exit 0
}
case "\$url" in
  https://get.malibu.tech/install.sh)
    if has oversize-install; then
      # Like curl, the writer dies at the caller's file-size limit.
      rc=0
      head -c 4194304 /dev/zero > "\$out" || rc=\$?
      exit "\$rc"
    fi
    hit "\$fixtures/served-install.sh"
    ;;
  https://coordinator.malibu.tech/healthz)
    has coordinator-down && exit 7
    body '{"status":"ok","recommended_binary_version":"1.8.123"}'
    exit 0
    ;;
  https://api.github.com/*)
    if has api-rate-limited; then
      [ -n "\$headers" ] && printf 'HTTP/2 403\r\nx-ratelimit-remaining: 0\r\nx-ratelimit-reset: 1790000000\r\n\r\n' > "\$headers"
      exit 22
    fi
    if has oversize-api; then
      rc=0
      if [ "\$out" != "/dev/null" ]; then head -c 33554432 /dev/zero > "\$out" || rc=\$?; else head -c 33554432 /dev/zero || rc=\$?; fi
      exit "\$rc"
    fi
    body '[{"tag_name":"v1.8.122","prerelease":false}]'
    exit 0
    ;;
  https://github.com/*)
    has github-downloads-404 && miss
    if has redirect-elsewhere; then
      # A 302 to an endpoint that is not a release host.
      [ "\$out" != "/dev/null" ] && printf 'moved' > "\$out"
      f="\${write_fmt//%\{http_code\}/302}"
      printf '%s' "\${f//%\{redirect_url\}/https://internal.example/probe}"
      exit 0
    fi
    ;;
  https://download.malibu.tech/releases/*) ;;
  *)
    printf 'unexpected curl URL: %s\\n' "\$url" >&2
    exit 2
    ;;
esac
case "\$url" in
  */checksums.txt.sig)
    has checksums-404 && miss
    if has bad-sig; then hit "\$fixtures/checksums-tampered.txt"; fi
    hit "\$fixtures/checksums.txt.sig"
    ;;
  */checksums.txt)
    has checksums-404 && miss
    if has oversize-checksums; then
      rc=0
      head -c 4194304 /dev/zero > "\$out" || rc=\$?
      echo "\$url \$(wc -c < "\$out" | tr -d ' ')" >> "$WORKDIR/stream.log"
      exit "\$rc"
    fi
    hit "\$fixtures/checksums.txt"
    ;;
  *.pkg)
    { has pkg-404-tar-200 || has assets-404; } && miss
    hit
    ;;
  *.tar.gz)
    has assets-404 && miss
    hit
    ;;
esac
printf 'unexpected curl URL: %s\\n' "\$url" >&2
exit 2
EOF
  chmod +x "$MOCK_BIN/curl"
}

write_fixture() {
  local path="$1"
  local body="$2"
  printf '%s\n%s\n' "$body" "$TEST_KEY_FUNCTION" > "$path"
}

run_checker() {
  local name="$1"
  local want="$2"
  shift 2
  local log="$WORKDIR/${name}.out"
  local rc=0
  local python_dir openssl_dir
  python_dir="$(dirname "$(command -v python3)")"
  openssl_dir="$(dirname "$(command -v openssl)")"
  : > "$WORKDIR/curl-urls.log"
  # Token values below are fake probe credentials for the unauth-isolation test.
  env -u INSTALL_SH_URL \
    PATH="$MOCK_BIN:$python_dir:$openssl_dir:/usr/bin:/bin" \
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

expect_output() {
  local name="$1" pattern="$2"
  grep -q -- "$pattern" "$WORKDIR/${name}.out" || {
    printf '[test-install-sh-consumer-health-alarm] FAIL %s: output lacks %s\n' "$name" "$pattern" >&2
    cat "$WORKDIR/${name}.out" >&2
    exit 1
  }
}

expect_no_fetch() {
  local name="$1" pattern="$2"
  if grep -q -- "$pattern" "$WORKDIR/curl-urls.log"; then
    printf '[test-install-sh-consumer-health-alarm] FAIL %s: fetched %s\n' "$name" "$pattern" >&2
    cat "$WORKDIR/curl-urls.log" >&2
    exit 1
  fi
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
run_checker happy-path 0 INSTALL_SH_FILE="$WORKDIR/ok.sh" INSTALL_SH_REFERENCE_FILE="$WORKDIR/ok.sh"
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
run_checker die3 1 INSTALL_SH_FILE="$WORKDIR/die3.sh" INSTALL_SH_REFERENCE_FILE="$WORKDIR/die3.sh"
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
run_checker bad-tag 1 INSTALL_SH_FILE="$WORKDIR/badtag.sh" INSTALL_SH_REFERENCE_FILE="$WORKDIR/badtag.sh"

# Missing function.
write_fixture "$WORKDIR/missing.sh" $'#!/usr/bin/env bash\necho hi\n'
run_checker missing-fn 1 INSTALL_SH_FILE="$WORKDIR/missing.sh" INSTALL_SH_REFERENCE_FILE="$WORKDIR/missing.sh"

# checksums.txt 404.
write_curl_mock checksums-404
write_fixture "$WORKDIR/ok2.sh" "$(cat <<'EOF'
latest_release_tag() {
  printf '%s' 'v1.8.123'
}
EOF
)"
run_checker checksums-404 1 INSTALL_SH_FILE="$WORKDIR/ok2.sh" INSTALL_SH_REFERENCE_FILE="$WORKDIR/ok2.sh"
grep -q 'checksums.txt' "$WORKDIR/checksums-404.out" || {
  printf '[test-install-sh-consumer-health-alarm] FAIL checksums-404 did not mention checksums.txt\n' >&2
  cat "$WORKDIR/checksums-404.out" >&2
  exit 1
}

# Both platform assets 404.
write_curl_mock assets-404
run_checker assets-404 1 INSTALL_SH_FILE="$WORKDIR/ok2.sh" INSTALL_SH_REFERENCE_FILE="$WORKDIR/ok2.sh"
grep -q 'platform asset' "$WORKDIR/assets-404.out" || {
  printf '[test-install-sh-consumer-health-alarm] FAIL assets-404 did not mention platform asset\n' >&2
  cat "$WORKDIR/assets-404.out" >&2
  exit 1
}

# pkg 404, tarball 200 still counts as installable.
write_curl_mock pkg-404-tar-200
run_checker pkg-fallback 0 INSTALL_SH_FILE="$WORKDIR/ok2.sh" INSTALL_SH_REFERENCE_FILE="$WORKDIR/ok2.sh"
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
run_checker braces-extract 0 INSTALL_SH_FILE="$WORKDIR/braces.sh" INSTALL_SH_REFERENCE_FILE="$WORKDIR/braces.sh"

# #2036: the served full resolver runs unauthenticated with the production
# coordinator, and never needs the anonymous GitHub API when it advertises.
write_curl_mock ok
write_fixture "$WORKDIR/discover.sh" "$(cat <<'EOF'
MACPROVIDER_MIN_SUPPORTED_VERSION="v1.7.11"
latest_release_tag() { printf '%s' 'v1.8.122'; }
release_mirror_enabled() { [ "$GITHUB_REPO" = "$RELEASE_MIRROR_REPO" ]; }
discovered_release_tag_acceptable() { return 0; }
version_at_least() { return 0; }
mirror_latest_release_tag() {
  [ "$coordinator_base" = "https://coordinator.malibu.tech" ] || return 1
  printf '%s' 'v1.8.123'
}
discover_latest_release_tag() {
  if release_mirror_enabled && mirror_latest_release_tag; then return 0; fi
  latest_release_tag
}
EOF
)"
run_checker discover-mode 0 INSTALL_SH_FILE="$WORKDIR/discover.sh" INSTALL_SH_REFERENCE_FILE="$WORKDIR/discover.sh"
expect_output discover-mode 'discover_latest_release_tag resolved v1.8.123'
expect_output discover-mode 'signature verified'

# GitHub release downloads unavailable: the byte-identical mirror serves them.
write_curl_mock github-downloads-404
run_checker mirror-assets 0 INSTALL_SH_FILE="$WORKDIR/discover.sh" INSTALL_SH_REFERENCE_FILE="$WORKDIR/discover.sh"
expect_output mirror-assets 'checksums.txt HTTP 200 from https://download.malibu.tech'
expect_output mirror-assets 'darwin-arm64.pkg HTTP 200 from https://download.malibu.tech'

# A GitHub redirect to any other endpoint is never followed; the mirror serves.
write_curl_mock redirect-elsewhere
run_checker redirect-elsewhere 0 INSTALL_SH_FILE="$WORKDIR/discover.sh" INSTALL_SH_REFERENCE_FILE="$WORKDIR/discover.sh"
expect_output redirect-elsewhere 'checksums.txt HTTP 200 from https://download.malibu.tech'
expect_output redirect-elsewhere 'darwin-arm64.pkg HTTP 200 from https://download.malibu.tech'
expect_no_fetch redirect-elsewhere 'internal.example'

# A bad checksums.txt.sig is an alarm, never a fallback to another host.
write_curl_mock bad-sig
run_checker bad-signature 1 INSTALL_SH_FILE="$WORKDIR/discover.sh" INSTALL_SH_REFERENCE_FILE="$WORKDIR/discover.sh"
expect_output bad-signature 'does not verify'

# A served installer without the release key cannot prove installability.
write_curl_mock ok
printf '%s
' "latest_release_tag() { printf '%s' 'v1.8.123'; }" > "$WORKDIR/nokey.sh"
run_checker no-release-key 1 INSTALL_SH_FILE="$WORKDIR/nokey.sh" INSTALL_SH_REFERENCE_FILE="$WORKDIR/nokey.sh"
expect_output no-release-key 'write_checksum_public_key'

# The checkout installer itself: its resolver takes the coordinator-advertised
# release without one api.github.com request. The fixture signature is not the
# production key's, so the probe then alarms on the signature (fail closed).
write_curl_mock ok
run_checker head-installer 1 INSTALL_SH_FILE="$install_sh"
expect_output head-installer 'discover_latest_release_tag resolved v1.8.123'
expect_output head-installer 'does not verify'
expect_no_fetch head-installer 'api.github.com'

# Coordinator down: the checkout installer falls back to the GitHub API once.
write_curl_mock coordinator-down
run_checker head-installer-github-fallback 1 INSTALL_SH_FILE="$install_sh"
expect_output head-installer-github-fallback 'discover_latest_release_tag resolved v1.8.122'
[ "$(grep -c 'api.github.com' "$WORKDIR/curl-urls.log")" = "1" ] || {
  printf '[test-install-sh-consumer-health-alarm] FAIL head-installer-github-fallback: want one GitHub API request
' >&2
  cat "$WORKDIR/curl-urls.log" >&2
  exit 1
}

# Coordinator down and the anonymous budget spent: an alarm that says when
# discovery resumes, after exactly one API request.
write_curl_mock coordinator-down api-rate-limited
run_checker head-installer-rate-limited 1 INSTALL_SH_FILE="$install_sh"
expect_output head-installer-rate-limited 'deferred until'
[ "$(grep -c 'api.github.com' "$WORKDIR/curl-urls.log")" = "1" ] || {
  printf '[test-install-sh-consumer-health-alarm] FAIL head-installer-rate-limited: want one GitHub API request
' >&2
  cat "$WORKDIR/curl-urls.log" >&2
  exit 1
}

# #2036: served bytes are never executed. A served copy carrying a malicious
# function and top-level code differs from the repository copy: parity fails
# and nothing from it runs.
write_curl_mock ok
pwned="$WORKDIR/PWNED"
cat "$WORKDIR/ok2.sh" > "$WORKDIR/malicious.sh"
cat >> "$WORKDIR/malicious.sh" <<EOF
touch "$pwned.top"
latest_release_tag() { touch "$pwned.resolver"; printf '%s' 'v1.8.123'; }
write_checksum_public_key() { touch "$pwned.key"; cat "$FIXTURES/test-release.pub"; }
EOF
run_checker served-malicious 1 INSTALL_SH_FILE="$WORKDIR/malicious.sh" INSTALL_SH_REFERENCE_FILE="$WORKDIR/ok2.sh"
expect_output served-malicious 'differs from the repository'
expect_output served-malicious 'were not executed'
if ls "$pwned".* >/dev/null 2>&1; then
  printf '[test-install-sh-consumer-health-alarm] FAIL served-malicious: served bytes were executed\n' >&2
  exit 1
fi
expect_no_fetch served-malicious 'coordinator.malibu.tech'

# Parity is exact: one trailing byte of drift is an alarm.
cp "$WORKDIR/ok2.sh" "$WORKDIR/ok2-twin.sh"
printf ' ' >> "$WORKDIR/ok2-twin.sh"
run_checker served-one-byte-drift 1 INSTALL_SH_FILE="$WORKDIR/ok2-twin.sh" INSTALL_SH_REFERENCE_FILE="$WORKDIR/ok2.sh"
expect_output served-one-byte-drift 'differs from the repository'

# The reference-file override is test-only: it needs INSTALL_SH_FILE.
run_checker reference-override-needs-file 2 INSTALL_SH_FILE="" INSTALL_SH_URL="https://get.malibu.tech/install.sh" \
  INSTALL_SH_REFERENCE_FILE="$WORKDIR/discover.sh"
expect_output reference-override-needs-file 'test override'
expect_no_fetch reference-override-needs-file 'get.malibu.tech'

# The production path: the served copy is fetched over https and, matching the
# checkout's dist/install.sh (the default repository copy), passes parity.
cp "$install_sh" "$FIXTURES/served-install.sh"
run_checker served-url-default-reference 1 INSTALL_SH_FILE="" INSTALL_SH_URL="https://get.malibu.tech/install.sh"
expect_output served-url-default-reference 'byte-identical to the repository checkout dist/install.sh'
expect_output served-url-default-reference 'discover_latest_release_tag resolved v1.8.123'
expect_output served-url-default-reference 'does not verify'

# A served copy that drifts from the checkout copy alarms before any probe.
cp "$WORKDIR/discover.sh" "$FIXTURES/served-install.sh"
run_checker served-url-drift 1 INSTALL_SH_FILE="" INSTALL_SH_URL="https://get.malibu.tech/install.sh"
expect_output served-url-drift 'differs from the repository checkout dist/install.sh'
expect_no_fetch served-url-drift 'coordinator.malibu.tech'

# An oversized served installer is cut off while it streams (probe error).
write_curl_mock oversize-install
run_checker served-oversize 2 INSTALL_SH_FILE="" INSTALL_SH_URL="https://get.malibu.tech/install.sh" \
  INSTALL_SH_MAX_BYTES=65536
expect_output served-oversize 'within 65536 bytes'

# An oversized checksums.txt is cut at the 1 MiB metadata cap on each host.
write_curl_mock oversize-checksums
: > "$WORKDIR/stream.log"
run_checker checksums-oversize 1 INSTALL_SH_FILE="$WORKDIR/discover.sh" INSTALL_SH_REFERENCE_FILE="$WORKDIR/discover.sh"
expect_output checksums-oversize 'checksums.txt is not HTTP 200'
[ "$(awk '$2 == 1048576' "$WORKDIR/stream.log" | wc -l | tr -d ' ')" = "2" ] || {
  printf '[test-install-sh-consumer-health-alarm] FAIL checksums-oversize: want both hosts cut at 1048576 bytes\n' >&2
  cat "$WORKDIR/stream.log" >&2
  exit 1
}

# A release tag must be vMAJOR.MINOR.PATCH and must exist locally.
run_checker bad-release-tag 2 INSTALL_SH_FILE="$WORKDIR/ok2.sh" INSTALL_SH_RELEASE_TAG='v1.8.1;id'
run_checker missing-release-tag 2 INSTALL_SH_FILE="$WORKDIR/ok2.sh" INSTALL_SH_RELEASE_TAG='v0.0.0'
expect_output missing-release-tag 'cannot read phase3-binary/dist/install.sh at tag v0.0.0'

# An older release copy without its own caps reads the API into a shell
# variable; the gate's curl bound still cuts the response at 16 MiB.
write_curl_mock oversize-api
write_fixture "$WORKDIR/uncapped.sh" "$(cat <<'EOF'
latest_release_tag() {
  json="$(curl -fsSL "https://api.github.com/repos/Augustas11/macprovider/releases?per_page=100&page=1")" \
    || die 3 "failed to query GitHub Releases API"
  printf '%s' "v1.8.$(printf '%s' "$json" | wc -c | tr -d ' ')"
}
EOF
)"
run_checker uncapped-old-installer 1 INSTALL_SH_FILE="$WORKDIR/uncapped.sh" INSTALL_SH_REFERENCE_FILE="$WORKDIR/uncapped.sh"
expect_output uncapped-old-installer 'failed to query GitHub Releases API'

# A valid INSTALL_SH_RELEASE_TAG selects that tag's dist/install.sh as the
# repository copy (a throwaway repository holding the checker and a tag).
tagrepo="$WORKDIR/tagrepo"
mkdir -p "$tagrepo/scripts" "$tagrepo/phase3-binary/dist"
cp "$checker" "$tagrepo/scripts/check-install-sh-consumer-health.sh"
cp "$WORKDIR/discover.sh" "$tagrepo/phase3-binary/dist/install.sh"
git -C "$tagrepo" init -q
git -C "$tagrepo" -c user.name=t -c user.email=t@example.invalid add -A
git -C "$tagrepo" -c user.name=t -c user.email=t@example.invalid commit -q -m tagged
git -C "$tagrepo" tag v9.9.9
printf '# moved on after the tag\n' >> "$tagrepo/phase3-binary/dist/install.sh"
write_curl_mock ok
checker_saved="$checker"
checker="$tagrepo/scripts/check-install-sh-consumer-health.sh"
run_checker release-tag-reference 0 INSTALL_SH_FILE="$WORKDIR/discover.sh" INSTALL_SH_RELEASE_TAG=v9.9.9
expect_output release-tag-reference 'byte-identical to the repository v9.9.9 dist/install.sh'
expect_output release-tag-reference 'discover_latest_release_tag resolved v1.8.123'
run_checker release-tag-drift 1 INSTALL_SH_FILE="$tagrepo/phase3-binary/dist/install.sh" INSTALL_SH_RELEASE_TAG=v9.9.9
expect_output release-tag-drift 'differs from the repository v9.9.9 dist/install.sh'
checker="$checker_saved"

# Fetch error against a non-https URL is a probe error (exit 2), not an ALARM.
run_checker bad-url 2 INSTALL_SH_FILE="" INSTALL_SH_URL="http://example.invalid/install.sh"

printf '[test-install-sh-consumer-health-alarm] ok: structural + hermetic consumer-health checks passed\n'
