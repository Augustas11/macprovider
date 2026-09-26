# Codex audit: M4 step 2, batched cached follow-up turns (SPEC-038 AC-26, `f9a71a3b`)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-cb-sampling`. Branch:
`campaign/1646-cb-sampling`. Review `git show f9a71a3b ff49716e` and the R2 fix in HEAD, in the context of the
already-audited M4 step 1 (`b8486a5c..a39f1b48`: hybrid recurrent checkpoints
and the batched snapshot/materialize path).

## The change
- **The flag.** `continuous_batching_cached_turns` (default false; yaml, env,
  CLI). Off: byte-for-byte today's behaviour. On, with canary/on: a
  positive-cached request whose lease carries a usable retained handoff enters
  the scheduler instead of the AC-26 serial fence.
  - A usable handoff is a retained paged-KV sequence. For a hybrid model it
    must also carry the recurrent checkpoint at exactly `cachedPromptTokens`.
- **Hybrid first turns (flag on).** They retain paged KV (the bridge is now
  created for hybrid) plus checkpoints, instead of the step-1 materialize.
- **`ConversationCache.begin` on a retained hybrid entry.** It picks the
  largest C ≤ lcp and leases the retained sequence with `cachedPromptTokens = C`
  and the checkpoint. If none qualifies, it misses with
  `recurrent_checkpoint_diverged` and discards the retained sequence.
- **Scheduler.** It reattaches the retained sequence trimmed to C. The backend
  install builds recurrent layers as fresh `MambaCache` with state from the
  checkpoint, and fails closed on a missing or wrong checkpoint. Then
  `prefillCursor = C`, and the conversation chains.
- **Specs:** SPEC-038 v0.2.8 and SPEC-024 0.2.6.

## Studio e2e (relay rig)
`docs/runbooks/continuous-batching-m4-hybrid-reuse-evidence-2026-09-24.md`,
"Step 2" section.
- With the flag on, cached follow-ups batch, with 0 forward failures.
- The worst first-token wait for 4 concurrent cached follow-ups drops from
  9.7 s to 4.4 s.
- Hit vs miss output shows tolerance-only divergence.

The AC-26 packaged proof (receipts and settlement) is still required before
the flag goes on on a live provider.

## Gate
0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line, a concrete
failure scenario, and a fix. Do not manufacture findings. End with
`VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.
## Lane: CODE (correctness, concurrency, tests)

Check:
- The reattach trim-to-C and prefill-cursor alignment.
- The MambaCache restore: state layout per layer and dtype.
- Checkpoint chaining across turns.
- Every new await point: is a cancel recorded meanwhile honoured? This is the
  same class as the two step-1 races.
- Retained-sequence ownership and discard on every miss, fail, cancel and
  replay path, including leaks and double discards.
- Flag-off byte-for-byte equivalence.
- Tests that would fail on a real regression.

Round 1 MEDIUMs are addressed in `ff49716e`. Code: recurrent checkpoint layout validation before install. Architecture: per-tuple revision-bound `cached_turns_accepted` grant, required with the flag; SPEC-038 v0.2.9, SPEC-039 v0.1.6 and the runbook aligned. Re-check both fixes and the whole change.

Round 2 code MEDIUM (cancel lost when a retained install fails) is fixed at the root: `finishQueued` now lets any recorded cancel win over a pre-admission failure (`testCancelDuringFailingRetainedInstallReportsCancelled` fails without the fix). This is the third lost-cancel finding across the M4 audits (snapshot await, terminal retain/materialize await, admission failure). Sweep ALL await points in `ContinuousBatchScheduler` that M4 (`3ef0825f..HEAD`) added or changed in one pass, and list any remaining path where a cancel recorded during an await is not honoured. Do not report pre-existing paths M4 did not touch unless M4 made them reachable.
