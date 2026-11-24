#!/usr/bin/env bash
# Offline tests for lib/window-preflight.sh: temp git repos and a PATH-shimmed
# ssh that runs the remote script locally with a fake Studio $HOME. Every
# check must fail loudly (BLOCKER: preflight ..., rc 1) and pass when satisfied.
set -euo pipefail

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PF="$OPS_DIR/lib/window-preflight.sh"
tmp="$(mktemp -d -t window-preflight.XXXXXX)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'not ok - %s\n' "$*" >&2; }

# run WANT_RC DESC [WANT_STDERR_SUBSTRING] -- ARGS...
run() {
  local want="$1" desc="$2" needle="$3" rc=0
  shift 4
  bash "$PF" "$@" >"$tmp/out" 2>"$tmp/err" || rc=$?
  if [ "$rc" != "$want" ]; then bad "$desc: want rc=$want got rc=$rc"; sed 's/^/    /' "$tmp/err"; return; fi
  if [ -n "$needle" ] && ! grep -qF -- "$needle" "$tmp/err"; then bad "$desc: stderr lacks '$needle'"; sed 's/^/    /' "$tmp/err"; return; fi
  if [ "$want" = 1 ] && ! grep -q '^BLOCKER: preflight ' "$tmp/err"; then bad "$desc: no BLOCKER line"; return; fi
  ok
}

g() { git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

# ---- repo: clean + pushed ------------------------------------------------------
g init -q --bare "$tmp/origin.git"
g init -q "$tmp/repo"
echo a > "$tmp/repo/a"; g -C "$tmp/repo" add a; g -C "$tmp/repo" commit -q -m a
g -C "$tmp/repo" remote add origin "$tmp/origin.git"
g -C "$tmp/repo" push -q origin HEAD:refs/heads/main
g -C "$tmp/repo" fetch -q origin
run 0 "pushed clean repo passes" "window-preflight: ok" -- --repo "$tmp/repo"
echo b > "$tmp/repo/b"
run 1 "untracked file fails" "working tree is not clean" -- --repo "$tmp/repo"
g -C "$tmp/repo" add b; g -C "$tmp/repo" commit -q -m b
run 1 "unpushed HEAD fails" "is on no origin branch" -- --repo "$tmp/repo"
g -C "$tmp/repo" push -q origin HEAD:refs/heads/topic
g -C "$tmp/repo" fetch -q origin
run 0 "HEAD on any origin branch passes" "" -- --repo "$tmp/repo"
run 1 "non-repo fails" "not a git tree" -- --repo "$tmp"

# ---- fork vs Package.resolved ----------------------------------------------------
g init -q "$tmp/fork"
echo f > "$tmp/fork/f"; g -C "$tmp/fork" add f; g -C "$tmp/fork" commit -q -m f
pin="$(g -C "$tmp/fork" rev-parse HEAD)"
resolved() {
  printf '{"pins":[{"identity":"mlx-swift-lm","kind":"remoteSourceControl","location":"https://x/mlx-swift-lm","state":{"revision":"%s","version":"1.0.0"}}],"version":2}\n' "$1" > "$tmp/Package.resolved"
}
resolved "$pin"
run 0 "fork at the pin passes" "" -- --fork "$tmp/fork" --resolved "$tmp/Package.resolved" --pin-identity mlx-swift-lm
resolved 0000000000000000000000000000000000000001
run 1 "fork off the pin fails" "!= mlx-swift-lm pin" -- --fork "$tmp/fork" --resolved "$tmp/Package.resolved" --pin-identity mlx-swift-lm
resolved "$pin"
run 1 "unknown identity fails" "no revision for identity mlx-swift" -- --fork "$tmp/fork" --resolved "$tmp/Package.resolved" --pin-identity mlx-swift
echo dirty >> "$tmp/fork/f"
run 1 "dirty fork fails" "fork $tmp/fork: working tree is not clean" -- --fork "$tmp/fork" --resolved "$tmp/Package.resolved" --pin-identity mlx-swift-lm
g -C "$tmp/fork" checkout -q -- f
run 1 "missing Package.resolved fails" "is missing" -- --fork "$tmp/fork" --resolved "$tmp/nope.resolved" --pin-identity mlx-swift-lm
run 2 "partial fork options are a usage error" "go together" -- --fork "$tmp/fork"

# ---- ship list -------------------------------------------------------------------
touch "$tmp/helper.py" "$tmp/job.sh"
run 0 "shipped files present" "" -- --ship "$tmp/helper.py" "$tmp/job.sh"
run 1 "missing shipped file fails" "$tmp/absent.sh is missing" -- --ship "$tmp/helper.py" "$tmp/absent.sh"
run 1 "empty ship list fails" "lists no files" -- --ship --repo "$tmp/repo"

# ---- studio over a fake ssh -------------------------------------------------------
studio_home="$tmp/studio-home"
mkdir -p "$tmp/bin" "$studio_home/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework"
# The fake ssh runs the remote command locally as the Studio would: fake $HOME,
# and FAKE_SSH_RC makes the connection itself fail.
cat > "$tmp/bin/ssh" <<'SH'
#!/usr/bin/env bash
[ -z "${FAKE_SSH_RC:-}" ] || exit "$FAKE_SSH_RC"
HOME="$FAKE_STUDIO_HOME" exec bash -c "${@: -1}"
SH
for v in "3 9" "3 12"; do
  printf '#!/bin/sh\necho "%s"\n' "$v" > "$tmp/bin/python-${v/ /.}"
done
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH" FAKE_STUDIO_HOME="$studio_home"
g init -q "$tmp/studio-clone"
echo s > "$tmp/studio-clone/s"; g -C "$tmp/studio-clone" add s; g -C "$tmp/studio-clone" commit -q -m s
S=(--studio fake-studio --python "$tmp/bin/python-3.12" --min-free-gb 0)

run 0 "satisfied Studio passes" "window-preflight: ok" -- "${S[@]}" --studio-clone "$tmp/studio-clone"
run 1 "python 3.9 fails" "is 3.9, need >= 3.10" -- --studio fake-studio --python "$tmp/bin/python-3.9" --min-free-gb 0
run 1 "missing python fails" "is not runnable" -- --studio fake-studio --python "$tmp/bin/no-python" --min-free-gb 0
run 1 "missing DEVELOPER_DIR fails" "does not exist" -- "${S[@]}" --developer-dir "$tmp/no-xcode"
mkdir -p "$tmp/empty-xcode/Platforms/MacOSX.platform"
run 1 "Xcode without XCTest fails" "no XCTest.framework" -- "${S[@]}" --developer-dir "$tmp/empty-xcode"
run 0 "--no-xcode skips the Xcode check" "" -- "${S[@]}" --developer-dir "$tmp/empty-xcode" --no-xcode
echo x >> "$tmp/studio-clone/s"
run 1 "dirty Studio clone fails" "1 uncommitted or untracked paths" -- "${S[@]}" --studio-clone "$tmp/studio-clone"
g -C "$tmp/studio-clone" checkout -q -- s
mkdir "$tmp/studio-clone/.git/rebase-apply"
run 1 "git am in progress fails" "git am/rebase in progress" -- "${S[@]}" --studio-clone "$tmp/studio-clone"
rmdir "$tmp/studio-clone/.git/rebase-apply"
run 1 "non-git Studio clone fails" "is not a git tree" -- "${S[@]}" --studio-clone "$tmp"
run 1 "low disk fails" "need >= 999999999 GB" -- --studio fake-studio --python "$tmp/bin/python-3.12" --min-free-gb 999999999
FAKE_SSH_RC=255 run 1 "ssh failure fails" "ssh check did not complete (rc=255)" -- "${S[@]}"
run 2 "bad --min-free-gb is a usage error" "must be an integer" -- --studio fake-studio --min-free-gb lots

# ---- combined + sourced function -----------------------------------------------------
run 1 "every failing check is reported" "3 check(s) failed" -- --ship "$tmp/absent" --fork "$tmp/fork" --resolved "$tmp/nope" --pin-identity x \
  --studio fake-studio --python "$tmp/bin/python-3.9" --min-free-gb 0
rc=0
(
  # shellcheck source=lib/window-preflight.sh
  . "$PF"
  # shellcheck disable=SC2329  # called through WINDOW_PREFLIGHT_SSH
  fake_studio_ssh() { printf 'custom-ssh %s\n' "$1" >> "$tmp/custom-ssh.log"; HOME="$FAKE_STUDIO_HOME" bash -c "$2"; }
  WINDOW_PREFLIGHT_SSH=fake_studio_ssh window_preflight "${S[@]}"
) 2>"$tmp/err" || rc=$?
if [ "$rc" = 0 ] && grep -q 'custom-ssh fake-studio' "$tmp/custom-ssh.log"; then ok; else bad "sourced window_preflight with WINDOW_PREFLIGHT_SSH (rc=$rc)"; fi

printf 'window-preflight: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
