# BUILD_SPEC_018 IMPL prompt — patch the 3 normative deltas + supporting artifacts

**You are starting a fresh session in a worktree off `origin/main`. You have no memory of prior conversations. Read this prompt end-to-end before writing anything.**

Your job is to land the SPEC-018 v0.1.5 IMPL deltas + supporting artifacts in `macprovider-poc`, audit-loop the diff through codex 4-lane until 0 CRITICAL + 0 HIGH + 0 MEDIUM, then open the IMPL PR.

## Pre-flight (read these in order)

1. **The locked SPEC: `specs/SPEC-018-agentic-tool-calling.md`** v0.1.5 — line 3 confirms version. §1.2 enumerates the 3 IMPL deltas. §9 enumerates AC-1 through AC-24 (AC-22 is intentionally a REMOVED-in-v0.1.3 placeholder; do not implement AC-22).
2. **Lock summary: `specs/SPEC-018-LOCK-v0_1_5.md`** — convergence trajectory + per-lane verdicts.
3. **Round narratives in `specs/SPEC-018-r{1,2,3}-audit.md`** — the design history. Particularly: r1 reframed v0.1 from "Ring-1 product" to "wire-shape certificate"; r3 + Claude critic dropped the v0.1.2 §3.6 mixed-sentinel rule as a DoS vector; r4 corrected the v0.1.1 §1.1 #4 model_hash overclaim.

## Worktree setup

Per [[feedback-always-fresh-worktree-for-code-work]]:

```bash
git worktree add ../macprovider-impl-spec-018 -b impl/spec-018-tool-calling origin/main
cd ../macprovider-impl-spec-018
```

Do all your work in that worktree. Do NOT branch off `spec/018-agentic-tool-calling` — the SPEC PR (Augustas11/macprovider#183) is already open and will land first. The IMPL PR is a separate branch off `origin/main`.

## What ships in this IMPL PR (3 normative deltas + 2 supporting artifacts)

### Delta 1 — §3.2 `modelID`-match-required parser change

**As-built** (`phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:482-487`): family detection is OR-based — modelID substring match OR raw output sentinel match selects the family.

**v0.1.5 normative** (§3.2 lines 145-153): family detection MUST require a modelID substring match against §3.1. Content-sentinel detection alone is NOT a normative trigger. Output containing recognized sentinels but no modelID family match MUST be emitted as plain assistant content. A request with missing / empty / whitespace-only modelID MUST be treated as no family match.

**Concrete patch instructions:**
- `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift`:
  - Around lines 482-487, change the family-detection condition from `modelID.contains("qwen2.5") || rawOutput.contains("<tool_call>")` (and the analogous Llama branch) to `modelID.localizedCaseInsensitiveContains("qwen2.5") || modelID.localizedCaseInsensitiveContains("qwen3")` for the Qwen row, and `modelID.localizedCaseInsensitiveContains("llama-3.3")` for the Llama row. **Sentinel content checks remain as body-shape validators after family is selected, NOT as a trigger.**
  - Add a guard early in `parse()`: if `modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` → return no tool calls (fallback to plain content per §3.5).
- `phase3-binary/Tests/macprovider-cliTests/ToolCallParserTests.swift:46-57`: existing tests assert delimiter-only parsing succeeds on non-matching modelID. UPDATE these tests:
  - `testDelimiterOnlyDetection_SentinelWithoutModelID_FallsBackToPlainContent()` — given empty/random modelID + Qwen output, assert `toolCalls.isEmpty` and `content == rawOutput`.
  - Keep all existing positive-path tests (modelID matches + sentinel present → tool call synthesized).
- Add new test: `testQwen3ModelID_TriggersQwenParser()` — modelID `mlx-community/Qwen3-32B-4bit` + Qwen sentinel output → tool call synthesized. (This case currently fails under v0.1.5 §3.2 if not patched — Qwen3 substring is required.)
- Add new test: `testEmptyModelID_FallsBackToPlainContent()`.
- Add new test: `testWhitespaceModelID_FallsBackToPlainContent()`.

**ACs covered:** AC-19 (modelID-match-required), AC-1/AC-2/AC-3 (Qwen + Qwen3 happy path).

### Delta 2 — §8.4 commit-worthy delta validator + DoS bounds

**As-built** (`phase4-coordinator/internal/buyer/server.go:2482-2605`): `hasOpenAIDeltaSignal` commits the response on any non-empty `tool_calls[]` array.

**v0.1.5 normative** (§8.4 lines 295-332): a `delta.tool_calls[]` event is commit-worthy ONLY if minimum shape AND DoS bounds pass:
- `index`: integer ≥ 0
- `id`: non-empty string
- `type == "function"`
- `function.name`: non-empty string
- `function.arguments`: present, a JSON string whose decoded value is a JSON object
- `function.arguments` decoded nesting depth ≤ 32
- `function.arguments` byte length ≤ 256 KiB

**Concrete patch instructions:**
- `phase4-coordinator/internal/buyer/server.go`:
  - Replace `hasOpenAIDeltaSignal`'s loose "any non-empty `tool_calls[]`" check with strict minimal-shape + DoS-bounds validation.
  - Use `encoding/json` for the JSON-object decode but layer a `json.NewDecoder` with `DisallowUnknownFields = false` (we allow unknown fields per §10c forward-compat).
  - Go's `encoding/json` doesn't expose depth — implement a custom token-stream depth counter (use `json.Decoder.Token()` and count `Delim('{')` / `Delim('[')` enter/exit). Reject when depth > 32.
  - Reject when `len(arguments) > 256 * 1024`.
- `phase4-coordinator/internal/buyer/server_internal_test.go:70-103`: extend with three new test cases — `TestCommitSignal_EmptyToolCallObject_Rejected` (`[{}]`), `TestCommitSignal_NonObjectArguments_Rejected` (`{"function":{"arguments":"[]"}}`), `TestCommitSignal_DeepNestedArguments_Rejected` (synthesize 100-deep nested object as `arguments` string).
- Add a unit test for the minimal valid shape: `TestCommitSignal_MinimalValidShape_Accepted`.

**Also apply DoS bounds to §3.4 parser-side duplicate validator** (`phase3-binary/Sources/macprovider-cli/ToolCallParser.swift:266-448`): same 32-depth / 256-KiB caps. Swift `JSONSerialization` accepts depth limits via no API but Swift's `JSONDecoder` does — use a pre-scan token counter or limit via byte-cap first. Add tests for the same three rejection cases on the parser side.

**ACs covered:** AC-21 (commit-worthy minimal-shape + DoS bounds), AC-24 (request-side pass-through — see Delta 4).

### Delta 3 — AC-20 documentation updates

**v0.1.5 §1.2** enumerates exact files MUST contain the buyer-side validation obligation phrase:
- `README.md`
- `examples/tool_calling_demo.py`
- `test/integration/tool_calling/README.md:38-53`
- `test/integration/tool_calling/openai_tool_call_e2e.py:78-85`

**The required phrase:** *"emitted `tool_calls[]` reflect model output, not provider-verified intent; buyer-side agent frameworks MUST validate before execution"*

Add a section / paragraph to each file containing the phrase verbatim. README.md gets a top-level "Security model: buyer-side validation obligation" subsection. The demo + integration runner README each get a callout near the existing tool-calling description. The Python e2e runner adds a comment header near line 78-85 with the phrase.

**ACs covered:** AC-20.

### Delta 4 — AC-24 coordinator request-side WS-frame test

**v0.1.5 AC-24** (lines 394-396): coordinator request-side `tool_calls[]` and `tool_call_id` pass-through fidelity is verified at the WebSocket frame layer.

**Concrete test instructions:**
- Add `TestRequestSidePassThrough_ToolCalls_ByteEquivalent` to `phase4-coordinator/internal/buyer/server_internal_test.go` (or a new test file if cleaner).
- The test:
  1. Constructs a buyer request with `messages[]` including an assistant message with `tool_calls[]` (multiple calls with various id formats) and a `role:"tool"` message echoing `tool_call_id`.
  2. Passes the request through the buyer-side server's request-validation + WS-routing path UP TO the point where the outbound `InferenceRequest` frame is constructed (do NOT require a provider socket to be connected).
  3. Inspects the outbound `InferenceRequest.Body` frame for byte-equivalence with the buyer-supplied `tool_calls[]` and `tool_call_id` field bytes after JSON canonicalization (allow whitespace normalization but NO field renaming, reordering of tool_calls[] elements, id rewriting, or value mutation).
- The test does NOT require the provider to accept the request — AC-14 confirms the provider will reject with `unsupported_tool_messages`. AC-24 isolates coordinator pass-through fidelity from that rejection.

**ACs covered:** AC-24.

### Delta 5 — `tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt`

**v0.1.5 §1.2 + AC-23** require this file as the v0.1.3 baseline parser pin.

**Create the file:**
- Path: `tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt` (create `tools/` and `tools/version-pins/` directories).
- Content: the exact `openai` Python SDK semver current at the v0.1.5 lock time. Look up via `pip index versions openai` or `gh api repos/openai/openai-python/releases/latest` for the latest stable as of 2026-06-27.
- Format: single line `openai==<semver>` (no comments, no whitespace). This makes the file usable directly by `pip install -r`.
- Also add a `tools/version-pins/README.md` explaining the purpose ("Version pins for SPEC-018 wire-shape baseline regression tests; do not edit without a SPEC-018 version bump").

**ACs covered:** AC-23.

## House conventions you MUST honour

1. **Worktree per [[feedback-always-fresh-worktree-for-code-work]]:** fresh worktree at `../macprovider-impl-spec-018` off `origin/main`. Branch: `impl/spec-018-tool-calling`.
2. **Build + test cleanly:**
   - `cd phase3-binary && swift test` — Swift tests, especially `ToolCallParserTests` + `HTTPServerReceiptTests`.
   - `cd phase4-coordinator && go test ./...` — Go tests, especially `internal/buyer` + `internal/ws`.
   - `cd phase5-gateway && go test ./...` — Go tests on the gateway side (no changes expected, but verify no regression).
   - `cd test/integration/tool_calling && python -m pytest openai_tool_call_e2e.py` or follow the README — integration smoke.
3. **Money-path / security implications per [[c2-gate-gateway-credential-validation-asymmetry]] + [[provider-disconnect-rootcause]]:** the §8.4 commit-validator change is on the coordinator commit-signal path, which is a money-path under SPEC-016 settlement. Add explicit comments noting "commit-worthy gates billing settlement; rejection must NOT settle provider-positive usage."
4. **Commit hygiene:** atomic commits per delta (5 commits). Commit messages cite the SPEC section + AC number.
5. **Audit-loop discipline per [[feedback-build-audit-loop]]:** before opening the IMPL PR, write `specs/AUDIT_SPEC_018_IMPL_{ARCHITECT,CODE,SECURITY,PRODUCT_DESIGN}_PROMPT.md` and run through codex 4-lane until 0 CRITICAL + 0 HIGH + 0 MEDIUM. Same convention as the SPEC audit loop. The audit prompts target the IMPL diff, not the SPEC body.
6. **No SPEC body edits in this PR** — the SPEC is locked. If the IMPL audit surfaces a SPEC issue, that's a separate SPEC-018 v0.1.6 PR.
7. **Per CLAUDE.md** — pushes route to Augustas11 automatically. No URL-embedded tokens needed.

## Audit-loop scope (after the diff lands)

Write four IMPL-specific audit prompts:

- **architect** — does the IMPL diff align with SPEC-018 §1.2 IMPL deltas? Are there cross-cutting structural issues (e.g. introducing a new SPEC-018 surface not enumerated in §1.2)?
- **code** — every changed line traceable to a SPEC §N or AC? Test coverage adequate? Edge cases (empty modelID, whitespace, mixed case, multi-byte unicode in arguments, max-depth-32 boundary)?
- **security** — does the §8.4 validator close the H-1/M-1 attack surface for real? Does the §3.2 parser change introduce any new bypass? Does the AC-24 test actually catch the M-3 failure mode (silent coordinator field drop)?
- **product-design** — does AC-20 documentation read well to a buyer? Are README + demo + integration runner consistent? Does a Cline / Aider user finding the README understand the v0.1.5 first-turn-only scope?

Convergence target: ≤4 rounds (smaller surface than the SPEC audit). Per [[feedback-three-lane-codex-audits]], lanes are independent.

## Open the IMPL PR

After audit-loop converges 0/0/0:

- Title: "SPEC-018 IMPL v0.1.5 — modelID-match-required parser + commit-worthy validator + AC-20 docs + AC-24 test + baseline pin"
- Body: enumerate the 5 deltas + audit-loop trajectory + test verification + cross-link to SPEC PR (#183).
- Base: `main`. Head: `impl/spec-018-tool-calling`.
- Per [[gh-pr-merge-augustas11-token-prefix]]: `GH_TOKEN=$(gh auth token -u Augustas11) gh pr create ...`

## Open questions to NOT resolve in this PR

- §11 Q1 — v0.2 framework readiness signal (a/b/c) is an operator product decision, not an IMPL choice.
- The OpenAI Python SDK semver to pin in Delta 5 — if there's no clear "the version current at 2026-06-27" answer, pick the latest stable as of that date and note the choice in the version-pin README.

---

**End of prompt. Begin in the fresh worktree. Land the 5 deltas atomically, audit-loop, open the PR. The SPEC PR (#183) is independent and will land in parallel.**
