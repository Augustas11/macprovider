# SPEC-019 v0.2 IMPL — Round 3 audit narrative

**Anchor:** `impl/spec-019-v0-2` HEAD (post r2 absorption + traceability)
**Audited diff:** `git diff 34bbab6..HEAD`
**Round:** r3
**Lanes:** 4 codex + 2 Claude blind-spot

## Per-lane verdicts

| Lane | Verdict | C | H | M |
|---|---|---|---|---|
| A architect (codex) | NEEDS REVISION | 0 | 0 | 1 |
| B code (codex) | NEEDS REVISION | 0 | 0 | 1 |
| C security (codex) | READY TO LOCK | 0 | 0 | 0 |
| D product-design (codex) | NEEDS REVISION | 0 | 0 | 1 |
| E critic (Claude, adversarial) | NEEDS REVISION | 0 | 0 | 1 |
| F narrative (Claude) | READY TO LOCK | 0 | 0 | 0 |

**Totals: 0 CRITICAL, 0 HIGH, 4 MEDIUM.** C + F clean.

## r2 closure confirmations (all 4 themes + 1 singular + 3 cleanups verified)

Lane F + lane A + lane B + lane D each spot-checked the r2 absorbed
items. Every r2 deliverable is present:

- T-r2-1 `Int64(exactly:)` lands at `JSONSchemaValidator.swift:278-286`
- T-r2-2 buffer-as-of-close ordering lands at `ModelRuntime.swift:1138-1180`
- T-r2-3 coord WS→SSE wire test lands in `structured_output_ws_detail_test.go`
- T-r2-4 helper extraction lands at `ModelRuntime.swift:1139-1162`
- D-r2-M-3 6-cell composite matrix lands; codex ran `assert_fixture.py` and confirmed byte-equivalence
- Cleanup items E-N-1/2/3 all landed
- Issue #235 opened; KNOWN_GAPS.md added; 4 fixture READMEs annotated

## r3 findings (all MEDIUM, all 1-3 line fixes)

### A-r3-M-1: buffer-as-of-close TOCTOU under budget exhaustion

**Site:** `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1230-1239`
(`waitForStructuredStreamingOperationStopped`).

The bounded-wait helper exits after the 100ms budget even when
`operationStopped` is still false. The watcher then reads
`accumulator.content` and validates, but the operation task may still
be appending. r2 absorbed the ordering (markTimedOut → cancel → await
→ snapshot → validate) but kept the wait helper bounded for liveness;
under a hung-operation worst case the validation runs on an in-flux
buffer. Existing tests use 20ms post-cancel delay so do not exercise
the budget-breach branch.

**Resolution (Decision (C) — locked-in design call):**

On budget breach, throw `provider_timeout` without reading the buffer.
Preserves AC-V2-9 "buffer-as-of-close" intent (close ≠ snapshot-during-
flux), avoids both deadlock (option B) and stale-buffer false-success
(status quo). Concrete change:

- `waitForStructuredStreamingOperationStopped` returns `Bool` (`true`
  if cleanly stopped within budget, `false` if budget exhausted).
- In the watcher arm, after the wait: if `false`, throw
  `Self.structuredStreamingProviderTimeoutError()` instead of calling
  `onIdleTimeout()`.
- Add test
  `testIdleBreachFailsClosedWhenOperationStopBudgetExhausted` that
  simulates a hung operation (refuses to stop within budget) and
  asserts the watcher throws `provider_timeout` AND `onIdleTimeout`
  is never called (i.e., the accumulator snapshot is never read).

### B-r3-M-1: helper drops modelHashObserved

**Site:** `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:1144`
(`synthesizeIdleTimeoutResultOrThrow`).

The extracted helper hardcodes `modelHashObserved: nil`. Pre-r2 inline
code at the prior site used
`Self.validObservedModelHash(snapshot.modelHash)`. r2 extraction
regression: idle-timeout-synthesized success now reports `null` for
`usage.macprovider_model_hash_observed` where it previously reported
the snapshot hash.

**Resolution:** Add `modelHash: String?` parameter to
`synthesizeIdleTimeoutResultOrThrow` and pass it through
`validObservedModelHash(...)`. Caller at `ModelRuntime.swift:686-689`
passes `modelHash: snapshot.modelHash`.

### D-r3-M-1 + E-r3-M-1 (convergent): broken KNOWN_GAPS.md relative link

**Sites:**
- `test/integration/spec_019/partial_content_negative/cline_partial_then_error/README.md:3`
- `test/integration/spec_019/partial_content_negative/vercel_partial_then_error/README.md:3`

Both READMEs use `../KNOWN_GAPS.md` but the file lives at
`test/integration/spec_019/KNOWN_GAPS.md` — two levels up. The link
404s in GitHub PR view and in markdown renderers. 2 of 4 fixture
README pointers broken — exactly the doc the r2 deferral (Decision
2γ) leans on.

**Resolution:** Change to `../../KNOWN_GAPS.md` in both files.

## r3 absorption applied inline (this commit)

All 3 fixes applied directly (no codex required — surgical surface,
~25 lines total):

1. **A-r3-M-1**: `waitForStructuredStreamingOperationStopped` returns
   `Bool`; watcher arm throws `structuredStreamingProviderTimeoutError()`
   on budget breach without calling `onIdleTimeout`. New test
   `testIdleBreachFailsClosedWhenOperationStopBudgetExhausted` asserts
   the budget-breach fail-closed path.
2. **B-r3-M-1**: `synthesizeIdleTimeoutResultOrThrow` accepts
   `modelHash: String?` and threads it through
   `validObservedModelHash(...)`. All 4 test callsites updated.
   Existing success-path test now asserts
   `result.modelHashObserved == String(repeating: "a", count: 64)`.
3. **D-r3-M-1 + E-r3-M-1**: 2 README path strings corrected.

## Out-of-scope finding (flagged, not absorbed)

Pre-existing time-bomb in `phase4-coordinator/internal/buyer/receipt_keys_test.go`:
`TestReceiptKeysReturnsPreviousKeyInGraceWindow` hardcodes
`expiresAt: 2026-06-29 12:00 UTC`. As of 2026-06-29 12:35 UTC the test
fails on a clean tree. Root cause: `Registry.Register` calls
`activeReceiptPubkeyPrev(incoming, time.Now())` at
`phase4-coordinator/internal/pool/provider.go:550`, using real wall-
clock, before the test's `server.now` override takes effect.

Pre-existing from SPEC-015 receipts work (PR #124, 2026-06-23). Not
touched by SPEC-019 v0.2 IMPL. Out of scope for this absorption loop.

Fix recipe (separate PR):

```
phase4-coordinator/internal/buyer/receipt_keys_test.go:105
TestReceiptKeysReturnsPreviousKeyInGraceWindow fails after
2026-06-29 12:00 UTC. Hardcoded expiresAt collides with real
wall-clock; test override of server.now doesn't reach
Registry.Register's internal activeReceiptPubkeyPrev call at
phase4-coordinator/internal/pool/provider.go:550.

Three fix options:
1. (smallest) Bump the hardcoded rotatedAt/expiresAt to e.g.
   2030-06-29 and document the time-bomb pattern.
2. (better) Thread a `now` parameter through
   registerReceiptKeyProvider so test and registry see the same
   frozen clock.
3. (best) Make Registry.Register accept an optional clock
   injection like Server.now, defaulting to time.Now.

Likely also affects receipt-keys tests at lines 76, 80 — audit
all hardcoded date constants and either pin to a future date or
wire through a clock.
```

## r4 audit pending

After committing r3 absorption: 3-module smoke (phase3 expected 646),
fire r4 audit (4 codex + 2 Claude). Lock convention 0/0/0 across all
6 lanes.

## Per-lane round files

- Lane A codex: `codex-spec-019-v0-2-impl-...10-38-52-726Z.md`
- Lane B codex: `codex-spec-019-v0-2-impl-...10-38-06-577Z.md`
- Lane C codex: `codex-spec-019-v0-2-impl-...10-38-21-007Z.md`
- Lane D codex: `codex-spec-019-v0-2-impl-...10-37-18-647Z.md`
- Lane E Claude: `tasks/aa22ae74c143907ac.output`
- Lane F Claude: `tasks/aaeb2a93507301f7a.output`
