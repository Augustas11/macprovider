# Fix prompt — phase5-gateway audit closing (1 CRITICAL + 8 MAJOR + 2 MINOR)

Operator-paste prompt to close all 11 findings from the Codex code audit
at `specs/PHASE5_GATEWAY_AUDIT.md` (commit 20f0880). Single coordinated
FIX session BEFORE Pearl deployment.

The CRITICAL (F-C1) is the load-bearing Tier 1 disclosure block from
SPEC-006 v0.6 § 5 — the audit-response commit message claimed it
landed, but Codex verified the code path does not actually emit it.
Production deployment is blocked until F-C1 closes.

F-M2 has a special honesty implication: AC-37 was reported PASS but
the test uses a synthetic pre-stream header, not the real cancel flow.
The FIX session MUST update `docs/AC_STATUS.md` to reflect the
corrected status after the fix lands.

Run in **Claude Code** or **Codex CLI**. Expected duration: ~90-120 min
(11 narrow findings, mostly localized fixes; test updates for F-M2
require more care).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are closing all 11 findings from the Codex code audit at
`specs/PHASE5_GATEWAY_AUDIT.md`. The audit walked the
phase5-gateway implementation (commit 4955cce) against the locked
spec corpus (SPEC-001 v1.2.4 + SPEC-002 v1.1.5 + SPEC-003 v0.7 +
SPEC-006 v0.6) and produced 1 CRITICAL + 8 MAJOR + 2 MINOR findings.
Verdict was READY WITH NARROW FIX PASS.

You will edit files in `phase5-gateway/` and update `docs/AC_STATUS.md`
to reflect the corrected status after fixes land. SPEC-001 / SPEC-002
/ SPEC-003 / SPEC-006 stay UNTOUCHED (verify with `git diff specs/`
after).

## Critical constraints

**1. Spec is locked.** Do NOT propose architectural changes. If a
fix requires a SPEC patch (it shouldn't here, but verify), STOP and
file as a follow-up.

**2. SPEC-001 v1.2.4 + SPEC-002 v1.1.5 + SPEC-003 v0.7 + SPEC-006
v0.6 stay untouched.** Verify with `git diff specs/` after — should
be empty.

**3. Locked operator pre-commitments are read-only:** D1, D2, D3,
D-CROSS-1 through D-CROSS-6. Each finding's fix MUST preserve them.

**4. AC_STATUS.md honesty.** If a fix changes an AC's status
(e.g., F-M2 fix turns AC-37 from synthetic-PASS to real-PASS), the
AC_STATUS entry MUST be updated with the new evidence. If a fix
reveals an AC was actually PARTIAL pretending to be PASS, the AC
MUST be re-graded to PARTIAL with honest gap notes.

**5. d-inference clean-room.** Do not inspect d-inference source.

**6. Surgical scope.** 11 findings; ~150-200 LoC of patches total.
If your edits exceed ~400 added lines, stop and re-check scope.

**7. No live testing.** Pearl deployment + live OAuth + live SDK
smoke remain operator-side post-FIX work.

## Required reading

1. `specs/PHASE5_GATEWAY_AUDIT.md` — the audit report. Every fix
   starts from a specific F-* finding's location + description.

2. `specs/SPEC-006-buyer-api.md` v0.6 — focus on:
   - § 1.6 (Tier 1 disclosure properties; the disclosure surface)
   - § 5.X tier1_disclosure block schema (the F-C1 spec contract)
   - § 17 (failure modes, error envelopes — for F-M7)

3. `specs/SPEC-002-coordinator.md` v1.1.5 — focus on:
   - § 7.5 FR-B1 (degraded definition for F-M3)
   - § 7.X PG-2 (proxy rate-limit invariants for F-M6)
   - nginx routing block

4. `specs/SPEC-001-phase3-binary.md` v1.2.3 — focus on:
   - § 6.6 cancel-usage normative (the real contract F-M2 must
     test against)

5. `phase5-gateway/internal/router/server.go` — the main handler
   surface. Focus on:
   - /v1/models handler (F-C1)
   - OAuth callback handler (F-M1)
   - Streaming cancel path (F-M2)
   - Status / degraded computation (F-M3)
   - X-Forwarded-For handling (F-M5)
   - Error envelope handling (F-M7)
   - X-Request-ID validation (F-M8)
   - Panic recovery middleware (F-m1)

6. `phase5-gateway/internal/router/server_test.go` +
   `phase5-gateway/internal/router/integration_test.go` — the tests
   to update for F-M2 (real cancel flow vs synthetic header).

7. `phase5-gateway/internal/storage/sqlite/store.go` — the quota
   reservation logic for F-M4 (reaper).

8. `phase5-gateway/dist/nginx-api.streamvc.live.conf` — for F-M6
   (PG-2 rate limits + connection caps).

9. `phase5-gateway/docs/AC_STATUS.md` — to update post-fix status.

## Findings to fix — by severity

### CRITICAL

**F-C1 — Tier 1 disclosure block on /v1/models.**

**Location:** `phase5-gateway/internal/router/server.go` /v1/models
handler.

**Problem:** SPEC-006 v0.6 § 5.X normatively requires the
`/v1/models` response to include a top-level `tier1_disclosure`
field with 4 properties (`plaintext_to_provider`,
`model_identity`, `hardware_attestation`, `tier2_milestone`) per
§ 1.6. The audit-response commit message claimed this landed,
but the code path does not emit it. Buyers consuming `/v1/models`
do not see the disclosure → expectation-drift class active.

**Fix:**

1. Locate the `/v1/models` handler. After it constructs the
   response from coordinator data (per § 5.5 forwarded models +
   provider_count + total_slots), wrap it to include
   `tier1_disclosure`:

```go
type tier1Disclosure struct {
    Version              string `json:"version"`
    PlaintextToProvider  bool   `json:"plaintext_to_provider"`
    ModelIdentity        string `json:"model_identity"`
    HardwareAttestation  string `json:"hardware_attestation"`
    Tier2Milestone       string `json:"tier2_milestone"`
}

func (s *Server) makeTier1Disclosure() tier1Disclosure {
    return tier1Disclosure{
        Version:             "v0.6",
        PlaintextToProvider: true,
        ModelIdentity:       "provider_reported",
        HardwareAttestation: "none",
        Tier2Milestone:      "future",
    }
}
```

2. The 4 property values are HARDCODED constants — non-overridable
   by config, env, or operator action. Add a unit test that asserts
   these values cannot be changed via any config path.

3. Update the response schema. The `/v1/models` JSON response now
   includes a top-level `tier1_disclosure` field.

4. Add an AC test:
   `TestModelsResponseIncludesTier1Disclosure` — fetches `/v1/models`,
   asserts the block is present, asserts all 4 properties match
   the hardcoded values exactly.

5. **Update `docs/AC_STATUS.md`** AC-13 entry. If AC-13 is already
   PASS, add the new test name. If AC-13 doesn't currently cover
   this, expand it or add a new AC entry referencing § 5.X.

### MAJOR

**F-M1 — OAuth callback redirect_uri handling.**

**Location:** `phase5-gateway/internal/auth/oauth.go`.

**Problem:** Handler requires a `redirect_uri` query parameter,
but GitHub's OAuth callback does NOT include `redirect_uri` in
the callback redirect. GitHub validates the redirect URL on its
end via the registered app config; the callback only sends `code`
and `state`.

**Fix:**

1. Remove the `redirect_uri` requirement from the callback handler.
2. The strict callback allowlist enforcement happens via the
   OAuth app's registered callback URL (verified server-side at
   GitHub) — the gateway code does NOT need to re-verify
   `redirect_uri` since GitHub guarantees it.
3. Keep the state parameter validation (CSRF defense per AC-29).
4. Update `TestOAuthCallbackAllowlist` to reflect the corrected
   contract: the test should verify allowlist enforcement HAPPENS
   at OAuth-app-config time (or via a documented startup check
   against `gateway.yaml`'s callback URL list), NOT via callback
   query param.

If the test was passing only because it was sending a synthetic
`redirect_uri` (similar to F-M2's synthetic header pattern), the
AC needs honest re-grading.

**Update `docs/AC_STATUS.md`** AC-4 + AC-26 if they're affected.

**F-M2 — Streaming cancel-usage contract.**

**Location:** `phase5-gateway/internal/router/server.go` streaming
path + `server_test.go` / `integration_test.go` for AC-37.

**Problem:** Per SPEC-006 v0.5 § 7.2 + SPEC-001 v1.2.3 § 6.6:
- For streaming, gateway reserves `max_tokens` against quota
- On client disconnect mid-stream:
  - If provider's `inference_response_end` includes `usage`
    (v1.2.4+ provider), settle to exact actual
  - Else (pre-v1.2.4), fall back to `ceil(bytes_emitted_so_far / 4)`

The current implementation only handles the synthetic-header path
where the provider's pre-stream header announces usage. The real
cancel flow (gateway sends cancel_request → provider responds with
inference_response_end carrying usage) is NOT implemented. AC-37
"passes" because the test uses the synthetic header.

**Fix:**

1. Implement the real cancel path in the streaming handler:
   - On client disconnect, send `cancel_request` to coordinator
   - Wait (bounded, ~500ms) for `inference_response_end` from
     provider via coordinator
   - If response carries `usage`, settle to actual prompt +
     completion
   - If response is timeout/empty, fall back to byte-estimation
     per D-CROSS-1

2. Update `TestStreamingQuotaReservationAndSettlement` (AC-37) to
   exercise the real path:
   - Mock coordinator that receives cancel_request and replies
     with `inference_response_end` carrying `usage`
   - Assert settlement matches actual usage from response (not
     synthetic header)
   - Add a second test variant exercising the fallback path:
     mock coordinator that times out / returns no `usage`,
     gateway falls back to byte-estimation

3. **Update `docs/AC_STATUS.md`** AC-37: replace synthetic-test
   reference with real-flow test name. If real flow can't fully
   land in this FIX cycle, downgrade AC-37 to PARTIAL with
   explicit gap (don't keep PASS).

**F-M3 — degraded calculation matches FR-B1.**

**Location:** `phase5-gateway/internal/router/server.go` status
or model-aggregation code.

**Problem:** SPEC-002 v1.1.4 § 7.5 FR-B1 normatively defines
`degraded` per model: TRUE if ANY of (all providers
unavailable/draining, <50% ready, all slots_free=0). The
gateway's current calculation diverges from this.

**Fix:** Update the degraded computation to exactly match FR-B1:

```go
func (s *Server) computeDegraded(modelStats poolzModelStats) bool {
    if modelStats.TotalProviders == 0 {
        return true
    }
    if modelStats.UnavailableOrDraining == modelStats.TotalProviders {
        return true
    }
    if (2 * modelStats.Ready) < modelStats.TotalProviders {
        return true
    }
    if modelStats.SlotsFreeTotal == 0 {
        return true
    }
    return false
}
```

Add `TestDegradedCalculationMatchesFRB1` with all 4 trigger cases +
the negative case. Update AC-13 / AC-32 evidence cross-reference.

**F-M4 — Quota reservation reaper.**

**Location:** `phase5-gateway/internal/storage/sqlite/store.go`.

**Problem:** SPEC-006 v0.5 § 7.2 notes: "Failed reservations expire
and are reclaimed by a reaper job within 24h." Code does not
implement the reaper, so abandoned reservations (gateway crash
mid-request, coordinator timeout, etc.) accumulate forever and
slowly overshoot the daily quota.

**Fix:**

1. Add a reservation column tracking `created_at` and `state`
   (`reserved` / `settled` / `expired`).
2. Add a background goroutine in `cmd/gateway/main.go` (or
   storage layer) that periodically (every 1h) reaps reservations
   older than 24h that haven't settled.
3. Add `TestExpiredReservationsReclaimedAfter24h` exercising the
   reaper logic.
4. Document the reaper behavior in `README.md`.

**F-M5 — XFF trust when X-Real-IP absent.**

**Location:** `phase5-gateway/internal/router/server.go` IP
detection middleware.

**Problem:** Per audit A.8 + nginx config F-M6: the nginx config
must overwrite `X-Forwarded-For`, and gateway code must trust the
nginx-set value (not the buyer-controlled raw XFF). Current code
falls back to trusting raw XFF if `X-Real-IP` is absent — buyer
can spoof their IP.

**Fix:**

1. Update IP detection: ONLY trust `X-Real-IP` (set by nginx).
   If absent, fall back to `RemoteAddr` (TCP source), NOT to XFF.
2. Add `TestClientIPDetectionRejectsForgedXFF` exercising the
   scenarios: real X-Real-IP set → use it; X-Real-IP absent +
   buyer-XFF present → use RemoteAddr; X-Real-IP absent + no XFF
   → use RemoteAddr.
3. Document in README that the gateway MUST be deployed behind
   nginx with the XFF overwrite + X-Real-IP set, or operator
   accepts the consequence (no XFF trust at all).

**F-M6 — nginx /ws/provider rate-limit + connection-cap.**

**Location:** `phase5-gateway/dist/nginx-api.streamvc.live.conf`.

**Problem:** SPEC-002 v1.1.5 § 7.X PG-2 normatively requires
nginx `limit_req_zone` + `limit_conn_zone` directives applied to
`/ws/provider` BEFORE the WS upgrade reaches coordinator.
Current nginx config does not include these directives.

**Fix:** Add the directives at the top of the nginx config and
apply them to the `/ws/provider` location block:

```nginx
limit_req_zone $binary_remote_addr zone=ws_provider_rate:10m rate=10r/m;
limit_conn_zone $binary_remote_addr zone=ws_provider_conn:10m;

# ... existing config ...

location /ws/provider {
    limit_req zone=ws_provider_rate burst=5 nodelay;
    limit_conn ws_provider_conn 5;
    proxy_pass http://127.0.0.1:8444;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_read_timeout 86400;
}
```

Document in `dist/deploy-pearl-vps.md` that these directives are
required for production launch per SPEC-002 v1.1.5 PG-2 invariant.

**F-M7 — Unknown routes + nginx-denied use OpenAI error envelope.**

**Location:** `phase5-gateway/internal/router/server.go` 404
handler + `dist/nginx-api.streamvc.live.conf` 404 responses.

**Problem:** SPEC-006 v0.5 § 5.2 requires all errors to use the
OpenAI envelope. Current 404 responses for unknown routes return
plain text or default `404 Not Found`. nginx-denied (`/admin/`,
`/v1/pool/check`) returns plain nginx 404 HTML.

**Fix:**

1. In `server.go`, install a fallback NotFound handler that
   returns:
   ```json
   {"error": {"message": "Not Found", "type": "invalid_request_error", "code": "not_found"}}
   ```
   with HTTP 404.

2. In nginx config, replace the `return 404` for `/admin/` and
   `/v1/pool/check` with `return 404 '{"error":{"message":"Not Found","type":"invalid_request_error","code":"not_found"}}';`
   plus `default_type application/json;`.

3. Add `TestNotFoundReturnsOpenAIEnvelope` and verify nginx config
   manually.

**F-M8 — X-Request-ID v4 validation.**

**Location:** `phase5-gateway/internal/router/server.go`
X-Request-ID middleware.

**Problem:** D-CROSS-3 mandates UUID v4 specifically. Current
validation accepts any UUID-shaped string including v1/v3/v5.
Affects correlation log uniqueness assumptions.

**Fix:**

1. Update the regex/parser to validate UUID v4 specifically
   (the version nibble is `4` at position 14, and the variant
   nibble is `8`/`9`/`a`/`b` at position 19).
2. If inbound `X-Request-ID` is malformed, generate a fresh v4
   on gateway side (don't reject the request).
3. Add `TestXRequestIDValidationRejectsNonV4` for v1/v3/v5
   shapes.

### MINOR

**F-m1 — Panic recovery logs the panic.**

**Location:** `phase5-gateway/internal/router/server.go` panic
recovery middleware.

**Fix:** Inside the recover block, log the panic value + stack
trace at ERROR level before returning the envelope. Add
`TestPanicRecoveryLogsPanicAndReturnsEnvelope`.

**F-m2 — Gateway-local health probe.**

**Location:** `phase5-gateway/internal/router/server.go` (new
endpoint).

**Fix:** Add `GET /healthz` returning JSON `{"status":"ok"}` with
200 status. Returns 503 if DB is unreachable (do a SELECT 1).
Used by systemd / load-balancer health probes. Mention in nginx
config — don't strip it. Add `TestHealthzReturnsOK` +
`TestHealthzReturns503WhenDBUnreachable`.

## Test verification AFTER fixes

Run locally and report results:

```bash
cd phase5-gateway
go vet ./...
go build ./...
go test ./...
go test ./internal/storage/... -cover
go run ./cmd/gateway -config gateway.yaml.example -check
```

All MUST pass before declaring done.

## docs/AC_STATUS.md updates

For each AC whose evidence changes, update the entry:

- AC-13 status: if degraded calculation is now correct, add F-M3
  test name.
- AC-37 status: if real cancel path is now tested, replace
  synthetic-header reference with real-flow test name. If real
  path can't fully land, DOWNGRADE to PARTIAL with honest gap.
- AC-26 / AC-4: if OAuth callback fix changes the auth test
  evidence, update.
- Add new AC entries (or extend existing) for new tests:
  `TestModelsResponseIncludesTier1Disclosure`,
  `TestClientIPDetectionRejectsForgedXFF`,
  `TestNotFoundReturnsOpenAIEnvelope`,
  `TestExpiredReservationsReclaimedAfter24h`,
  `TestXRequestIDValidationRejectsNonV4`,
  `TestPanicRecoveryLogsPanicAndReturnsEnvelope`,
  `TestHealthzReturnsOK`.

Total expected AC_STATUS changes: ~10-15 line updates.

## Self-verification checklist

- [ ] F-C1: `/v1/models` response includes `tier1_disclosure`
      block with 4 hardcoded properties; non-overridable.
- [ ] F-M1: OAuth callback no longer requires unsent
      `redirect_uri` query param; tests reflect corrected contract.
- [ ] F-M2: streaming cancel path uses real cancel_request flow;
      AC-37 evidence updated to real-flow test OR honestly
      downgraded.
- [ ] F-M3: degraded calculation matches SPEC-002 v1.1.4 FR-B1
      exactly; test asserts all 4 trigger cases.
- [ ] F-M4: quota reservation reaper implemented; test verifies
      24h expiration reclaim.
- [ ] F-M5: IP detection rejects forged XFF; only trusts X-Real-IP
      or RemoteAddr.
- [ ] F-M6: nginx config includes limit_req_zone + limit_conn_zone
      applied to /ws/provider per PG-2.
- [ ] F-M7: unknown routes + nginx-denied routes return OpenAI
      envelope.
- [ ] F-M8: X-Request-ID validation enforces v4 specifically;
      malformed inbound IDs replaced with fresh v4.
- [ ] F-m1: panic recovery logs panic value + stack trace.
- [ ] F-m2: /healthz endpoint exists, returns 200 or 503 based on
      DB health.
- [ ] AC_STATUS.md updated honestly: no PASS claim is hand-wavy.
- [ ] SPEC-001/002/003/006 untouched (empty `git diff specs/`).
- [ ] go vet/build/test all clean.

When done, print a 200-word handback summary:
- Findings closed (11/11)
- AC_STATUS changes made (which ACs upgraded/downgraded/added)
- Total LoC added
- Whether `go test ./...` is green
- Whether the gateway is now READY FOR PEARL DEPLOYMENT DRY-RUN
  (zero remaining CRITICAL, zero remaining blocking MAJOR)

Then stop. Operator decides next: proceed to Pearl deployment OR
one more narrow regression check.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~30 min):

1. `git diff phase5-gateway/` — verify each F-* finding has a
   corresponding code change.
2. `git diff phase5-gateway/docs/AC_STATUS.md` — verify ACs are
   honestly updated; no hand-wavy PASS retentions.
3. `git diff specs/` — should be empty.
4. Run the gateway test suite locally: `go test ./...` MUST be
   green.
5. Quick spot-check on F-C1: temporarily start gateway with
   `gateway -config gateway.yaml.example`, curl `/v1/models`,
   verify `tier1_disclosure` block in response.

Then commit + push. After landing:

- **Pearl deployment dry-run** unblocks (no remaining CRITICAL or
  blocking MAJOR).
- If you want belt-and-suspenders: optional Claude single-round
  regression on the FIX, ~30-45 min. Historical pattern says it
  surfaces 1-3 narrow MINORs at most.

## Why this audit cycle was high-value

Codex cross-model independence caught:
- The disclosure block (Category E from the audit prompt) — the
  audit-response commit message claimed it landed; Codex verified
  it didn't.
- F-M2 streaming cancel test using synthetic header — AC-37 was
  PASS-by-shortcut.
- Eight more MAJORs the embedded Claude audit missed.

The pattern from Entry 24 lesson 5 (external audit as normative
pre-launch gate) just paid off again. Without this Codex pass,
F-C1 alone would have shipped to production with the disclosure
language in the SPEC but not on the wire — exactly the
"expectation drift" the external security audit warned about.
