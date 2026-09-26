# M7 decision: keep continuous batching off (2026-09-26)

## Decision

Keep the production default `continuous_batching: off`. Do not enable `on`,
and do not expand any live canary. This record authorizes no release, provider
restart, configuration change, or other live action.

## Evidence

- M2 passed its remaining receipt/finalization and warm-swap-drain cases on the
  isolated Studio candidate ([M2 evidence](continuous-batching-ac25-m2-leftovers-evidence-2026-09-26.md)).
- M5 passed durable relay replay on the Studio, but only as real-Mac lab
  regression evidence, not packaged or signed enable evidence
  ([M5 evidence](continuous-batching-m5-durable-replay-evidence-2026-09-26.md)).
- The Gate A5 measurement mechanism passed, but **Gate A5 is NOT GREEN**. No
  real predeclared, signed minimum 60-pair OPoI window was collected, and the
  final counter bytes did not achieve independent audit convergence after the
  last remediation ([Gate A5 evidence](continuous-batching-gate-a5-counter-evidence-2026-09-26.md)).
- M6 modeled economics are mixed for the measured exact tuple: material gains
  at 512 tokens, modest gains at 1,536, and essentially flat economics at
  4,096. At batch 8, worst TTFT is about 9.55x-11.85x the matching serial
  control ([M6 economics](continuous-batching-m6-promotion-economics-2026-09-26.md)).

Existing isolated Studio canary tooling remains lab-only, exact-tuple, and
`--no-join`. It is not production authorization; the enable gate requires
packaged evidence for the exact tuple and a separate reviewed decision
([enable gate](continuous-batching-enable-gate.md),
[lab campaign boundary](lab-campaign-loop.md)).

## Reopen conditions

Reopen promotion only after all of the following exist:

1. a complete signed Gate A5 evidence bundle from a real predeclared window;
2. independently reviewed evidence with audit convergence;
3. acceptable economics and tail latency for the exact packaged tuple and
   runtime revision; and
4. a separate reviewed configuration decision.

Until then, production-default `off` and the current live-canary boundary are
unchanged.
