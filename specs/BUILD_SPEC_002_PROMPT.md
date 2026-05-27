# Build prompt — SPEC-002 (Phase 4 coordinator)

This document contains the operator-paste prompt to produce
`specs/SPEC-002-coordinator.md`. The receiving agent **writes the spec
document**; it does not build the coordinator itself.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Claude Code or Codex CLI session rooted at
`/Users/augstar/macprovider-poc`. Expected duration: ~2 hours.

---

```
=== BEGIN PROMPT ===

You are writing SPEC-002 for the Mac Provider project. Your output is a
single markdown file at /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md
plus a paired empty scaffold at /Users/augstar/macprovider-poc/phase4-coordinator/implementation-notes.html.

You are NOT building the coordinator. You are writing the spec a future
session will implement.

## Mission of SPEC-002

A VPS-hosted coordinator service that:
1. Accepts inbound WebSocket connections from Mac Provider binaries
   (Phase 3 binaries, specified by SPEC-001 v1.1.1)
2. Maintains a pool of available providers with their advertised capacity
3. Exposes an OpenAI-compatible HTTP API to buyers
4. Routes buyer requests to the best-matching provider in the pool
5. Handles provider failure modes (sleep, network drops, OOM, etc.)
6. Issues and validates provider auth tokens (deferred from SPEC-001)
7. Logs requests for billing/attribution

**Tier 1 launch posture** — single-tenant pool, operator vouches for
providers, no buyer-side privacy claim. Plain HTTP-over-WebSocket to
providers, plain HTTPS-over-OpenAI-API to buyers.

**Tier 2 roadmap-ready architecture** — clean hook points for a future
upgrade that adds buyer-side encryption, attestation chain (buyer →
coordinator → provider), TEE-bound routing. Same design discipline as
SPEC-001: name the hook points explicitly; don't speculate on
implementation.

## Required reading (in order — read fully before writing anything)

1. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   — the binary spec; SPEC-002 MUST be wire-compatible with § 6.5 verbatim.
   Read § 6.5 (coordinator WebSocket protocol) carefully. The protocol is
   LOCKED from the coordinator's side too: every message the binary sends,
   the coordinator must accept; every message SPEC-001 says the
   coordinator sends, SPEC-002 must define how the coordinator decides
   when to send it.

2. /Users/augstar/macprovider-poc/HANDOFF.md
   — project context, especially the "Coordinator on VPS" architecture
   intent and the existing antseed VPS at 165.22.182.207.

3. /Users/augstar/macprovider-poc/beta/PHASE2_UPGRADED_PLAN.md
   — what Phase 2 was meant to find; especially routing-mode evolution
   table (mirror → specialization → stress).

4. /Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md
   — read the decision log. Several entries are coordinator-side concerns
   that SPEC-001 explicitly deferred to SPEC-002:
     - D1 (502 vs 530 routing) — coordinator backoff strategy + tunnel
       polling
     - D4 (capacity-vs-quality routing) — buyer-facing model choice or
       auto-routing
     - Post-wake warm-up dispatch (binary supports it; coordinator decides
       when to send it)

5. /Users/augstar/macprovider-poc/beta/harness.py
   — the buyer-side behavior the coordinator must serve. The harness
   currently talks directly to providers; in Phase 4, the harness will
   point at the coordinator's HTTP endpoint and the coordinator routes.

6. /Users/augstar/macprovider-poc/results/REPORT.md
   — skim Step 6 (VPS SSH tunnel work) and Step 7 (tunnel latency) for
   existing VPS context.

## What SPEC-002 must contain (sections, in order)

### 0. Operator-paste invocation block (verbatim, at the top)

```
Implement SPEC-002. As you work, maintain a running
phase4-coordinator/implementation-notes.html that captures anything
I should know about how the implementation diverges from or interprets
the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise
```

### 1. Mission (1 paragraph)
   What this coordinator is, who it serves, why it exists, how it
   relates to the Phase 3 binary.

### 2. Scope
   • **In Tier 1 launch scope** — bullet list, exhaustive
   • **In Tier 2 roadmap scope (designed-in but not implemented)** — list
   • **Out of scope** — list:
     - Smart router with sticky caching → SPEC-004
     - Public direct buyer API with auth/billing → SPEC-006
     - Contributor reward distribution → SPEC-005
     - Antseed seller integration code → SPEC-003 (but the wire shape
       must be compatible with what SPEC-003 will need)
     - Buyer-side privacy stack (Tier 2)

### 3. Architecture overview
   ASCII / markdown diagram. Must show:
   • Buyer HTTP entry → request validation → routing → provider WebSocket
   • Provider WebSocket server → pool registry → capacity tracker
   • Storage layer (SQLite for v1)
   • Logging / metrics
   • Auth: provider token issuance + validation
   • **Tier 2 hook points** explicitly named (e.g. where an Attestation
     Verifier would sit, where buyer-side encrypted payloads would land)

### 4. Functional requirements (FR-1, FR-2, ..., numbered, testable)
   At minimum (expand each):

   Provider-side (matching SPEC-001 § 6.5):
   FR-P1   Accept WebSocket from authorized provider on /provider endpoint
   FR-P2   Validate `hello` message; respond `hello_ack` per SPEC-001
   FR-P3   Maintain provider pool entry with last-heard timestamp
   FR-P4   Process heartbeat messages, update capacity state
   FR-P5   Process `state_update`: react to ready/busy/degraded/draining/
           unavailable transitions
   FR-P6   Process `drain_status`: stop routing new traffic to draining
           providers
   FR-P7   Send `preflight` queries before routing context-heavy requests
   FR-P8   Send `warm_up` to provider after detected wake event (gap in
           heartbeats >120s then resumption)
   FR-P9   Send `drain` command on shutdown / blacklisting
   FR-P10  Detect provider disconnect; remove from active pool with
           configurable grace period
   FR-P11  Distinguish provider failure modes:
           - WebSocket disconnect → mark unavailable (remove from pool)
           - 502 on a routed buyer request (tunnel up, mlx down) →
             mark degraded (short backoff ~30s)
           - 530 → mark unavailable
   FR-P12  Auth: on hello, validate provider's bearer token (issued
           offline via operator CLI for v1)
   FR-P13  Reject `tier: 2` providers in v1 with explicit
           "tier_unsupported" nak

   Buyer-side:
   FR-B1   /v1/models endpoint returns aggregated model list across pool
   FR-B2   /v1/chat/completions (non-streaming) accepts standard OpenAI
           request (per SPEC-001 § 6.2 schema)
   FR-B3   /v1/chat/completions with stream=true returns SSE
   FR-B4   Route request to best provider (selection algorithm in § 5)
   FR-B5   Preflight check against chosen provider before forwarding
           context-heavy requests
   FR-B6   Forward SSE stream from provider to buyer, transparently
   FR-B7   If chosen provider fails mid-request, return clean error
           (no silent retry to a different provider in v1)
   FR-B8   Return HTTP 503 with descriptive body if no provider available
   FR-B9   Log every buyer request: timestamp, model, tokens, provider,
           latency, status

   Routing logic (the smarts):
   FR-R1   Default selection: provider whose `model_id` matches request's
           `model` field exactly; if multiple, prefer lowest `slots_free`
           that's still positive (utilization-favoring), unless capacity
           preference is requested
   FR-R2   Capacity preference: buyer can hint via header
           `X-MacProvider-Pref: fast | accurate` (fast = max
           throughput_tps_estimate, accurate = max model_params_b)
   FR-R3   Buyer can pin to a specific provider via header
           `X-MacProvider-Provider: <provider_id>` (for testing/A/B)
   FR-R4   Pool must include only providers with `state=ready` and
           `slots_free>0`
   FR-R5   Context length check: request's prompt_tokens (estimated by
           coordinator OR from explicit preflight) must fit within
           chosen provider's `max_context_tokens`
   FR-R6   Auth scope check: provider's tier must match request requirement
           (Tier 1 buyer → Tier 1 provider; Tier 2 reserved for future)

   Operations:
   FR-O1   /healthz endpoint for VPS-side monitoring
   FR-O2   /poolz endpoint (operator-only, auth-gated) for dashboarding
   FR-O3   SIGTERM gracefully drains in-flight buyer requests then exits
   FR-O4   Provider auth tokens issued via `coordinator-cli issue-token
           --provider <id>` command; revocable via `revoke-token`
   FR-O5   Persist provider auth, request log, and pool state across
           coordinator restarts (SQLite)

   ... continue to ~25-30 FRs total

### 5. Routing algorithm (dedicated section)
   Detailed pseudocode for FR-R1 through FR-R6 — selection order, tie-
   breaking, fallback when no providers match. This is where the actual
   intelligence lives; deserves more than a paragraph.

### 6. Non-functional requirements
   • Performance: <50ms coordinator overhead on routed requests (not
     including provider latency)
   • Availability: single-instance v1; HA in SPEC-002.next
   • Storage: SQLite, WAL mode, daily backup to local file
   • Logging: JSON Lines to stdout (captured by systemd journal)
   • Security: TLS termination via Caddy or nginx in front (out of
     scope of binary; deployment concern)
   • Concurrency: handle ≥100 concurrent buyer requests with ≥4 providers
   • Memory: <200MB resident at idle, <1GB at peak

### 7. Interface contracts

#### 7.1 Provider WebSocket (server side of SPEC-001 § 6.5)
   Replicate the message schemas from SPEC-001 § 6.5 verbatim. Add for
   the COORDINATOR side only:
   - When coordinator sends `preflight`, what triggers it
   - When coordinator sends `drain`, what triggers it
   - When coordinator sends `warm_up`, what triggers it
   - How coordinator interprets each provider-to-coordinator message
   - Connection lifecycle (hello → ack → heartbeats → drain → close)

#### 7.2 Buyer HTTP API
   Full schemas — must be wire-compatible with SPEC-001 § 6.2 because
   the harness will be the first buyer and it generates SPEC-001-shaped
   requests:
   - GET /v1/models
   - POST /v1/chat/completions (stream=true and stream=false)
   - All error response shapes
   - Custom headers: X-MacProvider-Pref, X-MacProvider-Provider
   - Rate limiting headers (X-RateLimit-* — even if v1 doesn't enforce,
     reserve the namespace)

#### 7.3 Auth
   - Token issuance flow (offline, CLI)
   - Token validation (bearer in WebSocket subprotocol or auth header)
   - Token rotation / revocation
   - Token storage in SQLite (hashed; no plaintext)

#### 7.4 Operator endpoints
   - GET /poolz — current pool state
   - GET /healthz — coordinator self-health
   - POST /admin/blacklist — operator-triggered provider removal

### 8. Dependencies & references

#### 8.1 Direct dependencies
   - Language: **Go 1.22+** (chosen for I/O-bound WebSocket relay;
     simpler concurrency than Rust for this workload; smaller deployment
     footprint than Node)
   - Key libraries (pin in spec):
     * github.com/gobwas/ws (WebSocket)
     * github.com/julienschmidt/httprouter or chi (HTTP routing)
     * modernc.org/sqlite (pure-Go SQLite, no cgo)
     * github.com/rs/zerolog (logging)
   - Deployment: VPS at 165.22.182.207 (existing AntFeed VPS — reused;
     coordinator co-located on a different port)

#### 8.2 Reference hygiene — strict clean-room for d-inference
   COPY THIS SECTION VERBATIM FROM SPEC-001 § 7.2. Same policy applies:
   d-inference is custom-licensed, do not consult source files. Public
   papers, blog posts, and Mac Provider's own materials only.

   Patent analysis: same as SPEC-001 — Tier 1 doesn't implement
   Darkbloom's privacy/attestation model; their patents likely don't
   apply. Tier 2 work will need fresh analysis.

#### 8.3 Public spec sources
   - SPEC-001 v1.1.1 (this repo) — protocol contract
   - OpenAI API reference
   - WebSocket protocol RFC 6455
   - HuggingFace model card schema

#### 8.4 Internal sources
   - /Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md
   - /Users/augstar/macprovider-poc/beta/harness.py (first buyer)

### 9. SPEC-001 protocol compatibility (dedicated subsection)
   A coverage matrix listing every message in SPEC-001 § 6.5 and what
   SPEC-002 says about the coordinator's behavior for that message:

   | SPEC-001 § 6.5 message | Direction | SPEC-002 coverage |
   |---|---|---|
   | hello | P→C | FR-P1, FR-P2, FR-P12 |
   | hello_ack | C→P | FR-P2 |
   | heartbeat | P→C | FR-P4 |
   | state_update | P→C | FR-P5 |
   | drain_status | P→C | FR-P6 |
   | preflight | C→P | FR-P7 |
   | preflight_response | P→C | FR-P7, FR-R5 |
   | drain | C→P | FR-P9 |
   | warm_up | C→P | FR-P8 |
   | nak | both | error semantics in § 7.1 |

   Verify every row maps. Missing entries are a finding.

### 10. Phase 1 + Phase 2 findings that SPEC-002 must encode
   - D1 (502/530 distinction) — FR-P11 routing behavior
   - D2 (post-wake throughput dip) — FR-P8 warm_up dispatch
   - D4 (capacity-vs-quality routing) — FR-R2 buyer preference header
   - Timeline compression — process-only, no FR

### 11. Acceptance criteria
   • AC-1: Phase 3 binary (mock) connects via WebSocket, exchanges
     hello, sends 5 heartbeats, receives drain on shutdown.
     Run by: `phase4-coordinator/scripts/test-provider-lifecycle.sh`
   • AC-2: Buyer harness (beta/harness.py with tunnel_url pointing at
     coordinator) runs full cooperative batch against pool of 2 mock
     providers, gets 100% HTTP 200.
     Run by: `cd beta && python harness.py --config <coord-config> --batch cooperative --verbose`
   • AC-3: Adversarial workloads against pool of 2 mock providers do
     not crash coordinator; concurrent_burst_8way routed across both.
     Run by: `cd beta && python harness.py --config <coord-config> --batch adversarial --verbose`
   • AC-4: Provider disconnect mid-buyer-request returns clean 503 to
     buyer (no silent retry).
   • AC-5: Issued token works; revoked token rejected.
     Run by: `phase4-coordinator/scripts/test-auth-flow.sh`
   • AC-6: SIGTERM with 3 in-flight requests drains gracefully ≤30s.
   • AC-7: 502 from provider → coordinator marks degraded, retries route
     for next request after 30s backoff.
   • AC-8: 530 from provider → coordinator removes from pool, sends
     warm_up after reconnection.
   • AC-9: Capacity preference header routes correctly across 2
     providers with different model sizes.
   • AC-10: /healthz returns 200 with pool size; /poolz returns provider
     list (auth-gated).

### 12. Open questions for operator
   Target 4-6. Examples:
   • TLS in front of coordinator — Caddy auto-cert vs nginx + manual?
     (My default: Caddy for v1 — fewer ops steps.)
   • Buyer auth — none in v1 (Antseed-only), or pre-issue API keys?
     (My default: none in v1; add when SPEC-006 lands.)
   • Provider auth token format — opaque random vs JWT?
     (My default: opaque 32-byte random; JWT adds complexity without
     benefit for v1 single-issuer.)
   • SQLite WAL — daily backup or hot replication?
     (My default: daily file copy + rsync to operator's M1.)
   • Multi-region — single VPS in v1, add later? (My default: single VPS;
     latency to Antseed and providers dominates anyway.)

### 13. Implementation hand-off
   Step sequence for the build session:
   1. Init Go module at phase4-coordinator/
   2. Implement WebSocket /provider endpoint + hello/hello_ack
   3. Implement pool registry + heartbeat handling
   4. Implement state machine for provider states
   5. Implement /v1/models aggregation
   6. Implement /v1/chat/completions non-streaming routing
   7. Implement SSE streaming pass-through
   8. Implement preflight + capacity routing
   9. Implement auth (token issuance CLI + validation)
   10. Implement operator endpoints (/healthz, /poolz)
   11. Acceptance test against mock providers + real harness

### Appendix A — References used during spec writing
   List every file consulted. Required transparency.

## Reference hygiene rules — operate by these throughout

Same as SPEC-001:
1. MUST NOT consult d-inference source files (custom restrictive license)
2. MAY consult public papers, blog posts, third-party reviews not
   reproducing source
3. MUST NOT copy code into the spec (requirements only)
4. SPEC-002 inherits the same "informed by, not copied" discipline

## Hard rules

1. The wire protocol from SPEC-001 § 6.5 is LOCKED. If you find a real
   protocol issue while writing SPEC-002, surface it as an Open Question
   for the operator to resolve as a SPEC-001 amendment. Do NOT silently
   alter the protocol in SPEC-002.
2. SPEC-002 owns coordinator internals; SPEC-001 owns binary internals;
   the wire between them is jointly governed by SPEC-001 § 6.5. Respect
   this boundary.
3. Length: 1000-1800 lines. Coordinator is more complex than the binary
   because it has both server-side WebSocket and HTTP routing layers.
4. Pick defaults where you'd otherwise leave open questions. Open
   questions count: 4-6 only.
5. No code samples beyond JSON schemas, ASCII diagrams, and pseudocode
   for the routing algorithm.

## Anti-rules

- Don't reopen SPEC-001 decisions (Tier 1/Tier 2 split, strict clean-room,
  protocol message names).
- Don't speculate about Tier 2 attestation implementation beyond hook
  point locations.
- Don't write deployment scripts. That's for the build session.
- Don't design SPEC-003 (Antseed integration) or SPEC-006 (public API)
  inside SPEC-002. Mention them as out-of-scope, that's it.

## Output files

1. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md
2. /Users/augstar/macprovider-poc/phase4-coordinator/implementation-notes.html
   (empty scaffold, same shape as phase3-binary/implementation-notes.html)
3. Update /Users/augstar/macprovider-poc/specs/README.md to add SPEC-002 row

## When you finish

1. Re-read SPEC-002 end to end. Every § 6.5 protocol message must map
   to one or more FRs.
2. Run a self-check: would a competent Go developer (or fresh Claude/Codex
   session) need more than 3 clarifications to start coding?
3. Print to stdout: <200-word summary, key decisions, count of open
   questions.

Begin by reading the required files in order.

=== END PROMPT ===
```

---

## How to use

```bash
cd /Users/augstar/macprovider-poc
claude < specs/BUILD_SPEC_002_PROMPT.md
```

Expected wall time: ~2 hours.

## Then run the audit

After SPEC-002 lands, run `AUDIT_SPEC_002_PROMPT.md` (drafted alongside this). Same Codex-CLI pattern as SPEC-001's audit.
