#!/usr/bin/env bash
# Studio window preflight: cheap checks on this Mac before a window pauses
# anything. Each failure prints one line starting `BLOCKER: preflight ` on
# stderr; the run exits 1 when any check failed, 2 on a usage error.
#
# Usage (CLI, or `window_preflight ARGS...` after sourcing this file):
#   scripts/ops/lib/window-preflight.sh [checks...]
#   --repo DIR                 clean tree; HEAD is on some origin branch
#                              (`git branch -r --contains HEAD`; fetch first)
#   --fork DIR --resolved FILE --pin-identity NAME
#                              fork HEAD equals NAME's revision in the
#                              Package.resolved FILE; fork tree clean
#   --ship FILE...             every file the window will copy exists locally
#                              (list ends at the next --option)
#   --studio HOST              one ssh call to HOST checking:
#     --python PATH            python3 (default) is >= 3.10
#     --developer-dir DIR      default $HOME/Applications/Xcode.app/Contents/Developer
#                              on the Studio; must hold XCTest.framework under
#                              Platforms/MacOSX.platform
#     --no-xcode               skip the Xcode/XCTest check
#     --studio-clone PATH      a git tree with no am/rebase in progress and an
#                              empty `git status --porcelain`
#     --min-free-gb N          free disk (clone filesystem, else $HOME), default 50
#
# WINDOW_PREFLIGHT_SSH names a command or shell function called as
# `CMD HOST REMOTE_SCRIPT`; the default is `ssh -o BatchMode=yes HOST SCRIPT`.

_wp_fail() { printf 'BLOCKER: preflight %s\n' "$*" >&2; _wp_failures=$((_wp_failures + 1)); }

_wp_default_ssh() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$1" "$2"; }

# Single-quote a value for the remote POSIX shell.
_wp_q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

_wp_repo() {
  local dir="$1" dirty
  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then _wp_fail "repo $dir: not a git tree"; return; fi
  dirty="$(git -C "$dir" status --porcelain 2>/dev/null | head -n 5)"
  [ -z "$dirty" ] || _wp_fail "repo $dir: working tree is not clean: $(printf '%s' "$dirty" | tr '\n' ';')"
  if [ -z "$(git -C "$dir" branch -r --contains HEAD 2>/dev/null)" ]; then
    _wp_fail "repo $dir: HEAD $(git -C "$dir" rev-parse --short HEAD 2>/dev/null) is on no origin branch (push it first)"
  fi
}

_wp_fork() {
  local dir="$1" resolved="$2" identity="$3" want head dirty
  [ -f "$resolved" ] || { _wp_fail "fork: Package.resolved $resolved is missing"; return; }
  want="$(python3 - "$resolved" "$identity" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
name = sys.argv[2].lower()
pins = doc.get("pins") or doc.get("object", {}).get("pins") or []
for pin in pins:
    ident = (pin.get("identity") or pin.get("package") or "").lower()
    if ident == name:
        print(pin.get("state", {}).get("revision", ""))
        break
PY
)" || want=""
  [ -n "$want" ] || { _wp_fail "fork: no revision for identity $identity in $resolved"; return; }
  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then _wp_fail "fork $dir: not a git tree"; return; fi
  head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
  [ "$head" = "$want" ] || _wp_fail "fork $dir: HEAD ${head:-unknown} != $identity pin $want in $resolved"
  dirty="$(git -C "$dir" status --porcelain 2>/dev/null | head -n 5)"
  [ -z "$dirty" ] || _wp_fail "fork $dir: working tree is not clean: $(printf '%s' "$dirty" | tr '\n' ';')"
}

_wp_studio() {
  local host="$1" python="$2" devdir="$3" xcode="$4" clone="$5" min_gb="$6" script out rc=0 line dd
  # shellcheck disable=SC2016  # $HOME and the script body expand on the Studio
  if [ -n "$devdir" ]; then dd="$(_wp_q "$devdir")"; else dd='"$HOME/Applications/Xcode.app/Contents/Developer"'; fi
  # shellcheck disable=SC2016
  script="py=$(_wp_q "$python"); dd=$dd; xcode=$(_wp_q "$xcode"); clone=$(_wp_q "$clone"); min=$(_wp_q "$min_gb")"'
v=$("$py" -c "import sys; print(\"%d %d\" % sys.version_info[:2])" 2>/dev/null) || v=""
if [ -z "$v" ]; then echo "FAIL python: $py is not runnable"
else set -- $v; if [ "$1" -lt 3 ] || { [ "$1" -eq 3 ] && [ "$2" -lt 10 ]; }; then echo "FAIL python: $py is $1.$2, need >= 3.10"; fi; fi
if [ "$xcode" = 1 ]; then
  if [ ! -d "$dd" ]; then echo "FAIL xcode: DEVELOPER_DIR $dd does not exist"
  elif [ -z "$(find "$dd/Platforms/MacOSX.platform" -maxdepth 6 -name XCTest.framework 2>/dev/null | head -n 1)" ]; then echo "FAIL xcode: no XCTest.framework under $dd/Platforms/MacOSX.platform"; fi
fi
target="$HOME"
if [ -n "$clone" ]; then
  if ! gd=$(git -C "$clone" rev-parse --absolute-git-dir 2>/dev/null); then echo "FAIL clone: $clone is not a git tree"
  else
    target="$clone"
    if [ -d "$gd/rebase-apply" ] || [ -d "$gd/rebase-merge" ]; then echo "FAIL clone: $clone has a git am/rebase in progress"; fi
    n=$(git -C "$clone" status --porcelain 2>/dev/null | wc -l | tr -d " ")
    if [ "$n" != 0 ]; then echo "FAIL clone: $clone has $n uncommitted or untracked paths"; fi
  fi
fi
kb=$(df -Pk "$target" 2>/dev/null | awk "NR==2 {print \$4}")
if [ -z "$kb" ]; then echo "FAIL disk: cannot read free space of $target"
elif [ $((kb / 1048576)) -lt "$min" ]; then echo "FAIL disk: $((kb / 1048576)) GB free on $target, need >= $min GB"; fi
echo PREFLIGHT_DONE'
  # /bin/sh -c: the Studio login shell may be zsh, which does not word-split.
  out="$("${WINDOW_PREFLIGHT_SSH:-_wp_default_ssh}" "$host" "/bin/sh -c $(_wp_q "$script")" 2>/dev/null)" || rc=$?
  while IFS= read -r line; do
    case "$line" in "FAIL "*) _wp_fail "studio $host: ${line#FAIL }" ;; esac
  done <<< "$out"
  if [ "$rc" != 0 ] || ! grep -qx PREFLIGHT_DONE <<< "$out"; then
    _wp_fail "studio $host: ssh check did not complete (rc=$rc)"
  fi
}

window_preflight() {
  local repo="" fork="" resolved="" identity="" studio="" python=python3 devdir="" xcode=1 clone="" min_gb=50 f
  local -a ship=()
  local ship_set=false
  _wp_failures=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo="${2:?--repo needs DIR}"; shift 2 ;;
      --fork) fork="${2:?--fork needs DIR}"; shift 2 ;;
      --resolved) resolved="${2:?--resolved needs FILE}"; shift 2 ;;
      --pin-identity) identity="${2:?--pin-identity needs NAME}"; shift 2 ;;
      --ship) ship_set=true; shift; while [ $# -gt 0 ] && [[ "$1" != --* ]]; do ship+=("$1"); shift; done ;;
      --studio) studio="${2:?--studio needs HOST}"; shift 2 ;;
      --python) python="${2:?--python needs PATH}"; shift 2 ;;
      --developer-dir) devdir="${2:?--developer-dir needs DIR}"; shift 2 ;;
      --no-xcode) xcode=0; shift ;;
      --studio-clone) clone="${2:?--studio-clone needs PATH}"; shift 2 ;;
      --min-free-gb) min_gb="${2:?--min-free-gb needs N}"; shift 2 ;;
      *) printf 'window-preflight: unknown argument %s\n' "$1" >&2; return 2 ;;
    esac
  done
  [[ "$min_gb" =~ ^[0-9]+$ ]] || { printf 'window-preflight: --min-free-gb must be an integer\n' >&2; return 2; }
  if [ -n "$fork$resolved$identity" ] && { [ -z "$fork" ] || [ -z "$resolved" ] || [ -z "$identity" ]; }; then
    printf 'window-preflight: --fork, --resolved and --pin-identity go together\n' >&2; return 2
  fi
  [ -z "$repo" ] || _wp_repo "$repo"
  [ -z "$fork" ] || _wp_fork "$fork" "$resolved" "$identity"
  if [ "$ship_set" = true ]; then
    [ "${#ship[@]}" -gt 0 ] || _wp_fail "ship: --ship lists no files"
    for f in ${ship[@]+"${ship[@]}"}; do
      [ -f "$f" ] || _wp_fail "ship: $f is missing (the window would copy it)"
    done
  fi
  [ -z "$studio" ] || _wp_studio "$studio" "$python" "$devdir" "$xcode" "$clone" "$min_gb"
  if [ "$_wp_failures" -gt 0 ]; then
    printf 'window-preflight: %d check(s) failed; nothing was paused\n' "$_wp_failures" >&2
    return 1
  fi
  printf 'window-preflight: ok\n' >&2
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  window_preflight "$@"
  exit $?
fi
