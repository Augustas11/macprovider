# SPEC-018 v0.2.0 Draft Notes

Date: 2026-06-27

## Editorial decisions

- Preserved locked v0.1.5 prose and AC numbering. I only changed the header metadata required by the v0.2 prompt and added new v0.2 content.
- Added the v0.2.0 change-log entry before v0.1.5 so the newest entry remains top-of-file, matching the existing change-log convention.
- Kept `Depends on:` unchanged. SPEC-008 and SPEC-011 remain referenced, not newly binding, because model-hash registry work is deferred to v0.3.
- Added the new tool prompt-template profile as a v0.2 additive `### 3.7` section immediately before the locked v0.1.5 `### 3.7 Adding a new family` heading. This creates duplicate `3.7` headings intentionally rather than renumbering locked v0.1.5 content. Reviewers may choose a deliberate lock-breaking renumber later, but this draft prioritized the prompt's "preserve v0.1.5 verbatim" constraint.
- Extended §8.4 by appending §8.4.1, §8.4.2, and §8.4.3 below the locked v0.1.5 coordinator-forwarding validator. I did not replace the existing non-streaming / buffered-streaming validator text.
- Added AC-25 through AC-45 directly after locked AC-24. Existing AC-1 through AC-24 were not renumbered.
- Placed §10d between §10c and §11, as requested. Within §10d, I ordered deliverables by their design deliverable number: #1, #4, #6, #7, then out-of-scope v0.3 pointers.
- Added the v0.2.0 cap invariant to §10c because the synthesis required forward-compatible cap behavior. This is additive text and does not rewrite the existing §10c invariant.
- Used `openai==2.44.0` for AC-23s streaming compatibility because the synthesis explicitly pinned that baseline.
- Kept v0.3 deferred items out of normative v0.2 body except for forward pointers in §10d.8 and non-exposure warnings. No v0.3 public `usage.macprovider_malformed_tool_call` schema is specified for v0.2.

## Loose interpretations

- The prompt asked for a new §3.7, but locked v0.1.5 already had §3.7. I interpreted "do not alter locked content" as stronger than unique section numbering and documented the duplicate heading.
- The prompt asked to lift Deliverable #6 "verbatim" where possible. I compressed the full design artifact into normative SPEC prose while preserving the two regex domains, seven consistency rules, pass/fail examples, four error codes, cross-session reuse, and buyer-fabricated ID acceptance.
- The Deliverable #7 design artifact included v0.3 structured malformed-signal examples. Because the build prompt forbids v0.3 schema exposure in v0.2, I encoded only internal failure reasons and v0.2 terminal/fault behavior.
- The request-side failure table said `role:"tool"` missing `tool_call_id` uses HTTP 400 `invalid_request`, while Deliverable #6's four-code enum includes `invalid_tool_call_id` for missing or format-invalid IDs. I preserved the table verbatim in §10d.1 and used `invalid_tool_call_id` in AC-32 for cross-message validation failures. Reviewers should decide if missing `tool_call_id` needs one canonical code.
- I treated "streaming-side analogue to AC-24" as AC-43 plus §10d.4 coordinator pass-through prose, rather than creating a separate AC-46, because the prompt required exactly AC-25 through AC-45 from the synthesis table.
- I kept v0.1.5 §10a text as-is even though it still names #2/#3/#5 as v0.2 targets. §10d and the v0.2 change log narrow actual v0.2.0 scope and defer those items to v0.3. Editing §10a would have violated the locked-content constraint.

## Code location citations encoded

- `phase3-binary/Sources/malibu-cli/ModelRuntime.swift:909` — current `validateToolCallingV1Scope` rejection path.
- `phase3-binary/Sources/malibu-cli/ModelRuntime.swift:344` — pre-streaming call site.
- `phase3-binary/Sources/malibu-cli/ModelRuntime.swift:395` — pre-non-streaming call site.
- `phase3-binary/Sources/malibu-cli/ModelRuntime.swift:924` — current `role:"tool"` rejection.
- `phase3-binary/Sources/malibu-cli/ModelRuntime.swift:931` — current assistant-history `tool_calls[]` rejection.
- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:194` — existing assistant `tool_calls[]` validation.
- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:202` — existing tool-message validation.
- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift:175` — current `ChatMessage` field-loss problem.
- `phase3-binary/Sources/malibu-cli/ModelRuntime.swift:374`, `:428`, `:513` — `request.messages.map { $0.mlxMessage }` replacement points.
- `phase3-binary/Sources/malibu-cli/PromptCanonicalizer.swift:5` and `:31` — receipt prompt canonicalization coverage for messages, `tool_call_id`, and `tool_calls`.
- `phase4-coordinator/internal/buyer/server.go:1234` — coordinator request structs preserve `tool_call_id` and `tool_calls`.
- `phase4-coordinator/internal/buyer/server.go:3089` — coordinator request validation area for v0.2 additions.
- `phase4-coordinator/internal/buyer/server.go:2119` — `forwardWSStreaming` pass-through path.
- `phase4-coordinator/internal/buyer/server.go:2279` — `forwardStreaming` pass-through path.
- `phase4-coordinator/internal/buyer/server.go:2674` — current complete-JSON streaming validator that is incompatible with incremental fragments.
- `phase4-coordinator/internal/buyer/billing_recorder.go:176` — existing zero-credit/FaultBreakerQualifying settlement path.
- `phase4-coordinator/internal/billing/formula.go:112` — existing billing formula path.

## Deferred references encoded

- `specs/v0_3-design/02-registry.md` — v0.3 model-hash registry candidate.
- `specs/v0_3-design/03-echo-guard.md` — v0.3 prompt-echo guard candidate.
- `specs/v0_3-design/05-malformed-signal.md` — v0.3 structured malformed signal candidate.
