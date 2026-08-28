# DESIGN_SPEC_018_v0_2 — Deliverable #2: Model-hash → tool-call-family registry

## Context

You are designing **SPEC-018 v0.2**, building on locked **SPEC-018 v0.1.5** (`specs/SPEC-018-agentic-tool-calling.md`). v0.2 anchor framework = **Cline** (single primary, expand to others in v0.3+).

**v0.1.5 baseline you must respect:**
- §3.2 modelID-match-required parser (Qwen2.5/Qwen3/Llama-3.3 by modelID substring; no sentinel-only synthesis)
- §10c pre-locked v0.2 invariant: unknown/unregistered `model_hash` MUST fail closed for tool-call synthesis. Operator-only overrides without buyer consent are NON-COMPLIANT. Buyer-consent header + mandatory response field is the override channel.
- §10a #2 names this deliverable but leaves the registry design open.
- SPEC-008 Pillar A model-hash trust layer + SPEC-011 v0.5 warm-swap heartbeat `model_hash` are **already live** end-to-end in production (`phase4-coordinator/internal/pool/provider.go:132-133`, `phase4-coordinator/internal/buyer/server.go:3743-3764`).
- Money-path: fail-closed = no synthesis = no malformed tool-call commit = no settlement risk.

## This deliverable: §10a #2 — model_hash → tool-call-family registry

**Current state (v0.1):** Parser family selection in `phase3-binary/Sources/malibu-cli/ToolCallParser.swift:482-487` uses `modelID` substring match (Qwen2.5/Qwen3 → Qwen family; Llama-3.3 → Llama family). `modelID` is **self-declared by the provider** — a malicious provider can advertise modelID `qwen3-fake` while loading arbitrary weights. v0.1.5 trusts the provider; buyer-side validation obligation per §1 + AC-20 is the v0.1 mitigation.

**Required v0.2 state:** Parser family selection is gated by `model_hash`. A registry maps `{model_hash → tool_call_family}`. Unknown hash → no synthesis (fail closed). The provider cannot lie about which tool-call family it serves because `model_hash` is verified by SPEC-008 against the actually-loaded weights.

## Design questions to answer

### 1. Registry location — three options

**Option A: Binary-baked.** Registry compiled into `phase3-binary` as a static Swift dictionary literal (or a JSON file in `Resources/`). New family entries require a binary release.
- Pros: Tamper-resistant by code-signing; no runtime trust dependency; airgapped-friendly.
- Cons: Glacier-pace updates; every new fine-tune of Qwen3 (e.g. Qwen3-72B variants) requires a binary release; community can't contribute without merging upstream.

**Option B: Coordinator-pushed JSON catalog.** Coordinator owns canonical `{model_hash → family, parser_version, status}` table; pushes to phase3 providers via SPEC-011 warm-swap channel (or new control-plane endpoint). Providers refresh on heartbeat.
- Pros: Operator-curated updates without binary releases; matches existing model-catalog feature on coordinator; aligns with SPEC-017 network-stats / SPEC-001 control plane patterns.
- Cons: Coordinator becomes trust root for tool-call-capability decisions; compromise of coordinator = compromise of tool-call security; provider must trust coordinator's signing/auth.

**Option C: Community-signed TUF-style root.** Decentralized trust root signed by N-of-M committee. Providers pull updates from a CDN/IPFS-style mirror, verify signatures.
- Pros: No single trust authority; community PRs against catalog; auditable signing history; matches "open marketplace" positioning.
- Cons: Heavy engineering (TUF spec, key rotation, signing infra); slow to bootstrap; overkill for current scale; key management is the hard part everyone underestimates.

**Pick one as the v0.2 recommendation. Justify against current macprovider scale (single coordinator on Pearl VPS, single-operator curation today, ~tens of providers, growing).**

### 2. Curation model

For whichever registry location you chose, who decides which `model_hash` enters the registry?
- (i) Single-operator (current coordinator operator, antfleet/Augustas11 today) — fastest, weakest separation.
- (ii) Multi-sig committee (N-of-M signers, requires shared infra) — stronger but coordination overhead.
- (iii) Community PRs against an open catalog file in this repo, merged via the existing PR + audit-loop process — leverages existing trust process; tied to GitHub access.

What's the right v0.2 curation model given current scale?

### 3. Hash → family entry shape

What metadata does each entry carry beyond `model_hash` and `family`?
- `model_hash`: the SHA-256 (or other) hash from SPEC-008.
- `family`: enum {qwen2_5, qwen3, llama3_3, …}.
- `parser_version`: which SPEC-018 parser version is required (so an old binary with stale parser fails-closed cleanly when registry advances)?
- `chat_template_id`: for deliverable #1's multi-turn threading — different families need different multi-turn rendering.
- `status`: enum {enabled, deprecated, revoked} — does the registry support deprecation/revocation?
- `notes`: human-readable provenance — who added it, when, why.

What's the minimal-yet-future-proof entry shape?

### 4. Fail-closed semantics (already pre-locked in §10c)

§10c says unknown/unregistered `model_hash` MUST fail closed for tool-call synthesis. Buyer-consent header + mandatory response field is the override channel. Make this concrete:
- What's the buyer-consent header name? Proposal: `X-MacProvider-Allow-Unregistered-ToolCall: true`.
- What's the mandatory response field shape? Proposal: in non-streaming response, `usage.macprovider_tool_call_attestation = {registered: bool, model_hash: hex, family_used: str | null}`. In streaming, last chunk's `usage` carries it.
- What does the response look like when buyer didn't send consent and provider sees unregistered hash? Pure-text synthesis (no `tool_calls[]`) is the v0.1.5 fallback semantics; v0.2 inherits that.

### 5. Registration workflow

Concretely: a new Qwen3 fine-tune appears (e.g., `qwen3-fp4-coder-32b-v2`). How does it get into the registry?
- Step-by-step: who runs what command, what audit gates apply, how the change propagates to providers, how long until buyers can trust tool-call synthesis from that model.
- What's the rollback path if a registered hash turns out to be malicious?

### 6. Concurrency: registry-update during in-flight requests

A provider has a tool-call-eligible request in flight (50ms parse window). Coordinator pushes a registry update that revokes the model_hash mid-request. What's the contract?
- (a) Use registry version at request-start time (snapshot semantics).
- (b) Re-check registry at each commit decision (latest wins, may revoke mid-stream).
- (c) Registry updates atomic with provider warm-swap (no in-flight collision possible).

### 7. Coordinator-side enforcement

§8.4 commit-worthy validator (v0.1.5) lives on coordinator. v0.2 means coordinator must also know about the registry, because it commits malformed-detection decisions before settlement. Or does v0.2 keep registry purely provider-side and trust the provider's "I synthesized tool calls because hash X is registered" claim?
- If coordinator-side, how does coordinator get the registry? Same source as provider, or different?
- Trust-asymmetry analysis: provider lies about model_hash → SPEC-008 catches; provider lies about "hash is registered" → who catches?

## Output format

Produce a normative design recommendation covering all 7 questions. Lead with the registry-location choice (A/B/C) + rationale. Concrete entry shape, header names, response field shapes. Workflow as numbered steps. Trust-model analysis with explicit threat enumeration.

This deliverable is the **highest-strategic-optionality** item in v0.2. The choice here shapes macprovider's long-term governance posture. Be opinionated and justify trade-offs.
