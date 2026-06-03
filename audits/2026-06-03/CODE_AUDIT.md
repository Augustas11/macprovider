# Code Quality Audit

**Repository:** `macprovider-poc` — a P2P AI-inference marketplace settling real USDC across a Swift provider binary (untrusted contributor Macs), a Go coordinator (the trusted money authority), and a Go gateway (the internet edge).
**Date:** 2026-06-03

**Scope & methodology.** This audit covers the full source corpus across all three trust tiers: the Go coordinator (`phase4-coordinator`: billing/settlement, buyer API, WebSocket relay, tier-2 attestation, explorer/request-log, auth/config/pool/CLI), the Go gateway (`phase5-gateway`: router/HTTP edge, SQLite storage, auth/OAuth/keys), the Swift provider binary (`phase3-binary`: self-update, attestation, runtime/inference), and the web demo plus install/deploy/Python tooling. Each component was first reviewed by a dedicated agent for correctness, security, concurrency, and resource-management defects; every raw finding was then put through an adversarial verification pass that read the cited code at `file:line`, reproduced behavior where feasible, removed false positives, and assigned an evidence-backed `adjustedSeverity` (the severity used throughout this report). Findings that survived verification carry either a *confirmed* or *downgraded* verdict; the supporting evidence quoted under each finding is the verifier's, not the original reporter's. No new findings were introduced during synthesis — near-duplicates (notably the recurring non-constant-time bearer-token comparison) have been merged across components.

## Executive summary

The codebase is in solid shape for a money-moving early-network system: there are **zero critical findings**, no confirmed fund-loss or auth-bypass paths in production wiring, and the highest-value invariants (constant-time API-key checks, atomic binary swap, signature-gated self-update, billing enforcement reading un-joined single-table totals) are correctly implemented. The defects that remain cluster into a small number of recurring themes. The most serious is **incorrect billing/settlement classification on streaming paths**: a buyer who cancels mid-stream on the coordinator's raw-HTTP path is recorded as a *provider disconnect* and the honest provider is paid zero (coord-buyer), and on the gateway a truncated or oversized upstream SSE stream is silently settled as `outcome="ok"` and billed as a success (gw-router). A second cluster is **operator-facing data integrity**: an unauthenticated `X-Forwarded-For`-keyed rate limiter on the public coordinator endpoint is both bypassable and an unbounded-memory DoS (coord-buyer), and a SQL JOIN fan-out inflates per-buyer usage by an N×M cross-product on the gateway's operator dashboard (gw-storage). A third, lower-stakes but pervasive theme is **non-constant-time bearer-token comparison** for the operator/admin key, which recurs in at least five sites across both Go services while the correct primitive already exists in the same trees. The single most important thing to fix first is the gateway's unchecked `scanner.Err()` on the streaming settlement path (`phase5-gateway/internal/router/server.go:1475-1531`): it is operator/provider-triggerable, mis-settles failed inference as paid-and-successful with no log signal, and directly touches USDC.

## Severity overview

| Severity | Count |
|----------|------:|
| Critical | 0 |
| High     | 4 |
| Medium   | 6 |
| Low      | 35 |
| Info     | 17 |
| **Total** | **62** |

## Findings

### [HIGH] Gateway settles truncated/failed SSE streams as a successful, billed `ok` (scanner.Err never checked)

- **Component:** Gateway · Router/HTTP edge (gw-router)
- **File(s):** `phase5-gateway/internal/router/server.go:1475-1531` (cap at :1476; settlement branches :1518-1530)
- **Category:** correctness / money-settlement
- **What:** `forwardStreamingChat` reads the upstream SSE body with a `bufio.Scanner` capped at 1 MiB (`scanner.Buffer(make([]byte,0,64*1024), 1024*1024)`). After `for scanner.Scan()` exits, the code never calls `scanner.Err()`. The only post-loop discrimination is client-cancellation (`r.Context().Err()==context.Canceled`) vs. the success path. A `Scan()` that returns false due to `bufio.ErrTooLong` (a single SSE line >1 MiB) or any mid-stream read error (connection reset, `ErrUnexpectedEOF`) — without client cancellation — falls through to `settleRequest(..., "ok")`.
- **Impact:** Buyers are billed for, and shown, truncated/failed responses as if they completed normally; the failure is invisible (logged status 200, outcome `ok`). A provider emitting an oversized SSE line can deterministically trigger silent truncation. On a USDC-moving edge, mis-settling a failed stream as `ok` is a money-correctness and observability defect.
- **Evidence:** Verifier read `server.go:1475-1531` verbatim; grep for `scanner.Err` in the file returns no hits. `settleRequest` (`server.go:1599-1610`) builds a `storage.ReservationSettlement` with the given outcome and finalizes billing via `SettleReservation`/`SettleDemoReservation`, so a read-error stream is billed with `Outcome="ok"`. A clean EOF correctly yields `scanner.Err()==nil` and `ok` (acceptable); the real exposure is `ErrTooLong` and non-EOF read errors. Confirmed.
- **Recommendation:** After the scan loop, `if err := scanner.Err(); err != nil && !errors.Is(r.Context().Err(), context.Canceled)` → settle with `outcome="upstream_error"` (or a dedicated `stream_truncated`) and emit an error log line. Consider raising the per-line cap or switching to `bufio.Reader.ReadBytes('\n')` if legitimately large SSE lines must be supported. *(See also the matching coverage gap below.)*

### [HIGH] Raw-HTTP streaming path misclassifies buyer disconnect as a provider breaker fault (false fault + provider paid zero)

- **Component:** Coordinator · Buyer API (coord-buyer)
- **File(s):** `phase4-coordinator/internal/buyer/server.go:1664-1692` (esp. 1682-1691); guarded contrast paths at 1411-1413, 1559-1561, 1622-1624
- **Category:** correctness / billing
- **What:** In `forwardStreaming` (the non-WS, raw-HTTP SSE path), `attemptCtx` derives from `r.Context()` (1607-1611), so a buyer disconnect cancels the in-flight provider read. The non-EOF read-error branch (1686-1691) does **not** check `r.Context().Err()` before classifying: it unconditionally logs "provider disconnected during streaming", emits a buyer-facing SSE error, and tags the billing attempt `billing.FaultBreakerQualifying`. Every other forwarding path guards this exact case (WS streaming 1559-1561, WS non-streaming 1411-1413, non-streaming HTTP 1622-1624); this raw-HTTP path is the lone unguarded one.
- **Impact:** A buyer that cancels mid-stream (stop button / closed tab — routine and trivially triggered) is recorded as a provider disconnect, and the provider is paid **zero** for work actually performed.
- **Evidence:** Verified `attemptCtx = r.Context()` at 1607-1611; the EOF branch (1682) returns clean while the fall-through (1686-1691) returns `progressAttempt(..., billing.FaultBreakerQualifying)` with no context check. `billing/formula.go:112-114` short-circuits `FaultBreakerQualifying` rows to zero `GrossCredits`/`ProviderCredits`, so the provider earns nothing. **Correction to the original report:** this path sets only the request-log attempt's `FaultFlag` and does **not** call `s.recordBreakerFault`, so it does not directly trip the circuit breaker (unlike the WS paths at 1562/1573) — the "reputation poisoning / honest providers removed from pool" claim is overstated. Kept HIGH for the confirmed zero-pay + false-disconnect record on the trusted billing ledger. Confirmed.
- **Recommendation:** Mirror the WS paths: on the non-EOF read-error branch, `if r.Context().Err() != nil { return wsForwardCancelled, 0, progressAttempt("Buyer disconnected during streaming", billing.FaultNone) }` so a canceled buyer context is never attributed to the provider.

### [HIGH] Public `/v1/pool/check` rate-limiter is keyed on spoofable `X-Forwarded-For` and never evicts (rate-limit bypass + unbounded-memory DoS)

- **Component:** Coordinator · Buyer API (coord-buyer)
- **File(s):** `phase4-coordinator/internal/buyer/server.go:335` (route), 583-627 (handler/allow), 629-641 (`clientIP`), 72 (`poolCheckLast` field)
- **Category:** resource-leak / authz
- **What:** `/v1/pool/check` is registered on the **public** `Handler()` (335), unauthenticated. Its only protection is `allowPoolCheck` (617-627), which throttles to 1 req/sec per key using the `s.poolCheckLast` sync.Map. The key is `clientIP(r)` (629-641), which returns the first comma-segment of attacker-controlled `X-Forwarded-For` verbatim with no validation and no trusted-proxy gate. The map is only ever `.Store`'d — never `.Delete`/swept/TTL'd — so distinct spoofed keys accumulate forever; per-key bucketing means rotating the header both bypasses the limit and inserts a permanent entry per request.
- **Impact:** An unauthenticated attacker sending a unique `X-Forwarded-For` per request grows `poolCheckLast` without bound (coordinator OOM) while defeating the limiter, so each spoofed identity drives a full `pool.Snapshot()` scan (593).
- **Evidence:** Confirmed 335 registers `GET /v1/pool/check` on the public router (auth-bearing routes are on `InternalHandler()` 340-345); `poolCheckLast` appears at exactly 3 sites — field decl (72), `.Load` (620), `.Store` (625) — with no `.Delete`/`.Range`/`.LoadAndDelete`/janitor and no TTL. `clientIP` returns `strings.TrimSpace(forwarded[:i])` with zero validation, falling back to `RemoteAddr` only when the header is absent. Confirmed.
- **Recommendation:** (1) Do not trust `X-Forwarded-For` unless the request arrived through a known trusted proxy hop; key on `r.RemoteAddr` or a configured trusted-proxy depth. (2) Bound `poolCheckLast` via a background janitor / evict-on-read / fixed-size LRU.

### [HIGH] LEFT JOIN fan-out inflates per-buyer token usage/reserved totals in the operator explorer

- **Component:** Gateway · SQLite Storage (gw-storage)
- **File(s):** `phase5-gateway/internal/storage/sqlite/explorer.go:32-62` (aggregates 34-35; offending joins 42-45; `GROUP BY` 54)
- **Category:** logic-bug / operator data integrity
- **What:** `ExplorerListBuyers` computes `SUM(ue.total_tokens) AS used_tokens` (34) and `SUM(CASE WHEN qr.status='active' THEN qr.reserved_tokens ELSE 0 END) AS reserved_tokens` (35) while LEFT JOINing four tables: `account_identities` (42), `api_keys` (43), `usage_events` (44), `quota_reservations` (45), then grouping by account. Because `account_identities` and `api_keys` are independent one-to-many relations to the same account, every usage and reservation row is duplicated `(identities × api_keys)` times before `SUM` runs, multiplying both totals. `feedback_count`/`average_rating` (39-40) correctly avoid this with correlated subqueries; the two token SUMs do not.
- **Impact:** The operator buyer list shows wildly inflated daily tokens-used and tokens-reserved for any account with multiple identities or API keys (the common case after key rotation, which leaves multiple key rows) — e.g. 4× or higher phantom consumption. Operators making capacity, abuse, or kill-switch decisions off these numbers could throttle or block legitimate buyers on fabricated usage. **Enforcement is unaffected** (see Evidence), so this is reporting/visibility, not billing.
- **Evidence:** Textbook fan-out confirmed by reading `explorer.go`: two independent one-to-many joins on `account_id` (42-43) feed plain aggregates (34-35) collapsed by `GROUP BY a.account_id` (54). `last_request_id`/`active_concurrency`/`feedback_count`/`average_rating` all use subqueries — only the two token SUMs were left on the join path. The quota-enforcement path `dailyUsageTx` (`store.go:794-810`) runs two separate single-table queries with no joins, so enforcement reads correct totals. High (operator-facing, money-adjacent) but not critical. Confirmed.
- **Recommendation:** Compute `used_tokens`/`reserved_tokens` with window-scoped correlated subqueries (mirror the 39-40 pattern) and drop the `usage_events`/`quota_reservations` LEFT JOINs; keep the `account_identities`/`api_keys` joins only for email/key-status filters. Add a regression test seeding 2 identities + 2 keys + 1 usage row and asserting the SUM equals the single row's value.

### [MEDIUM] Operator/admin bearer token compared with non-constant-time string equality (gateway router, two sites)

- **Component:** Gateway · Router/HTTP edge (gw-router); **also affects** Gateway · Auth/Config (gw-auth-core), which describes the same two lines from the auth angle
- **File(s):** `phase5-gateway/internal/router/server.go:1932-1945` — `operatorAuthorized` (1933) and `shouldPersistInternalHeaderAudit` (1942)
- **Category:** authz / timing-side-channel
- **What:** Every admin/operator endpoint is authorized with `r.Header.Get("Authorization") == "Bearer "+s.cfg.Coordinator.OperatorKey`, and the same `==` is repeated at 1942. Go's string `==` short-circuits on the first differing byte. This gates the kill-switch, capacity-signal, capacity-tier/evaluate, feedback-summary, and (via `explorerAllowed`) all explorer handlers. `crypto/hmac.Equal` is already imported and used for demo tokens (`internal/auth/demo.go:53`).
- **Impact:** An attacker reaching the admin endpoints and measuring latency could attempt byte-at-a-time recovery of the operator key, which toggles the global kill switch, drives money-path capacity tiers, and exposes explorer buyer PII. The operator key is high-entropy and network jitter dominates the signal, so remote recovery is impractical — hence medium, not high — but the asset is high value and the fix is trivial.
- **Evidence:** Read `server.go:1932-1945` verbatim; both sites use plain `==`. Callers verified at `server.go:632/657/702/740` and `explorer.go:247` (gating six explorer handlers). `hmac.Equal` confirmed available (`demo.go:53`; `crypto/hmac` imported at `server.go:7`). This is the lone timing-vulnerable secret check in the package. Confirmed.
- **Recommendation:** Use `hmac.Equal([]byte(got), []byte("Bearer "+s.cfg.Coordinator.OperatorKey))` (or `subtle.ConstantTimeCompare`) at both 1933 and 1942; hashing both sides to fixed length first avoids leaking length. *(Part of the cross-cutting non-constant-time cluster — see roadmap batch.)*

### [MEDIUM] `request_log` has no retention/pruning — unbounded growth and indefinite buyer-IP (PII) retention

- **Component:** Coordinator · Explorer + RequestLog (coord-explorer)
- **File(s):** `phase4-coordinator/internal/requestlog/store.go:85-115` (migrate), 144-188 (insert); buyer_ip populated at `internal/buyer/server.go:841`
- **Category:** resource-leak / data-retention
- **What:** The store only ever INSERTs into `request_log`. A repo-wide search for `DELETE`/prune/retention/cleanup/expire/`VACUUM` against `request_log` returns nothing — no scheduled prune, row cap, or TTL. Every buyer chat-completion writes one row per attempt (`server.go:830 logRowWithBilling`), each storing `buyer_ip` (`buyerIP(r.RemoteAddr)`), pref/provider headers, model, and error text. On a production deployment the table grows for the life of the process and buyer IPs are retained indefinitely and readable via the operator API (`SessionDetail`).
- **Impact:** Coupled failures: unbounded disk/DB growth, and indefinite PII retention with no expiry.
- **Evidence:** Confirmed grep over `internal/` returns zero `request_log`-related retention hits (all matches are unrelated session/catalog/token expiry). `store.go` has exactly one write path; no `DELETE`/prune method exists. `buyer_ip TEXT NOT NULL DEFAULT ''` (100), populated at `server.go:841`, surfaced via `SessionDetail` (`store.go:65`). **Downgraded HIGH→MEDIUM:** SQLite single-file store with indexed `ts_utc`, explorer scans bounded by max-window enforcement + `LIMIT≤200` (degrades gradually, not catastrophically); on a tunneled/proxied coordinator `RemoteAddr` is often the proxy address, weakening the PII claim; no integrity/fund/availability break and no remote trigger beyond ordinary traffic. Confirmed.
- **Recommendation:** Add a retention job (`DELETE FROM request_log WHERE ts_utc < ?` on a configurable cutoff analogous to `ProvisionalRetentionDays`, then `wal_checkpoint`/incremental `VACUUM`). Separately, avoid persisting raw `buyer_ip` beyond a short window (truncate or hash).

### [MEDIUM] `mockprovider` double-closes `stopHB` channel → deterministic panic on drain/shutdown

- **Component:** Coordinator · Auth/Config/Pool/CMD (coord-core, test tooling)
- **File(s):** `phase4-coordinator/tools/mockprovider/main.go:303` (create), 363-385 (three close sites)
- **Category:** concurrency
- **What:** `stopHB` is closed from three unsynchronized sites: the signal-handler goroutine (367), the read-loop on ws read error (375), and the `handleInbound` drain shutdown closure (382). Closing an already-closed channel panics. On the coordinator-initiated drain path this is deterministic: the drain closure closes `stopHB` (382) and the conn; the for-loop's next `wsutil.ReadServerData` fails on the closed conn and closes `stopHB` a **second** time at 375 → panic. The SIGINT path has the same race.
- **Impact:** The mock provider panics during exactly the drain/failover sequence the AC stress tests exercise, producing flaky, hard-to-diagnose failures and crash output that masks the behavior under test. No production reachability (test tool only).
- **Evidence:** Confirmed the three close sites and the deterministic drain trace; grep for `recover`/`sync.Once` across the file returns no matches. `go build`/`go vet ./tools/mockprovider/` succeed (runtime bug). Kept MEDIUM — real and deterministic on the drain harness, confined to test tooling. Confirmed.
- **Recommendation:** Guard the close with a `sync.Once` (`var stopOnce sync.Once; stop := func(){ stopOnce.Do(func(){ close(stopHB) }) }`) called from all three sites; apply the same treatment to the `conn.Close()` races.

### [MEDIUM] IPv6 demo-client IP normalization misuses `net.IP`, emitting a malformed identifier for every IPv6 client

- **Component:** Gateway · Auth/Config (gw-auth-core)
- **File(s):** `phase5-gateway/internal/auth/demo.go:79-92`; consumed at `internal/router/server.go:607`
- **Category:** stdlib-misuse / data integrity
- **What:** `normalizeDemoIP` builds the IPv6 /64 prefix as `net.IP(ip[:8]).String() + "::/64"`. `ip[:8]` is an 8-byte slice; `net.IP.String()` only formats 4- or 16-byte slices, so it falls through to the stdlib's hex-with-leading-`?` debug fallback. The malformed value is embedded in the signed demo token (`DemoPayload.IP`), re-derived on every `Validate`, and used as the account identifier `accountID = "demo:" + payload.IP`, so it persists into quota/feedback/audit rows.
- **Impact:** Every IPv6 demo user gets a garbage, non-RFC IP identifier across token payloads, quota keys, feedback events, and audit logs, making IP-based audit/abuse correlation unreliable for the dominant address family. Because `String()` is deterministic, the token still round-trips and IP-binding still "works" — not a hard auth break, but corrupts operator-facing data.
- **Evidence:** Reproduced empirically by compiling the exact function: `2001:db8:1:2:3:4:5:6` → `"?20010db800010002::/64"`; `::1` → `"?0000000000000000::/64"`; `fe80::1` → `"?fe80000000000000::/64"`. IPv4 unaffected (`192.168.1.5` and `::ffff:192.168.1.5` both → `192.168.1.5`). Flow to `accountID` confirmed at `server.go:607`. Kept MEDIUM (data-quality/auditability, no auth bypass). Confirmed.
- **Recommendation:** Build the prefix correctly: `m := ip.To16(); copy(m[8:], make([]byte,8)); return (&net.IPNet{IP:m, Mask:net.CIDRMask(64,128)}).String()` (yields `2001:db8:1:2::/64`). Add table-driven tests for IPv4, IPv6, mapped-v4, and loopback. *(The absence of these tests is itself a low finding below.)*

### [MEDIUM] Validated request params `seed`/`presence_penalty`/`frequency_penalty`/`response_format` are silently ignored by the runtime

- **Component:** Provider Binary · Runtime/Inference (bin-runtime)
- **File(s):** `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:103-107, 157-161`; validated-but-unused fields in `ChatCompletionRequest.swift:11-14, 63-78, 249-257`
- **Category:** api-contract
- **What:** `ChatCompletionRequest.parse` fully validates `seed`, `presence_penalty`, `frequency_penalty`, and `response_format`, but `ModelRuntime` constructs `GenerateParameters` only with `maxTokens`/`temperature`/`topP`. So `seed` does not make generation deterministic, the penalties have no effect, and `response_format: json_object` is accepted (HTTP 200) yet output is never constrained to or post-validated as JSON.
- **Impact:** Buyers paying real USDC get responses that contradict the accepted request — non-deterministic output despite a fixed seed, ignored penalties, free-form text for a `json_object` request. A silent contract violation on a paid endpoint that can break clients depending on JSON mode or reproducibility. No crash, money-accounting error, or security breach — hence medium.
- **Evidence:** Parse-time validation of all four params confirmed (`ChatCompletionRequest.swift:63-78`, enum cases 249-257). `grep` for `seed`/`responseFormat` in `ModelRuntime.swift` returns 0. Both `GenerateParameters` constructions (103-107, 157-161) pass only `maxTokens`/`temperature`/`topP`; the only post-processing is `applyOutputFilters` (stop-token stripping), with no JSON enforcement. Confirmed.
- **Recommendation:** Either wire these into `GenerateParameters`/a JSON-mode post-validation step where MLX supports them, or reject the unsupported params at parse time with a clear 400 (non-default `seed`/penalties, `response_format=json_object`) instead of validate-then-ignore. At minimum, enforce/validate `json_object` output before returning it.

### [MEDIUM] Console dashboard interpolates server-controlled `/v1/status` into `innerHTML` under `unsafe-inline` CSP

- **Component:** Web Demo + Scripts (web-scripts)
- **File(s):** `frontdoor/console/index.html:1093` (sink), 781-786 (`fetchStatus`), 1086 (`ps.status`); `nginx-console.streamvc.live.conf:27` (CSP)
- **Category:** xss
- **What:** `renderDashboard` sets `row.innerHTML` from a template literal interpolating `val`. The Status row's `val` is `ps.status`, raw unsanitized JSON fetched from `/v1/status`. Every other dynamic value uses `textContent` or numeric coercion; this is the lone HTML sink. CSP is `script-src 'unsafe-inline'`, so an injected `<img onerror=…>` inline handler executes.
- **Impact:** If `/v1/status` is ever attacker-influenced (compromised/malicious upstream), JS runs in-origin and can read the `demo_token` and exfiltrate localStorage chat history. Requires a malicious upstream — hence medium, defense-in-depth.
- **Evidence:** Confirmed `index.html:1093` interpolates `${val}` into `innerHTML` with no escaping; `val = ps.status` (1086) where `ps = poolStatus` assigned raw from `await r.json()` of `/v1/status` (781-783). Numeric rows are coerced via `String(... || 0)`; model tags use `textContent`; only `val` is the vector. CSP `script-src 'unsafe-inline'` confirmed at `nginx-console.streamvc.live.conf:27`; `fetchStatus` re-fires every 30s. Confirmed.
- **Recommendation:** Render Status via `textContent`/`className`, HTML-escape `val`, and drop `unsafe-inline` from `script-src`.

### [LOW] Token revocation by 6-char prefix can revoke unrelated tokens and kick the wrong provider

- **Component:** Coordinator · Auth/Config/Pool/CMD (coord-core)
- **File(s):** `phase4-coordinator/internal/auth/tokens.go:75-82, 136, 186-204, 223-228`; CLI consumer `cmd/coordinator-cli/main.go:137`
- **Category:** correctness
- **What:** `token_prefix` is the first 6 hex chars (24 bits). The schema puts `UNIQUE` only on `token_hash`, not `token_prefix`, with no issuance dedup. `RevokeToken` runs `UPDATE … WHERE token_prefix=? AND revoked_at IS NULL`, revoking **every** active token sharing that prefix, and only checks `affected == 0` (never `affected > 1`). `tokenByPrefix` then returns a single row via `ORDER BY id DESC LIMIT 1`, which may describe a different token than the one(s) revoked.
- **Impact:** An operator revoking provider A's token can silently revoke provider B's still-valid token (availability/DoS + real money impact, since revocation kicks a paid provider), and the CLI's `revoke-and-kick` can blacklist whichever provider the `LIMIT 1` row happens to be. With a 24-bit space, birthday collisions become likely in the low thousands of issued tokens.
- **Evidence:** Every code claim verified (24-bit prefix, no prefix UNIQUE, `affected==0`-only check, `LIMIT 1` row, CLI consuming `record.ProviderID` at `main.go:137`). **Downgraded MEDIUM→LOW:** at this deployment's scale (a handful of providers) a 24-bit birthday collision needs ~thousands of concurrent prefixes; the CLI mitigates via `--provider-id` (`main.go:138-143` refuses on mismatch, covered by `TestRevokeAndKickRejectsMismatchedProviderOverride`); revoke/blacklist are operator-only, not attacker-reachable. Confirmed.
- **Recommendation:** Resolve revocation by full `token_hash` (require pasting the full token), or add a `UNIQUE` on `token_prefix` and reject issuance on collision; at minimum treat `affected>1` as an error and refuse to act. The CLI should print the exact `provider_id(s)` actually affected, not a `LIMIT 1` guess.

### [LOW] Provider-supplied routing metrics (`slots_free`, `slots_total`, `max_concurrency`, `max_context_tokens`, `ram_gb`) are never bounds-checked

- **Component:** Coordinator · WebSocket Relay (coord-ws)
- **File(s):** `phase4-coordinator/internal/ws/messages.go:443-452` (`requireInt`), 489-500 (heartbeat), 351-359 (auth_request), 252-259 (hello); flows to `buyer/server.go:2123/2620/2663`, `pool/provider.go:427-430`
- **Category:** input-validation
- **What:** `requireInt()` only checks JSON-unmarshal success — no non-negativity or sanity bound — unlike `ParseDrainStatus` (577-582), which rejects negatives. The values flow unvalidated into `pool.Provider` (`server.go:519-522`) and `ApplyHeartbeat`. No check enforces `slots_free <= slots_total`.
- **Impact:** An untrusted provider can advertise `max_context_tokens=MAX_INT` and remain eligible for arbitrarily large contexts it cannot serve, degrading the network and (in the `balanced` objective) inflating its score via the 0.2-weight ctx component. Negative values are also accepted.
- **Evidence:** Confirmed `requireInt` only unmarshals; unvalidated ints reach `pool.Provider` with no bounds. **Downgraded MEDIUM→LOW with a key correction:** the default-objective sort (`server.go:2280-2285`) is **ascending** on `SlotsFree`, selecting lowest first — so an attacker advertising `slots_free=MAX_INT` ranks **last**, not first; the headline "wins routing via slots_free" mechanism is inverted. The genuine vector is `MaxContextTokens` (exclusion gate `p.MaxContextTokens < estimatedTokens`); `RoutingEligible` requires `SlotsFree>0` so negative slots fail closed. No money/pinned impact. Confirmed.
- **Recommendation:** Validate these integers at parse time in `ParseHello`/`ParseHeartbeat`/`parseAuthInitial`: reject negatives, reject `slots_free > slots_total`, clamp/reject implausibly large `max_context_tokens`/`max_concurrency` to a configured ceiling. Mirror the `ParseDrainStatus` pattern.

### [LOW] Global `providerhttp.Client.Timeout` caps total streaming duration, killing healthy long non-WS SSE streams

- **Component:** Coordinator · Buyer API (coord-buyer)
- **File(s):** `phase4-coordinator/internal/buyer/server.go:1605-1693` (forwardStreaming; `.Do` at 1619); `internal/providerhttp/client.go:15-22`; `cmd/coordinator/main.go:37`; `internal/config/config.go:253-255`
- **Category:** incorrect-timeout
- **What:** `forwardStreaming` issues the upstream SSE request via the shared `providerhttp.Client.Do`, constructed with `http.Client{Timeout: TimeoutS}` (default 300s). Go's `Client.Timeout` covers the entire exchange including body reads, so a long non-WS completion's body read can fail at the wall-clock timeout, routing to the unguarded 1686-1691 branch (`FaultBreakerQualifying`).
- **Impact:** Legitimate long generations over the raw-HTTP fallback could be truncated and mis-attributed as provider faults, compounding the high-severity disconnect-misclassification. Limited because most providers route via the WS-tunneled path, making this fallback rare.
- **Evidence:** Mechanism real but not binding in default config: the per-attempt deadline `attemptTimeout(r)` (60s `retryPerAttemptTimeout` or 280s `RequestTimeoutS`) wraps the read and fires **first**, since both are ≤ the 300s client timeout. The footgun only bites if an operator sets `RequestTimeoutS > ProviderHTTP.TimeoutS`. Underlying mis-classification already captured by the HIGH disconnect finding. **Downgraded MEDIUM→LOW.** Confirmed.
- **Recommendation:** Use a dedicated streaming client without a whole-request `Timeout` (rely on `attemptCtx`/request-scoped deadlines), or set `Transport.ResponseHeaderTimeout`/`IdleConnTimeout` instead of `Client.Timeout`. Also add the `r.Context().Err()` guard from the HIGH finding.

### [LOW] `stickyStore` LRU eviction does an O(n) full-map scan under the global sticky mutex on every insert at capacity

- **Component:** Coordinator · Buyer API (coord-buyer)
- **File(s):** `phase4-coordinator/internal/buyer/server.go:2404-2437` (esp. 2415-2431); mutex at 63
- **Category:** performance
- **What:** When `len(s.sticky) >= s.stickyMaxEntries` (default 10000), `stickyStore` linearly scans the whole map under `s.stickyMu` to evict the single oldest entry. `stickyLookup`, `purgeStickyAccount`, and `stickyStore` all contend on this plain mutex.
- **Impact:** Under sustained sticky load at capacity, hot-path routing latency degrades and `stickyMu` contention rises — a throughput cliff at scale, not a correctness bug (bounded and self-limiting).
- **Evidence:** Confirmed the full-map scan under the shared mutex. The finding's worst-case is slightly pessimistic: lines 2419-2422 delete **all** TTL-expired entries (30-min default) in the same pass, so the single-oldest delete only fires when ≥10000 entries are simultaneously within TTL. The O(n)-under-plain-mutex serialization at saturation is the genuine concern. Confirmed at LOW.
- **Recommendation:** Use an amortized structure (container/list-backed LRU or sharded map with per-shard locks) for O(1) eviction, or batch-evict per scan; at minimum skip the scan when the prior sweep already dropped the map below capacity.

### [LOW] `estimateTokens` uses raw-byte/4 over the entire JSON envelope, mis-gating context capacity/preflight

- **Component:** Coordinator · Buyer API (coord-buyer)
- **File(s):** `phase4-coordinator/internal/buyer/server.go:2999-3005`; consumers at 2073, 2123, 2620, 2641-2645
- **Category:** correctness
- **What:** `estimateTokens` returns `len(raw)/4` over the full serialized request body (keys, braces, quotes, tool schemas, base64 image payloads). This biased-high value gates context-capacity rejection (`p.MaxContextTokens < estimatedTokens` → 413 `context_exceeds_capacity`) and preflight, so structural bytes can reject requests whose real prompt fits.
- **Impact:** Buyers may receive spurious 413 `context_exceeds_capacity` (or unnecessary preflight round-trips), especially for tool-heavy/multi-message requests. No security impact; affects routing acceptance accuracy. The pinned-path 413 (2620-2621) has no tolerance margin.
- **Evidence:** Confirmed `len(raw)/4` over the full `json.RawMessage`; all four consumers verified, including the marginless pinned 413. The estimate is biased high, so spurious 413 is the realistic failure mode. Confirmed at LOW.
- **Recommendation:** Estimate over message content only (sum of decoded content string lengths) rather than the full envelope, or add a tolerance margin before issuing a hard 413.

### [LOW] WebSocket upgrade completes before token validation (auth after resource commitment)

- **Component:** Coordinator · WebSocket Relay (coord-ws)
- **File(s):** `phase4-coordinator/internal/ws/server.go:168-181`
- **Category:** authz
- **What:** `handleProvider()` calls `gobwas.UpgradeHTTP(r, w)` first (169) and only afterward `validateProviderToken(r)` (174); on failure it writes a close frame and schedules `conn.Close()` via a 100ms `time.AfterFunc` (177). The 101 handshake, socket allocation, and a 100ms timer are granted before the bearer check.
- **Impact:** An attacker with no valid token can repeatedly drive full WS upgrades plus a 100ms-pending close timer — a modest connection/timer-churn amplification. No protocol state beyond the raw conn is reached.
- **Evidence:** Confirmed the upgrade-then-validate ordering and the 100ms `AfterFunc`. `validateProviderToken` reads only `r.Header`/`r.Context()` and never touches the conn, so the reorder is mechanical. Confirmed at LOW.
- **Recommendation:** Validate the bearer token from `*http.Request` before `UpgradeHTTP`; on failure return HTTP 401 without upgrading.

### [LOW] `RefundRequest` pops the most-recent window timestamp regardless of which request failed

- **Component:** Coordinator · WebSocket Relay (coord-ws)
- **File(s):** `phase4-coordinator/internal/ws/admission.go:154-168` (RefundRequest), 133-152 (TryReserveRequest); refund triggers at `buyer/server.go:1326-1334`
- **Category:** accounting
- **What:** `TryReserveRequest` appends `now()` to `requestWindows[providerID]`; `RefundRequest` unconditionally drops the last element (LIFO) and decrements `TotalRequestsServed`. Under concurrent in-flight requests for the same provisional provider, the refunded slot may correspond to a different (newer, still-in-flight) reservation. Refund is also only triggered on a subset of failure results (`ProviderDisconnected`/`QueueFull`), so quota can drift.
- **Impact:** Provisional per-hour quota accounting can drift up or down under concurrency, letting a provider slightly exceed `ProvisionalQuotaPerHour` or be under-charged. Bounded by quota size; provisional-only; no money or pinned-provider impact.
- **Evidence:** Confirmed the LIFO drop (`window[:len(window)-1]`, guard only `len>0`) is not keyed to the failed request; both ops hold `a.mu` so there is no race on the structure — only the accounting picks the wrong still-valid entry. Subset-of-failures trigger confirmed at `server.go:1326-1333`. Confirmed at LOW.
- **Recommendation:** Make reservations refundable by identity: have `TryReserveRequest` return a token/timestamp and have `RefundRequest` remove that specific entry (or the oldest matching) rather than blindly the last.

### [LOW] Warmup-fallback timer keyed only by `providerID` can race a reconnect and is not cleaned on disconnect

- **Component:** Coordinator · WebSocket Relay (coord-ws)
- **File(s):** `phase4-coordinator/internal/ws/server.go:1172-1188` (markDegradedForWarmup), 1190-1210 (handleDisconnect); guard at `pool/provider.go:225`
- **Category:** resource-leak
- **What:** `markDegradedForWarmup` stores a `time.AfterFunc` in `s.timers` keyed by `providerID` only (1187). `handleDisconnect` clears the warmup gate and session but never deletes `s.timers[providerID]`. The callback self-deletes and its `MarkState` is guarded by `assignedID`, so a stale timer cannot resurrect a replaced session — but until it fires, a dangling timer persists.
- **Impact:** Minor: a short-lived dangling timer per warmup-window disconnect; no incorrect state transition (MarkState validates `assignedID`). Becomes small, self-healing timer accumulation only under rapid connect/disconnect churn.
- **Evidence:** Confirmed `s.timers.Store(providerID, timer)` with no corresponding delete in `handleDisconnect`; self-heal via callback self-delete (1179/1185) and `MarkState`'s `p.AssignedID == assignedID` guard verified. Confirmed at LOW.
- **Recommendation:** In `handleDisconnect`, `s.timers.LoadAndDelete(providerID)` and `Stop()` the timer; optionally key the timer by `sessionKey(providerID, assignedID)`.

### [LOW] `send()` silently drops control messages on write-buffer backpressure

- **Component:** Coordinator · WebSocket Relay (coord-ws)
- **File(s):** `phase4-coordinator/internal/ws/relay.go:118-130` (send), 194-195 (cancelActive); `admin_endpoints.go:104` (reject-drain)
- **Category:** reliability
- **What:** `providerSession.send` does a non-blocking channel send (writeCh cap 64) and returns `ErrRelayBackpressure` when full. `cancelActive` (`relay.go:194-195 _ = ps.send(b)`) and `handleAdminReject` (`admin_endpoints.go:104`) ignore that error. Under buffer saturation by inference chunks, a cancel or drain can be dropped with no retry.
- **Impact:** Under saturation a cancellation may never reach the provider, so it keeps generating (and the buyer keeps being relayed/charged) after the buyer cancelled. `DrainAll`/`handleBlacklist` do surface the error, confining impact to the ignored callers.
- **Evidence:** Confirmed the non-blocking send and the two error-ignoring callers vs. the error-surfacing `DrainAll`/warm_up. **Mitigation the finding understated:** the admin-reject path schedules a forced `conn.Close()` 200ms later (`admin_endpoints.go:106-109`), so a dropped drain frame still stops the provider — the genuinely unmitigated case is `cancelActive` (no fallback close). Confirmed at LOW.
- **Recommendation:** Treat backpressure on control frames as significant: log it and, for cancel, fall back to `conn.Close()` so the provider stops. At minimum stop discarding the error in `cancelActive`.

### [LOW] Empty challenge makes the attestation replay/freshness binding a no-op (defense-in-depth gap)

- **Component:** Coordinator · Tier2 Attestation (coord-tier2)
- **File(s):** `phase4-coordinator/internal/tier2/pillar_c.go:119-123`
- **Category:** replay-protection
- **What:** `VerifyAttestationToken` computes `wantChallenge := base64.RawURLEncoding.EncodeToString(challenge)` and rejects unless `token.Challenge == wantChallenge`. For an empty challenge, `wantChallenge` is `""`, so any token with an empty `Challenge` passes (and the mock path yields `Attested`). There is no `len(challenge) > 0` assertion.
- **Impact:** Not exploitable through the current WS path (challenge is always 32 random bytes). Latent contract defect: any future/alternate caller passing an empty nonce silently disables the component's primary anti-replay control.
- **Evidence:** Confirmed no `len(challenge)==0` guard; empirically an empty-challenge token validates as attested. All non-test callers enumerated: `ws/server.go:382` passes `randomBytes(32)`, and the artifact CLI enforces `len(challengeBytes)==32` before calling — both safe. Reachable only by direct library/test use. Confirmed at LOW.
- **Recommendation:** Reject empty challenges at the top of `VerifyAttestationToken` (`if len(challenge)==0 { return AttestationStatusFailed }`, or require ≥16 bytes), and document the non-empty precondition on the exported function.

### [LOW] Explorer rate-limiter map never evicts stale per-IP keys (slow unbounded memory growth)

- **Component:** Coordinator · Explorer + RequestLog (coord-explorer)
- **File(s):** `phase4-coordinator/internal/explorer/handlers.go:31, 41, 505-528`
- **Category:** resource-leak
- **What:** `allowRequest` trims expired timestamps within each key's slice but never deletes the key from `h.stamps`; the trimmed-but-empty slice is written back (522/526). The map accumulates one entry per distinct authenticated client IP for the process lifetime. Auth (56) precedes `allowRequest` (60), so only valid-operator-token requests populate it.
- **Impact:** Memory grows with distinct source IPs that successfully authenticate. Pre-auth traffic cannot grow the map; bounded to a leaked/shared operator token or an operator behind many rotating IPs.
- **Evidence:** Confirmed no `delete(h.stamps, key)` anywhere; auth-before-rate-limit ordering verified (`authorized()` 501-503). Process restart resets the map. Confirmed at LOW.
- **Recommendation:** After trimming, `if len(stamps)==0 { delete(h.stamps,key) } else { h.stamps[key]=stamps }`; optionally add a periodic idle-key sweep and a test driving many distinct `RemoteAddr` values.

### [LOW] Operator/admin bearer token compared with non-constant-time string equality (coordinator: explorer + WS admin gates)

- **Component:** Coordinator · Explorer + RequestLog (coord-explorer); **also affects** Coordinator · Auth/Config/Pool/CMD (coord-core) — the WS admin gate `authorizedOperator` (`internal/ws/server.go:1480`) and the dead `AuthorizedBearer` helper (`internal/auth/tokens.go:33-35`)
- **File(s):** `phase4-coordinator/internal/explorer/handlers.go:501-503`; `internal/ws/server.go:1480-1482`; `internal/auth/tokens.go:33-35`
- **Category:** timing-side-channel
- **What:** `authorized()` compares the bearer token with plain `==` (`r.Header.Get("Authorization") == "Bearer "+h.cfg.Auth.OperatorKey`), which short-circuits on the first differing byte. The same pattern recurs in the WS admin gate (`authorizedOperator`) and the dead `AuthorizedBearer` helper. `subtle.ConstantTimeCompare` is available and used correctly elsewhere (`buyer/server.go:2613`, `tier2/pillar_c.go:270`). The explorer is mounted on the public-internet WS mux, fronting session/ledger/settlement data.
- **Impact:** A remote attacker issuing many requests could in principle attempt byte-by-byte token recovery; practical exploitability is heavily masked by network jitter, scheduler noise, and the high-entropy token, so this stays low — but a money-authority admin API warrants constant-time comparison, and the safe primitive already exists in-tree (internal inconsistency).
- **Evidence:** Confirmed `authorized()` uses plain `==`; the public-mux claim verified (`ws/server.go Handler()` mounts the explorer on the same mux as `/ws/provider`, served on `providerAddr`). `subtle.ConstantTimeCompare` confirmed at `buyer/server.go:2613` and `pillar_c.go:270`. `AuthorizedBearer` confirmed dead (single grep hit at its definition). Kept LOW. Confirmed.
- **Recommendation:** Replace `==` with `subtle.ConstantTimeCompare` over the full `Authorization` header (with a key-set guard) in `authorized()` and `authorizedOperator`; delete the unused `AuthorizedBearer` or rewrite it the same way. Standardize on one helper to prevent drift. *(Part of the cross-cutting non-constant-time cluster.)*

### [LOW] Operator admin key compared with non-constant-time string equality (coordinator billing endpoints)

- **Component:** Coordinator · Billing/Settlement (coord-billing)
- **File(s):** `phase4-coordinator/internal/billing/endpoints.go:61`
- **Category:** timing-side-channel
- **What:** The admin gate at `endpoints.go:61` uses `r.Header.Get("Authorization") != "Bearer "+h.operatorKey` (native `!=`), with no `crypto/subtle` path anywhere in `internal/billing` or `internal/auth`. Protects every `/admin/ledger/*` endpoint (summary, providers, reconcile).
- **Impact:** Same class as above. Lower still: the gated endpoints are admin-only and read-mostly (reconcile only writes a benign `reconciliation_runs` row, not fund movement). The `operatorKey==""` open path is unreachable because `config.go:399` enforces the key be set.
- **Evidence:** Confirmed native `!=`; grep for `crypto/subtle` across `internal/billing`/`internal/auth` returns nothing. Empty-key case unreachable per `config.go:399`. **Downgraded MEDIUM→LOW:** remote target (`coordinator.streamvc.live`) where network jitter dwarfs per-byte timing, high-entropy key, read-mostly admin endpoints. Confirmed.
- **Recommendation:** Use `subtle.ConstantTimeCompare([]byte(authHeader), []byte("Bearer "+h.operatorKey)) == 1` after a length-independent guard. *(Cross-cutting non-constant-time cluster.)*

### [LOW] Operator admin token compared with non-constant-time string equality (gateway — auth lens of the gw-router MEDIUM)

- **Component:** Gateway · Auth/Config (gw-auth-core)
- **File(s):** `phase5-gateway/internal/router/server.go:1933, 1942`
- **Category:** timing-side-channel
- **What:** The same two `==` sites described in the MEDIUM gw-router finding, considered from the auth-core review. `operatorAuthorized` and `shouldPersistInternalHeaderAudit` compare the operator key with plain `==`; it is the lone timing-vulnerable secret check (every other secret comparison is constant-time).
- **Impact:** Same operator-key exposure as the MEDIUM entry. **Downgraded MEDIUM→LOW** from the auth lens: Go `==` compares lengths first and only iterates bytes on length match, leaking length but not a clean per-byte oracle; HTTP handler dispatch adds far more variance than a 32-byte memcmp short-circuit, so remote recovery of a high-entropy key is not practically demonstrated.
- **Evidence:** Confirmed identical to the gw-router finding's code; grep confirms only `demo.go:53` (`hmac.Equal`) uses a constant-time primitive in `internal/router`/`internal/auth`. Downgraded. Confirmed.
- **Recommendation:** Fix both `1933` and `1942` with `subtle.ConstantTimeCompare`/`hmac.Equal`. **Note:** this is the same code defect as the MEDIUM gw-router finding above — the two components reviewed it independently and assigned different severities; track it once, at the higher (medium) severity, in remediation.

### [LOW] `providerhttp.Client` is an unsynchronized mutable package global

- **Component:** Coordinator · Auth/Config/Pool/CMD (coord-core)
- **File(s):** `phase4-coordinator/internal/providerhttp/client.go:8-22`; readers at `buyer/server.go:1194,1619`, `ws/server.go:901`
- **Category:** concurrency
- **What:** `Client` is a package-level `*http.Client` that `Init()` reassigns and tests overwrite directly, read concurrently by handlers via `providerhttp.Client.Do`, with no mutex/atomic guarding the swap. Safe today only by convention: `main.go:37` calls `Init()` before any server goroutine starts and the SIGHUP reload path does not re-`Init`.
- **Impact:** No current data race. If a future change calls `Init()` during config reload or adds runtime timeout re-tuning, it becomes a data race on the global pointer read by in-flight forwarders (UB under `-race`, possible torn reads).
- **Evidence:** Confirmed package global reassigned in `Init` with no synchronization; single production write at `main.go:37` runs before serving; SIGHUP path (`main.go:191-226`) does not call `providerhttp.Init`. Latent, not active. Confirmed at LOW.
- **Recommendation:** Inject the client as a struct field at server construction, or store it in `atomic.Pointer[http.Client]` if it must remain global and ever be swapped. At minimum, document the "Init once before serving, never after" invariant.

### [LOW] Proxy copies hop-by-hop response headers verbatim to the client

- **Component:** Gateway · Router/HTTP edge (gw-router)
- **File(s):** `phase5-gateway/internal/router/server.go:2218-2227` (copyCleanHeaders); used at 1469, 1535
- **Category:** correctness / standards-conformance
- **What:** `copyCleanHeaders` copies every upstream response header except `x-macprovider-*` and `Content-Length`; it does not strip RFC 7230 hop-by-hop headers (`Connection`, `Keep-Alive`, `Proxy-Connection`, `TE`, `Trailer`, `Transfer-Encoding`, `Upgrade`). Used on proxied non-streaming, streaming, `/v1/models`, and no-provider passthrough responses.
- **Impact:** Potential response-framing inconsistencies with downstream CDN/LB intermediaries, and unintended header dropping if the coordinator ever forwarded `Connection: <token>`. The upstream coordinator is trusted, so this is hygiene/conformance rather than an active exploit.
- **Evidence:** Confirmed only `isMacProviderHeader` and `Content-Length` are skipped; no hop-by-hop set excluded. Go's `net/http` server overrides framing headers it manages, minimizing practical impact. Confirmed at LOW.
- **Recommendation:** Also skip the standard hop-by-hop set and any header named in the upstream `Connection` header, mirroring `httputil.ReverseProxy`.

### [LOW] Streaming token-too-long / scanner-error path has no test coverage

- **Component:** Gateway · Router/HTTP edge (gw-router)
- **File(s):** `phase5-gateway/internal/router/server_test.go` (coverage gap; no specific line)
- **Category:** test-coverage
- **What:** Grep of the router tests for `scanner.Err`, `ErrTooLong`, the 1 MiB buffer cap, and operator-auth timing returns no matches. The settlement classification is exercised only on the happy/cancellation path; no test asserts a truncated/oversized stream is settled as an error, and none pins constant-time operator comparison.
- **Impact:** The silent-truncation settlement bug (HIGH, above) could regress or be "fixed" incorrectly without any test failing. Money-settlement branches on the streaming path are undertested.
- **Evidence:** Confirmed grep across all router `*_test.go` files returns no matches; the only streaming test (`server_test.go:1470-1531`) emits a 120-char line and exercises client cancellation, never `ErrTooLong` or a mid-stream non-EOF error. Confirmed at LOW.
- **Recommendation:** Add a streaming test with a fake coordinator emitting a >1 MiB SSE line (forcing `bufio.ErrTooLong`) and another closing the body mid-stream with a non-EOF error, asserting the outcome is an error classification, not `ok`. This test also drives the HIGH fix.

### [LOW] `ReserveQuota` leaks raw SQLite UNIQUE-constraint error on duplicate `request_id` instead of a sentinel

- **Component:** Gateway · SQLite Storage (gw-storage)
- **File(s):** `phase5-gateway/internal/storage/sqlite/store.go:382-388`; sentinel at `errors.go:9`; caller `router/server.go:1314`
- **Category:** error-handling
- **What:** `quota_reservations` has `PRIMARY KEY (account_id, request_id)`. A second `ReserveQuota` with the same pair fails the INSERT with the raw driver UNIQUE error, returned verbatim. `storage.ErrReservationExists` exists for exactly this case but is never used; the caller maps the unrecognized error to HTTP 500 `quota_reservation_failed`.
- **Impact:** Replayed/retried requests reusing a `request_id` produce confusing 500s and leak SQLite driver internals (constraint names, code 1555) into logs. No money/quota is mis-accounted (`Admitted` false, no row written, defensive `RefundReservation` is a no-op); observability/idempotency only.
- **Evidence:** Confirmed the PK (`migrate.go:93`), the verbatim `return …, err` (387) with no classification, `ErrReservationExists` defined but unreferenced, and the caller falling through to `StatusInternalServerError`. Requires genuine client replay of the same `request_id` within the window. Confirmed at LOW.
- **Recommendation:** Detect the unique-constraint violation after the INSERT and return `storage.ErrReservationExists` (or re-read the existing reservation idempotently); map it in `router/server.go` to a deterministic 409/idempotent-replay response, not a generic 500.

### [LOW] `launchd` agent booted out before binary replacement — replace failure leaves provider stopped until next login

- **Component:** Provider Binary · Self-Update + Attestation (bin-security)
- **File(s):** `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift:175-212` (esp. drain 179/193-201, replace 159-173/184, restart 189/211)
- **Category:** resource-leak / availability
- **What:** `applyValidatedUpdate()` drains first (`launchctl bootout …` stops the agent), then `replaceCurrentBinary`, then `restartLaunchdIfInstalled`. If `replaceCurrentBinary` throws (`copyItem`/`setAttributes`/`rename`), the error propagates out and the `bootstrap` restart (211) is never reached. The agent is already booted out, so the provider stays stopped. There is no `defer`/cleanup.
- **Impact:** A transient filesystem error during replace turns a routine self-update into an outage: drained, agent unloaded, nothing restarts it. Because drain already told the coordinator the provider is going away, no automatic recovery occurs until a human re-runs the installer or the next login.
- **Evidence:** Confirmed no `defer`/cleanup in `applyValidatedUpdate` and the drain→replace(throwing)→restart ordering. **Two original claims refuted, lowering severity:** (1) "old binary may already be unlinked by a partial rename" is **false** — `replaceCurrentBinary` copies to a sidecar and swaps via atomic POSIX `rename`, removing the staged file on failure (no torn state); (2) "permanently stopped" overstates it — the plist is **not** removed, so the agent re-loads on next login/reboot (`RunAtLoad`). **Downgraded MEDIUM→LOW.** Confirmed.
- **Recommendation:** Stage and validate the replacement **before** stopping the agent, or wrap drain+replace+restart so any failure after `bootout` always attempts restart in a `defer`/cleanup. Boot out immediately before the atomic `rename` only.

### [LOW] No timeout on new-binary self-test or tar/openssl subprocesses — a hung self-test stalls the update

- **Component:** Provider Binary · Self-Update + Attestation (bin-security)
- **File(s):** `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift:92, 214-223 (runProcess), 265-278 (processOutput); 89 (tar), 250 (openssl)`
- **Category:** resource-leak
- **What:** `runProcess` and `processOutput` call `process.waitUntilExit()` with no deadline. Line 92 executes the freshly downloaded binary as `self-test`, which loads the configured model and runs a startup inference; if model load/inference hangs (Metal stall, model file lock, HF fetch), `waitUntilExit()` blocks forever. The same applies to `tar -xzf` (89) and `openssl dgst -verify` (250). No cancellation path exists.
- **Impact:** The `update` command hangs with no progress and no error, leaving a wedged process and a half-downloaded temp dir.
- **Evidence:** Confirmed bare `waitUntilExit()` in both helpers; grep for timeout/deadline/terminate/interrupt/DispatchSource finds none. **Downgraded MEDIUM→LOW:** in the production `run()` flow self-test (92) runs **before** `applyValidatedUpdate` while the agent is still **live** (no outage — just a wedged interactive CLI the operator can Ctrl-C). `update` is an operator-run command, not an unattended daemon path; the only outage route is "operator kills mid-`applyValidatedUpdate`", already captured by the launchd finding. Confirmed.
- **Recommendation:** Add a wall-clock timeout to `runProcess`/`processOutput` (a `Task` that calls `process.terminate()`/`interrupt()` after N seconds, or a `DispatchSource` timer) and fail with a clear error. The self-test in particular needs a bounded deadline since it loads a model.

### [LOW] Self-update redirect target not re-validated after `validateDownloadURL` (host allowlist checks only the pre-redirect URL)

- **Component:** Provider Binary · Self-Update + Attestation (bin-security)
- **File(s):** `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift:151-157 (download), 225-232 (validateDownloadURL); applied at 68-70`
- **Category:** supply-chain
- **What:** `validateDownloadURL` is applied to the GitHub `browser_download_url`, which 302-redirects to `objects.githubusercontent.com` (historically S3/Azure). `download()` uses the default `URLSession`, which auto-follows redirects with no `willPerformHTTPRedirection` hook, so the realized host is never re-checked against the allowlist.
- **Impact:** Defense-in-depth only: `checksums.txt` is ECDSA-verified against a pinned key and the tarball is SHA-256-matched against that signed manifest, so a hijacked redirect cannot substitute content without breaking the signature — the practical risk is a malicious redirect serving a different-but-failing artifact (DoS), not code execution.
- **Evidence:** Confirmed `download()` has no delegate/redirect handling; the signature gate (`verifyChecksumSignature` 245-263 against `checksumPublicKeyPEM`) and SHA-256 match (81-84) verified in-code. Confirmed at LOW.
- **Recommendation:** Install a `URLSessionTaskDelegate` that re-runs `validateDownloadURL` on each redirect target, or disable auto-follow and validate-then-follow manually.

### [LOW] Attestation envelope falls back to the challenge as the `token` when the MDA artifact omits a token

- **Component:** Provider Binary · Self-Update + Attestation (bin-security)
- **File(s):** `phase3-binary/Sources/macprovider-cli/Tier2Attestation.swift:60-80, 157-169`
- **Category:** supply-chain
- **What:** When an MDA artifact has no `token`, `makeAttestationToken` sets `tokenBase64URL: artifact.tokenBase64URL ?? challengeBase64URL` (62), so `baseTokenEnvelope` sets `envelope["token"]` to the echoed challenge (159). A binding signature is added only if `MACPROVIDER_TIER2_MDA_SIGNING_KEY_PATH` is configured; otherwise `envelope["signature"]` stays whatever the artifact provided (possibly nil).
- **Impact:** The provider can emit a structurally-complete `attestation_token` whose `token` carries no genuine device assertion (just the echoed challenge) and possibly no binding signature. Whether this is exploitable depends entirely on coordinator-side validation, which is out of scope for this (provider-only) component.
- **Evidence:** Confirmed the echo fallback (62→159) and that `parse()` enforces cert-chain/CSR but treats `token` as optional. Exploitability lives in the coordinator's verifier, not reviewable here. Confirmed at LOW.
- **Recommendation:** Do not echo the challenge as the token; if the artifact has no real token, return nil (attestation unsupported). Cross-check the coordinator's verifier to confirm it rejects `token == challenge` and requires a verified ES256 binding signature.

### [LOW] Local HTTP inference path leaks tasks and head-of-line-blocks on client disconnect (no `channelInactive`/cancellation)

- **Component:** Provider Binary · Runtime/Inference (bin-runtime)
- **File(s):** `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:41-85, 180-227, 229-320, 464-514`; `ModelRuntime.swift:13-22, 31, 96/150`
- **Category:** resource-leak
- **What:** `RouterHandler` implements only `channelRead` (no `channelInactive`/`errorCaught`). `handleChatCompletions`/`handleStreamingChatCompletions` each launch a fire-and-forget `Task.detached` whose handle is never retained; the HTTP overloads pass `shouldCancel: { false }`. On client disconnect nothing cancels the task — inference runs to completion holding the single `inferenceGate` permit, then writes to a dead channel.
- **Impact:** A single abandoned local request head-of-line-blocks every other local inference through the value=1 semaphore; repeated connect-then-disconnect requests pin the permit and stall the node.
- **Evidence:** Confirmed only `channelRead` is overridden, detached tasks are unretained, and the no-arg overloads route through `shouldCancel: { false }` so the in-loop cancel check never fires. **Downgraded MEDIUM→LOW:** the server binds `127.0.0.1` only (loopback, not external attack surface); MLX `generate` is bounded by `request.maxTokens` (validated >0), so an abandoned generation self-terminates in bounded time rather than pinning the permit indefinitely; the revenue-bearing WS relay path threads a real `shouldCancel: { state.isCancelled }` and is unaffected. Confirmed.
- **Recommendation:** Track the per-request detached `Task` and implement `channelInactive`/`errorCaught` to cancel it, or thread a `shouldCancel` closure that flips when the channel goes inactive. Add a server-side max-inference-duration timeout.

### [LOW] Local HTTP chat-completions path has no per-connection concurrency limit; all requests pile onto the value=1 gate

- **Component:** Provider Binary · Runtime/Inference (bin-runtime)
- **File(s):** `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:12-38, 180-212`; contrast `InferenceRelay.swift:70-79`
- **Category:** resource-exhaustion
- **What:** Unlike the WS relay (which enforces `active.count < maxActiveRequests` and returns `error_queue_full`), `handleChatCompletions` performs no admission check: every POST spawns a `Task.detached` that blocks on `inferenceGate`. There is no cap on queued detached tasks, no 429/queue_full, and no timeout.
- **Impact:** A local client can open many concurrent chat requests; each accumulates a detached task and buffered body on the unbounded semaphore `waiters` array, growing memory and task count with no queue-full signal. Loopback-only bind makes this self-DoS/robustness, not an external attack surface.
- **Evidence:** Confirmed no admission/concurrency gate before the detached task (only body-size and parse guards); no analogue of the relay's `guard active.count < maxActiveRequests`; bind is `127.0.0.1` only. Confirmed at LOW.
- **Recommendation:** Apply the relay's bounded-admission policy on the HTTP path (429/queue_full at an in-flight+queued cap) and add a request timeout. Composes with the `channelInactive` cancellation fix above.

### [LOW] Health/status `requests_queued` is hardwired to 0 (dead telemetry)

- **Component:** Provider Binary · Runtime/Inference (bin-runtime)
- **File(s):** `phase3-binary/Sources/macprovider-cli/ProviderStatus.swift:79, 110, 191`; surfaced at `HTTPServer.swift:355`
- **Category:** observability
- **What:** `requestsQueued` is declared, stored (init 0), and surfaced in `/v1/health`, but never incremented or decremented. Real queueing happens inside `AsyncSemaphore.waiters`, which `ProviderStatus` has no visibility into, so the reported value is always 0 while real queue depth can be >0.
- **Impact:** Operators and any coordinator-side autoscaling/health logic reading `requests_queued` get a constant 0, masking real backpressure on the single-slot gate — misleading rather than corrupting.
- **Evidence:** `grep requestsQueued` returns exactly three sites (decl, init, snapshot read) and no `+=`/`-=`; `beginRequest`/`finishRequest` only touch `requestsInFlight`. Confirmed at LOW.
- **Recommendation:** Compute it from the gate's waiter count (or `requestsInFlight - maxConcurrency` clamp), or remove the field from the public payload so it does not imply a measurement that is not taken.

### [LOW] Throughput estimate divides completion tokens by total request latency (includes queue wait and prompt processing)

- **Component:** Provider Binary · Runtime/Inference (bin-runtime)
- **File(s):** `phase3-binary/Sources/macprovider-cli/ProviderStatus.swift:149-155, 180-182`
- **Category:** metrics-accuracy
- **What:** `finishRequest` computes `elapsed` from `startedAt` (captured in `beginRequest`, **before** waiting on `inferenceGate` and before prompt processing), adds it to `windowGenerationSeconds`, and `snapshot()` reports throughput as `windowCompletionTokens / windowGenerationSeconds`. So "generation seconds" include semaphore queue-wait and prompt-encode time.
- **Impact:** Under any concurrency the reported `throughput_tps_since_last` systematically understates real generation speed (worse with more queueing). If the coordinator uses this TPS for routing/pricing/capacity, providers are mis-ranked. No inference-output correctness impact.
- **Evidence:** Confirmed `beginRequest` returns its `Date()` before inference (HTTP and relay paths both call it before `complete`/`stream`), and `finishRequest` divides by full wall-clock. Note a separate, accurate generation-only path exists (`measureStartupThroughput`) for the capacity estimate; only the per-window TPS conflates. Confirmed at LOW.
- **Recommendation:** Measure generation time from the actual `generate()` call (or MLX result timings), excluding semaphore wait; keep latency-since-last (which legitimately includes queue wait) separate from a true tokens/second figure.

### [LOW] Streaming delta reconciliation can silently drop or fail to retract output when filtered text is not a growing prefix

- **Component:** Provider Binary · Runtime/Inference (bin-runtime)
- **File(s):** `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:170-199, 401-404, 344-384`; `StopTokenFilter.swift:16-22`
- **Category:** logic
- **What:** `stream()` emits `delta(from: emitted, to: candidate.text)`, which returns `""` whenever `current` is not prefixed by `emitted` (402). `candidate.text` comes from `streamingSafePrefix`, which strips stop tokens by `replacingOccurrences` **anywhere** in the text. If stripping removes characters inside already-emitted text (or the final `applyOutputFilters` yields text shorter than already streamed), both per-chunk and final deltas compute to `""` and already-streamed bytes cannot be retracted.
- **Impact:** In the edge case where a stop/special token appears partway through already-emitted text, the SSE stream can emit content the final filtered result would have removed (cannot un-send) or drop a legitimate delta — the buyer's streamed transcript can differ from the canonical final content. Bounded and model/stop-token dependent; no crash or money error.
- **Evidence:** Confirmed `delta()` short-circuits non-prefix to `""`, that `stripping` removes all interior occurrences, and that flushed SSE chunks cannot be retracted; the non-streaming `complete()` path applies the filter once and is unaffected (divergence is streaming-only). Confirmed at LOW.
- **Recommendation:** Make streaming emission monotonic against the same final filter: emit only when final-filtered text strictly extends previously emitted text, and treat a shrink as a stop/cancel rather than a no-op. Add a unit test feeding a chunk sequence where an interior stop token forces the filtered text to shrink.

### [LOW] `companion.py` 1-second-timestamp PRIMARY KEY + `INSERT OR REPLACE` silently overwrites sub-second samples

- **Component:** Web Demo + Scripts (web-scripts)
- **File(s):** `/Users/augstar/macprovider-poc/beta/companion.py:31-38, 82-87, 92`
- **Category:** data-loss
- **What:** `ts_utc TEXT PRIMARY KEY` with `isoformat(timespec="seconds")` and `INSERT OR REPLACE`. The loop blocks ~1s in `cpu_percent(interval=1)` then sleeps `interval-1`; with `--interval 1` the sleep is 0, so two iterations can share a whole second and the second write overwrites the first.
- **Impact:** Silent telemetry gaps / real data loss under `--interval 1`.
- **Evidence:** Confirmed `ts_utc` PK, whole-second truncation, `INSERT OR REPLACE`, and `remaining = interval - 1 == 0` at `--interval 1`. The argparse default is 60; `--interval 1` is undocumented; at any interval ≥2 the collision cannot occur. Confirmed at LOW.
- **Recommendation:** Use `AUTOINCREMENT` or microsecond timestamps with a plain `INSERT`.

### [LOW] `harness.py` rotate model-select reads/writes the index file unlocked; concurrent runs skip/repeat a model

- **Component:** Web Demo + Scripts (web-scripts)
- **File(s):** `/Users/augstar/macprovider-poc/beta/harness.py:141-159`
- **Category:** concurrency
- **What:** In rotate mode, `resolve_model` reads `model_index`, writes the next index, and selects `current mod len` with a non-atomic read-modify-write (no `flock`, no temp-file+rename). A manual `--once` overlapping the hourly cron reads the same index and advances identically, so rotation skips/repeats.
- **Impact:** Biases which model is benchmarked; no corruption.
- **Evidence:** Confirmed the unlocked read (146) → compute (150) → write (151). **Latent under the installed schedule:** the only active cron lanes are `coord-cooperative.sh`/`coord-adversarial.sh` with no overlapping rotate crons, and `model_select: "rotate"` is commented out in every live config (the active M1/M4 configs use a single `model:` string with no `models:` list, so `resolve_model` returns early before the rotate branch). Triggering requires enabling rotate **and** two overlapping invocations. Confirmed at LOW.
- **Recommendation:** Guard with `fcntl.flock` or temp-file + `os.replace`.

### [INFO] `operator_share_bps = 10000 - ProviderShareBps` could violate a CHECK only if a stale/invalid config carried bps>10000

- **Component:** Coordinator · Billing/Settlement (coord-billing)
- **File(s):** `phase4-coordinator/internal/billing/hotpath.go:230-248` (esp. 242); CHECK at `store.go:90`
- **Category:** defense-in-depth
- **What:** `insertOperatorCreditTx` writes `operator_share_bps` as `10000 - result.ProviderShareBps`; `ledger_operator_credits` enforces `CHECK(operator_share_bps BETWEEN 0 AND 10000)`. The premise is that a config snapshot with `provider_share_bps > 10000` would make the subtraction negative and abort `WriteHotPath`, silently dropping billing.
- **Impact:** None reachable today; defense-in-depth only.
- **Evidence:** Mechanics confirmed but the premise is **refuted by the schema:** the only write into `ledger_config_snapshots` is `InsertConfigSnapshot`, whose `provider_share_bps` column itself has `CHECK(... BETWEEN 0 AND 10000)` (`store.go:152`); the rebuild migration re-validates every row. The config source `ParseShareBps(cfg.ProviderShare)` is fed by config validated to `[0.0,1.0]` (`config.go:515`). So `>10000` can never persist, and `10000-bps` can never go negative. **Downgraded LOW→INFO.** Confirmed.
- **Recommendation:** Clamp/validate `ProviderShareBps` to `[0,10000]` at the `ComputeCredits` boundary as defense-in-depth, and fail with a clear fault rather than a CHECK-constraint abort.

### [INFO] `ParseMultiplierPPM`/`ParseShareBps` lack overflow/clamp guards on operator-supplied floats

- **Component:** Coordinator · Billing/Settlement (coord-billing)
- **File(s):** `phase4-coordinator/internal/billing/formula.go:46-48, 50-52`; `config.go:518`
- **Category:** robustness
- **What:** `ParseMultiplierPPM` and `ParseShareBps` return `int64(math.Round(v*denom))` with no bounds check; `GlobalMultiplier` is validated only as `>0` (no upper bound), so a very large multiplier could overflow the int64 conversion.
- **Impact:** A corrupted multiplier degrades to the null-error/zero-credit path rather than producing wrong money. Operator-controlled config, not attacker input.
- **Evidence:** Confirmed no bounds check and `config.go:518` validates only `>0`. The persisted `global_multiplier_ppm` column is `CHECK(>= 0)`; `ComputeCredits` routes the multiplier through `checkedMul`, which returns `ok=false` on overflow and sends the row to `zeroCredits` rather than emitting wrong money. Confirmed at INFO.
- **Recommendation:** Add an explicit upper bound on `GlobalMultiplier` in config validation and clamp/validate the PPM and bps values before persisting a snapshot.

### [LOW→INFO] Dead/unreachable code in hot-path `attempt_n` derivation

- **Component:** Coordinator · Billing/Settlement (coord-billing)
- **File(s):** `phase4-coordinator/internal/billing/hotpath.go:55-88`
- **Category:** maintainability (severity: low)
- **What:** The block at 56 enters only when `derived := requestCount-1; derived > in.AttemptN`, so the nested guard at 57 `if in.AttemptN != derived` is tautologically true and its body always returns at 85, making `in.AttemptN = derived` at 87 unreachable.
- **Impact:** No behavioral defect (line 58 already sets `in.AttemptN = derived` before the work, so line 87 would be a no-op). Purely a clarity hazard on the billed path.
- **Evidence:** Confirmed by reading 55-88; the outer strict-`>` guard makes the inner `!=` always true and line 87 unreachable. `go vet` returns clean (it does not do value-range reasoning), which is precisely why human review caught it. Confirmed at LOW.
- **Recommendation:** Drop the always-true `if in.AttemptN != derived` wrapper and remove the unreachable line 87, or restructure so derived-attempt handling is expressed once.

### [INFO] Inconsistent blocking vs non-blocking sends to `active.errs` (NAK fallback path)

- **Component:** Coordinator · WebSocket Relay (coord-ws)
- **File(s):** `phase4-coordinator/internal/ws/relay.go:607-611` vs 170-173 / 197-201 / 227-230
- **Category:** concurrency
- **What:** Every other writer to `active.errs` uses the non-blocking `select { case errs<-err: default: }`. The NAK fallback at 609 instead does a bare blocking send `active.errs <- ErrRelayNAKFallback`.
- **Impact:** No current deadlock. Latent: any future change that pre-populates `errs` or reuses the `active` would deadlock the single per-connection read loop (`handleNAK` runs inline under `readProviderLoop`).
- **Evidence:** Confirmed the asymmetry and the "currently safe" reasoning: `errs` is `make(chan error, 1)` and line 608 `removeActive` atomically takes sole ownership before the buffered-1 send, so it cannot block today. Confirmed at INFO.
- **Recommendation:** Use the same non-blocking `select`/`default` pattern at 609 for consistency and defense-in-depth.

### [LOW→INFO] Pillar-D output-size cap off-by-one: stream prematurely closed when output exactly equals the cap

- **Component:** Coordinator · Tier2 Attestation (coord-tier2)
- **File(s):** `phase4-coordinator/internal/tier2/pillar_d.go:296-302` (capChoiceContent); propagated via 105-119
- **Category:** logic-error
- **What:** In `capChoiceContent`, when content fits (`contentBytes <= remaining`), the code adds the bytes then checks `if g.outputBytes >= capBytes` and returns `true` (truncated) — even though no truncation occurred (the content exactly filled the budget). `CheckStreamingChunk` then sets `stop=true`, slices `events[:i+1]`, and appends a spurious `[DONE]`.
- **Impact:** A legitimate completion that exactly equals the cap is truncated one chunk early with a spurious `[DONE]`, and subsequent legitimate chunks are blanked. No money-loss or security bypass.
- **Evidence:** Logic confirmed (`>=` rather than `>`). **Downgraded LOW→INFO:** `pillar_d_test.go:33-58` asserts `stop=true` + `[DONE]` at the exact-cap boundary as the **intended** contract; the default cap is 1 MiB (a byte-exact landing is vanishingly improbable) and blanking post-cap content is the cap doing its job. The genuine defect is the cosmetic spurious `[DONE]`/one-chunk-early close at the boundary. Confirmed at INFO.
- **Recommendation:** Use `if g.outputBytes > capBytes` (or restructure `capChoiceContent` to return `false` when content was fully emitted), keeping `capClosed=true` so a *later* chunk triggers truncation. Add a regression test for the exact-cap boundary.

### [LOW→INFO] Certificate chain verification uses `ExtKeyUsageAny`, disabling EKU enforcement on the MDA chain

- **Component:** Coordinator · Tier2 Attestation (coord-tier2)
- **File(s):** `phase4-coordinator/internal/tier2/pillar_c.go:671-677`
- **Category:** trust-validation
- **What:** `verifyAttestationCertificateChain` calls `certs[0].Verify` with `KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny}`, accepting the leaf regardless of EKU. The only structural constraints are chaining to the operator root plus validity period; all attestation-specific assurance rests on the downstream MDA checks.
- **Impact:** The structural trust decision is "issued by the trusted root, any purpose" — broader than necessary, relying entirely on the extension/binding checks being complete and the operator root being narrowly MDA-scoped.
- **Evidence:** Code confirmed. **Downgraded LOW→INFO:** the chain check is one of seven sequential gates (leaf key, freshness via `ConstantTimeCompare`, device properties, CSR key binding, binding signature) that must all pass; a non-MDA cert from the same root would fail freshness/CSR-binding/binding-signature. The finding concedes `ExtKeyUsageAny` is "likely intentional" for Apple MDA leaves. Confirmed at INFO.
- **Recommendation:** Confirm against Apple MDA cert profiles whether a specific EKU or leaf-marker OID can be asserted; if so, replace `ExtKeyUsageAny`. If MDA leaves carry no usable EKU, document the rationale in a code comment and require operator docs to scope the configured root to MDA issuance.

### [INFO] Device-property check passes on the first non-blank recognized OID rather than asserting required properties

- **Component:** Coordinator · Tier2 Attestation (coord-tier2)
- **File(s):** `phase4-coordinator/internal/tier2/pillar_c.go:281-293` (verifyMDADeviceProperties), 485-498 (mdaExtensionValueBlank)
- **Category:** trust-validation
- **What:** `verifyMDADeviceProperties` returns success on the first present, non-blank recognized OID; it only fails if none are present or the first-found is blank. `mdaExtensionValueBlank` treats any non-empty bytes that don't decode to an empty string/octet-string as valid. No specific property (SIP, secure boot, kext status) is required, nor are values well-formedness-checked.
- **Impact:** A provider with a genuine root-anchored MDA leaf could include a single arbitrary recognized extension (e.g. just the serial number) and satisfy the gate without the coordinator validating which security-relevant properties are attested — narrowing the integrity signal. Bounded (requires a validly-chained leaf).
- **Evidence:** Confirmed the first-match `return ""` and the lax blank check; the recognized set includes SIP/secure-boot/kext OIDs but none is individually required. Still requires passing all other gates. Confirmed at INFO.
- **Recommendation:** Per SPEC-008 policy, check mandatory device-property OIDs explicitly and validate their decoded state against an allowed-state policy rather than accepting the first present-and-non-blank OID; tighten `mdaExtensionValueBlank` to validate the expected ASN.1 type per OID.

### [INFO] Dead code: `countReady` is never referenced

- **Component:** Coordinator · Explorer + RequestLog (coord-explorer)
- **File(s):** `phase4-coordinator/internal/explorer/store.go:545-553`
- **Category:** dead-code
- **What:** `func countReady(providers []pool.Provider) int` has zero call sites; `poolOverview` computes `ready_providers` inline instead.
- **Impact:** None; minor maintenance noise and latent risk that the two ready-count paths diverge.
- **Evidence:** `grep countReady` returns only the definition. `poolOverview` (`handlers.go:571-610`) computes `ready_providers` inline. Confirmed at INFO.
- **Recommendation:** Remove `countReady`, or wire `poolOverview` to use it for a single source of truth.

### [INFO] `decodeTime` silently swallows parse errors, producing zero-time that mis-sorts corrupt rows

- **Component:** Gateway · SQLite Storage (gw-storage)
- **File(s):** `phase5-gateway/internal/storage/sqlite/store.go:868-871`
- **Category:** error-handling
- **What:** `decodeTime` does `t, _ := time.Parse(time.RFC3339Nano, s)` and discards the error, returning zero-time on unparseable input. All timestamps are written via `encodeTime`, so this never triggers in normal operation. The security-relevant consumer `ConsumeOAuthState` fails safe; every other consumer silently coerces a bad timestamp to the epoch, mis-sorting that row.
- **Impact:** On DB corruption or out-of-band writes, affected rows render as `0001-01-01` and sort incorrectly in explorer cursors/feeds with no log/error. Expiry checks fail safe (no auth bypass); impact is silent data-quality degradation.
- **Evidence:** Confirmed the discarded error and the fail-safe `ConsumeOAuthState` path (`!now.Before(zero)` → treated as expired). Other consumers (`scanUsage`, reservation/activity timestamps) coerce silently. Confirmed at INFO.
- **Recommendation:** Have `decodeTime` log/surface parse failures (or return `(time.Time, error)`); at minimum emit a sentinel/metric when a stored timestamp fails to parse so corruption is observable.

### [LOW→INFO] `ExplorerListBuyers` indexes `out.Items[q.Limit-1]`; panics if a caller passes `Limit<=0`

- **Component:** Gateway · SQLite Storage (gw-storage)
- **File(s):** `phase5-gateway/internal/storage/sqlite/explorer.go:99-103`; same pattern at 214-218, 348-352
- **Category:** edge-case
- **What:** After fetching `Limit+1` rows, pagination does `out.Items[q.Limit-1]`; with `Limit==0` and a non-empty result this is `out.Items[-1]` → panic. Same pattern in `ExplorerListSessions` and `ExplorerActivity`.
- **Impact:** None today; all current callers pass `Limit>=1`. A future caller passing `Limit=0` with a non-empty result set would panic the request goroutine.
- **Evidence:** Mechanism confirmed but **unreachable:** `parseExplorerLimit` only overrides on `parsed > 0` (defaults 50, caps 200); the internal `explorerBuyerByID` hardcodes `Limit:1`. **Downgraded LOW→INFO.** Confirmed.
- **Recommendation:** Defensively clamp `Limit` at the top of each `Explorer*` method (`if q.Limit <= 0 { q.Limit = 1 }`).

### [INFO] Connection-scoped PRAGMAs depend on the single-connection pool; raising `MaxOpenConns` would silently drop WAL/foreign_keys/busy_timeout

- **Component:** Gateway · SQLite Storage (gw-storage)
- **File(s):** `phase5-gateway/internal/storage/sqlite/store.go:37-42`
- **Category:** concurrency
- **What:** `Open` sets `SetMaxOpenConns(1)`/`SetMaxIdleConns(1)` then runs the PRAGMA block once. In SQLite, `busy_timeout` and `foreign_keys` are per-connection; they persist only because the pool reuses one connection (including the `beginImmediate` path via `s.db.Conn`). Correctness of FK enforcement and the 5s busy-timeout silently hinges on `MaxOpenConns` staying 1.
- **Impact:** No current bug. A plausible future throughput change (raising the cap) would silently disable FK integrity and busy-timeout backoff on all but the first connection, with no test catching it.
- **Evidence:** Confirmed the pinned pool and the once-run PRAGMA `ExecContext`; `journal_mode`/`synchronous` are durable but `busy_timeout`/`foreign_keys` are per-connection (accurate for modernc.org/sqlite). `beginImmediate` draws from the same pool. Confirmed at INFO.
- **Recommendation:** Set the PRAGMAs via a connector hook so every connection inherits them, or append them to the DSN (`?_pragma=busy_timeout(5000)&_pragma=foreign_keys(on)`). Document that the single-conn pool is load-bearing for PRAGMA durability.

### [INFO] Single-version migration model has no incremental-migration path

- **Component:** Gateway · SQLite Storage (gw-storage)
- **File(s):** `phase5-gateway/internal/storage/sqlite/store.go:59-65`; `migrate.go`
- **Category:** migration-safety
- **What:** `Migrate` runs the entire `schemaSQL` blob (all `CREATE … IF NOT EXISTS`) then `INSERT OR IGNORE INTO schema_migrations VALUES(1, …)`. Nothing reads the current max version; there are no `ALTER TABLE` statements and no migration runner. `IF NOT EXISTS` skips already-created tables, so a column/constraint change cannot be expressed as a migration.
- **Impact:** No runtime defect today (schema is locked v1). The `schema_migrations` table gives a false impression of a versioned system; future schema evolution risks inconsistent application across environments.
- **Evidence:** Confirmed `Migrate` hardcodes version 1, never `SELECT MAX(version)`, and the blob contains only `CREATE … IF NOT EXISTS` (zero `ALTER`). Confirmed at INFO.
- **Recommendation:** Either document that the schema is single-version, additive-only, or implement a real migration runner that reads `MAX(version)` and applies an ordered list of versioned steps (including `ALTER`s) in a transaction.

### [INFO] Demo token TTL parameter is effectively dead — `Issue` is always called with 24h

- **Component:** Gateway · Auth/Config (gw-auth-core)
- **File(s):** `phase5-gateway/internal/auth/demo.go:31-35`; caller `internal/router/server.go:348`
- **Category:** dead-code
- **What:** `DemoManager.Issue` takes a `ttl` parameter but clamps `<=0` or `>24h` to exactly 24h; the sole production caller always passes `24*time.Hour`, so the parameter is vestigial in current wiring.
- **Impact:** Operators reading the signature may believe demo TTL is tunable; it is hardcoded. Maintainability/clarity only.
- **Evidence:** Confirmed the clamp (values in `(0,24h]` pass through, so not strictly dead at the function level) and that the only non-test caller passes 24h. Confirmed at INFO.
- **Recommendation:** Drive the TTL from config and pass it through, or drop the parameter and document the fixed 24h session lifetime.

### [LOW] `internal/auth` package has zero test coverage on all critical auth primitives

- **Component:** Gateway · Auth/Config (gw-auth-core)
- **File(s):** `phase5-gateway/internal/auth` (oauth.go, keys.go, demo.go — whole package)
- **Category:** missing-test-coverage
- **What:** `go test ./internal/auth/...` reports `[no test files]`. No unit tests for `GitHubProvider.Exchange`, `ScopesAllowed`/`splitScopes`, `KeyManager.Generate/Validate/Hash` (prefix gating, hmac-vs-sha256 modes), `DemoManager.Issue/Validate` (signature, expiry, IP binding, version), or `normalizeDemoIP` (the demonstrably broken IPv6 path).
- **Impact:** Regressions in token signing, scope enforcement, key hashing-mode selection, or IP normalization can ship undetected on primitives that gate billing identity and demo abuse limits. The IPv6 MEDIUM defect shipped precisely because a normalization round-trip test was absent.
- **Evidence:** Confirmed `[no test files]` and `find … -name '*_test.go'` returns nothing; all named primitives exist. Confirmed at LOW (test-debt, not itself an exploitable defect).
- **Recommendation:** Add table-driven tests for `demo.go` (round-trip Issue→Validate, tampered signature, expired token, wrong-IP rejection, IPv4/IPv6/mapped normalization), `keys.go` (prefix mismatch → `ErrNotFound`, hmac_sha256 vs sha256 hashes, Hash determinism), and `oauth.go` (`ScopesAllowed` allow/deny matrix, `splitScopes` on space/comma input, `Exchange` against an `httptest` server covering forbidden-scope and missing-user-id branches).

### [LOW→INFO] Self-update checksum manifest parser rejects `sha256sum --binary` (`*filename`) and BSD formats

- **Component:** Provider Binary · Self-Update + Attestation (bin-security)
- **File(s):** `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift:292-300`
- **Category:** correctness
- **What:** `expectedSHA256` splits each line on spaces/tabs and requires `parts[1] == filename` exactly. `sha256sum --binary` emits `<hash> *<filename>` (yielding `*macprovider-…`), and BSD `SHA256(name)= <hash>` has no matching line — both throw `checksumMissing` on a valid signed manifest.
- **Impact:** A one-character change in the release pipeline's checksum invocation would break every contributor's `update` with a confusing error despite a valid signed manifest.
- **Evidence:** Parser fragility real, but the actual pipeline (`.github/workflows/release.yml:95`) runs `shasum -a 256 … > checksums.txt` (text mode, `<hash>  <filename>`) — exactly what the parser handles; no binary/BSD form is used. **Downgraded LOW→INFO** (no triggering input today). Confirmed.
- **Recommendation:** Strip a leading `*` from the filename token before comparison and/or support the `SHA256(<name>)= <hash>` form; at minimum pin the exact `sha256sum` invocation so the format cannot drift.

### [LOW→INFO] `findBinary` requires exactly one file named `macprovider-cli` — extra copies break the update

- **Component:** Provider Binary · Self-Update + Attestation (bin-security)
- **File(s):** `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift:308-323`
- **Category:** correctness
- **What:** `findBinary` collects regular, executable, non-symlink files named exactly `macprovider-cli` and throws `missingExtractedBinary` unless `matches.count == 1`. A future tarball with a second such file (universal-binary layout, debug copy, nested dir) would fail hard.
- **Impact:** A benign change to release archive layout would silently break self-update for all clients on the new release.
- **Evidence:** Strict guard real, but the cited triggers do not apply to the actual archive: `package.sh` ships only `macprovider-cli` plus two `.bundle` dirs (which contain zero files named `macprovider-cli`); the dSYM is not included, and even if it were its DWARF copy is mode 644 (non-executable, excluded by the `isExecutable` filter); the asset is single-arch darwin-arm64. **Downgraded LOW→INFO** (hypothetical-future only). Confirmed.
- **Recommendation:** Anchor the expected path (e.g. require `./macprovider-cli` or `bin/macprovider-cli`) so extra copies elsewhere are ignored, or keep the strict check but enumerate matches in the error and add a multi-match unit test.

### [INFO] Dead code: `fetchText(from:)` is defined but never called

- **Component:** Provider Binary · Self-Update + Attestation (bin-security)
- **File(s):** `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift:143-149`
- **Category:** dead-code
- **What:** `fetchText(from:)` does an HTTP GET and returns the body as a string, but no call site references it (all fetches go through `download(from:to:)`).
- **Impact:** None functionally; maintenance noise and slightly larger attack-surface review burden in a supply-chain-critical file.
- **Evidence:** `grep fetchText` across `Sources/` and `Tests/` returns only the definition at line 143. Confirmed at INFO.
- **Recommendation:** Remove `fetchText`, or wire a call site and a test if intended for an upcoming path.

### [INFO] NAK `in_reply_to` uses the literal type string instead of `request_id` for invalid/duplicate inference requests

- **Component:** Provider Binary · Runtime/Inference (bin-runtime)
- **File(s):** `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:43, 61, 66`; contrast 49, 55
- **Category:** protocol-consistency
- **What:** On the missing-fields and duplicate-request-id paths, `sendNAK` is called with `inReplyTo: "inference_request"` (the type literal), whereas the tier2 decrypt-failure paths correctly use `inReplyTo: requestID`. For the duplicate-id case the real `requestID` is known (it is interpolated into the message) yet `in_reply_to` is still the generic type. A test (`InferenceRelayTests.swift:126`) locks the literal for the missing-fields case.
- **Impact:** The coordinator cannot correlate the duplicate-id/invalid-message NAK to the specific request via `in_reply_to` (it must parse the message string). No correctness or money impact; diagnostic friction only.
- **Evidence:** Confirmed the three literal-type sites vs. the two correct `requestID` tier2 sites; the duplicate-id branch (66) knows the real `requestID`. The missing-`request_id` branch (43) genuinely has no id yet, so the literal is defensible there. Confirmed at INFO.
- **Recommendation:** When `request_id` is known (duplicate-id branch at 66, and arguably the missing-body branch), set `in_reply_to` to the request_id for consistency with the tier2 path, updating the test expectation.

### [LOW→INFO] `install.sh` readiness substring grep can false-positive a superstring model id

- **Component:** Web Demo + Scripts (web-scripts)
- **File(s):** `/Users/augstar/macprovider-poc/phase3-binary/dist/install.sh:682-683`
- **Category:** logic-bug
- **What:** `grep -Fq "$model"` is an unanchored substring match against `/v1/models` JSON; a served id containing the requested one (e.g. `…-4bit` vs `…-4bit-DWQ`) would pass despite a different loaded model.
- **Impact:** Reports "Ready" for a mismatched model.
- **Evidence:** Mechanism real, but the collision does not exist for this installer's model set: the only selectable ids are three (`Llama-3.2-3B-Instruct-4bit`, `Qwen2.5-7B-Instruct-4bit`, `Qwen2.5-14B-Instruct-4bit`), none a substring of another (`7B` vs `14B` diverge before the shared suffix). The grep is also paired with an `owned_by macprovider` check, and the local CLI loads exactly the requested `--model`. **Downgraded LOW→INFO** (latent fragility, no triggering input today). Confirmed.
- **Recommendation:** Match the exact JSON `id` value rather than a substring.

## Cross-cutting themes

1. **Streaming settlement mis-classification on the money path.** The two highest-impact correctness defects share a root cause: stream-read termination is not disambiguated before billing. The coordinator's raw-HTTP path attributes a buyer cancel to a provider disconnect (provider paid zero), and the gateway settles any scanner error as `ok`. Both are operator/provider-triggerable, both touch USDC, and both are masked from logs. The coordinator's WS paths already get this right (the guard exists three lines away), proving the correct pattern is known and just not applied uniformly.

2. **Non-constant-time bearer-token comparison, repeated everywhere.** The operator/admin key is compared with native `==`/`!=` in at least five distinct sites — `gw-router:1933/1942`, `coord-explorer/handlers.go:502`, `coord-ws/server.go:1481`, `coord-billing/endpoints.go:61`, plus the dead `coord-core/tokens.go:34` helper — while `subtle.ConstantTimeCompare`/`hmac.Equal` is already used correctly in `buyer/server.go:2613`, `tier2/pillar_c.go:270`, and `auth/demo.go:53`. Practical remote exploitability is low (high-entropy key, network jitter), so each instance is low/medium individually, but the *pattern* is an internal-consistency failure on the highest-value secret across both services.

3. **Unbounded in-memory maps keyed by client identity with no eviction.** The same resource-leak shape recurs: `poolCheckLast` (coord-buyer, HIGH — unauthenticated + spoofable key), the explorer rate-limiter `stamps` (coord-explorer), the billing `lastEarnings` map, and the WS warmup `timers`. None has TTL/sweep/LRU eviction. Severity tracks reachability — only the unauthenticated, spoofable-key one is HIGH; the auth-gated or provider-bounded ones are low.

4. **Provider-supplied / untrusted inputs are validated inconsistently.** `requireInt` (coord-ws) skips the non-negativity bounds that `ParseDrainStatus` applies; the gateway demo IPv6 normalization mis-uses `net.IP`; the runtime validates request params then ignores them. The codebase repeatedly demonstrates it knows the right pattern in one place and omits it in an adjacent one.

5. **Operator-facing data integrity vs. enforcement integrity are correctly separated — but the reporting side has bugs.** Encouragingly, every "wrong number" defect (JOIN fan-out, inflated TPS, dead `requests_queued`, `request_log` PII) lands on operator dashboards/telemetry, never on the enforcement path (`dailyUsageTx`, `ComputeCredits`, the WS relay's real `shouldCancel`). The money-enforcement core is clean; the observability layer that operators steer by is where the inaccuracies concentrate.

6. **Latent footguns guarded only by convention or current wiring.** A large share of info/low findings are reachable only if a future change crosses an unstated invariant: `providerhttp.Client` (safe only because `Init` runs before serving), the single-connection PRAGMA durability, the `Limit<=0` slice panic, the checksum/`findBinary` archive-shape coupling, and the `harness.py` rotate race. These are not bugs today but are undocumented tripwires.

7. **Self-update outage compounding (provider tier).** The launchd-bootout-before-replace, missing subprocess timeouts, and unvalidated redirect chain interact: a failure or hang during update can leave a contributor Mac drained and stopped. Individually downgraded, but they share the update-flow blast radius and should be hardened together.

## Prioritized remediation roadmap

1. **Fix streaming settlement classification on the money path (highest priority).** Resolves *"Gateway settles truncated/failed SSE streams as a successful, billed `ok`"* and *"Raw-HTTP streaming path misclassifies buyer disconnect as a provider breaker fault."* Add the `scanner.Err()` check before the gateway success branch (settle `upstream_error`/`stream_truncated`, log it) and add the `r.Context().Err()` guard to the coordinator raw-HTTP read-error branch (return `wsForwardCancelled`, `FaultNone`). Land the gateway streaming error tests in the same batch — this resolves *"Streaming token-too-long / scanner-error path has no test coverage"* and prevents regression. Also apply the `r.Context().Err()` guard fix from *"Global `providerhttp.Client.Timeout` caps total streaming duration."*

2. **Lock down the unauthenticated public endpoint.** Resolves *"Public `/v1/pool/check` rate-limiter is keyed on spoofable `X-Forwarded-For` and never evicts."* Stop trusting `X-Forwarded-For` unless via a configured trusted-proxy hop (key on `RemoteAddr`/trusted-proxy depth), and bound `poolCheckLast` with a janitor/LRU. While in this code, evict empty entries in the billing `lastEarnings` map and the explorer `stamps` map — resolves *"Unbounded growth of per-provider rate-limiter map"* and *"Explorer rate-limiter map never evicts stale per-IP keys."*

3. **Fix operator-facing data integrity.** Resolves *"LEFT JOIN fan-out inflates per-buyer token usage/reserved totals"* (rewrite the two token SUMs as correlated subqueries + regression test) and *"IPv6 demo-client IP normalization misuses `net.IP`"* (build the /64 prefix correctly + table-driven tests). Add the `internal/auth` unit tests here — resolves *"`internal/auth` package has zero test coverage"* and is the test that would have caught the IPv6 defect.

4. **Standardize constant-time bearer comparison across both services (single pass).** Resolves the merged non-constant-time cluster: *"Operator/admin bearer token compared with non-constant-time string equality"* (gw-router 1933/1942), and the coordinator siblings at explorer `handlers.go:502`, WS `server.go:1481`, and billing `endpoints.go:61`. Introduce one shared `constantTimeBearer` helper, route all sites through it, and delete the dead `AuthorizedBearer` — resolves *"Dead `AuthorizedBearer` helper uses non-constant-time comparison."*

5. **Add data retention and input bounds.** Resolves *"`request_log` has no retention/pruning"* (configurable `DELETE … WHERE ts_utc < ?` + `VACUUM`; truncate/hash `buyer_ip`) and *"Provider-supplied routing metrics are never bounds-checked"* (reject negatives, enforce `slots_free <= slots_total`, clamp `max_context_tokens`/`max_concurrency`, mirroring `ParseDrainStatus`).

6. **Harden the provider self-update flow as one unit.** Resolves *"launchd agent booted out before binary replacement"* (stage+validate before bootout, or restart-on-failure via `defer`), *"No timeout on new-binary self-test or tar/openssl subprocesses"* (wall-clock deadlines on `runProcess`/`processOutput`), and *"Redirect target not re-validated after `validateDownloadURL`"* (re-validate each redirect hop).

7. **Runtime contract and control-plane reliability fixes.** Resolves *"Validated request parameters seed/penalties/response_format are silently ignored"* (wire them in or reject at parse time; enforce JSON mode), *"`mockprovider` double-closes `stopHB`"* (`sync.Once`), *"`send()` silently drops control messages on backpressure"* (log + fallback `conn.Close()` on dropped cancel), *"Local HTTP inference path leaks tasks"* and *"Local HTTP chat-completions path has no concurrency limit"* (channelInactive cancellation + bounded admission + timeout), and *"Token revocation by 6-char prefix"* (resolve by full hash or reject `affected>1`).

8. **Robustness, accuracy, and clarity cleanups (low/info, batch opportunistically).** Resolves the remaining correctness/accounting items: WS upgrade-before-auth ordering, `RefundRequest` LIFO mismatch, warmup-timer cleanup, `estimateTokens` over-counting, `stickyStore` O(n) eviction, `ReserveQuota` UNIQUE sentinel, hop-by-hop header stripping, empty-challenge attestation guard; telemetry accuracy (`requests_queued`, throughput divisor, streaming delta reconciliation); the latent footguns (`providerhttp.Client` atomic/doc, PRAGMA connector hook, `Limit<=0` clamp, checksum-format/`findBinary` tolerance, `harness.py`/`companion.py` locking-and-timestamp fixes); the defense-in-depth bounds (`ParseShareBps`/`ParseMultiplierPPM` clamps, `operator_share_bps` validation, device-property/EKU tightening); and the dead-code/clarity removals (`countReady`, `fetchText`, hot-path `attempt_n`, blocking `active.errs` send, NAK `in_reply_to`, demo TTL, `decodeTime` logging, migration-model documentation, Pillar-D exact-cap boundary).
