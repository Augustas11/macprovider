# SPEC-017 v0.1.8 — Final Pre-Merge Adversarial Review (claude-subagent)

Branch: `impl/spec-017-step-1`
HEAD: `9ef3d92`
Reviewer: independent claude-subagent (adversarial lens)
Date: 2026-06-26

## Verdict

**REQUEST CHANGES.**

Lock bar (0 CRITICAL + 0 HIGH + 0 MEDIUM) is not satisfied. One HIGH severity bug (304 CORS omission) is a concrete spec compliance failure that breaks browser-side conditional GET against the leaderboard surface; one MEDIUM finding (`burst=59 nodelay` vs. locked SPEC §5.6 "no `burst=` parameter") is a documented SPEC↔IMPL drift the implementer rationalized in code comments but never updated in the SPEC.

`Blocking count: 0 CRITICAL / 1 HIGH / 2 MEDIUM / 2 LOW / 3 INFO`

---

## Method

I focused the budget on attack surfaces that the parallel codex audits are LEAST likely to have probed deeply:

1. **CORS+304 interaction.** The SPEC §5.7 CORS table doesn't carve out 304 responses. I read `writeJSON` in `handlers.go:691-707` to verify whether the conditional GET path emits the same CORS headers as the 200 path.
2. **`burst=59 nodelay` vs. SPEC §5.6 text.** I read SPEC §5.6 (lines 1103-1175) and the implemented nginx config side-by-side to argue both interpretations.
3. **§6.6.2 sign-off non-bypassability.** Verified whether the convergence record's "wired and non-bypassable" language matches the actual `partnerkeys.go` code path.
4. **requestObs concurrency.** Traced the pointer-in-context pattern across `middleware.go` ↔ `auth.go` ↔ `mux.go` to confirm the documented happens-before guarantee holds.
5. **AC sampling.** Spot-checked AC-12, AC-14, AC-18, AC-22 against their cited tests. AC-12 has a path-name discrepancy worth flagging.
6. **Rate-limit refund TOCTOU.** Verified the deferred refund cannot decrement a slot that was never reserved.
7. **Cache write-suppression on partner-projection 401/429 paths.** Verified `proxy_no_cache $http_authorization` semantics.
8. **Public security-headers coverage on 200 responses.** Read all four `location` blocks in `nginx-stats.malibu.tech.conf`.

Roughly 28 tool calls. I did not deeply re-audit the rollup pipeline, migrations, or partner-key CLI internals — codex lanes have spent multiple rounds on those.

---

## Findings

### [HIGH] 304 Not Modified path omits `Access-Control-Allow-Origin`

**Evidence:** `phase4-coordinator/internal/stats/handlers.go:699-706`

```go
if ifNoneMatchEquals(r.Header.Get("If-None-Match"), etag) {
    // 304 carries only RFC 7232 headers per §5.9. No body,
    // no X-Stats-Generated-At.
    w.Header().Set("ETag", etag)
    w.Header().Set("Cache-Control", cacheControl)
    w.Header().Set("Vary", vary)
    w.WriteHeader(http.StatusNotModified)
    return
}
```

The non-304 branch at `handlers.go:714` calls `writeCORSHeaders(...)`, which emits `Access-Control-Allow-Origin: *` (public) or echoes the Origin (partner). The 304 branch emits NEITHER.

**Why it matters:** Per SPEC §5.7 row 1/2 (public) and row 3/5 (partner-Origin-present), `Access-Control-Allow-Origin` is REQUIRED on every leaderboard response — there is no 304 carve-out in the table. A browser issuing a conditional GET with `If-None-Match` against `/v1/stats/leaderboard` from `https://console.malibu.tech` will receive a 304 without `Access-Control-Allow-Origin`, and the Fetch spec REQUIRES that header on the response (even 304) for the browser to accept it cross-origin. The browser will report a CORS error to the JS caller even though the response is functionally correct. This breaks conditional GET for every browser-side consumer (console.malibu.tech, portal.malibu.tech, third-party partner dashboards).

**Test coverage gap:** `TestAC12_304IfNoneMatch` (handlers_integration_test.go:345-367) does not set an `Origin` header and does not assert `Access-Control-Allow-Origin`. The bug is invisible to the AC suite.

**Fix direction:** Move the `writeCORSHeaders(w, ar.projection == "partner", ar.originPresent, ar.originValue)` call up so it fires before BOTH the 304 branch and the 200/HEAD branch. Add a test that conditional GET with `Origin: https://example.com` produces 304 carrying `Access-Control-Allow-Origin: *` (public projection) and echoes Origin for the partner projection.

**Severity rationale:** HIGH because it is a concrete SPEC violation (§5.7 CORS table omits no 304 carve-out) that silently breaks the documented partner integration path, AND because it would have been caught by an AC-12 with `Origin` set. Not CRITICAL because no data leak — just functional CORS failure.

---

### [MEDIUM] `burst=59 nodelay` deviates from locked SPEC §5.6 "no `burst=` parameter"

**Evidence:**

- `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:110, 138, 161`: `limit_req zone=stats_overview burst=59 nodelay;` (and same on /leaderboard and /health).
- `specs/SPEC-017-network-stats-api.md:1118-1119` (SPEC §5.6 v0.1.8 reconciliation):
  > "AC-8 is now mechanically achievable with `limit_req zone=<name> nodelay;` (no `burst=` parameter) on the public-tier location."
- `specs/SPEC-017-network-stats-api.md:1113`:
  > "The public tier is a hard 60 req/min per IP per endpoint with no burst absorption"

**Why it matters:** The SPEC §5.6 v0.1.8 explicitly drops the `burst=` parameter as a "reconciliation with AC-8." The implementation puts it BACK with `burst=59`, justified in nginx-stats.malibu.tech.conf:20-29 by the argument that with `rate=60r/m` and an initially-empty leaky bucket, `nodelay` alone admits only 1 request before refill, failing AC-8's "60 succeed" assertion. The implementer is mechanically correct about nginx semantics — and the SPEC author appears to have been wrong about what `nodelay` does alone. But the locked SPEC text and the shipped nginx config now disagree.

**Defensible interpretation (implementer's):** `1 in-rate token + 59 burst = 60 immediate, then strict 1/sec refill = 60/min sustained`. This delivers AC-8's wire behavior without amplifying long-term throughput.

**Indefensible interpretation (strict-SPEC reader):** The SPEC text says "no burst absorption" and "no `burst=` parameter"; the impl carries `burst=59`. Either the SPEC needs an erratum acknowledging the mechanical reality, or the impl needs to find a different way to admit 60 immediate (e.g. rate=60r/s, which would actually amplify long-term throughput far beyond 60/min and is worse).

**Fix direction:** Patch SPEC §5.6 to acknowledge that `burst=N-1 nodelay` is the only mechanically correct way to admit N immediate requests and reject the N+1th — and pin `N=60` to match AC-8. Otherwise the SPEC text is internally inconsistent and a future implementer rewriting from scratch will land back here. The current nginx config is operationally correct; the issue is documentary.

**Severity rationale:** MEDIUM because the IMPL is correct in spirit (AC-8 passes, no rate amplification) but breaks the contract that the locked SPEC is the source of truth. The convergence narrative claims `0M` but a docs-vs-impl drift this material should not ship without an erratum.

---

### [MEDIUM] AC-12 cited test exercises `/leaderboard`, not the SPEC-named `/overview`

**Evidence:**

- SPEC AC-12 text (`specs/SPEC-017-network-stats-api.md:2269-2271`):
  > "A request to `/v1/stats/overview` with `If-None-Match`..."
- Cited test (`internal/stats/handlers_integration_test.go:345-367`): `TestAC12_304IfNoneMatch` issues `GET /v1/stats/leaderboard` (line 347), not `/overview`.

**Why it matters:** The 22-AC sweep (`specs/SPEC-017-IMPL-STEP_4-22AC-sweep.md:42`) cites this test as PASS proof for AC-12. The SPEC explicitly names `/overview`. If the bug exists in the overview handler but not the leaderboard handler (or vice versa — and the HIGH finding above suggests it does exist on both), the cited test would not detect it. Both endpoints route through `writeJSON`, so the bug surface is shared — but the test honesty claim is broken regardless.

**Fix direction:** Add `TestAC12_304IfNoneMatch_Overview` exercising the actual SPEC-named path, OR amend the SPEC AC-12 text to read "any cacheable `/v1/stats/*` endpoint". The sweep claim of PASS is unsubstantiated as written.

**Severity rationale:** MEDIUM because it's a test-honesty drift on a SPEC-named acceptance criterion. The convergence record's "22/22 PASS" claim has at least one AC whose cited proof does not address what the SPEC asks.

---

### [LOW] Successful 200 stats responses lack `X-Content-Type-Options` / `X-Frame-Options` / `Referrer-Policy`

**Evidence:** `phase4-coordinator/dist/nginx-stats.malibu.tech.conf:107-178`. All three `location =` blocks (`/v1/stats/overview`, `/v1/stats/leaderboard`, `/v1/stats/health`) do NOT include `stats-security-headers.conf`. Only the `@stats_rate_limited` named location (line 100) includes it.

Server-level `add_header` directives are absent (lines 57-105). Therefore 200 responses inherit no security headers from this vhost.

**Why it matters:** Defense-in-depth headers help suppress MIME sniffing, clickjacking, and referrer leakage. For JSON responses with `Content-Type: application/json` the practical impact is minimal (no rendered content, no embed surface). Stats endpoints are public read-only JSON.

**Fix direction:** Add `include /etc/nginx/conf.d/stats-security-headers.conf;` at server-level (line 78 area, before any location-level `add_header`), so the snippet's `always` parameter applies it to every response including 200. The nginx-add-header inheritance trap notes in MEMORY.md (`nginx-add-header-inheritance-trap`) confirm this pattern is already understood by the codebase.

**Severity rationale:** LOW because impact on JSON-only endpoints is minimal; the convergence record claims security headers are wired but the wire only covers the 429 named-location path.

---

### [LOW] Auth-flooded `/overview` with bogus `Authorization` header bypasses nginx public limiter and reaches the freshness probe DB read before in-process Layer 6 caps

**Evidence:**

- `dist/nginx-snippets/stats-shared.conf:24-27` (the keyed-bypass map): any non-empty `Authorization` value drops the public-tier nginx limiter (key="").
- `mux.go:97-177`: only `endpoint == "leaderboard"` runs the auth-failure tier (300 rpm/IP). `/overview` and `/health` synthesize a public authResult without going through that tier.
- `mux.go:181-190`: the overview stale probe runs (one DB read) BEFORE Layer 6 (public 60 rpm in-process bucket).

**Why it matters:** An attacker spraying `GET /v1/stats/overview` with `Authorization: anything` bypasses the nginx 60 rpm limit AND bypasses the auth-failure tier entirely (because it's leaderboard-only). They land at the in-process 60 rpm Layer 6, but ONLY after every request runs the freshness probe SELECT. The probe is cheap (single SELECT against `stats_components_health` for component `overview`), so this is bounded — but a sufficiently determined attacker controlling multiple IPs amplifies cheap DB queries through this path.

**Fix direction:** Either (a) plumb the auth-failure tier across all three endpoints (currently leaderboard-only), or (b) re-order mux.go so the public 60 rpm bucket fires before the overview freshness probe. Option (b) is the smaller patch.

**Severity rationale:** LOW because per-tick DB load amplification is bounded by Layer 6 within the same IP; multi-IP amplification is the realistic vector and is also bounded by the freshness query cost (low). INFO-adjacent.

---

### [INFO] §6.6.2 sign-off gate is operational, NOT code-enforced

**Evidence:**

- `phase4-coordinator/cmd/coordinator/partnerkeys.go:165-350` (`runPartnerKeysIssue`): contains NO check against any sign-off table, file, env var, or YAML setting. Once an operator has the admin DSN, the INSERT proceeds.
- Convergence record (`specs/SPEC-017-IMPL-STEP_4-convergence.md:27-28`): "the gate is wired and non-bypassable."

**Why it matters:** The convergence narrative's "non-bypassable" wording is misleading if read as a code-level guarantee. The actual gate is a procedural one (OPS.md §10.5 sign-off template) and an operator with the admin DSN can bypass it by typing the command. SPEC §6.6.2 itself only requires that the operator runbook record the sign-off — it does not mandate code-level enforcement, so this is technically SPEC-compliant. But the convergence wording should be tightened to "wired at the runbook layer; the binary itself does not enforce the gate."

**Fix direction (non-blocking):** Reword the convergence note to "operationally enforced via OPS.md §10.5 + DECISION_CRITERIA.md sign-off; the binary does not block the INSERT." This is documentary only.

---

### [INFO] AC-22 test uses constant `mpk_invalid` token; SPEC says `mpk_invalid_<random>`

**Evidence:**

- SPEC AC-22 text (`specs/SPEC-017-network-stats-api.md:2326-2329`): "each carrying `Authorization: Bearer mpk_invalid_<random>`".
- Test (`internal/stats/handlers_integration_test.go:464`): `hdr.Set("Authorization", "Bearer mpk_invalid")` — single constant token.

**Why it matters:** The SPEC asks for randomized tokens to defeat any incidental token-caching the implementation might add. The current Store does no caching (`LookupPartnerKeyByHash` is a direct SELECT every call), so the test passes mechanically. But a future regression that adds a per-token cache would not be caught by the AC-22 test — it would mask the bug.

**Fix direction (non-blocking):** Patch the test to use `fmt.Sprintf("Bearer mpk_invalid_%d", i)` inside the loop so the SELECT count assertion remains meaningful against any future caching layer.

---

### [INFO] Convergence claim "22/22 PASS" rests on at least one cited test that does not match its SPEC AC text

See MEDIUM finding above on AC-12. The sweep document (`specs/SPEC-017-IMPL-STEP_4-22AC-sweep.md`) cites tests as PASS proof per-AC, but at least AC-12 cites a `/leaderboard` test against a SPEC AC that says `/overview`. A more careful sweep would either run BOTH endpoint variants through the AC harness or amend the SPEC.

---

## What I tried to refute but couldn't

These are concrete attack hypotheses I tested AGAINST the implementation and was unable to land:

1. **`requestObs` happens-before race.** I hypothesized that the dispatcher's `r = r.WithContext(...)` in mux.go:153 would attach a new context that the outer access-log middleware in middleware.go:188-189 wouldn't see. Result: the implementation is correct. `accessLogMiddleware` (middleware.go:176) stores a `*requestObs` POINTER in the request context BEFORE `next.ServeHTTP`; the dispatcher's `WithContext`-chained request carries the SAME pointer in its context tree; both code paths read the same `*requestObs` object. The dispatcher writes to `obs.PartnerKeyID` (mux.go:161); the access-log reads it (middleware.go:189). Single-threaded per request, no race, no missed write. The comments at auth.go:66-78 explain this exactly. PASS.

2. **Partner-projection `$` leak via 429/401 cache hit.** I hypothesized that an auth-failure 429 (which gets `Cache-Control: public, max-age=60` because the partner-projection marker hasn't been set yet) might persist a partner-relevant response in the nginx `stats_public` cache. Result: defeated by `proxy_no_cache $http_authorization` (nginx-stats.malibu.tech.conf:130, 154, 177). Any request carrying ANY Authorization header — including auth-failed 429s — has nginx suppress the cache write. Partner-tier 200s also can't leak because they carry `Cache-Control: private` AND get write-suppressed AND have `Vary: ... Authorization` for any downstream shared cache.

3. **Rate-limit refund decrementing on the 429 path.** I hypothesized that the deferred refund in mux.go:225-241 might fire on the `!allowed` 429 path and decrement a slot that was never reserved. Result: the `if !allowed { writeError(...); return }` at mux.go:220-224 occurs BEFORE the `defer func()` registration at line 225. The defer only registers in the `allowed=true` branch. No spurious refund.

4. **§6.6.2 EXACT-USD leak through panic path.** I hypothesized that the recover middleware (middleware.go:87-141) might log the panic value (which could carry partner-projection EXACT-USD substrings if the panic happened during JSON marshaling). Result: middleware.go:129-132 logs only `Type()` of the recovered value plus the stack trace to a Debug-only sink — not the panic value's string form. The public log line (lines 119-123) emits only `event=stats_handler_panic`, `route`, `request_id`. The recover middleware also defensively re-redacts `Authorization`, `Cookie`, `X-Api-Key` (lines 97-103) so any panic-introduced reference to those headers is sanitized. AC-15 invariant holds.

5. **AC-22 limiter ordering.** I hypothesized that the auth-failure 300 rpm limiter might fire AFTER the dispatcher's sha256+SELECT, defeating the "≤300 SELECTs" assertion. Result: mux.go:104-124 reserves the auth-failure slot BEFORE `dispatchAuth` runs (mux.go:129). The test `TestAC22_AuthFailureLimiter` (handlers_integration_test.go:444-487) asserts `LookupHashCountForTest() ≤ 300` and passes. Ordering is correct.

6. **Origin-bypass timing side-channel on AC-18.** I hypothesized that the Origin allowlist check in auth.go:250-265 might short-circuit BEFORE the sha256+SELECT for row 5 (valid token + rejected Origin), creating a timing oracle. Result: auth.go:217 issues the sha256+SELECT unconditionally for ALL bearer-present paths; the Origin check at line 250 runs ONLY after the SELECT. AC-18's 3-way ±20% timing assertion is the runtime proof. PASS.

---

## Other observations beyond the immediate audit

**Strengths.**
- The pointer-in-context pattern for `requestObs` (auth.go:66-94) is unusual but well-commented and CORRECT. The comments explicitly call out the rationale (mutable struct via pointer so the outer access-log can read dispatcher updates even though the inner `r.WithContext` chain produces a new request value). This is exactly the kind of subtle invariant that audits should ratify.
- Defense-in-depth header redaction across BOTH `redactionContextMiddleware` AND `recoverMiddleware` is the right pattern for a security-sensitive surface. The audit-loop's round-1 SECURITY M2 addition of Cookie + X-Api-Key redaction is appreciated even though SPEC v0.1.8 only names Authorization.
- The auth-failure tier (300 rpm/IP/endpoint, pre-SELECT) closes the partner_keys DB-flood vector cleanly. The `LookupHashCountForTest` seam is an excellent test-honesty mechanism.
- The 8-round Step 3 and 5-round Step 4.C convergence trajectories show real adversarial pressure. The audit files (`SPEC-017-IMPL-STEP_4C-arch-r5-audit.md` et al.) document specific fixes per round rather than generic "looks good." That's healthy.

**Weaknesses / areas of concern.**
- **The "non-bypassable" rhetoric in the convergence narrative is louder than the code warrants.** §6.6.2's gate is a runbook gate; the binary does not block. That's SPEC-compliant but the convergence wording should be tightened.
- **AC tests sometimes substitute equivalent paths for SPEC-named ones.** AC-12 exercises `/leaderboard` for a SPEC clause that names `/overview`. AC-22 uses constant tokens for a SPEC that says randomized. Both are PASS in spirit but break the SPEC↔test correspondence the AC sweep relies on. Future regression cases might land in the AC's blind spot.
- **The 304+CORS bug suggests the AC suite is endpoint-oriented but not header-oriented.** AC-12 and AC-13 each test one header axis; the combined "conditional GET with Origin" axis is uncovered.
- **The `burst=59 nodelay` situation reveals that the SPEC author and the IMPL author understood nginx semantics differently.** This is a healthy lesson for future SPECs — when the SPEC text constrains an external tool's behavior, the SPEC should be validated against the tool's actual semantics before locking.
- **The Step 4.B nginx behavior smoke (`coordinator-nginx-integration` CI job) is properly gated into `ci-required` (ci.yml:357-363), but the script's docker-availability skip is inside the script body itself.** The CI job's `Verify docker daemon` step (ci.yml:208) catches missing docker, but the script's internal skip remains a defense-in-depth-only safety net. Worth a code comment confirming the layered approach.

---

## Final recommendation

**REQUEST CHANGES.** Fix the HIGH (304 CORS) before merge — it's a one-line patch (call `writeCORSHeaders` before the 304 branch in handlers.go:691) plus a test. The two MEDIUMs can ship if (a) the SPEC §5.6 text is amended with a `burst=59 nodelay` erratum and (b) the 22-AC sweep adds an `/overview`-targeted AC-12 variant — both can land in the same PR or a same-day follow-up. The LOWs and INFOs can defer to a tracking issue per the [[tracking-issue-scope-control]] pattern. The convergence narrative's "0 CRITICAL / 0 HIGH / 0 MEDIUM" claim is materially incorrect; the lock bar is not yet met.

The work is in excellent shape overall — the codex audit loop did real work — but a separate adversarial pass found two SPEC-compliance gaps the parallel codex lanes are likely to miss because they share the same review surface and may not exercise the conditional-GET+Origin axis. That's exactly the value-add this second lens is supposed to provide.
