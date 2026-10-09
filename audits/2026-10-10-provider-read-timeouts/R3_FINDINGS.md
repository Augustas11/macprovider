## Raw output

```text
Architecture gate: **PASS** at `aab1dcfe3`. Complete diff, callers, and SPEC-014 v0.12 reviewed. No files edited.

- **R1 missing index — FIXED.** `unlock.go:226–234` selects the unpinned query when the index is absent or renamed. Regression coverage exercises shared and standalone readers. Cancellation remains an error.
- **R1 idle-prewarm contract — FIXED.** `SPEC-014-provider-portal.md:598` scopes mandatory 503 responses to financial/settlement reads and explicitly exempts optional telemetry.
- **R2 stale balances — FIXED.** `index.html:2056` displays the error alongside cached figures and labels them “last loaded.” A fresh harness verified success → 503 → success recovery without sign-out.

No new C/H/M/L findings.

- **INFO — Retention integration:** `unlock.go:234`; open PR #1909 adds archived counts in one SQL snapshot. Preserve that addition alongside this index fallback when integrating; otherwise retention can undercount trust progress.
- **INFO — Remaining linear cost, pre-existing:** `endpoints.go:1682`; payable aggregation still scans provider history. This reduces repeated work but does not bound lifetime cost. Future bounded aggregation must preserve financial semantics.

Validation: 7 portal tests passed, refresh/recovery harness passed, and `git diff --check` passed. Shared-pool ownership and Malibu’s nonfatal 503 handling checked by source review. Go/Swift suites were not rerun.

C/H/M/L = 0/0/0/0
