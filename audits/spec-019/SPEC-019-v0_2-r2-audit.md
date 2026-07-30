# SPEC-019 v0.2.1 — Round 2 audit narrative

**Anchor:** `spec/019-v0-2-streaming` @ `a977b28`
**Audited SPEC:** `specs/SPEC-019-structured-output.md` v0.2.1 (r1-absorption DRAFT)
**Round:** r2
**Lanes:** 4 codex (architect, code, security, product-design) + 2 Claude blind-spot (critic, narrative)

## Per-lane verdicts

| Lane | Verdict | C | H | M | Notes |
|---|---|---|---|---|---|
| A architect (codex) | READY TO LOCK | 0 | 0 | 0 | T-1 + T-4 closed; cross-spec consistency clean |
| B code (codex) | NEEDS REVISION | 0 | 1 | 1 | inference_timeout undefined, response_byte_cap_exceeded retryable conflict |
| C security (codex) | NEEDS REVISION | 0 | 1 | 0 | Slow-roller DoS — provider emits 1 token every N-1s |
| D product-design (codex) | NEEDS REVISION | 0 | 0 | 1 | AC-V2-13 disjunctive vs r1 conjunctive intent |
| E critic (Claude) | NEEDS REVISION | 1 | 1 | 3 | inference_timeout phantom, gateway citation under-bounded, NaN/Infinity silent |
| F narrative (Claude) | READY TO LOCK | 0 | 0 | 0 | Change-log accurate; AC numbering hygiene clean |

**Totals: 1 CRITICAL, 3 HIGH, 5 MEDIUM.** A + F clean.

## Convergent themes

### T-r2-1: `inference_timeout` phantom code (1C + 1H — E-C-1, B-r2-H-1)

AC-V2-9, §5 v0.2 streaming-validation paragraph, §10 v0.2.x deferral bullet,
and §12 v0.2.1 change-log all reference "the existing `inference_timeout`
code". **No such code exists.** E grepped IMPL + all SPECs (excluding
SPEC-019); B grepped IMPL — both confirmed 0 hits. The r1 narrative
offered "new `streaming_validation_timeout` OR existing
`inference_timeout`"; the absorber picked the latter but neither
candidate is real.

**Resolution:** (A) — substitute existing `provider_timeout`.

- HTTP 504, defined in SPEC-006 §3221
- Emitted at `phase4-coordinator/internal/buyer/server.go:1722/1949/2386/3455`
- Retryability already defined in IMPL
- Zero new codes added; matches v0.2.1 change-log "no new error codes"
  implied scope

Update sites:
- AC-V2-9 (line 434): replace "existing `inference_timeout`" →
  "existing `provider_timeout`"
- §5 v0.2 streaming-validation paragraph (line 991)
- §10 v0.2.x deferral bullet (line 1344)
- §12 v0.2.1 change-log entry (line 1481)
- §5 error-code table: add a one-line "v0.2 streaming idle timeout
  reuses `provider_timeout`" cross-reference row (or footnote on the
  existing row if `provider_timeout` is already listed; verify against
  table)

### T-r2-2: AC-V2-3a gateway citation under-bounds money-path surface (1H + 1M — E-H-1, E-M-1)

Citation `chat_proxy.go:493-531` covers the upstream-parse-error remap
at `:499` but misses two sites:

1. The `!hasChoices` `stream_malformed` remap at `:533` (off-by-2; SSE
   error frame parses OK but has no `choices`).
2. The positive-settlement path at `:625-629` (`settleReported("ok")`
   / `settleAfterCommit(..., "ok", ...)`).

An IMPL that suppresses `stream_malformed` remap on `:493-531` only
will still:
- Remap via `:533` (terminal SSE error frame has no `choices` →
  `stream_malformed`).
- Emit positive "ok" settlement at `:625-629` after the verbatim
  forward (double-settle vs FaultBreakerQualifying).

**Resolution:** widen citation in AC-V2-3a, §7 v0.2 streaming
pass-through paragraph, and §8 v0.2 streaming money-path paragraph to
include the `forwardLine` closure body in full
(`chat_proxy.go:482-557`) AND name the positive-settlement site
explicitly (`:625-629`). Add a unit-test requirement: gateway emits
NO `usage_events` row with `outcome:"ok"` for a stream whose terminal
SSE frame carries `error.code ∈ {malformed_json_response,
json_schema_validation_failed}`.

### T-r2-3: AC-V2-13 disjunctive weakens r1 S-4 intent (2M — D-r2-M-1, E-M-2)

AC-V2-13 reads "The fixture, preferably Cline or Vercel" —
disjunctive, singular. r1 narrative S-4 required **Cline AND Vercel**
because each ecosystem has independent SDK parser behavior on
partial-then-error streams.

**Resolution:** rewrite AC-V2-13 to require both fixtures explicitly:
"The fixture set MUST include both a Cline partial-content-then-
terminal-error stream AND a Vercel AI SDK partial-content-then-
terminal-error stream."

## Singular findings

### S-r2-1: Slow-roller DoS bound (1H — C-r2-H-1)

AC-V2-9 binds idle timeout to "no buyer-visible content delta for N
seconds". A provider emitting 1 tiny content delta every N-1 seconds
never trips idle. Resource hold + no settlement finality.

**Resolution:** (α) — wall-clock total deadline.

Add to AC-V2-9:
- Wall-clock total deadline reuses the existing SPEC-006 request
  deadline (cite the exact §/line in SPEC-006). On wall-clock breach:
  provider closes upstream generation, end-of-stream validation runs
  on the buffer-as-of-close, emits terminal SSE error frame using
  `provider_timeout`, settles `FaultBreakerQualifying`.
- Both idle AND wall-clock conditions independently trigger the same
  terminal frame; whichever fires first wins.

### S-r2-2: response_byte_cap_exceeded retryable conflict (1M — B-r2-M-1, E-N-1)

SPEC-019 §5 table row marks `retryable: true`; IMPL
`spec018RetryableByCode["response_byte_cap_exceeded"] = false`.
E flags this as pre-existing v0.1.5 LOCKED drift.

**Resolution:** OUT OF v0.2 SCOPE. The §5 table row is in v0.1.5
LOCKED text — cannot modify. AC-V2-9b doesn't explicitly bind
retryable, so it inherits IMPL semantics (`false`). Add a one-line
note to §11 audit hooks deferring reconciliation to v0.3.

### S-r2-3: NaN / ±Infinity silent in AC-V2-10b (1M — E-M-3)

AC-V2-10b says "non-number JSON values reject" but doesn't pin RFC
8259 §6 grammar. Different parsers tolerate NaN/Infinity differently.

**Resolution:** add to AC-V2-10b: "Per RFC 8259 §6, the JSON `number`
production excludes NaN, +Infinity, and -Infinity. All three MUST
reject as non-JSON-numbers with `json_schema_unsupported_keyword`.
Negative fixtures MUST cover these three literals in addition to
strings/booleans/null/array/object operands."

## r1 closures verified

- **T-1 (1C+2H)** partial closure: gateway verbatim-forward + remap
  forbidden CLEAN; coord SSE writer settlement_ran CLEAN; provider WS
  end-frame status CLEAN. **Gap:** positive-settle path (T-r2-2).
- **T-2 (3H+1M):** timeout source bound to provider idle CLEAN; but
  code citation invalid (T-r2-1).
- **T-3 (2H+1M):** numeric value validity CLEAN. multipleOf:0,
  negative, non-number, inverted bounds all covered.
- **T-4 (1H+1M):** numeric-bound type gate CLEAN. AC-V2-10a covers all
  non-numeric node types.
- **S-1 byte cap:** CLEAN. Post-stop-token-filter buyer-visible delta
  concatenation pinned.
- **S-2 error-code table split:** CLEAN. v0.1.x rows annotated.
- **S-3 AC-V2-5:** CLEAN. Cline commit + outbound POST byte capture +
  `stream:true` assertion.
- **S-4 AC-V2-13:** PARTIAL. Exists but disjunctive language (T-r2-3).
- **S-5 AC-V2-12:** CLEAN. Lane D confirmed via live capture.
- **S-6 `$schema` cap/hash:** CLEAN.
- **S-7 AC-V2-14:** CLEAN. Composite-render streaming invariant
  pinned.

## Citation drift

- E-M-1: AC-V2-3a citation `chat_proxy.go:493-531` off-by-2; should
  extend through `:540` minimum or `:482-557` for full forwardLine
  closure. Absorbed in T-r2-2.
- Otherwise no drift.

## r2 absorption plan

**r2 absorption target version:** v0.2.2

**Convergent absorption (3 themes):**
- T-r2-1: `provider_timeout` substitution (4 sites)
- T-r2-2: AC-V2-3a citation widening + positive-settle site naming
- T-r2-3: AC-V2-13 conjunctive Cline AND Vercel

**Singular absorption (3 items):**
- S-r2-1: Wall-clock total deadline in AC-V2-9 (α)
- S-r2-2: §11 deferral note for `response_byte_cap_exceeded` retryable
  drift to v0.3
- S-r2-3: AC-V2-10b RFC 8259 §6 NaN/Infinity normative clause

**Lock convention:** 0 CRITICAL + 0 HIGH + 0 MEDIUM across all 6
lanes.

## Per-lane round files

- `specs/SPEC-019-v0_2-architect-r2-audit.md` (codex artifact 07:46:38)
- `specs/SPEC-019-v0_2-code-r2-audit.md` (codex artifact 07:47:57)
- `specs/SPEC-019-v0_2-security-r2-audit.md` (codex artifact 07:47:22)
- `specs/SPEC-019-v0_2-product-design-r2-audit.md` (codex artifact 07:47:49)
- `specs/SPEC-019-v0_2-critic-r2-audit.md` (Claude critic agent)
- `specs/SPEC-019-v0_2-narrative-r2-audit.md` (Claude narrative agent)
