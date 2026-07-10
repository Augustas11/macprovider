# SPEC-019 v0.2 IMPL — Round 4 defensive audit narrative

**Anchor:** `impl/spec-019-v0-2` HEAD (post r3 inline absorption + rebase onto origin/main).
**Audited diff:** `git diff origin/main..HEAD` — 8 IMPL commits.
**Round:** r4 (defensive)
**Lanes:** 4 codex + 2 Claude blind-spot

## Per-lane verdicts — ALL READY TO LOCK

| Lane | Verdict | C | H | M |
|---|---|---|---|---|
| A architect (codex) | READY TO LOCK | 0 | 0 | 0 |
| B code (codex) | READY TO LOCK | 0 | 0 | 0 |
| C security (codex) | READY TO LOCK | 0 | 0 | 0 |
| D product-design (codex) | READY TO LOCK | 0 | 0 | 0 |
| E critic (Claude, adversarial) | READY TO LOCK | 0 | 0 | 0 |
| F narrative (Claude) | READY TO LOCK | 0 | 0 | 0 |

**Totals: 0 CRITICAL, 0 HIGH, 0 MEDIUM across all 6 lanes.**

**LOCK satisfied.**

## r3 closure confirmations (verified by all 6 lanes)

- **A-r3-M-1** (TOCTOU under budget exhaustion): closed via Decision
  (C). Lane A + Lane E both spot-checked the new return-`Bool` +
  fail-closed-without-onIdleTimeout path. Lane E confirmed the
  benign race between operation-task `defer markOperationStopped()`
  and watcher's bool return.
- **B-r3-M-1** (modelHashObserved drop): closed via `modelHash:
  String?` parameter threaded through `validObservedModelHash`.
  Lane B + Lane E both confirmed the boundary cases (nil, empty
  string, malformed hex, 64-char valid hex) match pre-r2 inline-
  path semantics.
- **D-r3-M-1 + E-r3-M-1** (broken README link): closed via path
  string `../KNOWN_GAPS.md` → `../../KNOWN_GAPS.md`. Lane D + Lane F
  both verified depth-1 vs depth-2 README pointers resolve.

## Audit trajectory

| Round | Findings | Result |
|---|---|---|
| r1 | 3C + 8H + 9M | absorbed → r1 absorption commit |
| r2 | 0C + 3H + 6M | absorbed → r2 absorption commit |
| r3 | 0C + 0H + 4M | absorbed inline → r3 absorption commit |
| **r4 defensive** | **0/0/0 across all 6 lanes** | **LOCKED** |

## Out-of-scope finding (flagged, not absorbed)

`phase4-coordinator/internal/buyer/receipt_keys_test.go:105`
`TestReceiptKeysReturnsPreviousKeyInGraceWindow` time-bomb. Hardcoded
`expiresAt: 2026-06-29 12:00 UTC` collides with real wall-clock as of
today. Root-caused to `Registry.Register` calling
`activeReceiptPubkeyPrev(incoming, time.Now())` at
`phase4-coordinator/internal/pool/provider.go:550` BEFORE the test's
`server.now` override takes effect.

Pre-existing from SPEC-015 receipts work (PR #124, 2026-06-23). NOT
introduced by SPEC-019 v0.2 IMPL. Separate PR fix recipe documented
in r3 narrative.

## Lock confirmation

**Bar:** 0 CRITICAL + 0 HIGH + 0 MEDIUM across all 6 lanes.
**Status:** SATISFIED at impl/spec-019-v0-2 HEAD.

**Next steps:** open IMPL PR against origin/main. The 8 IMPL commits
rebased cleanly onto origin/main (which now carries v0.2.4 LOCKED
SPEC via the squash-merge of PR #233 as commit cf53191).

## Per-lane round files

- Lane A codex: `codex-spec-019-v0-2-impl-...12-42-24-793Z.md`
- Lane B codex: `codex-spec-019-v0-2-impl-...12-43-35-512Z.md`
- Lane C codex: `codex-spec-019-v0-2-impl-...12-43-26-731Z.md`
- Lane D codex: `codex-spec-019-v0-2-impl-...12-42-46-607Z.md`
- Lane E Claude: `tasks/a93febc803eff8a3c.output`
- Lane F Claude: `tasks/ad03fd4defcb258a6.output`
