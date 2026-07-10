# SPEC-018 v0.2.0 — Round 1 Audit Narrative

**Date:** 2026-06-27
**Round:** 1
**Lanes:** architect / code / security / product-design (codex 4-lane per [[feedback-three-lane-codex-audits]])
**Verdict:** **FIX REQUIRED — all 4 lanes**

## Aggregate tally

| Lane | C | H | M | m | Q |
|---|---|---|---|---|---|
| Architect | 0 | 3 | 3 | 1 | 1 |
| Code | 0 | 4 | 2 | 0 | 1 |
| Security | **1** | 3 | 3 | 2 | 2 |
| Product-Design | 0 | 4 | 3 | 1 | 2 |
| **Total** | **1** | **14** | **11** | **4** | **6** |

Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM. Current round: well above. This is the largest first-round tally in the SPEC-018 family (v0.1 r1 was 2C+5H+13M; v0.2 r1 is 1C+14H+11M — higher H, lower C). The H concentration reflects the scope-narrowing-vs-locked-invariants tension that v0.2.0 inherited from the design synthesis.

## Convergent findings (3+ lanes agreed)

| Finding | Lanes | DRAFT-NOTES predicted? |
|---|---|---|
| **§10a / §10c contradictions with v0.2 narrowing** (especially v0.1.3-locked §10c model-hash invariant) | Architect H-1 / Security H-1 / Product-Design M-1 | Yes (DRAFT-NOTE #3) |
| **Failure-table vs AC-32 code mismatch** (missing `tool_call_id` → two normative codes) | Architect H-3 / Code H-2 / Security m-1 | Yes (DRAFT-NOTE #2) |
| **Duplicate §3.7 heading** | Architect M-1 / Product-Design minor-1 | Yes (DRAFT-NOTE #1) |
| **AC-25 release-gate not mechanically reproducible** | Code H-4 / Product-Design HIGH-1 | No |
| **Operator kill switch invisibility to buyers** | Security M-3 / Product-Design HIGH-3 | No |

## Lock-blocker: Security C-1 — final-close settlement leak

`§8.4.2` final-close validator only verifies JSON shape + caps. **A provider can emit a syntactically-valid argument object and EOF before `finish_reason:"tool_calls"` and `data: [DONE]`** — under v0.2.0 as written, an implementation could settle non-zero credits on incomplete streaming output. The existing money-path is safe only if `FaultBreakerQualifying` flag is set; v0.2.0 doesn't mandate setting it on incomplete-terminal states. **Settlement leak**.

Existing live code already distinguishes: `server.go:2239-2255` sets `FaultBreakerQualifying` on WS post-commit disconnect; `server.go:2476-2487` sets it on direct-HTTP post-commit disconnect; `server.go:2469-2471` allows clean EOF success. v0.2.0 final-close MUST explicitly define what makes EOF "clean" for tool-call streaming. (Code lane independently asked the same question as Q-1.)

## Strategic decision recorded: Path B for §10c invariant tension

Three paths were surfaced for resolving the locked v0.1.3 §10c "v0.2 MUST fail closed on unknown model_hash" invariant against the narrow v0.2.0 scope (which defers the model-hash registry to v0.3):

- **(A)** Add minimal binary-baked hash → family table to v0.2.0; satisfies §10c without full registry-curation work.
- **(B)** Explicitly reopen §10c as part of v0.2.0; document as deliberate lock-amendment in change log.
- **(C)** Walk back narrow scope, include full deliverable #2 in v0.2.0.

**User decision (2026-06-27):** **Path B**. The narrow v0.2.0 ships as designed; §10c v0.1.3-locked clause re model-hash registry is explicitly amended in v0.2.0 to defer to v0.3. This is a deliberate lock-amendment (NOT a silent scope cut). The change log MUST narrate the amendment with rationale.

Precedent set: locked invariants are NOT immutable but require an explicit named change-log entry to amend, with rationale. Future SPEC-018 versions may invoke the same pattern if scope-vs-invariant tension arises.

## Per-lane summary

**Architect** (3H + 3M + 1m + 1Q) — 3 HIGHs all concern version-narrative coherence: (H-1) §10a/§10c contradictions, (H-2) AC-14 v0.1.5 fail vs v0.2 success criterion both active, (H-3) failure-table vs AC-32 code mismatch. Mediums on duplicate §3.7, §4 buffered-streaming voice, AC-23s alias collision. All editorially absorbable.

**Code** (4H + 2M + 1Q) — (H-1) §3.7 not byte-specifiable enough to implement or test (no Qwen/Llama prompt-template golden fixtures); (H-2) failure-table vs AC-32 code; (H-3) several code citations off by N>5 lines (`ModelRuntime.swift:344`/`:395` should be `:353`/`:403`; `server.go:2119` should be `:2103` with byte-write at `:2149`; `server.go:1234` should be `:1241-1245`); (H-4) AC-25 / AC-44 / AC-45 lack reproducible fixture/observable definitions. Q-1 asks final-close to require `finish_reason:"tool_calls"` (same theme as Security C-1). Verified the live-repo claim that current `server.go:2674` validator is incompatible with OpenAI incremental fragments.

**Security** (1C + 3H + 3M + 2m + 2Q) — Top lane by severity. C-1 (settlement leak) detailed above. H-1 (model-hash invariant violation) drove the Path B decision. H-2 (prompt-echo guard deferral leaves realistic Cline same-family echo attack via untrusted repo files / tool outputs). H-3 (mid-stream SSE error not proven safe against partial tool-call dispatch by OpenAI clients). MEDIUMs on request-side DoS aggregate caps, buyer-fabricated history provenance language, operator kill switch state visibility.

**Product-Design** (4H + 3M + 1m + 2Q) — HIGH-1 (AC-25 is a manual demo, not a release gate; split into CI fixture + manual recording); HIGH-2 (1500 ms TTFMO bound not externally auditable from Cline recording alone — need provider-side timestamps + M-class benchmark justification); HIGH-3 (operator kill switch invisible to buyers); HIGH-4 (v0.2 error envelopes too thin for Cline to act on — need code/retryable/request_id/inference_ran/settlement_ran fields). MEDIUMs on §10a-vs-§10d reader confusion, framework-compatibility narrative, AC-25 legacy-vs-current Cline tool names.

Cline-doc note (PD audit): current ClineCore tools are `bash`, `editor`, `read_files`, `apply_patch`, `search`; AC-25 names legacy aliases `read_file`, `write_to_file`, `execute_command`, `list_files`, `search_files`. Both are valid Cline surfaces — release gate must specify which is being tested with mapping.

## Absorption plan → v0.2.1

Bundling all findings into a single v0.2.1 absorption pass. The §10c amendment (Path B) is the load-bearing change; everything else follows from it or is editorial.

**Load-bearing edits:**

1. **§10c v0.2.0 amendment** (Path B) — explicit change-log entry naming §10c amendment, with rationale. Note that #2 registry curation is v0.3.
2. **§8.4.2 final-close tightening** (closes Security C-1 + Code Q-1) — every opened tool_calls[].index has terminal arg string + `finish_reason:"tool_calls"` emitted + transport-completion marker reached + no disconnect/timeout/relay error after incremental-open. Absence = `FaultBreakerQualifying` + zero credits + no receipt.
3. **§8.4.3 forbid `finish_reason:"tool_calls"` on final-close failure** (closes Security H-3) — terminal-error SSE event MUST NOT carry that finish_reason; OpenAI SDKs surface as exception, not successful assistant message with dispatchable tool_calls.
4. **Minimal v0.2 prompt-echo guard** (closes Security H-2) — if the complete native sentinel+body+close sequence appears verbatim in request `messages[]` content or `role:"tool"` content, parser-side synthesis MUST fail closed to plain content. Add minimal guard AC. Defer full incremental detector + canonicalization to v0.3.
5. **§10d.1 failure-table canonicalization** (closes Architect H-3 + Code H-2 + Security m-1) — missing `tool_call_id` → `invalid_tool_call_id` everywhere. Keep `content:null` → `invalid_request` for content-shape errors.

**Editorial / mechanical edits:**

6. **AC-14 v0.2 applicability note** (closes Architect H-2) — explicit version-boundary callout near AC-14 + before AC-25: "AC-14 is locked v0.1.x ratification criterion; superseded for v0.2.0 by AC-26/AC-27."
7. **§4/AC-8 v0.2 streaming applicability override** (closes Architect M-2) — note that §4/AC-8 describe v0.1.x buffered-to-end behavior; §10d.4/AC-40-AC-45 are authoritative for v0.2 streaming.
8. **§10d v0.2 reader note** (closes Architect H-1 + PD M-1) — explicit note at start of §10d: "§10d supersedes §10a's earlier seven-item v0.2 target list for v0.2.0; #2/#3/#5 deferred to v0.3."
9. **Duplicate §3.7 → §3.8** (closes Architect M-1 + PD minor-1) — renumber v0.2 additive section to §3.8 (lock-amendment consistent with Path B).
10. **AC-23s alias** (closes Architect M-3) — explicit "`AC-23s` in design notes = AC-43 in this SPEC" line in §10d.4.
11. **Code citation regen** (closes Code H-3) — `ModelRuntime.swift:353`/`:403` for call sites; `server.go:2103` function start + `:2149` WS byte-write; `server.go:1241-1245` for tool_call_id/tool_calls preservation.
12. **§3.8 family-renderer byte-specifiable** (closes Code H-1) — add Qwen/Llama prompt-template golden fixtures (one input messages[] + expected rendered template bytes per family); tie AC-26/AC-27 to fixtures.
13. **§10d.4 SSE example concrete ID** (closes Code M-1) — replace `call_<32hex>` placeholder with `call_0123456789abcdef0123456789abcdef`.
14. **AC-39 + AC-43 scope clarification** (closes Code M-2) — "OpenAI SDKs may surface terminal error frame as exception; AC-43 no-parse-error applies only to successful streams."
15. **AC-25 split + Cline tool mapping** (closes Code H-4 + PD HIGH-1 + PD MEDIUM-3) — AC-25 splits into AC-25a CI-amenable fixture (pinned Cline version, pinned repo, machine-readable transcript) + AC-25b manual recorded smoke. Tool requirements expressed as categories + legacy/ClineCore alias mapping.
16. **AC-44 instrumented + benchmarked** (closes PD HIGH-2) — provider-side timestamps for tool-call-open detection / first forwarded SSE byte / first gateway byte; p95 ≤ 1500 ms on M4, ≤ 3000 ms on M2/M3 (or replace with measured benchmark target).
17. **AC-45 + buyer-visible streaming-mode header** (closes Security M-3 + PD HIGH-3) — non-negotiating diagnostic. Proposal: `X-MacProvider-Streaming-Mode: incremental | buffered_kill_switch | buffered_provider_downgrade`. AC-45 requires header presence + correlation in logs.
18. **v0.2 error envelope thicker** (closes PD HIGH-4) — minimum fields: `error.type`, stable `error.code`, `message`, optional `param`, `retryable: bool`, `request_id`, `inference_ran: bool`, `settlement_ran: bool`. Codes include `byte_cap_exceeded`, `response_byte_cap_exceeded`, `malformed_tool_call_final_json`, `provider_stream_downgraded`, request-validation codes.
19. **Aggregate request caps + linear validation** (closes Security M-1) — total raw request body cap, total `role:"tool"` content bytes cap, max messages, max tool calls per request. Cross-message validation MUST be linear via maps/sets, not O(N²).
20. **Buyer-fabricated history provenance language** (closes Security M-2) — request-side assistant-history MUST NOT create provider provenance, settlement entries, receipt output objects, or "provider emitted" audit claims for prior turns.
21. **"Why Cline gates v0.2" paragraph** (closes PD MEDIUM-2) — short rationale in §10d before deliverables.
22. **Aggregate streaming budget Q** (closes Security Q-1) — explicit statement that max concurrent streams per coordinator process is bounded by SPEC-006 buyer-API or coordinator config (cite); per-stream 2 MiB cap × max-concurrent = total accumulator budget. Or add explicit per-buyer streaming-accumulator budget.

22 edits total. Single absorption pass to v0.2.1, then re-fire all 4 lanes for r2.

## Next steps

1. Write `specs/SPEC-018-v0_2-r1-absorption-prompt.md` — codex instruction file for v0.2.1 edits.
2. Fire codex to apply v0.2.1 absorption.
3. Re-fire 4 lanes (codex architect/code/security/product-design) for r2.
4. Loop r3..rN until 0/0/0 across all lanes.
5. Then Claude blind-spot pass (critic + narrative analyst) per v0.1.5 precedent.

Round 1 narrative complete. Absorption prompt next.
