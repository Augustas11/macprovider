You are auditing the Pillar D + A IMPL slice of SPEC-004 from a
CODE lens.

# Repository context

- Branch `feat/spec-004-pillar-b` (bundled-PR mode), HEAD `922e454`
  (D+A R1 fix-pass).
- R1 absorbed:
  - CODE-H1 + SEC-L1: log shape now strict superset of pre-Phase-D —
    CandidateLogEntry carries SlotsFree/SlotsTotal/ThroughputTPS/
    Metric aliases; Decision carries Legacy{CandidateCount,
    Epsilon, Seed, Draw, Reason}; LogRoutingDecision emits both
    SPEC-004 §7 names AND legacy aliases. tiebreak_mode reverse-
    maps to legacy 'reason' ('random_epsilon' → 'randomized').
  - SEC-M1: seedForRequest now uses seedForRequestWithKey(requestID,
    defaultDailyKey()); UTC date is the daily-key bucket.
  - ARCH-M1: sticky.Map.Update refresh path returns early without
    eviction; only NEW-key insertion at cap triggers TTL+LRU.
  - ARCH-L1: routing.BalancedScores doc reword (no fake helper
    reference).

# Audit scope (CODE lens)

Standard slate for log.go / class.go / sticky/sticky.go / buyer/
server.go (logRoutingDecision delegation + seedForRequest).

R1-specific re-check:
- Verify CandidateLogEntry's legacy aliases (SlotsFree, SlotsTotal,
  ThroughputTPS, Metric) carry the exact pre-Phase-D values
  (slots_free = SlotsFree, slots_total = SlotsTotal, throughput_tps
  = effective throughput same as new field, metric = objective
  metric same as new field).
- Verify Decision.Legacy* defaults derive correctly from the new
  fields when zero-valued.
- Verify LogRoutingDecision's reverse-map ('random_epsilon' →
  'randomized') covers both modes and doesn't introduce spurious
  'reason' fields when TiebreakMode is empty.
- Verify seedForRequestWithKey's delimiter prevents (key+req)
  concat collisions; verify defaultDailyKey is UTC-stable
  (not local-time-dependent).
- Verify sticky.Map.Update refresh path now correctly preserves
  CreatedAt and doesn't risk evicting itself.

# Severity vocabulary

CRITICAL / HIGH / MEDIUM / LOW per R1.

# Output format

```
Location: <file:line or symbol>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: 0/0/0/0.

Read the BUILD prompt §Phase D + §Phase A + R1 fix-pass commit
(`922e454`) + relevant origin/main before writing any finding.
