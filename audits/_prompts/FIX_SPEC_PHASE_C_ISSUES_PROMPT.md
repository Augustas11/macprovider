# Fix Prompt — Phase C Stress-Test Issues (gateway quota + nginx hardening)

Self-contained Codex prompt. No prior session context required.
Root at `/Users/augstar/macprovider-poc`.

---

## Background

A 5-minute, 100-concurrent stress test (`phase5-gateway`) against Pearl VPS surfaced
two gateway bugs and one nginx gap. This prompt fixes all three. Read this file in
full before making any changes.

---

## Bug 1 — Quota reservation leak on request timeout / client disconnect

### What was observed

After a 5-minute wrk run (100 concurrent, invalid model, 59 socket timeouts), the
buyer account showed `reserved=40,960` tokens (exactly 10 × 4,096) that never
cleared — confirmed by `/v1/usage` 10 seconds after wrk exited. The daily-window
reset at UTC midnight cleared them. Reservation leaks under sustained load will
gradually exhaust buyer quota without any provider earning tokens.

### Root cause

`store.ReserveQuota` (file: `phase5-gateway/internal/storage/sqlite/store.go`,
function starting at line 353) ends with:

```go
return decision, tx.Commit()   // line 393
```

If the HTTP request context (`r.Context()`) is cancelled by the client **between**
the successful SQLite `INSERT` and `tx.Commit()` returning to Go — a race at the
commit boundary — SQLite commits the reservation row but Go returns an error. The
caller in `handleChatCompletions` (file:
`phase5-gateway/internal/router/server.go`) at lines 1119–1121:

```go
if err != nil {
    writeError(w, http.StatusInternalServerError, "server_error", "quota_reservation_failed", "Could not reserve quota")
    return
}
```

…returns HTTP 500 **without calling `RefundReservation`**, so the committed row
stays `status='active'` indefinitely (until the daily-window expiry reaps it).

### Fix required

In `phase5-gateway/internal/router/server.go`, replace lines 1119–1121 with:

```go
if err != nil {
    // Defensive cleanup: if the reservation INSERT committed before the
    // context was cancelled (commit-boundary race), this unwinds it.
    // If no row was written, RefundReservation is a safe no-op
    // (returns ErrReservationNotFound which we ignore here).
    _ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
    // If the error is a client disconnect, avoid writing a response to a
    // dead connection — the buyer already gave up.
    if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
        return
    }
    writeError(w, http.StatusInternalServerError, "server_error", "quota_reservation_failed", "Could not reserve quota")
    return
}
```

No changes to `store.go` are required for this fix.

### Test requirement

Add a test in `phase5-gateway/internal/router/server_test.go` named
`TestQuotaReservationLeakOnContextCancel`. Use the existing test harness pattern
(look at how other handler tests create a `*Server` with a fake `Store`). The test
must:

1. Inject a fake `Store.ReserveQuota` that:
   - Simulates the commit-boundary race: returns `(admitted decision, context.Canceled)`
     while a side-channel records that a reservation row **was** written.
2. Inject a fake `Store.RefundReservation` that records it was called.
3. Make a POST to `/v1/chat/completions` with a cancelled context.
4. Assert:
   - `RefundReservation` was called exactly once (the defensive cleanup fired).
   - HTTP status is NOT 500 (when the context is cancelled, the handler returns
     without writing a response; assert the `ResponseRecorder` status is either
     0/200 — whatever the zero value is for an unwritten recorder — or that no
     `quota_reservation_failed` body was written).

**Fix-stash-test verification is required**: after writing the test, confirm it
FAILS against the pre-fix code (with the original lines 1119–1121 restored via
`git stash`), then PASSES after the fix is re-applied (`git stash pop`). Record
the exact failure diagnostic in a comment above the test function.

---

## Bug 2 — HTTP 500 on quota exhaustion instead of 429

### What was observed

When the daily quota was near-exhausted, the gateway returned:

```
HTTP 500  {"error":{"code":"quota_reservation_failed","message":"Could not reserve
quota","type":"server_error"}}
```

63 instances during Phase C. The correct response when a buyer has no remaining
daily tokens is HTTP 429 `quota_exhausted`, not 500 `server_error`.

### Root cause

`store.ReserveQuota` (store.go lines 374–378) correctly returns
`storage.ErrQuotaExceeded` when `req.RequestedTokens > remaining`:

```go
if req.RequestedTokens > remaining {
    if err := tx.Commit(); err != nil {
        return storage.QuotaDecision{}, err   // ← this path
    }
    return decision, storage.ErrQuotaExceeded
}
```

If `tx.Commit()` in the rejection path itself fails (e.g. because the context
is cancelled at that exact moment), the function returns a non-nil, non-ErrQuotaExceeded
error. The caller's `errors.Is(err, storage.ErrQuotaExceeded)` check at server.go
line 1114 misses it and falls through to the generic 500 path.

### Fix required

In `phase5-gateway/internal/storage/sqlite/store.go`, in `ReserveQuota`, replace
the rejection commit block (lines 374–378):

```go
if req.RequestedTokens > remaining {
    if err := tx.Commit(); err != nil {
        return storage.QuotaDecision{}, err
    }
    return decision, storage.ErrQuotaExceeded
}
```

with:

```go
if req.RequestedTokens > remaining {
    _ = tx.Rollback() // read-only path; rollback is equivalent to commit here
    return decision, storage.ErrQuotaExceeded
}
```

Rationale: the rejection path performed no writes — it only read usage totals and
then returned early. Rolling back instead of committing is semantically identical
(no rows to commit) and eliminates the commit-error escape hatch that bypassed the
`ErrQuotaExceeded` return.

Also add a guard in the caller (`server.go`) after the `errors.Is(err,
storage.ErrQuotaExceeded)` block (currently lines 1114–1117) to catch the case
where `err != nil` AND the decision shows the account was over-quota anyway (belt
and suspenders):

```go
// Belt-and-suspenders: if the store returned an unexpected error but the
// decision already shows quota exceeded, surface 429 rather than 500.
if err != nil && decision.RemainingTokens == 0 && decision.LimitTokens > 0 {
    setRateLimitHeaders(w, decision.LimitTokens, decision.RemainingTokens, decision.ResetUnix)
    writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "quota_exhausted", "Quota exhausted")
    return
}
```

Insert this block immediately after the `ErrQuotaExceeded` block, before the
generic `if err != nil` block (which becomes the fallthrough for true server
errors).

### Test requirement

Add a test in `server_test.go` named `TestQuotaExhaustedReturns429Not500` that:

1. Injects a fake `Store.ReserveQuota` that returns
   `(QuotaDecision{LimitTokens: 1000, UsedTokens: 1000, RemainingTokens: 0},
   someOpaqueError)` — simulating the commit-error escape hatch.
2. Posts to `/v1/chat/completions`.
3. Asserts HTTP status is 429, body contains `"quota_exhausted"`, NOT 500.

Fix-stash-test verification required (same pattern as Bug 1 test above).

---

## Gap 3 — nginx `/v1/` buyer path has no connection limit (slow-loris gap)

### What was observed

Phase B probe B4: 20 concurrent connections to `https://api.malibu.tech/v1/usage`
all completed with HTTP 401 (no auth). Zero nginx `limit_conn` events. The existing
`limit_conn ws_provider_conn 5` in the nginx config protects only the
`/ws/provider` WebSocket endpoint. The buyer-facing `/v1/` path is unprotected —
an attacker can open unlimited slow-loris connections.

### Fix required

Edit `/etc/nginx/sites-available/api.malibu.tech` on Pearl VPS
(`159.223.165.194`). The local copy tracked in the repo is at:
`phase4-coordinator/dist/deploy-pearl-vps.sh` (which templates the nginx config
inline). **Both the live file on Pearl AND the repo template must be updated.**

At the top of the `api.malibu.tech` vhost file, alongside the existing
`limit_conn_zone` and `limit_req_zone` directives, add:

```nginx
limit_conn_zone $binary_remote_addr zone=buyer_conn:10m;
```

Inside the `location /v1/` block, add:

```nginx
limit_conn buyer_conn 20;
limit_conn_status 429;
```

The threshold of 20 concurrent connections per IP is conservative enough to block
slow-loris (typical attacker opens hundreds) while never affecting a legitimate
buyer (even high-volume API users rarely hold >5 persistent connections). After
adding the directives, run `nginx -t` to verify syntax, then `systemctl reload nginx`.

**Also update** the local repo copy of the nginx config wherever it is templated.
Confirm the repo file location by running:

```bash
grep -r "location /v1/" /Users/augstar/macprovider-poc --include="*.conf" --include="*.sh" --include="*.nginx" -l
```

### No unit test required for nginx config

Deploy verification: after applying the change, run from Pearl loopback:

```bash
ab -n 30 -c 25 -H 'Authorization: Bearer invalid' https://api.malibu.tech/v1/usage
```

Confirm that connections beyond 20 receive HTTP 429, and that `grep 'limiting connections' /var/log/nginx/error.log` shows events. Record the ab output.

---

## Commit and deploy protocol

1. **Gateway fixes first** (Bugs 1 + 2): implement, write tests, fix-stash-verify.
2. **Cross-compile** the gateway for `linux/amd64`:
   ```bash
   cd phase5-gateway
   GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o dist/gateway-linux-amd64 ./cmd/gateway
   ```
3. **Deploy** to Pearl using the established in-place swap pattern:
   ```bash
   # Check git identity first
   gh auth status   # must show Augustas11 active, or run: gh auth switch -u Augustas11
   # Deploy
   ssh -i ~/.ssh/pearl_operator_ed25519 root@159.223.165.194 "
     systemctl stop macprovider-gateway
     cp /opt/macprovider/dist/gateway-linux-amd64 /opt/macprovider/gateway
     systemctl start macprovider-gateway
     systemctl is-active macprovider-gateway
   "
   ```
4. **Nginx fix**: apply the config change to Pearl, run `nginx -t`, `systemctl reload nginx`.
5. **Smoke-test** immediately after deploy:
   - `curl -sf https://api.malibu.tech/healthz` → 200
   - `curl -sf -H 'Authorization: Bearer <buyer_key>' https://api.malibu.tech/v1/usage` → 200 with quota JSON
   - `curl -sf -H 'Authorization: Bearer bad' https://api.malibu.tech/v1/usage` → 401
6. **Commit** (from repo root, Augustas11 account):
   ```
   git add phase5-gateway/... phase4-coordinator/dist/...
   git commit -m "Fix quota reservation leak, 500-on-quota-exhausted, and nginx limit_conn gap

   Bug 1: add defensive RefundReservation + context-cancel guard in handleChatCompletions
   Bug 2: eliminate commit-error escape hatch in ReserveQuota rejection path; add
          belt-and-suspenders 429 guard in caller
   Gap 3: add limit_conn buyer_conn 20 to nginx /v1/ location

   Surfaced by Phase C deep stress test (Entry 37). Re-run Phase C after this
   ships to confirm quota delta = 0 and no 500s under sustained load.

   Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>"
   git push origin main
   gh auth switch -u antfleet-ops
   ```

---

## What NOT to do

- Do NOT change `SPEC-006` or any spec file — these are code-only fixes.
- Do NOT flip any routing config flags (pillar A/B/C/D stay as-is in `coordinator.yaml`).
- Do NOT modify `store.RefundReservation` itself — only its call sites change.
- Do NOT touch the coordinator binary or its config.
- Do NOT touch `air5`, `air8gb`, or any provider config.
- Do NOT add new endpoint routes, new config fields, or new SQLite migrations.

---

## When done, signal for Phase C re-run

Once all three fixes are deployed and smoke-tested, reply with:

```
FIX_PHASE_C_COMPLETE: gateway sha=<first 8 chars of new binary sha256>, nginx reloaded=yes
```

The next session will immediately re-run Phase C: 100 concurrent, 5 min, invalid
model, targeting quota delta = 0 and zero status=500 `quota_reservation_failed`.
