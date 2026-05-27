# Build prompt — Phase 4 coordinator

Operator-paste prompt to start the Phase 4 coordinator build. Wraps
SPEC-002 v1.0.3 § 0's operator-paste invocation with the self-contained
context a fresh Codex CLI session needs.

Paste everything between the markers into a fresh **Codex CLI session**
rooted at `/Users/augstar/macprovider-poc`. The agent will read the spec,
scaffold a Go module at `phase4-coordinator/`, and build incrementally
per SPEC-002 § 13. Expected wall time: 2-3 weeks of session work, with
operator checkpoints at T+15min and T+1h on day 1.

This prompt is structurally similar to BUILD_PHASE3_BINARY_PROMPT.md.
Same checkpoint pattern, same implementation-notes.html discipline.
Run this AFTER the Phase 3 binary's M4 parity validation passes — the
coordinator's mock-provider acceptance tests benefit from real-binary
testing later, and parallel binary+coordinator builds risk early
protocol drift.

---

```
=== BEGIN PROMPT ===

You are implementing SPEC-002 v1.0.3 — the Mac Provider Phase 4
coordinator. This is a Go service that runs on a VPS, accepts inbound
WebSocket connections from Phase 3 binaries, and exposes an
OpenAI-compatible HTTP API to buyers.

The spec is at /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md
and has been through 4 audit rounds (single SPEC-002 audit, joint
SPEC-001+SPEC-002 audit, final SPEC-002 re-audit, plus post-patch
verifications). It is build-ready. Your output is working code, NOT
spec revisions.

## Wrapper directive (from SPEC-002 § 0, verbatim)

"Implement SPEC-002. As you work, maintain a running
phase4-coordinator/implementation-notes.html that captures anything I
should know about how the implementation diverges from or interprets
the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise"

This directive is operative throughout the build. Update
implementation-notes.html as you go, not just at the end.

## Required reading (in order, fully — do not skim)

1. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md
   v1.0.3 — your specification. The whole document; pay particular
   attention to § 4 (FRs), § 5 (routing algorithm), § 7 (interface
   contracts), § 11 (acceptance criteria), § 13 (build sequence).

2. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   v1.1.1 — the BINARY spec. SPEC-001 § 6.5 defines the wire protocol
   you MUST speak verbatim from the coordinator side. SPEC-001 is
   LOCKED — if you find a protocol issue, surface it as an Open
   Question; do not silently amend SPEC-001.

3. /Users/augstar/macprovider-poc/specs/SPEC-002-audit.md
   /Users/augstar/macprovider-poc/specs/SPEC-002-v1-0-2-audit.md
   /Users/augstar/macprovider-poc/specs/JOINT-SPEC-001-002-audit.md
   — the audit history. Skim for context; not required line-by-line.

4. /Users/augstar/macprovider-poc/HANDOFF.md
   — project context. Read enough to understand what Mac Provider is
   and how Phase 4 connects Phase 3 binaries to Antseed buyers.

5. /Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md
   — read the decision log. It has 9+ entries documenting Phase 3 and
   coordinator-relevant findings from real Phase 2 traffic. Notably:
     * Entry 9: MLX max_concurrency=1 — providers advertise slots_total=1
       regardless of RAM tier. Your routing logic should expect
       single-slot providers as the v1 norm.
     * 502/530 distinction (FR-P11) is real — observed in production traffic.
     * Provider reliability varies 36-100% across days based on hardware
       usage pattern (lid-close cycles). The state machine must be robust.

6. /Users/augstar/macprovider-poc/beta/harness.py
   /Users/augstar/macprovider-poc/beta/workloads.py
   /Users/augstar/macprovider-poc/beta/workloads_adversarial.py
   — the Phase 2 harness. This is your buyer for AC-2 and AC-3. The
   harness fires SPEC-001-§6.2-shaped requests; your coordinator must
   forward them to providers and relay responses.

7. /Users/augstar/macprovider-poc/phase3-binary/implementation-notes.html
   — Phase 3 binary build log. Has useful context on toolchain
   surprises (Xcode/Metal Toolchain), MLX serialization decision, and
   real test data. Especially helpful for AC mock-provider design.

8. /Users/augstar/macprovider-poc/phase4-coordinator/implementation-notes.html
   — empty scaffold + v1.0.3 patch log. You'll append entries as you
   work.

## Build environment

You are on macOS Apple Silicon (operator's M1) for development. The
production deployment target is the operator's existing VPS at
165.22.182.207 (Linux). Cross-compile via `GOOS=linux GOARCH=amd64 go build`.

Go toolchain prerequisites:
- Go 1.22+ (`go version`). If not installed, request operator install
  via `brew install go`. Do NOT attempt to install Go yourself.

Dependencies are pinned in SPEC-002 § 8.1:
- github.com/gobwas/ws v1.4.0
- github.com/go-chi/chi/v5 v5.1.0
- modernc.org/sqlite v1.33.0
- github.com/rs/zerolog v1.33.0
- github.com/google/uuid v1.6.0
- gopkg.in/yaml.v3 v3.0.1

Use these versions exactly. If any breaks at build time (the way mlx-swift
"mlx-libraries" vs "mlx-swift-examples" did during Phase 3), log to
implementation-notes.html under Open Questions and STOP for operator
review. Do not silently bump versions.

## Reference hygiene (strict clean-room — non-negotiable)

SPEC-002 § 8.2 (adapted from SPEC-001 § 7.2) establishes strict
clean-room for d-inference. The DARKBLOOM LICENSE AGREEMENT prohibits
use in competing products. You MUST NOT:
- Fetch, clone, or read https://github.com/Layr-Labs/d-inference
- Read any d-inference source files, README, or config files
- Consult third-party blog posts that reproduce d-inference source

You MAY consult:
- Go standard library docs (pkg.go.dev)
- gobwas/ws, go-chi, zerolog, modernc.org/sqlite docs (MIT/BSD/Apache)
- OpenAI API reference
- Cloudflare's public docs on WebSocket tunneling (informational only)
- This repository's Phase 1-3 materials

If you wonder "how did Darkbloom solve X in their coordinator?", STOP
and add an Open Question. Do not resolve by reading their source.

## Build sequence (from SPEC-002 § 13)

Each step has a clear deliverable; complete it before moving on.

**Step 1. Init Go module.**
Initialize phase4-coordinator/ as a Go module
(`go mod init github.com/augstar/macprovider-coordinator` or similar
path; the operator's choice doesn't affect functionality). Add the
pinned dependencies. Verify `go build ./...` produces an empty main.

**Step 2. WebSocket /ws/provider endpoint + hello/hello_ack.**
Implement the WebSocket server that accepts provider connections. Parse
the hello message per SPEC-001 § 6.5 verbatim. Validate fields,
generate assigned_id (UUID), look up provider_id in static config,
respond hello_ack OR close WebSocket with appropriate FR-P13 close code
(4001-4005 / 4429). NOTE: SPEC-002 v1.0.3 v1 has provider auth
OPTIONAL — accept the WebSocket upgrade with or without an
Authorization header.

Deliverable: a mock provider that opens a WebSocket and sends a valid
hello receives hello_ack with assigned_id; a hello with bad
provider_id sees WS close code 4002 "unknown_provider_id: <id>".

**Step 3. Pool registry + heartbeat handling.**
Implement the pool data structure (concurrent-safe map). Process
heartbeat messages, update pool entries with the static config
endpoint_url. Implement staleness detection (warn on 1.5x heartbeat
interval). Deliverable: pool shows connected providers with live
capacity data; /poolz operator endpoint can dump it.

**Step 4. State machine for provider states.**
Implement state transitions from state_update messages. Implement
routing eligibility rules (only ready + slots_free > 0). Implement
wake detection (heartbeat gap > 120s → warm_up dispatch per FR-P8).
Implement disconnect detection + grace period.

Deliverable: a mock provider that sends state_update transitions
correctly cycles through ready/busy/degraded/draining/unavailable in
/poolz output.

**Step 5. /v1/models aggregation.**
Implement the buyer HTTP server using go-chi. GET /v1/models returns
the union of model_id values across all ready providers in OpenAI
list shape. Deliverable: with 2 mock providers serving the same model
plus 1 serving a different model, /v1/models returns 2 unique model
ids.

**Step 6. /v1/chat/completions non-streaming routing.**
Validate the request per SPEC-002 § 7.2 (which mirrors SPEC-001 § 6.2
verbatim — DO follow the validation order step 1→6, this is the
finding that distinguishes our binary from mlx_lm.server). Run the
routing algorithm from § 5 (X-MacProvider-Session > X-MacProvider-Provider
> default). Forward the request as HTTP POST to the chosen provider's
endpoint_url. Return the provider's JSON response.

Deliverable: Phase 2 harness `short_chat` workload against the
coordinator returns HTTP 200 from the chosen provider.

**Step 7. SSE streaming pass-through.**
Implement stream=true path. Receive the provider's SSE stream chunk by
chunk, relay each event to the buyer in real-time, add
X-MacProvider-Provider + X-MacProvider-Route headers.

Deliverable: Phase 2 harness streaming_check workload captures TTFT
through the coordinator.

**Step 8. Preflight + capacity routing.**
Implement FR-P7 preflight send for context-heavy requests (>
preflight_threshold_tokens). Handle preflight_ack with all 6 reason
enum values per § 7.1. Implement FR-R5 context-length filter and
FR-P11 recovery preflight (request_id prefix "recovery-probe-").

Deliverable: synthetic 30K-token request against a small-context
provider routes to a different provider OR returns 413 cleanly.

**Step 9. Auth (token CLI + validation).**
Implement the auth path B (Authorization: Bearer <token>) per § 7.3.
coordinator-cli issue-token and revoke-token subcommands. SQLite
provider_tokens table. Token validation on WebSocket upgrade.

NOTE: v1 default is auth OPTIONAL (path A); auth is a forward-compat
opt-in. The coordinator must handle BOTH the no-header case (admit
on static config match) and the bearer-token case (validate against
hash store).

Deliverable: AC-5 token flow tests pass — issued token connects, revoked
token rejected with WS close 4005, revoke-and-kick CLI closes active session.

**Step 10. Operator endpoints (/healthz, /poolz, /admin/blacklist).**
Implement per § 7.4. /admin/blacklist must match the AC-10 two-phase
contract (immediate draining state, deferred WS close + removal).

Deliverable: AC-10 passes.

**Step 11. Acceptance tests.**
Implement scripts in phase4-coordinator/scripts/ that drive each AC.
Phase 2 harness (with config pointed at the coordinator's port)
is the primary AC-2/AC-3 driver. Mock provider for AC-1/AC-7/AC-8/
AC-8b. Mock coordinator from SPEC-001 AC-5 informs the mock provider
design.

Deliverable: all 10+ ACs pass (AC-1 through AC-10 + AC-8b warm-up).

## Operator checkpoint timing

The operator will check on the build at:
- **T+15 minutes** — Are you reading required files? Do you understand
  the scope? Any immediate clarifying questions?
- **T+1 hour** — Step 1 done; Step 2 may be in progress. Any spec
  ambiguity surfaced should be in implementation-notes.html Open
  Questions.
- **Daily during active work** — Operator reads Open Questions and
  resolves them.

## When to stop and ask vs proceed

**Proceed without asking when:**
- The spec answers your question exactly.
- A trivial design choice has an obvious cheap default.

**Stop and ask (via Open Questions) when:**
- A requirement conflicts with another or with SPEC-001's locked protocol.
- A pinned dependency version's actual API doesn't match the spec's
  assumptions.
- An acceptance criterion requires infrastructure not yet in place
  (acceptable to defer; flag it).
- You discover a Phase 1-3 finding that contradicts the spec.

## Acceptance gate

When you believe Step 11 is complete:

1. Run every acceptance test script. Capture pass/fail.
2. Run the Phase 2 cooperative batch through the coordinator (pointing
   at a pool of 2 mock providers): `cd beta && python harness.py
   --config <fixture> --batch cooperative --verbose`. All 6 workloads
   must status=200, no stop-token leakage, throughput within 10% of
   Phase 2 baselines.
3. Run the Phase 2 adversarial batch. All must complete with NO HTTP
   500 responses. Coordinator process must remain healthy (/healthz
   200) within 30 seconds of workload completion.
4. Operator-assisted: deploy to VPS at 165.22.182.207, point at a
   real Phase 3 binary, run a 24-hour soak (this becomes the AC-3
   replacement at coordinator scope).
5. Write a final summary in implementation-notes.html: "Acceptance
   complete" with per-AC pass/fail.

Total expected effort: 2-3 weeks of active session work.

## Hard rules

1. **SPEC-001 is locked.** If you find a real protocol issue while
   implementing SPEC-002 coordinator side, write it to Open Questions;
   do not edit SPEC-001. The operator decides whether to amend.

2. **Do not modify code outside `phase4-coordinator/`.** Specifically:
   beta/, phase3-binary/, specs/ are all out of scope. The Phase 2
   harness in beta/ is your AC driver and stays as-is.

3. **Strict clean-room.** Reference hygiene above is enforceable.

4. **Commit checkpoints.** Commit working code at the end of each
   completed Step (1 through 11). Commit messages:
   `phase4-coordinator Step N: <deliverable>`.

5. **Never silently bump dependency versions.** Pinned versions are
   contract. If a pin breaks, Open Question.

6. **Honor the wire protocol from SPEC-001 § 6.5 exactly.** Don't
   rename fields, don't add fields the binary won't recognize, don't
   change enum values. Single-direction `nak` (P→C only) is enforced;
   coordinator rejections use WebSocket close codes per SPEC-002 FR-P13.

## Anti-rules

- Do not write build prompts for other SPECs.
- Do not implement Tier 2 features (only Tier 1 hook point names per
  SPEC-002 § 3 architecture).
- Do not implement Antseed seller integration (SPEC-003 territory).
- Do not implement buyer-facing API auth (SPEC-006 territory). v1 has
  no buyer auth.
- Do not implement smart router caching (SPEC-004 territory). v1
  routing is utilization-favoring per FR-R1.
- Do not pre-optimize. Get correctness first, profile later.
- Do not skip writing tests. Every FR should have a unit test where
  feasible; every AC has a script.

## On Tier 2 hook points

SPEC-002 § 3 names Tier 2 hook points (AttestationVerifier,
BuyerEncryptionRelay, TrustChainAuditor). In v1, these are no-op
pass-through Go interfaces with default implementations.

Implement them as the named interface/struct structure so a future
Tier 2 spec can plug in real implementations without rewriting the
request pipeline. Do NOT implement attestation logic, encryption
relay, or trust chain auditing — those are out of scope for v1.

## Phase 3 binary findings worth knowing

The Phase 3 binary build surfaced two operationally-important findings
your coordinator must accommodate:

1. **MLX max_concurrency = 1 across all RAM tiers.** Providers will
   advertise slots_total=1 regardless of hardware (per decision log
   entry 9). Coordinator routing already filters slots_free>0, so this
   works without any code change — but your AC tests should mock
   providers with slots_total=1, not 2 or 4. Don't assume larger pools
   per provider.

2. **mlx_lm.server validates model existence before request shape**;
   our binary correctly validates shape first (returning 400 for
   malformed JSON, not 404). Your coordinator's validation order in
   § 7.2 must match SPEC-001 § 6.2's strict order (1→6). Adversarial
   workloads (specifically malformed_tool_call) tested this and
   surfaced the gap; your AC-3 against the harness will too.

## Final pre-flight before you start

Print to stdout:
- Your understanding of the mission (1 sentence).
- Your understanding of the 11-step build sequence (one phrase each).
- Three things you'll do in the first 15 minutes.
- Any immediate questions for the operator (none is acceptable).

Then begin Step 1.

Good luck. The spec is solid (4 audit rounds), Phase 3 binary
acceptance proved the wire protocol works end-to-end, and the operator
is available asynchronously for substantive questions. Build well.

=== END PROMPT ===
```

---

## How to use

```bash
cd /Users/augstar/macprovider-poc
codex < specs/BUILD_PHASE4_COORDINATOR_PROMPT.md
```

Or paste interactively into Codex.

## When to launch this prompt

**Wait for the Phase 3 binary's M4 parity validation to land cleanly first.** Reasons:

1. **Real-binary integration testing** — coordinator's mock providers approximate the binary, but a real binary catches drift between SPEC-001 spec and SPEC-001 implementation.
2. **Decision log finalization** — Phase 3 binary may surface 1-2 more findings during the parity test that would change the coordinator's AC-1 mock-provider design.
3. **Operator bandwidth** — running two parallel multi-week build sessions doubles the implementation-notes.html review load.

Realistic schedule:
- Today: 3h local soak finishes
- Tomorrow morning: M4 parity validation (if M4 partner has a window)
- Tomorrow afternoon OR Friday: launch Phase 4 coordinator build

If the M4 parity validation reveals a SPEC-001 spec gap, we patch that first; otherwise SPEC-002 is unaffected and the coordinator build proceeds.

## What's different vs the Phase 3 binary build prompt

| | Phase 3 binary | Phase 4 coordinator |
|---|---|---|
| Language | Swift | Go |
| Build environment | Xcode + Metal Toolchain | `brew install go` |
| Toolchain risk | High (Xcode quirks) | Low (Go is famously simple) |
| Wire protocol | implements SPEC-001 § 6.5 binary-side | implements same protocol coordinator-side |
| MLX integration | yes (the inference) | no (forwards HTTP to providers) |
| Auth | n/a | optional v1 path A (no header) |
| Estimated wall time | 3-5 weeks | 2-3 weeks |
| Acceptance | runs Phase 2 harness against itself | runs Phase 2 harness through coordinator → mock providers |

The coordinator build should be smoother because:
- No Apple toolchain quirks (Go is its own self-contained world)
- No GPU/Metal dependencies
- Wire protocol is already implemented by Phase 3 binary, so spec-implementation drift can be cross-validated

## Operator checkpoints

Same pattern as Phase 3 binary build:
- T+15 min: did Codex read required files? Any spec questions surfaced immediately?
- T+1h: Step 1 done? `go build` succeeds?
- Daily: scan implementation-notes.html Open Questions and resolve.

## Final shipping flow

Once Phase 4 coordinator passes all acceptance tests:
1. Deploy to VPS at 165.22.182.207 (cross-compile via `GOOS=linux GOARCH=amd64`)
2. Point Phase 2 harness's tunnel_url at the coordinator's public endpoint
3. Watch Phase 2 cron for ~24h — coordinator should route harness traffic to the M4 partner's phase3-binary cleanly
4. **Phase 3 binary + Phase 4 coordinator end-to-end** — Mac Provider's core stack is operational
5. SPEC-003 (Antseed seller integration) becomes the next critical-path spec → first revenue

That's the path. This prompt is ready for tomorrow afternoon or Friday once the parity work lands.
