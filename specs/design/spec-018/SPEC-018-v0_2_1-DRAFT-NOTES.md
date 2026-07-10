# SPEC-018 v0.2.1 Draft Notes

Date: 2026-06-27
Purpose: Round-1 absorption notes for `SPEC-018-agentic-tool-calling.md` v0.2.1.

## Absorptions

| # | Finding ID | What changed | Location | Loose interpretation | Open follow-up |
|---:|---|---|---|---|---|
| 1 | Architect H-1 / Security H-1 / PD M-1 / Security Q-2 | Explicitly amended the §10c v0.1.3-locked model-hash registry invariant to defer registry enforcement to v0.3; change log names rationale and precedent. Added AC-46 passive `usage.macprovider_model_hash_observed`. | Change log; §10c; §10d.0.1; AC-46 | Used Path B exactly: amendment, not silent scope cut. | v0.3 must define registry curation/governance and enforcement. |
| 2 | Security C-1 / Code Q-1 | Final-close now requires terminal accumulated args, `finish_reason:"tool_calls"`, normal transport terminal marker, and no post-open transport/provider/auth/truncation failure. Failure means `FaultBreakerQualifying`, zero credits, no receipt, no sticky success. Added live code citations and AC-47. | §8.4.2; §10d.4; AC-47 | Direct HTTP clean EOF is clean only with all v0.2 terminal markers. | IMPL must patch direct HTTP clean EOF behavior for tool-call streams. |
| 3 | Security H-3 | Terminal SSE error after final-close failure MUST NOT carry `finish_reason:"tool_calls"`; SDK/framework must surface failed stream, not dispatchable tool calls. Added AC-48. | §8.4.3; AC-39; AC-43; AC-48 | Treats SDK exception as success for error-path validation. | Add Cline/openai-python negative fixture. |
| 4 | Security H-2 | Added minimal exact-verbatim prompt-echo guard and AC-49; full incremental/canonicalized detector remains v0.3. | §3.9; §10d.8; AC-49 | Byte-exact only; no normalization or partial matching. | v0.3 echo guard should handle transformed/canonicalized echoes. |
| 5 | Architect H-3 / Code H-2 / Security m-1 | Canonicalized missing `tool_call_id` to `invalid_tool_call_id` while keeping `content:null` as `invalid_request`. | §10d.1 failure table; AC-32 already aligned | None. | Provider/coordinator validators need matching fixture codes. |
| 6 | Architect H-2 | Added AC-14 applicability note and pre-v0.2 AC note: AC-14 is v0.1.x history, superseded by AC-26/AC-27. | AC-14; before AC-25a | Did not renumber AC-14. | None. |
| 7 | Architect M-2 | Added §4 note and AC-8/AC-9 notes that buffered streaming is v0.1.x; §10d.4 and AC-40-AC-45 control v0.2 streaming. | §4; AC-8; AC-9 | Preserves locked v0.1 wording with override note. | None. |
| 8 | Architect H-1 / PD M-1 | Added v0.2 reader note: §10d supersedes §10a for v0.2.0 scope; #2/#3 full/#5 deferred; §11 Q1 resolved by Cline. | §10d intro; §11 Q1 | §10a remains historical locked text. | v0.3 should revisit §10a wording if a future lock amendment allows it. |
| 9 | Architect M-1 / PD minor-1 | Renumbered additive tool prompt-template profile from duplicate §3.7 to §3.8 and recorded as explicit lock amendment. | §3.8; change log | Only numbering collision fixed; locked §3.7 remains "Adding a new family." | Link check after round-2 audit. |
| 10 | Architect M-3 | Added `AC-23s` alias note: design notes name it AC-23s, SPEC encodes it as AC-43. | §10d.4; AC-43 | AC-43 title still contains AC-23s for discoverability. | None. |
| 11 | Code H-3 | Updated v0.2 code citations: `ModelRuntime.swift:353`/`:403`, `server.go:2103` + `:2149`, `server.go:1241-1245`. | Change log; §8.4.1; §10d.1; §10d.4 | Verified against live repo before editing. | Re-run citation check after implementation moves code. |
| 12 | Code H-1 | Added §3.8 renderer fixture input and Qwen3/Llama-3.3 normative fixture structures with upstream tokenizer-config references; AC-26/AC-27 tie to fixtures. | §3.8.1; AC-26; AC-27 | Did not claim byte-exact Llama/Qwen output in SPEC where upstream template artifact must be pinned by IMPL. | IMPL must pin tokenizer-config artifact digests and generate golden bytes. |
| 13 | Code M-1 | Replaced `call_<32hex>` placeholder in SSE example with regex-valid `call_0123456789abcdef0123456789abcdef`. | §10d.4 example | None. | None. |
| 14 | Code M-2 | Clarified AC-39 SDK exceptions are intended for terminal-error streams; AC-43 no-parse-error applies only to successful streams. | AC-39; AC-43 | None. | None. |
| 15 | Code H-4 / PD HIGH-1 / PD MEDIUM-3 | Split AC-25 into AC-25a CI fixture and AC-25b manual smoke; added Cline version/extension ID, transcript schema, tool category requirements, and legacy/ClineCore mapping. | AC-25a; AC-25b | Cline v4.0.0 came from live Marketplace metadata on 2026-06-27; pin file may supersede exact patch. | Commit `tools/version-pins/cline-spec-018-v0_2_1.txt` during IMPL. |
| 16 | PD HIGH-2 | Replaced single timing statement with required provider/coordinator/gateway timestamps and p95 hardware targets. | AC-44 | Kept numeric targets rather than TBD. | Benchmark commit must establish fixture prompt and expected detection time. |
| 17 | Security M-3 / PD HIGH-3 | Added non-negotiating `X-MacProvider-Streaming-Mode` header and AC coverage for `incremental`, `buffered_kill_switch`, `buffered_provider_downgrade`. | §10d.4; AC-45 | Header is observation-only, not request negotiation. | Gateway/coordinator logs need correlation field. |
| 18 | PD HIGH-4 | Added v0.2 error envelope minimum fields and stable code/retryability table. | §10d.0 | `provider_stream_downgraded` is included for diagnostic downgrade paths. | IMPL should align HTTP and terminal SSE writers. |
| 19 | Security M-1 | Added aggregate raw/decoded request caps, message/tool-call caps, and O(N) validation requirement. | §10d.1 | Coordinator/provider cap is 4 MiB; SPEC-006 gateway default may be stricter at 1 MiB. | IMPL must decide exact enforcement layer ordering and tests. |
| 20 | Security M-2 | Added buyer-fabricated history provenance boundary: prompt data, not provider provenance; no retroactive settlement/receipt/audit claims. | §10d.6 | Current-turn prompt hash may bind fabricated history without attesting truth. | Receipt/UI/support tooling should avoid "provider emitted" claims for request history. |
| 21 | PD MEDIUM-2 | Added "Why Cline gates v0.2" paragraph and resolved §11 Q1. | §10d intro; §11 Q1 | Kept other OpenAI-wire frameworks as expected-compatible observation targets. | v0.3 compatibility matrix remains open work. |
| 22 | Security Q-1 | Added concurrent streaming accumulator budget: process cap tied to SPEC-006/deployment, recommended 64, per-buyer cap ≤4. | §10d.4 | Uses SPEC-006 concurrency defaults plus coordinator deployment cap because no single SPEC-006 process cap exists. | Operator config should expose process/per-buyer stream caps. |

## Notes

- The only v0.2.1 lock amendments are §10c model-hash registry timing and §3.8 renumbering of the additive v0.2 prompt-template section.
- All money-path final-close changes preserve zero provider-positive credits on malformed/incomplete provider output.
- Round-2 audit should focus on whether the §10d reader note is sufficient to prevent historical §10a/§12 wording from being misread as current v0.2.1 scope.
