# SPEC-001 v1.1 Re-audit Report

Auditor: Codex GPT-5
Prior audit: `specs/SPEC-001-audit.md`
Re-audit completed: 2026-05-26T23:39:00Z

## TL;DR verdict

**NEEDS MAJOR REVISION.** v1.1 is a substantial improvement: 23 original
findings are addressed, 3 are knowingly or appropriately deferred, and the
three operator questions are resolved. However, 2 original MAJOR findings
remain not addressed (`B2`, `H1`) and the revision introduced 3 MAJOR and 3
MINOR regressions. The blockers are narrow: fix the heartbeat field mismatch,
pin `mlx-swift-lm` to an actual tag/commit, remove the `stream_options` open
question ambiguity, and tighten a few status/test-command inconsistencies.

## Part 1 — Prior Findings Verification Table

| Finding | Severity | v1.1 status | Section ref | Note |
|---|---|---|---|---|
| D1 | CRITICAL | ADDRESSED | § 7.2 | License policy now records "SPDX NOASSERTION" and strict clean-room text. |
| E1 | CRITICAL | ADDRESSED | § 6.2 | Request schema now has required fields, optional fields, message validation, tool validation, and validation order. |
| A1 | MAJOR | DEFERRED | § 8 D1; implementation-notes | Backoff and `cfd_tunnel` polling are explicitly deferred to SPEC-002. |
| A2 | MAJOR | DEFERRED | § 8 D4; implementation-notes | Buyer-facing model choice / latency-quality routing deferred to SPEC-002. |
| A4 | MAJOR | ADDRESSED | § 6.2 Tool-call validation | Malformed tool/tool_call shapes now reject with 400 instead of being silently ignored. |
| A5 | MAJOR | ADDRESSED | § 9 AC-2 | AC-2 says "NO HTTP 500 responses" and 500/process crash is hard failure. |
| B2 | MAJOR | NOT ADDRESSED | § 4 FR-17; § 6.5 heartbeat | FR-17 still names `current_slots_free`; heartbeat schema uses `slots_free`/`slots_total`. |
| B3 | MAJOR | ADDRESSED | § 6.5 State update | `state_update` message shape added. |
| B4 | MAJOR | ADDRESSED | § 6.5 Drain status | `drain_status` provider-to-coordinator message shape added. |
| B5 | MAJOR | ADDRESSED | § 2, § 7.1, § 10 | `coordinator_token` removed; provider auth deferred to SPEC-002. |
| B6 | MAJOR | ADDRESSED | § 9 AC-6..AC-10 | New ACs cover drain, warm-up, health, config precedence, startup failure. |
| C1 | MAJOR | ADDRESSED | § 3; FR-8 | Tier 2 decrypt now precedes token-count pre-flight. |
| E2 | MAJOR | ADDRESSED | § 6.0, § 6.4, § 6.5 | Global HTTP errors, streaming errors, health 503, and `nak` added. |
| E3 | MAJOR | ADDRESSED | § 6.5 preflight | Rejection reason enum added. |
| F1 | MAJOR | ADDRESSED | § 9 | Every AC has a "Run by" line, though some are still manual; see minor regression R-MINOR-2. |
| G2 | MAJOR | ADDRESSED | § 10 | Hidden `coordinator_token` directive removed. |
| H1 | MAJOR | NOT ADDRESSED | § 7.1 | `mlx-swift-lm` still says "Pin to latest stable tag at build time"; no tag/commit is pinned. |
| H2 | MAJOR | ADDRESSED | § 6, § 7.1, § 9 | Implementability is now within <=3 clarifications; see Part 3. |
| I1 | MAJOR | ADDRESSED | § 8 D4 | Coordinator routing language softened to "MAY use" / deferred to SPEC-002. |
| A3 | MINOR | ADDRESSED | § 8 D5 | Timeline compression marked process-only with rationale. |
| A6 | MINOR | KNOWINGLY DEFERRED | implementation-notes | Build-sequence wording retained; literal `swift build` command removed. |
| B1 | MINOR | ADDRESSED | FR-4 | SSE wording now allows chunked transfer as normal. |
| C2 | MINOR | ADDRESSED | § 2 | Secure-enclave key derivation removed from Tier 2 scope list. |
| C3 | MINOR | ADDRESSED | § 6.2 | `content_filter` removed from Tier 1 finish_reason contract. |
| D2 | MINOR | ADDRESSED | § 7.2, Appendix A | d-inference refs replaced by strict clean-room policy and transparency note. |
| F2 | MINOR | ADDRESSED | § 9 intro | "AC-1 through AC-10 must ALL pass" added. |
| G1 | MINOR | ADDRESSED | § 10; FR-11; FR-19; NFR-7 | Open questions trimmed; defaults moved into requirements. |
| I2 | MINOR | ADDRESSED | § 2, § 7.1 | Provider auth fully deferred to SPEC-002. |
| Q1 | QUESTION | RESOLVED | § 2, § 7.1 | Auth deferred to SPEC-002; no `coordinator_token` in spec. |
| Q2 | QUESTION | RESOLVED | § 9 AC-2 | HTTP 500 is a hard adversarial failure. |
| Q3 | QUESTION | RESOLVED | § 3; FR-8 | Decrypt-before-token-preflight is now a hard architecture constraint. |

Counts: 23 addressed, 3 deferred, 2 not addressed. Questions: 3 resolved.

## Part 2 — Regressions Found

### CRITICAL Regressions (0)

None.

### MAJOR Regressions (3)

**R-MAJOR-1 — R2/B2 field rename was not propagated: `current_slots_free` vs `slots_free`.**

Spec quote, FR-17: "`current_slots_free`: real-time availability"

Spec quote, § 6.5 heartbeat:
`"slots_free": 1, "slots_total": 2`

What it conflicts with: the v1.1 fix prompt required the heartbeat schema to
include every field FR-17 names, including `current_slots_free`. This is still
the same class of contract mismatch as original B2.

**R-MAJOR-2 — R3/E1 `stream_options.include_usage=false` remains an open question despite a pinned default.**

Spec quote, § 10: "If a client sends `stream_options: {include_usage: false}`, should the binary respect this and omit the usage chunk?"

Spec quote, § 6.2: "`stream_options` ... `{include_usage: bool}`. See FR-7."

What it conflicts with: the fix prompt required `stream_options.include_usage`
to be true when `stream=true` because FR-7 always emits usage. v1.1 says the
spec picks "always emit usage" but still asks the operator to confirm. This
leaves a build-time ambiguity in a wire-contract field.

**R-MAJOR-3 — R8/H1 `mlx-swift-lm` is not pinned even though a current tag exists.**

Spec quote, § 7.1: "Pin to latest stable tag at build time; record tag + commit SHA in implementation-notes.html"

Evidence: GitHub tag/release lookup found `mlx-swift-examples` tag `2.29.1`
at commit `9bff95ca5f0b9e8c021acc4d71a2bbe4a7441631`.

What it conflicts with: H1 required pins before the build session starts. The
most important dependency is still deferred to implementation time.

### MINOR Regressions (3)

**R-MINOR-1 — R2 health-state vocabulary mixes `healthy` with actual `ready` state.**

Spec quote, FR-18: "Returns 200 when healthy"

Spec quote, § 6.4: `"status": "ready"`

Spec quote, § 6.5: "`state` is one of `ready`, `busy`, `degraded`, `draining`, `unavailable`."

Problem: "healthy" is prose, not an enum value, but AC-2 and AC-8 also say
"passes health with 200" / "when healthy." This is unlikely to block a build,
but it can cause assertion drift in tests.

**R-MINOR-2 — R9 AC-6, AC-7, and AC-9 still lack exact reusable commands.**

Spec quotes:
- AC-6: "Manual test during build."
- AC-7: "Send `warm_up` via mock coordinator"
- AC-9: "Manual test during build with 4 invocations."

Problem: F1 is mostly fixed, but these still require the implementer to invent
repeatable commands. That is acceptable for v1.1 only if the build session
turns them into scripts immediately.

**R-MINOR-3 — Clean-room § 7.2 replacement is not text-exact.**

Spec quote, § 7.2 heading: "### 7.2. Reference hygiene — strict clean-room for d-inference"

Fix prompt quote: "### 7.2 Reference hygiene — strict clean-room for d-inference"

Problem: The content is materially correct, but the prompt required an exact
replacement. This is a low-risk formatting mismatch.

## Part 3 — Implementability Verdict

### H1 v2 — Dependency Pins

| Dependency | v1.1 status | Verification |
|---|---|---|
| `mlx-swift-lm` / `mlx-swift-examples` | NOT PINNED | v1.1 defers tag/commit to build time. GitHub shows tag `2.29.1` exists at `9bff95ca5f0b9e8c021acc4d71a2bbe4a7441631`. |
| `swift-nio` | PINNED | GitHub tag `2.65.0` exists at `359c461e5561d22c6334828806cc25d759ca7aa6`. |
| `swift-log` | PINNED | GitHub tag `1.6.0` exists at `b3a637307772d20291d78a5b7a0d4204d9b1e981`. |
| `swift-argument-parser` | PINNED | GitHub tag `1.5.0` exists at `41982a3656a71c768319979febd796c6fd111d5c`. |
| `Yams` | PINNED | GitHub tag `5.1.0` exists. |

H1 v2 result: **NOT PASSING** until `mlx-swift-lm` is pinned in SPEC-001.

### H2 v2 — Remaining Clarifications

A competent Swift implementer can probably start after <=3 clarifications:

1. What exact `mlx-swift-examples` tag/commit should be used?
2. If `stream=true` and `stream_options.include_usage=false`, should the binary reject 400 or ignore the client preference and still emit usage?
3. Should `current_slots_free` be the heartbeat field name, or should FR-17 be renamed to `slots_free`/`slots_total`?

H2 v2 result: **PASSING with caveats**. This is now within the <=3 question
bar, but those questions should be patched before build handoff.

## Coverage Matrix Delta

| Decision log row | v1.0 audit status | v1.1 status |
|---|---|---|
| 502 vs 530 routing | Partial | Covered for binary scope; coordinator backoff/tunnel polling deferred to SPEC-002. |
| Post-wake throughput dip | Covered | Covered. |
| Stop-token leakage status | Covered | Covered. |
| Cross-provider throughput inversion | Partial | Covered for binary scope; buyer-facing routing/model choice deferred to SPEC-002. |
| Timeline compression | Uncovered | Process-only with explicit rationale. |

Net: the coverage matrix is now complete for SPEC-001's binary scope.

## What v1.1 Did Well

1. The Tier 2 request-chain ordering is now explicit and correct: decrypt
   happens before token-count pre-flight.
2. The coordinator wire protocol is much more implementable: `state_update`,
   `drain_status`, negative ack, and preflight rejection reasons are specified.
3. The adversarial acceptance criteria now disallow HTTP 500, which closes the
   biggest test-quality hole from v1.0.
4. The d-inference policy is now conservative and clean-room aligned.
5. Section 6.2 is much closer to an actual implementable request contract.

## Final Verdict Recommendation

**NEEDS MAJOR REVISION** — run a narrow `FIX_SPEC_001_V1_2` round.

Patch these before binary build:

1. Resolve `current_slots_free` vs `slots_free` by using one field name
   consistently in FR-17, heartbeat, health, and tests.
2. Pin `mlx-swift-lm` / `mlx-swift-examples` to a concrete tag and commit SHA.
3. Remove OQ-2 by making `stream_options.include_usage=false` behavior explicit:
   reject it with 400 or ignore it and always emit usage.
4. Optional but cheap: normalize "healthy" prose to `ready` where assertions
   depend on enum state, and replace manual AC run lines with script names or
   concrete commands.

