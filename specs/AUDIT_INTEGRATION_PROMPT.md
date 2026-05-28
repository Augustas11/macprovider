# Integration audit prompt — three-stream composition review

Operator-paste prompt for **cross-stream integration audit** after the
Swift, Go, and Distribution streams each pass their own per-stream
audit cycles. Each per-stream audit (Codex) verified ONE codebase in
isolation; this audit verifies the THREE codebases COMPOSE correctly.

Run with **Claude CLI** (different model than Codex did per-stream
audits — cross-model coverage of the integration surface). Expected
duration: ~45-60 min.

The integration audit catches a different failure class than per-
stream audits:
  - Per-stream: bugs within one codebase
  - Integration: assumptions one stream made about another that
                 turn out wrong (the "SPEC-001 said UUID per
                 instance, SPEC-002 said static config map"
                 problem, but at the implementation level)

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Claude Code session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are performing an integration audit of three coordinated build
streams in the Mac Provider project. Each stream has already passed
its own per-stream Codex audit. This audit verifies that the three
streams COMPOSE correctly — that assumptions one stream made about
another hold.

The three streams under composition audit:

  Stream A (Swift):       phase3-binary v1.2.1 implementation
                          Owns: phase3-binary/Sources/, Tests/
  Stream B (Go):          phase4-coordinator v1.1.2 implementation
                          Owns: phase4-coordinator/
  Stream C (Distribution): install.sh / launchd / GitHub Action /
                          README
                          Owns: phase3-binary/dist/install.sh,
                          uninstall.sh, launchd-plist-template.plist,
                          .github/workflows/release.yml, README.md,
                          phase3-binary/README.md
                          (already committed at 596460b)

Your job: read all three implementations + the three locked specs +
trace cross-stream contract points, then produce a structured audit
at /Users/augstar/macprovider-poc/specs/INTEGRATION-audit.md.

You are NOT here to re-audit per-stream code quality. The per-stream
Codex audits already covered:
  - Internal correctness within a stream
  - Spec compliance within a stream
  - Code-level safety (path safety, escaping, validation)

You ARE here to catch:
  - Wire compat: field-by-field, does Stream A send what Stream B
    parses?
  - CLI compat: does Stream C invoke CLI flags Stream A actually
    accepts?
  - HTTP/JSON compat: does Stream C grep on the response shape
    Stream B actually emits?
  - Release shape: does Stream C's GitHub Action produce the asset
    layout `macprovider-cli update` (Stream A) expects?
  - End-to-end flow gaps: walking "stranger curls install.sh" step
    by step, where does the chain assume something that's not
    guaranteed?
  - Test coverage gaps: does any cross-stream interaction lack a
    test in any stream?

## Critical constraints

**1. Backward-compat invariant.** SPEC-001 v1.2.1 backward-compat
statement (lines 20-38) is load-bearing. v1.1.x binaries (M4, M1
currently in production) must remain MANDATORY-compliant after
v1.2 deploy. Verify the implementations honor this:
  - Does Stream A's hello still match v1.1.x shape when endpoint_url
    is omitted?
  - Does Stream B's mode resolution send § 6.6 ONLY to providers
    that signaled WS-tunneled mode?
  - Does Stream B's nak fallback on § 6.6 from a v1.1.x provider
    actually do the right thing?

**2. d-inference clean-room.** Do not inspect d-inference source.
Reading their LICENSE is allowed if needed for cross-reference.

**3. Buyer API stability.** No observable change to
POST /v1/chat/completions, GET /v1/models, GET /healthz from a
buyer's perspective.

**4. Scope discipline.** Don't re-audit what per-stream audits
already covered. If you find a code-level bug INSIDE one stream
that's not a composition issue, file it as a MINOR with a note
"per-stream audit may have missed this." But the primary value of
this audit is integration findings — focus there.

## Required reading

### The three locked specs (the contracts)

1. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   v1.2.1 — wire protocol + binary spec. Especially:
     § 6.5 hello / hello_ack schemas
     § 6.6 inference_request, inference_response_chunk,
       inference_response_end, cancel_request schemas
     § 6.6 Request ID lifecycle
     § 6.5 nak fallback
     CLI subcommands (status, update, uninstall)

2. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md
   v1.1.2 — coordinator spec. Especially:
     § 3 mode resolution
     § 5 routing pseudocode (model_id_equal, check_provisional_quota,
       quota_blocked_candidates)
     § 7.1 wire schemas (must mirror SPEC-001)
     § 7.5 admin endpoints
     close codes 4007/4008/4009
     FR-P14.1 status-to-buyer-HTTP mapping

3. /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md
   v0.4 — distribution + onboarding spec. Especially:
     § 4 FR-C1..FR-C8 (distribution lifecycle)
     § 4 FR-D1..FR-D5 (onboarding UX)
     § 5 AC-1, AC-2, AC-3
     § 7 install.sh contract + launchd plist + GitHub Releases shape

### The three implementations (the contract realizations)

4. /Users/augstar/macprovider-poc/phase3-binary/Sources/ — read
   fully:
     macprovider-cli/CoordinatorClient.swift (Stream A wire impl)
     macprovider-cli/InferenceRelay.swift (Stream A § 6.6 handler)
     macprovider-cli/MacProviderCLI.swift (Stream A CLI surface)
     macprovider-cli/SelfUpdate.swift (Stream A update subcommand)
     macprovider-cli/UninstallCommand.swift (Stream A uninstall)
     macprovider-cli/HTTPServer.swift (Stream A /v1/status etc)
     MacProviderCore/Config.swift (Stream A config schema)
     Tests/macprovider-cliTests/ (Stream A unit tests)
     scripts/test-ac11..15.sh (Stream A AC scripts)
     tools/mock-coordinator/ (Stream A test harness)

5. /Users/augstar/macprovider-poc/phase4-coordinator/ — read fully:
     internal/ws/messages.go (Stream B wire types)
     internal/ws/server.go (Stream B handshake + dispatch)
     internal/ws/relay.go (Stream B WS-tunneled inference relay)
     internal/ws/admission.go (Stream B admission tier)
     internal/ws/admin_endpoints.go (Stream B /admin/* handlers)
     internal/buyer/server.go (Stream B buyer HTTP + mode resolution)
     internal/pool/provider.go (Stream B pool state)
     internal/config/config.go (Stream B config schema)
     tools/mockprovider/main.go (Stream B test harness)
     scripts/test-ac11..15-*.sh (Stream B AC scripts)

6. /Users/augstar/macprovider-poc/phase3-binary/dist/install.sh
   /Users/augstar/macprovider-poc/phase3-binary/dist/uninstall.sh
   /Users/augstar/macprovider-poc/phase3-binary/dist/launchd-plist-template.plist
   /Users/augstar/macprovider-poc/.github/workflows/release.yml
   /Users/augstar/macprovider-poc/README.md
   /Users/augstar/macprovider-poc/phase3-binary/README.md
   — Stream C deliverables (committed at 596460b)

### Audit history (for context, don't re-do)

7. /Users/augstar/macprovider-poc/specs/SPEC-003-audit.md
   — spec-side audit history (rounds 1, 2, 3). The per-stream
   audits (when they land) will have their own files. Read this
   for tone/format continuity.

8. /Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md
   — entries 12-18 explain the Phase 4 production lessons that
   drove these specs.

## Audit categories — integration focus

### Category W: Wire compat (Swift ↔ Go)

W.1  hello message: Stream A sends fields per SPEC-001 v1.2.1 § 6.5;
     Stream B parses them per SPEC-002 v1.1.2 § 7.1. Walk each
     field. Type, name, required vs optional. CRITICAL on any
     mismatch.
     Verify especially:
       - endpoint_url: Swift sends omitted/null when in WS-tunneled
         mode; Go reads absent-as-null per § 3 resolution
       - tier in hello_ack: Go sends "pinned" or "provisional";
         Swift reads it (currently for log nudge)
       - recommended_binary_version: Go sends; Swift uses for nudge

W.2  inference_request: Go sends per SPEC-001 § 6.6; Swift's
     InferenceRelay parses. Walk each field. CRITICAL on mismatch.

W.3  inference_response_chunk: Swift sends; Go's relay parses. Walk
     each field including chunk index (if any), final flag (if
     any), content shape.

W.4  inference_response_end: Swift sends with `status` per
     FR-P14.1 enum; Go's relay maps to buyer HTTP per § 5. Verify
     the status enum values match BYTE-FOR-BYTE between Swift and
     Go.

W.5  cancel_request: Go sends; Swift handles. Verify request_id
     correlation works.

W.6  nak fallback (M5 critical): if Stream A binary is v1.1.x
     (which doesn't have § 6.6 handlers), it responds nak. Stream
     B must detect this and mark http_forwarding_only. The current
     committed Swift binary IS v1.2 — verify the test exists to
     simulate v1.1.x behavior.

W.7  close codes 4007/4008/4009: Stream B emits; does any code in
     Stream A reference these constants? (If yes, they must match.)

### Category H: HTTP/JSON compat (Stream C → Stream B + Stream A)

H.1  install.sh AC-1 verification: install.sh queries coord
     /v1/models AND /poolz to verify this provider_id appears.
     Verify:
       - The URL paths match Stream B's actual route registrations
       - The JSON shape install.sh greps matches what Stream B emits
       - The auth header on /poolz matches what Stream B expects
         (bearer? operator_key?)

H.2  install.sh launchd plist substitution: the rendered plist
     invokes `macprovider-cli` with specific flags. Verify each
     flag exists in Stream A's CLI:
       - --port
       - --model
       - --provider-id
       - --coordinator
       - --endpoint-url (if set)
     If any flag changed name or doesn't exist, CRITICAL.

H.3  install.sh AC-1 also expects the binary to bind locally and
     answer /v1/models. Verify Stream A's HTTPServer serves that
     route shape.

### Category R: Release shape (Stream C → Stream A)

R.1  GitHub Action produces a tarball at a specific path/asset
     name; install.sh + Stream A's SelfUpdate.swift both consume
     this. Verify:
       - Asset name pattern matches between Action and consumers
       - SHA256 checksum file naming consistent
       - Signature file naming consistent
       - Tarball contents (binary path, mlx-swift Cmlx.bundle, etc)
         match what install.sh extracts to

R.2  SelfUpdate.swift queries GitHub Releases API for "latest" —
     verify Action sets the release as latest correctly.

R.3  install.sh and SelfUpdate.swift both verify SHA256 + (optional)
     signature. Are they verifying the SAME files in the SAME order?

### Category E: End-to-end flow walkthrough

E.1  Walk through "stranger runs install.sh on clean Mac":
       1. install.sh downloads tarball + checksums + signature
       2. Verifies checksum signature
       3. Verifies tarball checksum
       4. Extracts to ~/macprovider/
       5. Renders launchd plist with user's handle
       6. Loads plist via launchctl
       7. Binary starts; sends hello to coordinator with provider_id
          + omitted endpoint_url
       8. Coordinator (provisional admission) accepts hello, sends
          hello_ack with tier=provisional
       9. Binary heartbeats; binary's local /v1/models serves
      10. install.sh's AC-1 check: provider_id appears in coord
          /poolz
      11. install.sh prints success + uninstall command
     At each step, identify what could break across stream boundaries.

E.2  Walk through "buyer sends POST /v1/chat/completions to coord
     for a provisional provider":
       1. Coord receives buyer request
       2. Coord routes to provisional provider (tier-weighted)
       3. Coord sends inference_request via WS
       4. Provider's InferenceRelay receives, dispatches to ModelRuntime
       5. Provider streams inference_response_chunk frames
       6. Coord relays to buyer as SSE
       7. On completion, provider sends inference_response_end
       8. Coord maps status to HTTP per FR-P14.1
       9. Coord cleans up request_id state; provider does same
     Find gaps.

E.3  Walk through `macprovider-cli update`:
       1. Subcommand queries GitHub Releases API
       2. Compares compiled version to latest tag
       3. Downloads tarball + checksum + signature
       4. Verifies
       5. Stops current binary gracefully (drain coord WS, finish
          in-flight requests up to drain_timeout_s)
       6. Replaces binary file atomically
       7. Restarts via launchctl
     Find gaps.

E.4  Walk through `macprovider-cli uninstall`:
       1. Subcommand confirms with user
       2. Sends drain_status to coord, closes WS
       3. Stops self
       4. Removes ~/macprovider/, launchd plist, logs
     Compare with `uninstall.sh` (Stream C, separate path). Are
     they consistent on what gets removed? Conflicts?

### Category T: Test coverage gaps

T.1  Stream A AC-11..15 + Stream B AC-11..15 + Stream C AC-1..3.
     Walk through which scenarios are covered by at least one test
     in some stream. Identify scenarios that are normative-required
     but tested NOWHERE:
       - Buyer disconnect → cancel propagation → provider abort
         (within 1s SLA)
       - Provisional quota exhausted → HTTP 429 with Retry-After
       - v1.1.x binary receives unexpected § 6.6 → nak →
         coord marks http_forwarding_only
       - Drain during in-flight § 6.6 (composition with v1.1.4
         state-reset fix)
       - Update mid-buyer-request (graceful drain)
       - Install on M1 8GB tier vs M4 16GB tier — model selection

T.2  Any AC script in any stream that asserts behavior involving
     ANOTHER stream's code? Those are the de facto integration
     tests. Are they correct?

T.3  Are there places where Stream A's tests use mocks that don't
     match Stream B's real behavior (or vice versa)?

### Category I: Inconsistent assumptions

I.1  Hardcoded URLs / paths / ports — does any stream hardcode
     something that should match another stream?
       - WS path: /ws/provider — referenced where?
       - Buyer port 8443, provider port 8444 — consistent?
       - install.sh hits coordinator.streamvc.live; does Stream A
         use that as default too?

I.2  Timeouts/limits — do values match?
       - drain_timeout_s
       - request_timeout_s
       - heartbeat_interval_s
       - reconnect grace (15s in v1.1.3)
       - provisional admission rate (10/hr default)
       - provisional pool max (100 default)
       - quota per provider (100/hr default)
     Any drift between spec, Go config, Swift config?

I.3  Default model selection in install.sh — based on RAM tier.
     Does Stream A's binary actually serve those models? Are the
     model_id strings byte-equal (casefold per D9)?

### Category B: Backward-compat verification (integration angle)

B.1  Scenario: M4 with v1.1.4 binary connects to v1.1.2 coord. M4's
     hello does NOT include endpoint_url. M4 IS in coord
     config.providers[] with operator-set endpoint_url. Mode
     resolution → HTTP-forwarding. Walk through. CRITICAL on any
     break.

B.2  Scenario: M4 with v1.1.4 binary connects to v1.1.2 coord +
     somehow coord mistakenly tries to send inference_request to
     M4. M4 responds nak unknown_message_type. Coord marks
     http_forwarding_only + returns 503 to buyer. Walk through.
     Is the AC test for this present in some stream?

B.3  Scenario: M4 upgrades to v1.2 binary while still in config
     with endpoint_url. v1.2 binary should DEFAULT to keeping
     endpoint_url in hello (since it's in config). Does it? Or
     does v1.2 default to omitting endpoint_url and breaking M4's
     mode resolution? CRITICAL on the latter.

### Category C: Configuration coherence

C.1  Stream B config (coordinator.yaml.example) lists admission
     defaults. Stream A doesn't need those. Stream C launchd plist
     passes coordinator URL + provider_id to Stream A. Do these
     three configs reference consistent values?

C.2  install.sh prompts user for handle which becomes provider_id.
     Are there validation rules in Stream A or Stream B that
     install.sh doesn't enforce? (e.g., character restrictions,
     length limits)

C.3  Stream B has a "required_binary_version" config (optional).
     Stream A's SelfUpdate.swift respects this — verify the field
     name + format match.

## Severity rubric

  CRITICAL — wire incompatibility between streams (would break
             integration on first run); broken backward-compat for
             M4/M1; install.sh would fail AC-1 because Stream B
             route shape differs; SelfUpdate would fail because
             release shape differs.

  MAJOR    — ambiguous integration contract; missing test coverage
             for a cross-stream interaction; inconsistent timeout/
             limit values across streams; flag name mismatch
             between install.sh and Swift CLI.

  MINOR    — documentation drift; cosmetic naming inconsistency;
             missing log message.

  QUESTION — auditor cannot determine from source materials.

## Output format

Write to:
  /Users/augstar/macprovider-poc/specs/INTEGRATION-audit.md

Structure:

  # Integration Audit Report
  Auditor: <model + version>
  Streams audited at HEAD:
    Stream A (Swift) commit <hash>
    Stream B (Go) commit <hash>
    Stream C (Distribution) commit 596460b
  Audit completed: <UTC timestamp>

  ## TL;DR verdict
  READY TO INTEGRATE | NEEDS REVISION
  Finding counts + top three risks.

  ## Wire-compat matrix (Category W)

  Standalone table: every WS message type × every field × Swift's
  serialization vs Go's parsing. Verdict column: matches / mismatch /
  not covered.

  ## CLI / HTTP-route compat matrix (Category H)

  Standalone table of every install.sh assumption about Stream A
  CLI or Stream B HTTP routes, with verification verdict.

  ## End-to-end flow gaps (Category E)

  For each E.1..E.4 walkthrough, list any cross-stream gap found.

  ## Findings by severity

  ### CRITICAL (N)
  ### MAJOR (N)
  ### MINOR (N)
  ### QUESTIONS (N)

  Format per finding: title, severity, category (W/H/R/E/T/I/B/C),
  affected files (across all three streams), what's wrong, fix
  direction (whichever stream should fix it).

  ## Backward-compat verification

  Result of the three B.1/B.2/B.3 scenarios walked through. YES/NO
  per scenario.

  ## Recommendation

  - If READY TO INTEGRATE: list integration test plan (start coord
    locally + run binary as provisional + send buyer request +
    verify end-to-end).
  - If NEEDS REVISION: per-stream fix list with which stream owns
    each fix.

## What NOT to do

- Do NOT re-audit per-stream concerns already covered by Codex's
  per-stream audits.
- Do NOT modify any code yourself.
- Do NOT browse d-inference.
- Do NOT propose new features.
- Do NOT skip the backward-compat scenarios in B.1/B.2/B.3.

When done, print a 200-word summary: verdict, CRITICAL/MAJOR counts,
top three integration risks, backward-compat verification result.
Then stop.

=== END PROMPT ===
```

---

## When to run this

- After Swift per-stream audit closes (Codex finds + Swift fixes
  applied)
- After Go per-stream audit closes (same)
- After both are committed (so HEAD has all three streams realized)

Then this Claude audit catches the composition issues no per-stream
audit could see.

## Expected output

- `specs/INTEGRATION-audit.md` (~300-500 lines)
- 200-word stdout summary
- Likely 2-5 findings (mostly MAJORs around wire field mismatches,
  missing cross-stream tests, or timeout/limit drift)
- If 0 CRITICALs → integration test next
- If any CRITICALs → fix before any local integration test attempt

## Why Claude, not Codex

Per-stream audits used Codex (catches concrete code-level issues).
Integration audit uses Claude (better at semantic gaps + spec-to-impl
correspondence + cross-component walkthroughs). Same cross-model
pattern that worked for SPEC-001/002 audits.

Each model has different blind spots; alternating maximizes coverage.
