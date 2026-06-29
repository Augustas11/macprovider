# SPEC-019 v0.2.3 — Round 4 audit prompt (per-lane)

You are auditing **SPEC-019 v0.2.3 (2026-06-29, r3-absorption DRAFT)** at
worktree HEAD `568e110` on branch `spec/019-v0-2-streaming`. The v0.1.5
body remains LOCKED. v0.2.3 absorbed r3's 0C + 3H + 3M (from C, D, E) into
the v0.2 amendment surface only. Lanes A + B + F returned READY TO LOCK at
r3 already.

## What changed v0.2.2 → v0.2.3 (audit-anchor delta)

Per `specs/SPEC-019-v0_2-r3-audit.md` and the §12 v0.2.3 change-log entry:

**Convergent absorption (1 theme, closes 3H + 1M):**

- **E-H-1:** SPEC-006 §3221 citation was malformed (SPEC-006 numbering
  is §3.X). All 4 surface sites corrected to **§17.5 /
  `specs/SPEC-006-buyer-api.md:2605`** (the actual `provider_timeout`
  definition).
- **E-H-2:** `coordinator_request_seconds` had no normative prose in
  SPEC-006. v0.2.3 **retracts the "reuse existing" framing** and
  defines **SPEC-019-owned wall-clock semantics**: 300s by convention
  matching `coordinator_request_seconds` config field, NOT by SPEC-006
  normativity.
- **E-H-3:** `server.go:1722` was the WS-non-streaming HTTP-504 site.
  Streaming SSE `provider_timeout` is at **`:2386`**. Corrected
  everywhere.
- **E-M-1:** AC-V2-9 "wall-clock since request acceptance" — v0.2.3
  pins **gateway** as the wall-clock authority; zero-point =
  **gateway-side first-byte-of-request**. Provider owns the separate
  idle watcher.
- **C-r3-M-1:** Gateway transport timeout race — closed by promoting
  gateway-as-timeout-source from "fail condition" to "intended behavior
  under the SPEC-019 streaming gateway path". Gateway IMPL MUST route
  SPEC-019 streaming timeouts through `provider_timeout` + skip ok
  settlement; cited
  `phase5-gateway/internal/router/chat_proxy.go:225` +
  `:592-614`.

**Singular absorption (1 item):**

- **D-r3-M-1:** NaN/Infinity literals are invalid JSON tokens — parsed
  layer rejects them before schema validation. AC-V2-10b amended:
  buyer-visible envelope is **HTTP 400 `invalid_json`** for the four
  literals; non-numeric operand types (string/bool/null/array/object)
  retain `json_schema_unsupported_keyword` envelope.

**Grep guards verified clean at v0.2.3 (all = 0 hits):**
`§3221`, `:3221`, `server.go:1722`, `inference_timeout`.

## Anchors

- **SPEC under audit:** `specs/SPEC-019-structured-output.md` @
  `568e110`. v0.1.5 LOCKED body is immutable.
- **SPEC-006 LOCKED:** `specs/SPEC-006-buyer-api.md` — §17.5 / `:2605`
  defines `provider_timeout`. Verify the citation lands.
- **SPEC-018 v0.2.4 LOCKED:** `specs/SPEC-018-agentic-tool-calling.md` —
  §10d.4 SSE error frame envelope (parent contract for AC-V2-3 reuse).
- **SPEC-015 LOCKED:** `specs/SPEC-015-receipts-and-billing.md`. No
  schema change.
- **IMPL anchors** (verify file:line citations resolve):
  - `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:22-27` (parse layer)
  - `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift`
  - `phase4-coordinator/internal/buyer/server.go:2386` (streaming SSE provider_timeout)
  - `phase4-coordinator/internal/buyer/server.go:3467-3471` (parse layer)
  - `phase5-gateway/internal/router/chat_proxy.go:225` (300s upstream timeout)
  - `phase5-gateway/internal/router/chat_proxy.go:482-557` (forwardLine)
  - `phase5-gateway/internal/router/chat_proxy.go:592-614` (provider_disconnected/stream_truncated path SPEC-019 streaming MUST NOT take)
  - `phase5-gateway/internal/router/chat_proxy.go:625-629` (positive-settle path)

## Lane charter

This is a **defensive r4 audit** — primary objective is verifying that
the r3 wall-clock rewrite didn't introduce regressions in surfaces that
already returned READY TO LOCK at r3 (A, B, F).

Each lane:
1. Verify the cited r3-absorbed correction landed cleanly at every site
   it claimed to land.
2. Re-verify your own lane's r3 closures (or A/B/F's r2 closures if
   you're A/B/F).
3. Scan for **new findings the rewrite may have introduced** —
   wall-clock authority is a money-path surface, so any new ambiguity
   is in scope.

### Lane A — Codex architect
Focus: did the wall-clock rewrite introduce a cross-spec inconsistency?
Does the SPEC-019-owned wall-clock claim conflict with anything in
SPEC-006 (deployment, timeout taxonomy)? Does the gateway-authority
promotion create §7/§8 invariant violations?

### Lane B — Codex code
Focus: did each citation correction (§17.5/:2605, :2386, :225, :592-614)
actually land at the right place? Spot-check the cited line ranges
against the IMPL source. Are there leftover stale citations the absorber
missed?

### Lane C — Codex security
Focus: re-verify wall-clock deadline race closure (C-r3-M-1). Does the
v0.2.3 text actually require gateway-side `provider_timeout` emission
for SPEC-019 streaming timeouts? Are there any new DoS surfaces opened
by the gateway-authority promotion? Slow-roller revisit — is it now
materially closed by the gateway's own 300s timeout firing if the
provider's idle watcher doesn't fire?

### Lane D — Codex product-design
Focus: re-verify NaN/Infinity envelope closure (D-r3-M-1). Does AC-V2-10b
text now produce buildable buyer-side negative fixtures? Cline / Vercel
conjunctive language preserved? Is the "300s by convention" matching
`coordinator_request_seconds` value visible to buyers via documentation
hooks?

### Lane E — Claude critic (blind-spot adversarial)
Focus: hostile read of the r3 absorption diff. Did the rewrite
introduce any NEW phantom citation, MUST verb with ambiguous subject,
or contradictory wall-clock semantics between AC-V2-9 and §5/§7/§8?
Verify the SPEC-006 §17.5 / `:2605` citation against the SPEC-006 file.
Verify `server.go:2386` is actually the streaming SSE site (not another
non-streaming site). Verify `chat_proxy.go:225` is the 300s upstream
timeout site (not a misread of the surrounding code).

### Lane F — Claude narrative (blind-spot continuity)
Focus: v0.2.2 → v0.2.3 change-log accuracy; terminology consistency
across the rewrite ("SPEC-019-owned wall-clock", "gateway-side
first-byte-of-request", "by convention"); §12 doc metadata cites the r3
audit narrative file.

## Output format

Same per-lane format as r1/r2/r3:

```
# SPEC-019 v0.2.3 r4 audit — lane <X>

## Verdict
<READY TO LOCK | NEEDS REVISION>

## CRITICAL (N)
## HIGH (N)
## MEDIUM (N)
## Notes (N) [optional]
```

**Bar to return READY TO LOCK:** 0 CRITICAL + 0 HIGH + 0 MEDIUM.

**Do NOT** edit files. Do NOT propose v0.3+ scope. Do NOT propose v0.1.5
LOCKED body changes. Constrain to v0.2 amendment surface.
