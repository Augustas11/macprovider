# AUDIT — Issue #281 — SECURITY lane

## Goal
Adversarial SECURITY audit on commit `d748326` (branch `fix/iss281-ac18-timing-flake`). Bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW + INFO allowed.

## Scope

- `phase4-coordinator/internal/stats/handlers_integration_test.go::TestAC18_TimingEquivalenceRows5_6_7` (lines 928-1015)
- The handler code paths the test exercises (`/v1/stats/leaderboard` 401 paths for: row 5 = valid-key + non-allowlist Origin, row 6 = no-matching-key, row 7 = revoked-key). You may grep `phase4-coordinator/internal/stats/` for the corresponding auth-failure code paths.

## Threat model

AC-18 pins a **timing-equivalence security property**: an attacker probing `/v1/stats/leaderboard` with various malformed Authorization headers MUST NOT be able to distinguish between the three failure modes (5/6/7) by measuring response latency. If the three paths take wall-clock-distinguishable time, the attacker learns whether a key exists, was revoked, or just has a wrong Origin — a credential-existence oracle.

Pre-#281 the test compared MEDIANS of 100 samples per row, threshold 20% pairwise variance. It flaked at ~30%.

Post-#281 the test compares MINIMUMS of 100 samples, same 20% threshold.

## Lens — SECURITY

- **Is min the right statistic for the security property?**
  - Argument for: min is the floor of handler execution — what the code costs when no ambient noise. Noise can only push timings UP. So if the three mins are within 20%, the underlying handlers are constant-time-equivalent at floor.
  - Argument against: an actual attacker measures with their OWN noise — they don't get to observe min. They observe their own median/mean. A real attacker might see the difference even when our min-based test passes.
  - Which is correct?
- **Does the min weaken the security property the test was originally protecting?** Could a future timing leak — say, an early-return that fires 10% of the time — sneak past a min-based gate while it would have been caught by a median-based gate? Concrete examples welcome.
- **Are the three auth-failure paths actually constant-time in the underlying code?** If you can spot a code-level branch that returns earlier on one of the three paths (e.g. early-return on no-matching-key before bcrypt verify), this PR is band-aiding over a real leak. Look for: bcrypt dummy verifies, constant-time compare usage, early-returns in the auth middleware.
- **Sample-loop ordering**: is there any way for the loop's `time.Sleep(225ms)` between samples to introduce systematic bias between rows 5/6/7 (e.g. cache warming on the first row)?
- **Is 100 samples enough to actually capture the min?** If the handler has a long tail (rare slow path) we'll see a low min and a high max — but the min we observe is just "lucky" — it doesn't represent typical behavior. Is the min meaningful here?

## Out of scope

- Code style (CODE lane)
- Statistic-choice architecture (ARCHITECT lane)

## Output format

```
SEVERITY-N (CRITICAL|HIGH|MEDIUM|LOW|INFO) — <one-line title>
File: <path>:<line>
Finding: <what>
Risk: <why, cite threat model>
Recommendation: <concrete fix>
```

End: `C/H/M/L/INFO = a/b/c/d/e`. If 0 C/H/M: `ACCEPT — 0 C/H/M`.
