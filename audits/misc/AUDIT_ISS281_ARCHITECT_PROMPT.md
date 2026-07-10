# AUDIT — Issue #281 — ARCHITECT lane

## Goal
ARCHITECT / statistical-soundness audit on commit `d748326` (branch `fix/iss281-ac18-timing-flake`). Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW + INFO allowed.

## Scope

- `phase4-coordinator/internal/stats/handlers_integration_test.go::TestAC18_TimingEquivalenceRows5_6_7`
- The Round-6 BUILD prompt referenced in the comment ("Round-6 BUILD ask: 100+ samples per row, sustained rate ≤270 rpm") — find it if it's in `specs/` and read it for context.

## Background

The pre-#281 estimator was median-of-100. It flaked at ~30% variance on shared CI runners. The post-#281 estimator is min-of-100, same 20% threshold.

The original BUILD prompt that landed AC-18 named "100+ samples" but did NOT specify median vs min as the estimator — the choice of median was an implementation detail of the test author.

## Lens — ARCHITECT

- **Statistical soundness**: is min-of-100 a defensible choice for the "constant-time floor" property the test is trying to assert? Or is there a better statistic — e.g. trimmed mean (drop top 20% as noise), Hodges-Lehmann, or the 10th percentile?
- **Order statistic stability**: min has VERY high variance as an order statistic (theoretically, var(min) ≈ var(X) for n=1; doesn't shrink as you add samples). The reason it "works" here is that the underlying distribution has a sharp lower bound at the handler's actual execution time. Is that lower-bound stability reliable across CI runner shapes? On a runner where the handler floor itself drifts (e.g. shared host with another tenant using CPU), min could fluctuate too.
- **Pre-test sleep / warm-up**: the loop does `time.Sleep(225ms)` BETWEEN samples but not BEFORE the first sample of each row. Should there be a warm-up phase that captures and discards the first N samples? This matters more for min (which is sensitive to cold-start) than median.
- **Threshold choice**: 20% on min vs 20% on median — is that the right invariant? The min should be MORE stable than the median, so the same threshold is conservative. Could it be tightened to 10% to catch more real leaks?
- **Test runtime**: 3 rows × 100 samples × 225ms ≈ 67.5 seconds per test. Is this in the right ballpark for CI?
- **Cross-spec alignment**: does any SPEC document name "AC-18" with a normative reference to "median" as the estimator? If so, this PR needs to update the SPEC too.

## Out of scope

- Code style (CODE lane)
- Specific bypass / injection (SECURITY lane)

## Output format

```
SEVERITY-N (CRITICAL|HIGH|MEDIUM|LOW|INFO) — <one-line title>
File: <path>:<line>
Finding: <what>
Risk / Concern: <why, architectural>
Recommendation: <concrete change or defer-to-follow-up>
```

End: `C/H/M/L/INFO = a/b/c/d/e`. If 0 C/H/M: `ACCEPT — 0 C/H/M`.
