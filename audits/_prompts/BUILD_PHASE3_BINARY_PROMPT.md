# Build prompt — Phase 3 binary

Operator-paste prompt to start the Phase 3 binary build. This wraps
SPEC-001 v1.1.1 § 0's operator-paste invocation block with the
self-contained context a fresh Codex CLI session needs.

Paste everything between the markers into a fresh **Codex CLI session**
rooted at `/Users/augstar/macprovider-poc`. The agent will read the spec,
scaffold a Swift package at `phase3-binary/`, and build incrementally
per SPEC-001 § 11's step sequence. Expected wall time: 3–5 weeks of
session work, with operator checkpoints at T+15min and T+1h on day 1
and ad-hoc thereafter.

---

```
=== BEGIN PROMPT ===

You are implementing SPEC-001 v1.1.1 — the Mac Provider Phase 3 binary.
This is a Swift CLI that runs on Apple Silicon Macs and replaces
`mlx_lm.server` as the inference layer in the Mac Provider project.

The spec is at /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
and has been through 3 audit rounds (single, re-audit, joint with
SPEC-002). It is build-ready. Your output is working code, NOT spec
revisions.

## Wrapper directive (from SPEC-001 § 0, verbatim)

"Implement SPEC-001. As you work, maintain a running
phase3-binary/implementation-notes.html that captures anything I should
know about how the implementation diverges from or interprets the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise"

This directive is operative throughout the build. Update
implementation-notes.html as you go, not just at the end. The operator
reads it asynchronously to catch divergence early.

## Required reading (in order, fully — do not skim)

1. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   v1.1.1 — your specification. The whole document is in scope; pay
   particular attention to § 4 (functional requirements), § 6 (interface
   contracts), § 9 (acceptance criteria), § 11 (implementation hand-off
   step sequence).

2. /Users/augstar/macprovider-poc/specs/SPEC-001-audit.md
   /Users/augstar/macprovider-poc/specs/SPEC-001-v1-1-audit.md
   /Users/augstar/macprovider-poc/specs/JOINT-SPEC-001-002-audit.md
   — the audit history. Useful context for understanding why specific
   decisions are written the way they are. NOT required reading
   line-by-line; skim for shape.

3. /Users/augstar/macprovider-poc/HANDOFF.md
   — project context. Read enough to understand what Mac Provider is
   and where Phase 3 sits in the roadmap.

4. /Users/augstar/macprovider-poc/docs/legacy/phase1/PHASE1_REPORT.md
   — Phase 1 evidence. Skim Step 4 (mlx_lm.server quirks), Step 7
   (Cloudflare tunnel behavior), Step 7.5.3 (long-context OOM
   evidence). These are the failure modes your binary must handle.

5. /Users/augstar/macprovider-poc/beta/harness.py
   /Users/augstar/macprovider-poc/beta/workloads_adversarial.py
   — the Phase 2 buyer harness that will be your acceptance-test
   driver. Your binary must serve requests this harness sends.

6. /Users/augstar/macprovider-poc/phase3-binary/implementation-notes.html
   — the empty scaffold + v1.1.1 patch log. You'll append entries to
   the existing sections (Design decisions, Deviations, Tradeoffs,
   Open questions, References consulted) as you work.

## Build environment

You are running on macOS Apple Silicon. The operator has Swift toolchain
available (Xcode 15+ or `xcrun swift --version` returns 5.9+). You will
create a Swift Package Manager project at
`/Users/augstar/macprovider-poc/phase3-binary/`.

Dependencies are pinned in SPEC-001 § 7.1:
- mlx-swift-lm tag 2.29.1, commit 9bff95ca5f0b9e8c021acc4d71a2bbe4a7441631
  (from ml-explore/mlx-swift-examples)
- swift-nio 2.65.0
- swift-log 1.6.0
- swift-argument-parser 1.5.0
- Yams 5.1.0

Use these versions exactly. If any breaks at build time, log the issue
in implementation-notes.html under "Open questions" and STOP for
operator review. Do not silently bump versions.

## Reference hygiene (strict clean-room — non-negotiable)

SPEC-001 § 7.2 establishes strict clean-room for d-inference (the
DARKBLOOM LICENSE AGREEMENT prohibits use in competing products).
You MUST NOT:
- Fetch, clone, or read https://github.com/Layr-Labs/d-inference
- Read any d-inference source files, README, or config files
- Consult third-party blog posts that reproduce d-inference source

You MAY consult:
- mlx-swift-lm source (Apple/mlx-swift-examples, MIT, unrelated to Darkbloom)
- Apple MLX documentation
- OpenAI API reference (https://platform.openai.com/docs/api-reference)
- HuggingFace tokenizer_config.json schema
- This repository's Phase 1+2 materials

If during build you find yourself wondering "how did Darkbloom solve X?",
STOP and add an Open Question to implementation-notes.html. Do not
resolve it by reading their source. The operator will provide guidance
or accept the design you propose independently.

## Build sequence (from SPEC-001 § 11)

Follow this order. Each step has a clear deliverable; complete it before
moving on.

**Step 1. Create Swift package.**
Initialize phase3-binary/ as a Swift Package Manager project. Add the
pinned dependencies. Verify `swift build` produces an empty main.

**Step 2. CLI entry and config loader.**
Implement `--port`, `--model`, `--coordinator`, `--config`, `--log-level`
argument parsing (FR-19). Load YAML config; CLI flag overrides config
which overrides env which overrides defaults (precedence per AC-9).
Deliverable: `macprovider-cli --help` prints usage.

**Step 3. HTTP server + /v1/models endpoint.**
Wire swift-nio HTTP server. Implement GET /v1/models (FR-1). Returns
the model id from CLI/config in OpenAI list shape. Deliverable: `curl
http://localhost:8080/v1/models` returns valid JSON.

**Step 4. /v1/chat/completions non-streaming.**
Implement POST /v1/chat/completions with stream=false. Full request
validation per SPEC-001 § 6.2 (every field, message role rules,
tool-call shape). Load model via mlx-swift-lm; generate response;
return OpenAI-shaped JSON. Deliverable: harness `short_chat` workload
returns status=200 with usage populated.

**Step 5. SSE streaming.**
Implement stream=true. Emit `data: <chunk>\n\n` per SPEC-001 § 6.5.
Synthesize usage chunk before [DONE] (FR-7 — Phase 2 found
mlx_lm.server omits this). Skip any keepalive comments. Deliverable:
harness `streaming_check` workload captures TTFT.

**Step 6. Context pre-flight.**
Implement FR-8 two-stage pre-flight (Tier 1 path runs Stage 2 only).
Tokenize prompt before invoking inference; reject with HTTP 413 if
would exceed safe capacity. Deliverable: synthetic 30K-token request
returns 413 cleanly, no Metal OOM.

**Step 7. Coordinator WebSocket client.**
Outbound WebSocket to coordinator (FR-13). Send hello per SPEC-001
§ 6.5; handle hello_ack; emit heartbeats per ack interval; emit
state_update on state changes; emit drain_status on SIGTERM. Handle
inbound preflight, drain, warm_up. Deliverable: mock coordinator
exchanges full lifecycle.

**Step 8. Capacity advertisement.**
Implement FR-9 (per-RAM-tier caps) and FR-17 (heartbeat capacity
fields including slots_free, slots_total). On startup, run a brief
self-test to measure throughput_tps_estimate. Deliverable: heartbeats
contain accurate live capacity data.

**Step 9. Acceptance tests.**
Implement the scripts referenced by AC-1 through AC-10 in SPEC-001 § 9.
Each script lives at `phase3-binary/scripts/<name>.sh`. The Phase 2
harness with `tunnel_url` pointing at your binary's HTTP endpoint is
the primary AC driver. Deliverable: all 10 ACs pass.

## Operator checkpoint timing

The operator will check on the build at:
- **T+15 minutes** — Are you reading required files? Do you understand
  the scope? Any immediate clarifying questions you'd want answered
  before writing code?
- **T+1 hour** — Step 1 should be complete; Step 2 may be in progress.
  Any spec ambiguity surfaced should be in implementation-notes.html
  Open Questions.
- **Daily during active work** — Operator reads implementation-notes.html
  Open Questions and resolves them.

If you have a question that blocks progress, STOP and write it to
implementation-notes.html Open Questions. The operator will address it
asynchronously. Do not invent answers to substantive spec ambiguity.

## When to stop and ask vs proceed

**Proceed without asking when:**
- The spec answers your question exactly.
- A trivial design choice has an obvious cheap default (pick it, note
  in implementation-notes.html "Design decisions").
- You can satisfy a requirement two equivalent ways; pick the simpler.

**Stop and ask (via Open Questions) when:**
- A requirement conflicts with another requirement.
- The spec assumes a Swift / mlx-swift-lm API that doesn't match the
  pinned version's actual surface.
- An acceptance criterion is testable only with infrastructure that
  doesn't exist yet (acceptable to defer; flag it).
- You need to deviate from a pinned dependency version.
- You discover Phase 1+2 finding that contradicts the spec.

## Acceptance gate

When you believe Step 9 is complete:

1. Run every acceptance test script. Capture pass/fail.
2. Run the Phase 2 cooperative batch through your binary (`cd beta &&
   python harness.py --config <fixture> --batch cooperative
   --verbose`). All workloads must status=200, no stop-token leakage,
   throughput within 10% of Phase 2 baselines.
3. Run the Phase 2 adversarial batch. All must complete with NO HTTP
   500 responses (per AC-2). Provider must remain healthy
   (/v1/health 200) within 30 seconds of workload completion.
4. Run a 24-hour soak test on M4 hardware (operator-assisted).
   Acceptance: zero crashes, memory growth <5%.
5. Write a final summary in implementation-notes.html: "Acceptance
   complete" section with per-AC pass/fail and any deviations.

Total expected effort: 3-5 weeks of active session work.

## Hard rules

1. **Do not modify SPEC-001.** If you find a real spec bug, write it
   to implementation-notes.html Open Questions; do not edit the spec
   file. The operator may amend the spec; you should not.

2. **Do not modify code outside `phase3-binary/`.** Specifically: do
   not touch `beta/`, `specs/`, `phase4-coordinator/`, or any other
   project directory. The harness in `beta/` is the AC driver and
   stays as-is.

3. **Strict clean-room.** Reference hygiene above is enforceable. If
   you find d-inference content via search, close the tab and add an
   Open Question.

4. **Commit checkpoints.** Commit working code at the end of each
   completed Step (1 through 9). Operator can roll back to a step
   boundary if needed. Commit messages: `phase3-binary Step N:
   <deliverable>`.

5. **Never silently bump dependency versions.** Pinned versions are
   contract. If a pin breaks, Open Question.

6. **Honor the OpenAI API contract.** Buyers of your binary expect
   OpenAI-compat shape exactly. Don't add fields, don't rename fields,
   don't change error response shapes.

## Anti-rules

- Do not write build prompts for other SPECs.
- Do not implement Tier 2 features (only Tier 1 hook point names per
  SPEC-001 § 3 architecture diagram).
- Do not implement the coordinator (SPEC-002 territory).
- Do not implement Antseed integration (SPEC-003 territory).
- Do not pre-optimize. Get correctness first, profile later.
- Do not skip writing tests. Every FR should have a unit test where
  feasible; every AC has a script.

## On Tier 2 hook points

SPEC-001 § 3 names Tier 2 hook points (`InputDecryptor` before context
pre-flight, `OutputEncryptor` after response). In v1 (Tier 1), these
are no-op pass-through Swift protocols with default implementations.
Implement them as the named protocol/extension structure so a future
Tier 2 spec can plug in real implementations without rewriting the
request pipeline.

Do NOT implement decryption logic, attestation logic, or secure-enclave
integration. Those are out of scope for v1.

## Final pre-flight before you start

Print to stdout:
- Your understanding of the mission (1 sentence).
- Your understanding of the build sequence (one phrase per step).
- Three things you'll do in the first 15 minutes.
- Any immediate questions for the operator (none is acceptable).

Then begin Step 1 of the build sequence.

Good luck. The spec is solid; the operator is available asynchronously
for substantive questions. Build well.

=== END PROMPT ===
```

---

## How to use

```bash
cd /Users/augstar/macprovider-poc
codex < specs/BUILD_PHASE3_BINARY_PROMPT.md
```

Or paste interactively into Codex.

## What you should see in the first 15 minutes

- Agent reads SPEC-001 (~2-3 min)
- Agent skims supporting docs (~5 min)
- Agent prints its mission understanding + first 15 min plan
- Agent begins Step 1: Swift package init

Red flags to watch for in the first 15 min:
- Agent jumps to coding before reading
- Agent asks for clarification on architecture (means spec is unclear → patch)
- Agent attempts to read d-inference (clean-room violation)
- Agent proposes to modify SPEC-001 (out of scope)

## Operator checkpoints — concrete actions

**T+15 min:**
```bash
cat /Users/augstar/macprovider-poc/phase3-binary/implementation-notes.html | head -100
```
Look for any "Open questions" entries. If there are blocking questions,
answer them before letting the agent continue.

**T+1 hour:**
```bash
ls /Users/augstar/macprovider-poc/phase3-binary/
git -C /Users/augstar/macprovider-poc log --oneline -5
```
Expect Package.swift, Sources/, and a checkpoint commit for Step 1.

**Daily:**
Open implementation-notes.html in a browser, scan all sections. Resolve
any unresolved Open Questions.

## When binary build is done

You'll know because:
1. All 10 ACs pass
2. Phase 2 harness runs through your binary cleanly (replaces `mlx_lm.server`)
3. 24h soak test clean
4. implementation-notes.html has "Acceptance complete" section

At that point: decide whether to start the coordinator build (SPEC-002 v1.0.3
is ready) or take a break and validate the binary with a live contributor
swap first.

## What I'm NOT writing yet

`BUILD_PHASE4_COORDINATOR_PROMPT.md` — you said you want to see how Phase 3
goes first. Sensible. I'll draft it whenever you're ready to launch the
coordinator build, informed by whatever the Phase 3 build surfaced.
