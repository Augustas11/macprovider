# Issue #266 Tranche 1 — audit results

Three-lane codex audit on PR for issue #266 Tranche 1 (operator-green-light safety/correctness).

## R1 — 2026-06-30

Commit audited: `b80f39d` (initial implementation).

| Lane | C | H | M | L | Status |
|------|---|---|---|---|--------|
| CODE | 0 | 0 | **2** | 2 | iterate |
| SECURITY | 0 | 0 | 0 | 0 | ✅ ACCEPT |
| ARCHITECT | 0 | 0 | **2** | 3 | iterate |

### R1 findings absorbed (commit pending after R2)

**CODE-M1 / ARCH-M2** — `PreflightResult` not populated in retry-path
routing-decision logs. Fix: new `Server.preflightLabel(estimatedTokens)`
helper returning `"accepted"` or `"not_applicable"`; `forwardState.estimatedTokens`
snapshotted at request entry; all three afterAdvance callbacks
(streaming / WS-non-streaming / HTTP) populate the field via the
helper. Production retry logs now ship the complete SPEC-004 §7
audit-explainability surface.

**CODE-M2** — `stickyMismatchLimiter.allow` at-cap hostile-rotation:
when every entry was within-window, the old `evictOldestLocked` path
evicted the oldest legit entry to make room, allowing one warn per
hostile-rotated unique key. Fix: replaced with `sweepExpiredLocked`
which only drops expired entries; if cap is still full after sweep,
`allow` DENIES the new key. Aggregate warn rate bounded to
MaxEntries per window across all unique keys.

**ARCH-M1** — Case-insensitive class lookup vs case-sensitive
`InvalidateClass`. Fix: `sticky.Map.InvalidateClass` now uses
`strings.EqualFold(entry.ModelScope, className)` so a class
configured as "MLX-Fast" purges entries stored with
ModelScope="mlx-fast" / "MLX-FAST" / etc. This matches the
upstream `resolveModelClass` semantics.

**ARCH-L3** — `dailyKey` was captured with a second `s.now()` call.
Fix: derive from `startedAt.UTC().Format(...)` so request-start
timestamp and routing-seed bucket agree atomically at the
UTC-midnight boundary.

**ARCH-L4 / CODE-L4** — Stale comments referencing the pre-#266
asymmetry where WS-non-streaming did NOT emit the per-retry routing-
decision log. Fixed in `forward_with_failover.go:190` and
`server.go:1550`.

**CODE-L3** — `diffModelClasses` docstring said "members set /
normalised" but the implementation uses ordered slice comparison.
Fixed the docstring to state ordered comparison explicitly.

**CODE-L4** — `forwardState.dailyKey` comment claimed retries reuse
the original request_id; in fact each retry attempt rolls a fresh
uuid for nextRouteID. Fixed the comment to clarify that what's
sticky across attempts is the daily-key bucket, not the request_id.

**ARCH-L5** — `reloadTier2Config` name growing misleading as it
now handles tier2 + billing + routing. **Accepted with rationale**
for this tranche per the audit's own "accepted for this tranche;
rename in Tranche 2" guidance.

### New tests added in fix-pass

- `TestSetRoutingClasses_InvalidateClassIsCaseInsensitive` — pins
  the ARCH-M1 case-insensitive purge behavior across 2 case
  variants + 1 unrelated entry.
- `TestPreflightLabel_NotApplicableWhenPreflightSkipped` — pins the
  "preflight skipped → not_applicable" branch (nil preflight + below
  threshold).
- `TestPreflightLabel_AcceptedWhenPreflightRan` — pins the
  "preflight ran → accepted" branch.
- Refactored `TestStickyMismatchLimiter_BoundedByMaxEntries` into
  `TestStickyMismatchLimiter_AtCapAllInWindowDeniesNewKey` (pins
  new deny-at-cap semantics) and
  `TestStickyMismatchLimiter_ExpiredEntriesSweptToFreeCap` (pins
  the sweep-then-allow path).

## R2 — 2026-06-30

Commit audited: `efa8ef6` (R1 fix-pass). SECURITY lane skipped per
[[feedback-skip-accepted-audit-lanes]] (locked at R1 0/0/0/0).

| Lane | C | H | M | L | Status |
|------|---|---|---|---|--------|
| CODE | 0 | 0 | 0 | 2 | ✅ ACCEPT |
| SECURITY | — | — | — | — | sustained R1 (skipped) |
| ARCHITECT | 0 | 0 | 0 | 3 | ✅ ACCEPT |

**All three lanes at C/H/M = 0. Merge bar met.**

### R2 findings absorbed

**CODE-L1 / ARCH-L1** — stickyMismatchLimiter package doc still
described pre-fix "evict oldest before insertion" behavior. Rewritten
to describe sweep-expired-then-deny-at-cap.

**CODE-L2** — `forwardState.dailyKey` comment claimed the daily-key
is "recorded in the log" but no `daily_key` field exists. Reworded
to clarify: dailyKey survives via the request_log row's start
timestamp, which downstream auditors feed back into
`seedForRequestWithKey` alongside per-attempt request_id to reproduce
the seed.

**ARCH-L2** (reloadTier2Config rename) — accepted with rationale for
Tranche 1; deferred to Tranche 2.

**ARCH-L3** (retry log shape divergence) — accepted with rationale;
consumers distinguish retry rows via `attempt_index` / `retry_count` /
`retry_reason`.

Plus: gofmt cleanup on the 6 touched files.

## Convergence

R1 → R2 absorbed 2 MEDIUM + 5 LOW; R2 absorbed 2 LOW; total 9
findings closed across 2 rounds. SECURITY locked at R1 0/0/0/0.
Final bar: 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three lanes.
Ready for PR + merge.
