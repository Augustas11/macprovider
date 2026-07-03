---
role: security-audit
version: 1.0
date: 2026-07-03
target_pr: v1.7.8 fix TPS measurement (Track A4)
lens: SECURITY
audit_bar: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW/INFO acceptable if documented.
---

# SECURITY audit — v1.7.8 TPS measurement fix

Audit for security-relevant defects on the current diff.

## Context

`Stage1Prober.probeOnce` in
`phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
now counts SSE content deltas as a token-count proxy and measures
generation-only elapsed (from first token to last). Pre-v1.7.8
counted words and included TTFT in elapsed.

Result affects install-time recommendation math ONLY. Coord-side
billing math is unchanged (coord bills based on runtime usage, not
install-time benchmark).

## Security-relevant surfaces

### 1. TPS inflation as an eligibility bypass

Provider could try to inflate reported TPS to unlock a recommendation
they shouldn't get. Consider:
- Local subprocess trust: the MLX server is CLI-spawned. Attacker
  would need to compromise local machine to substitute a bogus SSE
  emitter that spams empty-content deltas fast.
- Empty content is filtered by the pre-existing `guard !content.isEmpty`
  check, so deltas require actual content bytes.
- A bogus emitter could send many single-char delta chunks fast to
  inflate deltaCount. This affects install-time recommendation
  identity ONLY. Runtime billing is based on coord-side rate-card,
  not the install-time TPS.

Confirm the inflation surface is limited to install-time
recommendation identity, not runtime credit inflation.

### 2. Rate-card decision downstream

An inflated TPS causes a HIGHER-expected-net-USD-per-hour candidate
to be recommended. Recommended candidate must still clear
$0.005/hr paid threshold. If the provider serves inference at
sub-threshold real-world TPS, they'll earn less than the install-
time projection. No financial harm to the network — they just earn
less than expected.

### 3. Amplification in denominator

`generationElapsed = max(0.001, ...)` gives a lower bound of 1ms.
Fastest possible TPS = `outputTokens / 0.001` = 1000 * outputTokens.
Consider whether this ceiling is exploitable. For `maxTokens = 64`,
max reported TPS = 64000. Is that observable/loggable in any way
that could confuse operators or downstream systems?

## Non-goals

- MLX server internal security (unchanged).
- Rate-card signing (unchanged).

## Files to read

- `phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift`
- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift`
  (for reference to how TPS feeds into recommendation math)

## Reply format

```
## SECURITY audit — v1.7.8

CRITICAL: <count>
HIGH: <count>
MEDIUM: <count>
LOW: <count>
INFO: <count>

### CRITICAL
[if none: "None."]
### HIGH
### MEDIUM
### LOW
### INFO
### Verdict
```
