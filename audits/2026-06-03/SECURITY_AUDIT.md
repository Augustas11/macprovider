# Security Audit

**Repository:** `macprovider-poc` · **Date:** 2026-06-03 · **System under review:** P2P AI-inference marketplace settling real USDC across a Swift provider binary (untrusted contributor Macs), a Go coordinator (trusted money authority), and a Go gateway (internet edge).

This audit was conducted as a multi-agent review, one lens per component (Coordinator Billing/Settlement, Buyer API, WebSocket Relay, Tier-2 Attestation, Explorer/RequestLog, Auth/Config/CMD; Gateway Router, SQLite Storage, Auth/Config; Provider Binary Self-Update, Runtime/Inference; Web Demo/Deploy/Python), followed by an adversarial verification pass that re-read every cited line, confirmed or rejected exploitability, removed false positives, and assigned an `adjustedSeverity` per finding. The severities below are the post-verification adjudicated severities, not the raw reporter severities. Every claim is grounded in `file:line` evidence captured during verification.

## Executive summary

The system's cryptographic and authorization primitives are largely sound — operator routes are gated, attestation chains terminate at operator-pinned Apple roots, the supply-chain update path is signature-gated, and the money-path SQL uses `BEGIN IMMEDIATE` to prevent double-spend. The dominant risk is not broken crypto but a **payment-integrity trust boundary that is repeatedly crossed: provider self-reported token counts and buyer-controlled request identifiers flow into the USDC settlement path with no independent metering or idempotency**. Three of the four High findings are money-integrity or availability defects on the coordinator (the trusted money authority), and the fourth is an environment-overridable signing key that converts environment-poisoning on a contributor Mac into persistent RCE. A recurring secondary theme is non-constant-time operator-key comparison duplicated across five files; verification consistently downgraded the remote-timing exploitability to Low but confirmed the inconsistency is real and the fix is trivial and shared. A third theme is missing connection/time bounds on internet-facing and hijacked sockets (gateway slow-body, WebSocket pre-auth slowloris and unbounded frames). **Fix first: stop paying providers on unverified self-reported token counts and stop letting buyers pick the billing `request_id`** — these two High findings (`coord-billing` payout and `coord-buyer` X-Request-ID) are the only paths in scope that directly move or zero out real money, and the X-Request-ID free-inference path is trivially exploitable by any normal authenticated client end-to-end through the public gateway.

## Severity overview

| Severity | Count |
|----------|-------|
| Critical | 0 |
| High | 4 |
| Medium | 7 |
| Low | 27 |
| Info | 9 |
| **Total** | **47** |

## Findings

### [HIGH] Provider payout is billed on self-reported, unverified token counts

- **Component:** Coordinator · Billing/Settlement (also affects Coordinator · Buyer API and the provider binary's self-reported usage; see the Medium buyer-layer finding and the Info trust-boundary notes below)
- **File(s):** `phase4-coordinator/internal/billing/formula.go:86-174` (ComputeCredits), `:176-178` (`maxBillableTokens=10,000,000`); `phase4-coordinator/internal/buyer/server.go:1539`, `:2766-2778`; `phase4-coordinator/internal/billing/store.go:65` (`attestation_class`)
- **Category:** payment-integrity / money-math
- **What:** `ComputeCredits` treats `usage_source='provider_reported'` token counts as ground truth and converts them directly into `provider_credits`. Those counts originate from the untrusted provider's WebSocket `end` frame (`server.go:1539` parses `prompt_tokens`/`completion_tokens` with no bounds, `server.go:2766-2778`). The only gate is `invalidBillableTokenCount()`, which rejects only `v<0 || v>10,000,000`. Byte-derived estimation is used solely as a fallback when the provider reports nothing (`server.go:1548-1550`), never to cap a value the provider *did* report. The `attestation_class` column declared at `store.go:65` is never written by any INSERT (the hot-path INSERT at `hotpath.go:192-199` omits it), so no attestation gate exists.
- **Impact:** A malicious or compromised onboarded provider can over-report `completion_tokens` (up to 10M per field, per request) to inflate `provider_credits` and its real-USDC payout at settlement, over-billing buyers and draining operator funds. This is the marketplace's core payout-integrity boundary.
- **Evidence:** Verified end-to-end. `server.go:1539` assigns provider-reported tokens verbatim; `formula.go:124-134` forces `UsageSource='provider_reported'` and uses `*completionTokens` as-is, gated only by `invalidBillableTokenCount` (`formula.go:176-178`). `estimatedCompletionTokensFromBytes` is guarded by `if attempt.CompletionTokens == nil` (`server.go:1548-1550`) so it never caps a reported value on the success path. `zeroTokenFault` (`server.go:2730-2741`) only detects under-reporting, not inflation. `grep` confirms `attestation_class` has only the schema decl and two read sites (`endpoints.go:110`, `:143`) — write-never. Exploitation requires an authenticated provider (fits the threat model), not an anonymous attacker.
- **Recommendation:** Do not pay providers purely on self-reported usage. Cap/validate `provider_reported` `completion_tokens` against `estimatedCompletionTokensFromBytes` with a tolerance band; quarantine rows whose reported tokens exceed the byte estimate by more than X%; and/or require a signed attestation (actually populate `attestation_class`) before honoring `provider_reported`. Lower `maxBillableTokens` to a realistic per-request ceiling rather than 10M.

### [HIGH] Buyer-controlled X-Request-ID drives billing idempotency, enabling free inference

- **Component:** Coordinator · Buyer API (the gateway forwards the client value verbatim — see Evidence)
- **File(s):** `phase4-coordinator/internal/buyer/server.go:801-804`, `:830-848`, `:887`, `:2832-2839`; `phase4-coordinator/internal/billing/hotpath.go:54-118`; `phase4-coordinator/internal/requestlog/store.go:88-110`; `phase5-gateway/internal/router/server.go:168-171`, `:1349`
- **Category:** money-math / idempotency
- **What:** `handleChatCompletions` takes the caller's `X-Request-ID` (`server.go:801`), echoes any valid UUIDv4 verbatim via `requestIDForBuyerRequest` (`server.go:2832-2839`), and uses it as the billing `request_id`. `request_log.request_id` has no UNIQUE constraint (only a non-unique index, `store.go:88-110`). `WriteHotPath` inserts the row first then derives `attempt_n` from `SELECT COUNT(*) ... WHERE request_id=?` (`hotpath.go:54-56`); for any derived `attempt_n>0`, it runs `zeroCredits(result)` and inserts a quarantined zero-credit row (`hotpath.go:75,107`). A buyer can therefore submit many genuinely distinct, successfully-served paid requests all carrying one fixed UUIDv4; every request after the first is billed at **zero** gross/provider/operator credits.
- **Impact:** Trivial, unprivileged-by-normal-client free inference: direct USDC revenue loss to the operator and under-payout to providers, reachable through the public chat path.
- **Evidence:** Traced end-to-end including the gateway. For the Nth distinct request reusing one UUIDv4, the count includes the just-inserted row, so `derived=N-1`; for N≥2 the ambiguous branch (`hotpath.go:56-86`) zero-credits and inserts a quarantined row with no operator credit. Critically, the gateway does **not** regenerate a valid client UUID: middleware keeps the client `X-Request-ID` whenever `isUUIDLike(requestID)` is true (`router/server.go:168-171`) — a valid UUIDv4 passes through — and forwards it verbatim to the coordinator (`router/server.go:1349`). Exploit is reachable with no special privilege.
- **Recommendation:** Do not let the client choose the billing identity. Generate the billing `request_id` server-side (`uuid.NewString`) and keep `X-Request-ID` only as an opaque correlation field that never feeds attempt derivation. Alternatively make `(request_id, attempt_n)` a UNIQUE/idempotency key whose first write wins, return HTTP 409 (or fully re-bill, never zero-credit) on collisions from distinct payloads, and verify a body hash before collapsing two ids into one logical request. Ensure the gateway overwrites `X-Request-ID` so the client cannot pin it.

### [HIGH] No read/idle deadline or frame-size limit on hijacked provider WebSocket (pre-auth slowloris + unbounded-buffer DoS)

- **Component:** Coordinator · WebSocket Relay
- **File(s):** `phase4-coordinator/internal/ws/server.go:168-181`, `:211-244`, `:611-624`; `phase4-coordinator/cmd/coordinator/main.go:181-189`
- **Category:** dos
- **What:** `handleProvider` calls `gobwas.UpgradeHTTP` (`server.go:169`), hijacking the `net.Conn`; after hijack the `http.Server` `ReadTimeout`/`IdleTimeout`/`ReadHeaderTimeout` from `newHTTPServer` (`main.go:185-187`) no longer apply. No `SetReadDeadline`/`SetWriteDeadline` is ever set in production WS code. The first auth read `wsutil.ReadClientData(conn)` (`server.go:221`) blocks indefinitely, and the liveness monitor starts only **after** post-auth session registration (`registerProviderSession`, `server.go:607`). Additionally `ReadClientData` in `readProviderLoop` (`server.go:613`) reads an entire text frame into memory with no max-frame cap (contrast `io.LimitReader(resp.Body, 1<<20)` at `server.go:909`).
- **Impact:** Two unauthenticated DoS vectors against the internet-facing edge of the trusted money authority: (1) slowloris / half-open goroutine + FD exhaustion via pre-auth connections that send nothing; (2) memory exhaustion / OOM via a single multi-GB text frame buffered whole.
- **Evidence:** Verified: hijack semantics confirmed; `grep` shows `SetReadDeadline`/`SetWriteDeadline` only in `*_test.go`, never in production. `server.go:221` is the first auth read with no preceding deadline; the reaper `monitorHeartbeat` (`server.go:1212`, closes at `:1245`) is reached only post-auth via `handleV1Conn:268`. No `MaxFrameSize` anywhere in `internal/ws`.
- **Recommendation:** Immediately after `UpgradeHTTP`, set an initial handshake `SetReadDeadline` (~10s); in `readProviderLoop`, reset `SetReadDeadline` each iteration to `heartbeatInterval * missThreshold`; set `SetWriteDeadline` before each write. Enforce a maximum frame size via a `wsutil.Reader` configured with `MaxFrameSize` (or `io.LimitedReader` + reject oversize). Cap in-flight unauthenticated upgrades.

### [HIGH] Pinned update-signing public key is overridable via environment variable, defeating the supply-chain root of trust

- **Component:** Provider Binary · Self-Update (Swift) (paired with the releases-URL override, Low, below)
- **File(s):** `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift:245-263`, `:7-12`, `:82-93`, `:92`, `:159-173`, `:203-212`
- **Category:** supply-chain
- **What:** `verifyChecksumSignature()` reads the verification key from `environment["MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM"] ?? Self.checksumPublicKeyPEM` (`:247`) — the env var unconditionally overrides the embedded key, with no `#if DEBUG` guard. The embedded `checksumPublicKeyPEM` (`:7-12`) is the sole root of trust: the `openssl dgst -sha256 -verify` step (`:250-259`) is the only authenticator of `checksums.txt`, which gates the tarball SHA-256 at `:82-93`. An attacker who can set one env var in the provider's process environment (poisoned LaunchAgent plist, compromised shell profile, malicious wrapper) substitutes their own key, points `MACPROVIDER_RELEASES_API_URL` at their server, and serves a self-consistent malicious release.
- **Impact:** Persistent RCE / supply-chain compromise on the contributor Mac: the attacker binary is executed (`:92`), atomically installed over the live binary (`:159-173`), and relaunched under launchd (`:203-212`), inheriting the provider's coordinator session, ECDH/attestation private keys, and money-bearing state.
- **Evidence:** `:247` read verbatim; no `#if DEBUG`/`RELEASE` guard anywhere (grep empty), `Package.swift:65-67` strips nothing in release; the env override is live in production and wired into `scripts/test-tier2-provider-release.sh:131-178`. Kept High rather than Critical because exploitation requires the attacker to already control the victim's process environment (write to the user's Library / launch wrapper), which already implies user-level code execution.
- **Recommendation:** Treat the signing key as a non-overridable compile-time constant; remove the env branch (or gate it behind a build-time DEBUG flag absent in release). For rotation, ship multiple pinned keys and roll via signed releases, never env. Prefer CryptoKit `P256.Signing.PublicKey` against the embedded PEM over shelling out to `openssl` with a temp-file key.

### [MEDIUM] Provider-reported usage tokens pass through the buyer layer unclamped against actual request size

- **Component:** Coordinator · Buyer API (companion to the High billing finding; same money path, distinct code layer)
- **File(s):** `phase4-coordinator/internal/buyer/server.go:1204`, `:1400-1404`, `:2756-2778`, `:2780-2792`; `phase4-coordinator/internal/billing/formula.go:16`, `:176-177`
- **Category:** money-math
- **What:** `tokenPointersFromUsageObject` (`:2766-2778`) and `tokenPointersFromChatResponse` (`:2756-2764`) return provider-supplied token pointers with no bound, handed straight to billing on both the non-stream HTTP path (`:1204`) and the WS non-stream path (`:1400-1404`). The `maxRequestLogUsageTokens` (1e7) clamp applies **only** to the byte-estimate path (`:2788-2789`), not the provider-reported path; within `[0,1e7]` the provider's counts are billed verbatim and never reconciled against prompt size or emitted bytes.
- **Impact:** Over-bill / payout inflation from an untrusted provider, bounded by the 10M-per-field cap and the rate card, per-request rather than unbounded.
- **Evidence:** Confirmed by reading token-extraction and formula code; `maxRequestLogUsageTokens=10000000` (`server.go:116`) is applied only inside `estimatedCompletionTokensFromBytes`. Requires a malicious/buggy provider, not an anonymous attacker — hence Medium.
- **Recommendation:** Cross-check provider-reported usage at the buyer layer: clamp `completion_tokens` to the byte-estimate plus tolerance, clamp `prompt_tokens` to an estimate from the actual request body, and quarantine responses whose reported usage is implausibly larger than observed bytes. Lower the absolute per-field ceiling toward realistic context limits.

### [MEDIUM] Session writer can block indefinitely on a single slow/stuck provider (no write deadline)

- **Component:** Coordinator · WebSocket Relay
- **File(s):** `phase4-coordinator/internal/ws/relay.go:98-106`, `:118-130`, `:195`
- **Category:** resource-leak
- **What:** `runWriter` calls `wsutil.WriteServerText(ps.conn, payload)` with no write deadline (`:98-106`). If a provider stops reading, the kernel send buffer fills and the write blocks, hanging the writer goroutine. `send()` (`:118-130`) is non-blocking, so buffered control messages (drain/cancel/blacklist, e.g. `cancelActive` at `:195`) queue and may never reach the stuck peer.
- **Impact:** A single misbehaving provider pins a writer goroutine and starves delivery of operator control frames, degrading control and contributing to goroutine accumulation; combined with the missing read deadline (High WS finding) this widens the DoS surface.
- **Evidence:** Verified no `SetWriteDeadline`/`writeTimeout` in production relay/server. Mitigated to Medium: `monitorHeartbeat` (`server.go:1245`) independently closes the conn past the inactivity threshold, so the goroutine is held for up to the heartbeat-miss window, not literally forever.
- **Recommendation:** Call `ps.conn.SetWriteDeadline(time.Now().Add(writeTimeout))` before each `wsutil.WriteServerText`; on timeout treat it as a write failure (`failAll` + `conn.Close`), as already done on error.

### [MEDIUM] request_log retains buyer IP and preference headers (PII) with no retention/pruning

- **Component:** Coordinator · Explorer + RequestLog
- **File(s):** `phase4-coordinator/internal/requestlog/store.go:85-115`, `:144-188`; `phase4-coordinator/internal/explorer/store.go:61-68`; `phase4-coordinator/internal/billing/recovery.go`
- **Category:** pii-retention
- **What:** `request_log` persists `buyer_ip` (PII), `pref_header`, and `provider_header` per request (`store.go:100,103-104`). The store layer only ever CREATE/ALTER/INSERTs — there is no DELETE, TTL, or VACUUM for this table anywhere (`grep` for `DELETE FROM request_log` returns zero matches; the only retention knob, `provisional_retention_days`, is unrelated). The explorer returns `buyer_ip` to operators (`explorer/store.go:65`), and billing recovery depends on these rows (`recovery.go`), so naive deletion is unsafe.
- **Impact:** Buyer source IPs (linkable to USDC-spending accounts) and request preference headers are retained indefinitely, increasing breach blast radius and creating GDPR/CCPA data-minimization and right-to-erasure exposure; the table also grows unbounded, a slow availability/disk risk on the money coordinator.
- **Evidence:** Full store layer read; repo-wide `grep` confirms no DELETE/TTL/VACUUM/expiry job. PII egress to operators confirmed at `explorer/store.go:61-68`; billing dependency confirmed at `recovery.go:52,59,67,80,84,87`.
- **Recommendation:** Add a configurable retention job that deletes/anonymizes `request_log` rows older than the window (coordinating with `billing.recovery` so settled rows survive long enough); consider truncating/hashing `buyer_ip`. Document the retention period and add it to config validation.

### [MEDIUM] Go standard-library CVEs are call-path-confirmed (govulncheck) in the coordinator build

- **Component:** Coordinator · Auth/Config/Pool/CMD
- **File(s):** `phase4-coordinator/go.mod:3` (`go 1.22` directive, built with go1.26.3), `:23` (`golang.org/x/sys v0.22.0`); reachable via `cmd/coordinator/main.go:141` and `internal/tier2/pillar_c.go:671` / `cmd/tier2-mda-artifact/main.go`
- **Category:** supply-chain
- **What:** `govulncheck ./...` reports two stdlib vulnerabilities whose symbols are reached: **GO-2026-5037** (quadratic candidate-hostname parsing in `crypto/x509`) reachable from the attestation chain verifier (`pillar_c.go:671` `x509.Certificate.Verify`) on **provider-supplied** certificate chains, and **GO-2026-5039** (`net/textproto` includes unescaped inputs in errors) reachable from the HTTP servers (`main.go:141` → `ReadMIMEHeader`). Both are fixed in go1.26.4. (GO-2026-5038/`mime` and GO-2026-5024/`x/sys` are not in the call path.)
- **Impact:** The x509 quadratic path is reachable from untrusted provider attestation chains, enabling CPU-amplification DoS against the trusted coordinator during admission; the textproto issue can surface attacker bytes unescaped in error paths.
- **Evidence:** `govulncheck` reproduced with the exact traces; `go version` = go1.26.3; reachability of `x509.Verify` from untrusted input corroborated via `ws/server.go:382` → `VerifyAttestationToken` → `verifyAttestationCertificateChain` → `certs[0].Verify`. Kept Medium: the x509 path requires production-MDA roots configured and several prior guards (size caps `pillar_c.go:94,107`; format/challenge/expiry `:103-142`) before `Verify`, and the fix is a routine toolchain bump.
- **Recommendation:** Rebuild and ship with Go ≥ 1.26.4; bump `golang.org/x/sys` to ≥ v0.44.0. Add `govulncheck ./...` to CI as a release gate.

### [MEDIUM] Gateway HTTP server has no ReadTimeout / IdleTimeout — unauthenticated slow-body DoS

- **Component:** Gateway · Router/HTTP edge
- **File(s):** `phase5-gateway/cmd/gateway/main.go:64-68`; `phase5-gateway/internal/router/server.go:568`, `:602`, `:609`
- **Category:** dos
- **What:** The internet-facing `http.Server` sets only `ReadHeaderTimeout: 10s` — no `ReadTimeout`, `IdleTimeout`, `WriteTimeout`, or `MaxHeaderBytes` (`main.go:64-68`). `handleFeedback` decodes the JSON body (`server.go:568`) **before** authenticating the non-playground scope (`server.go:609`), so `/v1/feedback` is reachable unauthenticated and blocks in `json.Decode` on a slow body. `MaxBytesReader` caps bytes, not wall-clock time.
- **Impact:** An unauthenticated remote attacker opens many connections, sends headers within 10s, then trickles bodies, each pinning a goroutine indefinitely; enough parallel connections degrade or deny service.
- **Evidence:** Struct literal confirmed with only `ReadHeaderTimeout`; `handleFeedback` ordering confirmed (Decode at `:568`, `requireBearer` at `:609`). The coordinator `http.Client` timeouts (`main.go:56-61`) bound the outbound client, not inbound bodies. Medium: resource-exhaustion only, typically also fronted by an upstream LB at `coordinator.malibu.tech`.
- **Recommendation:** Set `ReadTimeout` (~30s), `IdleTimeout` (~120s), and `MaxHeaderBytes` (`1<<16`). Do **not** set a global `WriteTimeout` (SSE streams are long-lived) — bound non-streaming handlers individually or via per-request context deadlines, and apply a request-scoped read deadline before the unauthenticated `json.Decode` in `handleFeedback`.

### [MEDIUM] Connection-scoped SQLite PRAGMAs can be silently lost on pool connection recreation

- **Component:** Gateway · SQLite Storage
- **File(s):** `phase5-gateway/internal/storage/sqlite/store.go:33-49`, `:848-858`; `phase5-gateway/internal/storage/sqlite/migrate.go:20`, `:44`
- **Category:** integrity-config
- **What:** `Open()` sets `busy_timeout`, `foreign_keys`, `journal_mode`, `synchronous` via a one-time post-`sql.Open` `ExecContext` (`store.go:39`), not in the DSN (`store.go:33` opens a plain path). `busy_timeout` and `foreign_keys` are connection-scoped; the pool is `SetMaxOpenConns(1)/SetMaxIdleConns(1)` but `ConnMaxLifetime`/`ConnMaxIdleTime` are unlimited, and `database/sql` will transparently re-open a fresh driver connection on a bad-conn error. The replacement runs with SQLite defaults — `foreign_keys OFF`, `busy_timeout 0`. Every money-path tx pulls a connection via `beginImmediate()` → `db.Conn(ctx)` (`store.go:848-858`).
- **Impact:** If the pool rebuilds its connection, FK constraints stop being enforced (orphan `api_keys`/`account_identities` become insertable; schema relies on FKs at `migrate.go:20,44`) and `busy_timeout` drops to 0 (immediate `SQLITE_BUSY` instead of a 5s wait), degrading money-path writes under contention — silent and intermittent.
- **Evidence:** `grep` confirms no `_pragma`/`busy_timeout`/`foreign_keys` outside the single `ExecContext`; `ConnMaxLifetime`/`ConnMaxIdleTime` zero hits. `journal_mode=WAL` is DB-persistent and survives. Driver `modernc.org/sqlite v1.33.0` supports `_pragma` DSN params. Medium: latent, probabilistic (not attacker-triggerable), and `MaxOpenConns(1)` makes recreation uncommon.
- **Recommendation:** Put connection-scoped PRAGMAs in the DSN, e.g. `file:<path>?_pragma=busy_timeout(5000)&_pragma=foreign_keys(ON)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)`, or register a connection hook applying them per-connection. Do not rely on a single post-Open `ExecContext`.

### [MEDIUM] Gateway operator-key compared with non-constant-time string equality

- **Component:** Gateway · Router/HTTP edge (this is the gateway instance of the cross-component non-constant-time operator-key theme; also affects the gateway storage/explorer auth barrier and the consolidated gateway-auth-core finding, all kept Low — see below)
- **File(s):** `phase5-gateway/internal/router/server.go:1932-1945` (compare at `:1933`, repeated at `:1942`)
- **Category:** crypto-timing
- **What:** `operatorAuthorized` authenticates every privileged admin route with plain `==`: `r.Header.Get("Authorization") == "Bearer "+s.cfg.Coordinator.OperatorKey` (`:1933`), repeated in `shouldPersistInternalHeaderAudit` (`:1942`). This is the only non-constant-time credential check in the gateway — API keys use a hash lookup (`auth/keys.go`) and demo tokens use `hmac.Equal` (`auth/demo.go:53`).
- **Impact:** A theoretical byte-at-a-time timing recovery of the operator key, which gates the global kill switch (`/admin/kill-switch`), capacity-tier control, the buyer-PII explorer (`/admin/explorer/*`, accepts `email`/`account_id`), and is reused as the gateway's coordinator bearer (`server.go:1359`).
- **Evidence:** Both `==` sites confirmed; blast radius confirmed via route registration `server.go:150-160` and `explorer.go:246-256`/`:173-191`. Kept Medium (not downgraded) because the blast radius is severe and the fix is trivial; practical remote exploitability is genuinely low (recovering a high-entropy key over TLS + jitter requires an enormous, likely infeasible sample count).
- **Recommendation:** Pre-derive the expected header and compare via `crypto/subtle.ConstantTimeCompare`, ideally after SHA-256-hashing both sides to a fixed length so length is not leaked; apply the same fix at `:1942`. Consider a dedicated gateway-admin credential distinct from the coordinator `OperatorKey`. Factor this into one shared helper used by all operator-key sites.

### [LOW] Admin ledger auth fails open when operator key is empty

- **Component:** Coordinator · Billing/Settlement
- **File(s):** `phase4-coordinator/internal/billing/endpoints.go:61-65`; mitigated by `phase4-coordinator/internal/config/config.go:397-400`, `:568-571`; `cmd/coordinator/main.go:115-116`
- **Category:** authz
- **What:** The guard `if h.operatorKey != "" && r.Header.Get("Authorization") != "Bearer "+h.operatorKey` short-circuits the entire condition when `operatorKey == ""`, allowing the request with no auth — the handler fails **open**.
- **Impact:** If the operator key is ever empty at the handler layer, `/admin/ledger/summary|providers|reconcile` become fully unauthenticated, exposing all provider earnings/totals and allowing reconcile runs.
- **Evidence:** Fail-open branch confirmed at `endpoints.go:61`. The mitigation is real and load-bearing: `config.Validate` rejects an empty `operator_key` (`config.go:397-400`, `:568-571`), and `main.go:115-116` passes it only after config load — so the shipped binary is safe. Confirmed Low: a defense-in-depth gap, not an exploitable production bug.
- **Recommendation:** Fail closed: if `h.operatorKey == ""` reject all admin requests (403) so handler safety does not depend on an external validator.

### [LOW] Internal error strings echoed to HTTP clients

- **Component:** Coordinator · Billing/Settlement
- **File(s):** `phase4-coordinator/internal/billing/endpoints.go:117`, `:128`, `:166`, `:171`, `:177`, `:188`, `:194`, `:210`, `:522-524`
- **Category:** information-disclosure
- **What:** Handlers return raw `err.Error()` to the caller via `writeError(w, 500, "internal_error", err.Error())`; `modernc.org/sqlite` errors can leak SQL fragments, column names, and schema details.
- **Impact:** Leaks internal schema/SQL details that aid an attacker who has or is brute-forcing the operator key.
- **Evidence:** All eight lines confirmed to pass raw `err.Error()` into the JSON `error.message` (`writeError` at `:522-524`). All are inside `providers()`/`reconcile()`, reachable only through `h.admin` operator-bearer gate (`:43-48`, `:56-66`). Note: bind is loopback (`config.go:220`) but nginx proxies `/admin/*` publicly (`dist/coordinator.yaml:3`), so "localhost-only" overstates isolation — still operator-gated, so Low.
- **Recommendation:** Log the detailed error server-side; return a generic `"internal error"` message to the client.

### [LOW] Operator admin key compared with non-constant-time string equality (billing)

- **Component:** Coordinator · Billing/Settlement (instance of the cross-component operator-key timing theme; see the consolidated coordinator-core finding below)
- **File(s):** `phase4-coordinator/internal/billing/endpoints.go:61`
- **Category:** timing-side-channel
- **What:** Admin auth uses Go `!=` string comparison, which short-circuits on the first differing byte, against the high-value operator credential gating `/admin/ledger/summary|providers|reconcile`. The same codebase already uses `subtle.ConstantTimeCompare` (`buyer/server.go:2613`, `tier2/pillar_c.go:270`).
- **Impact:** Theoretically allows byte-by-byte timing recovery of the operator key (full ledger read + reconcile trigger).
- **Evidence:** `endpoints.go:61` confirmed; inconsistency with the constant-time pattern confirmed. Downgraded medium→low: `/admin/*` is reachable over the internet via nginx (`dist/coordinator.yaml:2-4`), but that means an attacker measures across TLS+nginx+jitter, swamping the sub-microsecond signal; the key is 256-bit (`openssl rand -hex 32`, `coordinator.yaml:44-45`), making recovery infeasible.
- **Recommendation:** `subtle.ConstantTimeCompare([]byte(header), []byte("Bearer "+h.operatorKey)) == 1`, matching the existing pattern.

### [LOW] Unauthenticated /v1/pool/check: spoofable XFF rate limit over an unbounded, never-evicted map

- **Component:** Coordinator · Buyer API
- **File(s):** `phase4-coordinator/internal/buyer/server.go:72`, `:583-641`, `:617-627`, `:629-641`
- **Category:** dos
- **What:** `handlePoolCheck` is rate-limited only by `allowPoolCheck`, keyed on `clientIP(r)`, which returns the attacker-supplied first `X-Forwarded-For` value before falling back to `RemoteAddr` (`:629-641`). The state map `s.poolCheckLast` is only Load-ed/Store-d, never pruned/TTL'd/size-capped (`:620`, `:625`), so it grows unbounded.
- **Impact:** Memory-exhaustion DoS — but **local-only**.
- **Evidence:** XFF-leftmost behavior and unbounded map confirmed. Downgraded high→low: the buyer port binds `127.0.0.1` (`config/config.go:220`), and the public gateway does **not** proxy `/v1/pool/check` (full mux is `/auth/demo-session`, `/v1/models`, `/v1/chat/completions`, `/v1/sticky`, `/v1/status` — `router/server.go:138-147`) nor set/forward `X-Forwarded-For`. Reachable only from the coordinator's loopback (co-located process or SSRF).
- **Recommendation:** Do not trust `X-Forwarded-For` for rate-limiting unless from a configured trusted proxy hop; replace the unbounded `sync.Map` with a bounded TTL/LRU limiter and cap total tracked keys.

### [LOW] X-MacProvider-Account trusted unauthenticated for sticky attribution and cross-account purge

- **Component:** Coordinator · Buyer API
- **File(s):** `phase4-coordinator/internal/buyer/server.go:512-529`, `:2404-2449`, `:2584-2596`; mitigations at `phase5-gateway/internal/router/server.go:1359`, `:2209+`
- **Category:** authz
- **What:** The buyer server treats `X-MacProvider-Account` as an authenticated identity with no verification: `stickyStore` writes `AccountID` from the header (`:2436`), and `handleInternalStickyDelete`→`purgeStickyAccount` deletes all sticky entries matching an attacker-suppliable `account_id` (`:512-529`, `:2439-2449`).
- **Impact:** Forged account attribution into sticky metadata; cross-account sticky purge.
- **Evidence:** Code confirmed. Downgraded medium→low: (1) `handleInternalStickyDelete` is bearer-gated up front via `subtle.ConstantTimeCompare` (`:513`), so cross-account purge needs the operator key; (2) the gateway does not forward a client `X-MacProvider-Account` — `copyForwardHeaders` forwards only `Accept` and `X-MacProvider-Retry` (`router/server.go:2209+`), and the account header reaching the coordinator is set from the authenticated `subject.AccountID` (`router/server.go:1359`); (3) billing keys on request/provider, not account, so forged attribution moves no money. Residual effect is sticky-metadata mislabeling reachable only via direct loopback access.
- **Recommendation:** Derive account identity from a signed token the coordinator validates (HMAC/JWT set by the gateway after auth), not a client-settable header. Enforce that the gateway strips inbound `X-MacProvider-Account` from external clients.

### [LOW] No in-process authn and no WriteTimeout on the buyer API (loopback + gateway is the sole trust boundary)

- **Component:** Coordinator · Buyer API (amplifier precondition for the two Low buyer findings above)
- **File(s):** `phase4-coordinator/internal/buyer/server.go:331-338`, `:800-805`; `phase4-coordinator/cmd/coordinator/main.go:126`, `:181-189`; `config/config.go:220`
- **Category:** authz
- **What:** `Server.Handler()` registers `/v1/chat/completions`, `/v1/models`, `/v1/pool/check`, `/healthz` with no auth middleware (`:331-338`); `handleChatCompletions` does no identity check (`:800`). `newHTTPServer` sets `ReadHeaderTimeout`/`ReadTimeout`/`IdleTimeout` but **no** `WriteTimeout` (`main.go:181-189`). Security depends entirely on the `127.0.0.1` bind plus the gateway.
- **Impact:** If the buyer port is ever exposed (bind change, container networking, SSRF), there is zero in-process authn/authz and every `X-MacProvider-*`/`X-Request-ID` header is trusted; the missing `WriteTimeout` lets a slow stream reader hold a connection (and provider slot) indefinitely.
- **Evidence:** All confirmed; this is the precondition that makes the two preceding Low buyer findings reachable. Kept Low given the loopback default and gateway fronting.
- **Recommendation:** Add an in-process auth gate (signed token from the gateway) even on the loopback router; treat all `X-MacProvider-*`/`X-Request-ID` headers as untrusted unless authenticated; set a `WriteTimeout`/per-stream deadline; assert/log if `bind_address` is ever non-loopback without auth.

### [LOW] Non-constant-time operator bearer comparison guarding all WS admin/poolz endpoints

- **Component:** Coordinator · WebSocket Relay (instance of the operator-key timing theme)
- **File(s):** `phase4-coordinator/internal/ws/server.go:1480-1482`
- **Category:** crypto
- **What:** `authorizedOperator` compares with plain `==`: `r.Header.Get("Authorization") == "Bearer "+s.cfg.Auth.OperatorKey`, gating `/poolz`, `/admin/blacklist`, `/admin/provisional`, `/admin/promote/`, `/admin/reject/`.
- **Impact:** Theoretical timing recovery of the operator key → drain/blacklist/promote/reject providers and full pool read.
- **Evidence:** `:1480-1481` confirmed (also has an empty-key bypass disjunct, unreachable because `config.go:398` enforces non-empty). The correct pattern exists at `buyer/server.go:2613`. Low: HTTP string-compare timing channels are very noisy.
- **Recommendation:** `subtle.ConstantTimeCompare(...) == 1`, mirroring `buyer/server.go:2613`; drop the now-redundant empty-key disjunct.

### [LOW] Attacker-controlled numeric provider fields unvalidated; max_concurrency≤0 disables the per-session cap

- **Component:** Coordinator · WebSocket Relay
- **File(s):** `phase4-coordinator/internal/ws/messages.go:443-452`; `server.go:512-523`; `relay.go:141-143`, `:147`, `:418`; mitigation `admission.go:133-152`
- **Category:** input-validation
- **What:** `requireInt` accepts zero/negatives (`messages.go:443-452`); `prepareProviderAdmission` copies hello `MaxConcurrency` verbatim into `MaxConcurrency`/`SlotsFree`/`SlotsTotal` (`server.go:520-522`). `addActive` enforces the cap only `if maxConcurrency > 0` (`relay.go:141`), so `max_concurrency: 0`/negative bypasses it, permitting unbounded active relay entries (each allocating a 256-deep chunk channel, `relay.go:147`). Inflated `slots_free`/`slots_total` also skew routing.
- **Impact:** A provisional provider can bypass the in-session concurrency ceiling and advertise inflated slots; bounded by the provisional per-hour quota.
- **Evidence:** All confirmed; `TryReserveRequest` (`admission.go:~133-152`) caps provisional request volume. Low — fairness/resource footgun, not theft.
- **Recommendation:** Reject/clamp out-of-range values in `prepareProviderAdmission`/`ApplyHeartbeat`: require `max_concurrency` in `[1, ceiling]`, `slots_free` in `[0, slots_total]`, positive `ram_gb`/`model_params_b`; treat `max_concurrency<=0` as admission failure, not "unlimited."

### [LOW] MDA freshness OID not bound to the per-connection challenge (replay rests on the binding signature)

- **Component:** Coordinator · Tier2 Attestation
- **File(s):** `phase4-coordinator/internal/tier2/pillar_c.go:260-279`, `:161-233`, `:119-123`, `:228`, `:414`; `pillar_c_test.go:438-453`
- **Category:** replay/attestation-design
- **What:** `verifyMDAFreshness` checks only that the leaf's Apple freshness extension equals `SHA256(token.Token)` (`:268`), where `token.Token` is provider-supplied, not the coordinator challenge. The Apple MDA cert + device-attest token can be captured and replayed without the freshness OID rejecting it; cross-connection freshness rests on `verifyAttestationBindingSignature` (`:228`).
- **Impact:** Defense-in-depth weaker than the layered checks suggest; no direct money/RCE impact given the SE-key assumption.
- **Evidence:** Narrow claim true. Downgraded medium→low: a **second independent** software challenge gate runs first — `VerifyAttestationToken:119-123` rejects `token.Challenge != wantChallenge` as `AttestationStatusStale`, and `token.Challenge` is folded into the binding-signature payload (`:414`, verified at `:228`). So cross-connection replay is already blocked by two controls, not one.
- **Recommendation:** Require the device-attest token (`token.Token`) to commit to the coordinator-issued challenge and verify it, making Apple's freshness mechanism a second hardware-rooted anti-replay control independent of the software signature.

### [LOW] Attestation accepts self-asserted claimed/binary_version with no certificate-level corroboration

- **Component:** Coordinator · Tier2 Attestation
- **File(s):** `phase4-coordinator/internal/tier2/pillar_c.go:255-258`, `:392-422`; mitigations `ws/server.go:420`, `:422`
- **Category:** trust-boundary
- **What:** `attestationHardwareFamilyAllowed` reads `token.Claimed["hardware_family"]` and only checks it equals `"apple_silicon"` (`:255-258`); `attestationBindingPayload` signs `token.BinaryVersion` and the full `Claimed` map (`:392-422`) — but a signature by the genuine leaf key proves only that the device *asserted* these values. A dishonest provider on genuine Apple Silicon can set arbitrary `binary_version`/claimed metadata and still reach `AttestationStatusAttested`.
- **Impact:** Attestation proves "genuine Apple hardware + live SE-key possession," not "running the expected binary/model."
- **Evidence:** Confirmed. Mitigated: `RAMTierAttested` is hardcoded `false` (`ws/server.go:420`) and model integrity is handled separately by Pillar-A hash verification (`:422`), so this alone does not move money.
- **Recommendation:** Document and enforce that `claimed`/`binary_version` are self-asserted and must not gate trust/payout; derive `hardware_family` from a certificate-rooted property; continue to depend on Pillar-A hash verification for model integrity.

### [LOW] Production MDA chain verification uses ExtKeyUsageAny and does not constrain the leaf to a non-CA end-entity

- **Component:** Coordinator · Tier2 Attestation
- **File(s):** `phase4-coordinator/internal/tier2/pillar_c.go:659-678` (`:675`), `:236-253`, `:538-568`
- **Category:** x509-validation
- **What:** `verifyAttestationCertificateChain` calls `certs[0].Verify` with `KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny}` (`:675`), and `verifyMDALeafPublicKey` (`:236-253`) validates only key type/curve (P-256/P-384 ECDSA). There is no `IsCA == false`/BasicConstraints assertion and no MDA-specific EKU/OID; intermediates come from attacker-supplied `certs[1:]` (`:668`).
- **Impact:** Any cert that chains to a configured root and has a P-256/P-384 ECDSA key qualifies as an MDA leaf regardless of EKU or CA status — looser than the Apple MDA profile warrants.
- **Evidence:** Confirmed; no `IsCA`/`BasicConstraints` hits in grep. Low because the chain must still terminate at an operator-pinned Apple root and Go's `x509.Verify` independently enforces BasicConstraints/path-length on intermediates.
- **Recommendation:** After chain verification, pin the leaf to the Apple MDA end-entity profile: require `IsCA == false` and the expected MDA leaf EKU/marker OID; replace `ExtKeyUsageAny` with Apple's specific MDA EKU(s).

### [LOW] Explorer operator token verified with non-constant-time comparison

- **Component:** Coordinator · Explorer + RequestLog (instance of the operator-key timing theme)
- **File(s):** `phase4-coordinator/internal/explorer/handlers.go:501-503`; rate limit `:60`, `config.go:599-600`
- **Category:** crypto-timing
- **What:** `authorized()` gates the entire operator explorer with plain `==`: `... == "Bearer "+h.cfg.Auth.OperatorKey` (`:501-503`). The same secret is compared with `subtle.ConstantTimeCompare` in `buyer/server.go:2610-2613` and reused as gateway bearer/internal auth key (`main.go:97`, `:116`).
- **Impact:** Theoretical timing recovery of the master operator credential → full explorer read model (buyer history, IPs, prompts, ledger, payouts) plus gateway/internal compromise.
- **Evidence:** `==` confirmed; inconsistency and key reuse confirmed. Downgraded medium→low: the explorer is hard-capped at ≤60 req/min (`config.go:599-600` validates 1–60, enforced via `allowRequest` at `handlers.go:60`), making remote nanosecond-delta recovery of a high-entropy key infeasible.
- **Recommendation:** Extract the Bearer token, reject on length mismatch, then `subtle.ConstantTimeCompare(...) == 1`; factor the buyer-side comparator into a shared helper.

### [LOW] Explorer rate-limiter map grows unbounded (per-source-IP keys never evicted)

- **Component:** Coordinator · Explorer + RequestLog
- **File(s):** `phase4-coordinator/internal/explorer/handlers.go:505-528`, `:41`, `:56-60`, `:530-536`
- **Category:** resource-leak
- **What:** `allowRequest` prunes expired timestamps per key but re-stores the key even when its slice prunes empty (`:522`, `:526`) and never `delete`s it, so `h.stamps` accumulates one entry per distinct source IP for process lifetime.
- **Impact:** Slow unbounded memory growth proportional to distinct authenticated source IPs.
- **Evidence:** No `delete`/`if len(stamps)==0` guard confirmed. Mitigated: `allowRequest` runs only after `authorized()` (`:56` before `:60`), so only authenticated operators add keys, and the key is the real TCP peer via `clientAddrKey` (`:530-536`), not a spoofable header. Low.
- **Recommendation:** `if len(stamps) == 0 { delete(h.stamps, key) } else { h.stamps[key] = stamps }`, or run a periodic sweep; optionally cap tracked keys.

### [LOW] Coordinator operator-key endpoints use non-constant-time bearer comparison (consolidated)

- **Component:** Coordinator · Auth/Config/Pool/CMD (consolidates the billing, ws, and explorer operator-key timing instances above; **also affects** `billing/endpoints.go:61`, `ws/server.go:1481`, `explorer/handlers.go:502`)
- **File(s):** `phase4-coordinator/internal/billing/endpoints.go:61`; `phase4-coordinator/internal/ws/server.go:1481`; `phase4-coordinator/internal/explorer/handlers.go:502`; dead helper `phase4-coordinator/internal/auth/tokens.go:34`; wiring `cmd/coordinator/main.go:82`, `:97`, `:116`
- **Category:** crypto-timing
- **What:** Three live operator-key gates compare the bearer with ordinary Go string comparison (length-then-bytewise, short-circuiting); the same operator key is compared correctly with `subtle.ConstantTimeCompare` in `buyer/server.go:2613` and `tier2/pillar_c.go:270`, so this is an inconsistency, not a deliberate choice. The dead helper `auth.AuthorizedBearer` repeats the insecure pattern.
- **Impact:** A network attacker measuring response-time deltas could in principle recover the operator key, which controls provider blacklist/drain (availability + money) and full ledger/per-buyer read.
- **Evidence:** All three gates and the same-secret wiring confirmed (`main.go:82,97,116`); dead helper has no non-test caller. Downgraded medium→low: remote timing attacks against a high-entropy key over Go `==` are extremely difficult (jitter dwarfs the per-byte delta; length compared first); the explorer is additionally rate-limited (`config.go:599`). The ws and billing gates are **not** rate-limited, so a residual weakness remains and the fix is cheap.
- **Recommendation:** Add one shared `auth.ConstantTimeBearer(header, expected)` helper (length-check then `ConstantTimeCompare`) and call it from billing, ws, explorer, and the gateway; rewrite or delete the dead `auth.AuthorizedBearer`.

### [LOW] 24-bit token_prefix lets revocation collaterally revoke another provider's active token

- **Component:** Coordinator · Auth/Config/Pool/CMD
- **File(s):** `phase4-coordinator/internal/auth/tokens.go:136`, `:186-204`, `:190`, `:192`, `:196`, `:223-228`; `coordinator-cli/main.go:81`, `:150`
- **Category:** authz
- **What:** Tokens are indexed for revocation by a 6-hex-char prefix (24-bit namespace). `RevokeToken` runs `UPDATE provider_tokens SET revoked_at=? WHERE token_prefix=? AND revoked_at IS NULL` (`:192`), revoking every active token sharing that prefix; `RowsAffected` is checked only for zero (`:200`), so a `>1` collateral revocation is silent, and the CLI reports only one provider. The token secret itself is full 256-bit `crypto/rand`, stored as SHA-256 — so this is a revoke-by-prefix integrity/availability defect, not an entropy weakness.
- **Impact:** Revoking provider A by prefix can also revoke a colliding provider B's still-valid token (~50% collision near ~4,800 active tokens by birthday bound), kicking an innocent earning provider offline with no operator warning.
- **Evidence:** Confirmed; `token_prefix` has no UNIQUE constraint (only `token_hash`). Low at POC scale, growing with active-token count.
- **Recommendation:** Revoke by a unique id (token id or full `token_hash`), or error when `RowsAffected>1` and require a longer prefix; surface `RowsAffected` in the CLI; widen the stored prefix to 12+ hex chars.

### [LOW] coordinator-cli transmits the operator key to an unauthenticated, scheme-unchecked admin URL

- **Component:** Coordinator · Auth/Config/Pool/CMD
- **File(s):** `phase4-coordinator/cmd/coordinator-cli/main.go:118-127`, `:154-178` (`:162`, `:167`, `:169`); contrast `config.go:636-646`, `:602-613`
- **Category:** secrets
- **What:** `revoke-and-kick` takes `--admin-url`/`--operator-key`, then `kickProvider` builds `<adminURL>/admin/blacklist` and sets `Authorization: Bearer <operatorKey>` via `http.DefaultClient` with no scheme/host validation (`:162-169`). Unlike `config.ValidateEndpointURL` (`:636-646`) and the explorer base-URL check (`:602-613`), which reject non-loopback `http`, this path performs no scheme check.
- **Impact:** Cleartext disclosure / exfiltration of the operator key if an `http://` or hostile `--admin-url` is supplied; limited to operator misconfiguration / a malicious argv.
- **Evidence:** Confirmed — only non-empty checks, no scheme validation; the inconsistency with the existing validators is real. Operator-key is also exposed via argv in process listings.
- **Recommendation:** Validate `--admin-url` with `config.ValidateEndpointURL` (https-only except explicit loopback) before sending the key; read the operator key from an env var/file instead of an argv flag.

### [LOW] Upstream coordinator response headers passed through to buyers with minimal filtering

- **Component:** Gateway · Router/HTTP edge
- **File(s):** `phase5-gateway/internal/router/server.go:2218-2227` (`:2224`, `:2241-2243`); callers `:444`, `:1428`, `:1469`, `:1535`; `phase5-gateway/internal/router/cors.go:9-29`, `:44-48`
- **Category:** header-passthrough
- **What:** `copyCleanHeaders` copies every upstream header except those prefixed `x-macprovider-` and `Content-Length` — no allowlist, so `Set-Cookie`, `Access-Control-*`, `Cache-Control`, `CSP`, `Location`, etc. forward to buyers. Go's `net/http` blocks CR/LF response-splitting, but not header injection.
- **Impact:** Defense-in-depth gap: if a coordinator response ever carries unexpected headers (e.g. influenced by a compromised provider it relays), they reach buyers ungoverned.
- **Evidence:** Unbounded denylist passthrough confirmed. Downgraded (verdict): the CORS-override impact is overstated — `withCORS` sets gateway CORS via `h.Set` *before* the handler runs, and `copyCleanHeaders` uses `dst.Add` *after*, so an upstream `Access-Control-Allow-Origin` is appended as a duplicate (browsers reject dual values) rather than overriding; `cors.go:46` hardcodes `Allow-Credentials: false`. `Set-Cookie`/cache-poisoning concerns remain valid; Low.
- **Recommendation:** Replace the denylist with an explicit small allowlist (e.g. `Content-Type`, `X-Request-ID`); always strip `Set-Cookie`, `Access-Control-*`, and `Cache-Control`/`CSP` from upstream responses.

### [LOW] Settlement records uncapped provider-reported token counts with no constraint relating settled usage to the reservation

- **Component:** Gateway · SQLite Storage (companion to the coordinator money-math findings; gateway-side quota debit)
- **File(s):** `phase5-gateway/internal/storage/sqlite/store.go:395-437` (`:403-405`, `:411`, `:417-419`, `:420-435`), `:375`, `:794-810`; `migrate.go:74`, `:83-94`; `router/server.go:1496`, `:1520`, `:1527`, `:1599-1609`
- **Category:** money-math
- **What:** `SettleReservation` writes `settlement.TotalTokens` (`PromptTokens+CompletionTokens`, possibly `provider_reported`) straight into `quota_reservations.settled_tokens` and a new `usage_events` row (`:420-435`). It never reads `reserved_tokens`, so there is no check that `settled_tokens <= reserved_tokens`, and the schema enforces only `>= 0` (`migrate.go:88`). `dailyUsageTx` (`:794-810`) sums `usage_events.total_tokens`, so an inflated settle directly inflates consumed daily quota; an under-report under-bills. The reservation cap is enforced only at reserve time (`:375`).
- **Impact:** Over/under-billing of a buyer's daily token quota driven by the reported count, with no storage-layer ceiling; bounded by daily quota and 24h reservation expiry.
- **Evidence:** Confirmed — SELECT fetches only `window_date`/`status`; provider-reported counts flow unvalidated from `settleRequest` (`server.go:1599-1609`) with no cap. Low: requires a hostile/buggy upstream provider, blast radius bounded by daily quota.
- **Recommendation:** Enforce the invariant in the storage layer: clamp `settled_tokens` to `reserved_tokens` or reject over-settlements, and/or add a CHECK/trigger; have the billing layer reconcile against `reserved`, never trusting `settled` alone.

### [LOW] Replayed client-controlled request_id surfaces a raw PK collision instead of an idempotent response

- **Component:** Gateway · SQLite Storage
- **File(s):** `phase5-gateway/internal/storage/sqlite/store.go:354-393` (`:382-385`, `:386-387`), `:853`; `migrate.go:93`; `router/server.go:168-171`, `:1301-1316`; `errors.go:9`
- **Category:** idempotency
- **What:** `ReserveQuota` inserts into `quota_reservations` with PK `(account_id, request_id)`; `request_id` is the client-supplied `X-Request-ID` (any UUID-like value honored, `server.go:168-171`). On a duplicate the INSERT fails with a UNIQUE/PK error returned verbatim (`:386-387`), which the router maps to a generic 500 (`server.go:1301-1316`). No double-spend (`BEGIN IMMEDIATE` + PK), but no idempotency handling.
- **Impact:** Retries of a legitimately-failed request collide and return 500; a buyer can deliberately reuse their own request_ids to generate confusing internal errors. Correctness/availability, no fund loss.
- **Evidence:** Confirmed — no `ON CONFLICT`; `ErrReservationExists` is defined but never returned by `ReserveQuota`. No double-spend confirmed. Low (self-inflicted only).
- **Recommendation:** Use `INSERT ... ON CONFLICT(account_id,request_id) DO NOTHING` (or map the constraint error to `storage.ErrReservationExists`) and return a defined idempotency outcome the router translates to a stable response.

### [LOW] Operator-key comparison gating the PII-exposing explorer storage queries is non-constant-time

- **Component:** Gateway · SQLite Storage (instance of the gateway operator-key timing theme; the auth barrier lives in the router but gates this component's PII queries)
- **File(s):** `phase5-gateway/internal/router/server.go:1932-1942`; `phase5-gateway/internal/router/explorer.go:246-255`; PII at `phase5-gateway/internal/storage/sqlite/types.go:54`, `:63`, `:70`, `:76`, `:268`, `:274`, `:399`
- **Category:** crypto-timing
- **What:** `operatorAuthorized` (plain `==`, `:1933`/`:1942`) is the sole authorization barrier in front of every PII-returning explorer storage query (`ExplorerListBuyers`/`BuyerDetail`/`Sessions`/`Activity`), which return account emails, client IPs, API-key prefixes, and audit payloads.
- **Impact:** Theoretical timing side-channel on the operator key protecting buyer PII / API-key-prefix / audit data.
- **Evidence:** `==` confirmed; PII fields confirmed in `types.go`; `hmac.Equal` already available (`auth/demo.go:53`). Low (remote timing of a high-entropy bearer is impractical; operator-only PII, not fund movement).
- **Recommendation:** Compare via `crypto/subtle.ConstantTimeCompare`/`hmac.Equal` after a length-independent check (covered by the consolidated gateway operator-key fix).

### [LOW] Gateway operator/admin auth uses non-constant-time bearer comparison (consolidated gateway-auth view)

- **Component:** Gateway · Auth/Config (OAuth, keys) (consolidates with the Medium gateway-router operator-key finding and the gateway-storage instance above)
- **File(s):** `phase5-gateway/internal/router/server.go:1932-1938`, `:1942`, `:1948`; `phase5-gateway/internal/config/config.go:186`
- **Category:** timing-side-channel
- **What:** `operatorAuthorized` gates `handleKillSwitch`, `handleCapacitySignal`, `handleCapacityEvaluate`, `handleFeedbackSummary`, and `/admin/explorer/*` via plain `==` (`:1933`, repeated `:1942`); admin routes are explicitly exempt from the kill switch (`publicPaused` returns false for `/admin/`, `:1948`).
- **Impact:** Toggle the kill switch (DoS the live USDC API or disable a protective pause), force capacity-tier changes, and exfiltrate buyer/session PII.
- **Evidence:** Pattern and route gating confirmed. Downgraded high→low: in-process `==` is nanosecond-scale, far below remote HTTP timing noise; Go compares length first (attacker must know exact length before any per-byte signal); the explorer PII routes are gated behind `Explorer.Enabled`, which defaults `false` (`config.go:186`); no per-request delay amplifies the signal. The duplicate at `:1942` should still be fixed; constant-time is correct hardening.
- **Recommendation:** As consolidated above — shared constant-time helper after a length-independent (hash-based) compare; consider a dedicated gateway-admin credential distinct from the coordinator `OperatorKey`.

### [LOW] Demo-token IP binding collapses IPv6 clients to a /64

- **Component:** Gateway · Auth/Config (OAuth, keys)
- **File(s):** `phase5-gateway/internal/auth/demo.go:67`, `:79-92` (`:85`, `:91`), issued at `:36`; `router/server.go:607`, `:1687`/`:1241`; `config/config.go:317-320`
- **Category:** authz
- **What:** HMAC-signed demo tokens are bound to `normalizeDemoIP(clientIP)`: full `/32` for IPv4 but only the `/64` prefix for IPv6 (`:91` returns `net.IP(ip[:8]).String()+"::/64"`). The same `/64` value is reused as the rate-limit / quota identity (`server.go:607`).
- **Impact:** A client sharing the victim's IPv6 `/64` can replay a demo token minted for another address in that prefix.
- **Evidence:** Normalization confirmed. Downgraded medium→low: the `/64` collapse is the **same** key used for binding *and* quota — all `/64` addresses already share one quota bucket, so "replay" consumes the very bucket the legitimate occupant would (no amplification); exploitation requires being on-path within the victim's `/64` and capturing their token (already same trust zone); tokens are HMAC-signed, short-TTL, and demo consumption is hard-capped (`config.go:317-320`). Residual issue is `/64` vs `/128` quota-key granularity.
- **Recommendation:** Bind IPv6 demo tokens to the full `/128`; or, if `/64` is intentional, tie tokens to an additional server-issued opaque session id so the IP prefix is not the sole anti-replay control. Keep `DemoDailyTokensPerIP` low.

### [LOW] Extracted update binary is executed with the full inherited environment before validation completes

- **Component:** Provider Binary · Self-Update (Swift) (amplifier for the High update-key finding)
- **File(s):** `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift:92`, `:214-223`, `:81-84`
- **Category:** supply-chain
- **What:** After checksum verification, the new binary runs via `runProcess(newBinary.path, ["self-test"])` (`:92`); `runProcess` (`:214-223`) sets only `executableURL`/`arguments` and never assigns `process.environment`, so the child inherits every env var of the updater, including the `MACPROVIDER_*` overrides.
- **Impact:** Amplifies any environment-poisoning: the verified-but-environment-shaped binary executes immediately during update with full inherited env, before operator inspection.
- **Evidence:** Confirmed; runs after the SHA-256 gate (`:81-84`), so content is authenticated — worst case is the trusted binary observing an operator-controlled environment. Low.
- **Recommendation:** Set an explicit minimal `process.environment` for the self-test (drop `MACPROVIDER_*` and non-essential vars); run the self-test from the temp extraction directory.

### [LOW] Release-API URL is environment/flag overridable and never validated for scheme or host

- **Component:** Provider Binary · Self-Update (Swift) (pairs with the High update-key finding)
- **File(s):** `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift:30-32`, `:129-141` (`:130-131`, `:135-136`), `:225-232`, `:68-70`; `MacProviderCLI.swift:161-168`
- **Category:** ssrf / input-validation
- **What:** The release metadata endpoint comes from `releasesAPIURL ?? environment["MACPROVIDER_RELEASES_API_URL"] ?? default` (`:30-32`) and the `--releases-api-url` flag. `latestRelease()` only checks `URL(string:)` parses (`:130-131`) — it does **not** enforce https or a `github.com` host, unlike asset URLs which go through `validateDownloadURL()` (`:225-232`, applied only at `:68-70`).
- **Impact:** Standalone: cleartext fetch leaking the `macprovider-cli/<version>` user-agent and spoofing the version-available banner. Combined with a substituted key (High finding) it completes an attacker-controlled channel.
- **Evidence:** Inconsistency confirmed; `validateDownloadURL` never applied to `releasesAPIURL`. Downgraded medium→low: the override is operator-supplied (flag/own env), not network-injected (so "SSRF" overstates it); not code-exec on its own because assets are still allowlisted and the signature/SHA chain still gates the payload (`:68-70`, `:77-84`); the end-to-end concern is already counted in the High finding's precondition.
- **Recommendation:** Run `releasesAPIURL` through the same validation as assets (`scheme == "https"`, host `api.github.com`/configured allowlist) in `latestRelease()`; reject overrides that fail the allowlist.

### [LOW] Coordinator-supplied recommended_binary_version echoed into status output unsanitized

- **Component:** Provider Binary · Self-Update (Swift)
- **File(s):** `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:384-394` (`:385`, `:390-393`), `:438`; `SelfUpdate.swift:404-449` (`:434-438`, `:446-448`), `:280-290`; `HTTPServer.swift:392`; `MacProviderCLI.swift:115-117`
- **Category:** information-disclosure
- **What:** `acceptCoordinatorSession()` stores and prints `payload["recommended_binary_version"]` from the coordinator/WS-relay path (`:385`, `:390-393`), and `LocalStatusFormatter` renders coordinator-provided fields via `String(describing:)` with no control/ANSI stripping (`SelfUpdate.swift:446-448`).
- **Impact:** Terminal/log injection and operator-display spoofing from a trusted-but-compromised coordinator; no effect on the cryptographically gated update path.
- **Evidence:** Full taint flow confirmed end-to-end. Does **not** affect the update gate: `compareSemver` maps each component through `Int($0) ?? 0` (`:280-290`), and the real update path authenticates via GitHub assets + openssl signature + SHA. Cosmetic — Low.
- **Recommendation:** Strip control/ANSI characters and length-bound coordinator-provided strings before printing in `LocalStatusFormatter.string()` and `acceptCoordinatorSession`.

### [LOW] Local HTTP /v1/chat/completions has no concurrent-request limit (local memory/CPU DoS)

- **Component:** Provider Binary · Runtime/Inference (Swift)
- **File(s):** `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:180-227` (`:196`), `:62-85` (`:73-77`); `ModelRuntime.swift:31`, `:96`, `:150`; `AsyncSemaphore.swift:10`, `:28-43` (`:36`); contrast `InferenceRelay.swift:70-79`; `Config.swift:57`
- **Category:** resource-exhaustion
- **What:** `handleChatCompletions` unconditionally spawns `Task.detached` per request (`:196`) before any concurrency check; the only serialization is `ModelRuntime.inferenceGate = AsyncSemaphore(value: 1)` (`:31`) whose `waiters` array is unbounded (`AsyncSemaphore.swift:36`). The WS relay enforces `guard active.count < maxActiveRequests` (`InferenceRelay.swift:70-79`); the HTTP path has no equivalent gate. Each queued request retains its parsed `ChatCompletionRequest` (body capped at 10 MB, `Config.swift:57`) and channel.
- **Impact:** A local process/user can exhaust memory/FDs, degrading or crashing the inference service.
- **Evidence:** Mechanics confirmed (no active-count guard on the HTTP path; unbounded waiter array). Downgraded medium→low: server binds `127.0.0.1` only (`HTTPServer.swift:35`) — no remote surface; the deployment target is the contributor's single-user Mac (same-trust-domain attacker); per-request memory bounded by the 10 MB body cap.
- **Recommendation:** Mirror the WS relay backpressure: before spawning, check active in-flight count against `providerStatus.capacity.maxConcurrency` (or an `AsyncSemaphore tryAcquire`) and return HTTP 429/503 when full; cap the `AsyncSemaphore` waiter-queue depth and reject past the cap.

### [LOW] NIO HTTP server sets no read/idle/header timeout (slow-loris style local DoS)

- **Component:** Provider Binary · Runtime/Inference (Swift)
- **File(s):** `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:17-37` (`:18`, `:20-32`, `:35`), `:62-85` (`:73`, `:79-84`)
- **Category:** resource-exhaustion
- **What:** The `ServerBootstrap` pipeline installs no `IdleStateHandler` and no read/header timeout; `channelRead` acts only on `.end` (`:79-84`), so a connection that never sends `.end` (or trickles bytes below `maxBodyBytes`) holds the channel and `bodyBuffer` indefinitely. Backlog is 256 (`:18`), no per-connection cap.
- **Impact:** A local client holds connections/buffers open indefinitely, contributing to FD/memory exhaustion and blocking legitimate local buyer traffic.
- **Evidence:** Confirmed; repo-wide grep for `IdleStateHandler`/`readTimeout`/`connectTimeout` is empty in `phase3-binary/Sources` (the recent `ResponseHeaderTimeout` commit is in the Go gateway, not this binary). Bound to `127.0.0.1` (`:35`); per-connection buffer capped at 10 MB (`:73`). Low (loopback-scoped, single-user Mac).
- **Recommendation:** Add an `IdleStateHandler` (or NIO read-timeout handler) to the `childChannelInitializer` to close connections idle or incomplete within a bounded window (~30-60s).

### [LOW] DOM-XSS: coordinator-controlled /v1/status `status` interpolated raw into innerHTML under a permissive CSP

- **Component:** Web Demo + Install/Deploy Scripts + Python
- **File(s):** `frontdoor/console/index.html:782-789`, `:1086`, `:1093` (sink); `dist/nginx-console.malibu.tech.conf:27` (CSP); mitigating source `phase5-gateway/internal/router/server.go:1751-1806`, `:549`
- **Category:** xss
- **What:** `fetchStatus()` stores the raw `/v1/status` JSON as `poolStatus` (`:782-783`); `renderDashboard()` writes a row via `row.innerHTML = '...'+val+'...'` (`:1093`) where `val = ps.status` is taken verbatim (`:1086`) — unlike the sibling numeric rows wrapped in `String(...)` and the model list using `textContent` (`:1106-1110`). The console CSP sets `script-src 'unsafe-inline'` (`nginx-console.malibu.tech.conf:27`), so an injected `<img src=x onerror=...>` would execute.
- **Impact:** If `/v1/status` is attacker-influenced (first-party compromise or TLS-strip MITM), the `status` string renders as live HTML on the money-bearing console origin, with access to `localStorage` and the demo-token / chat flow.
- **Evidence:** Sink and missing escaping confirmed (no `escapeHtml`/`sanitize`/`DOMPurify` anywhere); CSP confirmed (`img-src 'self'` blocks the bogus load, which is exactly what fires `onerror`). Downgraded medium→low: `aggregateStatus` sets `out.Status` only from a fixed enum — `"up"`/`"idle"`/`"degraded"`/`"down"` (`server.go:1755,1802,1805,549`), never reflecting client input; exploitation requires controlling the first-party response.
- **Recommendation:** Build the row with `createElement` + `textContent` (as the model list already does), not `innerHTML` from server data; additionally drop `script-src 'unsafe-inline'` (move the inline script to an external file with a nonce/hash) so inline-handler injection cannot execute even if a sink is missed.

### [LOW] Localhost demo_server.py forwards an uncapped attacker-controlled max_tokens upstream

- **Component:** Web Demo + Install/Deploy Scripts + Python
- **File(s):** `beta/demo_server.py:86-95` (`:90`, `:91`, `:95`), `:38`, `:70-75`, `:118`; contrast `beta/web/api/chat.js:50`
- **Category:** dos
- **What:** `do_POST` builds the upstream payload with `"max_tokens": int(req.get("max_tokens", 512))` (`:90`) and `"temperature": float(...)` (`:91`) with no upper bound, then POSTs with a per-request timeout of 180s (`:38`, `:95`). The Vercel `chat.js` clamps `Math.min(..., 512)` (`:50`); this path does not. Server binds `127.0.0.1:8765` (`:118`).
- **Impact:** A local caller can request an enormous completion, tying up the model for the full timeout window. Local-only, no money path. A non-integer value raises an uncaught `ValueError` → 500 (`int()`/`float()` casts at `:90-91` are outside the only try/except at `:70-75`).
- **Evidence:** All confirmed against source; localhost-only bind bounds impact; no auth check, consistent with a dev demo. Low.
- **Recommendation:** Clamp before forwarding (`min(int(...), 512)`) and wrap the `int()`/`float()` casts in try/except to return 400 on bad input.

### [INFO] Per-provider N+1 subquery in admin providers listing enables amplified DB load

- **Component:** Coordinator · Billing/Settlement
- **File(s):** `phase4-coordinator/internal/billing/endpoints.go:139`, `:123`, `:135-144`, `:93-95`, `:226-279` (`:230-232`, `:271`, `:281-315`), `:162`, `:446-458`, `:462-475`
- **Category:** resource-amplification
- **What:** `providers()` runs the grouped aggregate, then issues one extra `SELECT SUM(provider_credits) ... WHERE provider_id=? AND status='ready'` per returned provider (`:139`); with `limit` clamped to 200, each admin call fans out to ~200 point queries. `reconcile()`'s `buyerEquivalentCredits` runs per-row correlated subqueries under a 5s context (`:226-279`).
- **Impact:** Amplified SQLite CPU/IO from a single authenticated admin request, contending with hot-path billing writes; not exploitable without the operator key.
- **Evidence:** N+1 and correlated-subquery structure confirmed; both paths behind `h.admin` operator auth; 5s cap bounds reconcile. Info — performance/amplification, not a vulnerability.
- **Recommendation:** Replace the per-provider subquery with a single `LEFT JOIN` aggregate over `ledger_payout_ready` grouped by `provider_id`; bound reconcile scans with a stricter time/row budget.

### [INFO] Provider-reported usage in inference_response_end is relayed verbatim into the money path (trust-boundary note)

- **Component:** Coordinator · WebSocket Relay (context for the High billing and Medium buyer findings)
- **File(s):** `phase4-coordinator/internal/ws/relay.go:325-354`, `:526-581` (`:576`); `messages.go:174-181`; downstream `internal/billing/formula.go:23-210`, `internal/buyer/server.go:1400`, `:1539`
- **Category:** money-math
- **What:** `handleInferenceEnd` parses the provider-supplied `InferenceResponseEnd.Usage` (`json.RawMessage`) and forwards it unchanged on `active.done` (`:576`); the relay performs no token arithmetic, so it cannot itself mis-bill. Flagged only to make the trust boundary explicit.
- **Impact:** If billing trusts provider-reported `completion_tokens` without an independent cap/estimate, a malicious provider could over-report to inflate payout — verified in the billing/buyer findings above.
- **Evidence:** Correctly-scoped info note; the integrity decision lives in `formula.go`/`buyer/server.go`. No defect in WS.
- **Recommendation:** Confirm in the billing path that provider-reported usage is bounded by a coordinator-side estimate or hard cap (addressed by the High/Medium findings). No change in `internal/ws`.

### [INFO] OpenPillarBFrame accepts a legacy JSON-form AAD path diverging from the canonical binary AAD

- **Component:** Coordinator · Tier2 Attestation
- **File(s):** `phase4-coordinator/internal/tier2/pillar_b.go:307-315` (`:311-315`), `:155-172`, `:303`, `:329`
- **Category:** protocol-robustness
- **What:** `OpenPillarBFrame` accepts a non-prefixed (legacy JSON) `aadRaw` when its decoded struct equals `expectedAAD` (`:311-315`); `DecodeAEADAAD` supports both the binary-prefixed path and a `json.Unmarshal` fallback. GCM authenticates the actual on-wire `aadRaw` (`:329`), so integrity is preserved over whatever bytes the provider sealed.
- **Impact:** No confidentiality/integrity break (`AEADFrameAAD` is a flat comparable struct so `==` is an exhaustive field compare). Maintenance/robustness only: dual encodings invite canonicalization drift.
- **Evidence:** Confirmed info/robustness-only as described.
- **Recommendation:** Once all providers emit binary AAD, drop the JSON fallback and require `bytes.Equal(aadRaw, expectedAADRaw)`; until then keep every `AEADFrameAAD` field part of the comparable struct so the equality check stays exhaustive.

### [INFO] Capacity-tier runtime config serialized/parsed with fmt.Sprintf/Sscanf %q (brittle round-trip)

- **Component:** Gateway · SQLite Storage
- **File(s):** `phase5-gateway/internal/storage/sqlite/store.go:688-717` (`:699`, `:710`, `:714-715`), `:730`, `:741`, `:751-752`; `explorer.go:366-370`
- **Category:** robustness
- **What:** `SetCapacityTier` writes `capacity_tier` via `fmt.Sprintf('{"tier":%d,"signals":%q}', ...)` (`:710`) and `GetCapacityTier` parses it with `fmt.Sscanf` against the same literal template (`:699`) — unlike the `kill_switch` path which correctly uses `encoding/json` (`:730`, `:741`). Both writes use bound parameters (no injection).
- **Impact:** No injection (operator/internal-written, bound parameter); a malformed/externally-edited `capacity_tier` row breaks tier reads and `ExplorerHealth`. Reliability/maintainability only.
- **Evidence:** Confirmed; `kill_switch` is the contrasting correct pattern.
- **Recommendation:** Serialize/parse `capacity_tier` with `encoding/json` (a small struct), exactly as the `kill_switch` path.

### [INFO] GitHub token exchange does not verify access_token is non-empty before use

- **Component:** Gateway · Auth/Config (OAuth, keys)
- **File(s):** `phase5-gateway/internal/auth/oauth.go:67-86` (`:70-73`, `:78`, `:86`), `:92`, `:102`, `:109`; `router/server.go:266`, `:269-280`
- **Category:** input-validation
- **What:** `Exchange` treats any 2xx from GitHub's token endpoint as success and decodes only `access_token`/`scope`, never checking `AccessToken != ""` or an `error` field, then calls `/user` with `Authorization: Bearer ` (`:86`). The downstream guard is incidental (`:92` non-2xx, `:102` `user.ID==0`).
- **Impact:** None exploitable — an empty/invalid bearer to `/user` returns 401, caught at `:92` (aborts 502); the scope guard (`:78`, `:109`) and identity gate (`server.go:269-280`, key issued only after a valid `user.ID`) mean no boundary is crossed. Diagnostics/defense-in-depth only.
- **Evidence:** Confirmed; downgraded low→info — no account/key is created without a valid GitHub identity.
- **Recommendation:** After decoding, explicitly fail when `AccessToken == ""` or an `error` field is present (add `Error string \`json:"error"\``), before the `/user` request.

### [INFO] OAuth callback error path unhandled and Secure-cookie flag depends solely on https base_url

- **Component:** Gateway · Auth/Config (OAuth, keys)
- **File(s):** `phase5-gateway/internal/router/server.go:228-231`, `:240-247`, `:1964-1967`, `:137`, `:252`; `phase5-gateway/internal/auth/oauth.go:134-136`; `phase5-gateway/internal/config/config.go:144`, `:236`, `:303-316`
- **Category:** oauth
- **What:** The `mp_oauth_session` cookie is correctly Path-scoped, HttpOnly, SameSite=Lax, single-use/time-bounded with a sound CSRF/state binding (`ConsumeOAuthState`, `:247`). Two minor notes: (1) `handleGitHubCallback` does not inspect GitHub's `error`/`error_description` query params (user-denied surfaces as a generic `oauth_state_invalid`); (2) `secureCookies()` returns true only when `Public.BaseURL` is https (`:1964-1967`), so a misconfigured http `base_url` would silently drop the Secure flag, and `Config.Validate` does not assert https (`config.go:303-316`).
- **Impact:** No security impact under the shipped production config (`BaseURL` defaults to `https://api.malibu.tech`, `config.go:144`). Recorded so the OAuth surface is documented as reviewed.
- **Evidence:** Cookie attributes, state binding, and both observations confirmed. Info.
- **Recommendation:** Optionally handle GitHub's `error` query param for clearer UX; validate in `Config.Validate` that `Public.BaseURL` is https when OAuth/demo auth is enabled so Secure cookies cannot be silently disabled.

### [INFO] Staged update binary made executable before the atomic rename (brief 0755 hidden file)

- **Component:** Provider Binary · Self-Update (Swift)
- **File(s):** `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift:159-173` (`:163-164`, `:166`, `:167`, `:168`)
- **Category:** toctou
- **What:** `replaceCurrentBinary()` copies the new binary to `.<name>.update-<UUID>` in the install directory, `setAttributes([.posixPermissions: 0o755])` (`:167`), then `rename()`s over the live binary (`:168`) — leaving a 0755 file briefly between `:167` and `:168`.
- **Impact:** Negligible — no privilege boundary crossed (same-user writable dir, random UUID suffix); only a same-uid co-resident process (already holding the user's privileges) could observe it.
- **Evidence:** Code confirmed. Downgraded low→info: best-practice ordering nit with effectively zero exploitable impact.
- **Recommendation:** `chmod` the staged file in a per-update temp dir (mode 0700) before moving into place, or `fchmod` after rename.

### [INFO] Provider self-reports prompt/completion token counts the coordinator must not trust for billing

- **Component:** Provider Binary · Runtime/Inference (Swift) (the originating end of the High billing / Medium buyer money path)
- **File(s):** `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:493-507`, `:277-280`, `:366-372`, `:557-565`; `ModelRuntime.swift:132-133`, `:215-216`; `HTTPServer.swift:296-298`, `:340-342`
- **Category:** money-integrity
- **What:** The untrusted provider binary computes `prompt_tokens`/`completion_tokens` from MLX (`ModelRuntime.swift:132-133,215-216`) and emits them in `inference_response_end` `usage` and HTTP responses. Correct behavior for this component, but a payment-integrity boundary: any coordinator billing derived from these is manipulable.
- **Impact:** Realized only if the trusted side trusts these fields — which the High/Medium coordinator findings confirm it currently does.
- **Evidence:** Taint flow confirmed; the finding correctly states "No defect exists in this binary."
- **Recommendation:** Ensure the coordinator independently meters tokens and treats provider-reported usage as advisory (addressed by the High billing and Medium buyer findings). No change in the provider binary.

### [INFO] Legacy beta Vercel proxy is an open prompt-relay / fixed-host SSRF, fenced behind a feature flag returning 410

- **Component:** Web Demo + Install/Deploy Scripts + Python
- **File(s):** `beta/web/api/chat.js:9-18`, `:20-23` (`:21`), `:39-83` (`:39-41`, `:50`, `:56`, `:79`); `beta/web/api/providers.js:18`
- **Category:** ssrf
- **What:** `chat.js` is an unauthenticated POST that forwards a caller prompt to a fixed host (`m1`/`m4.malibu.tech` — `provider` selects from a hardcoded `PROVIDERS` map, so not arbitrary-URL SSRF), `max_tokens` clamped to 512. Both `chat.js:21` and `providers.js:18` hard-gate behind `MACPROVIDER_ENABLE_LEGACY_BETA_PROXY !== '1'` and return HTTP 410 by default.
- **Impact:** If the flag is ever set to `'1'`, the endpoint becomes an anonymous, unmetered relay to the contributor Macs (capacity/cost DoS) and discloses tunnel hostnames via `X-Provider-Tunnel`. Off by default.
- **Evidence:** 410 gate, fixed-host map, 512 clamp, unauthenticated relay, and tunnel-header disclosure all confirmed; no secrets in either file. Info — abuse path exists only if an operator explicitly sets the flag.
- **Recommendation:** Keep the flag off in production (current state). If re-enabled, add an Origin/Referer allowlist, per-IP rate limit, and remove `X-Provider-Tunnel`. Consider deleting the legacy files entirely now that the front-door console talks directly to `api.malibu.tech`.

## Cross-cutting themes

- **Self-reported provider usage is the systemic money-integrity weakness.** The same untrusted token-count value flows unverified through four layers: the provider binary emits it (`InferenceRelay.swift`, Info), the WS relay forwards it verbatim (`relay.go`, Info), the buyer layer hands it to billing unclamped (`buyer/server.go`, Medium), and billing converts it directly to payout (`formula.go`, High). The gateway's settlement path repeats the pattern against the quota ledger (`gw-storage`, Low). The only durable fix is independent coordinator-side metering plus a byte-estimate clamp/quarantine — a single control that closes the High, Medium, and two Low money-math findings at once.

- **Client-controlled identifiers feed authority decisions.** Buyers control `X-Request-ID` (drives billing idempotency end-to-end → free inference, High; and quota-reservation 500s, Low) and `X-MacProvider-Account` (sticky attribution/purge, Low). The root cause is identical: the coordinator treats client-settable headers as trusted identity. The fix is server-side generation / signed gateway-issued tokens, never trusting raw inbound headers.

- **Non-constant-time operator-key comparison is duplicated across five files** (`billing/endpoints.go:61`, `ws/server.go:1481`, `explorer/handlers.go:502`, gateway `router/server.go:1933` and `:1942`), while the correct `subtle.ConstantTimeCompare`/`hmac.Equal` pattern already exists in the same codebases (`buyer/server.go:2613`, `tier2/pillar_c.go:270`, `auth/demo.go:53`). Verification downgraded most instances to Low (remote timing of a high-entropy key is impractical), but the inconsistency is real, the dead `auth.AuthorizedBearer` propagates it, and one shared helper resolves every instance.

- **Missing connection/time bounds on network-facing and hijacked sockets.** The hijacked provider WebSocket has no read/write deadline or frame-size cap (High), the gateway HTTP server has no `ReadTimeout`/`IdleTimeout` (Medium), the buyer server has no `WriteTimeout` (Low), and the Swift NIO server and local chat path have no idle timeout or concurrency cap (two Low). The pattern: timeouts/limits are set inconsistently and lost entirely on hijacked connections.

- **Loopback bind + gateway is the sole coordinator trust boundary.** Several Low findings (buyer no-auth, pool/check DoS, account header, internal error echo) are only Low because the buyer port binds `127.0.0.1` and the gateway sanitizes/authenticates. This is load-bearing: any `bind_address` change, container-network exposure, or co-located SSRF removes the only control. Defense-in-depth in-process auth is warranted.

- **Override knobs that bypass roots of trust on the untrusted edge.** The provider binary lets environment/flags override the signing key (High) and releases URL (Low), and runs the self-test with full inherited env (Low) — all eroding the supply-chain root of trust on hosts the operator does not control. Pinned trust anchors should be compile-time constants, not env-overridable.

## Prioritized remediation roadmap

1. **Stop unverified money movement (close the two directly-exploitable High money paths).** Resolves: *Provider payout billed on self-reported tokens*, *Buyer-controlled X-Request-ID enables free inference*. Generate the billing `request_id` server-side and overwrite/strip inbound `X-Request-ID` at the gateway; make `(request_id, attempt_n)` a true idempotency key (first-write-wins, 409 on distinct-payload collision, never zero-credit). In the same batch, bind provider payout to an independently observable quantity: clamp `provider_reported` tokens to the byte estimate with a tolerance band, quarantine implausible rows, and lower `maxBillableTokens` to a realistic ceiling. *(Pulls in the Medium buyer-layer unclamped-tokens and Low gateway settlement findings, and retires the two Info trust-boundary notes, since one metering control fixes the whole chain.)*

2. **Harden the WebSocket relay against unauthenticated DoS (remaining High + its Medium sibling).** Resolves: *No read/idle deadline or frame-size limit on hijacked provider WebSocket*, *Session writer can block indefinitely (no write deadline)*. Set a handshake `SetReadDeadline` immediately after `UpgradeHTTP`, reset per-iteration read deadlines in `readProviderLoop`, set write deadlines before every write, enforce `MaxFrameSize`, and cap in-flight unauthenticated upgrades.

3. **Pin the supply-chain root of trust on the provider binary (High + paired Lows).** Resolves: *Pinned update-signing public key overridable via env*, *Release-API URL not scheme/host-validated*, *Self-test runs with full inherited environment*. Make the signing key a non-overridable compile-time constant (no release-build env branch); run `releasesAPIURL` through the same https/host allowlist as asset URLs; set a minimal explicit environment for the self-test invocation.

4. **Bound the internet edge and storage integrity (remaining Mediums).** Resolves: *Gateway HTTP server has no ReadTimeout/IdleTimeout*, *SQLite connection-scoped PRAGMAs can be silently lost*, *Go stdlib CVEs in the coordinator build*. Set `ReadTimeout`/`IdleTimeout`/`MaxHeaderBytes` on the gateway server and a read deadline before the unauthenticated `handleFeedback` decode; move SQLite PRAGMAs into the DSN; rebuild with Go ≥ 1.26.4, bump `golang.org/x/sys`, and add `govulncheck` as a CI release gate.

5. **One shared constant-time operator-key comparator (folds in a Medium + five Lows).** Resolves: *Gateway operator-key non-constant-time compare* (Medium), the coordinator *billing/ws/explorer consolidated timing* Lows, and the *gateway storage/auth-core* timing Lows. Implement `auth.ConstantTimeBearer(header, expected)` (SHA-256 both sides + `subtle.ConstantTimeCompare`), call it from every operator-key site, and delete the dead `auth.AuthorizedBearer`. Consider a dedicated gateway-admin credential distinct from the coordinator `OperatorKey`.

6. **Privacy, fail-closed, and in-process trust hardening (coordinator Lows).** Resolves: *request_log PII retention* (Medium), *Admin auth fails open on empty operator key*, *Internal error strings echoed to clients*, *No in-process buyer auth / missing WriteTimeout*, *X-MacProvider-Account trusted unauthenticated*, *Pool/check XFF-spoof + unbounded map*, *Explorer rate-limiter map unbounded*, *max_concurrency≤0 disables the cap*, *24-bit token_prefix collateral revocation*, *coordinator-cli operator-key over unchecked URL*. Add a configurable `request_log` retention/anonymization job (coordinated with billing recovery); fail closed on an empty operator key; return generic error bodies; add in-process buyer auth + `WriteTimeout` and assert non-loopback binds require auth; derive account identity from a signed token; replace XFF-based rate-limiting and unbounded maps with bounded TTL/LRU limiters; clamp provider numeric fields; revoke tokens by unique id and error on `RowsAffected>1`; https-validate the CLI admin URL and read the key from env/file.

7. **Attestation policy tightening (coordinator Tier-2 Lows).** Resolves: *MDA freshness OID not challenge-bound*, *Self-asserted claimed/binary_version*, *ExtKeyUsageAny / no end-entity constraint*. Bind the device-attest token to the coordinator challenge; pin the leaf to the Apple MDA end-entity profile (`IsCA == false`, specific EKU/OID); document/enforce that `claimed`/`binary_version` are advisory only and continue relying on Pillar-A hash verification.

8. **Web, gateway-edge, and remaining Lows.** Resolves: *DOM-XSS via /v1/status `status`*, *demo_server.py uncapped max_tokens*, *Demo-token IPv6 /64 binding*, *Replayed request_id surfaces 500*, *Upstream header passthrough denylist*, *NIO/local-HTTP no timeout or concurrency cap*, *recommended_binary_version terminal injection*. Build the console status row with `textContent` and drop `script-src 'unsafe-inline'`; clamp `max_tokens` and guard casts in the Python demo; bind IPv6 demo tokens to `/128` (or add a server-side session id); map reservation PK collisions to a defined idempotency outcome; switch the gateway to a header allowlist that strips `Set-Cookie`/`Access-Control-*`/`Cache-Control`; add NIO idle timeouts and HTTP backpressure on the provider binary; sanitize coordinator-provided display strings.

9. **Informational hygiene (no production impact).** Track and address opportunistically: billing admin N+1 query, Pillar-B legacy JSON AAD path, capacity-tier `fmt.Sscanf` round-trip, GitHub empty-`access_token` check, OAuth callback error handling + https-`base_url` validation, staged-binary chmod ordering, and deletion of the flag-gated legacy Vercel proxy.
