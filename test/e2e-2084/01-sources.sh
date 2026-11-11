#!/usr/bin/env bash
# Step 1 (host): ship the two trees under test into the VM as one git repo
# with two commits (read-only on the host: git archive / stash create only):
#   old = $E2E_OLD_REF (production baseline, origin/main)   -> /root/e2e/wt-old
#   new = $E2E_NEW_REF (the #2084 code under test)          -> /root/e2e/wt-new
# Without E2E_NEW_REF the new tree is the harness checkout's working tree:
# `git stash create` records tracked edits as a commit object without
# touching the index, stash list or files, so a fix that is not committed yet
# (the secret hook keeps some files uncommitted) is tested as it will land.
set -euo pipefail
. "$(dirname "$0")/env.sh"
OLD="$(git -C "$E2E_SRC" rev-parse --verify "$E2E_OLD_REF^{commit}")"
if [ -n "${E2E_NEW_REF:-}" ]; then
  NEW="$(git -C "$E2E_SRC" rev-parse --verify "$E2E_NEW_REF^{commit}")"; NEW_DESC="$E2E_NEW_REF"
else
  NEW="$(git -C "$E2E_SRC" stash create 2>/dev/null || true)"
  if [ -z "$NEW" ]; then NEW="$(git -C "$E2E_SRC" rev-parse HEAD)"; NEW_DESC="HEAD"; else NEW_DESC="worktree (HEAD $(git -C "$E2E_SRC" rev-parse --short HEAD) + tracked edits)"; fi
fi
git -C "$E2E_SRC" archive --format=tar "$OLD" >"$E2E_WORK/old.tar"
git -C "$E2E_SRC" archive --format=tar "$NEW" >"$E2E_WORK/new.tar"
printf 'old=%s\nnew=%s\nnew_desc=%q\n' "$OLD" "$NEW" "$NEW_DESC" >"$E2E_WORK/commits.env"
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
git tag -a -m old v1.8.210
git rm -q -r --cached . >/dev/null; find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
tar -xf /root/e2e/new.tar
git add -A; git commit -q -m "new: #2084 $new"
git tag -a -m new v1.8.211
for t in old new; do git worktree remove --force /root/e2e/wt-$t 2>/dev/null || rm -rf /root/e2e/wt-$t; done
git worktree prune
git worktree add -q /root/e2e/wt-old v1.8.210
git worktree add -q /root/e2e/wt-new v1.8.211
git log --oneline --decorate | cat
SH
e2e_log "sources in VM: old=$OLD new=$NEW ($NEW_DESC)"
