# AUDIT PROMPT — Issue #585 v1.8.40 diff — ARCHITECT lane (R1)

You are an independent architecture auditor. Audit the complete diff for
v1.8.40 in THIS worktree:

```
git -C /Users/augstar/macprovider-malibu-bootstrap-bridge diff 71eb927a..HEAD
```

Base `71eb927a` is origin/main (= immutable v1.8.39 source).

## Context

- Issue #585 selected Option 2: launchd+CLI own the provider process,
  credentials, identity, update transactions, and lifecycle state; Malibu is a
  read-only projection client.
- Release history: v1.8.32–v1.8.39 were eight consecutive physically-failed
  rollouts; v1.8.39's candidate died on a missing lifecycle edge and its
  rollback stranded a lifecycle file that the restored legacy CLI cannot
  clear. This diff is the v1.8.40 correction plus transaction-boundary
  widening.
- Normative decisions: `beta/DECISION_CRITERIA.md` entries 152–161 (159–161
  are new in this diff — audit them as part of it).
- Rollout plan (Entry 161): operator-assisted; in-place upgrade on the
  reachable provider; wipe + fresh-onboard of the second Mac as the
  clean-onboarding acceptance host. No zero-touch path exists by construction.

## Audit scope (rate every finding CRITICAL / HIGH / MEDIUM / LOW)

1. **Transaction boundary completeness**: with the lifecycle file as the tenth
   member, is the installer transaction now closed over ALL state observable
   by Malibu and the coordinator? Enumerate any remaining files/registrations
   mutated during install but not snapshotted (e.g. lease.json and its lock
   files in the same lifecycle directory, model inventory markers, watchdog
   state) and rate the consequence of each omission.
2. **Ownership/writer contracts**: the restore-as-last-swap design means the
   installer briefly authors lifecycle history that then vanishes on rollback
   (restored contents overwrite the transactional tail). Is that consistent
   with the lifecycle contract's sequence/fencing semantics when a NEWER CLI
   is later restored (not just the pre-contract v1.8.30)? Could a restored
   stale-but-valid state confuse a subsequent serve startup or updater
   operation fence?
3. **Entry coherence**: do entries 159–161 contradict or silently weaken
   entries 152–158 (esp. 155/156 bridge freeze, 158 deletion prohibition and
   Sparkle-free requirement)? Is the Entry 160 re-arm reasoning sound as a
   standing per-release rule, or does it need a tighter trigger?
4. **Candidate/incumbent shared-file design**: the autotune candidate writes
   the SAME lifecycle file the incumbent's observers project (verified
   empirically on this Mac: a test candidate left
   `degraded_serving/local_http_ready_join_disabled` behind while the healthy
   incumbent served). The file carries `writer`/`operation_id` fields that
   projections could use to disambiguate. Rate this as a design risk for the
   upgrade UX and for Issue #585's "Malibu shows accurate state" acceptance —
   is it acceptable-with-documentation for v1.8.40, or blocking?
5. **Validation-order fitness**: given the eight release failures, does this
   diff plus its test evidence (real-model integration test passed; four-case
   installer rollback regression matrix; 171 app tests) close the gap between
   "component-tested" and "physically provable" for the transitions it
   touches? Name any acceptance claim in Issue #585 that this diff implies but
   does not evidence.

Attribute every finding as NEW-to-this-diff vs PRE-EXISTING on the v1.8.39
baseline; pre-existing-not-worsened issues are reported but not blocking.

## Output format

Markdown. For each finding: severity, area, reasoning, suggested direction.
End with a summary table and an explicit verdict line:
`VERDICT: X CRITICAL / Y HIGH / Z MEDIUM / W LOW`.
