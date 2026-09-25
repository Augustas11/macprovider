#!/usr/bin/env bash
# #1690 e2e mixed-version pairings. Each pairing gets its own lab dir with
# fresh databases (an old gateway refuses a schema v14 database; an old
# coordinator refuses a database whose billing_compat_floor is above its
# contract), sharing the e2e lab's keys and static release so the lab CLIs
# (which bake that release) join unchanged.
#
#   mix_setup.sh A   new coordinator + origin/main gateway -> LAB .../e2e-mixA
#   mix_setup.sh B   origin/main coordinator + new gateway -> LAB .../e2e-mixB
# MIX_LAB overrides the lab dir (a fresh pairing next to kept evidence).
#
# origin/main binaries come from $SRC_LAB/bin-main (built from a detached
# origin/main worktree). Prints the LAB to use with run_matrix.sh.
set -euo pipefail
SRC_LAB="${SRC_LAB:-/Users/a1/lab-1690-m6/e2e}"
HERE="$(cd "$(dirname "$0")" && pwd)"
case "${1:-}" in A) LAB=${MIX_LAB:-/Users/a1/lab-1690-m6/e2e-mixA} ;; B) LAB=${MIX_LAB:-/Users/a1/lab-1690-m6/e2e-mixB} ;; *) echo "usage: mix_setup.sh A|B" >&2; exit 2 ;; esac
export LAB
"$HERE/setup.sh" >/dev/null
for f in secrets.json static-feed.ed25519 tier2.priv tier2.pub; do cp -p "$SRC_LAB/keys/$f" "$LAB/keys/$f"; done
cp -p "$SRC_LAB"/static/* "$LAB/static/"
cp -p "$SRC_LAB"/bin/* "$LAB/bin/"
if [[ "$1" == A ]]; then cp -p "$SRC_LAB/bin-main/gateway" "$LAB/bin/gateway"; else cp -p "$SRC_LAB/bin-main/coordinator" "$LAB/bin/coordinator"; fi
shasum -a 256 "$LAB/bin/coordinator" "$LAB/bin/gateway" "$SRC_LAB/bin-main/coordinator" "$SRC_LAB/bin-main/gateway" | sed "s#$SRC_LAB#SRC_LAB#; s#$LAB#LAB#"
echo "$LAB"
