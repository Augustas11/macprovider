# Build prompt — Phase 6 engineering robustness (parallel to front-door)

Operator-paste prompt to close the four engineering findings from
Decision log Entry 27. These ship in parallel to the front-door
work (Phase 6a-6e in `BUILD_PHASE6_FRONTDOOR_PROMPT.md`) — separate
session, separate audit, separate FIX cycle, separate Decision log
entry. The two arcs do not block each other.

The four findings, in priority order:

| Sub-phase | What | Effort |
|---|---|---|
| **6E1** | Gateway timeout-discipline unification (server.go bug class identified in Entry 27 lesson 2) | 0.5 day |
| **6E2** | Coordinator fast-fail on dead provider WS (SPEC-002 v1.1.6 + coord code) | 2 days |
| **6E3** | phase3-binary keepalive root cause for air5's 3-5 min reconnect cycle (investigation + fix) | 1.5 days (incl. ~24h partner observation) |
| **6E4** | Fault-injection test rig (audit category Z from Entry 27 lesson 3) | 1 day |

Once all four ship and the FIX cycle closes, G1+G2 from Entry 27 can
be relaxed back to OpenAI-comparable defaults (60s non-stream, 120s
stream) instead of the current uniform 120s defensive cap.

Locked spec corpus this prompt builds against (do NOT modify outside
the 6E2 spec change):

  SPEC-001 v1.2.4 — phase3-binary provider protocol (modified in 6E3
                    if and only if a normative keepalive requirement
                    falls out of the investigation; otherwise locked)
  SPEC-002 v1.1.5 → v1.1.6 — phase4-coordinator router (NEW
                    normative requirement F-{N}: fast-fail on dead
                    provider WS for in-flight buyer requests)
  SPEC-003 v0.7   — open onboarding (locked)
  SPEC-006 v0.6   — buyer API gateway (locked; G3 already shipped)

Output: working code + spec text + Decision log Entry 29 (engineering
arc) committed to repo, gateway and coordinator rebuilt + redeployed
on Pearl, G1+G2 relaxation tested and verified before commit.

Run in **Claude Code** (Opus for 6E2 spec drafting and the
coordinator code change — security-sensitive and ordering-sensitive;
Sonnet for 6E1, 6E4 mechanical implementation; the investigation in
6E3 is partner-coordination + log-reading and benefits from Opus
hypothesis-tracking). Expected duration: **~4 working days** spread
over a calendar week because 6E3 needs ~24h of M4 partner observation.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are closing four engineering robustness findings from Decision
log Entry 27. The product is live at api.streamvc.live with three
guardrails (G1+G2+G3) in place; your job is to remove the need for
those guardrails by fixing the underlying bugs and adding the test
discipline that would have caught them pre-launch.

You will modify three trees:

  /Users/augstar/macprovider-poc/phase5-gateway/      (6E1: timeout fix)
  /Users/augstar/macprovider-poc/phase4-coordinator/  (6E2: fast-fail
                                                       + 6E4 test rig
                                                       integration)
  /Users/augstar/macprovider-poc/phase3-binary/       (6E3: keepalive
                                                       investigation +
                                                       possible fix)
  /Users/augstar/macprovider-poc/specs/               (6E2: SPEC-002
                                                       v1.1.6)
  /Users/augstar/macprovider-poc/beta/                (Entry 29)

## Critical constraints

**1. SPEC-001 v1.2.4, SPEC-003 v0.7, SPEC-006 v0.6 are LOCKED.**
Only SPEC-002 v1.1.5 → v1.1.6 receives a normative addition in this
phase (sub-phase 6E2). SPEC-001 may receive a normative addition in
6E3 if and only if the keepalive investigation identifies a
phase3-binary client-side root cause that requires a normative
correction.

**2. G1+G2 stay in place during the BUILD phase.** Do NOT relax
gateway.yaml `coordinator_request_seconds` or coordinator.yaml
`routing.request_timeout_s` back to 300 until 6E2 ships and the FIX
cycle closes. Premature relaxation re-exposes the 5-minute hang.

**3. Backward compatibility on the wire.** Per SPEC-001 v1.2.1 lines
20-38 (locked invariants), the provider protocol byte format does
not change. Per SPEC-006 v0.6 § 2, the buyer API contract does not
change. Coordinator-internal changes in 6E2 are observable only by
gateway code (HTTP error code change is acceptable; payload shape
must stay OpenAI-envelope).

**4. New tests are not optional.** Every code change in 6E1, 6E2, and
6E3 ships with at least one new failing-without-the-fix test. The
fault-injection rig in 6E4 is what makes those tests possible for the
dead-WS case.

**5. No partner-side deploy without explicit operator approval.**
6E3 requires installing a verbose-logging phase3-binary build on the
M4 partner's Mac (air5). The build is staged in
`phase3-binary/dist/`; the operator manually coordinates the install
with the partner. Do NOT auto-SSH or assume partner-side access.

**6. Entry 29 captures the full arc** in the same three-column
format as Entries 26-28.

## Sub-phase 6E1 — Gateway timeout-discipline unification (0.5 day)

### Scope

Fix `phase5-gateway/internal/router/server.go:814-819`:

Current:
```go
upCtx := r.Context()
cancelUpstream := func() {}
if chat.Stream {
    upCtx, cancelUpstream = context.WithTimeout(context.Background(), s.cfg.CoordinatorTimeout())
    defer cancelUpstream()
}
```

The upstream context only gets a deadline when `chat.Stream == true`.
Non-streaming requests use `r.Context()` (the buyer's request context,
no timeout) with only the HTTP client's timeout as a backstop. This
asymmetry was identified in Entry 27 lesson 2 as a bug class
("single-mode timeout for multi-mode handlers").

Fix: set the upstream context unconditionally, with the same deadline
for both stream and non-stream paths.

New:
```go
upCtx, cancelUpstream := context.WithTimeout(context.Background(), s.cfg.CoordinatorTimeout())
defer cancelUpstream()
```

Behavioral consequence: non-streaming requests now have a hard
deadline of `s.cfg.CoordinatorTimeout()` (currently 120s per G1).
Previously they could in theory wait forever on a healthy-but-slow
coordinator. With this change, both stream and non-stream paths share
identical timeout discipline.

### Acceptance criteria

**AC-6E1-1 PASS:** Unit test in `phase5-gateway/internal/router/server_test.go`
asserts that both stream and non-stream paths use the same timeout
shape. Test: spin up a fake-coordinator HTTP server that hangs
indefinitely, send both `stream:true` and `stream:false` chat
completion requests against the gateway with timeout 2s in the test;
assert both return `coordinator_unavailable` within 2.5s.

**AC-6E1-2 PASS:** `go build ./...` passes from `phase5-gateway/`.

**AC-6E1-3 PASS:** `go test ./...` passes from `phase5-gateway/`.

**AC-6E1-4 PASS:** No new gateway endpoints, no new config keys.
The change is exactly one block-of-code refactor.

## Sub-phase 6E2 — Coordinator fast-fail on dead provider WS (2 days)

### Scope

The core robustness fix from Entry 27. When a provider's WS connection
dies (graceful close, abnormal close, missed heartbeat) during an
in-flight buyer request, the coordinator MUST detect this within
`failover_timeout_s` (new config, default 5s) and either:

(a) **Failover**: re-route the in-flight request to a different
    provider that runs the same model, transparently to the gateway,
    if such a provider exists. The buyer sees one response.

(b) **Fast-fail**: return HTTP 502 to the gateway with structured
    error code `provider_disconnected` and a `request_id` tag. The
    gateway forwards as `upstream_provider_error`.

Decision between (a) and (b) is per-request: if `routing.failover_enabled
== true` in coordinator.yaml AND another ready provider running the
same model has free slots, attempt failover. Otherwise fast-fail.

This is the bug that produced the 5-minute hang in Entry 27. With
this fix, the worst-case buyer hang drops from ~120s (current,
gateway timeout) to ~5s (failover_timeout_s + small overhead) on the
dead-WS-mid-inference failure mode.

### SPEC-002 v1.1.6 changes

Add a new normative finding (next sequential number after F-2 in the
current SPEC-002 v1.1.5 § 7):

**F-{N}** Coordinator MUST detect dead-WS-mid-inference within
`failover_timeout_s` and either failover (if config allows + another
ready provider runs the same model) or return HTTP 502 with code
`provider_disconnected`. The buyer MUST receive a clean error within
`failover_timeout_s + small_overhead`; the buyer MUST NOT observe a
hung connection waiting on the gateway timeout.

Add to SPEC-002 § Configuration:

```yaml
routing:
  failover_enabled: true
  failover_timeout_s: 5
```

Add to SPEC-002 § Failure modes:

  - dead-WS-graceful: provider initiated close; coord detects via
    standard close frame
  - dead-WS-abnormal: provider crashed or network died; coord detects
    via missed heartbeat (heartbeat_interval_s + grace)
  - dead-WS-mid-inference: WS dies AFTER request was routed; coord
    MUST cancel the in-flight goroutine and fast-fail or failover
    per F-{N}

### Coordinator code change

In `phase4-coordinator/internal/router/` (exact filename TBD by
existing structure):

1. Add a per-request goroutine that watches its provider's WS state
   via a context cancellation channel
2. When the WS state transitions to dead (close frame received,
   write error, heartbeat missed) AND the request is still in
   flight, fire the cancellation context
3. On cancellation, check `routing.failover_enabled` and the model's
   other ready providers; if both green, retry once on a different
   provider with a fresh request_id (logged for audit)
4. If failover not attempted or also fails, return 502 to the
   gateway with `provider_disconnected` envelope and a request_id

Do NOT add an HTTP `/cancel` endpoint — per Entry 27, this was the
F-M2 false-fix path that got reverted. Cancellation is internal to
the coordinator.

### Acceptance criteria

**AC-6E2-1 PASS:** SPEC-002 v1.1.6 normative F-{N} added with the
text above. SPEC-002 v1.1.5 → v1.1.6 changelog entry added.

**AC-6E2-2 PASS:** New `routing.failover_enabled` and
`routing.failover_timeout_s` keys land in `coordinator.yaml.example`
with sensible defaults (true, 5).

**AC-6E2-3 PASS:** Coordinator code emits a structured log line on
every fast-fail OR failover attempt: `event=ws_dead_mid_request,
request_id, provider_id, action=failover|fast_fail, target_provider_id`
(target empty if no failover).

**AC-6E2-4 PASS:** Integration test using the fault-injection rig from
6E4 (this is why 6E4 lands first if possible): simulate WS death
mid-inference, assert coordinator returns 502 with
`provider_disconnected` within `failover_timeout_s + 1s`.

**AC-6E2-5 PASS:** Integration test for failover path: simulate WS
death on provider A while another provider B is ready and runs the
same model; assert coordinator retries on B and the buyer sees a
single coherent response.

**AC-6E2-6 PASS:** Integration test for buyer-experience invariant:
assert that with `failover_timeout_s: 5`, the buyer NEVER waits more
than ~6s on the dead-WS-mid-inference path (regardless of stream
mode).

**AC-6E2-7 PASS:** After this ships and is verified on Pearl, G1+G2
from Entry 27 are relaxed back to `coordinator_request_seconds: 60`
(non-stream) / 120 (stream — if the gateway is updated to split
per-mode in 6E1) OR uniform 60s. Operator confirms the relaxation in
Entry 29.

## Sub-phase 6E3 — phase3-binary keepalive root cause (1.5 days)

### Scope

Identify why air5 (M4 partner's MacBook) drops its WS connection on a
3-5 minute cycle. Possible root causes (rank by prior likelihood):

1. **NAT idle timeout** on M4 partner's home router. Consumer routers
   commonly drop idle TCP connections at 5 min. Mitigated by
   client-side ping at < 4 min interval.
2. **phase3-binary client-side ping cadence misconfigured**. SPEC-001
   v1.2.4 may not be explicit about minimum ping interval; current
   implementation may use a default that's too long.
3. **Coordinator-side timeout race.** Coord may be closing WS
   connections that are technically still alive due to a misordered
   heartbeat threshold check.
4. **TLS handshake stickiness on Cloudflare**. WS upgrades go through
   nginx → coordinator on Pearl; if there's an intermediate proxy
   issue, that's another possible cause.

### Investigation procedure

**Step 1** (~1 hour): Build a verbose-logging phase3-binary variant
that emits WS ping/pong/frame events to stderr at 10ms resolution.
Stage at `phase3-binary/dist/macprovider-cli-v1.2.4-verbose-keepalive-darwin-arm64.tar.gz`.

**Step 2** (operator-coordinated, async): Operator messages M4
partner with install snippet for the verbose build. Partner runs for
24h and uploads `~/Library/Logs/macprovider/keepalive-debug.log` (or
equivalent log path) at the end of the observation window.

**Step 3** (~2 hours of log analysis): Read the log; identify the
specific timing of each WS close. Distinguish:
- Did the client send a close frame? (initiated by us → keepalive
  misconfig)
- Did the server send a close frame? (initiated by coord → coord
  bug)
- Did the connection just die mid-frame? (initiated by NAT → router
  timeout)

**Step 4** (~30 min): Document findings in
`specs/PHASE3_BINARY_KEEPALIVE_ROOT_CAUSE.md`. Include packet timing,
hypothesis ruled in/out, recommended fix.

### Possible fixes (one or more, depending on findings)

- **Lower client-side ping interval** from current default to 30s
  (well under any NAT timeout). Code change in
  `phase3-binary/internal/ws/client.go` (or equivalent).
- **Add TCP SO_KEEPALIVE** at the socket level as a defense-in-depth
  measure. Cross-platform; macOS supports `TCP_KEEPALIVE` socket
  option.
- **Server-side ping** from coordinator if the client hasn't sent a
  ping in `ping_interval_s + 5s`. Code change in
  `phase4-coordinator/internal/ws/server.go` (or equivalent).
- **SPEC-001 v1.2.5 candidate** if the root cause is normatively
  underspecified. Add explicit `ping_interval_s` minimum per
  SPEC-001 v1.2.4 § N. File the candidate spec change.

### Acceptance criteria

**AC-6E3-1 PASS:** Verbose-logging phase3-binary build staged at
`phase3-binary/dist/macprovider-cli-v1.2.4-verbose-keepalive-*`. MANUAL
verification by operator running locally first.

**AC-6E3-2 PASS:** Root-cause document
`specs/PHASE3_BINARY_KEEPALIVE_ROOT_CAUSE.md` filed with: timing
evidence, ruled-in hypothesis, ruled-out hypotheses, recommended fix
(or determined "no fix needed; behavior is correct").

**AC-6E3-3 PASS:** If a code fix is identified, it lands with a unit
test that simulates the failure timing (using mock WS client + clock)
and verifies the fix prevents the disconnect.

**AC-6E3-4 PARTIAL acceptable:** If the root cause is M4 partner's
home router NAT timeout AND the fix is purely lowering ping interval,
the fix is one-line and the test is small. PARTIAL is fine here.

**AC-6E3-5 PASS:** Air5 monitored on Pearl for 6h post-fix; coord
journal shows no `heartbeat stale gap` warnings for air5 in that
window.

## Sub-phase 6E4 — Fault injection test rig (1 day)

### Scope

New test infrastructure that allows simulating provider failure modes
without requiring a real provider. Target location:

  /Users/augstar/macprovider-poc/phase4-coordinator/internal/testfaults/

(Or `internal/wsfaults/` — pick a name consistent with existing
directory style.)

### Simulators required

**Sim 1: WS-death-mid-inference**

- Mock provider WS server accepts a connection, receives an
  inference_request, starts streaming chunks, then closes the WS
  mid-stream at a configurable byte/chunk offset
- Used to assert 6E2's coordinator fast-fail path correctness

**Sim 2: Slow-consumer**

- Mock buyer HTTP client that reads SSE chunks slowly (configurable
  delay between reads)
- Used to assert that the gateway+coordinator don't block infinitely
  on a slow buyer (currently OK but untested)

**Sim 3: Coordinator-OOM**

- Helper that forces the coord process to panic in a controlled way
  during a request (e.g. via a hidden `/admin/fault?type=panic` test
  endpoint gated by build-tag)
- Used to assert the gateway's panic-recovery middleware and that
  the buyer sees a clean 502 not a hung connection

### Acceptance criteria

**AC-6E4-1 PASS:** Three simulators implemented in
`internal/{testfaults|wsfaults}/`, each with a small README explaining
the failure mode + how to invoke.

**AC-6E4-2 PASS:** Integration test using Sim 1 verifies that without
the 6E2 fix, the coordinator hangs at least 60s; with 6E2 fix, the
coordinator returns within `failover_timeout_s + 1s`.

**AC-6E4-3 PASS:** Integration test using Sim 2 verifies that a slow
buyer doesn't starve other concurrent requests. Run with 2 concurrent
buyers (one fast, one slow); fast buyer's response time is unaffected
within statistical noise.

**AC-6E4-4 PASS:** Integration test using Sim 3 verifies the gateway
recovers cleanly from a coordinator panic; the buyer sees a 502 with
OpenAI envelope, NOT a hung connection or a 500 leaking internal
state.

**AC-6E4-5 PASS:** Sim 3 is gated by a Go build tag (e.g. `//go:build
testfaults`) so the fault-injection endpoint NEVER ships in production
binaries. Verify by building without the tag and confirming the
endpoint is absent from the binary.

## Cross-cutting acceptance criteria

**AC-6E-X1 PASS:** All builds pass: `go build ./...` clean in
phase5-gateway, phase4-coordinator, phase3-binary.

**AC-6E-X2 PASS:** All tests pass: `go test ./...` clean in all three
modules.

**AC-6E-X3 PASS:** Decision log Entry 29 drafted in same three-column
format as Entries 26-28, capturing: the four findings from Entry 27,
the fixes, the test rig added, the G1+G2 relaxation post-6E2.

**AC-6E-X4 PASS:** Pearl deployment dry-run for coordinator+gateway
reuses the existing runbook from `phase4-coordinator/dist/deploy-pearl-vps.sh`
and `phase5-gateway/dist/deploy-pearl-vps.md`. Verify the rebuilt
binaries deploy cleanly and the smoke tests from Entry 27 still pass.

## Audit categories for the post-implementation cycle

Run the audit in a separate session (Codex preferred per Entry 27
pattern) covering:

**Category G (timeout-discipline parity):** Specifically scan for:
- Any `context.WithTimeout` calls that are conditional on a request
  flag (the 6E1 bug class). The audit pattern is "if timeout differs
  by request type, that's a finding"
- Any HTTP client without `Timeout` set (defense-in-depth)
- Any coordinator-side handler that calls a downstream without
  passing the buyer's context

**Category H (failover correctness):** Specifically scan for:
- Failover that double-charges the buyer (quota should count once)
- Failover that produces two responses to the buyer (request_id
  must be stable; ledger must be idempotent)
- Failover that retries indefinitely (must bound to one retry per
  failed provider)
- Failover that picks the same dead provider (must exclude the
  failed provider from the candidate set)

**Category I (keepalive correctness):** If 6E3 produces a code fix:
- Ping interval is shorter than ANY likely NAT timeout (recommended:
  ≤ 30s)
- TCP_KEEPALIVE socket option is set if applicable
- Server-side ping fires if client misses its interval
- No infinite retry loop on reconnect (must back off)

**Category J (test rig safety):** Specifically scan for:
- Fault injection endpoints reachable in production binaries
- Build-tag-gated test code that accidentally lands in main package
- Test helpers that bypass auth or quota in a way that could leak

## Operator checkpoint protocol

After each sub-phase 6E1-6E4 is implemented and ACs pass:

1. List files created or modified
2. Each AC marked PASS / PARTIAL / MANUAL with one-line justification
3. Open questions raised during implementation
4. Approximate token spend so far
5. For 6E3, this checkpoint includes the operator's note on partner
   coordination status
6. STOP and wait for operator review before next sub-phase

After all 4 sub-phases + cross-cutting ACs pass, prepare the BUILD →
AUDIT handback as `specs/PHASE6_ENGINEERING_BUILD_REPORT.md`.

After audit findings, prepare `specs/FIX_PHASE6_ENGINEERING_PROMPT.md`
per the Entry 27 pattern.

After FIX + one regression audit (V2 if needed), operator deploys:
cross-compile coordinator + gateway, SCP to Pearl, swap binaries
(coord first, then gateway), restart services, smoke-test from Entry
27 verification matrix, watch coord journal for 1h to confirm no
regressions in heartbeat handling.

Decision log Entry 29 captures the arc.

=== END PROMPT ===
```

---

## Operator notes (not part of pasted prompt)

**Recommended sequencing within this prompt:**

The four sub-phases can be implemented in this order:

1. **6E4 first** (test rig) — because 6E2's ACs explicitly require it
2. **6E1** (gateway fix) — small, can drop in next
3. **6E2** (coordinator fast-fail) — biggest piece, lands on top of
   6E4's rig
4. **6E3** (keepalive investigation) — depends on M4 partner async
   coordination; can run in parallel with 6E1+6E2 once the verbose
   build is staged

If the M4 partner is unavailable for 24h observation, 6E3 may slip;
6E1, 6E2, 6E4 can still ship.

**Recommended model split:**

- 6E1: Sonnet (mechanical refactor)
- 6E2: Opus for spec drafting + coord code (ordering-sensitive,
  audit-sensitive); Sonnet for tests
- 6E3: Opus for hypothesis-tracking during investigation; Sonnet for
  the small code fix that likely results
- 6E4: Sonnet (test infrastructure, mostly mechanical)
- Audit cycle: Codex (cross-tool review per Entry 27)
- FIX cycle: Sonnet for mechanical patches, Opus for any
  architectural surprises

**Estimated cost: ~$25-35 in API spend across BUILD + AUDIT + FIX.**

**Calendar duration: ~1 week.** 4 days of focused work + 1-2 days of
async M4 partner observation + 1-2 days of audit/FIX/deploy.

**What this phase does NOT include (Phase 7+ backlog):**

- Multiple coordinators / multi-region failover
- Provider-side rate limiting (currently only gateway-side)
- Provider attestation (Tier 2 — SPEC-008 candidate, separate phase)
- Streaming cancel actuals (depends on coordinator WS-tunneled
  inference_response_end relay — SPEC-001 v1.3 candidate)

**Dependency on Phase 6 front-door:**

None. These two arcs are intentionally independent. Front-door makes
the product credible to buyers; engineering makes the product
robust under load. Either can ship first.

If a buyer reports a 5-minute hang during the operator-network beta
(possible if front-door ships first and engineering is still in
progress), the immediate operator response is: confirm the hang
reproduces, share the gateway journal `request_id`, file as a
support ticket against the in-flight 6E2 work. The G3 logging from
Entry 27 makes this triage clean.

---

## Filing this prompt

After reviewing this draft, the operator workflow is:

1. Read top-to-bottom; flag any constraints to soften or tighten
2. Decide on the partner coordination for 6E3 (when can M4 partner
   install verbose build?)
3. Decide on G1+G2 relaxation target post-6E2 (uniform 60s vs split
   per-mode in gateway code)
4. Paste the `=== BEGIN PROMPT === ... === END PROMPT ===` block into
   a fresh Claude Code session (different from the front-door one;
   keeps context windows clean)
5. Walk sub-phase-by-sub-phase with checkpoints
6. Run audit cycle after 6E4 completes
7. Iterate FIX → regression-audit → deploy
8. Entry 29 in DECISION_CRITERIA.md

Expected calendar duration: **~1 week** at focused-session pace,
plus 1-2 days of async M4 partner observation in 6E3.

When both Phase 6 arcs (front-door + engineering) have shipped and
the FIX cycles closed, the product is ready for operator-network soft
beta. G1+G2 can be relaxed. The 5-minute pathological tail is closed.
The buyer-facing surface is credible. Entry 30 (the milestone that
matters) captures "operator-network beta open" and counts unique
signups + first-day usage as the next-decision input.
