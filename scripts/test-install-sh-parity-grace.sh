#!/usr/bin/env bash
# Offline tests for scripts/check-install-sh-parity.sh, including the mid-train
# grace rule (#2210): drift is OK only while the served script is exactly the
# previous release's install.sh and the expected release was published at most
# INSTALL_SH_TRAIN_GRACE_MINUTES ago. curl is a stub; nothing leaves the host.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/repo/scripts" "$tmp/repo/phase3-binary/dist" "$tmp/bin"
cp "$root/scripts/check-install-sh-parity.sh" "$tmp/repo/scripts/"
printf '#!/bin/bash\necho current\n' > "$tmp/repo/phase3-binary/dist/install.sh"
printf '#!/bin/bash\necho previous\n' > "$tmp/previous.sh"
printf '#!/bin/bash\necho other\n' > "$tmp/other.sh"
# curl stub: writes $FAKE_SERVED to the -o target; FAKE_SERVED unset = fetch error.
cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
[ -n "${FAKE_SERVED:-}" ] && [ -n "$out" ] || exit 22
cp "$FAKE_SERVED" "$out"
STUB
chmod +x "$tmp/bin/curl"

pass=0
fail=0
# run WANT_RC DESC [VAR=VALUE ...]
run() {
  local want="$1" desc="$2" rc=0
  shift 2
  env -u INSTALL_SH_PREVIOUS_FILE -u INSTALL_SH_LATEST_PUBLISHED_AT -u INSTALL_SH_TRAIN_GRACE_MINUTES \
    -u INSTALL_SH_NOW_EPOCH -u INSTALL_SH_URL PATH="$tmp/bin:$PATH" "$@" \
    bash "$tmp/repo/scripts/check-install-sh-parity.sh" >"$tmp/out" 2>&1 || rc=$?
  if [ "$rc" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s: want rc=%s got rc=%s\n' "$desc" "$want" "$rc"
    sed 's/^/    /' "$tmp/out"
  fi
}

PUB=2026-11-02T10:00:00Z
PUB_EPOCH="$(python3 -c 'import calendar,time; print(calendar.timegm(time.strptime("2026-11-02T10:00:00Z","%Y-%m-%dT%H:%M:%SZ")))')"
CUR="$tmp/repo/phase3-binary/dist/install.sh"
GRACE=(INSTALL_SH_PREVIOUS_FILE="$tmp/previous.sh" INSTALL_SH_LATEST_PUBLISHED_AT="$PUB")

run 0 "parity" FAKE_SERVED="$CUR"
run 1 "drift without grace inputs" FAKE_SERVED="$tmp/previous.sh"
run 2 "fetch error" FAKE_SERVED=
run 2 "non-https URL refused" FAKE_SERVED="$CUR" INSTALL_SH_URL=http://example.invalid/install.sh

run 0 "previous release 30 min after publication" FAKE_SERVED="$tmp/previous.sh" "${GRACE[@]}" \
  INSTALL_SH_NOW_EPOCH=$((PUB_EPOCH + 1800))
grep -q "mid-train grace" "$tmp/out" && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL grace OK not reported"; }
run 0 "previous release at the default grace edge" FAKE_SERVED="$tmp/previous.sh" "${GRACE[@]}" \
  INSTALL_SH_NOW_EPOCH=$((PUB_EPOCH + 7200))
run 1 "previous release past the default grace" FAKE_SERVED="$tmp/previous.sh" "${GRACE[@]}" \
  INSTALL_SH_NOW_EPOCH=$((PUB_EPOCH + 7201))
run 0 "custom grace" FAKE_SERVED="$tmp/previous.sh" "${GRACE[@]}" INSTALL_SH_TRAIN_GRACE_MINUTES=10 \
  INSTALL_SH_NOW_EPOCH=$((PUB_EPOCH + 600))
run 1 "past a custom grace" FAKE_SERVED="$tmp/previous.sh" "${GRACE[@]}" INSTALL_SH_TRAIN_GRACE_MINUTES=10 \
  INSTALL_SH_NOW_EPOCH=$((PUB_EPOCH + 601))
run 1 "non-numeric grace is drift" FAKE_SERVED="$tmp/previous.sh" "${GRACE[@]}" INSTALL_SH_TRAIN_GRACE_MINUTES=2h \
  INSTALL_SH_NOW_EPOCH=$((PUB_EPOCH + 60))
run 1 "other bytes inside the window are drift" FAKE_SERVED="$tmp/other.sh" "${GRACE[@]}" \
  INSTALL_SH_NOW_EPOCH=$((PUB_EPOCH + 60))
run 1 "publish time in the future is drift" FAKE_SERVED="$tmp/previous.sh" "${GRACE[@]}" \
  INSTALL_SH_NOW_EPOCH=$((PUB_EPOCH - 60))
run 1 "unparseable publish time is drift" FAKE_SERVED="$tmp/previous.sh" INSTALL_SH_PREVIOUS_FILE="$tmp/previous.sh" \
  INSTALL_SH_LATEST_PUBLISHED_AT=yesterday INSTALL_SH_NOW_EPOCH="$PUB_EPOCH"
run 1 "missing previous file is drift" FAKE_SERVED="$tmp/previous.sh" INSTALL_SH_PREVIOUS_FILE="$tmp/absent.sh" \
  INSTALL_SH_LATEST_PUBLISHED_AT="$PUB" INSTALL_SH_NOW_EPOCH="$PUB_EPOCH"
run 1 "no publish time is drift" FAKE_SERVED="$tmp/previous.sh" INSTALL_SH_PREVIOUS_FILE="$tmp/previous.sh" \
  INSTALL_SH_NOW_EPOCH="$PUB_EPOCH"

# The scheduled alarm feeds the grace inputs from the previous published tag.
wf="$root/.github/workflows/install-sh-parity-alarm.yml"
for needle in "export INSTALL_SH_PREVIOUS_FILE=" "export INSTALL_SH_LATEST_PUBLISHED_AT" "publishedAt" \
  'git show "$previous_tag:phase3-binary/dist/install.sh"'; do
  if grep -qF -- "$needle" "$wf"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL workflow lacks: $needle"; fi
done

printf 'test-install-sh-parity-grace: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
