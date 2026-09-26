# #1690 audit: unified delivered-SSE billing and receipt-bound loopback (all three lanes)

**READ-ONLY.** Do NOT run builds, package resolves, or tests on this machine.

**Scope:** `git diff 8b3d6313 HEAD -- phase4-coordinator phase3-binary/Sources phase5-gateway`, the cumulative cancel and billing work. The latest design change is in `8a449f59` and `5d60ffc6`.

**`8a449f59`:**
- A loopback attempt is creditable only with a provider-signed v0.4 receipt: verified against the pinned key, bound to the attempt and route snapshot, and signing the same billable usage the ledger records. Full usage, the fence and R-12 are also still required; otherwise 0/0, quarantined.
- The CLI sends no token counts when the upstream omitted usage.
- Recovery requires the attempt's settlement output to be `pool_operator_attested`.
- Native `buyer_cancel` keeps its pre-#1690 byte-estimate billing: SPEC-015 §N.7 / SPEC-022 R-5.6 require a verified delivered-prefix binding, and there is no token-level delivered-prefix counter for native, so the verdict stays pending and then quarantined.
- A non-streaming cancel bills no bytes.

**`5d60ffc6`:**
- `deliveredSSEAccounting` is the single billing source for HTTP incremental, HTTP buffered, WS incremental, WS buffered, and tool-call materialization.
- Usage is taken only from provider-original, provider-terminated events, and counts once the buyer writer accepts the terminator of the carrying event (LF or CRLF). Delivered usage is never cleared by a later tail. Delivered bytes are the only estimate basis.
- The WS end-frame usage counts only if the whole stream was delivered.
- Once content is delivered, the prompt from a partially delivered usage event is kept; the completion counts only on full delivery.
- Tool-call materialization keeps the provider usage event.
- Also fixed: an infinite loop in the duplicate-key scan on a truncated JSON array (pre-existing on main).

**Check (all lanes, per lane focus):**
- Is the single component correct and complete? Is any path left with its own bookkeeping?
- Can any path bill undelivered output, bill invented or unattested loopback usage, or give free delivered output?
- Are normal native and pool-attested completions billed exactly as before, including buffered tool-call completions?
- Is receipt verification on the hot path sound (key pinning, attempt binding, usage equality, replay)?
- Concurrency: no races or hangs.

Report only real defects at their true severity. End with `VERDICT: <c> CRITICAL / <h> HIGH / <m> MEDIUM / <l> LOW`.
