# SPEC-020 v0.1.3 → v0.1.4 — r4 absorption prompt

Absorb r4 findings into `specs/SPEC-020-provider-autoupdate.md`. Bump
**v0.1.3 → v0.1.4**. Add changelog entry.

**Bar:** r5 audit must return `READY TO LOCK` across all three lanes.

Read `specs/SPEC-020-r4-audit.md` for full per-finding text. r4 returned
0C + 0H + 2M total. Lane A and Lane C are already at READY TO LOCK.
Only Lane B has findings.

## Findings to absorb

### B-r4-M-1 — Success-state cleanup ordered sequence + crash recovery + AC

Replace the current "atomically" cleanup language in R-4.10 with the
ordered sequence below. Insert it as a new subsection
**"Success-state cleanup sequence and crash recovery"**:

> **Success-state cleanup sequence.** When the post-start observation
> succeeds (new binary passes local health AND rejoins coordinator with
> `binary_version == NORMALIZED_TARGET` within the post-start window),
> the observer MUST execute the following ordered sequence. Each step
> MUST complete (or its absence MUST be safely recoverable) before
> proceeding to the next:
>
> 1. **Write success sentinel.** Atomically create
>    `<binary-dir>/.macprovider-cli.success-<update_id>` with
>    `O_CREAT|O_EXCL|O_NOFOLLOW`, mode 0600, containing the JSON
>    `{"update_id":"<uuid>","binary_version":"<NORMALIZED_TARGET>","success_at":"<RFC3339>"}`.
>    `fsync()` the file and parent directory, then atomic rename to
>    final name.
> 2. **Unlink `pending.json`** via `unlink()`.
> 3. **Delete rollback backup** at
>    `<binary-dir>/.macprovider-cli.rollback-<update_id>` via `unlink()`.
> 4. **Release `update.lock`** by closing the flock fd and unlinking
>    the lockfile.
> 5. **Emit `outcome:"success"` event** with `phase:"post_start"`.
>
> **Crash recovery semantics.** On every provider startup (before
> coordinator handshake), the observer MUST scan for a success
> sentinel:
> - If `<binary-dir>/.macprovider-cli.success-<update_id>` exists AND
>   its embedded `binary_version` matches the current
>   `CoordinatorClient.binaryVersion`: this is a delayed success cleanup
>   path. The observer MUST unlink any matching `pending.json` (without
>   triggering orphan recovery), delete any matching rollback backup,
>   release any held `update.lock`, then delete the success sentinel.
>   Treat as `outcome:"success"`, NOT as orphan recovery.
> - If a success sentinel exists but its `binary_version` does NOT
>   match the current binary: emit
>   `failure_class:"orphaned_success_sentinel"`, delete the sentinel,
>   continue.
> - If `pending.json` is absent BUT a rollback backup exists with a
>   stale `update_id` (no matching pending marker), delete the backup
>   without attempting restore.

Update R-6.5 `failure_class` enum to include `orphaned_success_sentinel`.

Add new AC:

> **AC-V0.1-N: success-state cleanup.** Post-start success completes
> the ordered cleanup sequence. Subsequent provider startup finds no
> orphan state, emits no rollback events, and reports
> `outcome:"success"` (or `outcome:"noop"` if cleanup completed during
> the prior session). Crash between any pair of steps 1–5 is
> recoverable on next startup without rollback of the successful
> update.

### B-r4-M-2 — `marker_deadline` citation fix + future-beyond-tolerance retry state

Two edits:

1. **Citation fix.** Locate the `marker_deadline` "missing or malformed"
   and "expired" branches that cite "(R-4.8)". Replace with the correct
   citation to **R-4.10** (the orphaned-marker recovery state machine).

2. **"Future beyond tolerance" retry state.** Locate the bullet "Future
   beyond tolerance (marker_deadline > now + post_start_window + 30 min)".
   Replace with:

   > **Future beyond tolerance** (marker_deadline > now + post_start_window + 30 min):
   > treat as evidence of clock manipulation or a malformed writer.
   > Trigger orphan-marker recovery per R-4.10. After recovery completes,
   > the provider MUST:
   > - Record a cooldown entry keyed by `(NORMALIZED_TARGET, "orphaned_pending_marker")`
   >   with the standard backoff formula (300s × 2^(attempt-1), max 3600s).
   > - Disable autoupdate for the remainder of the current coordinator
   >   session. Re-evaluation occurs only on the next coordinator session
   >   start AND after the cooldown clears.
   > - Emit `failure_class:"orphaned_pending_marker"` with structured
   >   reason `marker_deadline_future_beyond_tolerance` for forensic
   >   correlation.

## Process

1. Read `specs/SPEC-020-provider-autoupdate.md` v0.1.3 and
   `specs/SPEC-020-r4-audit.md`.
2. Apply both edits exactly as specified.
3. Bump version `v0.1.3` → `v0.1.4`.
4. Add changelog entry citing B-r4-M-1 + B-r4-M-2 absorbed.
5. Verify the new failure_class `orphaned_success_sentinel` is in R-6.5
   enum.
6. Verify the new AC is added (AC count should go from 22 to 23).
7. Output: single edited `specs/SPEC-020-provider-autoupdate.md`. No
   other file edits.

You are absorbing — not re-auditing. Goal: r5 = READY TO LOCK on all
three lanes.
