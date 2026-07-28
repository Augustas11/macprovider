# B3 — Rank routing on observed throughput

**Type**: deferred design brief — a FUTURE separate SPEC with its own three-lane audit loop. Analysis, not a commitment.

**Gated on**: G0 (volume) + B1 (data).

## Problem
The routing objective ranks on a provider-authored number (roadmap §4.12, F12).

## Shape the SPEC must take
Replace self-reported throughput with B1's observed aggregate — in **both**
self-report code paths: `EffectiveThroughput` in the "fast" objective
(`routing/objective.go`, `candidate.go:80`) **and** `BalancedScores` in the
"balanced" objective, which reads `p.ThroughputTPSEstimate` directly at a 0.4
weight (`routing/class.go:46`). Below the sample threshold use a conservative
constant or randomized placement — **never** the claimed number, which preserves
the cold-start attack for the new/rotated providers that warrant caution. Rank
on combined TTFT+decode, not decode alone (decode rate is inflatable by
buffering-then-flushing). Also absorbs the runtime workload-bucketing classifier
(was R1b), which is new work borrowing SPEC-029 vocabulary — SPEC-029 explicitly
excludes runtime classification.
