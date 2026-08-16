# Build prompt — Swift stream (SPEC-001 v1.2.1 + SPEC-003 v0.4 Swift subcommands)

Operator-paste prompt to implement BOTH SPEC-001 v1.2.1 (phase3-binary
wire protocol extension) AND SPEC-003 v0.4 Swift subcommands
(`update`/`status`/`uninstall`) in **one Codex session** that owns
the Swift package end-to-end. This avoids the merge conflicts that
would occur if two separate sessions both edited MacProviderCLI.swift,
Config.swift, and Package.swift.

This stream is fully parallelizable with BUILD_COORDINATOR (Go)
and BUILD_DISTRIBUTION (shell/YAML/markdown).

What this stream produces:
  - WS-tunneled inference message handlers (§ 6.6 of SPEC-001 v1.2.1)
  - Request_id state + multiplexing on the provider side
  - Backpressure on WS write
  - New CLI subcommands: `update`, `status`, `uninstall`
  - SPEC-001 v1.2.1 acceptance tests (AC-11..AC-15)

Expected duration: ~6-8 hours. Run in **Codex CLI** rooted at
`/Users/augstar/macprovider-poc/`.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`.

---

```
=== BEGIN PROMPT ===

You are implementing the Swift-side changes for the Mac Provider
v1.2 release. You own the entire phase3-binary Swift package.
Specifically:

  SPEC-001 v1.2.1 § 6.6 — WS-tunneled inference message types
                         (inference_request, inference_response_chunk,
                          inference_response_end, cancel_request) +
                         request_id lifecycle + backpressure +
                         optional endpoint_url field in hello
  SPEC-003 v0.4 Part C subcommands — macprovider-cli update / status
                                     / uninstall (Swift portion only)

The shell/YAML/markdown side of SPEC-003 (install.sh, launchd plist,
GitHub Action, README) is being built in parallel by a separate
session (BUILD_DISTRIBUTION). The coordinator-side Go changes are
being built by BUILD_COORDINATOR. You do NOT touch either.

## Project context

Mac Provider is a pooled-inference network. As of 2026-05-28:

  - `coordinator.malibu.tech` (Pearl VPS) live with pool N=2
  - M4 partner (Qwen 7B) on phase3-binary v1.1.4
  - M1 partner (Llama 3.2 3B) on phase3-binary v1.1.3
  - Both communicate with coord via HTTP-forwarding (their hellos do
    NOT include endpoint_url; coord uses static config.providers[]
    to find their public URL)

SPEC-001 v1.2 (your target version is v1.2.1 — same numeric, audit-
patched) adds opt-in WS-tunneled inference for providers that have
NO public URL. v1.1.x binaries (M4, M1) remain MANDATORY-compliant
without change — the backward-compat statement at SPEC-001 v1.2.1
lines 20-38 is load-bearing.

## d-inference clean-room

Do NOT inspect d-inference source. The patterns you implement here
(WebSocket multiplexing, request_id state, backpressure on framed
streams, cancellation propagation) are standard for outbound-worker
systems and predate d-inference. Reaffirm clean-room separation if
you reach for their patterns.

## Required reading (in order, fully)

1. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   v1.2.1 — the spec under build. Read all of it. Focus areas:
     § 0 + change-log header (BACKWARD COMPAT statement — preserve
        verbatim semantics)
     § 6.5 hello with optional endpoint_url (add this)
     § 6.5 hello_ack with optional tier + recommended_binary_version
     § 6.6 Inference message types (your biggest deliverable)
     § 6.6 Request ID lifecycle and error handling
     § 6.5 nak fallback semantics
     FR-21..FR-32 (your work)
     AC-11..AC-15 (your acceptance criteria)
     OQ-4 (frame size), OQ-5 (write buffer)

2. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md
   v1.1.2 — the coordinator spec. Focus on:
     § 3 mode resolution (so you know when coordinator sends you
       § 6.6 messages vs HTTP)
     § 7.1 wire schemas (match these EXACTLY)
     § 7.5 admin endpoints (informational; you don't implement these)

3. /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md
   v0.4 — your subcommand spec. Focus on:
     § 4 FR-C5, FR-C6, FR-C7 (update / status / uninstall semantics)
     § 5 AC-2 (`macprovider-cli update` atomic swap)
     § 7 Interface contracts (the CLI subcommand surface)

4. /Users/augstar/macprovider-poc/phase3-binary/Sources/ — current
   Swift code. Read these fully before editing:
     macprovider-cli/MacProviderCLI.swift (ArgumentParser main —
       you'll add subcommands here)
     macprovider-cli/CoordinatorClient.swift (current WS client —
       largest change happens here for § 6.6 handlers)
     macprovider-cli/ModelRuntime.swift (MLX runtime — the
       inference engine you'll feed § 6.6 messages into)
     macprovider-cli/ProviderStatus.swift (state + capacity)
     macprovider-cli/HTTPServer.swift (the local HTTP server — stays;
       parallel path to § 6.6)
     macprovider-cli/AsyncSemaphore.swift (concurrency primitive)
     MacProviderCore/Config.swift (extend with optional fields)
     MacProviderCore/ChatCompletionRequest.swift (request/response
       types — reuse for § 6.6)
     MacProviderCore/StopTokenFilter.swift (stays; reused)
     Tests/ — current test scaffolding

5. /Users/augstar/macprovider-poc/phase3-binary/dist/package.sh
   /Users/augstar/macprovider-poc/phase3-binary/dist/install-m4-coordinator.sh
   — operator-side tooling. Stays; you don't change these.

6. /Users/augstar/macprovider-poc/phase3-binary/implementation-notes.html
   — append your build notes here.

7. /Users/augstar/macprovider-poc/HANDOFF.md
   /Users/augstar/macprovider-poc/CONTINUE_RUNBOOK.md
   — project context.

## Scope you OWN (only modify or create these)

Modify (existing Swift files):
  /Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift
    Add subcommands: update, status, uninstall (SPEC-003 v0.4 Part C).
    Existing root command stays as default (serve mode).

  /Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift
    Major changes:
      - Hello message includes new fields if user opted in (or
        provides config). Default: omit endpoint_url (WS-tunneled
        mode default for v1.2).
      - Handle inbound inference_request: dispatch to ModelRuntime,
        stream results back via inference_response_chunk
      - Send inference_response_end on completion/error
      - Handle cancel_request: abort active inference for that
        request_id
      - Request_id state map (active + cleanup on response_end
        or coord disconnect)
      - WS write buffer backpressure (per OQ-5: provider-side
        buffer 256 chunks default)
      - Existing handlers (hello_ack, drain, warm_up, preflight)
        preserved unchanged

  /Users/augstar/macprovider-poc/phase3-binary/Sources/MacProviderCore/Config.swift
    Add optional fields:
      endpoint_url: String?      // SPEC-001 v1.2.1 § 6.5 (default nil)
      ws_tunneled_mode: Bool?    // explicit override
      auto_update_enabled: Bool? // SPEC-003 v0.4 FR-C5

  /Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift
    Maybe add cancellation hook: ability to abort in-flight inference
    by request_id. The current runtime may serialize requests — confirm
    behavior is compatible with the request_id state map in
    CoordinatorClient. Document any limitation.

  /Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/ProviderStatus.swift
    Add tier reporting (provisional vs pinned — informational from
    hello_ack). Add request_id active count for /v1/status output
    (used by `macprovider-cli status`).

  /Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/HTTPServer.swift
    Add GET /v1/status endpoint for `macprovider-cli status`
    subcommand to query locally. Existing routes preserved.

  /Users/augstar/macprovider-poc/phase3-binary/Package.swift
    Add a dependency ONLY if necessary. Existing deps (Yams,
    ArgumentParser, mlx-swift-examples pinned at 2.29.1) should
    suffice. If you must add (e.g., for HTTP client used by update
    subcommand), pin tightly + document rationale.

Create (new Swift files):
  /Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/InferenceRelay.swift
    New file. Owns request_id state + dispatches inference_request
    to ModelRuntime + streams chunks back. SPEC-001 v1.2.1 § 6.6
    implementation. Composable with CoordinatorClient.

  /Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/SelfUpdate.swift
    New file. `macprovider-cli update` implementation. Queries
    GitHub Releases API, downloads new tarball, verifies SHA256,
    atomic in-place replace. SPEC-003 v0.4 FR-C5.

  /Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/UninstallCommand.swift
    New file. `macprovider-cli uninstall` implementation. Removes
    launchd plist, ~/macprovider/, ~/Library/Logs/macprovider/.
    SPEC-003 v0.4 FR-D5. (Note: install.sh produces a separate
    uninstall.sh — this Swift subcommand is the
    "while-binary-still-running" path that does graceful shutdown
    first.)

  /Users/augstar/macprovider-poc/phase3-binary/Tests/macprovider-cliTests/InferenceRelayTests.swift
    Unit tests for request_id state, multiplexing, cancellation.

  /Users/augstar/macprovider-poc/phase3-binary/Tests/macprovider-cliTests/SelfUpdateTests.swift
    Unit tests for update logic (mock GitHub Releases API).

  /Users/augstar/macprovider-poc/phase3-binary/scripts/test-ac11.sh
    AC-11 test (per SPEC-001 v1.2.1): mock coordinator sends
    inference_request → binary handles → chunks returned. Uses a
    "mock coordinator" test harness (you build this as part of the
    test).

  /Users/augstar/macprovider-poc/phase3-binary/scripts/test-ac12.sh
    AC-12 test: streaming SSE through multiple chunks.

  /Users/augstar/macprovider-poc/phase3-binary/scripts/test-ac13.sh
    AC-13 test: multiplexing N concurrent requests.

  /Users/augstar/macprovider-poc/phase3-binary/scripts/test-ac14.sh
    AC-14 test: cancellation propagation. Mock coord sends
    cancel_request → binary stops generating within 1s.

  /Users/augstar/macprovider-poc/phase3-binary/scripts/test-ac15.sh
    AC-15 test (BACKWARD COMPAT — critical): mock coord sends
    inference_request to a v1.1.x binary (use the actual v1.1.4
    Release tarball produced from current HEAD's package.sh in
    a previous session — operator can supply path). The binary
    should respond `nak unknown_message_type`. AC verifies the
    nak shape only. (The coordinator-side fallback behavior is
    tested in BUILD_COORDINATOR AC-15.)

  /Users/augstar/macprovider-poc/phase3-binary/tools/mock-coordinator/
    NEW DIRECTORY. A small Swift binary (or shell+ncat script) that
    simulates the coordinator sending § 6.6 messages. Used by the
    AC scripts above. SPEC-001 v1.2.1 AC tests need this since
    the real coordinator-side implementation lives in another stream.

## Scope you MUST NOT modify

  - Anything under /Users/augstar/macprovider-poc/phase4-coordinator/
    (Go package — BUILD_COORDINATOR owns this)
  - Anything under /Users/augstar/macprovider-poc/phase3-binary/dist/
    (BUILD_DISTRIBUTION owns this; you don't touch install.sh /
    launchd plist / etc.)
  - Anything under /Users/augstar/macprovider-poc/specs/
    (spec corpus is locked)
  - Anything under /Users/augstar/macprovider-poc/beta/
    (Phase 2 harness)
  - /Users/augstar/macprovider-poc/README.md or other top-level
    markdown (BUILD_DISTRIBUTION owns README updates)
  - /Users/augstar/macprovider-poc/.github/workflows/
    (BUILD_DISTRIBUTION owns)

If you find yourself wanting to edit any of the above, STOP — you've
crossed a stream boundary.

## Critical implementation constraints

**1. Backward compatibility (load-bearing).** v1.1.x binaries
(currently deployed) MUST remain MANDATORY-compliant. Your changes
ADD behavior; they don't remove or alter existing behavior. The
hello message's existing required fields stay required; new
fields (endpoint_url) are optional. The existing message handlers
(hello_ack, drain, warm_up, preflight) stay byte-for-byte
compatible. § 6.6 message types are ONLY activated when the
coordinator sends them — which it only does in WS-tunneled mode.

If a v1.1.x binary upgrades to your v1.2 binary, its existing
behavior is preserved. If it doesn't upgrade, it remains compliant
with the MANDATORY portion of SPEC-001 v1.2.1.

**2. Wire compat with SPEC-002 v1.1.2.** Every WS message you send
or receive must match SPEC-002 v1.1.2 § 7.1 wire schemas EXACTLY.
SPEC-001 v1.2.1 § 6.5 and § 6.6 are the authoritative source; SPEC-002
mirrors them.

**3. Drain composition with v1.1.4 fix.** Your § 6.6 handlers must
compose cleanly with the existing drainFromCoordinator() and
v1.1.4's state-reset path:
  - On drain received with in-flight inference_request:
    - Send drain_status starting + in_progress
    - Wait for in-flight requests to complete OR cancel them
      (your choice — document the policy; spec § 6.6 has
      guidance on this; if absent, pick "let in-flight finish
      up to drain_timeout_s, then forcibly cancel and send
      response_end status=aborted")
    - Send drain_status complete
    - Close WS
    - Reset providerStatus.status to ready (per v1.1.4 fix)
  - Reconnect path stays same.

**4. Don't break the existing HTTP server.** The local
HTTPServer.swift (port 8080 by default) keeps serving buyer requests
DIRECTLY for pinned providers. § 6.6 is a SEPARATE path. Both work
simultaneously. Tests in test-ac1..AC-10 (existing) must continue
to pass after your changes.

**5. The mock-coordinator test harness is YOUR responsibility.**
You can't depend on BUILD_COORDINATOR being done. Implement a small
test harness (Swift tool OR shell+websocat script) that simulates
the coordinator-side wire protocol. Document where it lives + how
to run it.

## Implementation plan

### Phase A: extend wire types + Config

1. Update Config.swift with optional endpoint_url +
   ws_tunneled_mode + auto_update_enabled.
2. Update CoordinatorClient.swift's hello message generation to
   include endpoint_url when set in config.
3. Add JSON decode/encode for inference_request,
   inference_response_chunk, inference_response_end, cancel_request
   in a shared module (probably new file).
4. `swift build` clean.

### Phase B: InferenceRelay.swift

5. New file. Owns:
   - request_id active map (Swift actor)
   - dispatch inference_request to ModelRuntime
   - stream tokens as inference_response_chunk frames
   - send inference_response_end with final status
   - handle cancel_request: abort active inference + send
     response_end status=aborted
   - backpressure: bounded WS write queue (256 chunks default
     per OQ-5)
6. Wire InferenceRelay into CoordinatorClient's message dispatch.
7. Unit tests in InferenceRelayTests.swift.

### Phase C: drain composition

8. Update drainFromCoordinator() in CoordinatorClient.swift to
   handle in-flight § 6.6 requests (let finish OR cancel per drain
   timeout — document the choice).
9. Verify v1.1.4 state-reset still fires after drain.
10. Unit test for drain-during-inflight-§6.6.

### Phase D: status endpoint

11. Add GET /v1/status to HTTPServer.swift returning JSON with:
    - binary_version
    - tier (from last hello_ack)
    - pool position info if known
    - active request_id count
    - uptime
12. Existing /v1/models + /v1/chat/completions unchanged.

### Phase E: CLI subcommands

13. Add subcommand parsing to MacProviderCLI.swift. Use
    ArgumentParser's subcommand pattern. The default (no subcommand)
    is the current serve mode.
14. Implement SelfUpdate.swift:
    - Query GitHub Releases API for latest
    - Compare to compiled-in version (capture at build time)
    - Download tarball, verify SHA256
    - Stop current process gracefully (via launchctl unload + reload
      pattern — document)
    - Atomic file replace
    - Restart
15. Implement UninstallCommand.swift: gracefully stop + remove
    files.
16. Unit tests in SelfUpdateTests.swift (mock GitHub API).

### Phase F: mock coordinator + AC scripts

17. Build a mock-coordinator test harness in
    `phase3-binary/tools/mock-coordinator/`.
    Simplest viable: Swift package or `websocat` + bash script
    that sends scripted § 6.6 message sequences. Document choice.
18. Implement test-ac11.sh through test-ac15.sh.
19. AC-15 (backward-compat) needs an actual v1.1.4 binary tarball.
    Document the path operator should supply.

### Phase G: Release build + smoke test

20. `swift build` clean.
21. `swift test` passes (all unit tests).
22. Run AC-11..AC-14 against your debug build + mock coordinator.
23. Document AC-15 result (whether v1.1.4 binary was available).
24. Run package.sh to verify Release build still produces a
    valid tarball.

## Mock dependencies (other streams not yet done)

You do NOT have:
  - A v1.1.2 coordinator that sends § 6.6 messages (BUILD_COORDINATOR
    is in parallel)
  - install.sh / launchd plist (BUILD_DISTRIBUTION is in parallel)

You DO have:
  - The current v1.0.4 coordinator at coordinator.malibu.tech —
    DO NOT use this to test your changes (it doesn't send § 6.6 yet)
  - The mock-coordinator test harness YOU build

Integration test with the real new coordinator happens post-merge
when BUILD_COORDINATOR lands.

## Process

1. Read all required materials.
2. Outline phases A-G in a scratchpad.
3. Build phases in order; each produces something testable.
4. After each phase, run `swift build` + relevant unit tests.
5. At end, run all AC scripts. Document results.
6. Append "Swift stream build" section to
   /Users/augstar/macprovider-poc/phase3-binary/implementation-notes.html
   covering design choices + deviations + open questions.
7. Print a 500-word handback summary:
   - Files created (paths + line counts)
   - Files modified (paths + delta line counts)
   - Files touched OUTSIDE scope: should be NONE
   - swift build status (must be clean)
   - swift test results (pass/fail counts)
   - AC test results (each of AC-11..AC-15 walked through;
     AC-15 may be deferred to integration if v1.1.4 tarball
     not available)
   - Backward-compat verification: confirmed existing FR-1..FR-20
     behavior unchanged (run existing test scripts test-ac1..AC-10)
   - Drain composition: confirmed in-flight § 6.6 handling
   - mock-coordinator location + invocation pattern
   - Open OQs that operator should decide
8. Do NOT commit. Operator commits all three streams as one
   coordinated commit after integration testing.

## What NOT to do

- Do NOT modify Go files.
- Do NOT modify install.sh / launchd plist / README / .github/.
- Do NOT touch spec corpus.
- Do NOT inspect d-inference source.
- Do NOT add new Swift dependencies unless absolutely necessary.
- Do NOT commit; operator commits.
- Do NOT alter the buyer-facing HTTP API on the local server.
- Do NOT remove or alter existing message handlers (hello_ack,
  drain, warm_up, preflight); only add new behavior.
- Do NOT deploy or distribute the new binary; operator handles
  that post-merge.

When done, print the 500-word handback summary and stop.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist:

1. `swift build` clean from `/Users/augstar/macprovider-poc/phase3-binary/`.
2. `swift test` passes including new InferenceRelayTests.swift +
   SelfUpdateTests.swift.
3. All five new AC scripts (test-ac11..15) pass against the local
   debug build + mock-coordinator harness.
4. Existing AC scripts (test-ac1..AC-10 if present) still pass.
5. `git diff --stat` shows files modified ONLY in `phase3-binary/`
   AND NOT in `phase3-binary/dist/`.
6. The Swift package's Package.resolved hasn't drifted (or has
   drifted only for justified new deps).

Hold this stream's deliverables until BUILD_COORDINATOR lands, then
integration test: deploy v1.1.2 coord locally + v1.2 binary as a
provisional provider (without endpoint_url) → real end-to-end through
§ 6.6 wire path.

After integration tests pass, run `package.sh v1.2.1-final` to
produce the Release tarball; BUILD_DISTRIBUTION's install.sh will
fetch it via GitHub Releases.
