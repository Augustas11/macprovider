# Build prompt — Coordinator v0.2 stream (SPEC-002 v1.1.2 implementation)

Operator-paste prompt to implement the coordinator-side changes
specified in SPEC-002 v1.1.2. This stream **only touches Go code in
phase4-coordinator/** and is fully parallelizable with BUILD_SWIFT
and BUILD_DISTRIBUTION streams.

What this stream produces:
  - WS-tunneled inference relay on the coordinator side (FR-P14,
    FR-P14.1, FR-P18, FR-P18.1)
  - Dynamic admission tier (pinned / provisional / rejected) per
    FR-P15, FR-P16, FR-P17
  - Tier-weighted routing + case-insensitive model_id matching
  - Three new admin endpoints (/admin/provisional, /admin/promote,
    /admin/reject)
  - New WS close codes 4007, 4008, 4009
  - SPEC-002 v1.1.2 acceptance tests (AC-11..AC-15)

Expected duration: ~6-8 hours. Run in **Codex CLI** rooted at
`/Users/augstar/macprovider-poc/`.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`.

---

```
=== BEGIN PROMPT ===

You are implementing the coordinator-side changes in SPEC-002 v1.1.2.
Your scope is Go code in /Users/augstar/macprovider-poc/phase4-coordinator/.
You do NOT touch Swift code (BUILD_SWIFT owns it) or shell/YAML
(BUILD_DISTRIBUTION owns it).

The current production coordinator v1.0.4 is LIVE at
coordinator.malibu.tech serving M4 and M1 partners. Your changes
are non-breaking — the legacy HTTP-forwarding path stays — but you
will deploy v1.1.2 only after BUILD_SWIFT lands so v1.2 phase3-binary
exists to exercise the WS-tunneled path.

## Project context

Mac Provider routes buyer inference requests across a pool of
volunteer Apple Silicon Macs. As of 2026-05-28:

  - `coordinator.malibu.tech` (Pearl VPS, 159.223.165.194) live
    with pool N=2 (M4 Qwen 7B, M1 Llama 3.2 3B)
  - Current coordinator v1.0.4 uses HTTP-forwarding path only —
    coordinator GETs to provider.endpoint_url
  - Every provider must be enumerated in `config.providers[]` (SPEC-002
    v1.0.4 F-2) — operator-locked supply

SPEC-002 v1.1.2 introduces:
  - **WS-tunneled relay**: inference flows through the existing
    provider WebSocket; provider needs zero inbound network
  - **Dynamic admission**: provisional tier accepts unknown
    provider_ids automatically (with rate limits + quota)
  - **Tier-weighted routing**: pinned providers preferred (1.0
    weight); provisional secondary (0.3 weight, configurable)
  - **Case-insensitive model matching** (D9 fix from production)
  - **Coordinator-advertised version nudge** in hello_ack

The HTTP-forwarding path stays for M4 and M1 (pinned via static
config). Two paths coexist forever in v1.

## d-inference clean-room

Do NOT inspect d-inference source. The patterns you implement
(outbound-worker WebSocket multiplexing, three-tier admission,
backpressure on framed streams) are standard for any worker-pool
system (Tor, Tailscale, GitHub Actions runners). Reaffirm clean-room
separation if you reach for their patterns.

## Required reading (in order, fully)

1. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md
   v1.1.2 — the spec under build. Read all of it. Focus areas:
     § 3 Request forwarding model (two-path mode resolution)
     § 5 Routing algorithm (model_id_equal + check_provisional_quota
         + quota_blocked_candidates + tier-weighted routing)
     § 7.1 Wire schemas + close codes 4007/4008/4009 + nak
         fallback paragraph
     § 7.5 New admin endpoints
     § 4 FR-P14, FR-P14.1, FR-P15, FR-P16, FR-P17, FR-P18,
         FR-P18.1, FR-P19, FR-P20, FR-P21
     § 11 AC-11..AC-15
     § 10 D7-D10 findings (informs design rationale)

2. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   v1.2.1 — the provider spec. Focus on:
     § 6.5 hello (added optional endpoint_url, tier in hello_ack)
     § 6.6 Inference message types (the new WS messages YOU send
       and receive: inference_request, inference_response_chunk,
       inference_response_end, cancel_request)
     § 6.6 Request ID lifecycle and error handling
     § 6.5 nak fallback semantics (special-case for § 6.6)

3. /Users/augstar/macprovider-poc/phase4-coordinator/ — current Go
   code. Read these files fully before editing:
     cmd/coordinator/main.go (process lifecycle)
     internal/ws/messages.go (wire-format Go structs to extend)
     internal/ws/server.go (provider WS handler — the largest change
       happens here for FR-P14 / FR-P18)
     internal/buyer/server.go (HTTP buyer handler — major rewrite to
       support both forwarding paths)
     internal/pool/provider.go (pool state — extend with tier field)
     internal/config/config.go (config schema — extend with
       admission tier limits + tier weight + provisional defaults)
     internal/auth/tokens.go (token validation; you'll add to it
       for new admin endpoints)
     tools/mockprovider/main.go (extend for § 6.6 — your tests
       depend on it)
     scripts/test-*.sh (existing acceptance test pattern; your AC
       scripts follow this style)

4. /Users/augstar/macprovider-poc/specs/SPEC-003-audit.md
   — read Decision log entries (round-1 + round-2) to understand
   the design rationale (especially Q1 = provisional providers
   never trust self-reported endpoint_url; D8 = drain does not
   terminate WS-tunneled in-flight requests; D9 = case-insensitive
   model match).

5. /Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md
   — entries 13-18 cover Phase 4 production lessons that drive
   SPEC-002 v1.1.2.

## Scope you OWN (only modify or create these)

Modify (existing Go files):
  /Users/augstar/macprovider-poc/phase4-coordinator/internal/ws/messages.go
    Add JSON structs for inference_request, inference_response_chunk,
    inference_response_end, cancel_request. Add close codes 4007,
    4008, 4009. Add endpoint_url (optional) to Hello struct. Add
    tier + recommended_binary_version (optional) to HelloAck struct.

  /Users/augstar/macprovider-poc/phase4-coordinator/internal/ws/server.go
    Major changes:
      - Handle § 6.6 inbound messages from providers (responses to
        coordinator-sent inference_request)
      - Dispatch inference_request DOWN the WS for WS-tunneled
        providers (called from buyer/server.go)
      - Request_id state map (active + completed + cleanup)
      - Multiplexing N concurrent requests per WS (bounded by
        provider's max_concurrency)
      - nak special-case for § 6.6 (mark http_forwarding_only)
      - WS write buffer backpressure (FR-P19, FR-P20)
      - Cancellation propagation (FR-P18)

  /Users/augstar/macprovider-poc/phase4-coordinator/internal/buyer/server.go
    Major rewrite:
      - Mode resolution per SPEC-002 v1.1.2 § 3 (pinned vs
        provisional, HTTP vs WS-tunneled)
      - For HTTP-forwarding providers: keep existing GET-to-endpoint
        path
      - For WS-tunneled providers: hand off to ws.Server's
        dispatch_inference_request, await response chunks, stream
        back to buyer as SSE (or accumulate for non-streaming)
      - Status-to-buyer-HTTP mapping per FR-P14.1
      - Quota check (check_provisional_quota) per FR-P16
      - quota_blocked_candidates disambiguation (FR-P16 + § 5
        pseudocode update)
      - Pre-emptive HTTP 429 when all candidates quota-blocked

  /Users/augstar/macprovider-poc/phase4-coordinator/internal/pool/provider.go
    Add Tier field (pinned / provisional / rejected) to Provider
    struct. Add admission timestamp. Add quota counter (sliding
    window 1hr). Update tier on operator-driven promotion/rejection.

  /Users/augstar/macprovider-poc/phase4-coordinator/internal/config/config.go
    Add Admission config block:
      pinned_only: bool (legacy mode — default false)
      provisional_admission_rate_per_hour: int (default 10)
      provisional_pool_max: int (default 100)
      provisional_quota_per_hour: int (default 100)
      provisional_tier_weight: float (default 0.3)
    Add coordinator_advertised_version block:
      latest_binary_version: string (in hello_ack)
      required_binary_version: string (optional; reject below)

  /Users/augstar/macprovider-poc/phase4-coordinator/coordinator.yaml.example
    Update template to reflect new admission config schema.

  /Users/augstar/macprovider-poc/phase4-coordinator/internal/auth/tokens.go
    Add bearer-auth helper for the three new /admin/* endpoints.

  /Users/augstar/macprovider-poc/phase4-coordinator/tools/mockprovider/main.go
    Extend with:
      --omit-endpoint-url flag (signals WS-tunneled mode in hello)
      Handle inference_request: simulate response chunks per --canned
        config (already partially exists; extend for new message types)
      Handle cancel_request: stop emitting chunks immediately
      Add --reject-nak flag: respond nak unknown_message_type to
        any § 6.6 message (for AC-15 backward-compat test)

Create (new files):
  /Users/augstar/macprovider-poc/phase4-coordinator/internal/ws/admission.go
    New file. Admission tier state machine + rate-limit logic.
    SPEC-002 v1.1.2 FR-P15..FR-P17 implementation.

  /Users/augstar/macprovider-poc/phase4-coordinator/internal/ws/relay.go
    New file. WS-tunneled inference relay. Multiplexing state +
    backpressure + cancellation propagation. SPEC-002 v1.1.2 FR-P14,
    FR-P14.1, FR-P18, FR-P18.1, FR-P19, FR-P20, FR-P21.

  /Users/augstar/macprovider-poc/phase4-coordinator/internal/ws/admin_endpoints.go
    New file. POST /admin/promote/{provider_id} + POST
    /admin/reject/{provider_id} + GET /admin/provisional handlers.

  /Users/augstar/macprovider-poc/phase4-coordinator/scripts/test-ac11-admission.sh
    AC-11 test: provisional provider hello → admitted, shown in
    /poolz with tier=provisional.

  /Users/augstar/macprovider-poc/phase4-coordinator/scripts/test-ac12-quota.sh
    AC-12 test: provisional provider's 101st request/hour → HTTP 429.

  /Users/augstar/macprovider-poc/phase4-coordinator/scripts/test-ac13-ws-relay.sh
    AC-13 test: buyer request → coordinator → mockprovider via
    WS-tunneled mode → response back. End-to-end.

  /Users/augstar/macprovider-poc/phase4-coordinator/scripts/test-ac14-cancellation.sh
    AC-14 test: buyer disconnect mid-stream → cancel_request to
    provider → provider aborts within 1s.

  /Users/augstar/macprovider-poc/phase4-coordinator/scripts/test-ac15-nak-fallback.sh
    AC-15 test: coordinator dispatches § 6.6 to mock that responds
    nak unknown_message_type → coord marks provider
    http_forwarding_only for session, returns HTTP 503 to buyer.

  /Users/augstar/macprovider-poc/phase4-coordinator/internal/ws/relay_test.go
    Unit tests for relay multiplexing, backpressure, cancellation.

  /Users/augstar/macprovider-poc/phase4-coordinator/internal/ws/admission_test.go
    Unit tests for tier transitions, rate limits, quota check.

## Scope you MUST NOT modify

  - Anything under /Users/augstar/macprovider-poc/phase3-binary/
    (Swift package — BUILD_SWIFT owns this)
  - Anything under /Users/augstar/macprovider-poc/specs/
    (spec corpus is locked)
  - Anything under /Users/augstar/macprovider-poc/beta/
    (Phase 2 harness)
  - /Users/augstar/macprovider-poc/phase4-coordinator/dist/
    (deployed coordinator — only updated post-build)
  - /Users/augstar/macprovider-poc/.github/workflows/
    (BUILD_DISTRIBUTION owns this)

If you find yourself wanting to edit any of the above, STOP — you've
crossed a stream boundary.

## Critical implementation constraints

**1. Backward compatibility (load-bearing).** The HTTP-forwarding
path for pinned providers MUST stay functional. M4 (v1.1.4) and M1
(v1.1.3) phase3-binaries are CURRENTLY in production; their hellos
do NOT include `endpoint_url` (that field was added in SPEC-001 v1.2
which is in BUILD_SWIFT not yet built). But they are in
config.providers[] with operator-set endpoint_url. Mode resolution
per SPEC-002 v1.1.2 § 3 sends them to HTTP-forwarding mode.

Your changes MUST NOT regress the existing M4/M1 traffic path.
Verify with: deploy your coord locally + connect mockprovider with
endpoint_url set + run a buyer request → should use HTTP-forwarding.

**2. Buyer API stability.** POST /v1/chat/completions, GET
/v1/models, GET /healthz behavior is IDENTICAL to v1.0.4 from the
buyer's perspective. Headers, body shape, status codes all
preserved. Add NOTHING to the buyer-facing API surface.

**3. Wire compat with SPEC-001 v1.2.1.** Every WS message you send
or receive must match SPEC-001 v1.2.1 § 6.5 + § 6.6 EXACTLY. Field
names, JSON shape, enum values. If SPEC-001 says
`inference_response_chunk.request_id` is a string, it's a string.

**4. Q1 operator decision.** A provisional provider (provider_id NOT
in config.providers[]) that sends a non-empty `endpoint_url` in
hello MUST have that endpoint_url logged-warn and ignored. Force
WS-tunneled mode for unknown provider_ids. This is anti-Sybil per
SPEC-002 v1.1.2 § 3 mode resolution.

**5. No new external deps unless absolutely necessary.** The
existing dep set (gobwas/ws, go-chi, modernc.org/sqlite, etc.) is
sufficient for this work. If you think you need a new dep, document
why in implementation-notes and proceed cautiously.

## Implementation plan (high level — refer to spec for details)

### Phase A: extend wire types + mockprovider

1. Extend `internal/ws/messages.go` with new structs + close codes
2. Extend `tools/mockprovider/main.go` with the new behavior flags
3. Verify mockprovider builds + can handshake with v1.0.4 coord
   (regression check) and with what-you-will-build coord

### Phase B: admission tier state + config

4. Implement `internal/ws/admission.go` with the tier state machine
5. Extend `internal/config/config.go` schema
6. Update `coordinator.yaml.example`
7. Extend `internal/pool/provider.go` with Tier field + quota counter
8. Unit tests for admission rate limits (admission_test.go)

### Phase C: relay logic (largest piece)

9. Implement `internal/ws/relay.go`:
   - Request_id active map (sync.Map or mutex-guarded)
   - Dispatch inference_request DOWN the WS to provider
   - Track response chunks back up, route to buyer's HTTP response
     writer
   - Cancellation propagation (buyer disconnect → cancel_request)
   - Backpressure (bounded per-provider WS write buffer)
10. Wire relay into `internal/ws/server.go`'s message dispatch
11. Unit tests for relay multiplexing + backpressure (relay_test.go)

### Phase D: buyer-side rewrite

12. Rewrite `internal/buyer/server.go` to handle two paths:
    - HTTP-forwarding (existing logic, preserved unchanged for
      pinned providers)
    - WS-tunneled (new — uses relay)
13. Mode resolution per SPEC-002 v1.1.2 § 3
14. Status-to-buyer-HTTP mapping per FR-P14.1
15. Quota check + 429 vs 503 disambiguation

### Phase E: admin endpoints + § 7.5

16. Implement `internal/ws/admin_endpoints.go`
17. Wire onto provider_port (FR-O5)
18. Bearer-auth via existing tokens.go

### Phase F: routing pseudocode → real code

19. Update routing in `internal/ws/server.go` (or wherever routing
    lives) to:
    - Use `model_id_equal` (casefold) per D9
    - Apply tier weight to effective_throughput
    - Implement quota_blocked_candidates disambiguation per § 5

### Phase G: acceptance tests

20. Implement the five AC scripts (test-ac11..15)
21. Run them locally against your built coordinator
22. Document results in implementation-notes

## Test strategy

- Unit tests for each new package (admission_test.go, relay_test.go)
- Acceptance test scripts run against local coordinator + mockprovider
- DO NOT test against the production coordinator at
  coordinator.malibu.tech — your changes are unverified until
  AC scripts pass locally
- After all ACs pass, document any deviations in implementation-notes
- Integration test with v1.2 phase3-binary happens post-merge (when
  BUILD_SWIFT lands)

## Process

1. Read all required materials.
2. Outline phases A-G in a scratchpad.
3. Build phases in order. Each phase produces something testable.
4. After each phase, run `go build ./...` + relevant unit tests.
5. At end, run all AC scripts. Document results.
6. Append "Coordinator stream build" section to
   /Users/augstar/macprovider-poc/phase4-coordinator/implementation-notes.html
   covering design choices + deviations + open questions.
7. Print a 500-word handback summary:
   - Files created (paths + line counts)
   - Files modified (paths + delta line counts)
   - Files touched OUTSIDE scope: should be NONE
   - go build status (must be clean)
   - Unit test results (pass/fail counts)
   - AC test results (each of AC-11..AC-15 walked through)
   - Backward-compat verification: ran mockprovider with
     endpoint_url set → confirmed HTTP-forwarding path still works
   - Open OQs that operator should decide
8. Do NOT commit. Operator commits all three streams as one
   coordinated commit after integration testing.

## What NOT to do

- Do NOT modify Swift files.
- Do NOT touch spec corpus.
- Do NOT inspect d-inference source.
- Do NOT add new Go dependencies unless absolutely necessary.
- Do NOT deploy to production VPS — operator deploys post-merge.
- Do NOT commit; operator commits.
- Do NOT modify the buyer-facing API surface.
- Do NOT remove the HTTP-forwarding path; both paths coexist.

When done, print the 500-word handback summary and stop.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist:

1. `go build ./...` clean from `/Users/augstar/macprovider-poc/phase4-coordinator/`.
2. `go test ./...` passes including new admission_test.go + relay_test.go.
3. All five AC scripts (test-ac11..15) pass against the local build.
4. Backward-compat verification: start coordinator locally, point an
   existing mockprovider with endpoint_url at it, run a buyer request
   → HTTP-forwarding path used.
5. `git diff --stat` shows files modified ONLY in
   `phase4-coordinator/`.

Hold this stream's deliverables until BUILD_SWIFT lands, then
integration test against the real v1.2 binary before deploying v1.1.2
coordinator to Pearl VPS.
