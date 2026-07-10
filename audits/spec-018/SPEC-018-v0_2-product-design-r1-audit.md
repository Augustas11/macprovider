# SPEC-018 v0.2.0 - Product-design-lane round-1 audit

## Counts

CRITICAL: 0
HIGH: 4
MEDIUM: 3
MINOR: 1
QUESTIONS: 2

## Cline Reference Notes

Reviewed sources:
- Local SPEC draft: `specs/SPEC-018-agentic-tool-calling.md`
- Design source: `specs/SPEC-018-v0_2-design-synthesis.md`
- Draft notes: `specs/SPEC-018-v0_2_0-DRAFT-NOTES.md`
- Build prompt: `specs/BUILD_SPEC_018_v0_2_PROMPT.md`
- Cline docs: `https://docs.cline.bot/tools-reference/all-cline-tools`
- Cline SDK integration docs: `https://docs.cline.bot/api/sdk-examples`
- Cline SDK error docs: `https://docs.cline.bot/api/errors`

Important Cline-doc observation: the current Cline tools reference documents ClineCore built-ins as `bash`, `editor`, `read_files`, `apply_patch`, and `search`, while the older XML tool names `read_file`, `write_to_file`, `execute_command`, `list_files`, and `search_files` are explicitly legacy aliases. That does not make the SPEC wrong for the extension-era Cline surface, but it makes AC-25 ambiguous unless the release gate says which Cline surface is being tested and maps legacy names to current equivalents.

## Findings

### HIGH-1 - AC-25 is a manual demo, not a release gate

- User impact: A Cline user can have a real coding session while the release gate still fails for arbitrary reasons, or the release can pass once by hand without producing reproducible evidence. That weakens the claim "Cline drop-in works."
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:470` (AC-25), `:486` (AC-33), `:508` (AC-44).
- Current framing: AC-25 requires a recorded Cline session with >=20 provider turns, >=30 tool calls/results, a named tool surface, >=3 edits across >=2 files, command failure plus recovery, history echo, and no provider faults.
- Reality from Cline: A normal Cline coding task can reach these volumes, but the exact counts are prompt, model, repo, and permission dependent. The current Cline docs also name the current runtime tools differently from the legacy names in AC-25.
- Recommended fix: Split AC-25 into two artifacts:
  1. A CI-amenable fixture or headless Cline SDK run with a pinned repo, pinned prompt, pinned Cline version, machine-readable transcript, and explicit mapping from current tools (`bash`, `editor`, `read_files`, `apply_patch`, `search`) to legacy aliases.
  2. A manual recorded smoke against the real extension UI, marked as release evidence rather than CI proof.
  AC-25 should pass when the deterministic artifact proves the protocol contract and the manual recording proves the user experience.

### HIGH-2 - The 1500 ms streaming bound is not product-realistic as written

- User impact: If the gate is too strict, a working local Mac provider can be blocked by timing noise. If it is too vague, a buffered implementation can pass by picking a favorable timestamp.
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:508` (AC-44), `:592-622` (§10d.4).
- Current framing: First `function.arguments` delta must reach Cline within 1500 ms of "provider recognizing the tool-call opening."
- Reality from Cline/local inference: Cline can display streaming deltas, but "provider recognizing the tool-call opening" is an internal provider event, not a Cline-observable event. The SPEC gives no benchmark evidence that Qwen3-32B-4bit on M2/M3/M4 can reliably hit this under real generation load. The 1500 ms target may be achievable after recognition if the provider flushes immediately, but it is not externally auditable from a recorded Cline session alone.
- Recommended fix: Keep a latency gate, but make it instrumented and fixture-based. Require provider-side timestamps for native tool-call-open detection, first forwarded SSE argument byte, and first gateway-delivered byte. Use the Cline recording only to prove visible incremental progress. Either justify 1500 ms with M2/M3/M4 benchmark data or state it as an initial target with an explicit fallback threshold, for example "p95 <= 1500 ms on M4, <= 3000 ms on M2/M3, measured in a deterministic provider fixture."

### HIGH-3 - The operator kill switch and auto-downgrade are invisible to Cline users

- User impact: If streaming is killed or a provider is auto-downgraded, the Cline user sees the old failure mode: a long pause followed by a large tool call. They cannot tell whether macprovider is slow, the model is stuck, Cline is broken, or streaming was intentionally disabled.
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:14`, `:594`, `:510` (AC-45).
- Current framing: Streaming mode configurability is operational only and must not be exposed as public wire negotiation in v0.2.
- Reality from Cline UX: The user-facing difference between token-incremental streaming and buffered-to-end is the product feature. If the feature is disabled silently, the "Cline drop-in works" story degrades without an actionable explanation.
- Recommended fix: Preserve "no public negotiation" but require buyer-visible signaling. At minimum, responses should expose a non-negotiating diagnostic header or final metadata/log artifact such as `X-MacProvider-Streaming-Mode: incremental|buffered_kill_switch|buffered_provider_downgrade` and a stable request ID. For Cline-visible UX, document that buffered mode is graceful degradation, not an error, and require the gateway/operator logs to correlate the buyer request with the downgrade reason.

### HIGH-4 - v0.2 error envelopes are too thin for Cline to act on

- User impact: On cap-cross, final-close parse failure, or malformed stream, Cline can end up showing a generic provider/API failure. The user does not know whether to retry, reduce the requested file size, re-prompt, or abandon the session.
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:404` (§8.4.3), `:618` (§10d.4), `:698-705` (§10d.6), `:741` (§10d.8), `:498` (AC-39).
- Current framing: v0.2 may include internal failure reasons in logs and a terminating OpenAI-style SSE error object, but it must not expose the v0.3 `usage.macprovider_malformed_tool_call` schema.
- Reality from Cline SDK docs: Cline distinguishes API/provider failures through structured error objects and retryability. "OpenAI-style error object" is not specific enough for a Cline integration to present a useful user message or decide retry behavior.
- Recommended fix: Without shipping the deferred v0.3 usage schema, define a v0.2 minimum error envelope for terminal SSE and HTTP failures: `error.type`, stable `error.code`, human-readable `message`, optional `param`, `retryable`, request ID, and whether inference/settlement ran. Codes should distinguish `byte_cap_exceeded`, `response_byte_cap_exceeded`, `malformed_tool_call_final_json`, `provider_stream_downgraded`, and request-validation errors. Mark `tool_result_too_large` / argument-cap failures as user-actionable, not retryable.

### MEDIUM-1 - The v0.2 narrowing is disclosed, but contradictory locked prose still leaks into reviewer-visible sections

- User impact: A reviewer or Cline integrator can read §10a / §12 and conclude that model-hash registry, prompt-echo guard, and structured malformed signal are still v0.2 requirements, then read §10d and see the opposite.
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:9-18` (good disclosure), `:514-524` (§10a still says seven v0.2 normative targets), `:733-741` (§10d.8 defers #2/#3/#5), `:765-769` (§12 still says #2/#3 are reserved for v0.2). Draft note acknowledges this at `specs/SPEC-018-v0_2_0-DRAFT-NOTES.md:25`.
- Current framing: The change log and §10d are honest, but the locked body still reads as if v0.2 silently shipped less than the earlier target.
- Reality from product review: This is not CRITICAL because the new change log and §10d explicitly disclose the scope cut. It is still costly: the SPEC asks reviewers to reconcile two timelines in their heads.
- Recommended fix: Add an explicit v0.2 reader note near the start of §10d or immediately before §11: "For v0.2.0 only, §10d supersedes §10a's earlier seven-item v0.2 target list; #2/#3/#5 are intentionally deferred to v0.3." Also update §11 Q1 status as resolved by §10d, or move it to historical notes.

### MEDIUM-2 - The framework-compatibility narrative states Cline is the gate but does not explain why

- User impact: A future SPEC reviewer or integrator from Aider/OpenCode/Continue can read the Cline-only gate as arbitrary rather than as a deliberate product slice.
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:10`, `:40`, `:470`, `:745`.
- Current framing: The change log says Cline gates v0.2 and other OpenAI-wire frameworks are observation only. §1 still lists all frameworks as what real users need. §11 still asks whether one framework or all frameworks should gate readiness.
- Reality from product positioning: "Cline drop-in works" is a coherent v0.2 thesis, but the SPEC should say why Cline is the anchor: deep multi-turn tool workload, common coding-agent use, file edits plus shell commands, and streaming UX sensitivity.
- Recommended fix: Add a short "Why Cline gates v0.2" paragraph in §10d before deliverables. Name the non-gating frameworks as "expected-compatible observation targets" and say a compatibility matrix is v0.3+ or a separate release criterion.

### MEDIUM-3 - AC-25 names legacy Cline tools without a current-tool equivalence map

- User impact: A normal Cline SDK/ClineCore run may use `bash`, `editor`, `read_files`, `apply_patch`, and `search`, while AC-25 asks for `list_files`, `search_files`, `read_file`, `write_to_file`, and `execute_command`. That can make valid evidence look non-compliant.
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:470`, `:508`.
- Current framing: Only `write_to_file` gets an "or equivalent edit tool" escape hatch.
- Reality from Cline docs: Current docs identify those exact older names as legacy aliases and document current tools separately.
- Recommended fix: Change AC-25 wording to require tool categories, not exact tool names: directory listing/search, file read, file edit/full-write or patch, and shell command. Then give a Cline extension legacy mapping and a ClineCore mapping.

### minor-1 - Duplicate §3.7 numbering is understandable but reviewer-hostile

- User impact: Reviewers searching or linking to §3.7 can land on the wrong section.
- SPEC location: `specs/SPEC-018-agentic-tool-calling.md:208` and `:227`; draft note at `specs/SPEC-018-v0_2_0-DRAFT-NOTES.md:10`.
- Recommended fix: If lock discipline allows, rename the additive section to `3.7a` or `3.8` with a note that v0.1.5 numbering was preserved elsewhere. If not, add anchor labels in headings.

### Q-1 - Should Cline see a graceful "buffered response" notice in the chat surface?

- Trade-off: A header/log-only signal is enough for operators and integration tests, but not enough for the Cline end user watching a stalled large write. The SPEC should decide whether v0.2 promises only protocol compatibility or also a user-visible degraded-mode explanation.

### Q-2 - Is the 256 KiB `role:"tool"` result cap compatible with real Cline file-read workflows?

- Trade-off: The cap is defensible for prompt-render memory, but Cline can read files and command outputs that exceed 256 KiB in real repos. If the provider rejects the whole next turn, the user experience is a hard session failure. Decide whether v0.2 requires Cline-side truncation evidence, a larger cap, or a specific actionable `tool_result_too_large` message telling the user what to do.

## Anchor Walk-through

A developer points Cline at macprovider, asks for a realistic refactor, and gets multi-turn tool use. The v0.2 draft now correctly identifies that this is the product target, not just first-turn wire-shape parity. The weak point is failure and degradation UX: when streaming is disabled, malformed, capped, or too slow, the current SPEC leaves Cline with generic API failure or silent buffering instead of a user-actionable diagnosis.

## Verdict

FIX REQUIRED.

No CRITICAL because the top change log and §10d honestly disclose the four-deliverable v0.2.0 scope. The release should not lock with the current HIGH issues: AC-25/AC-44 need reproducible evidence, kill-switch degradation needs buyer-visible signaling, and terminal error envelopes need enough structure for Cline to present actionable messages.
