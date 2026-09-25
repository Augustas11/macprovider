# #1690 audit: cancel and billing fixes, round 4 (final; all three lanes)

**READ-ONLY.** Do NOT run builds, package resolves, or tests on this machine.

**Focus:** `git show 95c45f87`, the fix for the single round-3 HIGH. Cumulative context: `git diff 8b3d6313 HEAD`; earlier briefs `AUDIT_1690_CANCELFIX*.md`.

**Round-3 HIGH (all lanes):** a clean EOF on direct HTTP SSE billed an unterminated final event.

**Fix:** an SSE event counts as delivered only after its blank-line terminator is written, including at clean EOF. This applies on all four streaming paths: HTTP SSE, WS incremental, WS buffered, and HTTP buffered. Usage is taken from the provider's original line and counted once the event carrying it is delivered. Normal completions end with `data: [DONE]\n\n` and settle unchanged.

**Check:**
- that the round-3 HIGH is resolved on every path;
- that normal completions still settle and bill correctly;
- that usage attribution cannot double-count, drop, or be taken from a rewritten line;
- that no regression affects the previously accepted fixes (fence, recovery, cancel receipts).

Report only real defects at their true severity. End with `VERDICT: <c> CRITICAL / <h> HIGH / <m> MEDIUM / <l> LOW`.
