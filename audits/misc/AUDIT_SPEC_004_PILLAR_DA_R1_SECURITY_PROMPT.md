You are auditing the combined Phase D + Phase A IMPL slice of
SPEC-004 from a SECURITY lens.

# Repository context

- Branch `feat/spec-004-pillar-b`, HEAD `59f4184`. Recent commits:
  - `05cdd9a` Phase D log.go (SPEC-004 §7 fields)
  - `c2d7e73` Phase D server.go log delegation + class.go
    (BalancedScores)
  - `59f4184` Phase A sticky package
- SPEC-004 v0.3.1 LOCKED. SPEC-005 v0.4 quarantine surface MUST
  remain untouched by this slice.

# Audit scope (SECURITY lens)

- **Sticky AccountID source authority.** The Phase A sticky.Map
  treats accountID as an opaque attribution string. Buyer-side
  code (which DEFERS to a follow-up commit) MUST verify the
  gateway-authenticated `X-MacProvider-Account` header before
  invoking Update. The sticky package doc says this explicitly —
  verify nothing in the package short-circuits or bypasses that
  contract. A bug here would let a hostile buyer pin themselves
  to or steal another buyer's sticky session.
- **PurgeAccount scope safety.** PurgeAccount(accountID) MUST
  scope to the supplied accountID only. Verify no path lets a
  caller wipe another account's entries. Concurrent-ops test
  hammers this.
- **Bounded-map DoS boundary.** MaxEntries cap MUST never be
  exceeded, including under contention. Verify two-pass eviction
  (TTL drop, then LRU) does not have a window where Len() could
  exceed cap. Concurrent test asserts maxObserved ≤ MaxEntries.
- **All five lifecycle operations under one mutex.** Read,
  write, last_used_at update, TTL expiry, LRU eviction — plus
  PurgeAccount and InvalidateClass — MUST all take the same
  sync.Mutex. Verify no method bypasses the lock.
- **FR-SR-17 reproducibility log.** random_seed MUST be derivable
  from request_id + daily key per SPEC-004 §7 closing paragraph
  (NEVER from time.Now). Phase D step 1 / 2 wires the log
  payload but the seed-derivation function lives in server.go
  (seedForRequest) — verify it has the required property and the
  new Decision struct correctly threads it through.
- **SPEC-005 v0.4 quarantine surface preserved.** Verify NO writes
  to ledger_quarantine_resolutions, NO new force-void route
  changes, NO billing_config_flag_changed audits from any
  Phase D / A code path. SPEC-005 v0.4 is OUT OF SCOPE per
  BUILD prompt NOT-cover list.
- **No buyer-input leak.** Verify the new log.go's x_request_id
  field is treated as buyer-untrusted in log consumers (logged
  verbatim is correct per SPEC-004 §7, but downstream consumers
  must know it's untrusted).
- **No selection-result drift.** TestDefaultConfigPreservesBaselineProviderSelection
  AC-SR-1 byte-identity verifies that no Phase D / A refactor
  has altered default-config selection — verify this remains
  green.
- **Logging side-effect parity.** Verify the new logRoutingDecision
  delegation produces a SUPERSET of the pre-Phase-D fields (no
  field dropped), with field renames matching SPEC-004 §7
  verbatim ('throughput_tps' → 'effective_throughput' in the
  per-candidate shape, 'slots_free' → 'slots', 'seed' →
  'random_seed', 'draw' → 'random_draw', 'reason' → 'tiebreak_mode').

# Severity vocabulary

CRITICAL / HIGH / MEDIUM / LOW per prior pillars.

# Output format

```
Location: <file:line or symbol>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: 0/0/0/0. Any HIGH or MEDIUM blocks
merge.

Read the BUILD prompt §Phase D + §Phase A + the new routing files
(class.go, log.go, sticky/sticky.go) + their tests + the
refactored server.go + relevant origin/main code before writing
any finding. Do not speculate; cite quotes.
