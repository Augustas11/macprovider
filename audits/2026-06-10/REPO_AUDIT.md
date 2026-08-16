# MacProvider Repository Audit — 2026-06-10

**Method.** Four-phase multi-agent audit: 5 discovery readers mapped the subsystems; 8 dimension auditors (architecture, code quality, security, testing, performance, dependencies, devex/ops, docs) produced findings with file:line citations; every finding was re-read and adversarially verified by an independent verifier (citations re-checked against the actual files, severities recalibrated); a completeness critic then swept for cross-cutting gaps. 69 agents, ~1,060 tool calls. 55/55 findings survived verification (9 with severity adjustments); the critic added 2 cross-component findings the per-dimension auditors missed. Raw structured findings: `findings-raw.json` in this directory.

**Scope note.** Depth went to the core: coordinator (buyer path, ws, pool, billing), gateway (router, storage, auth), Swift binary (coordinator client, relay, self-update), deploy/ops scripts, and docs. Lighter review: explorer static JS internals, `tools/mockprovider`, `cmd/tier2-mda-artifact`, the *content* of the 176-file spec corpus (structure and version headers were checked; prose was not re-audited), and the beta harness internals. The critic spot-checked SelfUpdate, ControlSocket, install.sh, tier-2 attestation, CORS, demo/API-key crypto, the billing formula, and the earnings endpoint and found them sound.

---

## 1. Executive Summary

**Overall health: B−.** The engineering inside the services is well above PoC norm — integer-only overflow-checked billing math, constant-time auth comparisons, hashed credentials, parameterized SQL, signature-verified self-update, deep behavior-oriented test suites — but the *control loop around* that code is below the minimum bar for a system with live users and a live money path: nothing runs the tests automatically, production binaries are hand-built with no provenance, alerting can silently be a no-op, and the public README makes a cryptographic claim the product does not implement. Zero Critical findings; 7 distinct High findings; 27 Medium; 21 Low.

**Top 3 risks:**
1. **Provider identity is effectively unauthenticated end-to-end on the live network** (completeness-critic finding, High). The installer ships no token, the Swift binary never sends an `Authorization` header, so production must run `require_provider_tokens=false` — which also disables the pinned-provider impersonation guard. Anyone can connect claiming any `provider_id`, including a pinned one ([install.sh:464-469](../../phase3-binary/dist/install.sh), [CoordinatorClient.swift:111-137](../../phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift), [ws/server.go:602-619](../../phase4-coordinator/internal/ws/server.go), [admission.go:78-81](../../phase4-coordinator/internal/ws/admission.go)).
2. **Zero CI on the money path** — the only workflow is the release build; billing/auth regressions can squash-merge looking green ([release.yml](../../.github/workflows/release.yml)). Compounded by hand-built unversioned production binaries and one silently-optional email alert channel co-hosted on the VPS it watches.
3. **Public trust claims drift** — README advertises signed receipts (zero implementation anywhere) and console billing/management features that don't exist, directly contradicting the deployed `/docs` tier-1 disclosure mandate ([README.md:22,59-83](../../README.md), [docs.md:119-124](../../phase5-gateway/internal/router/templates/docs.md)).

**Top 3 opportunities:** a ~20-line CI workflow + one test fix makes the entire 17k-line test corpus a real gate (a day); the provider-token machinery already exists (store, hashing, CLI, ws validation) and only needs wiring through installer + binary; a one-day docs-truth sweep aligns every public claim with the deployed disclosure language the team already wrote.

---

## 2. Repo Map

**Purpose.** MacProvider turns Apple Silicon Macs into remote-addressable MLX inference endpoints: OpenAI-compatible API, provider pool with routing/failover, per-request credit ledger and payouts. Two-sided users: providers (Mac owners, curl-installed binary, outbound-WS only) and buyers (drop-in OpenAI client). ~6-week-old 2-person spec-driven PoC now in **live public beta**: coordinator + gateway co-hosted on one RAM-constrained VPS ("Pearl"), N=3 real providers, real (small) money.

**Stack.** Go 1.26 (two independent modules, no cross-imports), Swift 6 / SwiftPM (provider CLI, MLX), SQLite via modernc.org/sqlite (CGO-free — load-bearing for laptop→linux cross-compile deploys), bash ops scripts, Python stdlib monitor/harness, nginx + systemd + Let's Encrypt on the VPS, GitHub Actions (release only).

**Architecture & data flow.**

```
Provider Mac (Swift binary, MLX)            Buyer (OpenAI client)
  │ outbound WSS (v1 hello | v2 ECDH+AEAD)    │ Bearer API key / demo token
  ▼                                           ▼
phase4-coordinator ◀──── proxy ───── phase5-gateway (api.malibu.tech)
  pool registry (in-mem, 1 RWMutex)     GitHub OAuth, API keys (HMAC-SHA256)
  routing/failover/breakers             quota reserve→settle→refund (SQLite)
  billing ledger (SQLite, BEGIN         kill switch, capacity, /docs, /account
    IMMEDIATE, integer credit math)
  explorer UI, admin/ledger endpoints  console.malibu.tech (static console)
```

**Key directories.**

| Path | What it is |
|---|---|
| `phase4-coordinator/` | The hub (~25k LOC Go): provider WS lifecycle, buyer API, money path (`internal/billing/`), pool, tier-2 trust, explorer. No README. |
| `phase5-gateway/` | Buyer-facing gateway (~12k LOC Go, stdlib-first): identity, quotas, proxy, admin plane. Model README. |
| `phase3-binary/` | Swift provider CLI (~11k LOC + 4.3k test LOC): ModelRuntime, CoordinatorClient, InferenceRelay, SelfUpdate, ControlSocket. |
| `beta/` | Ops harness, cron synthetic traffic, `DECISION_CRITERIA.md` (57-entry append-only decision log). |
| `scripts/`, `frontdoor/`, `*/dist/` | Release signing, install chain (get.malibu.tech → raw main → signed GitHub Releases), deploy scripts, nginx/systemd units, VPS monitor. |
| `specs/` | 176 files, 12 SPEC families with version-pinned headers and audit-finding-cited changelogs — the authoritative design record. |
| `.github/workflows/release.yml` | The only CI: tag-triggered Swift release build + sign + verify. |

**Surprises from discovery** (verified): the "signed receipts" pitch has zero implementation in any service; v1-plaintext and v2-encrypted provider protocols are both live and the security posture is config-dependent (`RequireEncryptedLeg` defaults false); operator auth predicates fail *open* on empty keys (masked by config validation); the gitignored laptop `coordinator.yaml` is the de facto production source of truth; the coordinator buyer port has no buyer auth at all (by design — loopback + gateway-only, worth re-verifying on the VPS); `handleChatCompletions` is a 510-line function with three near-duplicate failover loops; gateway billing estimate when provider omits usage is `bytes/4` including JSON envelope overhead.

---

## 3. Audit Report

Severities below are **post-verification** (verifier adjustments noted). "fact" = verifiable in code; "judgment" = design opinion. Overlapping findings from different auditors are merged.

### 3.1 The ugly parts — what needs utmost priority

1. **[High · fact] XSEC-1 — Provider identity unauthenticated end-to-end** (completeness critic). Installer writes config with no token field (`phase3-binary/dist/install.sh:464-469`); the binary never sets an Authorization header (`CoordinatorClient.swift:111-137`); coordinator defaults `require_provider_tokens=true` (`config.go:357-359`) and would *reject* every curl|bash provider — so the live tokenless beta necessarily runs with it false, and with it false `prepareProviderAdmission` skips the `pinned && !auth.validated` impersonation guard entirely (`ws/server.go:602-619`); `pinned` derives from the attacker-controlled hello `provider_id` and `admission.Admit` returns `TierPinned` with no credential (`admission.go:78-81`). **Consequence:** a remote attacker can be admitted as a pinned provider, receive buyer inference attributed to a trusted Mac, serve arbitrary responses under its identity, and poison its billing/fault stats. The entire `internal/auth/tokens.go` token system is dead code for real providers. This also worsens SECU-6: billing trusts token counts from providers whose identity is itself self-asserted.
2. **[High · fact] DEVE-1 — No test/lint/vet CI.** Only `release.yml` exists (tag-triggered build+sign; even it runs no tests). 26+13 Go test files and 16 Swift test files run only when someone remembers. AGENTS.md mandates PR review for billing/auth paths but a PR has zero required checks (`release.yml:3-12`, `AGENTS.md:32-42`). In an AI-agent-authored codebase this is the single highest-leverage fix available.
3. **[High · fact] ARCH-1/CODE-1 — `handleChatCompletions` is a 510-line god-function with three diverging copies of the failover state machine** (`buyer/server.go:840-1350`; loops at 1056-1153, 1154-1245, 1246-1349; six inline closures at 851-1045). Verifiers confirmed the drift is **already real, not theoretical**: a streaming-WS provider returning queue-full is never marked `StateBusy` (the non-streaming loop does this at :1229), and the QueueFull path at :1233 omits the `explicitRetries++` the other paths perform. This is the hottest money-path code in the system; every retry-semantics change must be hand-synced across three copies.
4. **[High · fact] DEVE-2 — The 3am story.** Alerting is one Gmail channel that silently degrades to journald-only without creds (`macprovider-monitor.py:174-180`), permanently drops an alert if one SMTP send fails (state saved regardless of delivery, :159-171, :194-195), and runs on the same VPS it watches. No external uptime check exists anywhere. A Pearl outage is structurally invisible until a user complains.
5. **[High · fact] DOCS-1/SECU-2 — README advertises an unimplemented cryptographic feature.** "Every response carries a signed receipt" + full v1 receipt schema (`README.md:22,57,59-83`); grep for receipt issuance across all three services: zero. The deployed buyer docs honestly disclaim it and *mandate* front-door consistency (`docs.md:119-124`) — the README violates the project's own SPEC-006 rule. Verifier kept High on the README finding (public, present-tense, false) while rating the security-dimension duplicate Low because the account-page disclosure partially self-corrects.
6. **[High · fact, verifier upgraded from Medium] SECU-1 — Unrate-limited public `/ws/provider` on the coordinator hostname** bypasses the rate limits the api hostname applies (`nginx-coordinator.malibu.tech.conf:65-84` has none; `nginx-api.malibu.tech.conf:10-11,124-134` has both). The only backstop is a single *global* 64-slot unauthenticated-conn semaphore with no per-IP dimension (`config.go:273`, `ws/server.go:220-224,824-831`) — one host can starve all provider (re)admissions; at N=3 that is a full inference outage.
7. **[High · judgment] DOCS-3 — No ops runbook exists for the live system.** The files *named* RUNBOOK/CONTINUE_RUNBOOK/HANDOFF are frozen Phase-1 artifacts that actively misdirect (wrong VPS IP, `mlx_lm.server` instructions, "Awaiting M4 user before going live"); real ops knowledge lives in deploy-script comments and the decision log. Incidents are routine in this beta; recovery depends on one person's memory.

### 3.2 Architecture & design (6 findings; healthy boundaries, two structural risks)

Health: better than the file sizes suggest. Service-level boundaries are sound (two Go modules, no cross-imports, no import cycles, composition-root DI via functional options, money math correctly isolated). The problems are intra-service.

- **[High] ARCH-1** — see §3.1 item 3.
- **[Medium · fact] ARCH-2 + CODE-2 + PERF-2 — Synchronous SQLite write under the global pool lock.** `ApplyHeartbeat` holds `Registry.mu` while invoking the swap-audit emitter (`pool/provider.go:483-484,542-554`), wired to a direct `auditStore.EmitSwap` INSERT (`main.go:94-111`) on a DB with `busy_timeout=5000`. A contention event can freeze *all* routing/liveness for up to ~5s. The contract is enforced only by a comment (:446-457). Rare today (swap-completion only), pool-wide blast radius when it hits. Also the documented single-coordinator scalability ceiling (one RWMutex over all pool state) — a known wall, acceptable to leave documented.
- **[Medium · fact] ARCH-3 — Uncapped `*sql.DB` handles on one SQLite file while the money path takes `BEGIN IMMEDIATE`.** Three handles opened in `main.go:47-59`, none with `SetMaxOpenConns(1)`; the gateway deliberately caps at 1 (`store.go:38-39`) — the team knows the pattern; the coordinator omits it. Latent until concurrency rises: busy-timeout tail latency or `request_log_failed` 500s after inference already ran (`buyer/server.go:1286-1290`).
- **[Medium · judgment] ARCH-4 — Gateway `router/server.go` is a 2,495-line god-file** (~10 responsibility clusters on one Server type; route table at :134-164; the self-contained disclosure-synthesis block at :831-1249 is the strongest extraction candidate). Maintainability cost, not correctness.
- **[Low · judgment] ARCH-5 — Cross-service duplication is mostly justified domain separation**; the byte-identical SQLite DSN helper (`sqliteutil/dsn.go:8-23` vs gateway `dsn.go:8-23`) and constant-time bearer compare are conscious-debt copies to document.
- **[Low · judgment] ARCH-6 — Billing/request-log persistence orchestration lives inline in handler closures** (`buyer/server.go:851-945`) vs the gateway's interface-clean pattern; money *math* is correctly isolated in `formula.go`.

**Strengths:** explorer handlers have zero direct SQL (all behind `explorer/store.go`); acyclic dependency graph with interface wiring at the composition root; `WriteHotPath` atomic request_log+ledger tx with quarantine-don't-lose fallback; gateway's role-segregated storage interfaces.

### 3.3 Code quality (6 findings; good-to-strong, disciplined money path)

Health: `go vet` clean in both modules; Swift has zero empty catches and correctly-scoped `try?`; the apparent swallowed-refund errors in the gateway are deliberate reaper-reconciled design, not carelessness.

- **[High] CODE-1** — merged into §3.1 item 3.
- **[Medium] CODE-2** — merged into ARCH-2 above.
- **[Low · judgment, verifier downgraded from Medium] CODE-3 — Buyer-facing tier-2 trust disclosure parsed from untyped `map[string]any` with silent zero-fallbacks** (`server.go:1020-1080`). Verifier found the typed `/internal/routing` metadata path dominates (:930-943) and three golden tests pin the shape; residual risk is only the Phase-1 fallback path.
- **[Low · fact] CODE-4 — Copy-pasted HTTP helpers diverging:** `readLimitedBody` identical in both services; **three** `writeError` variants with different envelope shapes (4-field vs 3-field vs 2-field at `buyer/server.go:3111`, gateway `:2304`, `billing/endpoints.go:524`) — a real client-facing inconsistency.
- **[Low · fact] CODE-5 — Dead code on the Swift connect path:** unreachable `wsTunneledMode` branch in `connectAndRunLegacy` (`CoordinatorClient.swift:280-291`, provably dead — caller gates on `!wsTunneledMode` at :236-239) plus a no-op `do/catch` rethrow (:254-257).
- **[Low · fact] CODE-6 — Hand-rolled `fmt.Sscanf`/`Sprintf` JSON serializer for capacity tier** (`store.go:767,778`) where the sibling kill-switch correctly uses `encoding/json`.

**Strengths:** fully-typed WS wire protocol with graceful unknown-frame handling on both Go and Swift sides; reserve→settle→refund covered on every traced branch with reaper backstop; fault injection isolated behind `//go:build testfaults`; load-bearing concurrency invariants documented in code.

### 3.4 Security (6 findings + XSEC-1; strongest dimension in-code, weakest at the boundaries)

Health: **no exploitable-today critical in the audited code.** Secrets clean in git (full-tree entropy scan: zero hits); API keys/tokens hashed with constant-time compares; SQL fully parameterized; OAuth CSRF/scope/redirect correct; self-update verifies signature *before* download with traversal guards; config validation fails closed on secrets. The issues are posture and trust-boundary level.

- **[High] XSEC-1** — see §3.1 item 1. **[High] SECU-1** — see §3.1 item 6.
- **[Medium · judgment] SECU-3 — Tier-2 posture defaults fully permissive** (all five enforcement flags false, `config.go:287-297`; v1 plaintext hello accepted unless `RequireEncryptedLeg`, `ws/server.go:320-323`). Actual production posture lives only in the gitignored `coordinator.yaml`; no deploy gate asserts it. (Verifier note: external transport is TLS via the tunnel — the gap is payload-level encryption + hash/attestation enforcement, not raw cleartext.)
- **[Medium · fact] SECU-4 — One shared operator key spans three planes:** gateway admin endpoints (`server.go:2061-2067`), the coordinator operator API, and — when sticky routing is on — the hot buyer path itself (`server.go:1394-1405`). One leak compromises everything; no service-vs-human credential separation.
- **[Low · fact] SECU-5 + TEST-5 — Auth predicates fail open on empty keys** (`ws/server.go:1717-1718`, `billing/endpoints.go:63`), masked solely by `config.Validate()` in a different file; no test locks the behavior. (Verifier: `AuthorizedBearer` is dead code; explorer is already fail-closed; SIGHUP reload cannot zero the key — risk is future entry points bypassing Validate.)
- **[Low · judgment] SECU-6 — Provider-reported token counts trusted for billing within a cap.** Buyer over-charge is correctly impossible (`usageFromJSON` caps at `promptEstimate+max_tokens`, `server.go:2356-2369`); the coordinator additionally clamps completion to byte-estimate (`formula.go:214`); the gateway settlement path lacks that cross-check. Residual: provider revenue gaming — compounded by XSEC-1.

**Strengths (preserve these):** HMAC-SHA256 key storage with show-once delivery; single-use session-bound OAuth state in `BEGIN IMMEDIATE` tx; signature→hash→traversal→self-test→atomic-replace update ordering; trusted-proxy-CIDR-gated client IP derivation; strict exact-origin CORS with credentials=false; nginx 404-ing operator surfaces on public vhosts as defense-in-depth; CI release workflow with SHA-pinned actions and key deleted after signing.

### 3.5 Testing (7 findings; above-average suite, broken-by-default right now)

Health: billing store tests are the standout (25 scenarios: ACID, quarantine, clamps, idempotent recovery, settlement thresholds, terminal-status immutability). WS/buyer tests exercise real WebSocket lifecycles, not mocks. Gateway integration tests cover OAuth→key→chat→settle.

- **[Medium · fact, downgraded from High] TEST-1 — The gateway suite fails right now:** `TestConsoleStaticContracts` bans `innerHTML`; the arm64golf feature added four usages (`frontdoor/console/index.html:1200,1378,1413,1432`; static literals, no XSS — verified). Suite exits non-zero on every run. (Downgrade rationale: there is no CI to turn red — see DEVE-1.)
- **[Medium · fact] TEST-3 — Wall-clock-coupled WS tests:** unconditional sleeps (`ws/server_test.go:1493,1715,1759`), package runtime ~48s vs 6-14s for all others; project memory documents prior load-dependent flakes here. (Verifier corrected the flake mechanism — server-side goroutine starvation, not the sleep itself.)
- **[Medium · fact] TEST-4 — tier2 catalog package-global singleton** (`catalog.go:81-84`) forces `ResetForTest` everywhere, blocks `t.Parallel()`, shared across at least three test packages, and carries a SIGHUP-reload race by design.
- **[Medium · judgment] TEST-6 — No cross-service integration test** between gateway and coordinator; the sticky-route header contract (`server.go:1401-1405` ↔ coordinator `internalBearerAuthorized`) has zero cross-boundary coverage; `beta/harness.py` bypasses the gateway entirely (verified against its configs).
- **[Low, downgraded from Medium] TEST-2 — `TestAuthLookupP95` 1ms hard assertion** flakes under parallel load (observed 13ms failure; 222-518µs isolated). **[Low, downgraded] TEST-5** — merged into SECU-5. **[Low · fact] TEST-7 — Swift tests (4,264 LOC, incl. self-update security regression locks) never run in CI.**

**Strengths:** behavior-named money tests (`TestWriteHotPath_503_NoLedgerRows`); `eventually()` helpers done right; `t.TempDir()` SQLite isolation everywhere; security-regression pinning in `SelfUpdateTests.swift`; the account-scoping regression lock `TestConversationKeyIsAccountScoped`.

### 3.6 Performance & resource safety (6 findings; good shape today, growth-shaped debt)

Health: body caps, bounded channels, TTL caches, fail-fast backpressure, and outbound timeouts are present essentially everywhere; coordinator retention is fail-closed with 90-day defaults. Nothing on fire at N=3. The ~25-30% coordinator overhead appears to be inherent hop/relay cost — no hidden hot-path blocking I/O found beyond the intentional durable-log-before-respond writes.

- **[Medium · fact] PERF-1 — The gateway DB can never shrink:** `RAISE(ABORT)` BEFORE-DELETE triggers on all 8 event tables + `concurrency_reservations` (`migrate.go:184-251`); the reaper only flips `quota_reservations` status (`store.go:847-860`). ≥3 permanent rows per request, forever, on a disk/RAM-constrained VPS. Deliberate tamper-evidence design with **no archival story** — must be designed before tables are big. (Verifier: hot quota queries are indexed; the per-request scan concern was overstated.)
- **[Medium] PERF-2** — merged into ARCH-2. **[Medium · fact] PERF-3 — Non-sargable unbatched retention DELETEs** (`julianday(ts_utc)` defeats the index, `requestlog/store.go:185-188`) sharing the write lock with billing's 6s hot-path budget; trivial fix (RFC3339 strings sort lexicographically).
- **[Medium · judgment] PERF-4 — Money path and explorer analytics serialize through the gateway's single SQLite connection** (`store.go:38-39`; explorer 3s budgets, `explorer.go:17`): operator opens dashboard → buyers stall at `ReserveQuota`. Cheap fix: second read-only handle (WAL).
- **[Medium · fact, upgraded from Low] PERF-6 — Demo traffic bypasses the concurrency limiter** (`if !authn.Demo`, `server.go:1362-1381`). Paying accounts cap at 2 concurrent; demo has no cap; 3 parallel demo requests saturate the N=3 MLX-serialized pool for up to `CoordinatorTimeout` — an accidental DoS path against paying buyers.
- **[Low · fact] PERF-5 — `pool.Registry.seenModels` grows unbounded and is writable by provisional providers** (`provider.go:133,194,519`; never deleted) — the one unbounded in-memory structure, writable by the least-trusted parties.
- **[Medium · fact] XPERF-2 (critic) — Provisional admission state never pruned and rewritten as one full JSON blob per provisional request** (`admission.go:99-152,209-221`; whole-state `json.Marshal` per mutation under the admission mutex). `ProvisionalRetentionDays` is configured (`config.go:281`) but **implemented nowhere** — direct evidence pruning was specified and dropped. Compounds XSEC-1 (unauthenticated callers mint provider_ids).

**Strengths:** bounded relay channels with `ErrRelayBackpressure` fail-fast; 1MB/16MB caps on every read path; universal outbound timeouts; sticky map TTL+10k sweep; goroutine exit paths verified clean; purpose-built indexes matching query patterns in both stores.

### 3.7 Dependencies (8 findings; excellent posture, zero process)

Health: among the best dependency *postures* at this maturity — gateway has two direct deps, everything exact-pinned and lock-filed, zero vendored/CDN code, deliberate shared CGO-free SQLite driver enabling the cross-compile deploy model. The *process* is set-and-forget, and it already let a retracted driver sit in production.

- **[Medium · fact, downgraded from High] DEPE-1 — Both services run modernc.org/sqlite v1.33.0, retracted by its authors ("breaks clients"), 19 minors behind** (`go.mod:12`/`:7`; verified live via `go list -m -u all`). Downgrade rationale: the retraction was *known and deliberately held* (documented in `implementation-notes.html` as OQ-1) and 320k-request stress runs showed zero driver pathology — operator-acknowledged debt, not a surprise. Still the top dependency action.
- **[Medium · fact] DEPE-2 — No update process at all** (no dependabot/renovate; `go mod tidy` drift proven by goldmark mislabeled `// indirect` while directly imported, `pages.go:11` vs `go.mod:17`). This is the systemic cause of DEPE-1.
- **[Medium · fact] DEPE-4 — Publicly distributed binary ships zero third-party license attribution** despite statically linking Apache-2.0 deps whose NOTICE reproduction is required (`package.sh:52-60`; verified absent in shipped v1.2.4-v1.2.6 tarballs).
- **[Low, downgraded] DEPE-3 — swift-nio exact-pinned at 2.65.0 (~36 minors behind, security fixes upstream)** — downgraded because the NIO server binds 127.0.0.1 unconditionally (`HTTPServer.swift:36`) and the coordinator WS leg uses URLSession, not NIO. Bump on next release cycle. **[Low] DEPE-5 — yaml.v3 officially archived/unmaintained** (operator-config-only input; note and move on). **[Low] DEPE-6 — swift-log is a declared, linked, never-imported dead dependency.** **[Low] DEPE-7 — No Python manifest; cron runtime is an EOL-Python-3.9 venv** (verifier: `harness.py` imports `requests`+`yaml` too — the "stdlib-only" claim was wrong). **[Low] DEPE-8 — gobwas/ws upstream dormant since May 2024** (current version; contingency note only — and `admission.go` leaks its `StatusCode` type in a signature, so a swap is slightly more than `internal/ws`-contained).

### 3.8 DevEx & operations (8 findings; great artifacts, broken control loop)

Health: lopsided. What exists is unusually good (incident-encoding fail-closed deploy gates, SHA-pinned release CI with key hygiene, hardened systemd units, curated `.gitignore` with rationale). What's *missing* sits below the bar for live money: see §3.1 items 2 and 4, plus:

- **[Medium · fact] DEVE-3 — Production Go binaries are hand-built with no script, no commit provenance, no rollback.** The only build documentation is a comment (`deploy-pearl-vps.sh:9`); `/healthz` reports a hardcoded `"0.1.0"` (`buyer/server.go:576`), so nobody can answer "which commit runs on Pearl?"; rollback = remembering an untracked `.bak` exists.
- **[Medium · fact] DEVE-4 — The gateway (money service) is the only component with no scripted deploy and no config gate**, and the one cross-component safety check (C2 timer ordering — a *real past production incident*) is structurally skipped on every standard deploy because the coordinator script never passes the gateway config (`deploy-pearl-vps.sh:50`, `check-deploy-config.sh:18-19,62-74`).
- **[Medium · fact] DEVE-5 — The production coordinator config's single source of truth is a gitignored laptop file, and deploys clobber the VPS copy unconditionally** (`coordinator.yaml.example:79-83` documents the lesson; `deploy-pearl-vps.sh:73,79` scp with no diff/backup). Project memory records a near-miss where an agent session sanitized the local file.
- **[Medium · judgment] DEVE-6 + DOCS-8 — No Makefile/canonical dev commands; the 25k-LOC coordinator has no README at all.** Fresh agent sessions re-derive the dev loop each time; the gateway README proves the standard is achievable.
- **[Low · fact] DEVE-7 — Coordinator secret handling is the weak half of an asymmetric pattern:** plaintext `operator_key` in YAML regex-parsed by a root-running monitor, vs the gateway's env-file indirection. **[Low · fact] DEVE-8 — 45 Phase-1 log/result artifacts git-tracked**; everything else hygiene-suspect (profraw, build-release/, .venv, dist binaries, secret configs) verified properly ignored.

**Strengths:** `check-deploy-config.sh` encodes actual incidents and hard-fails; idempotent coordinator deploy with provider-connected restart refusal + FORCE_RESTART escape; release workflow SHA-pins actions, validates tag format, deletes the signing key, re-verifies post-publish; uniform systemd hardening with RAM caps sized to the host; transition-based (not poll-spam) monitor design.

### 3.9 Documentation (8 findings; sharply bimodal)

Health: the machine-facing layer (spec corpus version discipline, AGENTS.md, the deployed `/docs` honesty) is far above PoC norm. The human-facing summary layer has decayed: see §3.1 items 5 and 7, plus:

- **[Medium · fact] DOCS-2 — README claims console management/billing features that don't exist** (three views in the actual console; zero matches for earnings/billing/manage — `README.md:31,35-40` vs `frontdoor/console/index.html:493,530,539`).
- **[Medium · fact] DOCS-4 — `specs/README.md` indexes 3 of 12 spec families at versions ~6 revisions stale** — the only discoverability layer over the authoritative corpus is wrong, in a project whose whole methodology is version-pinned specs.
- **[Medium · fact] DOCS-5 — Project CLAUDE.md feeds every agent session stale "locked" baselines** (binary v1.2.3 / SPEC-001 v1.2.2 / SPEC-002 v1.1.3 vs actual 1.3.0 / v1.3 / v1.3.5; `CLAUDE.md:151-153`, and AGENTS.md routes all agents to it).
- **[Medium · judgment] DOCS-6 — Provider economics (rates, share, payout threshold, earnings endpoint, promotion criteria, reaping rules) documented on zero provider-visible surfaces** — money disputes are currently unresolvable by reference, and seller recruitment's first question has no public answer.
- **[Low · fact] DOCS-7 — Version-drift cluster:** README says v1.2.5 while its own badge and link say v1.3.0; gateway README pins SPEC-006 v0.5 (actual v0.8.3); SPEC-002's header self-contradicts on its SPEC-001 dependency.

**Strengths:** the tier-1 disclosure in `docs.md:115-126` is the gold standard the README should be held to; gateway README is a model component doc; spec headers with audit-finding-cited changelogs; `DECISION_CRITERIA.md`'s 57 dated append-only entries are genuine institutional memory.

---

## 4. Improvement Strategy

### Theme 1 — Close the control loop around the code (CI, alerting, provenance)
**Explains:** DEVE-1, DEVE-2, DEVE-3, DEVE-4, TEST-1, TEST-7, DEPE-2.
**Target state / principle:** *every change to the money path passes an automated gate, and every production failure reaches a human through a channel that doesn't live on the failing host.* Concretely: PR-triggered `go vet`+`go test` for both modules as required checks; suites green; external uptime check on both `/healthz` endpoints; version-stamped builds with a scripted gateway deploy; Dependabot at monthly cadence.
**Done when:** CI is a required check and red blocks merge; `curl healthz` failure produces a phone notification within 5 minutes from a non-Pearl service; `--version` on the VPS binaries answers "which commit"; the C2 cross-check runs on every deploy.

### Theme 2 — Make trust boundaries fail closed and code-enforced, not config-dependent
**Explains:** XSEC-1, SECU-1, SECU-3, SECU-4, SECU-5/TEST-5, PERF-6, XPERF-2.
**Target state / principle:** *provider identity is authenticated; security posture is asserted at deploy time; empty credentials deny.* Wire the existing token machinery through installer+binary; rate-limit the coordinator WS vhost; add tier-2/auth posture assertions to the deploy gate; invert fail-open predicates; cap demo concurrency.
**Done when:** production runs `require_provider_tokens=true` with all N=3 providers connected via tokens; both `/ws/provider` vhosts carry identical limits; a deploy with permissive tier-2 flags or empty operator key fails loudly; a test locks fail-closed behavior.

### Theme 3 — Public claims must match delivered reality
**Explains:** DOCS-1/SECU-2, DOCS-2, DOCS-3, DOCS-4, DOCS-5, DOCS-6, DOCS-7.
**Target state / principle:** *the README is held to the same honesty standard as the deployed `/docs` disclosure (the project's own SPEC-006 mandate).* Receipts → explicit roadmap section or implemented; console claims trimmed to reality; one current OPS.md; index/CLAUDE.md versions regenerated or replaced with pointers; a short provider-economics page.
**Done when:** every present-tense capability claim in README/console copy has a corresponding code path; RUNBOOK/HANDOFF carry superseded banners; specs index lists all 12 families at correct versions.

### Theme 4 — De-risk the money-path hot spot structurally
**Explains:** ARCH-1/CODE-1, ARCH-2/CODE-2/PERF-2, ARCH-3, ARCH-6.
**Target state / principle:** *one failover state machine, no I/O under the global lock, serialized SQLite writers.* Fix the two confirmed loop divergences immediately; then extract a single `forwardWithFailover` skeleton behind the existing 4,400-line test suite; emit swap audits after unlock; `SetMaxOpenConns(1)`.
**Done when:** the three loops are one; queue-full handling is identical across transports (with a regression test); no SQLite call executes under `Registry.mu`; coordinator stores are capped like the gateway's.

### Theme 5 — Decide growth-shaped resource debt now, while tables are small
**Explains:** PERF-1, PERF-3, PERF-4, PERF-5, XPERF-2, DEPE-1.
**Target state / principle:** *every persistent store has a designed retention/archival story; nothing grows monotonically unbounded.* Archive-rotate (or aged-delete) design for the gateway DB; reservation cleanup; sargable batched prunes; admission-state pruning implementing the already-configured `ProvisionalRetentionDays`; sqlite driver bump.
**Done when:** a written retention decision exists per table (kept-forever must be explicit); prune queries use the index; admission blob size is bounded; driver is current and suites pass.

### Explicitly NOT recommended (effort/payoff judgment)
- **Don't restructure the phase-numbered repo layout** — historical artifact, harmless, renaming would break the spec corpus's cross-references.
- **Don't merge the two Go services or build a shared module yet** — the duplication is mostly justified domain separation; document the 3 cloned helpers as conscious debt; revisit only if a third service appears.
- **Don't chase the ~25-30% coordinator overhead** — it's inherent hop cost; no code defect found.
- **Don't shard/replace the single in-memory pool Registry** — known ceiling, fine at this scale; document it.
- **Don't adopt enterprise observability (Prometheus/Grafana/etc.)** — one external pinger + the existing monitor with delivery fixed is the right size.
- **Don't migrate off yaml.v3 or gobwas/ws now** — decision-log notes only.
- **Don't rush receipt implementation** — it's a product decision (Open Question 1); the immediate fix is honest copy.

---

## 5. Task Plan

### Quick wins (high impact, S effort — do immediately)
| ID | Task | Why it's a quick win |
|---|---|---|
| QW-1 (=M0-1) | Add `ci.yml`: vet+test both Go modules on PR/push | ~20 lines, free runners, activates 17k LOC of existing tests |
| QW-2 (=M0-2) | Fix `TestConsoleStaticContracts` (DOM methods for 4 arm64golf blocks) | Unbreaks the gateway suite so QW-1 is green |
| QW-3 (=M0-4) | External healthcheck (healthchecks.io/UptimeRobot) on both `/healthz` | Free, 30 min, covers VPS/nginx/monitor death |
| QW-4 (=M1-3) | README truth sweep (receipts→roadmap, console claims, version pins) | Pure copy edit; removes a false public cryptographic claim |
| QW-5 (=M2-3) | `SetMaxOpenConns(1)` on coordinator store handles | 3 lines, matches gateway's proven pattern |
| QW-6 (=M2-7) | `dependabot.yml` (gomod ×2, swift, monthly) + `go mod tidy` | 15 min; fixes the systemic cause of the retracted-driver miss |
| QW-7 (=M3-7) | Regenerate `specs/README.md`; replace CLAUDE.md hardcoded versions with pointers | 30 min; stops feeding agents stale baselines |

### Milestone 0 — Safety net (before touching anything else)
| ID | Task | Files/areas | Acceptance criteria | Effort | Risk | Deps |
|---|---|---|---|---|---|---|
| M0-1 | **Test/vet CI for both Go modules** on PR + push to main; mark as required checks | `.github/workflows/ci.yml` | PR with failing billing test cannot merge; runtime <5 min | S | None | M0-2 |
| M0-2 | **Fix the broken console contract test** — rewrite 4 innerHTML blocks via `createElement`/`textContent` (keep the blanket ban) | `frontdoor/console/index.html:1200,1378,1413,1432` | `go test ./internal/router/...` green; console renders identically | S | Low (static UI) | — |
| M0-3 | **De-flake load-sensitive tests:** convert `TestAuthLookupP95` to a Benchmark; replace `ws` sleep-then-assert at :1493 with eventually-loop | `store_test.go:729-765`, `ws/server_test.go:1493` | `go test ./... -count=5` green under parallel load | S | None | — |
| M0-4 | **External uptime monitoring** + monitor delivery fix: only `save_state()` after ≥1 non-journald delivery (or re-alert while condition persists); confirm Gmail app password set in prod | external service; `macprovider-monitor.py:159-195` | Kill nginx on a test window → notification arrives; SMTP failure no longer drops a transition | S | Low | — |
| M0-5 | **Version-stamped build + rollback:** per-service build script (`-ldflags -X main.version=$(git describe --dirty)`, refuse dirty tree), deploy keeps `coordinator.prev`, `/healthz` reports real version | new `build-linux.sh` ×2; `deploy-pearl-vps.sh`; `buyer/server.go:576` | `curl healthz` on Pearl names the deployed commit; documented one-command rollback | M | Low | — |

### Milestone 1 — Critical fixes (security & correctness)
| ID | Task | Files/areas | Acceptance criteria | Effort | Risk | Deps |
|---|---|---|---|---|---|---|
| M1-1 | **Wire provider tokens end-to-end** (closes XSEC-1; sketch below): binary sends Bearer; installer/onboarding provisions token; migrate N=3 providers; flip `require_provider_tokens=true` in prod | `CoordinatorClient.swift`, `Config.swift`, `install.sh`, coordinator config/runbook; spec patch (SPEC-001/002/003) | Prod runs require=true; tokenless connect rejected (verified live); pinned impersonation guard active; all 3 providers connected | XL → break down | **High** (can disconnect the live pool; staged rollout required) | M0-1 |
| M1-2 | **Fix the two confirmed failover divergences** *ahead of* the big refactor: streaming queue-full must mark `StateBusy`; QueueFull path must count `explicitRetries++` — each with a regression test | `buyer/server.go` streaming loop (~1066-1152), :1233 | New tests fail on old code, pass on new; behavior matches non-streaming loop | S | Medium (money path — PR + review per AGENTS.md) | M0-1 |
| M1-3 | **README/console truth sweep** (DOCS-1/2/7, SECU-2): receipts → "Roadmap — not yet implemented"; trim console feature list; drop hardcoded release version; align with `docs.md` tier-1 language | `README.md`, frontdoor copy | No present-tense claim without a code path; reviewed against `docs.md:119-124` mandate | S | None | — |
| M1-4 | **Rate-limit coordinator `/ws/provider`** identically to api vhost; make the unauthenticated-conn semaphore per-IP (or drop the coordinator-hostname WS path entirely) | `nginx-coordinator.malibu.tech.conf:65-84`; `ws/server.go:220-224,824-831` | Burst test from one IP cannot exhaust admission slots; legit provider reconnect unaffected | M | Medium (nginx prod change; test on staging window) | — |
| M1-5 | **Fail-closed auth predicates** + regression test (SECU-5/TEST-5): empty operator key denies; delete dead `AuthorizedBearer` | `ws/server.go:1717-1718`, `billing/endpoints.go:63`, `auth/tokens.go:37-38` | Test constructing a server with empty key gets 401 on `/poolz`; prod config unchanged | S | Low | M0-1 |
| M1-6 | **Deploy-gate hardening** (DEVE-4, SECU-3, DEVE-5): script the gateway deploy (clone coordinator script shape); make C2 cross-check mandatory (fail if gateway.yaml missing); assert tier-2/auth posture flags; remote-config diff+backup before overwrite | `phase5-gateway/dist/`, `check-deploy-config.sh`, `deploy-pearl-vps.sh` | Standard deploy runs C2; permissive-posture or diverged-config deploy fails loudly with FORCE escape | M | Low | — |
| M1-7 | **Bump modernc.org/sqlite → current** in both modules; full suites incl. `-race` and ACID/concurrency tests; deploy via PR path | both `go.mod` | Suites green; one canary day on Pearl with no SQLITE errors in logs | M | Medium (driver under the ledger — but strong test coverage) | M0-1 |
| M1-8 | **Cap demo concurrency** (PERF-6): small fixed cap keyed on demo identity via existing reservation machinery | `server.go:1362-1381` | 3 parallel demo requests no longer saturate the pool; paying-buyer p99 unaffected by demo bursts | S | Low | — |

### Milestone 2 — High-leverage improvements
| ID | Task | Files/areas | Acceptance criteria | Effort | Risk | Deps |
|---|---|---|---|---|---|---|
| M2-1 | **Extract single `forwardWithFailover`** from `handleChatCompletions` (sketch below) | `buyer/server.go:840-1350` | Three loops become one skeleton + per-transport dispatch; full suite green; zero behavior diff on logged fields | L | High (hottest money path — one transport per PR, behind M0-1 + M1-2) | M0-1, M1-2 |
| M2-2 | **Move swap-audit emit off the pool lock** (ARCH-2/CODE-2/PERF-2): collect under lock, dispatch via buffered channel after unlock | `pool/provider.go:482-554`, `main.go:94-111` | No SQL under `Registry.mu` (assert via test hook); exactly-once gate preserved | S | Low | M0-1 |
| M2-3 | `SetMaxOpenConns(1)` on coordinator stores (ARCH-3) | `main.go:47-59` | Concurrent-write test shows serialization, no SQLITE_BUSY | S | Low | M0-1 |
| M2-4 | **Gateway retention/archival design** (PERF-1) + read-only second DB handle (PERF-4): decide archive-rotate vs aged-delete per table (Open Q4); delete terminal-state reservations >N days; route explorer/status reads through RO handle | `migrate.go`, `store.go`, `main.go` | Written retention decision per table; explorer query under load no longer blocks `ReserveQuota` (measured) | M | Medium (touches money tables — migration + tests) | Open Q4 |
| M2-5 | **Implement `ProvisionalRetentionDays`** + per-record admission persistence (XPERF-2); bound `seenModels` per provider (PERF-5) | `ws/admission.go`, `admission_store.go`, `pool/provider.go` | Admission state size bounded under churn test; config knob actually consumed | M | Low | M0-1 |
| M2-6 | **Coordinator README + root Makefile** (DEVE-6/DOCS-8): build/test/mockprovider/cross-compile/deploy-pointer; `make test|build-linux|check` | new `phase4-coordinator/README.md`, root `Makefile` | A fresh session builds+tests the coordinator from docs alone; CI uses `make test` | M | None | — |
| M2-7 | Dependabot + tidy (DEPE-2) | `.github/dependabot.yml`, gateway `go.mod` | goldmark classified direct; monthly PRs arrive | S | None | M0-1 |
| M2-8 | **Write OPS.md; archive Phase-1 runbooks** (DOCS-3): topology, safe restart (FORCE_RESTART semantics), settlement, monitor response, key rotation, gateway deploy; superseded banners on RUNBOOK/CONTINUE_RUNBOOK | new `OPS.md`; root runbooks | A non-author can execute a coordinator restart + rollback from OPS.md alone | M | None | M0-5, M1-6 |
| M2-9 | **Cross-service integration test** (TEST-6): both services via httptest + mockprovider; OAuth→key→chat→settle; assert sticky-header contract + both stores' rows | new `test/integration/` | Runs in CI <2 min; fails on a sticky-header rename | M/L | Low | M0-1 |

### Milestone 3 — Quality & polish
| ID | Task | Effort | Notes |
|---|---|---|---|
| M3-1 | Sargable, batched retention DELETEs (PERF-3) | S | `WHERE ts_utc < ?` + LIMIT loop |
| M3-2 | Split operator key into service-to-service vs human-admin (SECU-4); coordinator env-file secret indirection + de-root the monitor (DEVE-7) | M | Rotate independently |
| M3-3 | THIRD-PARTY-NOTICES.txt in release tarball (DEPE-4) | S | Script over Package.resolved checkouts |
| M3-4 | swift-nio bump + drop dead swift-log (DEPE-3/6); Swift test job in CI on macos runner (TEST-7) | M | Fold into next binary release |
| M3-5 | `git rm` Phase-1 `logs/`+`results/` raw artifacts, keep REPORT.md in place (cross-referenced widely); delete stale profraw; `beta/requirements.txt` (DEVE-8, DEPE-7) | S | |
| M3-6 | Provider economics & lifecycle doc on a provider-visible surface (DOCS-6) | M | Formula in plain language, share, payout threshold, earnings endpoint usage, promotion criteria, sleep/reaping behavior |
| M3-7 | Specs index regen + CLAUDE.md/AGENTS version pointers; fix SPEC-002 depends-on self-contradiction (DOCS-4/5, DOCS-7) | S | Add "grep old version" to release checklist |
| M3-8 | Code polish: unify 3 `writeError` envelope variants; delete dead Swift branch + no-op catch; `Sscanf`→`encoding/json`; tier2 catalog DI instead of global (CODE-4/5/6, TEST-4) | M | Each is S alone |
| M3-9 | Gateway `server.go` file split by concern; extract disclosure synthesis (ARCH-4) | M | Pure file moves within package first |
| M3-10 | Hoist `logRowWithBilling` into a billing-recorder type (ARCH-6) | S/M | Pairs naturally with M2-1 |

### Implementation sketches — top 3 tasks

**M1-1 Provider tokens end-to-end (the one XL).**
Approach: all server-side machinery exists (`auth/tokens.go` store + hashing + constant-time compare; `coordinator-cli issue-token`; ws validation at `server.go:236-262`). The work is client-side wiring plus migration choreography.
Steps: (1) Spec patch first per house rule (SPEC-001 token config key + auth header; SPEC-003 onboarding flow). (2) Swift: add `provider_token` to `Config.swift` (flag/env/yaml triple-exposure per house convention); set `Authorization: Bearer` on the WS request in `CoordinatorClient` (both v1 and v2 paths). (3) Installer: accept a token interactively or via env; write it into config (decide Open Q2 for strangers — operator-issued vs self-serve provisional tokens). (4) Migration: issue tokens for M1/M4/air8gb; ship binary release; update each provider's config (relaunch txt-file pattern per past practice); verify all three connected *with* tokens while `require_provider_tokens` still false. (5) Flip to true; verify a tokenless connect is rejected; confirm the pinned-impersonation guard now executes (`ws/server.go:603-619`).
Gotchas: don't flip the flag until every provider heartbeats with a validated token or you orphan the pool (the deploy script's provider-connected restart guard will fight you — plan a window); provisional/open-onboarding tier needs a product decision on token issuance (Q2); keep the v1.2.x-binary compatibility story explicit — old binaries can't send tokens, so the flag flip is the compatibility cutoff.

**M0-1/M0-2 CI + suite green.**
Approach: one workflow, two ubuntu jobs (`cd phase4-coordinator && go vet ./... && go test ./...`; same for gateway), `timeout-minutes: 10`. Fix the console test first or CI is born red: rewrite the four arm64golf innerHTML sites with `document.createElement` + `textContent` (data already escaped via `escArm`, so it's mechanical), keeping the test's blanket ban as the simpler contract.
Gotchas: the `ws` package costs ~48s (fine); keep `TestAuthLookupP95` out of the gate (M0-3) or it flakes on loaded runners; defer `swift test` to a separate non-required macos job (cost/latency); mark both Go jobs required in branch protection or the gate has no teeth — that's the actual deliverable.

**M2-1 `forwardWithFailover` extraction.**
Approach: strangle, don't rewrite. First land M1-2's divergence fixes with tests so the refactor target is *correct* behavior. Then: (a) extract the 5×-duplicated advance-to-next-provider tail (`selectProviderExcluding` + `routingDone` + counters + `logRoutingDecision`) into one helper — pure mechanical, zero risk; (b) define `transportResult` normalizing `wsForwardResult`/HTTP outcomes into one classification (retryable? failover? mark-busy? billable?); (c) one loop: `for { dispatch(transport); classify; record; advance }` with per-transport dispatch closures; migrate HTTP-forwarding first (simplest), non-streaming WS second, streaming last (SSE lifecycle is the tricky one — first-chunk-received commits the attempt).
Gotchas: billing attempt numbering (`attempt_n`) and `logAttempt` ordering must stay byte-identical — the ledger and its quarantine logic key off them; the 4,400-line `server_test.go` is the safety net, so run it per-commit, one transport per PR; preserve the subtle intentional differences (per-attempt context timeout is HTTP-only) as explicit transport parameters, not lost behavior.

---

## 6. Open Questions (need a human decision)

1. **Receipts: build or retract?** The README's signed-receipt schema is the product's headline differentiator and has zero implementation. Implementing it properly touches binary signing, gateway pass-through, and key distribution (~weeks). Until decided, M1-3 ships honest copy. Which is it, and on what timeline?
2. **Provider token issuance model for open onboarding.** Pinned providers clearly need operator-issued tokens. For curl|bash strangers (provisional tier): operator-issued (friction, but authenticated) or self-serve provisional tokens minted at first admission (preserves open onboarding, still kills pinned impersonation)? SPEC-003's intent here needs an explicit ruling.
3. **Target tier-2 posture for this beta.** Which of the five enforcement flags (encrypted leg, hash verification, attestation, behavioral safety, encoding validation) should production assert *now* vs at scale? M1-6's deploy gate needs the answer to know what to assert.
4. **Gateway append-only-forever: requirement or default?** Is tamper-evidence-in-place a deliberate compliance posture (→ archive-rotate with cold storage), or is aged-out deletion of event rows acceptable (→ trigger amendment)? Determines M2-4's design.
5. **Deprecation candidates:** `beta/web` legacy demo (currently 410-gated — delete?), the ~10 historical release tarballs in `phase3-binary/dist/`, Phase-1 `logs/`+`results/` artifacts, the root `.venv`. Any objections to removal?
6. **Performance target.** Is the ~25-30% coordinator-path overhead acceptable as a standing property of the product, or does a buyer-facing latency SLO exist that would force optimization work the audit found no easy wins for?
7. **Console roadmap vs copy.** DOCS-2's fix trims README claims to the three real views — unless provider management/earnings views are imminent, in which case keep the copy and build the views. Which way?

---

*Generated by a four-phase multi-agent audit (discovery → dimension audits → per-finding adversarial verification → completeness critic), 2026-06-10. All citations verified against working-tree state at commit `5b34f8c`.*
