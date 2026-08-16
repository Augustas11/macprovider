# SPEC-017 SnapshotProvider wiring — SECURITY-lane audit (R1)

You are the **security** lane of a three-lane audit (code / security
/ architect) of the pool.Registry → stats/rollup SnapshotProvider
wiring. Stay narrowly in your lane — code correctness questions go
to the code lane; API-shape questions go to architect.

## Branch / commit
- Branch: `feat/stats-snapshot-provider`
- Worktree root: `/Users/augstar/macprovider-stats-snapshot`
- Base: `origin/main` @ `66f372e`
- Files in scope:
  - `phase4-coordinator/internal/stats/poolsnapshot/poolsnapshot.go` (NEW)
  - `phase4-coordinator/internal/stats/poolsnapshot/poolsnapshot_test.go` (NEW)
  - `phase4-coordinator/cmd/coordinator/main.go` (single wiring edit)

## What this change does (operator summary — NOT the audit answer)

Before this PR, `/v1/stats/overview` returned zero for every
§5.1.1 live-snapshot field. The endpoint is documented as public
(`stats.malibu.tech/v1/stats/overview`, 30s CDN cache, 60 rpm/IP,
CORS on, no auth). This PR wires 5 fields (nodes_online,
nodes_hardware_attested, unified_ram_gb_total, models_serving,
network_utilization_pct) to be aggregated from
`pool.Registry.Snapshot()`; the other 4 fields (bandwidth, power,
cores) still zero.

## Security-lane scope (apply each; stay in lane)

### SEC-1. Information disclosure via aggregation

The endpoint is PUBLIC. Now instead of returning zero, it will
return aggregate counts. Consider what an unauthenticated observer
can newly learn:

- **NodesOnline** — pool size. Was previously private (only
  operator via `/poolz` had it). Now anyone can poll every 30s
  and see the fleet size, plus arrival/departure deltas. Is that
  intentional per SPEC-017? Re-read SPEC-017 §5.1 to confirm the
  intent was to publish this, not just to name the field. If
  SPEC-017 intended NodesOnline as an aggregate marketing stat,
  fine — but confirm.
- **NodesHardwareAttested** — sub-count. An adversary can infer
  what fraction of the fleet passes attestation. Signal: if
  attested drops materially (e.g. from 90% to 30%), an attacker
  learns that attestation infrastructure has degraded — a
  targeting signal against non-attested providers if such a
  targeting vector exists.
- **UnifiedRAMGBTotal** — sum. Combined with NodesOnline gives an
  average RAM-per-node. Combined with ModelsServing gives a
  capacity-per-model heuristic. Whether this crosses a leak
  threshold depends on threat model; note it, don't overreach.
- **ModelsServing** — distinct model count. A model catalog
  observer can already enumerate models via `/v1/models` on the
  gateway. Confirm this doesn't add new info; if it does, note.
- **NetworkUtilizationPct** — a competitor / DoS attacker learns
  network load in near-real-time. 30s cache limits the sampling
  rate. Consider: at 100% utilization, is the endpoint's own
  value a DoS-amplification signal ("attack when they're busy")?

The question in every bullet is: does this change the disclosure
posture beyond what SPEC-017 already accepted, given the endpoint
was already documented public with these fields defined? If
SPEC-017 §5.1 explicitly lists them as public wire-format fields,
the disclosure is authorized by the spec and the R1 finding is
"no new leak, spec-authorized". If SPEC-017 defines the fields but
never assessed leakage vs a live source, that's the audit finding.

### SEC-2. Snapshot semantics leaking non-routable providers

`onlineForStats` deliberately EXCLUDES:
- `AuthState == AuthBearerlessDuplicate` (a shadow-registered
  attacker session)
- `len(PendingReceiptPubkey) > 0` (mid-key-rotation)

That's the right posture for a public stat — otherwise an attacker
could inflate `NodesOnline` by connecting bearer-less duplicates.
Confirm no path where a bearerless-duplicate can escape this
filter, e.g. a race where the field is not yet populated when
`Snapshot()` is called.

Look at `pool.Provider.AuthState` semantics: is it ever LATER
promoted (e.g. self-mint success re-writes it from empty →
AuthSelfMinted) such that a snapshot mid-transition could be
inconsistent? Trace the transition atomicity.

### SEC-3. Attestation status disclosure

`NodesHardwareAttested` is derived from
`AttestationStatus == AttestationStatusAttested`. The other statuses
(`Failed`, `Stale`, `Unsupported`, `NotRequired`, empty) are all
counted as "not attested". A provider that has never attested and
one that FAILED attestation are indistinguishable in the aggregate.
Is that the right posture, or should we surface a "failed"
sub-count separately (which would be a bigger disclosure)? Argue
the tradeoff.

### SEC-4. No secret / key material in derived path

Grep the adapter for any handling of receipt pubkeys, tokens,
signing material, session IDs, or hostnames. The only field
touched from a security-sensitive struct is `PendingReceiptPubkey`
(as a length check, `len(prov.PendingReceiptPubkey) > 0`). Confirm
the length check is a valid Provider-visible predicate (i.e. the
adapter never reads the pubkey bytes themselves).

### SEC-5. Rate-limit + auth posture unchanged

The adapter runs INSIDE the rollup goroutine, not on the HTTP
path. The public HTTP path
(`/v1/stats/overview` handler) already has: 60 rpm/IP rate limit,
30s CDN cache, CORS, no auth. The adapter change does not modify
any of these. Confirm.

### SEC-6. DoS via snapshot cost

`Registry.Snapshot()` allocates `[]Provider` = full map copy under
`RLock`. If an attacker can drive registry churn (many
connect/disconnect cycles), can they amplify rollup CPU cost via
this new adapter?
- The rollup runs at a FIXED interval, not per-request. Adversary
  can't trigger extra ticks.
- Registry churn is bounded by admission gates (bearer token /
  self-mint rate limiting) — see `SPEC-003 v0.8.x` gates and
  `[[macprovider-deepsec-coordinator-spam]]`.
- Snapshot cost per tick is O(N_providers), well within budget at
  realistic N.
Confirm no new amplification vector.

### SEC-7. Timestamp trust

`OverviewSnapshot.At` is set from `p.now()` = `time.Now().UTC()`.
This flows into `stats_overview_current.generated_at`. The rollup
tick may later override with its own tick time (see
`rollup/overview.go`); confirm no clock-skew between adapter and
tick that could confuse an operator (this is code-lane-adjacent
but security-relevant if `generated_at` is used to validate
freshness on the wire).

### SEC-8. Downstream impact on ETag / caching

Handlers set an ETag on the response. If the new dynamic values
(previously zero, now varying) cause ETags to churn per tick
even when values didn't change (map iteration order in the
adapter is NOT deterministic — but distinct `ModelID` set is
counted, not iterated for output, so order shouldn't matter),
confirm the response payload doesn't accidentally leak
non-determinism that would break 304-Not-Modified caching.
Specifically: does `ModelsServing` (int) or any other returned
field depend on iteration order? It should not — all outputs
are counts or sums, order-invariant. Confirm.

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Attack:  <one-sentence adversary scenario>
      Fix:     <one-sentence fix>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write to
`specs/STATS_SNAPSHOT_PROVIDER_R1_SECURITY_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: security lane READY TO MERGE`
