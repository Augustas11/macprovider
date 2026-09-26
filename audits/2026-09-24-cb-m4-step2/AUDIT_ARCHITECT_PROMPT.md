# Codex audit: M4 step 2, batched cached follow-up turns (SPEC-038 AC-26, `f9a71a3b`)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-cb-sampling`. Branch:
`campaign/1646-cb-sampling`. Review `git show f9a71a3b`, in the context of the
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
## Lane: ARCHITECTURE (spec conformance, rollout)

Check:
- SPEC-038 v0.2.8 and SPEC-024 0.2.6 against the code; CONFORMANCE and the
  spec index.
- The flag's default-off safety and its interaction with the step-1
  materialize fallback.
- The AC-26 proof requirement stated in the spec and the runbook.
- Whether the design stays inside SPEC-038 scheduler ownership and SPEC-039
  FR-PKV10 retain/reattach semantics.
- Rollout guidance for enabling the flag on a live provider.
