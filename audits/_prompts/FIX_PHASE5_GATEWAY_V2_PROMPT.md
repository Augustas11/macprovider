# Fix prompt — phase5-gateway regression closing (1 MAJOR + 1 MINOR)

Operator-paste prompt to close the 2 regression findings from
`specs/PHASE5_GATEWAY_AUDIT_V2.md` (commit 54cef18). Tiny narrow
patch on top of the prior FIX cycle (commit 7783256).

The MAJOR is the load-bearing one: F-M2 / AC-37 STILL doesn't prove
the normative streaming cancel path despite the prior FIX session's
update. The prior FIX traded one shortcut for another. This FIX
must either land the REAL normative path OR honestly downgrade
AC-37 to PARTIAL.

The MINOR is mechanical: reaper interval config.

Run in **Claude Code** (cross-model alternation: Codex did round 1 +
regression; Claude does this FIX). Expected duration: ~45-60 min
(the cancel-flow real test is the bulk of the work).

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Claude Code session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are closing 2 narrow regression findings from
`specs/PHASE5_GATEWAY_AUDIT_V2.md`. The MAJOR (regression M1) is
that AC-37 / F-M2 still does not prove the normative streaming
cancel path; the prior FIX session shifted from one shortcut
(synthetic pre-stream header) to another (cancel HTTP response)
without landing the real spec contract.

You will edit files in `phase5-gateway/` and update `docs/AC_STATUS.md`
honestly. SPEC-001 / SPEC-002 / SPEC-003 / SPEC-006 stay UNTOUCHED.

## The normative cancel path (read this first)

Per SPEC-001 v1.2.3 § 6.6 + SPEC-006 v0.5 § 7.2 + D-CROSS-1:

1. Buyer sends streaming `POST /v1/chat/completions` with
   `stream: true`. Gateway forwards to coordinator → provider via
   WS-tunneled inference (per SPEC-001 v1.2.x § 6.6 message types).
2. Provider streams `inference_response_chunk` messages back via
   the WS tunnel. Gateway relays them to buyer as SSE chunks per
   OpenAI format `data: {...}\n\n`.
3. Buyer disconnects mid-stream (client side).
4. Gateway detects buyer disconnect and sends `cancel_request`
   (per SPEC-001 § 6.6) to coordinator → provider via the same WS
   tunnel. This is a control-plane message, NOT an HTTP request.
5. Provider (v1.2.4+) honors the cancel and emits a final
   `inference_response_end` message via the SAME WS tunnel, carrying
   `usage` with prompt_tokens + actual completion_tokens generated
   before cancel was honored.
6. Gateway receives the inference_response_end (as part of the
   open WS stream, NOT as a separate HTTP response), settles the
   daily-quota reservation to actual usage.

For pre-v1.2.4 providers (M4, M1 if not upgraded — though both
ARE upgraded now), inference_response_end may OMIT `usage`.
Gateway falls back to `ceil(bytes_emitted_so_far / 4)` estimation
per D-CROSS-1.

**Critical insight:** the cancel-response usage arrives via the
OPEN inference stream, NOT as a separate HTTP response. There is
NO `/v1/chat/completions/cancel` HTTP endpoint in the spec; the
prior FIX session invented one. The real path uses the existing
WS tunnel.

## Critical constraints

**1. SPEC-001 v1.2.4 + SPEC-002 v1.1.5 + SPEC-003 v0.7 + SPEC-006
v0.6 stay UNTOUCHED.** Verify with `git diff specs/` after — empty.

**2. Operator pre-commitments preserved.** D1, D2, D3,
D-CROSS-1..6 unchanged.

**3. AC-37 honesty.** Either:
   (a) Land the REAL normative cancel path: gateway sends
       cancel_request via WS tunnel; mock coordinator emits
       inference_response_end with usage via the same stream;
       gateway settles to actual; OR
   (b) DOWNGRADE AC-37 from PASS to PARTIAL in `docs/AC_STATUS.md`
       with honest gap: "Real WS-tunneled inference_response_end
       carrying usage on cancel not implemented in v1; gateway
       relies on byte-estimation fallback for ALL disconnects
       until coordinator integration adds the cancel-response
       relay."

Choice (a) is preferred. Choice (b) is acceptable only if (a)
requires coordinator-side changes that exceed this FIX's scope
(in which case file a coordinator-side follow-up).

**4. Reaper config.** Add `quota.reaper_interval_hours` to
gateway.yaml (default 1) and `quota.reservation_max_age_hours`
(default 24). Wire through to the reaper goroutine.

**5. Surgical scope.** ~80-150 LoC of patches total.

## Required reading

1. `specs/PHASE5_GATEWAY_AUDIT_V2.md` — the regression report.

2. `specs/SPEC-001-phase3-binary.md` v1.2.4 § 6.6 — the
   normative inference_response_end + cancel_request message
   semantics. Read CAREFULLY — this is the contract the test
   must verify.

3. `specs/SPEC-006-buyer-api.md` v0.6 § 7.2 + § 17.5 — the
   gateway-side prefer-actuals + fallback rules + refund matrix.

4. `phase5-gateway/internal/router/server.go` — the streaming
   handler + cancel path. Look at what the prior FIX produced
   (it added a /cancel HTTP shortcut); your fix replaces it with
   the WS-tunneled cancel_request flow.

5. `phase5-gateway/internal/router/server_test.go` +
   `integration_test.go` — the AC-37 test. It currently uses
   the cancel HTTP response shortcut.

6. `phase5-gateway/cmd/gateway/main.go` — the reservation reaper
   goroutine. The interval is hardcoded; needs config.

7. `phase5-gateway/internal/config/config.go` — config schema;
   add the new quota fields.

8. `phase5-gateway/gateway.yaml.example` — document the new
   config fields.

## Findings to fix

### Regression M1 (MAJOR) — AC-37 streaming cancel-usage normative path.

**Location:** `phase5-gateway/internal/router/server.go` streaming
cancel path + `server_test.go` / `integration_test.go` AC-37 test
+ `docs/AC_STATUS.md`.

**Fix path A (preferred):** Implement the real WS-tunneled cancel
flow.

1. Replace the /v1/chat/completions/cancel HTTP shortcut with the
   real flow: when buyer disconnects mid-stream, gateway sends a
   cancel_request control message to coordinator via the existing
   request channel (WS-tunneled).

2. Gateway then listens on the SAME inference response channel
   for a final `inference_response_end` message carrying `usage`.
   Bounded wait (e.g., 2s); if the message doesn't arrive, fall
   back to byte-estimation per D-CROSS-1.

3. Update the test (`TestStreamingQuotaSettlementOnCancelUsesActuals`
   or similar — pick a clear name):
   - Mock coordinator that, on receiving cancel_request, emits
     inference_response_end on the same response channel with
     usage={prompt_tokens: N, completion_tokens: M, total_tokens: N+M}
   - Buyer test client streams a request, receives some chunks,
     disconnects mid-stream
   - Assert gateway settles daily quota to N+M (exact actual)

4. Add a second test variant for the estimation fallback:
   - Mock coordinator that times out on cancel_request (does NOT
     emit inference_response_end with usage)
   - Assert gateway falls back to ceil(bytes_emitted/4) estimation
   - Document tolerance: estimation result within ±5 tokens of
     real generated count

5. **Update `docs/AC_STATUS.md`** AC-37 entry: replace whatever
   test name is currently cited with the new real-flow test
   name(s). PASS retention is honest because the test now exercises
   the spec contract.

6. Remove the /v1/chat/completions/cancel HTTP shortcut endpoint
   if it was added in the prior FIX (it's not in the spec).

**Fix path B (fallback if A is blocked by coordinator-side
changes):** Honestly downgrade AC-37.

1. Update `docs/AC_STATUS.md` AC-37 entry:
   - Status: PARTIAL (was PASS)
   - Evidence/gap: "Real WS-tunneled inference_response_end carrying
     usage on cancel requires coordinator-side relay implementation
     not present in v1. Gateway tests verify the byte-estimation
     fallback path per D-CROSS-1; the actuals path is structurally
     unreachable from gateway integration tests until coordinator
     supports cancel-response-with-usage forwarding."

2. File coordinator-side follow-up in implementation-notes.html as
   a known gap.

3. Update streaming code: when buyer disconnects mid-stream,
   gateway sends cancel_request to coord (existing path) but does
   NOT wait for inference_response_end; immediately settles via
   byte-estimation. Document this is the v1 behavior.

You choose A or B based on what you find in the coordinator's
existing surface. If coord already supports the cancel-response
relay (check `phase4-coordinator/internal/ws/server.go` for the
cancel_request handler + inference_response_end forwarding), do A.
If not, do B and file the follow-up.

### Regression m1 (MINOR) — Reaper interval configurable.

**Location:** `phase5-gateway/cmd/gateway/main.go` +
`phase5-gateway/internal/config/config.go` +
`phase5-gateway/gateway.yaml.example`.

**Fix:**

1. Add to `internal/config/config.go` `QuotaConfig` struct (or
   similar):
   ```go
   ReaperIntervalHours          uint `yaml:"reaper_interval_hours" default:"1"`
   ReservationMaxAgeHours       uint `yaml:"reservation_max_age_hours" default:"24"`
   ```

2. Validate at startup: `ReaperIntervalHours` MUST be >= 1.
   `ReservationMaxAgeHours` MUST be >= 2 (sanity floor; a 1h max
   age would conflict with the reaper interval).

3. Update `runReservationReaper` in `cmd/gateway/main.go` to use
   the configured values rather than hardcoded.

4. Document in `gateway.yaml.example`:
   ```yaml
   quota:
     reaper_interval_hours: 1
     reservation_max_age_hours: 24
   ```

5. Add a quick test that startup fails with bad values
   (`reaper_interval_hours: 0` should reject; verify error message
   is clear).

## Output requirements

1. `phase5-gateway/internal/router/server.go` updated for
   regression M1 path A (preferred): real WS-tunneled cancel flow
   replaces /cancel HTTP shortcut. OR path B: gateway sends
   cancel_request but doesn't wait for inference_response_end;
   byte-estimation path documented as v1 limitation.

2. `phase5-gateway/internal/router/server_test.go` +
   `integration_test.go` updated. Path A: 2 new test functions
   (actuals path + estimation fallback). Path B: existing test
   stays but is renamed to clarify it tests estimation, NOT
   actuals.

3. `phase5-gateway/docs/AC_STATUS.md` updated for AC-37: path A
   keeps PASS with new test names; path B downgrades to PARTIAL
   with honest gap.

4. `phase5-gateway/internal/config/config.go` gains
   `QuotaConfig.ReaperIntervalHours` +
   `QuotaConfig.ReservationMaxAgeHours`.

5. `phase5-gateway/cmd/gateway/main.go` reaper uses configured
   values.

6. `phase5-gateway/gateway.yaml.example` documents the new
   config fields.

7. `phase5-gateway/dist/deploy-pearl-vps.md` mentions the
   reaper config in the deployment notes (one line).

## Verification

Run locally:
```bash
cd phase5-gateway
go vet ./...
go build ./...
go test ./...
```

All MUST pass.

If path B chosen, also update implementation-notes.html with the
coordinator-side follow-up reference.

## Self-verification checklist

- [ ] Regression M1: path A or path B chosen + executed.
- [ ] If path A: cancel test exercises real WS-tunneled
      inference_response_end carrying usage. NO /cancel HTTP
      endpoint exists.
- [ ] If path B: AC-37 honestly downgraded to PARTIAL with
      coordinator-side follow-up filed.
- [ ] Regression m1: reaper config added + validated +
      documented in example yaml.
- [ ] SPEC-001/002/003/006 untouched (empty `git diff specs/`).
- [ ] Operator pre-commitments D1, D2, D3, D-CROSS-1..6 preserved.
- [ ] go vet/build/test all green.
- [ ] AC_STATUS.md AC-37 evidence is honest (PASS with real test
      OR PARTIAL with honest gap; no hand-wavy retention).

When done, print a 150-word handback summary:
- Path A or B chosen + why
- New test names (if A)
- Whether AC-37 stays PASS or moves to PARTIAL
- Reaper config defaults + validation behavior
- Whether gateway is now READY FOR PEARL DEPLOYMENT DRY-RUN

Then stop. Operator decides next: Pearl deployment, or one more
narrow regression check.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~10 min):

1. `git diff phase5-gateway/internal/router/server.go` — verify the
   cancel path matches the chosen approach (A: real WS flow; B:
   immediate byte-estimation).
2. `git diff phase5-gateway/docs/AC_STATUS.md` AC-37 — verify
   evidence is honest (path A: real test name; path B: PARTIAL
   downgrade with honest gap).
3. `git diff specs/` — should be empty.
4. Run `cd phase5-gateway && go test ./...` to confirm green.

Then commit + push. Two reasonable next moves:

| Option | When it's right |
|--------|-----------------|
| Pearl deployment dry-run | Path A landed cleanly; gateway is honestly READY |
| One more Claude pass on the FULL gateway (NOT just the FIX delta) | Want cross-model coverage on the whole gateway code, not just the patches; ~60-90 min |

Given Codex has done 3 rounds (initial audit + this regression + this FIX would be its 3rd touch), and Claude has done 0 rounds on the gateway, an optional Claude full-gateway pass would close the cross-model coverage gap. That's ~60-90 min for full gateway audit, comparable to the original Codex round 1.

Whether that's worth doing depends on operator risk preference. Day-5 close has plenty of evidence in either direction.
