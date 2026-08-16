# Build prompt — SPEC-003 (Open onboarding + WS-tunneled inference)

This document contains the operator-paste prompt to produce
`specs/SPEC-003-open-onboarding.md`. The receiving agent **writes the spec
document**; it does not build the system itself.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Claude Code session rooted at `/Users/augstar/macprovider-poc`.
Expected duration: ~3-4 hours of focused writing.

---

```
=== BEGIN PROMPT ===

You are writing SPEC-003 for the Mac Provider project. Your output is a
single markdown file at /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md
plus a paired empty scaffold at
/Users/augstar/macprovider-poc/phase5-onboarding/implementation-notes.html
(create the directory if needed).

You are NOT building anything. You are writing the spec a future session
will implement.

## Mission of SPEC-003

The Phase 4 coordinator is live in production at https://coordinator.malibu.tech
and the network works (two providers, two models, real multi-model
routing, ~2.5s end-to-end inference). But the supply side is
operator-locked: a stranger reading a GitHub README cannot become a
provider without three operator interventions (subdomain on malibu.tech,
Cloudflare tunnel token, manual config.providers[] enumeration in
coordinator.yaml). That works for 2 vetted partners; it breaks at 5;
it's impossible at 50.

SPEC-003 is the architectural pivot to make Mac Provider a downloadable
product. After SPEC-003 ships, the user experience for joining the
network is:

  curl -fsSL https://get.malibu.tech/install.sh | bash

— one line, zero operator action, provider in the pool within 2 minutes
(excluding the multi-GB model download on first run).

Four tightly-coupled changes make this work, and they MUST ship as one
spec because each fails without the others:

  Part A: WS-tunneled inference. Inference traffic flows through the
          existing provider WebSocket instead of HTTPS-to-public-URL.
          Provider needs zero inbound network — only outbound WSS to
          the coordinator. Works behind any NAT, firewall, hotspot.

  Part B: Dynamic admission. Relax SPEC-002 v1.0.4 Finding F-2 (the
          "every provider_id must be in config.providers[]" invariant)
          with a three-tier model: pinned (M4/M1 today), provisional
          (strangers, accepted automatically, lower routing weight),
          rejected (banned).

  Part C: Distribution + lifecycle. GitHub Releases, curl-pipe-bash
          install script at get.malibu.tech, `macprovider-cli update`
          subcommand, launchd plist for reboot survival, optional
          coordinator-advertised version nudge.

  Part D: Onboarding UX. The README flow, install.sh prompts,
          first-run behavior, status check, uninstall.

Plus E (acceptance criteria), F (deps + clean-room hygiene), G (build
prompts for the implementation phases).

## Critical constraints

**1. d-inference clean-room.** The d-inference codebase
(https://github.com/layr-labs/d-inference) is custom-licensed
(NOASSERTION SPDX) and prohibits use to compete. Do NOT inspect their
source code at any point while writing SPEC-003. Reading their public
LICENSE file is allowed (you'll need it for § F clean-room hygiene
paragraph). Reading their README/docs is allowed but discouraged —
prefer general industry-standard patterns. If you find yourself reaching
for d-inference for inspiration, stop and reason from first principles
instead. SPEC-001 § 8.2 and SPEC-002 § 8.2 already document this
constraint; reaffirm it in SPEC-003 § F.

The WS-tunneled inference architecture is industry-standard for
outbound-only worker pools (Tor relays, Tailscale, GitHub Actions
self-hosted runners, Cursor agents, AWS IoT Core). Convergent design
from the "worker has no inbound network" constraint, not derivative.
Document this rationale in § A.1.

**2. Buyer-side surface stable.** The buyer-facing HTTP API
(POST /v1/chat/completions, GET /v1/models, GET /healthz) MUST NOT
change in observable behavior. All architectural changes are internal
to the coordinator <-> provider path. A buyer that worked yesterday
must work tomorrow.

**3. Backward compatibility for pinned providers.** M4 (running
phase3-binary v1.1.4) and M1 (running v1.1.3) are in the production
pool today with operator-managed Cloudflare tunnels. They must continue
to work after SPEC-003 ships without any required upgrade or
reconfiguration. Their `hello` message includes an `endpoint_url`
(by virtue of being in `config.providers[]`); the coordinator MUST
detect this and use the legacy HTTP-forwarding path for them.

Net: SPEC-003 introduces WS-tunneled mode as the DEFAULT for new
providers, but HTTP-forwarding mode persists indefinitely in v1 for
pinned providers. Two paths coexist. No forced migration.

**4. Match the rigor pattern.** SPEC-001 (1.1.4) and SPEC-002 (1.0.4)
went through 3-4 audit rounds each before being build-ready. SPEC-003
will go through the same audit cycle (Claude + Codex cross-model audit).
Write to that quality bar: every normative statement should have a
clear rationale, every example should be syntactically valid, every
failure mode should have a defined error code. Anywhere you write
"the implementation should figure this out," replace with a normative
choice or an explicit open question.

**5. No hand-waving on cancellation, backpressure, or multiplexing.**
These three are the highest-risk parts of Part A (WS-tunneled
inference). Spec them with the same precision as SPEC-001 § 6.5
(close codes, state transitions, exact wire format). If you don't know
what the right answer is, write an explicit open question (OQ) — do
not paper over it.

## Read these files first (in order)

1. /Users/augstar/macprovider-poc/CONTINUE_RUNBOOK.md
   — overall project state, what's in/out of scope.

2. /Users/augstar/macprovider-poc/HANDOFF.md
   — Tier 1 / Tier 2 architecture, project history.

3. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md (v1.1.4)
   — phase3-binary spec, especially § 6.5 (the WebSocket envelope you
   are extending). Note v1.1.3 + v1.1.4 change logs at the top — they
   capture two drain-related bugs caught during Phase 4 deploy. Don't
   re-introduce them.

4. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md (v1.0.4)
   — coordinator spec, especially § 3 "Request forwarding model" (which
   you are amending), § 5 "Routing algorithm" (which you are extending
   with the admission-tier weight), § 7.1 (the static config-map you
   are relaxing), § 7.4 (operator endpoints — you'll add three more),
   and § 10 D6 (the F-1/F-2/F-3 findings, which you'll reference).

5. /Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md
   — especially Decision log entries 12-18 (cover Phase 4 deploy +
   the drain bugs + Day 2 wrap). Entry 18 is the rationale chain for
   why SPEC-003 exists.

6. /Users/augstar/macprovider-poc/phase4-coordinator/internal/ws/messages.go
   — the existing wire-format Go structs for hello/heartbeat/etc.
   The new message types you specify must be consistent with this.

7. /Users/augstar/macprovider-poc/phase4-coordinator/internal/buyer/server.go
   — the current HTTP-forwarding path. The WS-tunneled path replaces
   the call to `http.Do(req)` against `provider.EndpointURL` with a
   WS round-trip. Understand the current shape before redesigning it.

8. /Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift
   — the existing provider-side WS handler. The new message types will
   be handled here. Note v1.1.3's drainFromCoordinator() and v1.1.4's
   state-reset — the WS-tunneled inference handler must compose cleanly
   with these existing flows.

9. /Users/augstar/macprovider-poc/specs/BUILD_SPEC_002_PROMPT.md
   — example of the rigor + structure expected for SPEC-003. Don't
   copy verbatim, but match depth.

You may also browse the rest of phase3-binary/ and phase4-coordinator/
for context. Do NOT browse anything under /Users/augstar/macprovider-poc/d-inference*
if such a directory exists (it shouldn't — clean-room separation).

## Spec structure (write to this outline)

Match the section structure of SPEC-002 (mission, scope, architecture,
FRs, interface contracts, deps, acceptance criteria, build steps).
SPEC-003 will be longer than SPEC-002 because four parts share the
document; expect 2500-4000 lines.

### § 0. Operator-paste invocation block
Same pattern as SPEC-001/002.

### § 1. Mission
~1 page. The "why this spec exists" narrative — supply scale is the
bottleneck, three hard blocks today, downloadable product is the goal.

### § 2. Scope
In-scope (Parts A-D), out-of-scope (Antseed seller integration deferred
to SPEC-007; smart router stays at SPEC-004; rewards at SPEC-005).
Also out of scope: Tier 2 attestation, buyer-side privacy, anything
touching the buyer HTTP API surface.

### § 3. Architecture overview
ASCII diagram showing the two coexisting paths:
  - Pinned providers (M4/M1): coord -> HTTPS GET -> provider tunnel
  - Provisional providers (strangers): coord -> WS frame -> provider
Plus a narrative on how the dynamic admission tier interacts with
routing weight.

### § 4. Functional requirements
Organized by Part:
  FR-A1 through FR-A12: WS-tunneled inference
  FR-B1 through FR-B7: dynamic admission tiers
  FR-C1 through FR-C8: distribution + lifecycle
  FR-D1 through FR-D5: onboarding UX

### § 5. Wire protocol (Part A details)
The high-density section. Includes:
  - Exact JSON schemas for inference_request, inference_response_chunk,
    inference_response_end, cancel_request
  - Per-field semantics (required/optional, ordering guarantees)
  - request_id correlation and lifecycle
  - Multiplexing: how N concurrent requests share one WS, framing,
    backpressure when one slow request would block others
  - Streaming translation: SSE chunk -> WS frame mapping, exact-once
    delivery guarantees, retransmission policy on WS disconnect
  - Cancellation: buyer disconnect -> coordinator detects -> sends
    cancel_request -> provider aborts inference -> sends final
    inference_response_end with status=aborted
  - Error semantics: model-not-loaded, out-of-context, internal-error,
    provider-timeout each map to specific status codes in
    inference_response_end (not new nak codes — preserve nak for
    protocol-level errors per SPEC-001 § 6.5)
  - Backpressure: bounded WS write buffer per provider; what happens
    when provider can't drain frames fast enough; coordinator-side
    response timeouts
  - Backward-compat detection: presence of endpoint_url in hello ->
    HTTP-forwarding mode; absence -> WS-tunneled mode

### § 6. Admission tiers (Part B details)
  - Three tiers: pinned, provisional, rejected
  - State transitions and triggers
  - Rate limits (provisional admission rate, total provisional pool
    size, per-provisional-provider request quota)
  - New WS close codes: 4007 provisional_pool_full,
    4008 provisional_rate_limited, 4009 banned
  - Routing weight integration: SPEC-002 § 5 routing algorithm gains
    a tier-multiplier (suggested: pinned 1.0, provisional 0.3)
  - SPEC-002 v1.0.4 F-2 amendment: "F-2 applies to pinned providers
    only; provisional providers are accepted dynamically subject to
    rate limits"
  - Persistence: provisional admissions written to coordinator.db
    (new table), survives coordinator restart, configurable retention

### § 7. Interface contracts
  - § 7.1 New WS message types (full JSON schemas)
  - § 7.2 New operator endpoints:
      GET /admin/provisional         list all provisional providers
      POST /admin/promote/{provider_id}   promote to pinned
      POST /admin/reject/{provider_id}    ban (close + add to rejected list)
      All bearer-auth gated (same as existing /admin/*).
  - § 7.3 install.sh contract: arguments, env vars, exit codes,
    side effects (files written, launchd plist installed)
  - § 7.4 macprovider-cli new subcommands:
      update         self-update
      status         local + remote state
      uninstall      remove everything
  - § 7.5 launchd plist schema (org reverse-domain, RunAtLoad,
    KeepAlive, logging)
  - § 7.6 GitHub Releases shape: tag format, asset naming, checksums,
    release notes format

### § 8. Dependencies + clean-room hygiene
Same shape as SPEC-001/002 § 8. Specifically:
  - No new Go deps in the coordinator if possible (existing gobwas/ws
    should handle the new message types)
  - Reaffirm d-inference clean-room separation
  - GitHub API (for self-update) — standard library + existing deps
  - cloudflared NOT a hard dep anymore (provisional providers don't
    need it); kept as an option for pinned providers

### § 9. Phase 4 findings + Day 2 lessons that SPEC-003 encodes
Like SPEC-002 § 10. Reference Decision log entries 13-18. Specifically:
  - D7 (was F-2): static config-map relaxed to provisional tier
  - D8 (drain conflation): coordinator-initiated drain must NOT
    terminate the provider; this is now load-bearing on WS-tunneled
    mode (where the provider has no fallback direct path)
  - D9 (case-sensitivity regression): model_id comparison normative
    semantics in coordinator routing (case-insensitive lookup, with
    canonical form preserved in storage)
  - D10 (coord overhead measurement): ~25-30% throughput drop through
    coord vs direct in early data; WS-tunneled path will have
    additional overhead from multiplexing — document expected
    range and validation method

### § 10. Acceptance criteria
AC-1 through AC-12 covering both WS-tunneled path and pinned-provider
path:
  AC-1  WS-tunneled: mockprovider connects with endpoint_url=null,
        serves inference_request, returns response.
  AC-2  Streaming SSE through WS multiplexing.
  AC-3  Cancellation propagation (buyer disconnect -> provider abort
        within 1s).
  AC-4  Concurrent multiplexing (max_concurrency=N served simultaneously
        on one WS).
  AC-5  Backward compat: pinned provider (with endpoint_url) routed
        via HTTP-forwarding path.
  AC-6  Provisional admission: unknown provider_id accepted, shown
        in /poolz with tier=provisional.
  AC-7  Provisional rate limit: 11th admission/hour returns close 4008.
  AC-8  install.sh from clean Mac: binary running + registered <2 min
        (excluding model download).
  AC-9  macprovider-cli update: atomic version swap with running
        service.
  AC-10 launchd plist: survives mac reboot, binary reconnects to coord.
  AC-11 admin/promote: provisional -> pinned, routing weight upgrades.
  AC-12 admin/reject: provider added to rejected list, future hellos
        get close 4009.

Each AC has: setup, action, expected, how-to-verify (test script path).

### § 11. Open questions (OQs)
Be honest about unknowns. Anticipated:
  - OQ-1: WS frame size limit for large completions (32K-token responses)
  - OQ-2: per-provider WS write buffer high-water mark
  - OQ-3: how to surface tier=provisional to buyers (header?
    routing-only?)
  - OQ-4: should `required_binary_version` enforcement check apply
    to provisional or only pinned providers?
  - OQ-5: code signing strategy (Apple Developer ID $99/yr vs.
    xattr workaround)

### § 12. Build steps (paste-ready Codex prompts)
One section per implementation phase:
  - 12.1 phase3-binary v1.2 (new WS message handlers, install.sh
    auto-bundle, launchd plist generation)
  - 12.2 coordinator v0.2 (WS-tunneled inference relay,
    multiplexing/cancellation/backpressure, dynamic admission,
    new admin endpoints)
  - 12.3 install.sh + get.malibu.tech hosting (Cloudflare Pages
    or similar)
  - 12.4 macprovider-cli update + status + uninstall subcommands
  - 12.5 GitHub Releases automation (Action or runbook)

Each build step matches the pattern of SPEC-001 § 12 / SPEC-002 § 13:
operator-paste prompt for Codex with full context + acceptance
criteria from § 10.

## Style guidance

  - Match the voice of SPEC-001/002: direct, normative, no
    marketing language. "MUST", "SHALL", "MAY", "MUST NOT" used
    per RFC 2119.

  - Every behavior change has a rationale tied to a Decision log
    entry, a Phase 4 finding, or first principles.

  - Examples should be syntactically valid JSON (or shell, or YAML).
    Lint your own examples by re-reading them before commit.

  - Cross-spec references are explicit (e.g., "amending SPEC-002
    v1.0.4 § 7.1") — never "see the coordinator spec".

  - When you specify a numeric threshold (timeout, buffer size, rate
    limit), include the rationale. "max provisional pool size = 100"
    isn't enough; "= 100 because (a) Pearl VPS has 3.8 GB RAM, (b)
    per-connection state is ~40KB, (c) 100 leaves 96 MB headroom for
    bursts + other coord state" is.

  - Open questions are first-class citizens. Don't pretend you've
    decided when you haven't.

## Process

1. Read everything in the "Read these files first" list. Take notes.

2. Outline the spec in a scratchpad before writing prose. Confirm
   the four parts compose cleanly — no contradictions between
   admission tiering and WS multiplexing, etc.

3. Write the spec. Expect 2500-4000 lines. Take breaks; this is a
   focused task.

4. Self-review for: undefined terms, undefined error codes,
   "the implementation should" hand-waving, contradictions with
   SPEC-001 v1.1.4 or SPEC-002 v1.0.4.

5. Create the implementation-notes.html scaffold (empty template
   matching phase3-binary/implementation-notes.html and
   phase4-coordinator/implementation-notes.html in shape).

6. Final deliverable list:
   - specs/SPEC-003-open-onboarding.md (the spec)
   - phase5-onboarding/implementation-notes.html (empty scaffold)
   - A 200-word handback summary to the operator describing what's
     in the spec, what's deliberately deferred, and which 3-5 OQs
     are most consequential. Print this summary to stdout at the
     end of your run.

7. Do NOT commit. Operator will review, audit, and commit.

## What NOT to do

  - Do NOT build any code. Spec only.
  - Do NOT modify SPEC-001 or SPEC-002 in this pass. The amendments
    are recorded in SPEC-003 § 6 (B-tier amendment) and § 9 (D7-D10).
    Cross-spec consistency pass happens in a separate audit round.
  - Do NOT inspect d-inference source.
  - Do NOT propose Antseed integration or revenue mechanisms (deferred).
  - Do NOT propose forcing pinned providers to migrate.
  - Do NOT propose changes to the buyer-facing HTTP API.
  - Do NOT propose Tier 2 attestation features.
  - Do NOT skip OQs; surfacing real uncertainty is the spec's job.

When done, print the 200-word summary and stop. Operator takes it
from there.

=== END PROMPT ===
```

---

## After running this prompt

The operator's review checklist:

1. Skim spec for completeness vs. the outline above.
2. Verify the four parts compose cleanly (no contradictions between
   admission tier semantics and WS multiplexing).
3. Check § 9 D7-D10 against Decision log entries 13-18.
4. Check § F clean-room paragraph mirrors SPEC-001/002 wording.
5. Confirm OQs are honest (no hand-waving where decisions matter).
6. Confirm acceptance criteria are independently testable.

Then the audit cycle:
- AUDIT_SPEC_003_PROMPT.md — Codex audits Claude's spec
- FIX_SPEC_003_V0_1_PROMPT.md — Claude resolves Codex findings
- Repeat until clean (target 2-3 rounds)
- Then BUILD_SPEC_003_PROMPT.md hands off to implementation

Expected total time spec-to-build-ready: ~1 day of focused work.
