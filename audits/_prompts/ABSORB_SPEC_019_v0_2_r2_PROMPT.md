# SPEC-019 v0.2.2 — r2 absorption prompt

You are absorbing **r2 audit findings** into
`specs/SPEC-019-structured-output.md`, bumping version `0.2.1 → 0.2.2`.
r2 narrative is at `specs/SPEC-019-v0_2-r2-audit.md`.

r2 totals: **1C + 3H + 5M** across 4 lanes; A + F READY TO LOCK.

**Constraints — DO NOT VIOLATE:**

- v0.1.5 LOCKED body is **immutable**. All edits land in v0.2 amendment
  surface only (AC-V2-* ACs, §3/§5/§6/§7/§8/§9/§10 v0.2 subsections,
  §11 audit-hook additions, §12 change-log).
- No SPEC-015 schema change.
- No SPEC-018 edits.
- No new HTTP endpoint.
- No new error codes (reuse existing codes only — see T-r2-1 decision).
- Bump version header (line 3) AND §12 metadata to
  **0.2.2 (2026-06-29, r2-absorption draft for audit)**. Status remains
  `DRAFT — audit loop pending`.

## Resolved design calls (baked in — DO NOT re-litigate)

**T-r2-1 timeout code substitution: (A) `provider_timeout`.**
Replace all `inference_timeout` references with `provider_timeout`. Drop
the "existing" qualifier where needed. Cite SPEC-006 §3221 as the
defining doc and `phase4-coordinator/internal/buyer/server.go:1722` as
one IMPL emission site. Zero new error codes.

**S-r2-1 slow-roller DoS bound: (α) wall-clock total deadline.**
Add to AC-V2-9: wall-clock total deadline reuses the existing SPEC-006
per-request deadline (cite the exact §/line). On wall-clock breach: same
behavior as idle timeout. Both conditions independently trigger; whichever
fires first wins.

## Absorption items

### Convergent (3 themes — must close all 3)

**T-r2-1: `provider_timeout` substitution (1C + 1H)**

Replace `inference_timeout` → `provider_timeout` at all four sites:

1. **AC-V2-9 (line 434):** "terminal SSE error frame using the existing
   `inference_timeout` code with retryability per SPEC-006 timeout
   semantics" → "terminal SSE error frame using the existing
   `provider_timeout` code (SPEC-006 §3221, emitted at
   `phase4-coordinator/internal/buyer/server.go:1722`) with retryability
   per SPEC-006 timeout semantics".

2. **§5 v0.2 streaming-validation paragraph (line 991):** same
   substitution.

3. **§10 v0.2.x deferral bullet (line 1344):** same substitution.

4. **§12 v0.2.1 change-log entry (line 1481):** same substitution.

5. **§5 error-code table:** verify `provider_timeout` is already listed
   in v0.1.5 LOCKED rows. If not listed, add a v0.2-amendment note row
   citing SPEC-006 §3221 as the source-of-truth. If already listed, add
   a one-line v0.2 cross-reference noting that streaming idle and
   wall-clock timeouts reuse this code.

**T-r2-2: AC-V2-3a citation widening + positive-settle site naming (1H + 1M)**

Widen citation in three places:

1. **AC-V2-3a (line 364):** current citation
   `phase5-gateway/internal/router/chat_proxy.go:493-531`. Change to
   `phase5-gateway/internal/router/chat_proxy.go:482-557` (full
   `forwardLine` closure). Add a second citation:
   `phase5-gateway/internal/router/chat_proxy.go:625-629` (positive-
   settlement path: `settleReported("ok")` and
   `settleAfterCommit(..., "ok", ...)`).

2. **§7 v0.2 streaming pass-through paragraph (~line 1194):** same
   citation widening.

3. **§8 v0.2 streaming money-path paragraph (~line 1262):** explicitly
   name the positive-settle site `:625-629` and require gateway-side
   "ok"/"positive" settlement be skipped after forwarding a terminal
   SSE error frame with `error.code ∈ {malformed_json_response,
   json_schema_validation_failed}`.

Add to AC-V2-3a, as an explicit IMPL test obligation:

> "Test: gateway MUST emit no `usage_events` row with `outcome:"ok"`
> for a stream whose terminal SSE frame carries `error.code ∈
> {malformed_json_response, json_schema_validation_failed}`. The
> gateway MUST also NOT remap the terminal frame to `stream_malformed`
> via the `!hasChoices` parse branch at
> `phase5-gateway/internal/router/chat_proxy.go:533`."

**T-r2-3: AC-V2-13 conjunctive Cline AND Vercel (2M)**

Rewrite AC-V2-13 to require BOTH fixtures:

> "AC-V2-13. Partial-content negative streaming fixture set: the
> fixture set MUST include **both** a Cline partial-content-then-
> terminal-error stream **AND** a Vercel AI SDK partial-content-then-
> terminal-error stream. Both fixtures MUST:
> - emit partial assistant content deltas (visible to the buyer's
>   parser),
> - terminate with a SSE error frame whose `error.code ∈
>   {malformed_json_response, json_schema_validation_failed}`,
> - assert that final SDK-side object parsing fails (no partial-
>   success path),
> - document the contract that partial deltas pre-validation are
>   provisional, not final."

### Singular (3 items — must close all)

**S-r2-1: AC-V2-9 wall-clock total deadline (1H)**

Amend AC-V2-9 to add the wall-clock total deadline rule, paired with
the existing idle rule. Suggested wording:

> "**Wall-clock total deadline:** the streaming structured-output
> request also fails closed when the wall-clock duration since
> request acceptance exceeds the existing SPEC-006 per-request
> deadline [cite SPEC-006 §/line — verify the exact section governing
> the per-request deadline]. On wall-clock breach: provider closes
> upstream generation, end-of-stream validation runs on the buffer-
> as-of-close, emits terminal SSE error frame using
> `provider_timeout`, settles `FaultBreakerQualifying`.
>
> **Idle vs wall-clock:** both conditions independently trigger the
> same terminal frame; whichever fires first wins. Provider MAY
> implement either via a single combined watcher or two independent
> watchers, but the buyer-visible terminal frame is identical."

Add a §11 audit hook entry asking whether the SPEC-006 deadline value
N (or N-equivalent) is fit-for-purpose for structured streaming, or
whether v0.2.x should pin a separate value.

**S-r2-2: §11 audit-hook entry for response_byte_cap_exceeded retryable drift (1M)**

Add a single bullet to §11 audit hooks:

> "**v0.1.5 LOCKED retryable drift for `response_byte_cap_exceeded`**:
> §5 error-code table marks `retryable: true`, but IMPL
> `phase4-coordinator/internal/buyer/server.go:56` marks `false`. This
> is pre-existing v0.1.5 LOCKED drift; out of v0.2 amendment scope.
> AC-V2-9b doesn't explicitly bind retryable and inherits IMPL
> semantics. Reconcile in v0.3."

**S-r2-3: AC-V2-10b RFC 8259 §6 NaN/Infinity normative clause (1M)**

Amend AC-V2-10b's `multipleOf`/`minimum`/`maximum` value-validity
sub-rules to include:

> "Per RFC 8259 §6, the JSON `number` production excludes the
> literals `NaN`, `Infinity`, `+Infinity`, and `-Infinity`. All four
> MUST reject as non-JSON-numbers via `json_schema_unsupported_keyword`
> with `error.param` pointing at the offending node. Negative fixtures
> MUST cover these four literals in addition to strings, booleans,
> null, arrays, and objects."

### Lane A + F READY closures (no action)

Both lanes returned 0/0/0. Lane F's 4 non-blocking Notes (N-1..N-4)
confirm change-log accuracy, terminology consistency, and AC numbering
hygiene. No action.

### Out-of-scope items (do NOT absorb)

- Lane E E-N-1 (`response_byte_cap_exceeded` retryable drift) — covered
  by S-r2-2 §11 deferral note only; do NOT modify the v0.1.5 LOCKED
  table row.
- Lane E E-N-2 (coord SSE writer cite is generic) — AC-V2-3a binds
  behavior, not function. Acceptable as-is. No action.

## Output requirements

- Edit `specs/SPEC-019-structured-output.md` in-place.
- Bump version header (line 3) and §12 metadata to
  **0.2.2 (2026-06-29, r2-absorption draft for audit)**.
- Add v0.2.2 change-log entry to §12. Summarize T-r2-1..T-r2-3 +
  S-r2-1..S-r2-3 in one paragraph. Cite the audit narrative file
  `specs/SPEC-019-v0_2-r2-audit.md` for traceability.
- Status remains `DRAFT — audit loop pending`.
- DO NOT commit. The r3 audit will fire against this draft; absorber
  leaves the working tree dirty.
- Reasoning effort: **low** (mechanical text edits with exact file:line
  targets per item above).
