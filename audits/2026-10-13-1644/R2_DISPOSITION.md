# Round 2 disposition (#1644 cross-provider scoring)

Round 2 verdicts: code H1 M3 L1; security M1; architecture H3 M7 L2.
Round 1 fixes were confirmed complete by the security lane.

| Finding | Lane | Disposition |
| --- | --- | --- |
| Empty phrasing style lets a corpus entry go out verbatim | code H | Fixed: every request appends a non-empty phrasing instruction; the corpus test asserts no request equals a corpus entry. |
| Relay-blind/privacy binding uses ServingCapable | code M, arch H | Fixed in `relayBlindBindable` and both capability counts (ServingCapable stays untouched: SPEC-032-R001 conformant fragment). Test: `TestRelayBlindBindableExcludesComputeIntegritySuspended`. `buyer_serving` on pool-check is a session-liveness signal and stays unchanged on purpose: false makes the CLI reconnect in a loop, and a suspended provider must stay connected to recover; documented in FR-25. |
| Operator clear not restored on commit failure | code M, arch M | Fixed: state is cloned and restored. Test: `TestComputeScoringOperatorClearFailureRestoresState`. |
| First request not jittered | code M | Fixed: the first request uses the same [0.5, 1.5) jitter. Test: `TestComputeScoringFirstRequestUsesJitteredCadence`. |
| Known-sequence cadence counts unsent jobs | code L, arch L | Fixed: counted only after a successful send. |
| Known-sequence checks not independent | security M, arch H | Fixed: each sequence records its source provider/operator and both scorer operators; a checker must be independent of all of them and carry an operator key. Unit test covers source, sibling, original scorer and operator cases. |
| FR-17 vs §5A money-path contradiction | arch H | Resolved in SPEC: FR-17 governs the overt profile and reference work; an FR-20 verification request is an ordinary paid SPEC-022 attempt with no buyer debit (new SPEC-022 R-16.9), as the campaign brief requires ("settled normally for the provider"). The scoring job itself is unpaid. |
| Scope still says covert probes are out of scope | arch M | Fixed in §2: FR-1..FR-18 stay overt; §5A adds the covert path. |
| Non-transition persistence failure advances memory | arch M | Fixed: a failed state write drops the measurement and restores memory; the honest-pair window accepts a measurement only after it commits. |
| Scorer selection weighted by Mac count | arch M | Fixed: operators drawn uniformly, then one provider each. Test: `TestSelectScorersIsOperatorWeighted`. |
| Sweep and ownership-lookup cost | arch M | Reduced: operator keys resolve only for pools with a provider due; the per-sweep index is O(providers) with no DB work. |
| Per-credit rollup writes on hold | arch M | Fixed: holds bump each distinct (provider, hour) bucket once (`SELECT DISTINCT`); covered by the rollup equivalence test. |
| Unbounded scoring memory | arch M | Fixed: tolerance windows and known sequences of a (model, manifest) unseen for 7 days are dropped; in-memory unverified/passing states of providers absent 7 days are dropped (durable rows stay); adverse states are never pruned. Documented in FR-25. |
| No hardware cross-chip evidence | arch L | Carried: CONFORMANCE stays pending; the provider scorer needs Studio validation (PR "Before merge"). |
