# Audit: ISS-165 R2 security lens — fix pass on R1 findings

R1 returned 1 HIGH (SEC) + 1 LOW (SEC). R2 verifies on commit
`a5e9e34`. Tree: `spec/iss-165-spec-016-followups`.

## R1 SEC findings to verify

- **HIGH**: `ProduceStaleOutboxRows` LIMIT applied before RPC
  eligibility → denial of detection (non-actionable rows
  permanently block stale-cancel PAGEs). Fix: cap on PRODUCED
  rows, hard scan cap of 1000, regression test
  `TestProduceStaleOutboxRows_NonActionableRowsDoNotConsumeLimit`.
- **LOW**: tracker mutex held through `zerolog.Send()`. Fix:
  Evaluate collects emit decisions under lock, releases, emits.

## Security threat model (R2)

Continue from R1: money path, operator-visibility integrity,
PAGE-storm prevention. Additionally:

1. **R1 SEC HIGH fix verification**: trace a scenario where
   the first 10 candidates are reconfirmable + a 11th candidate
   is truly stale + limit=2. Does the producer PAGE the 11th
   within the same cycle, or does the new scan cap interact
   poorly?
2. **Scan cap as new attack surface**: if an adversary can
   inflate the candidate set past 1000, does the cap mask real
   stale cancels? When the scan cap fires, is the operator
   alerted (`scan_cap_hit=true` field in the WARN)?
3. **Tracker goroutine**: `Run()` ticks every ≤1 minute. Can a
   chronic outage cause the tracker to PAGE every cycle once
   the cooldown lapses, even when the SAMPLES haven't changed?
   Check the prune-then-evaluate ordering.
4. **Mutex release timing**: the new Evaluate releases the mutex
   before emitting logs. Could the decision-set be stale by the
   time we emit? Is `lastPagedAt` still racefree?

Find SECURITY DEFECTS. Same severity + output format. End with
`## Convergence X/X/X/X → DECISION`.
