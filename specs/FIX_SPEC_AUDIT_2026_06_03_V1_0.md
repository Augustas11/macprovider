# FIX_SPEC_AUDIT_2026_06_03_V1_0 — Remediation work order

**Source audit:** `audits/2026-06-03/` (`INDEX.md`, `CODE_AUDIT.md`,
`SECURITY_AUDIT.md`, `ARCHITECTURE_AUDIT.md`, `findings-raw.json`).
**For:** a separate implementation session (Codex). Work top-down; each task is
self-contained with file:line, the defect, the fix, and a Definition of Done
(DoD). Full evidence for any item is in the referenced report under the matching
finding title.

---

## 0. Ground rules (read first)

- **Trust model.** The provider Mac and the buyer are **untrusted**; the
  coordinator is the trusted money authority. Every fix below exists because an
  untrusted party influences money, availability, or code execution.
- **Do NOT inspect d-inference** (`github.com/layr-labs/d-inference`) — strictly
  clean-room, NOASSERTION license.
- **Build/test commands:**
  - Coordinator: `cd phase4-coordinator && go build ./... && go test ./...`
  - Gateway: `cd phase5-gateway && go build ./... && go test ./...`
  - Provider binary: `cd phase3-binary && swift build && swift test`
- **Every task must keep `go test ./...` (and `swift test` where touched) green.**
  Where a task changes money or billing behavior, **add a regression test** that
  fails before the fix and passes after.
- **Do not push.** Commit locally. If a push is later requested, this repo
  requires `gh auth switch -u Augustas11` first (see `CLAUDE.md`).
- **Decision log.** When a fix changes a normative behavior (billing semantics,
  trust boundary), append an entry to `beta/DECISION_CRITERIA.md` (current head:
  Entry 41).
- Suggested commit granularity: one commit per Tier-1 task; Tier-2 may be grouped
  by theme; Tier-3 as a single sweep commit.

---

## TIER 1 — Critical / High (mandatory)

### T1.1 — Stop paying providers on unverified self-reported token counts
**Severity:** CRITICAL (architecture) + HIGH (security). *Refs: ARCH "Provider
self-reported token usage drives real-USDC payout"; SEC "Provider payout is
billed on self-reported, unverified token counts"; ARCH "Pillar-D output
byte-cap bounds bytes-to-buyer but not billed completion_tokens".*

- **Files:** `phase4-coordinator/internal/billing/formula.go:86-178`
  (ComputeCredits; `usage_source` default + completion assignment 124-133);
  `phase4-coordinator/internal/buyer/server.go:1390-1404,1534-1555,2766-2778`
  (`tokenPointersFromUsageObject`); `phase4-coordinator/internal/billing/hotpath.go:119-139`;
  `phase4-coordinator/internal/billing/recovery.go:75-93,182-249,345-407`;
  `phase4-coordinator/internal/tier2/pillar_d.go:252-309` (`enforceOutputCap`,
  `g.outputBytes`).
- **Defect:** The provider's `inference_response_end.usage.completion_tokens` is
  the sole billing input. No server-side metering; reconcile re-reads the same
  provider-sourced counts. Pillar-D's output cap truncates buyer-facing bytes but
  never clamps billed tokens, so it gives false assurance.
- **Fix:**
  1. Measure emitted completion size server-side. The coordinator already buffers
     full non-streaming output and proxies every stream chunk; thread the
     observed output byte count (Pillar-D already tracks `g.outputBytes`) into
     billing.
  2. Bill on `min(provider_reported, server_observed_estimate)`. Derive
     `server_observed_estimate` from observed bytes using the existing-but-unused
     `OutputBytesPerTokenCeiling` config (a byte-floor per token).
  3. In `recovery.go` reconcile, recompute the completion-token ceiling from the
     stored output-size measure instead of re-trusting the provider count.
  4. When the Pillar-D cap truncates, force `usage_source = byte_estimated` for
     that request.
- **DoD:** A test provider that returns ~5 bytes of content but reports
  `completion_tokens: 10_000_000` is billed at the byte-derived ceiling, not 10M.
  Reconcile does not restore the inflated value. Existing billing tests stay
  green; new regression test added. Decision-log entry appended.

### T1.2 — Take the billing `request_id` away from the client (X-Request-ID free inference)
**Severity:** HIGH (security). *Ref: SEC "Buyer-controlled X-Request-ID drives
billing idempotency, enabling free inference".*

- **Files:** `phase4-coordinator/internal/buyer/server.go:801-804,830-848,887,2832-2839`
  (`requestIDForBuyerRequest`); `phase4-coordinator/internal/billing/hotpath.go:54-118`
  (`WriteHotPath` attempt derivation + `zeroCredits`);
  `phase4-coordinator/internal/requestlog/store.go:88-110` (no UNIQUE on
  `request_id`); `phase5-gateway/internal/router/server.go:168-171,1349`
  (gateway forwards client `X-Request-ID` verbatim when `isUUIDLike`).
- **Defect:** A buyer pins one valid UUIDv4 across many distinct paid requests;
  every request after the first derives `attempt_n>0` and is `zeroCredits`'d →
  free inference, reachable through the public gateway.
- **Fix:**
  1. Generate the billing `request_id` server-side (`uuid.NewString`) in the
     coordinator; keep client `X-Request-ID` only as an opaque correlation field
     that never feeds attempt derivation.
  2. Gateway: overwrite (do not pass through) `X-Request-ID` toward the
     coordinator so the client cannot pin the billing identity.
  3. Make `(request_id, attempt_n)` a real idempotency key: first write wins;
     on a genuine retry of the **same** payload (verify a body hash) collapse;
     on distinct payloads sharing an id, re-bill normally or return 409 — never
     silently zero-credit a served request.
- **DoD:** N distinct paid requests carrying one fixed `X-Request-ID` are each
  billed in full. Retits of an identical payload remain idempotent. Regression
  test exercises the end-to-end gateway→coordinator path.

### T1.3 — Gateway must not settle truncated/failed SSE as a successful billed `ok`
**Severity:** HIGH (code). *Ref: CODE "Gateway settles truncated/failed SSE
streams as a successful, billed `ok`".*

- **Files:** `phase5-gateway/internal/router/server.go:1475-1531` (scan loop +
  settlement branches; `settleRequest` at :1599-1610).
- **Defect:** After `for scanner.Scan()`, `scanner.Err()` is never checked. A
  `bufio.ErrTooLong` (SSE line > 1 MiB) or mid-stream read error that is **not**
  client cancellation falls through to `settleRequest(..., "ok")` — failed
  inference billed as success, logged 200, invisible.
- **Fix:** After the loop:
  `if err := scanner.Err(); err != nil && !errors.Is(r.Context().Err(), context.Canceled)`
  → settle with `outcome="upstream_error"` (or new `stream_truncated`) and emit
  an error log line. Consider raising the per-line cap or switching to
  `bufio.Reader.ReadBytes('\n')` if large SSE lines are legitimate.
- **DoD:** A simulated upstream that emits an oversize line / resets mid-stream
  settles as a non-`ok` outcome with a log line; a clean EOF still settles `ok`.
  New test covers both.

### T1.4 — Raw-HTTP streaming must not blame the provider for a buyer cancel
**Severity:** HIGH (code). *Ref: CODE "Raw-HTTP streaming path misclassifies
buyer disconnect as a provider breaker fault".*

- **Files:** `phase4-coordinator/internal/buyer/server.go:1664-1692` (esp.
  1686-1691; contrast the guarded paths at 1411-1413, 1559-1561, 1622-1624).
- **Defect:** The raw-HTTP SSE path is the lone forwarding path that does not
  check `r.Context().Err()` before classifying a read error as
  `billing.FaultBreakerQualifying`. A buyer who cancels mid-stream → provider
  recorded as disconnected and **paid zero** (`formula.go:112-114` zeroes
  breaker-qualifying rows).
- **Fix:** Before the fault classification at 1686-1691, check
  `r.Context().Err()` (mirror 1559-1561): if the buyer canceled, settle as a
  buyer-side cancel (provider paid for work done), not a provider fault.
- **DoD:** A test that cancels the buyer context mid-stream on the raw-HTTP path
  results in provider credit > 0 and no breaker-qualifying fault flag.

### T1.5 — Make the update-signing key non-overridable (supply-chain RCE)
**Severity:** HIGH (security). *Ref: SEC "Pinned update-signing public key is
overridable via environment variable".*

- **Files:** `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift:7-12,82-93,
  159-173,203-212,245-263` (`verifyChecksumSignature`, key read at :247).
- **Defect:** `environment["MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM"] ?? embedded`
  lets any process-environment write replace the supply-chain root of trust, then
  `MACPROVIDER_RELEASES_API_URL` points at an attacker server → persistent RCE on
  the contributor Mac.
- **Fix:** Treat the signing key as a non-overridable compile-time constant.
  Remove the env branch (or gate strictly behind a build-time DEBUG flag absent
  from release builds). For rotation, ship multiple pinned keys and roll via
  signed releases. Prefer CryptoKit `P256.Signing.PublicKey` over shelling to
  `openssl` with a temp-file key. Audit `MACPROVIDER_RELEASES_API_URL` override
  similarly (Low finding, fix together).
- **DoD:** Setting the env var in a release build has no effect on the verified
  key; `swift test` green; a test asserts the embedded key is used in release.

### T1.6 — Bound the hijacked provider WebSocket (pre-auth slowloris + unbounded frame)
**Severity:** HIGH (security). *Ref: SEC "No read/idle deadline or frame-size
limit on hijacked provider WebSocket".*

- **Files:** `phase4-coordinator/internal/ws/server.go:168-181,211-244,611-624`;
  `phase4-coordinator/cmd/coordinator/main.go:181-189`.
- **Defect:** After `gobwas.UpgradeHTTP` hijacks the conn, the `http.Server`
  timeouts no longer apply and no `SetReadDeadline`/`SetWriteDeadline` is set in
  production. First auth read blocks forever; the liveness reaper only starts
  post-auth; `ReadClientData` has no max-frame cap (contrast the `io.LimitReader`
  at :909) → slowloris/FD exhaustion and multi-GB-frame OOM, both unauthenticated.
- **Fix:** Immediately after `UpgradeHTTP`, set a handshake `SetReadDeadline`
  (~10s); in `readProviderLoop` reset `SetReadDeadline` each iteration to
  `heartbeatInterval * missThreshold`; set `SetWriteDeadline` before each write;
  enforce a max frame size (`wsutil.Reader` `MaxFrameSize` or `io.LimitedReader`
  + reject oversize); cap in-flight unauthenticated upgrades.
- **DoD:** A pre-auth client that sends nothing is dropped after the handshake
  deadline; an oversize frame is rejected without buffering it whole. New tests.

### T1.7 — Replace the spoofable, never-evicting `/v1/pool/check` rate limiter
**Severity:** HIGH (code). *Ref: CODE "Public `/v1/pool/check` rate-limiter is
keyed on spoofable `X-Forwarded-For` and never evicts".*

- **Files:** see the CODE report finding for exact lines in
  `phase4-coordinator/internal/buyer/server.go`.
- **Defect:** Limiter keyed on client-controlled `X-Forwarded-For` (bypassable)
  and the map never evicts (unbounded-memory DoS).
- **Fix:** Key on a trusted source (real `RemoteAddr`, or a single trusted proxy
  hop with a configured trusted-proxy allowlist). Bound the map with TTL/LRU
  eviction. Apply the same trusted-IP derivation used elsewhere.
- **DoD:** Spoofed `X-Forwarded-For` no longer resets the limit; the limiter map
  size is bounded under sustained unique-key load. New test.

### T1.8 — Fix LEFT JOIN fan-out inflating per-buyer usage in the operator explorer
**Severity:** HIGH (code). *Ref: CODE "LEFT JOIN fan-out inflates per-buyer token
usage/reserved totals".*

- **Files:** `phase5-gateway/internal/storage/sqlite/explorer.go` (the per-buyer
  aggregate query — see CODE report for line range).
- **Defect:** A LEFT JOIN produces an N×M cross-product, multiplying summed token
  usage / reserved totals shown on the operator dashboard.
- **Fix:** Aggregate each table in a subquery/CTE before joining (or use
  `COUNT(DISTINCT)`/separate aggregate queries) so sums are not fanned out.
- **DoD:** A fixture with known per-buyer totals reports exact values; regression
  test added.

### T1.9 — Address coordinator availability SPOFs
**Severity:** HIGH (architecture). *Refs: ARCH "Coordinator restart is a single
point of failure"; "Multi-coordinator failover config … never used"; "Coordinator
liveness relies on a 30s app heartbeat with no WS ping/pong, no TCP keepalive, no
sleep-prevention assertion".*

- **Defect / Fix (scoped — these are larger; land what is feasible, file issues
  for the rest):**
  1. **Phantom failover:** the gateway validates multi-coordinator failover
     config that is never used. Either implement real failover **or** remove the
     config and stop advertising it (and `auto_update_enabled`, `warmup_enabled`
     if also unimplemented) to avoid integrity-of-expectations risk.
  2. **Provider liveness:** add WS ping/pong + TCP keepalive on the provider
     connection and a no-sleep assertion on the provider leg (reproduces the
     known production disconnect class — see `provider-disconnect-rootcause`).
  3. **In-memory SPOF:** document the blast radius and, at minimum, ensure clean
     reconnect/re-registration after a coordinator restart (the c1cfc97 gateway
     fast-fail fix is related). Full state-externalization is out of scope for
     this work order — file a tracking issue.
- **DoD:** Config no longer claims capabilities the code lacks; provider
  reconnect survives a coordinator restart in a test/staging exercise; ping/pong
  + keepalive present. Larger HA work captured as issues.

---

## TIER 2 — Medium (recommended)

Fix together where they share a file. Full detail in the reports under each title.

- **Constant-time operator/admin bearer-token comparison** (recurs ~5 sites,
  both Go services). Single shared helper using `crypto/subtle.ConstantTimeCompare`
  / `hmac.Equal`. *(CODE + SEC "non-constant-time … operator key".)*
- **`request_log` retention/pruning** — unbounded growth + indefinite buyer-IP
  (PII) retention. Add a retention window + pruning job. *(CODE + SEC.)*
- **Gateway `ReadTimeout`/`IdleTimeout`** missing → slow-body DoS on the edge.
  *(SEC.)*
- **Session writer write deadline** — a slow/stuck provider can block the session
  writer indefinitely. *(SEC.)*
- **Provider-reported usage unclamped at the buyer layer** against actual request
  size (companion to T1.1; ensure the clamp lives at the right layer). *(SEC.)*
- **Go stdlib CVEs** call-path-confirmed by `govulncheck` in the coordinator
  build — bump the Go toolchain / deps. *(SEC.)*
- **SQLite connection-scoped PRAGMAs** can be lost on pool connection
  recreation — set via DSN or a connection init hook. *(SEC.)*
- **`mockprovider` double-closes `stopHB`** → deterministic panic on shutdown
  (test-only, but fix). *(CODE.)*
- **IPv6 demo-client IP normalization** misuses `net.IP` → malformed identifier.
  *(CODE.)*
- **Silently-ignored validated params** (`seed`, `presence_penalty`,
  `frequency_penalty`, `response_format`) — either forward to the runtime or
  document as unsupported and reject. *(CODE.)*
- **Console `/v1/status` → `innerHTML` under `unsafe-inline` CSP** — sanitize /
  use `textContent`; tighten CSP. *(CODE.)*

---

## TIER 3 — Low / Info (optional sweep)

35 Low + 17 Info (code), 29 Low + 9 Info (security), 11 Low + 1 Info
(architecture). These are listed in full in the three reports' "Findings"
sections with file:line and recommendations. Recommended single-sweep items:
token-revocation-by-6-char-prefix, provider routing metrics never bounds-checked,
`providerhttp.Client.Timeout` killing healthy long SSE streams,
`MACPROVIDER_RELEASES_API_URL` override (fold into T1.5). Triage the rest against
effort/impact; not all need fixing.

---

## Definition of done (overall)

1. All Tier-1 tasks implemented; `go test ./...` (both modules) and `swift test`
   green; new regression tests for every money-behavior change.
2. Tier-2 addressed or explicitly deferred with a one-line reason.
3. `beta/DECISION_CRITERIA.md` updated for any normative behavior change.
4. Tracking issues filed for deferred HA work (T1.9 state-externalization).
5. Commits are atomic and message-scoped; **no push** unless separately
   requested (and then `gh auth switch -u Augustas11` first).
