# SPEC-019 v0.2.3 — r3 absorption prompt

You are absorbing **r3 audit findings** into
`specs/SPEC-019-structured-output.md`, bumping version `0.2.2 → 0.2.3`.
r3 narrative is at `specs/SPEC-019-v0_2-r3-audit.md`.

r3 totals: **0C + 3H + 3M** across 3 lanes. A + B + F READY TO LOCK at r3.

**Constraints — DO NOT VIOLATE:**

- v0.1.5 LOCKED body is **immutable**. All edits land in v0.2 amendment
  surface only.
- No SPEC-015 schema change.
- No SPEC-018 edits.
- No SPEC-006 edits (cannot fix SPEC-006's missing wall-clock prose;
  SPEC-019 v0.2.3 defines its own).
- No new HTTP endpoint.
- No new error codes (reuse existing only).
- Bump version header (line 3) AND §12 metadata to
  **0.2.3 (2026-06-29, r3-absorption draft for audit)**. Status remains
  `DRAFT — audit loop pending`.

## Resolved design calls (baked in — DO NOT re-litigate)

**Decision 1A — Wall-clock authority = gateway, SPEC-019-defined.**
SPEC-019 v0.2.3 defines its own wall-clock semantics. Drop the "reuse
existing SPEC-006 per-request deadline" framing. Pin the gateway as the
wall-clock watcher with zero-point at gateway-side first-byte-of-request.
Value 300s matches `coordinator_request_seconds` by **convention**, not
by SPEC-006 normativity. Gateway emits terminal SSE `error.code =
provider_timeout` + `FaultBreakerQualifying` settlement on breach.

**Decision 2α — AC-V2-10b NaN/Infinity envelope = HTTP 400 `invalid_json`.**
The request-body JSON parser catches these literals before schema
validation. Buyer-visible envelope is `invalid_json` (HTTP 400) from the
parse layer, NOT `json_schema_unsupported_keyword`. Negative fixtures
assert `invalid_json`. Non-numeric operand types (strings, booleans,
null, arrays, objects) keep the `json_schema_unsupported_keyword`
envelope.

## Absorption items

### Convergent — wall-clock authority rewrite (3H + 1M)

Closes E-H-1 + E-H-2 + E-H-3 + E-M-1 + C-r3-M-1 in one consistent
rewrite.

**Site 1: AC-V2-9 (current lines ~438-461).**

Rewrite the wall-clock paragraph(s). Required content:

> **Wall-clock total deadline (SPEC-019 v0.2 defined):** the streaming
> structured-output request also fails closed when the wall-clock
> duration since gateway-side first-byte-of-request exceeds 300 seconds.
> The gateway owns this watcher; the value matches the
> `coordinator_request_seconds` configuration field by convention. On
> wall-clock breach: the gateway emits a terminal SSE error frame using
> the existing `provider_timeout` code (SPEC-006 §17.5 defines
> `provider_timeout`, `specs/SPEC-006-buyer-api.md:2605`), settles the
> request as `FaultBreakerQualifying` with zero provider-positive
> credits, and skips the gateway-side ok / positive settlement path.
>
> **Provider-side idle timeout** (separate watcher): the provider closes
> upstream generation when no buyer-visible content delta is emitted for
> N seconds (N deferred to v0.2.x). On idle breach: end-of-stream
> validation runs on the buffer-as-of-close; the streaming SSE
> `provider_timeout` emit path at
> `phase4-coordinator/internal/buyer/server.go:2386` carries the
> terminal frame; settlement is `FaultBreakerQualifying`.
>
> **Idle vs wall-clock:** both authorities own independent watchers.
> Either may fire first. Whichever fires first produces the buyer-visible
> terminal frame; the other authority MUST observe the closed stream
> and not fire a second time.
>
> **Gateway-emit-provider_timeout** is the intended behavior of the
> gateway watcher; the gateway IMPL MUST route SPEC-019 streaming
> wall-clock timeouts through `provider_timeout` + skip ok/positive
> settlement (not through `provider_disconnected` /
> `stream_truncated`). Cite
> `phase5-gateway/internal/router/chat_proxy.go:225` (existing 300s
> upstream-request timeout site) and `:592-614` (the
> `provider_disconnected` / `stream_truncated` path that MUST NOT
> classify SPEC-019 streaming structured-output timeouts).

**Site 2: §5 v0.2 streaming-validation paragraph (current line ~1020-1032).**

Mirror the same dual-authority structure. Drop the "reuse existing
SPEC-006 per-request deadline" framing. Cite SPEC-006 §17.5 / `:2605`
only for the `provider_timeout` *definition*, not for any per-request
deadline.

**Site 3: §10 v0.2.x deferral bullet (current line ~1340-1395).**

Update the bullet's text to reflect the SPEC-019-defined wall-clock
semantics. The deferred items remain: concrete provider-idle N value,
partial-JSON-prefix validation, schema warm-cache, etc.

**Site 4: §12 v0.2.2 change-log entry (current line ~1431).**

Add a v0.2.3 entry summarizing the rewrite. Acknowledge the r2 framing
("reuse existing SPEC-006 per-request deadline") was incorrect because
SPEC-006 has no normative prose for `coordinator_request_seconds`;
v0.2.3 retracts that framing and defines SPEC-019 v0.2 wall-clock
semantics gateway-side.

**Site 5: §11 audit-hook 16 cross-reference (if any).**

Verify the §11 entry doesn't carry the stale SPEC-006 §3221 cite.

**All four "SPEC-006 §3221" / "specs/SPEC-006-buyer-api.md:3221"
occurrences MUST be replaced** — grep the file for `§3221` and `:3221`
to verify zero remain after the edit.

**`server.go:1722` MUST be replaced with `:2386`** at every occurrence —
grep for `server.go:1722` to verify zero remain.

### Singular — AC-V2-10b NaN/Infinity envelope (1M)

**Site: AC-V2-10b (current ~lines 488-501).**

Rewrite the RFC 8259 §6 clause to:

> Per RFC 8259 §6, the JSON `number` production excludes the literals
> `NaN`, `Infinity`, `+Infinity`, and `-Infinity`. All four are not
> valid JSON tokens, so the **request-body JSON parser** at the
> coordinator (`phase4-coordinator/internal/buyer/server.go:3467-3471`)
> and at the provider
> (`phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:22-27`)
> rejects them BEFORE schema validation runs. The buyer-visible envelope
> for these four literals MUST be HTTP 400 `invalid_json` (the standard
> request-body parse error envelope), NOT
> `json_schema_unsupported_keyword`.
>
> Negative fixtures for `NaN`, `Infinity`, `+Infinity`, and `-Infinity`
> in numeric-bound positions MUST assert HTTP 400 `invalid_json`.
>
> The `json_schema_unsupported_keyword` envelope (via §3 schema-subset
> reject path) applies to non-numeric operand types only: strings,
> booleans, `null`, arrays, and objects in `multipleOf` / `minimum` /
> `maximum` positions. Negative fixtures for those five operand types
> MUST assert HTTP 400 `json_schema_unsupported_keyword` with
> `error.param` pointing at the offending node path.

### Lane A + B + F READY closures (no action)

All three lanes returned 0/0/0 at r3. No action.

### Out-of-scope items (do NOT absorb)

- Lane E E-N-1/E-N-2/E-N-3 notes — observational only, no action.
- Lane C Note about idle-vs-wall-clock double-firing — already covered
  by "the other authority MUST observe the closed stream and not fire a
  second time" clause in the absorption text above.

## Output requirements

- Edit `specs/SPEC-019-structured-output.md` in-place.
- Bump version header (line 3) and §12 metadata to
  **0.2.3 (2026-06-29, r3-absorption draft for audit)**.
- Add v0.2.3 change-log entry to §12. Summarize the wall-clock authority
  rewrite + NaN/Infinity envelope correction in one paragraph. Cite the
  audit narrative `specs/SPEC-019-v0_2-r3-audit.md` for traceability.
- Status remains `DRAFT — audit loop pending`.
- DO NOT commit. r4 audit will fire against this draft.
- Reasoning effort: **medium** (this absorption changes the wall-clock
  authority story across 4-5 sites; verify cross-section consistency
  before considering the edit complete).
- After editing, **grep the file for `§3221`, `:3221`, `server.go:1722`,
  and `inference_timeout`** — all four MUST return zero hits.
