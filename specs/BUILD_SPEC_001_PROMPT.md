# Build prompt — SPEC-001 (Phase 3 binary)

This document contains the operator-paste prompt to produce
`specs/SPEC-001-phase3-binary.md`. The receiving agent **writes the spec
document**; it does not build the binary itself. Building happens in a
separate later session using SPEC-001 as input.

Paste everything between the `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
lines into a fresh Claude Code or Codex CLI session rooted at
`/Users/augstar/macprovider-poc`. Expected duration: ~2 hours of focused
autonomous spec writing.

---

```
=== BEGIN PROMPT ===

You are writing SPEC-001 for the Mac Provider project. Your output is a
single markdown file at /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
plus a paired empty scaffold at /Users/augstar/macprovider-poc/phase3-binary/implementation-notes.html
that a *future* build session will populate.

You are NOT building the binary. You are writing the spec a future session
will implement.

## Required reading (in this order — read fully before writing anything)

1. /Users/augstar/macprovider-poc/HANDOFF.md
   — full project context, Phase 1+2 history, strategic decisions
2. /Users/augstar/macprovider-poc/results/REPORT.md  (skim — Phase 1 evidence)
3. /Users/augstar/macprovider-poc/beta/PHASE2_UPGRADED_PLAN.md
   — what Phase 2 was meant to find
4. /Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md
   — read the **decision log** in particular; every row is a spec input
5. /Users/augstar/macprovider-poc/beta/harness.py
6. /Users/augstar/macprovider-poc/beta/workloads_adversarial.py
   — the failure modes the binary must handle
7. /Users/augstar/macprovider-poc/beta/stop_tokens.py
   — per-model token derivation pattern

## Mission of SPEC-001

A Swift CLI binary that runs on Apple Silicon Macs and replaces
`mlx_lm.server` as the inference layer for Mac Provider contributors.

**Tier 1 launch posture** — cooperative trust pool. Operator vouches for
contributors; buyers trust the operator's curation; no buyer-side privacy
claim. No attestation, no secure enclave, no encrypted-input flows.

**Tier 2 roadmap-ready architecture** — the design MUST leave room for a
future protocol upgrade that adds:
  • TEE/secure-enclave-bound inference (privacy attestation)
  • Buyer-side encryption of prompts
  • Coordinator-mediated attestation chain
without requiring a rewrite. Concretely: clean middleware boundaries,
pluggable trust models, request handler chains that an attestation layer
can be inserted into, coordinator protocol that can advertise tier
capability (`tier: 1` vs `tier: 2`).

This is the most consequential architectural decision in SPEC-001.
Spend time on it. Make the Tier 2 hook points explicit and named.

## What SPEC-001 must contain (sections, in order)

### 0. Operator-paste invocation block (verbatim, at the top)

```
Implement SPEC-001. As you work, maintain a running
phase3-binary/implementation-notes.html that captures anything I should
know about how the implementation diverges from or interprets the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise
```

### 1. Mission (1 paragraph)
   What this binary is, who it serves, why it exists vs `mlx_lm.server`.

### 2. Scope
   • **In Tier 1 launch scope** — bullet list, exhaustive
   • **In Tier 2 roadmap scope (designed-in but not implemented)** — list
   • **Out of scope** — list (e.g. multi-model rotation, billing, reward
     distribution — those belong to other SPECs)

### 3. Architecture overview
   ASCII or markdown diagram of components. Must show where Tier 2 hooks
   would plug in. Components likely include:
   • CLI entry / arg parsing
   • Config loader
   • Model loader (mlx-swift-lm wrapper)
   • HTTP server (Swift NIO or equivalent)
   • Request handler chain (validation → trust model → inference → response)
   • SSE streaming layer
   • Coordinator client (outbound WebSocket, Phase 4 dependency)
   • Capacity advertiser
   • Logging + metrics
   Name the **Tier 2 hook points** in this diagram explicitly.

### 4. Functional requirements (FR-1, FR-2, ... numbered, testable)
   At minimum these requirements (expand each into proper spec language):
   FR-1   /v1/models returns currently-loaded model id
   FR-2   /v1/chat/completions (non-streaming) accepts OpenAI-format request
   FR-3   /v1/chat/completions with stream=true returns SSE
   FR-4   SSE stream is OpenAI-compat (data: prefix, [DONE] terminator)
   FR-5   No SSE keepalive comment lines emitted (Phase 1 quirk eliminated)
   FR-6   Stop-token defensive stripping per loaded model's
          tokenizer_config.json (Phase 1+2 finding)
   FR-7   Streaming responses include synthesized `usage` chunk before
          [DONE] (Phase 2 finding — mlx_lm.server omits this)
   FR-8   Context length pre-flight: tokenize incoming prompt, reject with
          HTTP 413 if would exceed safe capacity for current RAM tier
          (Phase 1 finding — Metal OOM at ~26K on 8GB)
   FR-9   Per-RAM-tier capacity advertised at startup:
          • 8 GB  → ~20K tokens max context, single concurrency
          • 16 GB → ~50K tokens, 2-way concurrency
          • 32 GB → ~120K tokens, 4-way concurrency
          (numbers are starting estimates; binary measures and refines)
   FR-10  Mid-stream client disconnect releases request slot within 5s
          (Phase 2 adversarial finding)
   FR-11  Concurrent request handling with bounded queue
   FR-12  Graceful SIGTERM (drains in-flight requests up to N seconds)
   FR-13  Outbound coordinator WebSocket (Phase 4 dependency — spec the
          message envelope, leave coordinator URL configurable)
   FR-14  Tier capability announcement on coordinator handshake
          ({tier: 1} now; upgrade to {tier: 2} hook in place)
   ... continue to ~20 FRs

### 5. Non-functional requirements
   • Performance: ≥90% of mlx_lm.server throughput baseline on identical model
   • Cold start: <30s on M4
   • Memory: stable over 24h sustained load (no growth >5% from baseline)
   • Startup robustness: model load failure → exit cleanly with diagnostic
   • Code style: Swift Package Manager, no Xcode-only deps
   • Signing: signed for macOS Gatekeeper (developer ID, not notarized
     for first version)

### 6. Interface contracts
   For each endpoint, exact request + response JSON schema. Include:
   • /v1/models (request: none; response: {object, data:[{id, object,
     created}]})
   • /v1/chat/completions (full OpenAI schema for both stream=true and
     stream=false)
   • Coordinator WebSocket envelope:
     - Handshake (tier, model, capacity, hostname)
     - Capacity heartbeat
     - Pre-flight check (coordinator asks "can you take N tokens?")
     - Drain signal (coordinator: "stop accepting new")

### 7. Dependencies & references

#### Direct dependencies (use as libraries)
   • mlx-swift-lm (MIT) — apple/mlx-swift-examples
   • swift-nio (Apache 2.0)
   • SwiftLog (Apache 2.0)
   • Swift 5.9+, macOS 14+

#### Reference implementation (open source — study with discipline)
   • Darkbloom (LayrLabs) d-inference: https://github.com/layr-labs/d-inference
     - Operating principle: **informed by, not copied**
     - PERMITTED study: server bootstrap, mlx-swift-lm wiring patterns,
       OpenAI HTTP compat layer shape, SSE streaming, model loading,
       port handling, graceful shutdown
     - OUT OF SCOPE (do NOT replicate, do NOT study deeply): privacy /
       attestation modules, secure enclave usage, key derivation,
       sealed-encryption flows, buyer-auth tied to their attestation chain
     - Their privacy stack is patented; our Tier 1 architecture does not
       need it. Tier 2 roadmap will design our own implementation when
       the time comes, also from public spec.
   • Verify the d-inference license at spec-write time and record the
     SPDX id in the spec
   • Attribution: SPEC-001 binary, when built, will ship a
     THIRD_PARTY_NOTICES.md crediting Darkbloom d-inference as reference
     for the non-privacy components

#### Public spec sources
   • Darkbloom's academic paper (cite normally)
   • Apple MLX documentation
   • OpenAI API reference
   • HuggingFace tokenizer_config.json schema

#### Internal sources
   • Phase 1 results/REPORT.md
   • Phase 2 beta/DECISION_CRITERIA.md decision log

### 8. Phase 1 + 2 findings the binary must encode

Every entry in beta/DECISION_CRITERIA.md's "Decision log" table becomes
one or more functional requirements. As of spec writing time, the log
contains at least:

   D1 — 502 vs 530 routing distinction
        → FR mapping: coordinator client must distinguish these states
          and report them differently to the coordinator

   D2 — Post-wake throughput dip (-12% first request after sleep)
        → FR mapping: binary must support a "warm-up" hook the
          coordinator can fire to prime the model after wake events

   D3 — Capacity-vs-quality routing tradeoff (smaller-model on slower
        hardware beats bigger-model on faster hardware)
        → FR mapping: capacity advertisement must include model size +
          throughput estimate, not just RAM tier

Re-read the decision log at spec-write time; new entries may have landed
between this prompt being written and the spec being written.

### 9. Acceptance criteria
   • All 5 Phase 2 cooperative workloads pass with same metrics as Phase 2
     baseline (within 10% throughput, identical HTTP shape)
   • All 5 Phase 2 adversarial workloads complete without crashing the
     binary or its host process
   • 24h soak test on M4 hardware: zero crashes, memory growth <5%
   • Phase 2 harness can swap mlx_lm.server URL for SPEC-001 binary URL
     and see no test failures
   • Coordinator client connects to a mock coordinator and exchanges
     handshake + capacity heartbeat

### 10. Open questions for operator
   Flag at least 5 things you weren't sure about. Examples:
   • Streaming usage chunk format — exact wire format (some clients
     expect usage at end, some inline, some not at all)
   • Should the binary auto-start mlx_lm.server-compatible behavior or
     break compat where Phase 1 quirks said it should?
   • Coordinator URL discovery — env var? config file? CLI flag?
     embedded at build time?
   • Logging destination — stdout for launchd / Console.app? local
     SQLite for self-reporting? both?
   • How does the binary report its tier to the coordinator on
     handshake — version string? explicit field?

### 11. Implementation hand-off

Final section of SPEC-001 must include a "Hand-off to implementer"
sub-section that gives the future build session a working starting
sequence:

   1. Create Swift package at phase3-binary/
   2. Add mlx-swift-lm dependency
   3. Implement /v1/models first (smallest scope, proves wiring)
   4. Implement /v1/chat/completions non-streaming (next smallest)
   5. Add SSE streaming
   6. Add context pre-flight
   7. Add coordinator client
   8. Add capacity advertisement
   9. Acceptance test against Phase 2 harness

## Reference hygiene rules — operate by these throughout

1. You MAY look at d-inference's repo structure, README, license, and
   non-privacy module names to understand what the project covers.
2. You MAY read d-inference source files NOT in privacy/attestation/
   secure-enclave directories.
3. You MUST NOT copy d-inference code verbatim into the SPEC. The SPEC
   is requirements, not implementation.
4. You MUST NOT read d-inference's privacy/attestation modules. If a
   file looks like it might be that, skip it. Examples of likely names:
   `Attestation/`, `SecureEnclave/`, `Sealed/`, `Crypto/`, anything with
   `privacy` or `attest` in the path.
5. If you DO read a d-inference file to inform a spec decision, note
   which file in the SPEC's "References used during spec writing"
   appendix. Transparency over silence.

## Output files

1. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   — the full spec, sections 0-11 above

2. `/Users/augstar/macprovider-poc/phase3-binary/implementation-notes.html`
   — scaffold only (the build session populates this). Structure:
   ```html
   <!doctype html><html><head>
   <title>SPEC-001 implementation notes</title>
   <style>
   body { font: 14px/1.45 -apple-system, system-ui, sans-serif;
          margin: 2em; max-width: 980px; }
   h1 { font-size: 1.4em; }
   h2 { font-size: 1.1em; border-bottom: 1px solid #ccc;
        padding-bottom: 0.2em; margin-top: 2em; }
   .meta { color: #666; font-size: 0.9em; }
   .entry { border-left: 3px solid #ddd; padding-left: 1em;
            margin: 1em 0; }
   .entry time { color: #888; font-size: 0.85em; }
   code { background: #f4f4f4; padding: 0.1em 0.3em; border-radius: 3px; }
   </style></head><body>
   <h1>SPEC-001 — phase3-binary — implementation notes</h1>
   <p class=meta>Status: <strong>not started</strong> · Spec: 
   <a href="../specs/SPEC-001-phase3-binary.md">SPEC-001</a></p>
   <section><h2>Design decisions</h2>
   <p class=meta>Choices made where the spec was ambiguous.</p>
   </section>
   <section><h2>Deviations from spec</h2>
   <p class=meta>Intentional departures, with reason.</p>
   </section>
   <section><h2>Tradeoffs considered</h2>
   <p class=meta>Alternatives evaluated and why we picked what we did.</p>
   </section>
   <section><h2>Open questions for operator</h2>
   <p class=meta>Things needing operator confirmation or revision.</p>
   </section>
   <section><h2>References consulted</h2>
   <p class=meta>External resources read during implementation, with
   what was taken. Especially d-inference paths consulted.</p>
   </section>
   </body></html>
   ```

3. `/Users/augstar/macprovider-poc/specs/README.md`
   — index of all SPECs (just SPEC-001 for now, with status and link).
   Append-only; future SPECs will add rows.

## Hard rules

1. Output is markdown for the spec, HTML for implementation-notes
   scaffold. No code in the spec — interfaces only.
2. The spec is a writeable document for human + agent consumption.
   Write in plain English. Avoid jargon where simpler words work.
3. Numbered requirements are mandatory. Use FR-N, NFR-N, AC-N for
   functional / non-functional / acceptance criteria. The build
   session will reference these by number.
4. Be opinionated. Where there's a defensible default, pick it and
   note the alternative in "Open questions" so the operator can
   challenge. Do NOT leave large undefined areas.
5. Honest unknowns belong in section 10 (Open questions). Don't pad
   them with fake confidence.
6. Length budget: 800-1500 lines of markdown for the spec itself.
   Long is OK if every line earns its keep. Short is OK if you've
   actually covered everything.

## Anti-rules — things NOT to do

• Don't write build steps (no `swift build` commands, no Xcode
  invocations). That's the build session's job.
• Don't add code samples beyond JSON schemas and ASCII diagrams.
• Don't reference internal implementation files that don't exist yet.
• Don't speculate about Tier 2 implementation details beyond the
  hook-point names. Tier 2 gets its own SPEC later.
• Don't make assumptions about contributor agreements, reward
  structure, or business logic. Those belong in other SPECs.

## When you finish

1. Re-read SPEC-001 end to end as if you were the implementer who'll
   build it next. Flag anything ambiguous to yourself; fix or move
   to "Open questions."
2. Append a "References used during spec writing" appendix listing
   any d-inference file you opened.
3. Commit with message: 
   "SPEC-001: Phase 3 binary spec written, Tier 1 launch + Tier 2 roadmap-ready"
4. Print a < 200-word summary of the spec's most consequential
   decisions and the count of open questions.

That's the whole job. Begin by reading the required files in order.

=== END PROMPT ===
```

---

## How to use

```bash
cd /Users/augstar/macprovider-poc

# Open the prompt file
open specs/BUILD_SPEC_001_PROMPT.md
# Copy everything between BEGIN/END PROMPT into Claude Code / Codex

# Alternative: stdin pipe
claude < specs/BUILD_SPEC_001_PROMPT.md
```

## What you'll get back

- `specs/SPEC-001-phase3-binary.md` — full spec (~1000-1500 lines)
- `phase3-binary/implementation-notes.html` — empty scaffold for the build session
- `specs/README.md` — spec index
- A `<200 word` summary in the agent's final reply

## Then what

You review SPEC-001, resolve the open questions (section 10), commit the
spec. A separate later session uses the operator-paste invocation block at
the top of the spec to start the build, populating implementation-notes.html
as it goes.

## What makes this prompt different from earlier ones

1. **Output is a spec, not code.** Resists the agent's urge to start building.
2. **Tier 1 launch + Tier 2 roadmap** baked into every architecture decision.
3. **Reference hygiene** is explicit but practical — d-inference is open
   source, we may read it, but only the non-privacy parts and with attribution.
4. **The wrapper template** ("maintain implementation-notes.html...") is
   built into Section 0 verbatim, so the build session inherits it without
   the operator copy-pasting twice.
5. **Decision log → FR mapping** is explicit. Every entry in
   DECISION_CRITERIA.md's decision log becomes one or more requirements.
   Catches Phase 3 spec drift before it starts.
