# Cursor Automation prompt: upstream throughput watch

Paste-ready instructions for the scheduled Cursor automation that polls upstream mlx-swift-lm/mlx-swift
blockers for the throughput engineering plan. This automation is **issue-first**: it must never open
an implementation or draft dependency-bump PR, but a reviewed feature-branch PR is required to
persist an updated watcher snapshot.

## Prompt

```
Read: docs/runbooks/PLAN_THROUGHPUT_ENGINEERING_RUNBOOK.md § Upstream watch
Rules: CLAUDE.md worktree isolation.

1. First run `python3 scripts/read_swiftpm_pins.py phase3-binary/Package.resolved`, then run
   `bash scripts/check-upstream-throughput-blockers.sh --json` from repo root and capture the
   snapshot. Also run it without --json to get the plain exit code. `Package.resolved` stores
   versions at `pins[].state.version`; any missing/empty required pin is a checker failure. The
   resolved graph is authoritative over this prompt, benchmark notes, metallib metadata, and
   `UPSTREAM_WATCH.json`.
2. Classify the exit code:
   - exit 0: no material change. Update
     `beta/throughput-engineering/UPSTREAM_WATCH.json` (`last_checked_at` only) if the checker
     writes it; otherwise stop, no further action.
   - exit 1: checker error (network/API failure, bad credentials, etc). Do NOT open or update any
     issue. Report the error and stop.
   - exit 2: material change detected (resolved pin/source/revision drift, issue/PR closed or
     merged, new release tag above the current pin, or the KVCache compile-fix heuristic flipped).
     Continue to step 3.
3. On exit 2, determine which blocker(s) changed by diffing the new snapshot against
   `beta/throughput-engineering/UPSTREAM_WATCH.json` (`macprovider_pins`, `blockers.*.state`,
   `releases.*.tag`, `implementation_signals.*`). Pin/source/revision drift is owned by #700.
4. For each changed blocker, search for its sticky tracking issue BEFORE creating anything:
   `gh issue list --repo Augustas11/macprovider --state all --search "<sticky title text>"`
   - The mlx-swift-lm #364 (Gemma MoE) blocker's sticky issue is #700
     ("Awaiting mlx-swift-lm release containing #364 (Gemma MoE) — then T1-01 + T1-02").
   - The mlx-swift-lm #406 (KVCache compile) blocker's sticky issue is #964.
   - The quantized reusable-KV ownership tracker is #965; watch upstream #312 and merged PR #453.
   - The speculative cache-wrap tracker is #377; watch upstream #424.
   - The independent swift-transformers migration tracker is #966.
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
     A tag is not `release_ready` while upstream package-consumption issue #518 blocks normal
     remote SwiftPM use, or while the protected Xcode 16.4 / Swift 6.1 toolchain cannot resolve it.
   - Refresh `macprovider_pins` only from the checker's authoritative `Package.resolved` snapshot;
     never edit those values manually. Do NOT touch `Package.swift` or perform a pin bump here —
     dependency changes are a separate human-reviewed T1-01 task.
   - Preserve `watchlist.omlx` and all other fields untouched unless the checker snapshot itself
     changed them.
6. Commit the JSON snapshot update (and runbook table cell if the row's status label changed)
   on an isolated feature branch and open a normal PR through the standard workflow. Never commit
   directly to `main`, including for docs-only watcher changes.
7. Do not open a PR during steps 2-5. The only artifacts produced before step 6 are GitHub issue
   creates/comments/edits; step 6 adds the feature-branch commit and PR.
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
- Before calling an engine release actionable, run the package/toolchain preflight in
  `docs/runbooks/MLX_ENGINE_UPGRADE_MATRIX.md`. Never auto-bump to upstream `main`.
