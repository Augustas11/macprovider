#!/usr/bin/env bash
# Step 1 (host): ship the two trees under test into the VM as one git repo
# with two commits (no history needed):
#   old = $E2E_OLD_REF of the canonical checkout (GitHub origin/main, the
#         production v1.8.193 / gateway schema 13 baseline)   tag v1.8.193
#   new = HEAD of the #1690 branch on the Studio (read-only bundle) tag v1.8.194
# The Studio worktree is only read (git bundle create); nothing is written there.
set -euo pipefail
. "$(dirname "$0")/env.sh"
OLD="$(git -C "$E2E_CANON" rev-parse "$E2E_OLD_REF")"
ssh "$E2E_STUDIO" "cd '$E2E_STUDIO_WT' && git rev-parse HEAD >&2 && git bundle create - origin/main..HEAD" >"$E2E_WORK/b1690.bundle" 2>"$E2E_WORK/b1690.head"
NEW="$(tr -d '[:space:]' <"$E2E_WORK/b1690.head")"
rm -rf "$E2E_WORK/src"
git clone -q --no-checkout "$E2E_CANON" "$E2E_WORK/src"
git -C "$E2E_WORK/src" fetch -q "$E2E_WORK/b1690.bundle" "HEAD:refs/heads/b1690"
[ "$(git -C "$E2E_WORK/src" rev-parse b1690)" = "$NEW" ] || e2e_die "bundle head mismatch"
git -C "$E2E_WORK/src" archive --format=tar "$OLD" >"$E2E_WORK/old.tar"
git -C "$E2E_WORK/src" archive --format=tar "$NEW" >"$E2E_WORK/new.tar"
printf 'old=%s\nnew=%s\n' "$OLD" "$NEW" >"$E2E_WORK/commits.env"
for t in old new; do vm_put "$E2E_WORK/$t.tar" "$E2E_VM_ROOT/$t.tar"; done
vm_put "$E2E_WORK/commits.env" "$E2E_VM_ROOT/commits.env"
vm_script <<'SH'
set -euo pipefail
. /root/e2e/commits.env
R=/root/e2e/repo
rm -rf "$R"; mkdir -p "$R"; cd "$R"
git init -q -b main
git config user.name "E2E Operator"; git config user.email e2e@test.invalid; git config advice.detachedHead false
tar -xf /root/e2e/old.tar
git add -A; git commit -q -m "old: origin/main $old (production baseline)"
git tag -a -m old v1.8.193
git rm -q -r --cached . >/dev/null; find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
tar -xf /root/e2e/new.tar
git add -A; git commit -q -m "new: #1690 branch $new"
git tag -a -m new v1.8.194
for t in old new; do rm -rf /root/e2e/wt-$t; done
git worktree add -q /root/e2e/wt-old v1.8.193
git worktree add -q /root/e2e/wt-new v1.8.194
git log --oneline --decorate | cat
SH
e2e_log "sources in VM: old=$OLD new=$NEW"
