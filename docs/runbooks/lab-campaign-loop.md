# Lab campaign loop — Studio / real-hardware e2e

This is the default workflow for any change whose next fact comes from a real
Apple Silicon box (Mac Studio, Mini, or a provider Mac). It exists because the
merge → cut CLI → reinstall → retest loop wastes hours that a local
`swift build -c release` on the box does in minutes.

Canonical short form: `AGENTS.md` (Hardware campaign loop). Cursor
enforcement: `.cursor/rules/lab-campaign-loop.mdc`.

Pearl catalog T0 (#608 → #609) still uses
`.cursor/rules/autonomous-serial-pearl-ship.mdc`. Do not use this runbook as
permission to skip those ordered production mutations.

## Two loops

### Loop A — lab campaign (iterate here)

Goal: one branch that contains every code, harness, and evidence change needed
for that e2e, proven on a locally built CLI before anyone waits on GitHub.

1. One worktree, one branch, one **draft** PR. The campaign is the task.
   Further e2e findings belong on this PR, not a new branch.
2. Sync sources to the Studio (or build there). Install identity is irrelevant.
   ```bash
   ssh macstudio 'cd /Users/a1/<worktree>/phase3-binary && \
     swift build -c release --product macprovider-cli'
   ```
3. Serve on an **isolated loopback** (`127.0.0.1`, a non-8080 port, `--no-join`
   / no Pearl unless the campaign is explicitly a live-canary confirmation).
   Do not touch `live.malibu.provider` / the buyer-serving 8080 process.
4. Run the e2e against that binary. Record sanitized evidence on the same
   branch.
5. If it fails: change code, rebuild locally, re-run. Push commits to the
   draft PR. Do not merge. Do not cut a signed CLI. Do not Pearl-apply.
6. Three-lane `omc ask codex` audits run **once**, on the freeze diff, after
   the lab e2e PASSes. Not per commit. Not on an incomplete slice.
7. Mark the PR ready only when the campaign checklist in the PR body is green.
   CI green is not the merge gate.

### Loop B — production land (once)

Goal: the binary buyers (or a serving canary) will actually run is reviewed
`main`, signed, and confirmed — not rediscovered.

1. Squash-merge the campaign PR (antfleet-ops approve, Augustas11 merge,
   required checks green).
2. Cut **one** signed candidate that includes the whole campaign. Update
   `docs/releases/cli-release-train.md` in that cut, not after every CLI-row
   merge during Loop A.
3. If the gate needs packaged identity (compat-set, Sparkle, launchd install,
   KVS-01a PASS, CB enable-gate): install that candidate on the Studio and run
   the **confirmation** e2e. This is not a new discovery loop. A fail here
   reopens the same campaign PR (or a hotfix on a branch from that tag), it
   does not start a fresh “next slice” from `origin/main`.
4. Pearl coordinator/gateway: one cut of current `main` after the campaign
   lands, if the campaign needs live `api.malibu.tech`. Prefer Loop A against
   a local coordinator/gateway when the bug is CLI-side.
5. Buyer-facing flags (`continuous_batching`, `kv_disk_cache` fleet default,
   sticky, slot raises) stay **off** until a separate operator enable gate.

## When a packaged CLI is required

Packaged / signed identity is required for Loop B confirmation and for any
enable gate that says so (KVS-01a, SPEC-038 canary, Sparkle updater, launchd
install). It is **not** required to learn whether a scheduler change scales,
whether a parser recovers Qwen markup, or whether a disk-tier smoke hits.

| Question | Binary |
|---|---|
| Does this code path work / scale / parse? | Local `swift build -c release` on the Studio, isolated port |
| May we enable / canary / promote? | Signed candidate whose SHA is in the evidence |

A worktree binary is valid lab evidence. It is not an enable path and not a
fleet path.

Off-train lab packages (`acceptance-candidate.yml` on the campaign branch)
are allowed when the confirmation gate needs a signature but `main` must not
move yet. Never promote those tags. Never swap live 8080 with them unless the
operator wrote that this campaign is a live canary.

## Campaign PR body

Open as draft. Title names the campaign, not the first slice
(`feat/spec038-studio-cb-scale`, not `docs/msb-harness-only`). Include:

```text
Campaign: <one sentence>
Lab binary: Studio local release build | off-train package <tag>
Lab target: isolated 127.0.0.1:<port> (live 8080 untouched: yes/no)
E2E command: <exact>
Lab result: PASS / FAIL / in progress
Freeze audit: not started | 0C/0H/0M <date>
Ready to land: no until lab PASS + freeze audit
Buyer flags in this PR: unchanged / listed
```

Ready-for-review means lab PASS + freeze audit. Auto-merge-when-CI-green does
**not** apply to a draft campaign, and does not apply to a ready campaign
whose lab checklist is still red.

## What one campaign may include

Everything needed to close that e2e, even if it touches CLI + coordinator +
gateway + harness + evidence docs. Split only when a change is a different
campaign (unrelated OpenRouter catalog row, billing schema, fleet promote).

Do not stack PRs inside a campaign. Push more commits. Do not hold the
campaign behind an unrelated PR; rebase onto `origin/main` as needed.

## Studio ownership

One live campaign owns the box. Other sessions may use a different isolated
port only when they will not SIGKILL, reinstall, or steal the live 8080
lease. Check `live.malibu.provider` and the other session’s draft PR before
any `kill`.

## Forbidden (the wait loop)

- Identify next slice → PR → audit → merge → wait CI → cut CLI → install →
  e2e → new branch → new PR.
- Fresh worktree from `origin/main` after every Studio finding.
- Cutting a signed CLI because a CLI-row PR merged.
- Applying the Pearl serial-ship rule to hardware campaigns.
- Swapping `live.malibu.provider` with a worktree binary.
- Flipping buyer canary flags from a lab PASS.
- Claiming an enable gate green on an unpackaged binary.

## Still serial on purpose

- Pearl catalog T0 (#608 Llama → ledger → promote → dual-file → #609).
- Money-path billing, auth, receipts, buyer-exposed trust-tier labels.
- Fleet CLI promotion (`binaryVersion`, `latest_binary_version`, autoupdate).
- Buyer canary / slot raises.
- Red `spec-index` / `check`.
- Admin-merge / review bypass.
