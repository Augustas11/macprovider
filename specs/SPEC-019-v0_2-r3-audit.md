# SPEC-019 v0.2.2 — Round 3 audit narrative

**Anchor:** `spec/019-v0-2-streaming` @ `c0aa2a9`
**Audited SPEC:** `specs/SPEC-019-structured-output.md` v0.2.2 (r2-absorption DRAFT)
**Round:** r3
**Lanes:** 4 codex (architect, code, security, product-design) + 2 Claude blind-spot (critic, narrative)

## Per-lane verdicts

| Lane | Verdict | C | H | M |
|---|---|---|---|---|
| A architect (codex) | READY TO LOCK | 0 | 0 | 0 |
| B code (codex) | READY TO LOCK | 0 | 0 | 0 |
| C security (codex) | NEEDS REVISION | 0 | 0 | 1 |
| D product-design (codex) | NEEDS REVISION | 0 | 0 | 1 |
| E critic (Claude) | NEEDS REVISION | 0 | 3 | 1 |
| F narrative (Claude) | READY TO LOCK | 0 | 0 | 0 |

**Totals: 0 CRITICAL, 3 HIGH, 3 MEDIUM.** A + B + F clean.

## Convergent root cause: wall-clock authority is mythical

Three findings (E-H-2, E-M-1, C-r3-M-1) are three angles on the same hole.
r2 absorption claimed "reuse existing SPEC-006 `coordinator_request_seconds`
per-request deadline" — but:

- SPEC-006 §17.5 / `:2605` defines `provider_timeout` (✓ E-N confirmed via
  Lane E verification).
- SPEC-006 has **zero normative prose** defining what
  `coordinator_request_seconds` actually bounds. The field appears exactly
  once at `:2434` inside a YAML config example.
- The phrases "wall-clock", "per-request deadline", "request deadline" do
  not appear anywhere in SPEC-006.

SPEC-019 v0.2.2 invented wall-clock semantics in the prose surrounding the
citation. The "reuse existing" framing is false.

Layered consequence: AC-V2-9 says provider closes upstream generation on
wall-clock breach (E-M-1: provider cannot observe a gateway-rooted
deadline), and current gateway IMPL emits `provider_disconnected` +
`stream_truncated` if it hits the timeout first (C-r3-M-1: gateway path
diverges from required `provider_timeout` + FaultBreakerQualifying).

## Findings

### E-H-1: SPEC-006 §3221 citation is malformed

SPEC-006 section numbering is **§3.1 through §3.11** (verified via grep on
`^### `). There is no §3221. The number was interpreted as a line number,
which lands inside `AC-36: quota refund on 504 with zero completion tokens`
(verification scenario at lines 3215-3225), not the definitional site.

**Actual definition: §17.5 / `specs/SPEC-006-buyer-api.md:2605`** ("If
provider exceeds timeout, return 504 before response headers are sent.
Code: `provider_timeout`").

Affected sites (4): AC-V2-9 line 444, §5 idle/wall-clock paragraph
line ~1020, §5 v0.2 error-code amendment line ~1068, §11 audit-hook 16
cross-text.

**Resolution:** rewrite all four `SPEC-006 §3221 / specs/SPEC-006-buyer-api.md:3221`
→ `SPEC-006 §17.5 / specs/SPEC-006-buyer-api.md:2605`.

### E-H-3: server.go:1722 is the wrong site for streaming

`:1722` uses `writeError` (HTTP 504 JSON body) — the WS-non-streaming
path. The streaming SSE `provider_timeout` emit is `writeSSEError(...
"provider_timeout")` at **`:2386`**. r2 narrative listed 4 sites;
absorber picked the only one that doesn't match the streaming surface
AC-V2-9 governs.

**Resolution:** cite `phase4-coordinator/internal/buyer/server.go:2386`
as the streaming `provider_timeout` SSE emit site.

### E-H-2 + E-M-1 + C-r3-M-1: wall-clock authority

Three convergent findings:

- **E-H-2:** `coordinator_request_seconds` cited as deadline authority,
  but SPEC-006 has no normative prose for it.
- **E-M-1:** AC-V2-9 "wall-clock since request acceptance" — provider
  can't observe a gateway-rooted event; actor + temporal anchor undefined.
- **C-r3-M-1:** Gateway already applies same 300s; if it fires first,
  emits `provider_disconnected` + `stream_truncated`, not
  `provider_timeout` + FaultBreakerQualifying.

**Resolution (Decision 1A — locked-in design call):**

SPEC-019 v0.2.2 **defines its own wall-clock semantics** rather than
claiming reuse from SPEC-006. Concrete rewrite:

- Wall-clock deadline value: 300s (matches `coordinator_request_seconds`
  config field by **convention**, not by SPEC-006 normativity).
- **Authority: gateway.** Gateway owns the watcher.
- Zero-point: gateway-side first-byte-of-request (already observable in
  current IMPL).
- Gateway emits terminal SSE error frame with `error.code =
  provider_timeout` + `FaultBreakerQualifying` settlement on breach,
  **including** when no downstream provider has produced the terminal
  frame yet.
- Provider idle timeout (existing AC-V2-9 idle clause) is a separate,
  provider-owned watcher; provider closes upstream generation on idle
  breach. Either authority can fire first.
- Closes C-r3-M-1 by promoting gateway-as-timeout-source from "fail
  condition" to "intended behavior under the gateway-emit-provider_timeout
  branch", AND requires the gateway IMPL change: route SPEC-019 streaming
  timeouts through `provider_timeout` + skip ok/positive settlement, not
  through `provider_disconnected` + `stream_truncated`.

This contradicts the r2 "reuse existing" framing but maps cleanly to
the IMPL surface (gateway already has the timeout, just needs to route
SPEC-019 codes correctly).

### D-r3-M-1: AC-V2-10b NaN/Infinity unobservable through normal request bodies

NaN/Infinity literals are invalid JSON tokens — they trip the
`json.Unmarshal` parse layer first (coordinator
`server.go:3467-3471`, provider `ChatCompletionRequest.swift:22-27`)
and surface as HTTP 400 `invalid_json`, **never reaching schema
validation**. AC-V2-10b's requirement that they reject via
`json_schema_unsupported_keyword` is unbuildable as a fixture.

**Resolution (Decision 2α — locked-in design call):**

Acknowledge `invalid_json` is the actual envelope. Amend AC-V2-10b:

- NaN, Infinity, +Infinity, -Infinity at numeric-bound positions are
  excluded from JSON grammar per RFC 8259 §6.
- Buyer-visible envelope is HTTP 400 `invalid_json` from the
  request-body parse layer, NOT `json_schema_unsupported_keyword`.
- Negative fixtures MUST assert `invalid_json` for these four literals.
- Schema-keyword rejection envelope (`json_schema_unsupported_keyword`)
  remains buyer-visible only for non-numeric operand types (strings,
  booleans, null, arrays, objects).

## r2 closures verified

- **T-r2-1** `provider_timeout` substitution: complete at 4 surface
  sites; `inference_timeout` count = 0. **But** citation §/line targets
  wrong — see E-H-1/E-H-3.
- **T-r2-2** AC-V2-3a gateway citation widening: CLEAN. `:482-557` and
  `:625-629` both cited; `usage_events outcome:"ok"` test obligation
  reads normative.
- **T-r2-3** AC-V2-13 conjunctive Cline AND Vercel: CLEAN. "Both ...
  AND" load-bearing; fail condition explicitly rejects single fixture.
- **S-r2-1** wall-clock total deadline: PARTIAL — three angles open
  (E-H-2, E-M-1, C-r3-M-1).
- **S-r2-2** §11 audit-hook 16 deferral: CLEAN. IMPL line cite
  `server.go:56` accurate.
- **S-r2-3** AC-V2-10b RFC 8259 §6 clause: PARTIAL — NaN/Infinity
  buyer-visible envelope (D-r3-M-1).

## Citation drift summary

The r2 absorption pass introduced **three phantom citations** in the
wall-clock surface:

1. `SPEC-006 §3221` — malformed (§3.X scheme has no §3221) → must be
   `§17.5`.
2. `coordinator_request_seconds` semantics — undefined in SPEC-006.
3. `server.go:1722` — wrong site for streaming surface.

Net citation cost of r2 absorption: traded one phantom code
(`inference_timeout`) for three phantom citations. v0.2.3 retargets.

## r3 absorption plan

**r3 absorption target version:** v0.2.3

**Convergent absorption (1 theme):**
- E-H-1 + E-H-3 + E-H-2 + E-M-1 + C-r3-M-1: wall-clock authority
  rewrite. SPEC-019 defines its own wall-clock semantics, gateway-owned,
  cites SPEC-006 §17.5 / :2605 only for the `provider_timeout`
  definition. server.go citation corrected to :2386.

**Singular absorption (1 item):**
- D-r3-M-1: AC-V2-10b NaN/Infinity buyer-visible envelope = HTTP 400
  `invalid_json`; non-numeric operand rejection envelope remains
  `json_schema_unsupported_keyword`.

**Lane A + B + F (READY TO LOCK at r3):** no action.

**Lock convention:** 0 CRITICAL + 0 HIGH + 0 MEDIUM across all 6 lanes.

## Per-lane round files

- Lane A codex artifact: `codex-spec-019-v0-2-2-...2026-06-29T08-09-22-360Z.md`
- Lane B codex artifact: `codex-spec-019-v0-2-2-...2026-06-29T08-09-56-456Z.md`
- Lane C codex artifact: `codex-spec-019-v0-2-2-...2026-06-29T08-10-14-072Z.md`
- Lane D codex artifact: `codex-spec-019-v0-2-2-...2026-06-29T08-10-34-233Z.md`
- Lane E Claude agent: `tasks/a170737bec1f124ff.output`
- Lane F Claude agent: `tasks/a4239223f16722bbc.output`
