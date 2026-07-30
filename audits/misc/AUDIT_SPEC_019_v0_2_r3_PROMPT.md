# SPEC-019 v0.2.2 — Round 3 audit prompt (per-lane)

You are auditing **SPEC-019 v0.2.2 (2026-06-29, r2-absorption DRAFT)** at
worktree HEAD `c0aa2a9` on branch `spec/019-v0-2-streaming`. The v0.1.5
body remains LOCKED. v0.2.2 absorbed r2's 1 CRITICAL + 3 HIGH + 5 MEDIUM
into the v0.2 amendment surface only. Lanes A + F returned READY TO LOCK
at r2 already.

## What changed v0.2.1 → v0.2.2

Per the §12 v0.2.2 change-log entry and `specs/SPEC-019-v0_2-r2-audit.md`:

**Convergent absorption (3 themes):**

- **T-r2-1 (1C+1H):** `inference_timeout` (referenced 4 places) was a
  phantom code. Substituted with existing **SPEC-006 §3221
  `provider_timeout`**. Zero new error codes.
- **T-r2-2 (1H+1M):** **AC-V2-3a** gateway citation widened from
  `phase5-gateway/internal/router/chat_proxy.go:493-531` →
  `:482-557` (full `forwardLine`) **PLUS** explicit second citation
  `:625-629` (positive-settle path). Adds normative IMPL test
  obligation: gateway MUST emit NO `usage_events` row with
  `outcome:"ok"` for a stream whose terminal SSE `error.code ∈
  {malformed_json_response, json_schema_validation_failed}`.
- **T-r2-3 (2M):** **AC-V2-13** rewritten conjunctive — fixture set
  MUST include BOTH a Cline AND a Vercel partial-content-then-
  terminal-error stream.

**Singular absorption (3 items):**

- **S-r2-1:** **AC-V2-9** wall-clock total deadline paired with idle
  inactivity. Reuses SPEC-006 §15.2 / `specs/SPEC-006-buyer-api.md:2433-2435`
  per-request deadline. Both conditions independently trigger
  `provider_timeout` + `FaultBreakerQualifying`.
- **S-r2-2:** §11 audit-hook 16 — defers v0.1.5 LOCKED
  `response_byte_cap_exceeded` retryable drift to v0.3. AC-V2-9b
  inherits IMPL semantics (`false`).
- **S-r2-3:** **AC-V2-10b** RFC 8259 §6 normative clause — `NaN`,
  `Infinity`, `+Infinity`, `-Infinity` MUST reject via
  `json_schema_unsupported_keyword`. Negative fixtures MUST cover.

## Anchors

- **SPEC under audit:** `specs/SPEC-019-structured-output.md` @
  `c0aa2a9`. Read §§1–12 + v0.2.2 change-log entry. v0.1.5 LOCKED body
  is immutable.
- **SPEC-006 LOCKED:** `specs/SPEC-006-buyer-api.md` — §3221
  (`provider_timeout`) and §15.2 (per-request deadline, lines 2433-2435).
  Verify both citations exist as cited.
- **SPEC-018 v0.2.4 LOCKED:** `specs/SPEC-018-agentic-tool-calling.md` —
  §10d.4 SSE error frame envelope (parent contract for AC-V2-3 reuse).
- **SPEC-015 LOCKED:** `specs/SPEC-015-receipts-and-billing.md` — v0.2
  amendment claims "no schema change". Verify.
- **IMPL anchors:**
  - `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift`
  - `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift`
  - `phase4-coordinator/internal/buyer/server.go` (esp. `:1722`,
    `:1949`, `:2386`, `:3455`, `:5150-5170`)
  - `phase5-gateway/internal/router/chat_proxy.go` (esp. `:482-557`,
    `:625-629`)
  - `phase3-binary/Sources/MacProviderCore/PromptCanonicalizer.swift`

## Lane charter

Same charter as r1/r2. Probe whether each r2 absorbed finding actually
closed cleanly, AND scan for new findings r2 may have introduced
(each absorption edit is a fresh audit surface).

Specifically:
- Did `provider_timeout` substitution land at all 4 cited sites without
  drift? Does the §5 error-code table reflect this reuse?
- Does the SPEC-006 §15.2 citation (lines 2433-2435) actually point at
  the per-request deadline? Confirm against the SPEC-006 file.
- AC-V2-3a gateway citation widening: are both `:482-557` and `:625-629`
  cited? Does the `usage_events outcome:"ok"` test obligation read as
  normative (MUST), not advisory?
- AC-V2-13 conjunctive language: is "MUST include both Cline AND Vercel"
  load-bearing, or does the rest of the AC body re-open the disjunctive
  door?
- AC-V2-10b RFC 8259 §6 clause: covers all four literals? Negative
  fixture requirement explicit?

### Lane A — Codex architect
Focus: cross-spec consistency post-r2; verify SPEC-006 §3221 + §15.2
exist; ensure AC-V2-9 dual-trigger semantics (idle OR wall-clock) don't
contradict §8 money-path invariants.

### Lane B — Codex code
Focus: verify all 4 `provider_timeout` substitution sites cleanly;
verify SPEC-006 §15.2 line numbers (2433-2435) are accurate; verify
gateway citation widening lands at both `:482-557` and `:625-629`;
verify §11 deferral entry 16 references correct IMPL line.

### Lane C — Codex security
Focus: does wall-clock total deadline close the slow-roller DoS hole
(C-r2-H-1) by bounding total request duration? Are there NEW failure
modes introduced by dual-trigger semantics (e.g., idle fires before
wall-clock and a second wall-clock firing causes double-terminate)?

### Lane D — Codex product-design
Focus: AC-V2-13 conjunctive requirement clear for fixture authors?
Cline AND Vercel both implementable with current SDK shapes? AC-V2-10b
NaN/Infinity rejection observable from buyer-side (404/400 envelope
shape)?

### Lane E — Claude critic (blind-spot adversarial)
Focus: hostile read of the r2 absorption diff (vs v0.2.1). What new
contradiction emerges? Verify SPEC-006 §15.2 / line 2433-2435 citation
against actual SPEC-006 file. Are there new MUST verbs in v0.2.2 whose
subject (provider/coord/gateway) is ambiguous? Cite 3 file:line
citations added in v0.2.2 and verify against source.

### Lane F — Claude narrative (blind-spot continuity)
Focus: v0.2.1 → v0.2.2 change-log accuracy; terminology consistency
("provider_timeout", "wall-clock total deadline", "Cline AND Vercel");
§12 doc metadata cites the r2 audit narrative file.

## Output format

Same per-lane format as r1/r2:

```
# SPEC-019 v0.2.2 r3 audit — lane <X>

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
