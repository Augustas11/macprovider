# Fix prompt — integration audit findings → cross-stream patch

Operator-paste prompt to apply the union of findings from the
cross-model integration audit (Codex round 1 in
`specs/INTEGRATION-audit.md`, Claude round 2 in
`specs/INTEGRATION-audit-claude.md`).

Combined results:
  3 CRITICAL  — all confirmed by both audits
  ~8 MAJOR    — Claude added 5 to Codex's findings
  4 MINOR     — opportunistic cleanup
  3 QUESTIONS — operator decision baked into this prompt (Q1=B)

This prompt touches all three streams (Swift / Go / shell). One
Codex CLI or Claude Code session can do all the fixes sequentially.
The streams are independent enough that you could split this into
three parallel sessions if you prefer; the file boundaries are
explicit in each finding's "Owner" tag.

Run in **Claude Code** (consistent with prior FIX_* prompts).
Expected duration: ~2-3 hours.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Claude Code session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are applying integration audit findings to the Mac Provider
project. Two independent audits (Codex GPT-5.5 + Claude) reviewed
the just-committed three-stream build and converged on 3 CRITICAL
findings + 8 MAJOR + 4 MINOR + 3 QUESTIONS.

The architecture is sound. Findings are about: (a) wire-format
mismatches between Swift and Go, (b) cross-stream contract
assumptions that don't hold, (c) missing test coverage for
cross-stream paths, (d) install path consistency.

You will edit files across all three streams:
  Stream A (Swift):       /Users/augstar/macprovider-poc/phase3-binary/
  Stream B (Go):          /Users/augstar/macprovider-poc/phase4-coordinator/
  Stream C (shell):       /Users/augstar/macprovider-poc/phase3-binary/dist/

Output: edits to existing files (no new versions). No version
bumps required — these are integration patches, not feature work.

## Critical constraints

**1. Backward-compat invariant is load-bearing.** The verbatim
backward-compat statement at SPEC-001 v1.2.1 lines 20-38 must
stay verbatim. § 6.6 normative scope clause untouched. After
your fixes, v1.1.x binaries (M4, M1) connecting to v1.1.2 coord
MUST still work via HTTP-forwarding path with no behavior change.

The C1 fix is INSIDE this invariant — fixing the NAK parser makes
backward-compat ACTUALLY work, not just claim to.

**2. d-inference clean-room.** Do not inspect d-inference source.

**3. Buyer API stability.** POST /v1/chat/completions,
GET /v1/models, GET /healthz observable behavior unchanged. C2's
new endpoint adds a new path (not modify existing).

**4. No new design beyond fix direction.** Every change must trace
to an audit finding's fix direction or the operator-decided Q1
answer below.

**5. Match the rigor pattern.** RFC 2119 normative keywords in
spec language. Tests for everything you change.

## Operator decisions (apply these as written)

**Q1 (Codex): /healthz placement — answer is B.**

Mount `/healthz` on the BUYER port (8443) in addition to provider
port (8444). Keep existing operator-port mount unchanged. This
eliminates reliance on nginx routing for /healthz buyer-port
stability — defense-in-depth against future infra config drift
(Pearl VPS nginx has drifted twice this project already).

**Q1 (Claude): mockprovider NAK shape — answer is "use SPEC-001
shape".**

Mock providers (Go's tools/mockprovider/main.go and Swift's
tools/mock-coordinator/) must emit NAKs in the SPEC-001 v1.2.1 §
6.5 nested format. The Go mock currently uses Go's struct shape
which masked C1. After this fix, mocks match real wire format.

**Q2 (Claude): /v1/models proxy routing — moot.**

After C2 lands (new pool-check endpoint), install.sh no longer
depends on /v1/models routing for the AC-1 check. Question
becomes irrelevant. Leave the nginx config as-is.

## Required reading (in order, fully)

1. /Users/augstar/macprovider-poc/specs/INTEGRATION-audit.md
   — Codex round 1 audit. Read CRITICAL + MAJOR sections.

2. /Users/augstar/macprovider-poc/specs/INTEGRATION-audit-claude.md
   — Claude round 2 audit. Read CRITICAL + MAJOR sections.
   Compare against round 1 — Claude confirmed all 3 CRITICALs
   AND added 5 new MAJORs.

3. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   v1.2.1 — wire protocol spec. Especially:
     § 6.5 nak message normative shape (the source of truth for
       C1 fix)
     § 6.6 message types (already implemented but verify against)

4. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md
   v1.1.2 — coordinator spec. Especially:
     § 7.1 close codes + nak fallback paragraph
     FR-P14.1 status mapping

5. /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md
   v0.4 — distribution spec. Especially:
     FR-C2 (canonical install path: ~/.local/bin/macprovider-cli)

6. Current implementations (the targets of your fixes):
     phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift
     phase3-binary/Sources/macprovider-cli/UninstallCommand.swift
     phase3-binary/tools/mock-coordinator/mock_coordinator.py
     phase4-coordinator/internal/ws/messages.go
     phase4-coordinator/internal/ws/relay.go
     phase4-coordinator/internal/ws/server.go
     phase4-coordinator/internal/buyer/server.go
     phase4-coordinator/internal/pool/provider.go
     phase4-coordinator/tools/mockprovider/main.go
     phase3-binary/dist/install.sh
     phase3-binary/dist/uninstall.sh

7. /Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md
   — context for D7-D10 lessons.

## Fixes to apply, grouped by stream

### Stream B (Go) — fix first

#### C1. NAK wire structure incompatibility

**Location:** `phase4-coordinator/internal/ws/messages.go` (Nak
struct + ParseNak) and `phase4-coordinator/internal/ws/relay.go`
(consumer of parsed NAK).

**Problem:** Go expects flat `{type, request_id, code, message}`.
SPEC-001 says nested `{type, in_reply_to, error: {code, message,
details?}}`. Swift sends spec shape. Mismatch → fallback never
fires → backward-compat broken.

**Fix:** Restructure Go's Nak struct to match SPEC-001:

```go
type NakError struct {
    Code    string                 `json:"code"`
    Message string                 `json:"message,omitempty"`
    Details map[string]interface{} `json:"details,omitempty"`
}

type Nak struct {
    Type      string   `json:"type"`
    InReplyTo string   `json:"in_reply_to"`
    Error     NakError `json:"error"`
}
```

Update all consumers (relay.go fallback check, server.go logging,
test files) to read `nak.Error.Code` and `nak.InReplyTo` instead
of `nak.Code` and `nak.RequestID`.

Add a test fixture using a REAL Swift NAK payload (copy from
phase3-binary's NAK sender). Place in
`phase4-coordinator/internal/ws/messages_test.go` (create if
absent) — verify ParseNak round-trips correctly.

#### C2. Add /v1/pool/check endpoint

**Location:** `phase4-coordinator/internal/buyer/server.go`

**Problem:** install.sh's AC-1 check greps `/v1/models` for
provider_id but Go doesn't return provider_ids there. Need a
new public endpoint.

**Fix:** Add `GET /v1/pool/check?provider_id=<id>` to the buyer
server (port 8443). Behavior:

  - Returns 200 with `{"provider_id":"<id>","tier":"...","state":"ready|degraded|draining|unavailable"}`
    if provider_id is in the pool
  - Returns 404 with `{"error":"provider_not_found","provider_id":"<id>"}`
    if not
  - No auth required (public — install.sh polls it during
    onboarding)
  - Rate limit: 1 req/sec/IP (simple in-memory bucket)
  - Logged at info level

Add to FR-P22 in SPEC-002 (informational addition) — actually,
do NOT modify the spec; this is a patch landing. Document the
endpoint in the existing implementation-notes.html instead.

Wire test: `phase4-coordinator/scripts/test-pool-check.sh` —
start coord with mockprovider connected, poll /v1/pool/check,
assert 200 with correct shape.

#### M2. Provisional quota 429 missing Retry-After

**Location:** `phase4-coordinator/internal/buyer/server.go`

**Fix:** When returning HTTP 429 for `provisional_quota_exceeded`
(line where the error response is constructed — search for
`429` and `quota`), add `Retry-After: 3600` header.

#### M3. ParseHeartbeat drops 3 fields

**Location:** `phase4-coordinator/internal/ws/messages.go` —
ParseHeartbeat function.

**Fix:** Read Claude's audit M3 finding for the exact 3 fields
that are dropped. Add them to the Heartbeat struct + ParseHeartbeat
unmarshal. Re-run go test ./... to confirm.

#### M4. NAK cross-stream test

**Location:** `phase4-coordinator/internal/ws/messages_test.go`
+ `phase4-coordinator/scripts/test-ac15-nak-fallback.sh`

**Fix:** This already partially exists from per-stream audit, but
uses Go-shape NAK (masked C1). Update to use real Swift-shape NAK
payload as the fixture. Test passes against the C1-fixed parser
and fails against the pre-fix parser.

#### Q1 (B). Mount /healthz on buyer port

**Location:** `phase4-coordinator/internal/buyer/server.go`

**Fix:** Add `r.Get("/healthz", s.handleHealthz)` to the buyer
server's chi router. The handler can be the SAME function as
the existing one on provider_port (extract to a shared helper
if cleaner). No auth, same JSON response shape as existing
/healthz on provider port.

Verify both ports serve /healthz after restart.

#### Mockprovider NAK shape (Claude Q1)

**Location:** `phase4-coordinator/tools/mockprovider/main.go`

**Fix:** When mockprovider emits a NAK (for AC-15 testing), use
SPEC-001 v1.2.1 § 6.5 nested format:

```json
{
  "type": "nak",
  "in_reply_to": "<request_id-or-message-type>",
  "error": {"code": "unknown_message_type", "message": "..."}
}
```

Not the Go-struct flat format.

### Stream A (Swift) — fix after Stream B's C1 lands

#### C3. Install path mismatch

**Location:** `phase3-binary/Sources/macprovider-cli/UninstallCommand.swift`

**Problem:** Swift uninstall looks at `~/.local/bin/macprovider-cli`,
install.sh writes to `~/macprovider/`. SPEC-003 FR-C2 says
`~/.local/bin/macprovider-cli` is the canonical binary path.

**Fix decision:** Align install.sh and UninstallCommand.swift to
SPEC-003. Binary goes at `~/.local/bin/macprovider-cli`. Support
files (models, logs, configs) stay at `~/macprovider/` or
`~/Library/Logs/macprovider/` as appropriate.

In `UninstallCommand.swift`:
  - Keep the binary path as `~/.local/bin/macprovider-cli`
  - Also remove `~/macprovider/` (the support dir) and
    `~/Library/Logs/macprovider/`
  - Remove launchd plist at `~/Library/LaunchAgents/live.malibu.provider.plist`

(Stream C will align install.sh — see below.)

#### M5. Phase 3 preflight test

**Location:** `phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift`
(create if absent)

**Fix:** Add a Swift unit test that exercises the preflight
handler in CoordinatorClient. Mock the WS, send a preflight
message, verify the binary computes preflight_ack with the
correct request_id correlation.

#### M6. Phase 3 drain test

**Location:** Same test file (or new
`CoordinatorClientDrainTests.swift`).

**Fix:** Unit test for drain handling. Cover:
  - Drain received with no in-flight § 6.6 requests → clean close
  - Drain received with in-flight § 6.6 requests → wait or cancel
    per drain_timeout_s, then close
  - After drain + reconnect, state resets to ready (v1.1.4 fix
    verification)

#### M7. Self-update graceful drain proof

**Location:** `phase3-binary/Tests/macprovider-cliTests/SelfUpdateTests.swift`

**Fix:** Add a test (or expand existing) that proves self-update
performs a graceful drain BEFORE replacing the binary:
  - Mock WS open + in-flight inference_request
  - Trigger update
  - Assert: drain_status starting → in_progress → complete sent
  - Assert: binary replacement happens AFTER drain complete
  - Assert: launchctl bootstrap restart invoked

If implementation doesn't currently do graceful drain on
self-update, add it (likely in SelfUpdate.swift right before the
binary swap).

#### Mock-coordinator NAK shape (Claude Q1, Swift side)

**Location:** `phase3-binary/tools/mock-coordinator/mock_coordinator.py`

**Fix:** Ensure the Python mock coordinator parses NAK in SPEC-001
nested format when receiving NAKs from Swift. Should already be
correct since Swift emits spec shape, but verify.

### Stream C (shell) — fix after Stream B's C2 endpoint lands

#### C2 (Stream C side). Use new pool-check endpoint

**Location:** `phase3-binary/dist/install.sh` — `wait_for_coordinator`
function (around line 514-525 per audit reference).

**Fix:** Replace the current `grep -Fq "$provider_id"` against
`/v1/models` with a call to the new endpoint:

```bash
wait_for_coordinator() {
  local deadline=$(($(date +%s) + 30))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local response
    response=$(curl -fsS --max-time 5 \
      "$COORDINATOR_BASE/v1/pool/check?provider_id=$(urlencode "$PROVIDER_ID")" \
      2>/dev/null) || { sleep 2; continue; }

    if echo "$response" | grep -q '"state":"ready"'; then
      return 0
    fi
    sleep 2
  done
  return 1
}
```

Add a `urlencode` helper if not present (one-liner Python or printf).

#### C3 (Stream C side). Binary path align

**Location:** `phase3-binary/dist/install.sh`

**Fix:** Change install path strategy:

  - Binary lives at `~/.local/bin/macprovider-cli` (per SPEC-003
    FR-C2)
  - Support directory `~/macprovider/` keeps models, configs
  - Update INSTALL_DIR + BINARY_PATH variables at top
  - Update launchd plist template's ProgramArguments to point
    at `~/.local/bin/macprovider-cli`
  - Ensure `~/.local/bin` exists (`mkdir -p`) before binary
    placement
  - Print a PATH check message: if `~/.local/bin` not in user's
    PATH, recommend adding it (or just instruct the user to use
    full path / launchctl-managed)

In `phase3-binary/dist/uninstall.sh`:
  - Same path alignment: remove
    `~/.local/bin/macprovider-cli`, then remove
    `~/macprovider/`, then logs + plist

#### M8. Uninstall consistency

**Location:** `phase3-binary/dist/uninstall.sh` and
`phase3-binary/Sources/macprovider-cli/UninstallCommand.swift`

**Fix:** Both paths (shell uninstall.sh AND swift
`macprovider-cli uninstall`) MUST remove the same set of files.
After this fix, walk through both code paths and verify the
file-removal lists are identical:

  - Binary: ~/.local/bin/macprovider-cli
  - Support dir: ~/macprovider/
  - Logs: ~/Library/Logs/macprovider/
  - Plist: ~/Library/LaunchAgents/live.malibu.provider.plist
  - Optional: ~/.cache/macprovider/ (warn user, don't auto-remove
    by default — addresses m4)

The Swift path additionally must drain the WS and stop heartbeats
before file removal. The shell path doesn't need to (it's the
binary-is-already-stopped scenario).

## Process

1. Read all required materials in order.

2. Apply Stream B fixes FIRST (C1, C2, M2, M3, M4, Q1=B,
   mockprovider NAK shape). Reason: C2 endpoint must exist
   before C3 can use it; C1 fix unblocks AC-15 testing.

3. Run `go test ./...` + `go vet ./...` from
   `/Users/augstar/macprovider-poc/phase4-coordinator/`. Must pass.

4. Run `./scripts/test-ac15-nak-fallback.sh` — confirms C1 fix
   works against updated test fixture using SPEC-001 NAK shape.

5. Run `./scripts/test-pool-check.sh` (new) — confirms C2 endpoint
   works.

6. Apply Stream A fixes (C3 path, M5 preflight, M6 drain, M7
   self-update drain, mock-coordinator NAK).

7. Run `swift build` + `swift test` from
   `/Users/augstar/macprovider-poc/phase3-binary/`. Must pass.

8. Apply Stream C fixes (install.sh use new endpoint + path
   align, uninstall.sh same).

9. Run `bash -n install.sh + bash -n uninstall.sh`. Run
   `install.sh --dry-run` and `uninstall.sh --dry-run`. All clean.

10. Cross-stream consistency self-review pass:
    - C1: Swift NAK shape now parsed correctly by Go (test M4 passes)
    - C2: install.sh polls /v1/pool/check, gets 200 with state:ready
      when provider_id is in pool
    - C3: install.sh writes to ~/.local/bin/macprovider-cli;
      both uninstall paths remove the same file set
    - Backward-compat: SPEC-001 lines 20-38 statement still verbatim
    - Q1=B: /healthz responds on BOTH ports

11. Append implementation notes to:
    - phase3-binary/implementation-notes.html
    - phase4-coordinator/implementation-notes.html
    - phase5-onboarding/implementation-notes.html

12. Print a 500-word handback summary:
    - Each finding (C1/C2/C3 + M2/M3/M4/M5/M6/M7/M8 + Q1=B + Q1
      mockprovider): CLOSED / PARTIAL
    - Files modified per stream
    - Test results: go test + swift test + bash -n + AC scripts
    - Backward-compat statement still verbatim: YES/NO
    - Q1=B confirmed: /healthz on both ports? YES/NO
    - Any unresolved issues for next-round audit
    - Operator follow-ups (still needs: M1 signing key, MINORs
      m1-m3 if not addressed)

13. Do NOT commit. Operator commits all changes as one
    coordinated commit covering the union of integration fixes.

## What NOT to do

- Do NOT modify SPEC-001/002/003. They're locked. The C1 fix
  ALIGNS Go to the existing spec; it doesn't change the spec.
- Do NOT inspect d-inference source.
- Do NOT change buyer-facing HTTP API surface (existing endpoints
  unchanged; C2 ADDS one).
- Do NOT introduce new dependencies (Go or Swift).
- Do NOT touch M1 signing-key placeholder (operator follow-up;
  documented in install.sh comments).
- Do NOT commit. Operator commits.

When done, print the 500-word handback summary and stop.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist:

1. `git diff --stat` — confirm changes spread across Stream A
   (Swift), Stream B (Go), Stream C (shell) as expected.
2. Backward-compat statement at SPEC-001 v1.2.1 lines 20-38
   STILL VERBATIM (this fix didn't touch specs).
3. `go test ./...` + `swift test` + `bash -n install.sh` all clean.
4. M4 cross-stream NAK test passes with real Swift NAK payload.
5. /v1/pool/check works against a mockprovider locally.
6. install.sh + uninstall.sh both use `~/.local/bin/macprovider-cli`.
7. /healthz served on both buyer port (8443) AND provider port
   (8444).

Then commit. Suggested message:

```
fix(integration): apply cross-model audit findings — Codex + Claude

Resolves 3 CRITICAL + 8 MAJOR + Q1=B from
specs/INTEGRATION-audit.md (Codex round 1) and
specs/INTEGRATION-audit-claude.md (Claude round 2).

CRITICAL:
  C1  Go NAK parser aligned to SPEC-001 nested error.code shape;
      v1.1.x backward-compat fallback now functional
  C2  new GET /v1/pool/check endpoint on buyer port; install.sh
      uses it for AC-1 check instead of grepping /v1/models
  C3  install path aligned to SPEC-003 FR-C2:
      ~/.local/bin/macprovider-cli; uninstall paths (shell + swift)
      reconciled

MAJOR:
  M2  HTTP 429 quota response includes Retry-After header
  M3  ParseHeartbeat now preserves all heartbeat fields
  M4  AC-15 NAK fallback test now uses real SPEC-001 wire shape
      (was masked by mock-only Go-struct format)
  M5  added Phase 3 preflight handler unit test
  M6  added Phase 3 drain handler unit test (composes with v1.1.4
      state-reset)
  M7  self-update graceful drain proven via test
  M8  uninstall.sh + macprovider-cli uninstall remove identical
      file sets

Q1=B (operator decision): /healthz mounted on buyer port too —
defense-in-depth against nginx config drift.

Backward-compat verified: SPEC-001 v1.2.1 lines 20-38 statement
verbatim, § 6.6 normative scope intact.

Operator follow-ups remain:
  M1 — replace placeholder signing key at install.sh:281
  m1-m4 — MINOR cleanup, opportunistic
```

After commit:
- (Optional) narrow regression check (~15-20 min) to verify
  fixes didn't introduce regressions
- Local integration test: start v1.1.2 coord + run v1.2 binary
  as provisional provider + buyer request → expect end-to-end
  success now that C1/C2 fixed
- Then deploy v1.1.2 coord to Pearl VPS
