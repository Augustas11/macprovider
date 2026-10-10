#!/usr/bin/env bash
# shellcheck disable=SC2016  # command lines under test are literal text
# Block/allow cases for scripts/ops/hooks/claude-pretooluse-ops-guard.sh.
# Usage: bash scripts/ops/test-ops-guard.sh
set -euo pipefail

GUARD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hooks/claude-pretooluse-ops-guard.sh"
pass=0
fail=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

event() {
  python3 -c 'import json,sys; print(json.dumps({"tool_name": sys.argv[1], "tool_input": {"command": sys.argv[2]}, "cwd": sys.argv[3]}))' "$1" "$2" "$tmp"
}

# expect WANT(block|allow) COMMAND [TOOL] [ENV_MARKER]
expect() {
  local want="$1" cmd="$2" tool="${3:-Bash}" marker="${4:-}" rc=0
  if [ -n "$marker" ]; then
    event "$tool" "$cmd" | env MACPROVIDER_OPS_ENTRYPOINT="$marker" bash "$GUARD" 2>"$tmp/err" || rc=$?
  else
    event "$tool" "$cmd" | env -u MACPROVIDER_OPS_ENTRYPOINT bash "$GUARD" 2>"$tmp/err" || rc=$?
  fi
  local got=allow
  [ "$rc" -eq 2 ] && got=block
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then got="error($rc)"; fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL want=%s got=%s: %s\n' "$want" "$got" "$cmd"
    sed 's/^/    /' "$tmp/err"
  fi
}

# --- workflow dispatches ---
expect block 'gh workflow run acceptance-candidate.yml --ref main -f tag=v1.8.230'
expect block 'gh workflow run promote-acceptance-candidate.yml -f tag=v1'
expect block 'gh workflow run release.yml --ref main -f version=v1.8.230'
expect block 'gh workflow run pearl-runtime-release.yml --ref main -f version=v1.8.230 -f prerelease=true'
expect block 'gh -R Augustas11/macprovider workflow run release.yaml'
expect block 'cd /x && gh workflow run "pearl-runtime-release.yml" --ref main'
expect block 'gh api -X POST repos/o/r/actions/workflows/release.yml/dispatches -f ref=main'
expect allow 'gh workflow run malibu-release.yml --ref main'
expect allow 'gh workflow run promote-signed-native-mtp-release-journey.yml'
expect allow 'gh workflow view release.yml'
expect allow 'gh run list -w release.yml -L 5'
expect allow 'gh workflow run ci.yml'

# --- Pearl mutations ---
expect block 'bash phase4-coordinator/dist/deploy-pearl-vps.sh'
expect block 'FORCE_RESTART=1 CONFIG_MODE=preserve-live bash phase4-coordinator/dist/deploy-pearl-vps.sh || true'
expect block 'scripts/catalog-content-release.sh --deploy --commit abc'
expect allow 'scripts/catalog-content-release.sh --preflight --commit abc'
expect block 'scripts/publish-native-mtp-revocations.sh --deploy'
expect allow 'scripts/publish-native-mtp-revocations.sh'
expect block "ssh \"\$PEARL_SSH\" '/usr/local/sbin/macprovider-pearl-update --apply --tag v1.8.230'"
expect allow "ssh \"\$PEARL_SSH\" '/usr/local/sbin/macprovider-pearl-update --plan --tag v1.8.230'"
expect block "ssh host 'sudo systemctl restart macprovider-coordinator'"
expect block 'systemctl --no-block restart macprovider-coordinator.service'
expect allow 'systemctl status macprovider-coordinator'
expect allow 'journalctl -u macprovider-coordinator -n 50'
expect allow 'grep -n "systemctl restart macprovider-coordinator" docs/runbooks/pearl-coordinator-rollout.md && echo ok'
expect block 'sudo -u root systemctl try-restart macprovider-coordinator'
expect block 'service macprovider-coordinator restart'
expect allow 'service macprovider-coordinator status'

# --- M1: guarded names as arguments of read-only commands are allowed ---
expect allow 'grep -rn deploy-pearl-vps.sh docs'
expect allow 'git log --oneline -- phase4-coordinator/dist/deploy-pearl-vps.sh'
expect allow 'bash -n phase4-coordinator/dist/deploy-pearl-vps.sh'
expect allow 'bash -euo pipefail -n phase4-coordinator/dist/deploy-pearl-vps.sh'
expect allow 'rg "gh workflow run release.yml" docs'
expect allow 'cat scripts/catalog-content-release.sh | head -n 40'
expect allow 'sed -n 1,20p scripts/publish-native-mtp-revocations.sh'
expect allow "awk '/--apply/' ops/runbooks/pearl-release-updater.md"
expect allow 'echo "run deploy-pearl-vps.sh later" # deploy-pearl-vps.sh'
expect allow 'less docs/runbooks/pearl-coordinator-rollout.md'
# ... but wrappers are unwrapped
expect block 'sudo -E env FOO=1 nohup bash phase4-coordinator/dist/deploy-pearl-vps.sh'
expect block 'time nice -n 10 ./phase4-coordinator/dist/deploy-pearl-vps.sh'
expect block "bash -c 'cd /x && scripts/catalog-content-release.sh --deploy --commit abc'"
expect block "sh -ec \"gh workflow run release.yml\""
expect block "ssh -i key -p 22 host 'sudo systemctl restart macprovider-coordinator'"
expect block "ssh host sudo systemd-run --unit=mp-update-1 -p UMask=0077 /usr/local/sbin/macprovider-pearl-update --apply --tag v1.8.230"
expect block 'echo "$(gh workflow run release.yml)"'
expect block 'eval "gh workflow run pearl-runtime-release.yml"'
expect block 'timeout 60 scripts/publish-native-mtp-revocations.sh --deploy'

# --- M2: display names, numeric ids, reruns ---
expect block 'gh workflow run "Sign private acceptance candidate" --ref main'
expect block 'gh workflow run "Promote exact physically accepted candidate"'
expect block 'gh workflow run "release macprovider-cli" -f version=v1'
expect block "gh workflow run 'Release Pearl runtime' -f version=v1"
expect block 'gh workflow run "Verify live coordinator release rollout" -f tag=v1'
expect block 'gh workflow run 123456789 --ref main'
expect block 'gh api -X POST repos/o/r/actions/workflows/987654/dispatches -f ref=main'
expect block 'gh run rerun 37746076994'
expect block 'gh -R o/r run rerun 1 --failed'
expect allow 'gh run view 37746076994 --log'
expect allow 'gh workflow run "CI" --ref main'

# --- M3: separators, comments, entry-point exemption ---
expect block 'scripts/ops/cli-release.sh status & gh workflow run release.yml'
expect block 'echo x # comment
bash phase4-coordinator/dist/deploy-pearl-vps.sh'
expect allow '# bash phase4-coordinator/dist/deploy-pearl-vps.sh'
expect block 'cat scripts/ops/README.md; bash phase4-coordinator/dist/deploy-pearl-vps.sh'
expect block 'ls scripts/ops/ && gh workflow run release.yml'
expect allow 'bash scripts/ops/catalog-activate.sh next --run'
expect allow './scripts/ops/pearl-runtime.sh status'

# --- entry points and the marker ---
expect allow 'scripts/ops/catalog-activate.sh next --run'
expect allow 'MACPROVIDER_OPS_OWNER=me scripts/ops/pearl-runtime.sh next --run'
expect allow 'MACPROVIDER_OPS_OWNER=me scripts/ops/cli-release.sh next --run'
expect allow 'scripts/ops/cli-release.sh status'
expect block 'scripts/ops/cli-release.sh _pearl-config --accepted-id x'
expect block 'bash scripts/ops/cli-release.sh _pearl-config --recommend 1.2.3 x'
expect block 'scripts/ops/cli-release.sh _revoke-seed'
expect block "ssh pearl 'python3 - apply --accepted-id x' < scripts/ops/lib/pearl-cli-config.py"
expect block 'python3 scripts/ops/lib/pearl-cli-config.py apply --accepted-id x'
expect allow 'grep -n accepted scripts/ops/lib/pearl-cli-config.py'
expect allow 'bash scripts/ops/cli-release.sh status'
expect allow 'gh workflow run release.yml --ref main -f version=v1.8.230' Bash 1
expect allow 'bash phase4-coordinator/dist/deploy-pearl-vps.sh' Bash 1
expect block 'MACPROVIDER_OPS_ENTRYPOINT=1 gh workflow run release.yml'
expect block 'export MACPROVIDER_OPS_ENTRYPOINT=1; bash phase4-coordinator/dist/deploy-pearl-vps.sh'
expect block 'scripts/ops/cli-release.sh status; gh workflow run release.yml'
expect allow 'gh workflow run release.yml' Read
expect block 'export FOO=1 MACPROVIDER_OPS_ENTRYPOINT=1'
expect block 'env MACPROVIDER_OPS_ENTRYPOINT=1 bash phase4-coordinator/dist/deploy-pearl-vps.sh'
expect allow 'grep -rn "MACPROVIDER_OPS_ENTRYPOINT=" scripts/ops'

# --- closing keywords ---
expect block 'git commit -m "Fix the router. Closes #123"'
expect block 'git commit -m "fixes #9"'
expect block 'git commit -m "Resolved: #77"'
expect block 'gh pr create --title "x" --body "This does not close #1749 yet."'
expect block 'gh pr create --body "not fixing; fixed #12 is wrong wording"'
expect block 'gh pr edit 1900 --body "Resolves Augustas11/macprovider#1749"'
expect block "git commit -F- <<'EOF'
Subject

Close #42
EOF"
expect allow 'git commit -m "Refs #123: tighten router"'
expect allow 'gh pr create --title "Part of #1749" --body "Tracks #1749"'
expect allow 'git commit -m "Fix the prefix #3 parser"'
expect allow 'git commit -m "fixed in 1.8.230"'
expect allow 'git log --grep "fixes #12"'
expect block 'git -c user.name=x -C . commit -m "closes #5"'
expect block 'git --no-pager commit -am "Fixes https://github.com/Augustas11/macprovider/issues/1749"'
expect block 'gh pr merge 1900 --squash --subject "Resolve #12"'
expect block 'gh pr merge 1900 --squash --body "closed #12"'
expect allow 'gh pr merge 1900 --squash --subject "Refs #12"'
expect allow 'git commit -m "See https://github.com/Augustas11/macprovider/issues/1749"'
printf 'Body\n\nThis does not resolve #55.\n' > "$tmp/body.md"
expect block "gh pr create --title t --body-file body.md"
printf 'Body\n\nRefs #55.\n' > "$tmp/ok.md"
expect allow "gh pr create --title t --body-file ok.md"
printf 'Subject\n\nfixes #8\n' > "$tmp/msg.txt"
expect block "git commit -F msg.txt"

# --- round 2: more wrappers ---
expect block "ssh pearl 'flock -n /run/lock/a flock -n /opt/b systemctl restart macprovider-coordinator'"
expect block 'flock /tmp/l bash phase4-coordinator/dist/deploy-pearl-vps.sh'
expect block 'flock -w 30 -E 9 /tmp/l -c "scripts/catalog-content-release.sh --deploy --commit abc"'
expect block "su -c 'systemctl restart macprovider-coordinator'"
expect block "su - root -c 'systemctl restart macprovider-coordinator'"
expect block "runuser -u root -- bash -c 'systemctl restart macprovider-coordinator'"
expect block '. phase4-coordinator/dist/deploy-pearl-vps.sh'
expect block 'source phase4-coordinator/dist/deploy-pearl-vps.sh'
expect block 'watch -n 5 systemctl restart macprovider-coordinator'
expect block "ssh -o BatchMode=yes -p 22 pearl -- 'macprovider-pearl-update --apply'"
expect block 'doas -u root systemctl restart macprovider-coordinator'
expect block 'setsid -f bash phase4-coordinator/dist/deploy-pearl-vps.sh'
expect block "script -q -c 'gh workflow run release.yml' /dev/null"
expect block 'chroot /srv/root /usr/local/sbin/macprovider-pearl-update --apply'
expect block 'gh api -X POST "repos/o/r/actions/workflows/$WF/dispatches" -f ref=main'
expect block 'gh workflow run "$WORKFLOW" --ref main'
expect allow 'flock -n /tmp/l true'
expect allow 'source scripts/ops/lib/common.sh'
expect allow 'watch -n 5 curl -s localhost/healthz'
expect allow "ssh pearl -- 'macprovider-pearl-update --plan --tag v1.8.230'"

# --- malformed input fails open ---
rc=0; printf 'not json' | bash "$GUARD" 2>/dev/null || rc=$?
if [ "$rc" -eq 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL malformed input rc=$rc"; fi

printf 'ops guard: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
