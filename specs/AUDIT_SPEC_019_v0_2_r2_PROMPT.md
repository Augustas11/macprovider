# SPEC-019 v0.2.1 — Round 2 audit prompt (per-lane)

You are auditing **SPEC-019 v0.2.1 (2026-06-29, r1-absorption DRAFT)** at
worktree HEAD `a977b28` on branch `spec/019-v0-2-streaming`. The v0.1.5 body
remains LOCKED; v0.2.1 absorbed r1's 1 CRITICAL + 9 HIGH + 9 MEDIUM findings
into a v0.2 amendment surface only.

## What changed v0.2.0 → v0.2.1

Per the §12 v0.2.1 change-log entry and `specs/SPEC-019-v0_2-r1-audit.md`:

**Convergent absorption (4 themes):**

- **T-1 (1C+2H):** 3-layer money-path bridge → **AC-V2-3a**. Provider WS
  `inference_response_end.status ∈ {malformed_json_response,
  json_schema_validation_failed}` + coordinator SSE writer
  `settlement_ran:true` + gateway forwards terminal SSE error frame
  verbatim through `[DONE]` (no remap to `stream_malformed`, no
  gateway-side ok/positive settlement).
- **T-2 (3H+1M):** Streaming validation timeout → **AC-V2-9** bound to
  provider-side idle inactivity; reuses `inference_timeout` SSE code;
  concrete N value deferred to v0.2.x per SPEC-006 idle semantics.
- **T-3 (2H+1M):** Numeric-bound value validity → **AC-V2-10b**.
  `multipleOf > 0` (JSON number), `minimum`/`maximum` as JSON numbers,
  `minimum ≤ maximum` when both present. All rejects use existing
  `json_schema_unsupported_keyword` with `error.param` pointing at the
  offending node (no new code).
- **T-4 (1H+1M):** Numeric-bound type-conditional gate → **AC-V2-10a**.
  Any of `minimum`/`maximum`/`multipleOf` on a non-`number`/`integer`
  node MUST reject pre-inference at provider AND coordinator.

**Singular absorption (7 items):**

- **S-1:** SPEC-019-owned streaming content byte cap → **AC-V2-9b**. 2 MiB
  on post-stop-token-filter buyer-visible delta concatenation;
  SPEC-019-defined (not SPEC-018 reuse).
- **S-2:** Deleted v0.1 reject codes annotated as v0.1.x-only migration
  rows in the §5/§7 error-code table.
- **S-3:** AC-V2-5 amended — Cline commit pin + outbound POST byte
  capture + assert `stream:true` + exact `response_format.json_schema`
  fields before asserting parsed output.
- **S-4:** **AC-V2-13** partial-content negative streaming fixture.
- **S-5:** AC-V2-12 captured-body bytes for `z.number().int()` Vercel
  emission (`integer` + safe-integer min/max + top-level `$schema`).
- **S-6:** Top-level `$schema` cap-accounting + receipt prompt-hash
  clarifier in §3 AND §9 (cold-reader resilience).
- **S-7:** **AC-V2-14** composite-render invariant for `stream:true +
  tools + json_schema` (schema-adjusted `ChatMessage` →
  `ToolPromptRenderer.renderMessages` → `UserInput`).

## Anchors

- **SPEC under audit:** `specs/SPEC-019-structured-output.md` @ `a977b28`.
  Read §§1–12 + v0.2.1 change-log entry. v0.1.5 LOCKED body is
  immutable; constrain findings to v0.2 amendment surface.
- **SPEC-018 v0.2.4 LOCKED:** `specs/SPEC-018-agentic-tool-calling.md` —
  §10d.4 (SSE error frame minimum envelope) is the parent contract for
  AC-V2-3 reuse.
- **SPEC-015 LOCKED:** `specs/SPEC-015-receipts-and-billing.md` — the
  v0.2 amendment claims "no schema change". Verify.
- **IMPL anchors** (file:line citations in v0.2 amendment must
  resolve against these):
  - `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift` (WS
    error-frame allow-list)
  - `phase3-binary/Sources/MacProviderCore/JSONSchemaValidator.swift`
    (subset + reject-list)
  - `phase3-binary/Sources/MacProviderCore/StrictJSONParser.swift`
    (depth-bounded parser)
  - `phase4-coordinator/internal/buyer/server.go` (mirror validator +
    FaultBreakerQualifying + SSE writer)
  - `phase5-gateway/internal/router/chat_proxy.go` (Content-Encoding
    gate + SSE pass-through + double-settle prevention)
  - `phase3-binary/Sources/MacProviderCore/PromptCanonicalizer.swift`
    (prompt-hash binding)

## Lane charter (pick ONE based on agent firing this prompt)

Same charter as the r1 prompt, but **focused on the r1 absorption diff**.
Probe whether each absorbed finding actually closed cleanly, AND scan for
**new findings r1 may have introduced** (each absorption edit is a fresh
audit surface).

### Lane A — Codex architect

- Verify T-1 closed: §7/§8 v0.2 amendment text + AC-V2-3a contains
  provider WS, coord SSE writer, gateway pass-through invariants. Each
  layer normatively pinned, not narrative.
- Verify T-4 numeric-bound type gate is normatively enforced (not
  documentation-only). AC-V2-10a covers all non-numeric node types.
- Cross-spec consistency on AC-V2-3a: does the 3-layer bridge text
  collide with existing v0.1 layer invariants in §7/§8?
- Versioning monotonicity after v0.2.1 (T-3/T-4 numeric rules) — does
  §9 schema-keyword monotonicity still hold for future v0.2.x?

### Lane B — Codex code

- Re-verify B-H-1 closed: AC-V2-9b cap. Does the cap text resolve the
  byte-domain ambiguity (post-stop-token-filter buyer-visible delta
  concatenation) without leaving a §5/§6 contradiction?
- Re-verify B-H-2 closed: AC-V2-9 timeout source is now provider idle.
  Is the wire code (`inference_timeout`) actually defined in the v0.1.5
  error-code table? If not, AC-V2-9 references an undefined code.
- Re-verify B-H-3 closed: coord SSE writer `settlement_ran:true` for the
  two v0.2 codes. Is the citation
  `phase4-coordinator/internal/buyer/server.go:5150-5170` still accurate?
- New findings introduced by AC-V2-3a/9/9b/10a/10b/12/13/14 text — fresh
  audit surface. Re-grep file:line citations in those ACs for drift.

### Lane C — Codex security

- Re-verify C-1 closed: gateway no longer re-normalizes terminal v0.2
  error frames. Does AC-V2-3a explicitly forbid `stream_malformed`
  remap?
- Re-verify C-H-1 closed: AC-V2-9 timeout is now bound to provider idle.
  Does the new wording cover slow-roller streams that never trigger
  idle (i.e., emit one token every N-1 seconds)? Spec gap?
- Re-verify C-H-2 closed via AC-V2-10b: `multipleOf:0` rejected
  pre-inference. Negative `multipleOf`? Non-number operand? Inverted
  bounds? All covered?
- Double-settlement under streaming error frame: AC-V2-3a says gateway
  forwards verbatim and skips ok/positive settlement. Does it forbid
  double-settle if a terminal error frame is followed by a positive
  `[DONE]` from the coordinator? Spec gap?

### Lane D — Codex product-design

- Re-verify D-H-1 closed: AC-V2-5 now pins Cline commit + outbound POST
  byte capture. Is the captured byte requirement specific enough to
  prevent a passing-but-wrong fixture?
- Re-verify D-M-1 closed: AC-V2-13 partial-content negative fixture
  exists. Does it require both Cline AND Vercel partial-then-terminal-
  error fixtures, or just one?
- Re-verify D-M-2 closed: AC-V2-12 captured-body bytes for
  `z.number().int()`. Does the expected shape match actual
  `@ai-sdk/openai-compatible@2.0.38` emission (integer + safe-integer
  min/max + top-level `$schema`)? If the spec text speculated and the
  actual emission differs, the fixture will fail at IMPL time.

### Lane E — Claude critic (blind-spot adversarial)

- Hostile read of the v0.2.1 amendment diff (vs v0.2.0). What new
  contradiction emerges between absorbed text and existing v0.1.5
  LOCKED text? What absorbed AC could be satisfied by an IMPL that
  technically passes but violates the original finding's intent?
- AC-V2-9 idle timeout: who owns "idle"? Provider must measure idle
  on the upstream model generation, or on the buyer-visible delta
  emission? Differential definitions possible?
- AC-V2-10b `minimum <= maximum`: what about floating-point edge cases
  (NaN, ±Infinity)? Spec silent?
- AC-V2-9b cap-exceeded code: which existing code is reused? If the
  absorption picked an SPEC-018 code that doesn't exist on the
  SPEC-019 streaming path, the AC has an invalid citation.
- Citation drift: spot-check 3 file:line citations added in v0.2.1
  against IMPL source.

### Lane F — Claude narrative (blind-spot continuity)

- v0.2.0 → v0.2.1 change-log entry: does it accurately reflect the
  absorbed items? Any over-claim or under-claim?
- New terminology introduced in v0.2.1 ("provider-side idle",
  "post-stop-token-filter buyer-visible delta concatenation",
  "v0.1.x-only migration code") — consistent across §3, §5, §7, §8,
  §9, §10, §12?
- AC numbering hygiene: AC-V2-3a, 9b, 10a, 10b, 12, 13, 14 — does the
  letter-suffix pattern (AC-V2-Na) collide with future v0.3 numbering?
- §12 doc metadata: change log v0.2.1 entry cites the audit narrative
  file `specs/SPEC-019-v0_2-r1-audit.md`?

## Output format

Same per-lane format as r1:

```
# SPEC-019 v0.2.1 r2 audit — lane <X>

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
