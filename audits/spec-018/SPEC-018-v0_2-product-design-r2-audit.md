# SPEC-018 v0.2.1 - Product-design-lane round-2 audit

## Counts

CRITICAL: 0
HIGH: 0
MEDIUM: 1
MINOR: 0
QUESTIONS: 0

## Inputs Reviewed

- `specs/SPEC-018-agentic-tool-calling.md` v0.2.1 working copy.
- `specs/SPEC-018-v0_2-product-design-r1-audit.md`.
- `specs/SPEC-018-v0_2-r1-audit.md`.
- `specs/SPEC-018-v0_2-r1-absorption-prompt.md`.
- `specs/SPEC-018-v0_2_1-DRAFT-NOTES.md`.
- Cline reference docs as product context: `https://docs.cline.bot/tools-reference/all-cline-tools`, `https://docs.cline.bot/api/sdk-examples`, `https://docs.cline.bot/api/errors`.

## Prior PD r1 Closure Matrix

### HIGH-1 - AC-25 is a manual demo, not a release gate

Status: CLOSED.

v0.2.1 splits AC-25 into a CI-amenable headless Cline fixture and a manual recorded smoke. AC-25a requires pinned Cline version, pinned repo commit, pinned prompt, machine-readable transcript, raw request/response or SSE transcript hashes, tool IDs/categories, timings, request IDs, streaming header, and automated pass/fail criteria. AC-25b keeps the real VS Code extension recording as release evidence rather than CI proof. Citation: `specs/SPEC-018-agentic-tool-calling.md:549-553`.

### HIGH-2 - AC-44 1500 ms streaming bound not auditable/product-realistic

Status: CLOSED.

AC-44 now requires provider/coordinator/gateway timestamps and a deterministic provider benchmark fixture. The latency target is per hardware class: p95 <= 1500 ms on M4 and <= 3000 ms on M2/M3, measured from provider-internal open detection to first gateway byte. Citation: `specs/SPEC-018-agentic-tool-calling.md:591`.

### HIGH-3 - Operator kill switch and downgrade invisible to Cline users

Status: CLOSED.

v0.2.1 adds a non-negotiating buyer diagnostic header and requires it on every v0.2 response, with fixtures for `incremental`, `buffered_kill_switch`, and `buffered_provider_downgrade`. Citations: `specs/SPEC-018-agentic-tool-calling.md:747`, `specs/SPEC-018-agentic-tool-calling.md:593`.

### HIGH-4 - v0.2 error envelopes too thin for Cline actionability

Status: CLOSED.

§10d.0 defines a minimum OpenAI-style error envelope with stable `code`, human-readable `message`, optional `param`, `retryable`, `request_id`, `inference_ran`, and `settlement_ran`; it also enumerates retryability for cap, malformed-final-json, downgrade, ID, profile, and echo-guard failures. Citations: `specs/SPEC-018-agentic-tool-calling.md:657-693`.

### MEDIUM-1 - §10a vs §10d reader confusion

Status: CLOSED.

§10d now says it supersedes §10a's earlier seven-item v0.2 target list for v0.2.0 scope, explicitly defers registry/full echo guard/malformed-signal to v0.3, preserves §10a as historical locked content, and resolves §11 Q1 by making Cline the anchor framework. Citations: `specs/SPEC-018-agentic-tool-calling.md:649-655`, `specs/SPEC-018-agentic-tool-calling.md:900-902`.

### MEDIUM-2 - Missing "Why Cline gates v0.2" rationale

Status: CLOSED.

v0.2.1 adds a Cline rationale paragraph: marketplace scale, heavy multi-turn tool workload, large write arguments, open-source/community evidence, and other OpenAI-wire frameworks as v0.3+ compatibility-matrix targets. Citation: `specs/SPEC-018-agentic-tool-calling.md:655`.

### MEDIUM-3 - Legacy vs current Cline tool names unmapped

Status: CLOSED.

AC-25 is now category-based rather than exact-name-based, and maps legacy extension tool names to ClineCore names. The release evidence must cover directory listing/search, file read, file edit, and shell command categories. Citation: `specs/SPEC-018-agentic-tool-calling.md:549-553`.

### minor-1 - Duplicate §3.7 numbering

Status: CLOSED.

The additive v0.2 prompt-template-profile section is renumbered to §3.8, with an explicit lock-amendment note. Locked §3.7 remains "Adding a new family." Citation: `specs/SPEC-018-agentic-tool-calling.md:220-221`, `specs/SPEC-018-agentic-tool-calling.md:296-300`.

### Q-1 - Buffered-mode UX notice

Status: CLOSED.

The product decision is header/log visibility, not chat-surface injection. §10d.4 exposes buffered mode via `X-MacProvider-Streaming-Mode`, and AC-45 requires header/state/request-log correlation. Citations: `specs/SPEC-018-agentic-tool-calling.md:745-747`, `specs/SPEC-018-agentic-tool-calling.md:593`.

### Q-2 - 256 KiB tool-result cap vs real Cline file reads

Status: CLOSED.

v0.2.1 keeps the 256 KiB per-message tool-result cap as the product decision and makes the failure explicit: HTTP 413, OpenAI-style error envelope, `tool_result_too_large`, `param: "messages[i].content"`, no silent truncation. Aggregate decoded tool-result bytes are capped at 1 MiB. Citations: `specs/SPEC-018-agentic-tool-calling.md:707-715`, `specs/SPEC-018-agentic-tool-calling.md:559`.

## Fresh Findings

### MEDIUM-1 - AC-46 is mandatory but absent from the Cline evidence schema

- User impact: A Cline integrator gets a new response field that is supposed to be passive evidence, but the release gate does not require the Cline transcript to capture or assert it. That leaves ambiguity over the intended UX: should Cline ignore it, should macprovider-side logs record it, or should support/debug artifacts expose it? It is not a graceful-degradation failure, so this is MEDIUM rather than HIGH.
- SPEC location: AC-46 requires every v0.2 provider response to include additive, non-canonicalized `usage.macprovider_model_hash_observed` and says it is observation-only. §10d.0.1 says buyers can passively log it. AC-25a transcript schema requires request/response/SSE transcript hashes, request IDs, streaming-mode header, and pass/fail summary, but not the observed model hash or an assertion that Cline ignores the additive `usage` field safely. Citations: `specs/SPEC-018-agentic-tool-calling.md:595`, `specs/SPEC-018-agentic-tool-calling.md:695-697`, `specs/SPEC-018-agentic-tool-calling.md:549`.
- Recommended fix: Add `usage.macprovider_model_hash_observed` to the AC-25a transcript schema and assertions: each successful provider response records the observed hash when known; Cline does not branch on it; the value is correlated with provider/coordinator request IDs for support/debugging. Also add one sentence to §10d.0.1: "Cline and other OpenAI clients need not act on this field in v0.2; macprovider release evidence/logs capture it for diagnostics and v0.3 registry preparation."

## Fresh Sweep - No New Finding

### Error envelope retry/abandon space

No new PD finding. The current envelope covers Cline's minimum decision space: stable code, retryability, request ID, path ownership via `param`, and inference/settlement booleans. `tool_result_too_large` and request-shape failures are non-retryable; malformed final JSON and downgrade diagnostics are retryable. Citations: `specs/SPEC-018-agentic-tool-calling.md:657-693`, `specs/SPEC-018-agentic-tool-calling.md:721-735`.

### AC-25a pinned Cline version and ClineCore mapping completeness

No new PD finding. AC-25a pins the extension ID and Cline v4.0.0 or a repo version-pin file if the marketplace patch advances. AC-25 avoids exact tool-name brittleness by requiring categories, and the legacy/ClineCore mapping covers the categories needed for the v0.2 release gate: search/list, read, edit, and shell. Citation: `specs/SPEC-018-agentic-tool-calling.md:549-553`.

## Path B Narrative Honesty

PASS.

The buyer-visible changelog is explicit enough for a Cline integrator, not just a SPEC reviewer. It says the locked §10c model-hash registry requirement is amended, registry curation moves to v0.3, and v0.2 substitutes exact-verbatim prompt-echo blocking, tighter final-close settlement gating, and passive model-hash observation. The longer v0.2.1 entry also gives the product rationale and precedent. Citations: `specs/SPEC-018-agentic-tool-calling.md:9-18`, `specs/SPEC-018-agentic-tool-calling.md:641-643`, `specs/SPEC-018-agentic-tool-calling.md:651-655`.

Residual note: §10a still contains historical "v0.2 deliverable" language for the registry, but §10d's reader note is direct enough to prevent a silent-scope-cut reading. No PD finding.

## Verdict

FIX REQUIRED.

Round 1 PD findings are closed. v0.2.1 is not yet READY TO LOCK from the product-design lane because AC-46 creates a new passive buyer-visible field without making Cline release evidence capture or explain it. Once that MEDIUM is fixed, PD has no remaining Cline UX objections.
