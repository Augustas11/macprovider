#!/usr/bin/env bash
# Tier E2 step 1: build the scratch repository the operator lane runs from.
#
#   $E2E_BARE  (local bare repo)  plays `origin`; nothing is pushed to GitHub.
#   e2e-pre    = $E2E_PRE_BASE (v1.8.191, pre-#1693) + genesis   -> tag $E2E_TAG_PRE
#   main       = merge(e2e-pre, $E2E_BRANCH_HEAD) with the genesis applied
#                (same test identities, same release A bytes)    -> tag $E2E_TAG_ENABLE
# Tags are annotated and SSH-signed with the test tag key; the genesis points
# the deploy/build release-tag checks at that key and at the bare origin.
# Rerunning rebuilds everything from scratch (the VM is not touched).
set -euo pipefail
. "$(dirname "$0")/env.sh"

rm -rf "$E2E_REPO" "$E2E_BARE"
git init -q --bare "$E2E_BARE"
git clone -q --no-checkout "$E2E_SRC_REPO" "$E2E_REPO"
cd "$E2E_REPO"
git remote set-url origin "$E2E_BARE_URL"
# Drop the source repo's branches the clone recorded as origin/*: catalog-release.py
# compares the release ledger with origin/main, which must be the scratch origin
# (the pre-#1693 base until the first push), never whatever the source checkout's main is now.
git for-each-ref --format='%(refname)' refs/remotes/origin | xargs -r -n 50 git update-ref -d 2>/dev/null ||
  git for-each-ref --format='%(refname)' refs/remotes/origin | while read -r r; do git update-ref -d "$r"; done
git config user.name "E2E Operator"
git config user.email e2e@test.invalid
git config gpg.format ssh
git config user.signingkey "$E2E_KEYS/tag_signing_ed25519.pub"
printf 'e2e@test.invalid %s\n' "$(cat "$E2E_KEYS/tag_signing_ed25519.pub")" >"$E2E_KEYS/allowed_signers"
git config gpg.ssh.allowedSignersFile "$E2E_KEYS/allowed_signers"
git config advice.detachedHead false
git fetch -q "$E2E_SRC_REPO" "$E2E_BRANCH_HEAD"
# The release ledger base for the pre-#1693 genesis is the base commit itself.
git update-ref refs/remotes/origin/main "$E2E_PRE_BASE"

export E2E_GENERATED_AT="${E2E_GENERATED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
printf '%s\n' "$E2E_GENERATED_AT" >"$E2E_WORK/release-a.generated_at"

# ---- pre-#1693 world --------------------------------------------------------
git checkout -q -b e2e-pre "$E2E_PRE_BASE"
bash "$E2E_HARNESS/lib/genesis.sh" "$E2E_REPO" cut >"$E2E_LOGS/genesis-pre.log" 2>&1 ||
  { tail -30 "$E2E_LOGS/genesis-pre.log"; e2e_die "genesis on $E2E_PRE_BASE failed"; }
git add -A phase3-binary phase4-coordinator scripts ops
git commit -q -m "E2E genesis: test trust identities and release $E2E_RELEASE_A (pre-#1693 base)"
git tag -s -m "$E2E_TAG_PRE (e2e pre-#1693)" "$E2E_TAG_PRE"
PRE_TIP="$(git rev-parse HEAD)"

# ---- the branch under test, same test world ---------------------------------
# Tree = branch head + genesis identities + release A files copied verbatim from
# e2e-pre (the enabling deploy then carries the live catalog: compare-live
# `equivalent`). Parents = (e2e-pre, branch head) so both are ancestors.
git checkout -q --detach "$E2E_BRANCH_HEAD"
bash "$E2E_HARNESS/lib/genesis.sh" "$E2E_REPO" keep-release >"$E2E_LOGS/genesis-main.log" 2>&1 ||
  { tail -30 "$E2E_LOGS/genesis-main.log"; e2e_die "genesis on the branch failed"; }
for p in $(git diff --name-only "$E2E_PRE_BASE" "$PRE_TIP" -- phase3-binary/catalog phase3-binary/dist/static \
    phase3-binary/Sources phase4-coordinator/internal phase4-coordinator/cmd); do
  git checkout -q "$PRE_TIP" -- "$p"
done
# The committed coordinator.yaml keeps the branch's content with the genesis
# keys, plus release A's rate_card block (release A carries one test row).
python3 "$E2E_HARNESS/lib/sync-dist-rate-card.py"
git add -A phase3-binary phase4-coordinator scripts ops
TREE="$(git write-tree)"
MAIN="$(git commit-tree "$TREE" -p "$PRE_TIP" -p "$E2E_BRANCH_HEAD" -m "E2E: merge #1693 branch ($E2E_BRANCH_HEAD) into the e2e world")"
git checkout -q -B main "$MAIN"
git tag -s -m "$E2E_TAG_ENABLE (e2e enabling #1693 runtime)" "$E2E_TAG_ENABLE"
git push -q origin e2e-pre main "refs/tags/$E2E_TAG_PRE" "refs/tags/$E2E_TAG_ENABLE"
git fetch -q origin
git branch -q --set-upstream-to=origin/main main
git verify-tag "$E2E_TAG_ENABLE" 2>&1 | head -1
python3 scripts/catalog-release.py verify >/dev/null
e2e_log "scratch repo ready: pre=$(git rev-parse "$E2E_TAG_PRE^{commit}") main=$(git rev-parse main)"
