# Handoff: #1646 remaining campaign (branch `campaign/1646-remaining`)

You are continuing the #1646 continuous-batching campaign. Before starting, read:
- AGENTS.md;
- the #1646 comment of 2026-09-25 that lists the remaining milestones;
- this file.

## State (2026-09-26)
- **Worktree:** `/Users/augstar/macprovider-1646-rest`, branch `campaign/1646-remaining`, pushed to origin. There is no PR: the campaign rule is one draft PR at freeze, then merge once, then one signed CLI cut.
- **Done on the branch:**
  - Tool-bearing and structured-output rows batch (SPEC-038 v0.2.11 AC-6c): commits `dd5a7d88`..`23429b7d`. Audit trail and results: `audits/2026-09-25-cb-tools-structured/README.md`.
  - M3, the FR-PKV13 overhead ceiling: PASS. See `docs/runbooks/continuous-batching-m3-overhead-ceiling-2026-09-25.md`.
- **Live Studio** (`ssh macstudio`, provider `mp-5aad…`): runs signed CLI candidate v1.8.195. **Pearl** runs v1.8.200 with catalog `published-2026-09-25-artifact-hash-correction-v1`. The operator canary Mac (this Mac, `mp-26592d…`) also runs 195.

## Remaining milestones, in order
1. **M2 leftovers:** AC-25 case 6 (receipt half) and case 10 (warm-swap drain), on the Studio as a catalog-trusted joined provider.
2. **M5:** durable replay through relay identity. A reconnect after a terminal result must carry the correct settlement disposition.
3. **Gate A5**, before `continuous_batching: on` can be used. Carried from the #1716 audit.
4. **M6:** promotion economics, on the re-measured batched numbers.
5. **M7:** a recorded, reviewed decision: keep off, or a narrow canary per exact tuple.

Freeze afterwards: one draft PR, CI green, `antfleet-ops` review, merge once, one signed CLI cut, then the Studio swap.

## Working rules (from the operator; they override defaults)
- **Implementation goes to Codex**, not Claude subagents:
  `codex exec -m gpt-5.6-sol -c model_reasoning_effort=medium -C <worktree> -s workspace-write --skip-git-repo-check "<brief>" < /dev/null`
  - Always pass `< /dev/null`, or it hangs on stdin.
  - Inspect Codex's diff yourself.
  - Run the full Swift suite yourself, **outside** the sandbox: `cd phase3-binary && perl -e 'alarm 5400; exec @ARGV' swift test --skip testWaitForReadyDeadlineCancelsDrippingSpoofResponse`. Codex's sandbox run shows false failures.
  - Restore `phase3-binary/Package.resolved` before every commit. Never `git add -A`.
- **Audits:**
  - Three Codex lanes (code, security, architecture) through `omc ask codex -p "$(cat prompt)" < /dev/null`, with prompt files under `audits/<date>-<topic>/`.
  - Run until 0 CRITICAL/HIGH/MEDIUM, **3 rounds at most**, then e2e testing to find bugs. Don't re-fire a lane that passed.
- **Studio e2e:** build on the box from the branch:
  1. `rsync phase3-binary/Sources` to `/Users/a1/macprovider-cb-sampling/phase3-binary/Sources`.
  2. `swift build -c release`.
  3. Copy the binary into `/Users/a1/lab-cb-sampling/bin-tools/`.
  4. Run an isolated serve on :18080 with `--no-join`.
- **Lab benchmarks:** always pause live through `/Users/a1/lab-cb-sampling/bench.sh <script>`. It pauses, then resumes, and restarts the provider automatically when the resume stalls (bug #1755).
  - Keep each pause to 20 minutes or less.
  - Confirm `macprovider-cli status` says "Provider is ready" afterwards.
  - Copies of the lab scripts are in `scripts/lab/cb-studio/`.
- **Never** stop, restart or change config on the live provider or on Pearl without explicit OK, except the benchmark pause/resume above.
- Don't file GitHub issues from audit findings unless asked. Don't present option menus; pick one path and do it.

## Open follow-ups (not in this campaign)
- #1755: the provider stays coordinator-unavailable after pause and resume.
- #1751: coordinator startup rescans billing tables.
- #1752: held settlement reservations.
- #1735: per-row catalog evidence, including GLM prepare/verify plus a strict-pin buyer request and its settlement row.
- Pearl updater: no snapshot retention, and about 6 minutes of coordinator downtime per apply (coordinator release train, "Open Pearl actions").
- Unverified: plain gpt-oss (Harmony) batched streaming may leak analysis-channel text. Check it before any gpt-oss CB enablement.
