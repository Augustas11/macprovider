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

## R2 — pending

Per [[feedback-skip-accepted-audit-lanes]]: SECURITY lane sustained
0/0/0/0 at R1; SKIP R2 for SECURITY (no new attack surface added
in R1 fix-pass — fixes touched correctness of existing surface,
not new boundaries).

Fire CODE + ARCH only at R2. Target: 0 C/H/M.
