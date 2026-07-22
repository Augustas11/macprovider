# Cursor Automation prompt: upstream throughput watch

Paste-ready instructions for the scheduled Cursor automation that polls upstream mlx-swift-lm/mlx-swift
blockers for the throughput engineering plan. This automation is **issue-only**: it must never open a
draft pull request.

## Prompt

```
Read: docs/runbooks/PLAN_THROUGHPUT_ENGINEERING_RUNBOOK.md § Upstream watch
Rules: CLAUDE.md worktree isolation.

1. Run `bash scripts/check-upstream-throughput-blockers.sh --json` from repo root and capture the
   snapshot. Also run it without --json to get the plain exit code.
2. Classify the exit code:
   - exit 0: no material change. Update
     `beta/throughput-engineering/UPSTREAM_WATCH.json` (`last_checked_at` only) if the checker
     writes it; otherwise stop, no further action.
   - exit 1: checker error (network/API failure, bad credentials, etc). Do NOT open or update any
     issue. Report the error and stop.
   - exit 2: material change detected (issue/PR closed or merged, new release tag above the
     current pin, or the KVCache compile-fix heuristic flipped). Continue to step 3.
3. On exit 2, determine which blocker(s) changed by diffing the new snapshot against
   `beta/throughput-engineering/UPSTREAM_WATCH.json` (`blockers.*.state`, `releases.*.tag`,
   `implementation_signals.*`).
4. For each changed blocker, search for its sticky tracking issue BEFORE creating anything:
   `gh issue list --repo Augustas11/macprovider --state all --search "<sticky title text>"`
   - The mlx-swift-lm #364 (Gemma MoE) blocker's sticky issue is #700
     ("Awaiting mlx-swift-lm release containing #364 (Gemma MoE) — then T1-01 + T1-02").
   - The mlx-swift-lm #406 (KVCache compile) blocker should follow the same pattern once it has
     a sticky issue; create one with an analogous title/body shape if none exists yet.
   - If a matching open issue exists: `gh issue comment <number> --repo Augustas11/macprovider`
     with the new snapshot (state, merged_at/closed_at, status, timestamps) and update checkboxes
     by editing the issue body if needed (`gh issue edit <number> --body-file ...`).
   - If no matching issue exists: `gh issue create --repo Augustas11/macprovider` with a body
     following the Status / Pins / When a release tag lands / Do not / Automation contract / Refs
     shape used in issue #700.
5. Update `beta/throughput-engineering/UPSTREAM_WATCH.json` to reflect the new snapshot:
   - Bump `last_checked_at` and, only if something actually changed, `last_changed_at`.
   - Update the specific blocker's `state`, `updated_at`, and add `merged_at`/`closed_at` as
     appropriate.
   - Set blocker `status` to `awaiting_release_tag` when merged/closed but not yet in a tagged
     release ahead of the current pin, or `release_ready` once a qualifying release tag exists.
   - Do NOT touch `macprovider_pins` or `Package.swift` here — pin bumps are a separate,
     human/task-reviewed step (T1-01), gated on `status: release_ready`, never done automatically
     from this watch job.
   - Preserve `watchlist.omlx` and all other fields untouched unless the checker snapshot itself
     changed them.
6. Commit the JSON snapshot update (and runbook table cell if the row's status label changed)
   directly to `main` if this is a docs-only, non-code change (per repo docs-only-to-main policy);
   otherwise open a normal feature-branch PR through the standard PR workflow.
7. Never run `gh pr create` as part of steps 2-5. The only artifacts this automation produces are:
   GitHub issue creates/comments/edits, and the JSON snapshot commit in step 6.
8. Report: which blockers changed, which issue(s) were created/updated (with URLs), and the new
   `status` value(s) written to UPSTREAM_WATCH.json.

Deliver: issue URL(s) + updated JSON diff. Do NOT update the runbook plan structure unless asked —
only the Upstream watch table cell / status wording tied to a blocker's state.
```

## Notes for the operator

- This prompt assumes `scripts/check-upstream-throughput-blockers.sh` exit codes are: `0` = no
  change, `1` = checker error, `2` = material change. Re-verify against the script if it is
  modified.
- "Sticky title" means: search by the exact issue title text (or a stable substring of it) so the
  automation reliably finds the same issue across runs instead of creating duplicates.
- `awaiting_release_tag` vs `release_ready` is the key state machine for T1-01/T1-02: a merged PR
  is not enough to bump the pin — only a tagged mlx-swift-lm release whose changelog/commit range
  includes the PR clears it to `release_ready`.
