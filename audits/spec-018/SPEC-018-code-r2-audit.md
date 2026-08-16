# SPEC-018 v0.1.1 — CODE-lane round-2 audit

You are the **code** lane of a four-lane round-2 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.1.1. Stay narrowly in your lane.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.1 (commit `14d0319`)
- Round-1 code findings: `specs/SPEC-018-code-r1-audit.md`
- Round-1 absorbed: every code r1 finding (M-1, M-2, M-3, Q-1, Q-2, Q-3) was marked absorbed in the round narrative.

## Round-2 lane scope

1. **Verify r1 absorption.** For each code r1 finding, confirm the v0.1.1 body actually closes it. Specifically:
   - **M-1** family table: §3.1 now states "`arguments` preferred; `parameters` accepted as fallback" for Qwen and inverse for Llama. Open `ToolCallParser.swift:52-74` and `:473-479` and verify the §3.1 table matches the actual fallback in code.
   - **M-2** Python duplicate cite: §3.4 now cites `:96-123` + `:266-448`. Verify both ranges contain the cited behavior.
   - **M-3** InferenceRelay non-streaming cite: §8.2 now adds `:269-309`. Verify that range contains the non-streaming `data` forward.
   - **Q-1** AC-15 split: AC-15a is CI-verifiable code default + validation; AC-15b is deploy artifact. Are both mechanically verifiable in their lanes?
   - **Q-2** AC-18 parametric: AC-18 no longer names `api.malibu.tech`. Verify the parametric phrasing is mechanically verifiable.
   - **Q-3** AC-4 collision: AC-4 now says "observed unique within the test response" and "non-collision is invariant by construction." Does this remove the false-precision problem from r1?

2. **Verify all new citations in v0.1.1.** The SPEC added or moved several `Source:` lines:
   - §2.3 unchanged but verify the `:96-123` and `:169-188` citations.
   - §3.1 cites `:451-491` and `:77-123` — recheck for §3.1 row content.
   - §3.4 — recheck.
   - §3.5 — recheck.
   - §6 — recheck SPEC-001:950-979 + SPEC-002:2280-2318.
   - §7 — recheck `phase5-gateway/internal/config/config.go` ranges + `cmd/gateway/main.go:81-95`.
   - §8.4 — `phase4-coordinator/internal/buyer/server.go:1982-2195, 2320-2473, 2482-2605` + `server_internal_test.go:70-103`.
   - §10a #2 — `phase4-coordinator/internal/pool/provider.go:158-162`, `phase4-coordinator/internal/buyer/server.go:3743-3764`. Verify these contain the SPEC-008/011 model_hash infrastructure the SPEC claims they do.

3. **Verify new ACs are mechanically verifiable.**
   - AC-19 modelID-match-required: can a test write this against the current as-built? Note the SPEC says §3.2 is a SPEC-driven IMPL change — the as-built today does NOT enforce modelID-match-required (see `ToolCallParser.swift:486` which is OR-based). Is AC-19 verifiable today, or only after the IMPL prompt patches the parser? If the latter, flag explicitly so the IMPL prompt knows.
   - AC-20 buyer-side validation visibility: tests `README.md`, examples, test harnesses for the obligation string. CI-verifiable?
   - AC-21 commit-worthy validation: new normative rule in §8.4. AC-21 says "verified by a new coordinator test on the commit-signal path." Is the test specified concretely enough to write?
   - AC-22 mixed-sentinel: per §3.6 — verifiable today against the as-built parser? Check `ToolCallParser.swift` for the mixed-sentinel behavior.

4. **Find new code-lane drift.** v0.1.1's rewrite touched §3 + §5 + §6 + §7 + §8 + §9 + §10. Any new behavioral claim that disagrees with the as-built source is a finding.

## Output format

```
# SPEC-018 v0.1.1 — Code-lane round-2 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## r1-absorption verification
[per r1 finding: CONFIRMED | RESIDUAL | UNCHANGED | NEW-ISSUE]

## Findings
### C-1 / H-1 / M-1 / m-1 / Q-1 — Title
- SPEC location: §N or AC-N
- Code location: file:line-range
- What the SPEC claims:
- What the code does:
- Drift summary:
- Recommended fix to SPEC body (or QUESTION):

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. MINORs + QUESTIONS deferrable. Stay in code lane.

## Final prompt

# SPEC-018 v0.1.1 — CODE-lane round-2 audit

You are the **code** lane of a four-lane round-2 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.1.1. Stay narrowly in your lane.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.1 (commit `14d0319`)
- Round-1 code findings: `specs/SPEC-018-code-r1-audit.md`
- Round-1 absorbed: every code r1 finding (M-1, M-2, M-3, Q-1, Q-2, Q-3) was marked absorbed in the round narrative.

## Round-2 lane scope

1. **Verify r1 absorption.** For each code r1 finding, confirm the v0.1.1 body actually closes it. Specifically:
   - **M-1** family table: §3.1 now states "`arguments` preferred; `parameters` accepted as fallback" for Qwen and inverse for Llama. Open `ToolCallParser.swift:52-74` and `:473-479` and verify the §3.1 table matches the actual fallback in code.
   - **M-2** Python duplicate cite: §3.4 now cites `:96-123` + `:266-448`. Verify both ranges contain the cited behavior.
   - **M-3** InferenceRelay non-streaming cite: §8.2 now adds `:269-309`. Verify that range contains the non-streaming `data` forward.
   - **Q-1** AC-15 split: AC-15a is CI-verifiable code default + validation; AC-15b is deploy artifact. Are both mechanically verifiable in their lanes?
   - **Q-2** AC-18 parametric: AC-18 no longer names `api.malibu.tech`. Verify the parametric phrasing is mechanically verifiable.
   - **Q-3** AC-4 collision: AC-4 now says "observed unique within the test response" and "non-collision is invariant by construction." Does this remove the false-precision problem from r1?

2. **Verify all new citations in v0.1.1.** The SPEC added or moved several `Source:` lines:
   - §2.3 unchanged but verify the `:96-123` and `:169-188` citations.
   - §3.1 cites `:451-491` and `:77-123` — recheck for §3.1 row content.
   - §3.4 — recheck.
   - §3.5 — recheck.
   - §6 — recheck SPEC-001:950-979 + SPEC-002:2280-2318.
   - §7 — recheck `phase5-gateway/internal/config/config.go` ranges + `cmd/gateway/main.go:81-95`.
   - §8.4 — `phase4-coordinator/internal/buyer/server.go:1982-2195, 2320-2473, 2482-2605` + `server_internal_test.go:70-103`.
   - §10a #2 — `phase4-coordinator/internal/pool/provider.go:158-162`, `phase4-coordinator/internal/buyer/server.go:3743-3764`. Verify these contain the SPEC-008/011 model_hash infrastructure the SPEC claims they do.

3. **Verify new ACs are mechanically verifiable.**
   - AC-19 modelID-match-required: can a test write this against the current as-built? Note the SPEC says §3.2 is a SPEC-driven IMPL change — the as-built today does NOT enforce modelID-match-required (see `ToolCallParser.swift:486` which is OR-based). Is AC-19 verifiable today, or only after the IMPL prompt patches the parser? If the latter, flag explicitly so the IMPL prompt knows.
   - AC-20 buyer-side validation visibility: tests `README.md`, examples, test harnesses for the obligation string. CI-verifiable?
   - AC-21 commit-worthy validation: new normative rule in §8.4. AC-21 says "verified by a new coordinator test on the commit-signal path." Is the test specified concretely enough to write?
   - AC-22 mixed-sentinel: per §3.6 — verifiable today against the as-built parser? Check `ToolCallParser.swift` for the mixed-sentinel behavior.

4. **Find new code-lane drift.** v0.1.1's rewrite touched §3 + §5 + §6 + §7 + §8 + §9 + §10. Any new behavioral claim that disagrees with the as-built source is a finding.

## Output format

```
# SPEC-018 v0.1.1 — Code-lane round-2 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## r1-absorption verification
[per r1 finding: CONFIRMED | RESIDUAL | UNCHANGED | NEW-ISSUE]

## Findings
### C-1 / H-1 / M-1 / m-1 / Q-1 — Title
- SPEC location: §N or AC-N
- Code location: file:line-range
- What the SPEC claims:
- What the code does:
- Drift summary:
- Recommended fix to SPEC body (or QUESTION):

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. MINORs + QUESTIONS deferrable. Stay in code lane.

## Raw output

```text
# SPEC-018 v0.1.1 — Code-lane round-2 audit

## Counts
CRITICAL: 0  
HIGH: 0  
MEDIUM: 3  
MINOR: 0  
QUESTIONS: 3  

## r1-absorption verification
- M-1: CONFIRMED. `ToolCallParser.swift:72-74` plus `:473-479` match §3.1 fallback: Qwen prefers `arguments` then accepts `parameters`; Llama prefers `parameters` then accepts `arguments`.
- M-2: CONFIRMED. `ToolCallParser.swift:96-123` contains Python duplicate keyword rejection; `:266-448` contains JSON duplicate-key validation.
- M-3: CONFIRMED. `InferenceRelay.swift:269-309` contains non-streaming `data: response` forwarding.
- Q-1: CONFIRMED. AC-15a is CI-verifiable code default/validation; AC-15b is release/deploy evidence.
- Q-2: CONFIRMED. AC-18 no longer pins `api.malibu.tech`; the runner records parametric `base_url`, `model`, provider pin, shape, and latency.
- Q-3: CONFIRMED. AC-4 now tests observed uniqueness and states no explicit de-dup loop exists, removing the r1 false-precision issue.

## Findings

### M-1 — Mixed-sentinel fallback is not implemented or listed as an IMPL delta
- SPEC location: §3.6, §5, AC-22
- Code location: `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:482-487`, `:29-49`; `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:826-839`
- What the SPEC claims: Output containing both `<tool_call>` and `<|python_tag|>` sentinels MUST produce no `tool_calls[]`.
- What the code does: Detection returns Llama when `<|python_tag|>` is present, even if `<tool_call>` is also present. A valid Llama-delimited call can still synthesize `tool_calls[]`; extra Qwen markup becomes cleaned content and is discarded by runtime when tool calls exist.
- Drift summary: AC-22 is not verifiable against the as-built parser today, and §1 only names `modelID` matching and §8.4 as planned IMPL deltas.
- Recommended fix to SPEC body: Add mixed-sentinel fallback to the explicit v0.1.1 IMPL-delta list and require parser/tests, or move §3.6/AC-22 to §10a.

### M-2 — §10a model-hash infrastructure citation points at supported-model fields
- SPEC location: §10a #2
- Code location: cited `phase4-coordinator/internal/pool/provider.go:158-162`; actual `provider.go:132-133`, `:1001-1052`
- What the SPEC claims: `provider.go:158-162` contains live SPEC-008/SPEC-011 `model_hash` infrastructure.
- What the code does: `:158-162` is `SupportedModels` / `PublishesSupportedModels`. `ModelHash` and `HashStatus` are at `:132-133`; heartbeat model-hash update is at `:1001-1052`.
- Drift summary: The infrastructure exists, but the cited range is wrong.
- Recommended fix to SPEC body: Replace `provider.go:158-162` with `provider.go:132-133` and optionally `provider.go:1001-1052`.

### M-3 — §8.4 citation/test range proves the old commit predicate, not AC-21 validation
- SPEC location: §8.4, AC-21
- Code location: `phase4-coordinator/internal/buyer/server.go:2482-2605`; `server_internal_test.go:70-103`
- What the SPEC claims: Commit-worthy `delta.tool_calls[]` requires integer `index`, non-empty `id`, `type == "function"`, non-empty `function.name`, and parseable JSON `function.arguments`.
- What the code does: `hasOpenAIDeltaSignal` accepts any non-empty `tool_calls` array. The cited test at `server_internal_test.go:101` accepts a tool-call delta missing the full minimal shape.
- Drift summary: This is correctly named as a §8.4 IMPL delta in §1, but the current `Source:` line reads like evidence for behavior that is not implemented yet.
- Recommended fix to SPEC body: Label the cited ranges as “current commit-signal path to patch,” and require a new test that rejects `[{}]` and accepts only the minimal valid tool-call delta.

### Q-1 — AC-19 is verifiable only after the parser patch
- SPEC location: AC-19, §3.2
- Code location: `ToolCallParser.swift:482-487`; tests `ToolCallParserTests.swift:46-57`
- QUESTION: Current detection is OR-based and tests delimiter-only parsing for non-matching model IDs. IMPL must update both parser logic and these tests before AC-19 can pass.

### Q-2 — AC-20 is CI-verifiable, but current docs/harness text is absent
- SPEC location: AC-20
- Code location: `test/integration/tool_calling/README.md:38-53`; `openai_tool_call_e2e.py:78-85`
- QUESTION: A grep-style CI test can verify the obligation string, but the current README/harness does not state “model output, not provider-verified intent” or “validate before execution.” Enumerate exact files and required phrase.

### Q-3 — Qwen3 modelID matching is ambiguous after modelID-required tightening
- SPEC location: §3.1, AC-18
- Code location: `ToolCallParserTests.swift:32-57`; `ToolCallParser.swift:482-487`
- QUESTION: §3.1 names “Qwen2.5 / Qwen3” but requires `modelID` substring `qwen2.5`. Current tests use `Qwen3-32B-4bit` and pass only because delimiter-only detection exists. Should `qwen3` be an explicit match, or should the row stop naming Qwen3?

## Verdict
FIX REQUIRED

