# SPEC-001 — Phase 3 Binary: Mac Provider Inference CLI

**Version:** 1.9.4 (2026-09-04, BYOM slice-1 rework: earning-verdict-first human output + `models switch` / `models adopt-recommendation` in the §6.14a oracle)
**Revision note (historical, superseded by v1.7):** v1.3.1 added the `provider_token` (yaml, top-level) /
`MACPROVIDER_PROVIDER_TOKEN` (env) / `--provider-token` (CLI) config key
and mandates the binary attach `Authorization: Bearer <token>` on the
coordinator WS connect when the token is non-empty. Closes
[XSEC-1](../audits/2026-06-10/REPO_AUDIT.md) — "Provider identity
unauthenticated end-to-end" — for pinned providers. No change to the
v2 ECDH handshake itself; the Bearer header is an HTTP-level credential
checked at the WS upgrade (SPEC-002 v1.3.5 § auth) before the v2
handshake starts. Backwards-compatible: a v1.3.1 binary with no
`provider_token` configured sends no Authorization header, matching v1.3
behavior, so a coordinator running with `auth.require_provider_tokens=false`
continues to accept tokenless legacy fleets. Flag flip on the
coordinator is the compatibility cutoff for old binaries.

**Change log v1.9.3 (2026-08-28, BYOM model command taxonomy):** The live
model-management commands are registered as the compatibility oracle for BYOM
follow-on work. `models list` and `models browse` retain the
`model_catalog_json_v1` capability and exact JSON schema strings
`models_list.v1`, `models_browse.v1`, and `model_catalog_error.v1`; the
checked-in Malibu manifest tokens remain `models list.v1` and
`models browse.v1`. New BYOM commands are reserved to SPEC-046/SPEC-047 and
MUST NOT reuse the legacy browse/list schemas or make browse rows actionable.

**Change log v1.9.2 (2026-07-19, fragment referral capability):** A
fragment-aware CLI advertises `referral_fragment_links_v1` in addition to the
status/action capabilities. Malibu suppresses all referral UI without it, so an
already-shipped path/query client cannot falsely negotiate the incompatible
fragment grammar. The first such CLI release is 1.8.49; this does not couple the
independently versioned Malibu app to the CLI marketing version.

**Change log v1.9.1 (2026-07-19, fragment-only referral links):** Public
invite and X-share credentials use the exact
`join_base_url#/<invite_code>[?c=<challenge>]` grammar so website, CDN, and
referrer request URLs never contain referral material. The CLI rejects the
legacy path/query form and validates the fragment before projecting it.

**Change log v1.9.0 (2026-07-16, SPEC-034 integration):**
- The v1 `hello` and v2 initial/proof `auth_request` bootstrap shapes gain an
  OPTIONAL `referral_code` string. It is emitted only from a supported CLI-owned
  onboarding attempt and is covered by the v2 signed transcript. SPEC-003
  FR-C9.7 owns coordinator emission/admission behavior; SPEC-034 owns code policy.
- Local status may advertise `referral_bootstrap_v1` when the installed CLI
  accepts the protected referral-journal handoff, and independently advertise
  `referral_status_v1` for the sanitized owner-only control-socket status
  projection. `referral_advocacy_v1` independently advertises the complete typed
  challenge/verify/cancel/reopen action set. Neither capability exposes the
  provider bearer or raw referral code, and Malibu never calls coordinator
  referral APIs directly.

**Change log v1.8.4 (2026-07-15, runbook item 23 — `auth_state` ack field):**
- §6.5.1 adds the OPTIONAL `auth_state` string on the v1 `hello_ack` and v2 accepted `auth_response` frames — the coordinator's admission verdict (`bearer_validated` / `self_minted` / `bearerless_duplicate`). SPEC-001 owns the field shape/domain; emission is SPEC-003 FR-C9.2a and autoupdate interpretation is SPEC-020 v0.1.7. Additive `omitempty`; pre-v1.8.4 binaries ignore the key.

**Change log v1.8.3 (2026-07-14, issue #585 — admission identity):**
- The v2 initial frame carries CLI-owned current/pending admission keys and an explicit
  recovery marker. Challenge/response frames carry the selected key, authoritative
  generation, active key, and verified-key role.
- Old-key-signed generation-CAS rotation, seven-day previous-key rollback, response-loss
  convergence, and dual-control operator recovery are normative in SPEC-026 §4.3.
- Every durable admission identity rejects v1 bearer-only downgrade, irrespective of
  provider-ID prefix. `/v1/status` reports local custody, coordinator generation/key role,
  pending/previous grace, transition error, and the exact redacted recovery action.

**Change log v1.8.2 (2026-07-14, issue #585 — local status and recovery slice):**
- `/v1/status` now publishes a versioned, capability-gated local contract. Each
  response identifies the observation, its bounded validity, the stable running
  service instance, and the last CLI-authored lifecycle transition. Malibu remains a
  reader/renderer; `macprovider-cli` is the sole lifecycle authority.
- Provider credential diagnostics now distinguish missing, locked, access-denied,
  corrupt, conflict, unavailable, and ready custody without emitting token bytes or a
  token-derived identifier. `credentials status` exposes the same redacted v1
  contract out of process when the HTTP service cannot start.
- `credentials repair` is a narrow CLI-owned transaction. It may import a missing
  item or replace a corrupt item only from an owner-only regular config file
  whose identity remains unchanged during inspection. Conflict and Keychain
  access-state failures refuse mutation. Malibu may invoke this command through the
  validated installed CLI but never writes the Keychain item itself.
- Admission proof signing is CLI-owned. The dormant Malibu identity-signature bridge,
  its control-socket frames, and its unsigned timeout fallback are removed; a
  credentialed provider produces the proof from its durable CLI Keychain admission
  identity or fails coordinator admission.

**Triage note 2026-06-26 (no version bump, no normative change):**
- §10 OQ-1 (streaming usage chunk client compat) and OQ-2 (tier announcement format) are marked RESOLVED inline. Pointer: `docs/OPEN_QUESTIONS.md` 2026-06-26 triage row for SPEC-001.

**Change log v1.8.1 (2026-07-14, issue #585 — Option 2 credential-custody slice):**
- The launchd-managed `macprovider-cli` becomes the authority for the provider bearer.
  It stores the bearer in the macOS login Keychain under service
  `live.malibu.provider.provider-token.v1`, account `<provider_id>`, using the
  legacy login-Keychain default ACL/designated requirement and non-interactive reads.
  It deliberately does not claim a Data-Protection-Keychain accessibility class.
- Existing layered YAML/environment input remains a compatibility source. On startup,
  an existing CLI-Keychain value wins; otherwise the CLI imports the compatibility
  value and verifies a readback before use. A matching private YAML value remains only
  as migration rollback state until that restarted provider proves coordinator
  admission; the CLI then removes it with an exact compare-and-remove transaction.
- Adds `credentials import --config` and `credentials verify --config`. Malibu uses two
  separate installed-CLI invocations against one immutable 0600 snapshot to stage
  custody, but Malibu never removes the live YAML credential. `/v1/status` gains a
  redacted `credential` lifecycle object; no token bytes or token-derived identifier
  are exposed.
- The release carrying this behavior is `binary_version` **1.8.34** (Malibu build 34).
- Release signing pins the stable CLI identifier `live.malibu.provider.cli` so the
  default Keychain ACL is based on a stable designated-requirement identity across
  signed updates. Real signed vN→vN+1, reboot, login, and locked-Keychain validation is
  still a rollout gate under issue #585.

**Change log v1.8 (2026-07-13, issue #540 — in-band AEAD rekey):**
- The release carrying this capability is `binary_version` **1.8.32** (Malibu
  build 32), so 1.8.31 installations can discover it through the normal
  coordinator-advertised update path.
- The v2 initial-stage `tier2_capabilities` object adds
  `in_band_aead_rekey_v1: true`, confirmed by the coordinator in the accepted
  encrypted-leg session.
- §6.15 adds inbound `aead_rekey_request` / `aead_rekey_commit` and outbound
  `aead_rekey_response` / `aead_rekey_committed`. SPEC-008 v0.5 owns their
  cryptographic and lifecycle semantics. The binary keeps one WebSocket and one
  assigned identity; no application inference frame is retransmitted.

**Change log v1.7 (2026-07-12, binary-1.8.31 drift reconciliation — spec-only, reconciled to shipped code; code is source of truth):**
The spec header had drifted to 1.6 (2026-06-22) while the shipped `binary_version`
advanced to **1.8.31**. v1.7 reconciles the three drift areas the runbook named,
plus the additive wire surface that accumulated in between. No code change.
- **FR-11 (rewritten).** The "bounded FIFO queue, depth = 2× concurrency, HTTP
  `429` + `Retry-After`, `rate_limit_exceeded`" contract was **never implemented**
  and is retired. Shipped: a **blocking `AsyncSemaphore(max(1, max_concurrency))`**
  serializes the HTTP inference path (excess requests await a permit, never
  rejected); the WS-tunneled path instead hard-rejects at capacity=1 with
  `error_queue_full` (FR-27). The §status-code `429` row is struck.
- **FR-16 (rewritten).** No wake-event detection exists (no IOKit power / wall-clock
  jump). The coordinator `warm_up` command is a **no-op** (`degraded`→`ready`, no
  inference). The real warm-up is an **idle-triggered `IdlePrewarmer`** with six
  `idle_prewarm.*` config keys (FR-19), gated on idle-threshold **and** enabled /
  zero-in-flight / thermal / power / model-loaded, battery-gated off by default,
  emitting a single `idle_prewarm_event` frame type whose `event` field carries the
  raw lifecycle string (`idle_prewarm_fired`/`_completed`/`_failed`/
  `_cancelled_by_real_request`/`_skipped`) (§6.15.4).
- **Control socket (§6.9.2, R-6.9.3a).** The shipped `ControlSocketFrame` enum has
  **17** frame types; §6.9 previously documented 5. The 12 additions are enumerated
  with owner cross-refs — receipt-key rotation (SPEC-015), App-track
  metrics/pause/resume/shutdown (SPEC-025 §5.2), and the identity-signature
  challenge/response pair (SPEC-026 §4.3). SPEC-001 owns the transport; the owner spec
  owns each frame's semantics. The socket activates when warm-swap **or** receipt
  rotation is enabled (not warm-swap only), and the peer is authenticated by
  effective UID only (not app identity).
- **§6.15 (new) — additive coordinator-wire surface.** Enumerates the fields/frames
  that later specs own but that transit the binary: `auth_request` tier2
  (SPEC-008) / `credential_bootstrap` (SPEC-003 FR-C9) / catalog-admission
  (SPEC-010/022) fields; heartbeat `hardware_summary` (untrusted SPEC-017 display
  fallback, sub-schema carried here) / all six spec-decode fields (SPEC-028) /
  `last_autoupdate_event` on heartbeat **and** `state_update` (SPEC-020); inbound
  `se_liveness_challenge` (SPEC-008) and the `losslessness_probe_v1.*` family
  (SPEC-030); outbound `se_liveness_response` (SPEC-008) and the SPEC-001-owned
  `idle_prewarm_event`. (Numbered §6.15 to avoid the existing §6.12.)
- **FR-19.** Adds the six `idle_prewarm.*` config keys / `--idle-prewarm*` flags.

**Change log v1.6:**
- **v1.6 (2026-06-22, SPEC-015 v0.1.3 absorption):** Adds one
  parser-optional field to the v2 `auth_request` initial-stage frame:
  `provider_receipt_public_key`. The field carries the provider's
  standard padded base64-encoded 32-byte ed25519 receipt public key for
  SPEC-015 v0.1.3 non-streaming inference receipts. This is additive
  only: the field is NOT required by parsers, absent values preserve
  pre-v1.6 behavior, and the v2 proof-stage frame is unchanged.

**Change log v1.5:**
- **v1.5 (2026-06-21, pair_ot / claim_url wire additions):** Adds
  backwards-compatible coordinator-to-binary wire surfaces needed by the
  SPEC-014 v0.2 GitHub-account binding flow. First, `hello_ack` may carry
  optional `pair_ot` and `claim_url` fields alongside the
  `assigned_provider_token` placement established by SPEC-003 FR-C9.3.
  Second, a proof-stage-accepted v2 `auth_response` may carry the same two
  optional fields, while challenge and rejection-shaped auth frames remain
  ineligible for usable pairing material. Third, the server-push channel
  gains `ownership_event` and `ownership_status` server-push frames, with
  `needs_claim` carried by `ownership_status`. This amendment
  exists because the SPEC-014 v0.2 round-1 A.1 audit found that those
  WebSocket field shapes belong in SPEC-001, the protocol owner, rather
  than in the downstream GitHub-auth consumer spec. L-1 baseline preservation is explicit: a v1.4
  binary or coordinator that omits these fields is byte-identical to current
  behavior, and v1.5 readers MUST treat absent fields as "no pairing signal."
  SPEC-001 v1.5 defines wire shape only. The emission policy for when the
  coordinator chooses to include the new fields is owned by the separate
  SPEC-003 v0.10 FR-C10 amendment.

**Change log v1.4:**
- **v1.4 (2026-06-12, custom model selection):** Closes architect MAJOR-1 from the parallel codex audit on the installer-custom-model PR series (PRs #67/#70/#72): the previously implicit "user picks any MLX model that fits" surface is now normative.
  **(a) `--force` semantics on `models switch`** are extended beyond the v1.3 SPEC-011 cooldown-only contract: `--force` now ALSO bypasses the v1.4 RAM fit guard (`.wontFit` hard-block, `.tight` warning suppression, `.unknown`-on-HF-shape fail-closed override). It still does NOT bypass `SupportedModels.validate` (catalog membership) or the server-side concurrency rejection (an in-flight load still returns `loadingInProgress` per SPEC-011 v0.5 R-3.1.x). The v1.3 prose "suppresses ONLY the CLI-side cooldown soft guard" is superseded by the v1.4 §6.13 contract below.
  **(b) `models browse` subcommand** is added alongside `list / switch / status`. Browse queries the HuggingFace API at `https://huggingface.co/api/models?author=mlx-community&sort=downloads&direction=-1&limit=N[&search=Q]` and annotates each result with the local-Mac `ModelFit` verdict. Filters: `--family <substr>`, `--limit N` (1 <= N <= 200), `--fits-only`, `--max-gb N` (N > 0). Output is tab-separated to stdout; the count summary is to stderr. `HF_TOKEN` env var, if set, is sent as a Bearer header for gated content; the underlying URLSession refuses cross-origin redirects so the token cannot leak.
  **(c) Pre-flight fit guard on `models switch`** is added as a new normative requirement (§6.13). The guard runs after `SupportedModels.validate` succeeds and before any control-socket round-trip. Verdict tiers and headroom constants are shared between the installer (SPEC-003 v0.9 FR-D2.1) and the binary (`MacProviderCore/ModelFit`) so a model accepted at install time is judged the same way at switch time.
  **(d) Forward-looking note on `MacProviderModelCatalog`:** v1.4 places `ModelFit` and `HFClient` in the existing `MacProviderCore` library next to `SupportedModels`. A future revision SHOULD extract these into a `MacProviderModelCatalog` target once the next consumer (download-at-switch with byte-accurate sizing, multi-model `supported_models` mutation, gated-repo flow) lands. The catalog boundary is named here but not yet enforced; the v1.4 module placement remains acceptable for the current consumer set per codex architect MAJOR-2.
  No L-1 wire / on-disk impact: the fit guard is a local CLI policy that runs before the existing socket round-trip, and `browse` is read-only against HuggingFace's public API. No protocol, schema, or `supported_models` advertisement change.

**Change log v1.3.1:**
- **v1.3.1 (2026-06-11, M1-1 / XSEC-1):** Adds top-level
  `provider_token` config key, triple-exposed per house convention
  (yaml `provider_token`, env `MACPROVIDER_PROVIDER_TOKEN`, CLI
  `--provider-token`). Note: this is **flat**, not nested under
  `auth:`, matching the rest of the binary's flat
  `~/.config/macprovider/config.yaml` schema (the `auth.<flag>`
  spelling refers to the COORDINATOR-side `coordinator.yaml` and is
  not the binary's config layout). When set, the binary attaches
  `Authorization: Bearer <token>` to the coordinator WS connect
  (`CoordinatorClient.swift` `openWebSocket`). When unset, no
  Authorization header is sent. Token is redacted from logs (URL
  redaction already in place; headers were never logged; the default
  `webSocketFactory` now uses a dedicated `URLSession` with a
  `NoRedirectURLSessionDelegate` that refuses HTTP redirects so the
  Bearer header cannot leak to an attacker-controlled redirect
  target — M1-1 follow-up after the 2026-06-11 codex security audit).
  The operator is expected to chmod 0600 the config file containing
  this value. Pinned-tier migration uses `coordinator-cli issue-token`
  to mint per-provider tokens, write them into each provider's
  `macprovider.yaml` as `provider_token: <token>`, then flip
  `auth.require_provider_tokens=true` in the COORDINATOR config.
  v1.2.x and earlier binaries cannot send tokens; the flag flip
  is the compatibility cutoff. Stranger / curl|bash onboarding token
  flow is pending Open Question 2 (operator-issued vs self-serve
  provisional). SPEC-002's normative surface is unchanged — the
  validator already exists at `internal/ws/server.go:236-262`; the
  binary now sends Bearer (was: nothing).

**Change log v1.3:**
- **v1.3 (2026-06-06, SPEC-010 v1.5 + SPEC-011 v0.5 absorption):** Adds binary-side surface for two now-LOCKED companion specs. SPEC-010 v1.5 adds `--supported-models` / `--publish-supported-models` flags, gains the two optional v2 `auth_request` initial-stage fields, gains local pre-flight validation per R-3.6.3. SPEC-011 v0.5 adds `--enable-warm-swap` opt-in gate, `--swap-drain-timeout-seconds`, `--ctl-socket-path`, `--switch-state-path` flags on `serve`; adds the `models` subcommand with `list / switch / status` actions; mandates a `ModelRuntime` refactor from immutable `let container` to actor-isolated mutable `current_container` with an atomic-swap state machine; adds an opt-in heartbeat extension carrying `model_hash` (raw lowercase hex) and `loading: bool`; adds a newline-delimited JSON control socket protocol on a macOS-native `$TMPDIR`-based path. ALSO adds a new normative §6.7 v2 `auth_request` handshake section — the v2 contract has been in code since v1.2.x but was never normatively documented in SPEC-001; v1.3 closes that gap. L-1 baseline preserved: with neither flag set, a v1.3 binary introduces no NEW SPEC-010/SPEC-011 fields, sockets, or runtime state beyond the SPEC-010 R-3.6.2 single-entry `supported_models: [model_id]` default (which SPEC-010 v1.5 §4.1 establishes as observably indistinguishable from a pre-SPEC-010 binary on routing, `/v1/status`, and `/v1/models`).

**Change log v1.2.4:**
- **v1.2.4 (2026-05-29, audit response, concurrency reality alignment):** Aligns the RAM-tier max_concurrency documentation to the Swift runtime's enforced semaphore-of-1 reality (H-003 from the 2026-05-29 independent security audit). Spec previously documented per-tier defaults >1; runtime always overrode to 1. No code change required. Future parallel generation deferred to a SPEC-001 v1.3 candidate pending runtime validation.

**Change log v1.2.3:**
- § 6.1 `/v1/models`: producers MUST emit model `id` values with unescaped forward slashes (`/`) by suppressing the legal-but-cosmetic `\/` JSON escape. Consumers MUST continue to tolerate both encodings for backward compatibility.
- § 6.6 `inference_response_end`: when sent in response to `cancel_request`, providers MUST include actual token usage so downstream gateways, accounting systems, and billing infrastructure can settle cancellation usage exactly instead of estimating.

**Change log v1.2.2:**
- § 6.5 coordinator `drain` message: post-drain reconnect is now explicitly normative. After `drain_status: complete` and WS close, the provider MUST re-enter the startup reconnect loop; first reconnect attempt MUST occur within 15 seconds; three consecutive reconnect failures MUST log WARN with attempt count and last error; the process MUST NOT exit.
- § 6.2 `/v1/chat/completions`: model identifier comparison is ASCII case-insensitive. This matches legacy `mlx_lm.server` behavior and prevents buyer-visible 404 storms from harmless casing differences.
- § 6.1 `/v1/models`: the `id` field may contain `/` or the RFC 8259 `\/` escape; consumers MUST tolerate both. Producers SHOULD prefer unescaped `/` for readability.

**Change log v1.2:**
- § 6.5 hello message: added OPTIONAL `endpoint_url` field (string or null). Absence or null means "route inference through this WebSocket" (WS-tunneled mode). Non-empty string means "I am reachable at this HTTPS URL" (HTTP-forwarding mode). Existing v1.1.x binaries do not send this field; the coordinator falls back to its static `config.providers[]` map.
- § 6.5 hello_ack message: added OPTIONAL `tier` field ("pinned" or "provisional") and OPTIONAL `recommended_binary_version` field (string). Both informational.
- Added § 6.6 "Inference message types" — four new WS message types (`inference_request`, `inference_response_chunk`, `inference_response_end`, `cancel_request`) for WS-tunneled mode. These are NORMATIVELY SCOPED to providers operating in WS-tunneled mode only.
- Added FR-21 through FR-32 covering WS-tunneled inference handling.
- Added AC-11 through AC-15 covering WS-tunneled inference acceptance.
- Added OQ-4 (WS frame size limits) and OQ-5 (per-provider WS write buffer high-water mark).

**Change log v1.2.1:**
- § 6.6: restored request_id demux error handling from SPEC-003 v0.1 FR-A4 (C3 fix): unknown request_id → warn + discard; duplicate active request_id → nak `duplicate_request_id`; completed request_id cleanup rules.
- OQ-3: closed as resolved by SPEC-003 v0.3 FR-C1/FR-C2 (M7 fix).
- OQ-4, OQ-5: restored full rationale paragraphs from SPEC-003 v0.1 (M6 fix).
- § 6.5: clarified endpoint_url absence text to reference SPEC-002 v1.1.1 § 3 for final mode resolution (m2 fix).

> **Backward compatibility.** Phase 3 binaries implementing SPEC-001
> v1.1.4 (or earlier v1.1.x patches v1.1.2, v1.1.3) remain FULLY
> COMPLIANT with the MANDATORY portion of SPEC-001 v1.2 without any
> code change, recompile, or reinstall. The new § 6.6 (Inference
> message types) is NORMATIVELY SCOPED to providers operating in
> WS-tunneled mode, signalled by the absence of `endpoint_url` in
> their `hello` message AND the absence of a corresponding
> `endpoint_url` in the coordinator's `config.providers[]` entry for
> their `provider_id`. Operator-configured pinned providers (e.g.,
> M4 and M1 as of 2026-05-28, both running v1.1.x binaries with
> coordinator-side static endpoint_url entries) operate in HTTP-
> forwarding mode and MUST NEVER receive § 6.6 messages from the
> coordinator. Coordinators (SPEC-002 v1.1) MUST verify routing mode
> via § 3 mode resolution before dispatching any § 6.6 message.
> v1.1.x binaries that receive an unexpected § 6.6 message SHOULD
> respond with `nak code=unknown_message_type` per § 6.5 nak
> semantics; coordinators that observe such a nak MUST mark the
> routing-mode resolution buggy and not retry, treating the provider
> as HTTP-forwarding-only for that session.

**Change log since v1.1.3:**
- § 6.5 coordinator `drain` message: after `drain_status: complete` and WS close, the provider's internal state machine MUST reset to `ready` (assuming the local HTTP server is healthy, which is the only path that reaches `drainFromCoordinator`). The coordinator has no implicit `draining → ready` transition; if the provider's status field carries over from the previous session into the first heartbeat of the next session, the provider stays excluded from routing indefinitely.
- Implementation fix in phase3-binary v1.1.4: `drainFromCoordinator()` calls `providerStatus.setState(.ready)` after the WS close. Bug surfaced same day as v1.1.3 ship when the first FORCE_RESTART of the coordinator left M4 stuck at `state=draining` post-reconnect.

**Change log v1.1.3:**
- § 6.5 coordinator `drain` message: now explicitly normative — drain stops coordinator registration only and MUST NOT terminate the provider's local buyer HTTP server. The provider continues serving direct-to-tunnel buyer traffic across coordinator restarts.
- Implementation fix in phase3-binary v1.1.3: `drainAndExit()` (full process shutdown, used by local SIGTERM) is split from `drainFromCoordinator()` (drop WS, keep HTTP server, reconnect after grace).

**Change log v1.1.2:**
- § 6.5 hello message: `provider_id` field now explicitly normative — it is the operator-issued stable identifier from SPEC-002's static `config.providers[]` map. Example value updated; misleading "uuid-of-this-instance" placeholder removed.
- § 6.5 added normative paragraph immediately after the hello example explaining the relationship to SPEC-002 Finding F-2 and what happens on mismatch (WS close 4002 `unknown_provider_id`).

---

## 0. Operator-paste invocation block

```
Implement SPEC-001. As you work, maintain a running
phase3-binary/implementation-notes.html that captures anything I should
know about how the implementation diverges from or interprets the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise
```

---

## 1. Mission

The Phase 3 binary (`macprovider-cli`) is a Swift command-line tool that
runs on Apple Silicon Macs and replaces `mlx_lm.server` as the inference
layer for Mac Provider contributors. It wraps `mlx-swift-lm` to serve
OpenAI-compatible HTTP inference, strips the SSE quirks and stop-token
leakage observed in Phase 1 and Phase 2, enforces per-hardware context
limits to prevent Metal OOM crashes, and speaks a coordinator WebSocket
protocol so a future Phase 4 VPS coordinator can route buyer requests to
a pool of contributor Macs. The binary ships as a signed macOS CLI that
a contributor runs in a single terminal alongside a Cloudflare tunnel or
behind the Phase 4 coordinator.

---

## 2. Scope

### In Tier 1 launch scope (build now)

- Swift CLI binary targeting macOS 14+ on Apple Silicon (M1 through M4)
- Config loader: YAML config file, CLI flag overrides, env var fallbacks
- Model loading via `mlx-swift-lm` (single model per process)
- HTTP server on configurable local port (default 8080)
- `/v1/models` endpoint (OpenAI-compatible)
- `/v1/chat/completions` endpoint (streaming and non-streaming, OpenAI-compatible)
- `/v1/health` local diagnostics endpoint
- SSE streaming with clean OpenAI format (no keepalive comments)
- Stop-token defensive stripping derived from model's `tokenizer_config.json`
- Streaming usage chunk synthesis (mlx_lm.server omits this)
- Two-stage context length pre-flight (envelope size + token count)
- Per-RAM-tier capacity computation at startup (8 GB, 16 GB, 32 GB+ tiers)
- Concurrent-request serialization via a blocking semaphore with configurable max concurrency (FR-11; the ≤ v1.6 "bounded reject-queue + 429" was never shipped)
- Mid-stream client disconnect detection and slot release within 5 seconds (FR-10 — aspirational; not fully wired in the shipped binary, see FR-10)
- Graceful SIGTERM handling: drain in-flight requests before exit
- Outbound coordinator WebSocket client (connects to configurable URL)
- Coordinator handshake with tier, model, capacity, and throughput metadata
- Capacity heartbeat at configurable interval
- Health state reporting over WebSocket (ready, busy, degraded, draining, unavailable)
- Idle-triggered prewarm inference to mitigate the post-idle throughput dip (FR-16; the ≤ v1.6 "post-wake warm-up" / wake detection was never shipped — `warm_up` is a no-op)
- Startup self-test: load model, run one inference, verify output
- Structured logging to stdout (JSON lines format)
- macOS code signing (Developer ID, not notarized for v1)
- `THIRD_PARTY_NOTICES.md` shipping with the binary
- Operator-opt-in capability advertisement per SPEC-010 v1.5 §3.6
  (`--supported-models`, `--publish-supported-models`). Default
  OFF; when on, the v2 `auth_request` initial-stage frame carries
  `supported_models[]` and `publishes_supported_models: true`.
- Operator-opt-in warm model swap per SPEC-011 v0.5 §3.1-§3.9
  (`--enable-warm-swap`). Default OFF; when on, enables the
  `models switch <id>` operator workflow, the in-process runtime
  state machine, the control socket, and the extended heartbeat
  fields. Closes arm64golf canary operator pains #1 (multi-minute
  restart loop to change served model) and #2 (red-dashboard / WS
  reconnect on swap).

### In Tier 2 roadmap scope (original Phase-3 design intent)

- `TrustGate` middleware: request-level trust evaluation (attestation-based auth)
- `InputDecryptor` middleware: buyer-side encrypted prompt decryption
- `ResponseSeal` middleware: output signing or encryption for buyer verification
- `AttestationProvider` coordinator component: attestation token on handshake
- Coordinator tier capability upgrade (`tier: 1` to `tier: 2`)

Each of these was originally a named Swift protocol with a Tier 1 no-op
(passthrough) implementation and explicit insertion points in the request handler
chain (see Section 3 for the hook-point diagram).

> **Reconciled v1.7 — no longer "not implemented".** The shipped binary
> (`binary_version` 1.8.31) has since implemented substantial Tier-2 machinery
> owned by **SPEC-008**: the fresh-connect `auth_request` advertises
> `tier2_capabilities` (encrypted-leg / attestation / AEAD suites), the
> proof-stage handshake generates an **attestation token**, and the binary
> answers `se_liveness_challenge` (§6.15). This is **not** hardware-identity
> proof — SPEC-008's default `self_signed` tier does **not** prove
> Secure-Enclave residence or hardware identity; the earlier "hardware
> attestation proof" wording overstated it. Legacy `hello.tier = 1` remains
> accurate for the v1 path; the modern v2 trust pipeline is SPEC-008's and is
> live, not roadmap. SPEC-001 carries only the transport (§6.15); SPEC-008 owns
> the trust semantics.

### Out of scope

- Multi-model rotation within a single process (operator restarts with different model)
- Billing, payment, or reward distribution logic
- Coordinator implementation (Phase 4 separate SPEC)
- Smart router logic (Phase 4/5)
- Buyer authentication or authorization (Tier 2)
- Web UI, dashboard, or contributor portal
- Contributor onboarding flow beyond "run this binary"
- Antseed seller plugin integration (coordinator's responsibility)
- Automatic model downloading (contributor pre-downloads via `huggingface-cli`)
- **Coordinator-side** validation/policy of provider authentication and
  attestation (owned by SPEC-002 / SPEC-008 / SPEC-026). **Reconciled v1.7:** the
  binary-side of these — bearer-token transport, the v2 challenge/proof
  handshake (in WS-tunneled / credential-bootstrap mode; R-6.7.8), and SE/MDA
  **attestation-token generation** — *is* in scope and
  shipped (`CoordinatorClient.swift`, FR-13/FR-14/§6.7/§6.15); only the
  coordinator's acceptance decision is out of scope here.

---

## 3. Architecture overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                          macprovider-cli                            │
│                                                                     │
│  ┌───────────┐    ┌───────────┐    ┌──────────────────────────┐    │
│  │ CLI Entry  │──→│ Config    │──→│ Model Loader              │    │
│  │ (ArgumentP │    │ Loader    │    │ (mlx-swift-lm wrapper)    │    │
│  │  arser)    │    │ (YAML +   │    │                          │    │
│  │            │    │  CLI +env)│    │ Reads tokenizer_config   │    │
│  └───────────┘    └───────────┘    │ for stop-token list      │    │
│                                     └────────────┬─────────────┘    │
│                                                   │                  │
│  ┌────────────────────────────────────────────────┼────────────┐    │
│  │                 HTTP Server (Swift NIO)         │            │    │
│  │                 Bound to 127.0.0.1:{port}       │            │    │
│  │                                                 │            │    │
│  │  Incoming request                               │            │    │
│  │       │                                         │            │    │
│  │       ▼                                         │            │    │
│  │  ┌─────────────────┐                            │            │    │
│  │  │ Request Router   │   /v1/models → static JSON│            │    │
│  │  │                  │   /v1/health → health JSON │            │    │
│  │  │   404 for unknown paths                      │            │    │
│  │  │   405 for wrong methods                      │            │    │
│  │  └────────┬────────┘                            │            │    │
│  │           │ /v1/chat/completions                  │            │    │
│  │           ▼                                      │            │    │
│  │  ┌─────────────────┐                            │            │    │
│  │  │ Request          │  JSON parse, schema check,  │            │    │
│  │  │ Validator        │  tool validation, model     │            │    │
│  │  │                  │  match. Reject → 400/404    │            │    │
│  │  └────────┬────────┘                            │            │    │
│  │           ▼                                      │            │    │
│  │  ┌─────────────────┐                            │            │    │
│  │  │ Pre-flight       │  Stage 1: envelope size     │            │    │
│  │  │ Stage 1          │  check (raw bytes).         │            │    │
│  │  │                  │  Reject → HTTP 413          │            │    │
│  │  └────────┬────────┘                            │            │    │
│  │           ▼                                      │            │    │
│  │  ┌─────────────────┐  ← TIER 2 HOOK POINT      │            │    │
│  │  │ [TrustGate]      │  Tier 1: passthrough       │            │    │
│  │  │                  │  Tier 2: attestation check  │            │    │
│  │  └────────┬────────┘                            │            │    │
│  │           ▼                                      │            │    │
│  │  ┌─────────────────┐  ← TIER 2 HOOK POINT      │            │    │
│  │  │ [InputDecryptor] │  Tier 1: SKIP (no-op)      │            │    │
│  │  │                  │  Tier 2: decrypt prompt     │            │    │
│  │  └────────┬────────┘                            │            │    │
│  │           ▼                                      │            │    │
│  │  ┌─────────────────┐                            │            │    │
│  │  │ Pre-flight       │  Stage 2: tokenize prompt,  │            │    │
│  │  │ Stage 2          │  check token count against  │            │    │
│  │  │                  │  RAM cap. Reject → 413     │            │    │
│  │  └────────┬────────┘                            │            │    │
│  │           ▼                                      │            │    │
│  │  ┌─────────────────┐                            │            │    │
│  │  │ Semaphore Gate   │  Blocking semaphore, no    │            │    │
│  │  │                  │  queue; beyond limit → wait │            │    │
│  │  └────────┬────────┘                            │            │    │
│  │           ▼                                      ▼            │    │
│  │  ┌────────────────────────────────────────────────┐          │    │
│  │  │ Inference Engine                                │          │    │
│  │  │ (mlx-swift-lm generate / stream)               │          │    │
│  │  │ Tracks prompt_tokens + completion_tokens        │          │    │
│  │  └────────────────────────────┬───────────────────┘          │    │
│  │                                │                              │    │
│  │                                ▼                              │    │
│  │  ┌─────────────────┐  ← TIER 2 HOOK POINT                   │    │
│  │  │ [ResponseSeal]   │  Tier 1: passthrough                    │    │
│  │  │                  │  Tier 2: sign/encrypt output            │    │
│  │  └────────┬────────┘                                         │    │
│  │           ▼                                                   │    │
│  │  ┌──────────────────────────────────────────────────┐        │    │
│  │  │ Response Formatter                                │        │    │
│  │  │  Stop-token stripping, SSE framing,               │        │    │
│  │  │  usage chunk synthesis, JSON envelope              │        │    │
│  │  └──────────────────────────────────────────────────┘        │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │ Coordinator Client (outbound WebSocket)                      │    │
│  │                                                              │    │
│  │  ┌───────────────┐  ┌──────────────┐  ┌─────────────────┐  │    │
│  │  │ Handshake +    │  │ Capacity     │  │ Health State    │  │    │
│  │  │ Tier Announce  │  │ Heartbeat    │  │ Reporter        │  │    │
│  │  └───────────────┘  └──────────────┘  └─────────────────┘  │    │
│  │                                                              │    │
│  │  ┌─────────────────────────┐  ← TIER 2 HOOK POINT          │    │
│  │  │ [AttestationProvider]    │  Tier 1: omitted from handshake│    │
│  │  │                         │  Tier 2: sends attestation blob │    │
│  │  └─────────────────────────┘                                │    │
│  │                                                              │    │
│  │  ┌──────────────────────────────────────────────────┐       │    │
│  │  │ Inbound: preflight, drain, warm_up               │       │    │
│  │  │ Outbound: hello, heartbeat, state_update,         │       │    │
│  │  │           drain_status, preflight_ack, nak        │       │    │
│  │  └──────────────────────────────────────────────────┘       │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  ┌──────────────┐    ┌──────────────────┐                          │
│  │ Logger        │    │ Metrics Counters  │                          │
│  │ (SwiftLog,    │    │ (in-process,      │                          │
│  │  JSON lines)  │    │  exposed on       │                          │
│  │               │    │  /v1/health)      │                          │
│  └──────────────┘    └──────────────────┘                          │
└─────────────────────────────────────────────────────────────────────┘
```

### Tier 2 request chain ordering (hard architecture constraint)

The request chain is Tier-aware. The critical ordering difference:

**Tier 1 path:** Validate → Stage 1 pre-flight → [TrustGate: pass] →
Stage 2 pre-flight (tokenize) → Semaphore gate (FR-11, blocking; no queue) →
Inference → [ResponseSeal: pass] → Format

**Tier 2 path:** Validate → Stage 1 pre-flight (envelope bytes) →
[TrustGate: attest] → [InputDecryptor: decrypt] →
Stage 2 pre-flight (tokenize plaintext) → Semaphore gate (FR-11, blocking) →
Inference → [ResponseSeal: sign/encrypt] → Format

(The "Queue" stage of the ≤ v1.6 chain is the FR-11 blocking semaphore, not a
depth-bounded reject-queue; reconciled v1.7. The `[TrustGate]` /
`[InputDecryptor]` / `[ResponseSeal]` middleware brackets are the *original
Phase-3 Tier-2 design* — Tier-1 passthrough no-ops that never shipped as the
tier-2 mechanism; see the Tier-2 reconciliation note in the scope section.)

`InputDecryptor` MUST run before Stage 2 pre-flight in Tier 2, because
encrypted prompts cannot be tokenized. Stage 1 (envelope byte-size
check) runs before decryption in both tiers as a fast-reject for
obviously oversized payloads.

### Tier 2 hook points summary

> **Reconciled v1.7 — original design, not the shipped Tier-2 mechanism.** This
> hook-point table describes the *original Phase-3 design* for how Tier-2 would
> be added: request-chain middleware protocols with Tier-1 passthrough no-ops.
> That middleware design **never shipped** — none of these four Swift protocols
> exist in the binary. The Tier-2 that actually shipped (`binary_version`
> 1.8.31) is a **coordinator-wire pipeline owned by SPEC-008** (v2 `auth_request`
> `tier2_capabilities`, proof-stage `attestation_token`, `se_liveness`, encrypted
> leg; §6.15), which is orthogonal to the request-chain middleware below. The
> "hardware attestation blob" phrasing also overstates assurance: SPEC-008's
> default `self_signed` tier proves key custody and session binding, **not**
> hardware provenance. The table is retained as design context only.

| Hook point (original design) | Location | Tier 1 behavior | Envisioned Tier 2 behavior |
|---|---|---|---|
| `TrustGate` | After Stage 1 pre-flight | Passthrough (all requests accepted) | Validate buyer attestation token |
| `InputDecryptor` | Before Stage 2 pre-flight | Skip entirely | Decrypt buyer-encrypted prompt |
| `ResponseSeal` | After inference, before formatter | Passthrough (plaintext output) | Sign or encrypt output |
| `AttestationProvider` | Coordinator handshake | Omitted from handshake payload | (envisioned) attestation token on handshake |

Each hook point *was* to be a Swift protocol with a Tier-1 passthrough conformance
(e.g. `PassthroughTrustGate`). In the shipped binary these protocols were never
created; SPEC-008's wire pipeline supersedes them.

---

## 4. Functional requirements

### Core HTTP endpoints

**FR-1. Model listing endpoint.**
`GET /v1/models` returns a JSON response containing the currently-loaded
model identifier. Response shape matches the OpenAI models endpoint
(see Section 6). The model list always contains exactly one entry — the
model loaded at startup. If no model is loaded (startup failure), the
endpoint returns HTTP 503.

**FR-2. Chat completions — non-streaming.**
`POST /v1/chat/completions` with `stream: false` (or `stream` omitted)
accepts an OpenAI-format chat completion request and returns a single
JSON response with the full completion. The response includes
`usage.prompt_tokens` and `usage.completion_tokens` with accurate counts.
Full request schema and validation rules are in Section 6.2.

**FR-3. Chat completions — streaming.**
`POST /v1/chat/completions` with `stream: true` returns an SSE stream
of chat completion chunks. Each chunk is a valid OpenAI-format delta.
The stream terminates with `data: [DONE]`.

**FR-4. SSE stream format compliance.**
Every SSE line in a streaming response uses the `data: ` prefix (with
exactly one space). No blank `data:` lines between chunks. Each
`data: {...}` payload is valid JSON. The final line is `data: [DONE]`.
Content-Type header is `text/event-stream; charset=utf-8`. The response
uses HTTP/1.1 chunked transfer encoding (which is the normal transport
for SSE when Content-Length is unknown). The binary produces valid SSE
event framing; transport encoding is handled by Swift NIO.

**FR-5. No SSE keepalive comments.**
The binary never emits SSE comment lines (lines starting with `:`).
Phase 1 found `mlx_lm.server` emits `: keepalive N/M` lines that break
strict SSE parsers. The binary controls SSE output directly and does
not proxy `mlx_lm.server` — it generates SSE from its own inference.

### Response quality

**FR-6. Stop-token defensive stripping.**
At model load time, the binary reads the model's `tokenizer_config.json`
and extracts all special tokens (`eos_token`, `bos_token`, entries in
`added_tokens_decoder` where `special: true`). These tokens are compiled
into a stripping filter applied to every generated token before it is
sent to the client. Phase 1 observed `<|eot_id|>` leaking on Llama and
`<|end|>` on Phi. Phase 2 day-0 data showed 0% leakage — likely
upstream `mlx-lm` fixed it — but the binary implements defensive
stripping regardless because:
- Upstream fixes can regress.
- The binary may run older `mlx-lm` model checkpoints.
- The cost of stripping is negligible; the cost of leaking is visible to buyers.

**FR-7. Streaming usage chunk synthesis.**
When streaming, the binary emits a final chunk before `[DONE]` that
contains a `usage` field with `prompt_tokens` and `completion_tokens`.
The binary counts tokens during generation — it does not rely on the
upstream model server to report usage. Phase 2 confirmed that
`mlx_lm.server` omits usage from SSE streams entirely; the Phase 3
binary fixes this.

Format of the usage chunk:
```json
{"id":"chatcmpl-...","object":"chat.completion.chunk","created":1234567890,
 "model":"...","choices":[],"usage":{"prompt_tokens":150,"completion_tokens":42,"total_tokens":192}}
```
Note: `choices` is an empty array in the usage-only chunk. This matches
the OpenAI convention adopted by most proxy-compatible clients.

### Safety and capacity

**FR-8. Two-stage context length pre-flight.**
Pre-flight is split into two stages to support Tier 2 encrypted prompts
without rewriting the chain:

**Stage 1 — Envelope size check (both Tier 1 and Tier 2).**
Before any decryption, check the raw HTTP request body size in bytes.
If the body exceeds a configurable maximum (default: 10 MB), reject
with HTTP 413 immediately. This is a fast-reject for obviously oversized
payloads and does not require tokenization.

**Stage 2 — Token-count pre-flight (after decrypt in Tier 2; immediately in Tier 1).**
Tokenize the full plaintext prompt (system + messages) using the loaded
model's tokenizer and compute the expected token count. If the count
exceeds the safe context capacity for the current hardware tier (FR-9),
reject with HTTP 413 and a JSON error body:
```json
{"error":{"message":"Prompt length (28400 tokens) exceeds this provider's safe capacity (20000 tokens).","type":"context_length_exceeded","param":"messages","code":"context_length_exceeded"}}
```

This prevents the Metal GPU OOM crash observed in Phase 1 at ~26K tokens
on M1 8GB. The binary never forwards a prompt to the inference engine
if it might exceed capacity.

**FR-9. Per-RAM-tier capacity advertisement.**
At startup, the binary reads `hw.memsize` (via `sysctl`), determines the
hardware tier, and computes a safe maximum context length and advertised
concurrency limit. Starting context estimates are refined by runtime
measurement; default concurrency is locked to the runtime-safe value:

| RAM tier | Max context (tokens) | Max concurrency | Rationale |
|---|---|---|---|
| 8 GB | 20,000 | 1 | Phase 1: OOM at ~26K on M1 8GB; 20K with headroom |
| 16 GB | 50,000 | 1 | Context capacity scales with RAM; generation remains serialized |
| 32 GB | 120,000 | 1 | Conservative context capacity for large models; generation remains serialized |
| 64 GB+ | 200,000 | 1 | Upper context bound; generation remains serialized |

Until provider runtime parallel generation is proven safe under MLX
(catalog reasoning, memory pressure analysis, stability validation),
advertised `max_concurrency` MUST be 1 for all RAM tiers. The provider
runtime enforces the advertised concurrency via a process-local semaphore
sized to `max(1, max_concurrency)` around MLX generation calls (FR-11) — 1 at
the normative default; an operator override sizes it higher. Operators MAY set `max_concurrency_override` in
`~/.config/macprovider/config.yaml` (or via
`MACPROVIDER_MAX_CONCURRENCY_OVERRIDE` env) for experimental use, but
the default and recommended value is 1.

This is a deliberate safety floor, not an architectural ceiling. A
future SPEC-001 revision MAY raise the default when parallel generation
has been validated under concurrent buyer load without quality, latency,
or memory regressions. Until then, consumers (coordinator routing,
buyer-API gateways, capacity reporting) MUST treat advertised values >1
as opt-in operator overrides, not normative defaults.

The context values are defaults. `max_context_override` can override the
context limit. If the binary detects available memory at startup is
significantly less than expected for the tier (e.g., heavy background
apps), it logs a warning and reduces the advertised context capacity
proportionally.

**FR-10. Mid-stream disconnect cleanup (reconciled v1.7 — aspirational, not
shipped).** The intended behavior is: when a client disconnects during a
streaming response, the binary detects the broken connection (via NIO channel
close event), cancels the in-flight inference task, and releases the request
slot within 5 seconds. **Shipped reality diverges:** streaming inference runs in
a **detached** task (`HTTPServer.swift`) and calls the runtime `stream` with no
channel-derived cancellation predicate (`ModelRuntime` `shouldCancel` defaults to
`false`); a failed response write is not propagated back into generation. So a
mid-stream client disconnect does **not** cancel the in-flight generation or
guarantee the 5-second slot release. Phase 2 testing found `mlx_lm.server`
handles this via `BrokenPipeError`; the binary does **not** yet match that.
Wiring channel-close → `Task.cancel` (shared with the FR-11 waiter-cancellation
gap) is a carried follow-up, not a shipped v1.7 guarantee.

**FR-11. Concurrent request handling — semaphore serialization (reconciled v1.7).**
The binary bounds concurrent inference to advertised `max_concurrency`
(FR-9). The normative default is 1; values >1 are operator overrides for
experimental use.

**Shipped behavior (v1.7 reconciliation — code is source of truth).** The
mechanism is a **blocking semaphore**, not a bounded reject-queue. The HTTP
inference path serializes through `inferenceGate = AsyncSemaphore(value:
max(1, max_concurrency))` (`ModelRuntime.swift`), acquired via
`inferenceGate.withPermit { … }` around the generation call. A request that
arrives while all permits are held **awaits** a free permit (it blocks in the
async runtime); it is **not** placed in a depth-bounded FIFO and is **not**
rejected. There is therefore **no HTTP `429`, no `Retry-After` header, and no
`rate_limit_exceeded` response on the HTTP inference path** — the earlier
"bounded FIFO queue, depth = 2× concurrency, 429 + Retry-After, silent removal
of pre-engine-cancelled queued requests" contract (SPEC-001 ≤ v1.6) was **never
implemented** and is retired.

The semaphore's waiter list is **unbounded** (`AsyncSemaphore.swift` appends
every excess acquirer); admission is not depth-capped. Waiters are drained
**FIFO** — a normal permit release resumes the first waiter (`removeFirst()`) —
and a waiter is *also* removed if its own Swift task is cancelled. On the HTTP
inference path this cancellation is **not** wired to client disconnect: requests
run in detached tasks (`HTTPServer.swift`) and the non-streaming path passes
`shouldCancel: { false }`, so a client that disconnects while awaiting a permit
does **not** release its waiter or its later compute. FR-11's earlier assurance
that awaiting clients are freed by structured-concurrency cancellation on
disconnect is therefore **not** shipped; a flood of (including disconnected)
requests can retain parsed request state and later consume compute. Hardening
this (channel-close → `Task.cancel`, waiter cap) is a carried follow-up, not a
v1.7 spec claim.

**WS-tunneled path (FR-21–FR-32) capacity handling.** The coordinator-tunneled
relay bounds in-flight requests differently: `InferenceRelay` hard-**rejects**
at capacity — `guard active.count < maxActiveRequests` else it emits
`status: "error_queue_full"` (FR-27), with **no** queue and **no** `Retry-After`.
`maxActiveRequests` is fixed to **1** (`InferenceRelay.swift`,
`CoordinatorClient.swift`). So the tunneled path admits one request and
immediately rejects a concurrent second with `error_queue_full`, whereas the
local HTTP path blocks on the semaphore.

**FR-12. Graceful SIGTERM drain.**
On receiving SIGTERM, the binary:
1. Stops accepting new HTTP connections.
2. Sends a `drain_status` message to the coordinator (if connected).
3. Waits for all in-flight requests to complete, up to a configurable
   timeout (default: 30 seconds).
4. Force-cancels any remaining requests after the timeout.
5. Closes the coordinator WebSocket.
6. Exits with code 0.

On SIGINT (Ctrl-C), same behavior with a shorter default timeout
(5 seconds). Double SIGINT forces immediate exit.

### Coordinator protocol

**FR-13. Outbound coordinator WebSocket.**
The binary maintains a persistent outbound WebSocket connection to a
coordinator URL. The URL is configurable via CLI flag (`--coordinator`),
env var (`MACPROVIDER_COORDINATOR_URL`), or config file. If no
coordinator URL is configured, the binary runs in standalone mode
(local HTTP server only, no WebSocket). If the WebSocket connection
drops, the binary reconnects with exponential backoff (1s, 2s, 4s, ...
capped at 60s). The coordinator is a Phase 4 dependency; the binary
ships with the client protocol fully implemented, tested against a mock.
**Reconciled v1.7:** provider authentication is **not** wholly out of scope. The
binary-side credential transport and proof generation are shipped and in scope —
it attaches `Authorization: Bearer <provider_token>` on the coordinator WS
connect (when the token is non-empty; see the header §, and
`CoordinatorClient.swift`). The handshake it then runs is **mode-selected**
(R-6.7.8): a **WS-tunneled or credential-bootstrap** connection runs the v2
`auth_request` challenge/proof with attestation/identity proof (§6.7, §6.15),
while a **legacy HTTP-forwarding** connection uses the §6.5 `hello`. Only the
**coordinator-side** validation and issuance *policy* is deferred to SPEC-002
(and SPEC-008 / SPEC-026 for attestation/identity).

**FR-14. Tier capability announcement (reconciled v1.7).**
On the legacy `hello` message the shipped binary sends `tier: 1` with
`attestation: null` (`CoordinatorClient.swift`) — that frame never advanced to
`tier: 2`. The Tier-2 upgrade did **not** happen via the originally-envisioned
`AttestationProvider` hook / `hello.tier = 2` "attestation blob" path (that
middleware design never shipped). Instead, the shipped Tier-2 rides the **v2
`auth_request` handshake** owned by **SPEC-008**: `tier2_capabilities`
advertisement in the initial stage, a proof-stage `attestation_token`, and
`se_liveness` challenge/response (§6.15). The legacy `hello.tier`/`attestation`
fields are inert with respect to that pipeline.

**FR-15. Health state reporting.**
The binary reports its health state to the coordinator via the WebSocket.
States, informed by Phase 2 decision log entry D1 (502 vs 530 routing):

| State | Meaning |
|---|---|
| `ready` | Accepting requests, model loaded |
| `busy` | All request slots occupied |
| `degraded` | Transient `warm_up`-command acknowledgement only — emitted immediately before `ready` (see FR-16); **not** a post-wake warm-up state (no wake detection ships) and **not** entered by the idle prewarmer |
| `draining` | SIGTERM received, finishing in-flight |
| `unavailable` | Model load failed or fatal error |

State transitions are sent as `state_update` WebSocket messages
whenever the state changes (see Section 6.5). A WebSocket close
without a prior `draining` message indicates an unclean disconnect
(the 530-equivalent from D1).

**FR-16. Warm-up — idle prewarmer (reconciled v1.7).**
Phase 2 decision log entry D2 found a -12% throughput dip on the first
request after a period of inactivity. The **shipped** mitigation differs
from the ≤ v1.6 spec text in two ways; code is source of truth.

**No wake-event detection (v1.7).** The binary does **not** detect wake
events. There is no IOKit power-notification / `didWake` handler and no
wall-clock-jump detector anywhere in the CLI; the earlier "detects wake
events … before transitioning from `degraded` to `ready`" contract was
never implemented and is retired.

**The `warm_up` coordinator command is a no-op (v1.7).** On receiving a
`warm_up` WebSocket command the binary emits `state_update: degraded`
("coordinator warm_up requested") immediately followed by
`state_update: ready` ("warm_up complete") and runs **no** synthetic
inference between them (`CoordinatorClient.swift`). It is a stateless
two-message acknowledgement, not a warm-up trigger.

**Shipped warm-up is idle-triggered (`IdlePrewarmer`).** The real warm-up
is an idle prewarmer (`IdlePrewarmer.swift`), enabled by default. On a tick
loop (`idle_prewarm.tick_seconds`, default 5s, range 1…60) it measures elapsed
time since the last inference. The idle threshold
(`idle_prewarm.idle_threshold_seconds`, default 30s, range 5…3600) is a
**necessary but not sufficient** trigger: a run fires only when *all* of the
following also hold (`IdlePrewarmer.swift`) — prewarm is enabled, there are
zero in-flight requests, thermal state is acceptable (thermal-gated), the power
source is permitted, and a model with a known hash is loaded; a second
busy/idle re-check immediately before the run guards against a request arriving
during setup. When they hold it runs a synthetic `ModelRuntime`
`runInternalWarmup` — a short fixed prompt (`idle_prewarm.prompt`, default
`"warm"`, 1…64 bytes) generating up to `idle_prewarm.max_tokens` tokens
(default 1, range 1…8), result discarded. It is **battery-gated off by
default** (`idle_prewarm.run_on_battery`, default false; power source read via
`IOKit.ps`) — on explicit `.battery` it skips unless enabled. Note the gate
**fails open** when IOKit cannot classify the source: an `.unknown` reading is
*not* `.battery`, so a synthetic run can proceed under power-detection failure
(carried LOW residual).

Lifecycle is reported on the coordinator wire as a **single frame type**,
`type: "idle_prewarm_event"`, whose `event` field carries the transition —
`idle_prewarm_fired`, `idle_prewarm_completed`, `idle_prewarm_failed`,
`idle_prewarm_cancelled_by_real_request` (pre-empted by a real request), or
`idle_prewarm_skipped` (the raw `IdlePrewarmer` strings, forwarded unchanged); a
`reason` is attached only on the skipped event. There
is **no** distinct `idle_prewarm_skipped` frame type, and a single run emits
*multiple* lifecycle events (e.g. `idle_prewarm_fired` then
`idle_prewarm_completed`), not one frame per run (§6.15.4). The prewarmer does **not** change the provider health state
(`ready`/`degraded`); it warms the model cache in place. See FR-19 for the six
`idle_prewarm.*` config keys / `--idle-prewarm*` flags.

**FR-17. Capacity advertisement includes model and throughput.**
Phase 2 decision log entry D4 found that smaller-model-on-slower-hardware
(Llama 3B on M1 8GB: 22-25 tok/s) outperformed bigger-model-on-faster-hardware
(Qwen 7B on M4 16GB: 17-20 tok/s). The capacity heartbeat message
must include:

- `model_id`: the loaded model's HuggingFace identifier
- `model_params_b`: approximate parameter count in billions
- `max_context_tokens`: computed from FR-9
- `max_concurrency`: computed from FR-9 (1 by default; higher only by operator override)
- `slots_free`: real-time availability (matches heartbeat schema in § 6.5)
- `slots_total`: total inference slots configured for this provider
- `throughput_tps_estimate`: measured tok/s from the startup self-test
- `ram_gb`: total system RAM

The coordinator MAY use these fields to route by actual measured
performance rather than assumed hardware capability. The binary's
responsibility ends at sending accurate values.

### WS-tunneled inference (v1.2)

**Normative scope.** FR-21 through FR-32 apply ONLY to providers
operating in WS-tunneled mode. Providers in HTTP-forwarding mode
are not affected by these requirements.

**FR-21. Inference request handling.**
On receiving `inference_request` (§ 6.6), the provider:
1. Parses the embedded `body` field through the existing request
   validation pipeline (§ 6.2).
2. Runs inference through the existing pipeline (validation,
   pre-flight, FR-11 semaphore gate, inference engine, response formatter) but
   captures output internally instead of writing to an HTTP response.
3. For streaming requests: emits each SSE chunk as an
   `inference_response_chunk` WS message.
4. For non-streaming requests: emits the complete response as a single
   `inference_response_chunk` followed by `inference_response_end`.
5. On completion or error, sends `inference_response_end` with the
   appropriate status.

**FR-22. Streaming response emission.**
For `stream: true` inference requests, the provider emits one
`inference_response_chunk` per SSE event. Each chunk's `data` field
contains the SSE event line (including `data: ` prefix and `\n\n`
terminator). The `seq` field increments from 0. The final chunk
contains `data: [DONE]\n\n`, followed by `inference_response_end`.

**FR-23. Non-streaming response emission.**
For `stream: false` inference requests, the provider emits a single
`inference_response_chunk` with `seq: 0` containing the complete JSON
response body, followed by `inference_response_end`.

**FR-24. Request ID correlation.**
Every `inference_response_chunk` and `inference_response_end` MUST
carry the `request_id` from the originating `inference_request`. The
provider MUST NOT reuse or reassign `request_id` values.

**FR-25. Multiplexing — fixed WS capacity 1 (reconciled v1.7).**
On the WS-tunneled path the relay capacity is **hardcoded to 1**
(`InferenceRelay.maxActiveRequests = 1`, `CoordinatorClient.swift`); it does
**not** track `max_concurrency`. The relay admits one in-flight
`inference_request` and hard-rejects a concurrent second with
`inference_response_end status: "error_queue_full"` (FR-27) — there is no WS
queue and no `Retry-After`. `max_concurrency` > 1 governs only the *local HTTP*
semaphore (FR-11), not the tunnel. Each admitted request is tracked by its
`request_id`; the `slots_free` heartbeat field reflects WS-tunneled requests as
well as local HTTP requests.

**FR-26. Cancellation handling.**
On receiving `cancel_request` (§ 6.6), the provider aborts the
in-flight inference for the specified `request_id` within 5 seconds
and sends `inference_response_end` with `status: "cancelled"`.
For an unknown or already-completed `request_id` the acknowledgement is
**path-dependent in the shipped relay** (reconciled v1.7, `InferenceRelay.swift`):
on the plaintext relay path it replies idempotently with
`status: "cancelled"` and `chunks_sent: 0`; on the Tier-2 (encrypted) path an
unknown ID is **silently dropped with no ack**. The ≤ v1.6 "always acknowledge
unknown IDs" contract does not hold uniformly — see the detailed §6.6
`cancel_request` note.

**FR-27. Error mapping.**
Inference errors map to `status` values in `inference_response_end`:

| Error condition | `status` value |
|---|---|
| Successful completion | `"complete"` |
| Client cancelled | `"cancelled"` |
| Model not loaded | `"error_model_not_loaded"` |
| Context length exceeded | `"error_context_exceeded"` |
| WS capacity-1 rejection (concurrent 2nd request; no queue exists — FR-25) | `"error_queue_full"` |
| Internal inference error | `"error_internal"` |

**FR-28. Provider-side write buffer backpressure.**
Per § 6.6 "Backpressure — provider-side write buffer": 256-chunk
buffer per request, pause generation on full, resume at 50%.

**FR-29. Local HTTP server coexistence.**
The provider's local HTTP server (§ 6.0–6.4) continues to run
alongside WS-tunneled inference. WS-tunneled inference is an
additional code path, not a replacement. The local HTTP server is
used for `GET /v1/health` diagnostics and for direct-tunnel buyer
traffic (if the provider also has a public URL).

**FR-30. Drain interaction.**
Coordinator-initiated drain (§ 6.5 drain message) MUST NOT terminate
WS-tunneled inference for in-flight requests. The provider completes
all outstanding `inference_request` responses before closing the
WebSocket. This composes with the v1.1.3 `drainFromCoordinator()` path
(drop WS, keep HTTP, reconnect after grace).

**FR-31. Endpoint URL in hello.**
The provider sends `endpoint_url` in hello per § 6.5 if it has a
configured public URL. If omitted or null, the coordinator treats
this provider as WS-tunneled. See § 6.5 for field semantics.

**FR-32. Hello_ack tier and version fields.**
The provider parses `tier` and `recommended_binary_version` from
hello_ack per § 6.5. Logs the tier on connection. Warns if
binary_version < recommended_binary_version.

### Operations

**FR-18. Health endpoint.**
`GET /v1/health` returns a JSON object with the binary's current state:
model loaded (bool), model id, uptime seconds, requests served (total),
requests in-flight, requests queued, total errors, memory usage (RSS),
current health state (from FR-15), and the per-tier capacity values.
This endpoint is unauthenticated and intended for local diagnostics
(the contributor checking their own binary). It is not exposed through
the coordinator. Returns 200 when healthy, 503 when degraded or
unavailable (same JSON body shape, different `status` value).

**FR-19. Configuration layering.**
Configuration is loaded in this precedence order (highest wins):
1. CLI flags (`--port`, `--model`, `--coordinator`, `--config`, etc.)
2. Environment variables (`MACPROVIDER_PORT`, `MACPROVIDER_MODEL`, etc.)
3. Config file (YAML, default path: `~/.config/macprovider/config.yaml`,
   override with `--config` or `MACPROVIDER_CONFIG`)
4. Built-in defaults

**Provider-credential exception (v1.8.2).** After the general layering above is
resolved, a non-empty `provider_id` selects the CLI-owned Keychain item. If that item
exists, it is authoritative even when the layered config contains a different token.
If it is absent and a layered `provider_token` exists, the CLI MUST import it and
verify an exact readback before reporting restart-safe custody. If Keychain access
fails while a layered token remains available, the process MAY continue from that
private migration source but MUST report its typed Keychain failure,
`source=config_fallback`, `restart_safe=false`, and MUST NOT remove that source. A
differing Keychain/YAML pair MUST use Keychain, report `state=conflict`, and preserve
YAML for explicit repair. With
neither an accessible CLI-Keychain item nor a compatibility token, an established
provider joining the coordinator MUST fail explicitly rather than silently connect
bearerless. The deliberate exceptions are local/no-join or donor mode and a fresh
high-entropy `mp-<32hex>` principal using the tokenless first-claim bootstrap protocol.

`malibu-cli credentials import --config <path>` MUST import the exact
`provider_id`/top-level `provider_token` pair from the selected file only when the
Keychain item is absent or already equal. An existing mismatch MUST fail without
mutation. Both commands return only redacted result metadata.
`credentials verify --config <path>` MUST load the selected
file without inherited `MACPROVIDER_*` overrides and compare it with the CLI-Keychain
value. Running `verify` as a second process is the compatibility transaction's
fresh-process staging proof. It is not coordinator admission and never authorizes
Malibu to delete the live migration source.

`malibu-cli credentials status --config <path>` MUST be non-mutating and emit
credential contract version 1 with `credential_store`, `operation`, `provider_id`,
`source`, `condition`, `restart_safe`, `migration_pending`, `recoverable`, and
`action`. `malibu-cli credentials repair --config <path>` MUST require an
owner-owned regular file with mode no broader than 0600, reject symlinks, and verify
the file's device/inode/size/mtime identity before using its token. Repair MAY add an
absent item only through the absent-or-equal import primitive and MAY replace an item
only when the preceding read classified its stored bytes as corrupt. Ready custody is
verified, while conflict, locked, permission-denied, unavailable, degraded, and
unconfigured conditions MUST refuse mutation. Every successful mutation requires an
exact Keychain readback. Neither stdout nor stderr may contain bearer material.

When a process starts with a Keychain credential exactly matching the YAML migration
source, status MUST set `migration_pending=true`. Only after that process authenticates
to the coordinator and successfully publishes its first state update may the CLI
remove the top-level YAML credential. Removal MUST occur under the config lock and
only when the on-disk value and a fresh Keychain read both exactly match the admitted
in-memory bearer. Mismatch or I/O failure preserves YAML and the pending state.
Only the selected YAML file can set `migration_pending`; an environment value or
`--token-file` may seed Keychain custody but is not an on-disk source for this cleanup.
Automatic autotune backups MUST omit top-level `provider_token`, and admission cleanup
MUST redact legacy machine-owned `config.yaml.bak-<unix>-<counter>` snapshots before
removing the live source. Operator-named archives are outside that automatic cleanup.
If a current-target autoupdate rollback marker exists, YAML cleanup MUST wait until the
rollback owner has accepted the same serving proof and finalized the update. The
coordinator-owned path commits its rollback before cleanup; a `self_update`-owned marker
remains parent-owned, so the child process retains both rollback state and YAML.

Routine `uninstall` preserves the CLI-Keychain credential because it also preserves the
provider principal for safe reinstall. It MUST reject unrecognized manifest labels,
stop the watchdog before the provider, and prove every managed launchd job absent again
after the complete stop phase before removing an executable or plist. `launchctl print`
status 0 means still loaded, the documented service-not-found status 113 proves absence,
and every other result fails closed as indeterminate. Credential destruction requires a
future explicit full-identity-reset operation; routine uninstall is not that operation.

The local `GET /v1/status` response includes a versioned envelope. Contract v1 has
`minimum_reader_version=1`, names `macprovider_cli` as `lifecycle_owner`, and advertises
only fields a reader may trust through these capabilities:
`buyer_serving_authority_v1`, `catalog_status_v1`, `credential_status_v1`,
`status_observation_v1`, `service_instance_v1`, `lifecycle_transition_v1`,
`referral_bootstrap_v1`, `referral_status_v1`, `referral_advocacy_v1`,
`referral_fragment_links_v1`, and
`legacy_reader_fallback_v1`. A reader MUST suppress a typed field when its capability
is absent and MUST suppress all typed fields when the minimum reader exceeds its
supported version. An absent envelope is the legacy-reader path.

```json
"local_status_contract": {
  "version": 1,
  "minimum_reader_version": 1,
  "lifecycle_owner": "macprovider_cli",
  "capabilities": ["status_observation_v1", "service_instance_v1", "lifecycle_transition_v1", "referral_bootstrap_v1", "referral_status_v1", "referral_advocacy_v1", "referral_fragment_links_v1"]
},
"observation": {
  "id": "per-response UUID",
  "observed_at": "RFC 3339 timestamp",
  "valid_for_ms": 5000
},
"service_instance": {
  "instance_id": "stable process-lifetime UUID",
  "pid": 1234,
  "boot_session": "macOS boot-session UUID or null",
  "started_at": "RFC 3339 timestamp",
  "role": "serve"
},
"lifecycle": {
  "transition_id": "UUID",
  "transition_at": "RFC 3339 timestamp",
  "state": "ready | busy | degraded | unavailable",
  "reason_code": "machine-readable transition reason",
  "authority": "macprovider_cli"
},
"credential": {
  "source": "cli_keychain | config_fallback | none",
  "state": "ready | missing | locked | permission_denied | corrupt | conflict | unavailable | degraded | unconfigured",
  "restart_safe": true,
  "migration_pending": false,
  "recovery_action": "none | retry | unlock_keychain | authorize_keychain | repair_from_protected_source | restore_or_reenroll"
}
```

These objects are local diagnostics only and MUST NOT include the bearer, a prefix, a
hash, or any other stable token-derived value. The service instance identifies a
process, not a provider principal or credential. Observation IDs change per response;
service instance IDs remain stable only for that running `serve` process; transition
IDs change only on a reported lifecycle edge. Older clients MUST tolerate all objects'
absence. `referral_bootstrap_v1` means the running installed CLI implements the
complete SPEC-026 protected handoff: `bootstrap-auth --referral-code-file`,
owner/mode and bounded-content validation, identical initial/proof transmission,
Keychain persist-before-adopt, and safe journal retirement. It is not evidence
that a code is valid or referral enforcement is enabled; it gates only whether
Malibu may offer referral input to that installed CLI.

`GET /v1/status` advertises referral capabilities but does not embed the
coordinator referral projection. When `referral_status_v1` is advertised,
Malibu obtains that projection over the owner-only provider control socket with
`referral_status_request` and this flattened response shape:

```json
{
  "type": "referral_status_response",
  "campaign": "prebeta",
  "join_base_url": "https://configured-public-origin/j",
  "social_state": "locked_until_first_serving | eligible | pending | failed | matured | revoked",
  "base_capacity": 1,
  "configured_bonus_capacity": 2,
  "bonus_capacity": 0,
  "redemptions": 0,
  "remaining": 1,
  "first_serving_seen": true,
  "social_bonus_enabled": false,
  "invite_code": "shareable-code",
  "invite_url": "https://configured-public-origin/j#/shareable-code",
  "observed_at": "RFC 3339 timestamp",
  "pending_challenge": {
    "expires_at": "RFC 3339 timestamp"
  }
}
```

The status capability covers only the request/response projection. Missing,
unknown, or newer `referral_status_v1` suppresses all referral status and action
UI. `referral_advocacy_v1` is separately advertised only when the CLI implements
the complete typed `referral_challenge_request`,
`referral_challenge_reopen_request`, `referral_verify_request`, and
`referral_challenge_cancel_request` flows and their response/error frames.
Malibu requires both capabilities before presenting any advocacy mutation; a
status-capable CLI without `referral_advocacy_v1` remains read-only.
`referral_fragment_links_v1` is additionally required for any referral UI and
asserts that generation, projection, onboarding, and X verification use the
exact fragment grammar. Its absence makes referral status unavailable rather
than falling back to the legacy path/query representation.

The invite URL is a shareable admission capability, distinct from the provider
bearer; it remains reusable referral material and MUST stay out of request URLs,
logs, storage, and diagnostics. All provider secrets and raw onboarding inputs
remain omitted. A successful status response
MUST contain the campaign, join base, social state, counts, serving/social
booleans, and observation time. Invite code/URL and pending challenge are
optional. Coordinator/authentication/unavailability failures use the typed
`referral_error` frame; they MUST NOT be converted into zero balances or local
eligibility. `join_base_url` MUST be credential-free HTTPS and end in `/j`
without a trailing slash. When invite code and URL are present, `invite_url`
MUST equal the exact `join_base_url#/<invite_code>` value supplied by the
authenticated coordinator status. Malibu repeats that exact binding before
presenting or copying the invite. `revoked` is distinct from `failed`:
revocation is an authoritative issuer/policy action, while failure is a
social-verification result; exhaustion is derived from authoritative
`remaining == 0`, not a locally invented social state.

The config file schema includes at minimum: `port`, `model` (HuggingFace
model path), `coordinator_url`, `log_format` (`json` or `text`),
`log_file` (optional path; if set, logs are also written to this file),
`max_context_override`, `max_concurrency_override`, `drain_timeout_s`,
`warmup_enabled` (bool), `max_request_body_bytes` (Stage 1 pre-flight limit).

**Idle-prewarm config (reconciled v1.7, FR-16).** Six keys govern the shipped
`IdlePrewarmer` (config keys under `idle_prewarm.*`; matching CLI flags shown):

| Config key | CLI flag | Default | Range |
|---|---|---|---|
| `idle_prewarm.enabled` | `--idle-prewarm` / `--no-idle-prewarm` | **on** | bool |
| `idle_prewarm.idle_threshold_seconds` | `--idle-prewarm-idle-threshold-s` | 30 | 5…3600 |
| `idle_prewarm.tick_seconds` | `--idle-prewarm-tick-s` | 5 | 1…60 |
| `idle_prewarm.max_tokens` | `--idle-prewarm-max-tokens` | 1 | 1…8 |
| `idle_prewarm.prompt` | `--idle-prewarm-prompt` | `"warm"` | 1…64 bytes |
| `idle_prewarm.run_on_battery` | `--idle-prewarm-on-battery` | **off** | bool |

The YAML config keys (`idle_threshold_seconds`, `tick_seconds`, `run_on_battery`)
differ in spelling from their CLI flags (`--idle-prewarm-idle-threshold-s`,
`--idle-prewarm-tick-s`, `--idle-prewarm-on-battery`); the parser
(`Config.swift`) keys on the YAML spellings shown in the left column.

These supersede the legacy `warmup_enabled` bool as the operative warm-up
controls (the shipped warm-up is idle-triggered, not startup/wake-triggered;
see FR-16). `warmup_enabled` is retained for backward compatibility.

**FR-20. Startup self-test.**
On launch, after loading the model, the binary runs a single short
inference (fixed prompt: `"Hello"`, max_tokens: 5) and verifies that:
- The model produces non-empty output.
- Token counting works (prompt_tokens > 0, completion_tokens > 0).
- Output does not contain leaked stop tokens.
- Wall time is under 30 seconds.

If the self-test fails, the binary logs the failure details and exits
with code 1. The self-test result (throughput in tok/s) is used as the
`throughput_tps_estimate` in FR-17.

---

## 5. Non-functional requirements

**NFR-1. Throughput parity.**
The binary achieves at least 90% of `mlx_lm.server`'s throughput on an
identical model and hardware configuration, measured as tokens per second
on a standardized 200-token generation from a 500-token prompt. Both
streaming and non-streaming modes meet this bar.

**NFR-2. Cold start time.**
From `macprovider-cli start` to the first request being serviceable
(model loaded, self-test passed, HTTP server listening): under 30
seconds on M4 hardware with a 7B 4-bit model. Under 60 seconds on M1
8GB with a 3B 4-bit model.

**NFR-3. Memory stability.**
Under sustained load (continuous requests at 80% of max concurrency for
24 hours), RSS memory growth does not exceed 5% above the post-startup
baseline. No unbounded growth in heap allocations, file descriptors,
or NIO event loop resources.

**NFR-4. Startup robustness.**
If the model path is invalid, the model files are corrupt, or the model
requires more memory than available, the binary exits with code 1 and
a clear diagnostic message to stderr. It does not hang, segfault, or
leave orphaned Metal processes. The diagnostic message includes: what
failed, the model path attempted, available memory, and a suggested
action. No partial server state is left running.

**NFR-5. Build system.**
Swift Package Manager only. No Xcode project file required (though one
may be generated for IDE convenience). No Xcode-only dependencies.
The binary builds on any Mac with Xcode command-line tools and Swift 5.9+.

**NFR-6. Code signing.**
The release binary is signed with a Developer ID certificate for macOS
Gatekeeper approval. First version is not notarized (notarization
requires an Apple Developer Program subscription and adds review
latency). Contributors may need to right-click -> Open on first launch,
or the operator provides a `xattr -d com.apple.quarantine` instruction.

**NFR-7. Logging.**
All log output goes to stdout in structured JSON lines format by
default. Each log line includes: ISO 8601 timestamp, log level, message,
and structured fields (request_id, model, latency_ms, etc.). A `text`
format option is available for human readability during development.
Log level is configurable via `--log-level` (default: `info`). The
binary never logs prompt content or response content at `info` level
(privacy default). `debug` level may log truncated previews. If
`log_file` is set in config, logs are also appended to that file.

**NFR-8. No network calls on startup except coordinator.**
The binary does not phone home, check for updates, or make any outbound
HTTP requests at startup. The only outbound connection is the optional
coordinator WebSocket. The tokenizer config for stop-token derivation
must be bundled with the model files locally (it is — HuggingFace
model repos include `tokenizer_config.json`).

---

## 6. Interface contracts

### 6.0. Global HTTP behavior

**Unknown paths:** Any request to a path not defined below returns
HTTP 404:
```json
{"error":{"message":"Not found","type":"invalid_request_error","code":"path_not_found"}}
```

**Wrong method:** A request with an unsupported HTTP method returns
HTTP 405 with an `Allow` header listing the supported methods.

**Malformed JSON body:** If the request body of a POST is not valid
JSON, return HTTP 400:
```json
{"error":{"message":"Invalid JSON in request body","type":"invalid_request_error","code":"invalid_json"}}
```

**Streaming errors after headers sent:** If an error occurs after the
SSE response headers have been sent (e.g., inference engine failure
mid-stream), emit a final SSE event with the error, then `[DONE]`:
```
data: {"error":{"message":"Inference engine error","type":"server_error","code":"internal_error"}}

data: [DONE]

```
Do not change the HTTP status code mid-stream.

### 6.1. GET /v1/models

**Request:** No body. No required headers.

**Response (200):**
```json
{
  "object": "list",
  "data": [
    {
      "id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
      "object": "model",
      "created": 1716768000,
      "owned_by": "macprovider"
    }
  ]
}
```

`created` is the binary's start time as a Unix timestamp. `id` is the
model's HuggingFace identifier as passed in config. `owned_by` is
always `"macprovider"`.

The `id` field returned by `/v1/models` MUST be emitted with
unescaped forward-slash characters (`/`). Producers MUST set their JSON
encoder to suppress the legal-but-cosmetic `\/` escape — for Swift
`JSONEncoder`, this means
`outputFormatting.formUnion(.withoutEscapingSlashes)`.

Consumers MUST tolerate the escaped form `\/` for backward compatibility
with pre-v1.2.4 phase3-binaries (the v1.2.0..v1.2.2 series may emit
either form depending on encoder defaults). RFC 8259 § 7 permits both,
so consumer tolerance is required by spec.

The producer-side MUST applies to v1.2.4 and later. v1.2.3 binary
happens to already comply but was not specifically required to; this
clause catches the spec up to v1.2.3's behavior and locks it for
v1.2.4+.

Example legacy response (with `\/`), which consumers MUST still tolerate:

```json
{
  "object": "list",
  "data": [
    {
      "id": "mlx-community\/Llama-3.2-3B-Instruct-4bit",
      "object": "model",
      "owned_by": "macprovider",
      "created": 0
    }
  ]
}
```

**Response (503):** Returned if model is not loaded.
```json
{
  "error": {
    "message": "Model not loaded",
    "type": "server_error",
    "code": "model_not_loaded"
  }
}
```

### 6.2. POST /v1/chat/completions

#### Request schema

**Required fields:**

| Field | Type | Constraint |
|---|---|---|
| `model` | string | Must match the loaded model's id using ASCII case-insensitive comparison. Mismatch returns 404. |
| `messages` | array | Non-empty array of message objects. |

**Optional fields:**

| Field | Type | Default | Constraint |
|---|---|---|---|
| `max_tokens` | int | Remaining context capacity | Must be > 0 |
| `temperature` | float | 1.0 | 0.0 to 2.0 |
| `top_p` | float | 1.0 | 0.0 to 1.0 |
| `n` | int | 1 | MUST be 1. Values > 1 rejected with 400 (single-tenant). |
| `stream` | bool | false | |
| `stream_options` | object | null | `{include_usage: bool}`. Per FR-7, binary always emits the usage chunk when `stream=true`; a client-provided `include_usage=false` is silently ignored (not an error). Documented to remove ambiguity for buyers expecting strict opt-out semantics. |
| `stop` | string or array | null | Max 4 stop sequences. |
| `presence_penalty` | float | 0.0 | -2.0 to 2.0 |
| `frequency_penalty` | float | 0.0 | -2.0 to 2.0 |
| `seed` | int | null | Passed to MLX for deterministic decoding if supported. |
| `user` | string | null | Logged at DEBUG level for diagnostics only. |
| `response_format` | object | `{type:"text"}` | `type` is `"text"` or `"json_object"`. `"json_object"` engages MLX structured-decoding hint if available. Any other value rejected with 400. |
| `tools` | array | null | Parsed and validated syntactically (see below). |
| `tool_choice` | string or object | null | Parsed, not acted upon in Tier 1. |

Unknown top-level fields are silently ignored (forward-compatible) and
logged at DEBUG level.

The `model` field in `/v1/chat/completions` requests and the `id`
field returned by `/v1/models` are compared case-insensitively in
ASCII by the provider. A request for `Mlx-Community/Llama-...` against
a provider hosting `mlx-community/Llama-...` MUST be served, not
404'd. This matches `mlx_lm.server` behavior and mirrors the existing
case-insensitivity of HTTP header field names (RFC 9110 § 5.1).
Non-ASCII code points in model identifiers are out of scope; provider
behavior with such identifiers is undefined.

#### Per-message validation

Each entry in `messages` must satisfy:

| Role | Required fields | Rules |
|---|---|---|
| `"system"` | `content` (string) | Must be non-empty string. |
| `"user"` | `content` (string) | Must be non-empty string. No multimodal content arrays in Tier 1. |
| `"assistant"` | `content` (string) or `tool_calls` (array) | At least one must be present and non-null. `content` may be null if `tool_calls` is present. Both null/absent -> 400. |
| `"tool"` | `tool_call_id` (string), `content` (string) | Both required. |

Any other `role` value is rejected with 400.

#### Tool-call validation

**`tools` array** (top-level request field): Each tool object must have
`type: "function"` and a `function` object with `name` (string) and
`parameters` (valid JSON Schema object). If any tool is malformed,
reject with 400:
```json
{"error":{"message":"Invalid tools[0]: missing function.name","type":"invalid_request_error","code":"invalid_tools"}}
```

**`tool_calls` in assistant messages** (message history): Each entry
must have `id` (string), `type: "function"`, and `function` with `name`
(string) and `arguments` (string containing valid JSON). If `arguments`
is not valid JSON, reject with 400.

The binary validates tool shapes syntactically but does not execute
tool calls in Tier 1.

#### Validation order

The request handler processes validation in this sequence. The first
failure short-circuits:

| Step | Check | Failure response |
|---|---|---|
| 1 | JSON parse | 400 `invalid_json` |
| 2 | Required fields present (`messages` non-empty) | 400 `invalid_request` |
| 3 | Field types and ranges (temperature, top_p, n, etc.) | 400 `invalid_request` |
| 4 | Per-message role and content validation | 400 `invalid_request` |
| 5 | Tool/tool_call shape validation (if present) | 400 `invalid_tools` |
| 6 | Model match (`model` field vs loaded model, ASCII case-insensitive) | 404 `model_not_found` |
| 7 | Stage 1 pre-flight (envelope bytes) | 413 `context_length_exceeded` |
| 8 | Stage 2 pre-flight (token count) | 413 `context_length_exceeded` |
| 9 | Semaphore admission (FR-11) | *blocks* on a permit — **no** failure response; the ≤ v1.6 `429 rate_limit_exceeded` was never shipped |

#### Non-streaming response (200)

```json
{
  "id": "chatcmpl-abc123",
  "object": "chat.completion",
  "created": 1716768000,
  "model": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "Hello! How can I help you today?"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 25,
    "completion_tokens": 9,
    "total_tokens": 34
  }
}
```

`id` is a unique identifier per request (format: `chatcmpl-{uuid-hex}`).
`finish_reason` is `"stop"` (natural end or stop token hit) or `"length"`
(max_tokens reached).

#### Error responses

| Status | Condition | Error code |
|---|---|---|
| 400 | Missing/invalid fields, malformed tools, n>1 | `invalid_request` or `invalid_tools` |
| 404 | `model` field doesn't match loaded model | `model_not_found` |
| 413 | Prompt exceeds context capacity (FR-8) | `context_length_exceeded` |
| ~~429~~ | ~~Request queue full~~ — **not shipped (v1.7)**: the HTTP path blocks on the FR-11 semaphore rather than returning 429; `rate_limit_exceeded` is unused on the inference path. The WS-tunneled path signals capacity via `error_queue_full` (FR-27), not an HTTP status. | ~~`rate_limit_exceeded`~~ |
| 503 | Model not loaded or draining | `model_not_loaded` |

All error responses use the OpenAI error envelope:
```json
{"error":{"message":"...","type":"...","param":null,"code":"..."}}
```

Note: HTTP 500 is not an expected response. Internal inference errors
are caught and returned as structured errors (400 for input issues,
503 for model issues). If a 500 escapes, it indicates a bug in the
binary. See AC-2.

#### v1.3 provider CLI additions (serve + models)

The `macprovider-cli` top-level subcommand inventory gains `models` as
the sixth subcommand alongside the existing `serve`, `status`,
`self-test`, `update`, and `uninstall` commands. The `models`
subcommand has actions `models list`, `models switch <model-id>
[--force]`, `models status`, and (v1.4) `models browse` —
see §6.13 for the v1.4 fit guard and §6.14 for `browse`.

**v1.4 amendment to `--force` semantics on `models switch`:** v1.3's
"suppresses ONLY the CLI-side cooldown soft guard" prose is superseded.
`--force` now bypasses BOTH the SPEC-011 v0.5 R-3.1.3 cooldown soft
guard AND the v1.4 §6.13 fit guard (wontFit hard-block, tight warning,
and unknown-on-HF-shape fail-closed override). It still does NOT bypass
`SupportedModels.validate` (catalog membership) or the server-side
concurrency rejection (an in-flight load returns `loadingInProgress`
per SPEC-011 v0.5 R-3.1.x).

The `serve` command gains the following additive flags:

- `--supported-models <ids>` — comma-separated list of HuggingFace
  model IDs or local paths per SPEC-010 v1.5 R-3.6.1. Resolution
  priority is CLI > ENV (`MACPROVIDER_SUPPORTED_MODELS`) > config key
  `supported_models: [string]`. Default unset. When unset after
  resolution, the binary MUST send `supported_models: [model_id]`
  (single-entry) on the v2 `auth_request` initial-stage frame per
  SPEC-010 v1.5 R-3.6.2 and AC-19. This single-entry default is the
  L-1 baseline: it does not change observable routing or `/v1/status`
  shape relative to a pre-SPEC-010 binary per SPEC-010 v1.5 §4.1
  back-compat analysis. Local pre-flight per SPEC-010 v1.5 R-3.6.3
  validates `model_id ∈ supported_models` (case-folded), array length
  <= 64, and each entry <= 256 UTF-8 bytes. Validation failures exit
  code 2 with specific stderr per SPEC-010 v1.5 R-3.6.3 / R-3.1.9.
- `--publish-supported-models <bool>` — opt-in flag per SPEC-010
  v1.5 R-3.6.4. Default `false`. Resolution priority is CLI > ENV
  (`MACPROVIDER_PUBLISH_SUPPORTED_MODELS`) > config key
  `publish_supported_models: bool`, mirroring `--supported-models` per
  SPEC-010 v1.5 AC-10. When `true`, populates
  `publishes_supported_models: true` on the v2 `auth_request`
  initial-stage frame per SPEC-010 v1.5 R-3.1.6 and AC-21. When
  `false` (default), the field is omitted from the wire per SPEC-010
  v1.5 AC-21 unless a future locked SPEC-010 revision requires
  explicit `false` emission.
- `--enable-warm-swap` — opt-in gate per SPEC-011 v0.5 R-3.1.0.
  Boolean: presence enables; explicit `=true` / `=false` are supported.
  Default DISABLED. When disabled, the binary MUST NOT host the §6.8 state
  machine (legacy synchronous load path remains), MUST NOT accept/emit the
  warm-swap control frames, and MUST NOT emit `loading` or
  `model_hash` heartbeat fields. This preserves the SPEC-011 v0.5 L-1
  byte-identical default for the **warm-swap** surface. **Reconciled v1.7:**
  disabling warm-swap alone does **not** guarantee the control socket is
  absent — receipt rotation independently opens it (R-6.9.1,
  `enableWarmSwap || receiptRotator != nil`); the socket is absent only when
  *neither* is enabled. This flag is exclusive to `serve`; it is not valid on
  `models <subcommand>`.
- `--swap-drain-timeout-seconds <N>` — drain budget per SPEC-011
  v0.5 §3.4 and R-3.9.1. Default `20`. Range `5 <= N <= 600` per
  SPEC-011 v0.5 R-3.9.1; out-of-range values cause `serve` to exit
  code 2 with stderr diagnostic at startup per R-3.9.1. Only
  meaningful when `--enable-warm-swap` is set.
- `--ctl-socket-path <path>` — override the macOS-native default per
  SPEC-011 v0.5 R-3.1.5. Default `$TMPDIR/macprovider-cli/ctl.sock`,
  resolved via `FileManager.default.temporaryDirectory`. Socket parent
  directory mode is `0700`; socket mode is `0600`. Meaningful whenever the
  control socket opens — i.e. when `--enable-warm-swap` **or** receipt rotation
  is enabled (R-6.9.1 reconciled v1.7), not warm-swap only.
- `--switch-state-path <path>` — override the cooldown state file per
  SPEC-011 v0.5 R-3.1.4. Default
  `$HOME/Library/Application Support/macprovider-cli/last-switch.ts`.

### 6.3. POST /v1/chat/completions (streaming)

**Request:** Same as 6.2, with `"stream": true`.

**Response:** `Content-Type: text/event-stream; charset=utf-8`

First chunk includes `delta.role`:
```
data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1716768000,"model":"mlx-community/Qwen2.5-7B-Instruct-4bit","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

```

Content chunks:
```
data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1716768000,"model":"mlx-community/Qwen2.5-7B-Instruct-4bit","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

```

Final content chunk has `finish_reason`:
```
data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1716768000,"model":"mlx-community/Qwen2.5-7B-Instruct-4bit","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

```

Usage chunk (FR-7), immediately before `[DONE]`:
```
data: {"id":"chatcmpl-abc123","object":"chat.completion.chunk","created":1716768000,"model":"mlx-community/Qwen2.5-7B-Instruct-4bit","choices":[],"usage":{"prompt_tokens":25,"completion_tokens":9,"total_tokens":34}}

```

Terminator:
```
data: [DONE]

```

Each SSE event is followed by two newlines (`\n\n`). No comment lines.
No blank `data:` lines between events.

### 6.4. GET /v1/health

**Response (200 when healthy, 503 when degraded/unavailable):**
```json
{
  "status": "ready",
  "model": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "model_loaded": true,
  "uptime_s": 3600,
  "requests_total": 142,
  "requests_in_flight": 1,
  "requests_queued": 0,
  "errors_total": 3,
  "memory_rss_mb": 4200,
  "capacity": {
    "ram_gb": 16,
    "ram_tier": "16GB",
    "max_context_tokens": 50000,
    "max_concurrency": 1,
    "throughput_tps_estimate": 19.8
  }
}
```

Same JSON body shape at both 200 and 503. The `status` field
distinguishes the state.

### 6.5. Coordinator WebSocket envelope

All messages are JSON. Direction indicated as C->P (coordinator to
provider) or P->C (provider to coordinator).

#### Handshake (P->C) — sent on WebSocket open
```json
{
  "type": "hello",
  "version": 1,
  "tier": 1,
  "provider_id": "m4-anon",
  "hostname": "Johns-MacBook-Pro.local",
  "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "model_params_b": 7.0,
  "ram_gb": 16,
  "max_context_tokens": 50000,
  "max_concurrency": 1,
  "throughput_tps_estimate": 19.8,
  "binary_version": "0.1.0",
  "attestation": null,
  "endpoint_url": null
}
```

**`provider_id` is normative and stable (v1.1.2 clarification).** It is
the operator-issued identifier that the coordinator looks up in its
static `config.providers[]` map (SPEC-002 v1.0.4 § 7.1, Finding F-2).
The same `provider_id` MUST be reused across reconnects, restarts, and
binary upgrades — it represents the persistent identity of this
provider in the trust pool, not the lifetime of the current process.

Concretely, the phase3-binary obtains `provider_id` from (in priority
order):
1. `--provider-id` CLI flag
2. `MACPROVIDER_PROVIDER_ID` environment variable
3. `provider_id` field in the YAML config file

If none are set, the binary generates a per-instance UUID as a fallback
suitable for development and local testing only. Production
coordinators will reject any unrecognized `provider_id` with WebSocket
close code **4002 `unknown_provider_id`** (per § 6.5 close codes and
SPEC-002 FR-P13), so dev-fallback UUIDs cannot connect to a production
pool without first being enumerated in the coordinator config.

`attestation` is `null` on the legacy `hello` frame and **stays `null`** in the
shipped binary (`CoordinatorClient.swift` always emits `attestation: null`
here). The originally-envisioned "Tier 2 populates it via the
`AttestationProvider` hook" never shipped; the shipped Tier-2 attestation rides
the v2 `auth_request` proof stage (`attestation_token`) owned by SPEC-008 (FR-14
reconciled v1.7), not this legacy field.

**`endpoint_url` determines inference routing mode (v1.2 addition).**
This field is OPTIONAL (may be absent or null). When present and
non-empty, it declares the provider's HTTPS endpoint for HTTP-
forwarding mode (same as SPEC-002 v1.0.4's static `config.providers[]`
endpoint_url, but now self-reported by the provider). When absent or
null, the provider operates in WS-tunneled mode and receives inference
traffic via § 6.6 messages over this WebSocket.

When `endpoint_url` is absent or null in hello, this is the provider-
side signal for WS-tunneled mode. The coordinator's final mode
determination uses BOTH the hello field AND the static
`config.providers[]` map; see SPEC-002 v1.1.1 § 3 for the complete
mode resolution rule. Existing v1.1.x binaries do not send
`endpoint_url`; the coordinator resolves their mode via the static
config map. Net: zero binary changes required for existing providers.

#### Handshake acknowledgement (C->P)
```json
{
  "type": "hello_ack",
  "coordinator_version": 1,
  "assigned_id": "provider-pool-id",
  "heartbeat_interval_s": 30,
  "tier": "pinned",
  "recommended_binary_version": "1.2.0"
}
```

The coordinator may override the heartbeat interval.

**`tier` and `recommended_binary_version` (v1.2 addition).** Both
fields are OPTIONAL and informational.

`tier` is `"pinned"` or `"provisional"` (see SPEC-002 v1.1 § 7.5 for
admission tier semantics). The provider uses this for display purposes
(e.g., `malibu-cli status` output) and MUST NOT change its
inference behavior based on tier.

`recommended_binary_version` is a semver string. If the provider's
`binary_version` (from hello) is older than this value, the provider
SHOULD log a warning: "A newer version is available (vX.Y.Z). Run
'malibu-cli update' to upgrade." The coordinator does NOT enforce
the version — providers running older binaries continue to function.

#### 6.5.1. `pair_ot` and `claim_url` on `hello_ack` (NEW in v1.5)

`hello_ack` MAY include two optional GitHub-claim pairing fields in the
same ack object as `assigned_provider_token` from SPEC-003 FR-C9.3:

```json
{
  "type": "hello_ack",
  "coordinator_version": 1,
  "assigned_id": "provider-pool-id",
  "heartbeat_interval_s": 30,
  "tier": "provisional",
  "recommended_binary_version": "1.5.0",
  "assigned_provider_token": "<64-hex-token>",
  "pair_ot": "<opaque-token>",
  "claim_url": "https://portal.example/claim?ot=<opaque-token>"
}
```

| Field | JSON type | Required | Encoding / meaning |
|---|---|---|---|
| `pair_ot` | string | No | Opaque pairing token matching `^[A-Za-z0-9_\-]{1,256}$`. It is not a provider credential and conveys only the ability to attempt a provider-ownership bind in a downstream auth flow. |
| `claim_url` | string | No | HTTPS URL of the form `https://<portal-host>/claim?ot=<pair_ot>`. The `ot` query value MUST be the same opaque token carried in `pair_ot`. |

The reference coordinator wire struct is the existing `HelloAck` in
`phase4-coordinator/internal/ws/messages.go`, with the additive Go fields:

```go
PairOT   string `json:"pair_ot,omitempty"`
ClaimURL string `json:"claim_url,omitempty"`
```

Both fields are OPTIONAL and use `omitempty` semantics. Absence means
"no pairing material on this ack" and MUST be treated identically to
SPEC-001 v1.4 behavior. The coordinator-side emission policy is defined
by SPEC-003 v0.10 FR-C10; SPEC-001 v1.5 defines only the field names,
types, encodings, and compatibility obligations.

Compatibility: pre-v1.5 Swift binaries ignore unknown `hello_ack` keys
under the same `Codable` / `decodeIfPresent` discipline used for
SPEC-003 FR-C9.3's `assigned_provider_token`. A v1.5 binary connected
to a v1.4 coordinator sees absent optionals and behaves exactly as it
does today.

##### `auth_state` on `hello_ack` / `auth_response` (NEW in v1.8.4)

The same accept ack object (v1 `hello_ack` and v2 proof-stage-accepted
`auth_response`) MAY carry an OPTIONAL `auth_state` string field:

| Field | JSON type | Required | Encoding / meaning |
|---|---|---|---|
| `auth_state` | string | No (`omitempty`) | The coordinator's admission verdict for the registered session. Domain is the closed set `{"bearer_validated", "self_minted", "bearerless_duplicate"}` (the `pool.AuthState` names). `mint_failed` and the reject paths close the connection and MUST NOT appear on an ack. Absent means the coordinator declined to state a verdict (e.g. no token issuer) and the binary MUST fall back to its own inference. |

Reference coordinator wire struct: the existing `HelloAck` / `AuthResponse` in
`phase4-coordinator/internal/ws/messages.go`, additive Go field
`AuthState string \`json:"auth_state,omitempty"\``. SPEC-001 v1.8.4 defines only
the field name, type, encoding, and domain; the coordinator EMISSION policy is
owned by SPEC-003 FR-C9.2a and the autoupdate-trust INTERPRETATION (the
bearerless-duplicate notify-only floor, and fail-closed handling of an
unrecognized value) by SPEC-020 v0.1.7. Compatibility: pre-v1.8.4 binaries
ignore the unknown key (same `decodeIfPresent` discipline as
`assigned_provider_token`); a binary connected to a coordinator that omits the
field behaves exactly as it does today.

#### Capacity heartbeat (P->C) — sent every `heartbeat_interval_s`
```json
{
  "type": "heartbeat",
  "status": "ready",
  "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "model_params_b": 7.0,
  "ram_gb": 16,
  "max_context_tokens": 50000,
  "max_concurrency": 1,
  "slots_free": 1,
  "slots_total": 1,
  "throughput_tps_estimate": 19.8,
  "requests_served_since_last": 12,
  "avg_latency_ms_since_last": 450.0,
  "throughput_tps_since_last": 18.5
}
```

Static fields (`model_id`, `model_params_b`, `ram_gb`, `max_context_tokens`,
`max_concurrency`) are repeated in every heartbeat so the coordinator can
re-establish state after a coordinator restart without requiring a new
handshake.

#### 6.5.2. `needs_claim` coordinator status signal (NEW in v1.5)

`needs_claim` is an optional coordinator-to-provider boolean status
signal carried by the §6.12 `ownership_status` frame. It is C->P only;
the provider-to-coordinator capacity heartbeat above MUST NOT carry
`needs_claim`.

```json
{
  "type": "ownership_status",
  "provider_id": "p_01HK4Z3VYE...",
  "needs_claim": true
}
```

| Field | JSON type | Required | Default when absent | Meaning |
|---|---|---|---|---|
| `needs_claim` | boolean | No | `false` | A coordinator-to-binary status signal that this connected provider should surface a user claim / ownership-binding action. |

SPEC-001 v1.5 owns this carrier placement: `needs_claim` is an
`ownership_status` field, not a provider heartbeat field and not a
binary-to-coordinator request. SPEC-003 v0.10 FR-C10 owns only the
emission policy: when the coordinator sends the status frame, whether it
is one-shot per WebSocket session, and when it must be suppressed after
a successful ownership event.

This field does not add any binary-to-coordinator request field, and
SPEC-001 v1.5 does not define a WebSocket refresh request for pairing
tokens. Compatibility: pre-v1.5 binaries ignore the unknown key on a
recognized C->P frame or handle an unknown C->P frame per §6.5
`nak code=unknown_message_type`. A v1.5 binary MUST treat an absent
`needs_claim` field as `false`, preserving SPEC-001 v1.4 behavior
byte-for-byte when the coordinator omits the field.

#### State update (P->C) — sent on state change, independent of heartbeat
```json
{
  "type": "state_update",
  "state": "degraded",
  "reason": "coordinator warm_up requested",
  "since": "2026-05-27T14:30:00Z",
  "metrics_snapshot": {
    "slots_free": 1,
    "slots_total": 1,
    "requests_served_since_last": 0,
    "avg_latency_ms_since_last": null,
    "throughput_tps_since_last": null
  }
}
```

`state` is one of `ready`, `busy`, `degraded`, `draining`, `unavailable`.
Fired whenever the state changes, independent of the heartbeat schedule.

#### Drain status (P->C) — sent during drain sequence
```json
{
  "type": "drain_status",
  "phase": "in_progress",
  "inflight_requests": 2,
  "estimated_drain_seconds": 15
}
```

`phase` is `"starting"` (SIGTERM just received), `"in_progress"` (waiting
for in-flight requests), or `"complete"` (all drained, about to close
WebSocket). Sent when the binary enters drain (FR-12) or receives a
coordinator `drain` command.

#### Pre-flight check (C->P) — coordinator asks before routing
```json
{
  "type": "preflight",
  "request_id": "buyer-req-uuid",
  "estimated_tokens": 8500
}
```

#### Pre-flight response (P->C)
```json
{
  "type": "preflight_ack",
  "request_id": "buyer-req-uuid",
  "accepted": true,
  "estimated_wait_ms": 0
}
```

If `accepted` is false, the provider includes a reason and relevant context:

The shipped provider emits exactly these four rejection reasons
(`CoordinatorClient.swift`); the ≤ v1.6 `queue_full` and `tier_mismatch` reasons
were **never shipped** (there is no WS queue — FR-25; and no tier-mismatch
preflight rejection) and are struck:

| Reason | Additional fields | Meaning |
|---|---|---|
| `context_exceeds_capacity` | `max_context_tokens` | Prompt too large for this provider |
| `draining` | — | Provider is shutting down |
| `model_not_loaded` | — | Model failed to load or is loading |
| `unhealthy` | — | Provider in unavailable state |
| ~~`queue_full`~~ | ~~`estimated_wait_ms`~~ | **not shipped (v1.7)** — no WS queue; capacity-1 relay rejects at dispatch with `error_queue_full`, not at preflight |
| ~~`tier_mismatch`~~ | ~~`provider_tier`~~ | **not shipped (v1.7)** — no tier-mismatch preflight path |

Example rejection:
```json
{
  "type": "preflight_ack",
  "request_id": "buyer-req-uuid",
  "accepted": false,
  "reason": "context_exceeds_capacity",
  "max_context_tokens": 50000
}
```

#### Drain signal (C->P) — coordinator tells provider to stop registering
```json
{
  "type": "drain"
}
```

**Normative (v1.1.3 clarification).** The coordinator-initiated drain
stops *coordinator registration only*. On receipt the provider MUST:

1. Send `state_update` with `state: "draining"`.
2. Send the `drain_status` sequence: `starting` → `in_progress` →
   `complete` (matching the SIGTERM path in FR-12, since the
   coordinator's accounting is symmetric).
3. Wait for in-flight coordinator-routed requests to complete (subject
   to `drain_timeout_s`).
4. Close the WebSocket cleanly (close code 1000).
5. Attempt to reconnect to the coordinator after a grace period
   (recommended: 10–15 s, longer than typical coordinator restart).

After sending `drain_status: complete` and closing the WebSocket, the
provider MUST re-enter the same reconnect loop used at process start.
The first reconnect attempt MUST occur within 15 seconds of the WS
close (matching the coordinator-side grace period defined in SPEC-002
§ 6). If the first three reconnect attempts fail in a row, the provider
MUST log at WARN level with the attempt count and the last error; it
MUST NOT exit the process. The reconnect cadence follows the same
backoff as the initial-connect path.

This requirement exists because conflating drain with process exit was
the bug fixed in v1.1.3 (Entry 18); v1.1.3/v1.1.4 then exposed a second
bug where reconnect was structurally enabled but not exercised
post-drain. The implementation MUST treat post-drain reconnect as a
first-class path with its own test coverage, not a side effect of the
connect loop's natural retry.

The provider MUST NOT terminate its local buyer HTTP server in
response to this message. The local server continues to serve
direct-to-tunnel buyer traffic (e.g., `https://m4.malibu.tech/...`)
across the coordinator's drain/restart cycle. Coordinator drain is
about pool membership, not provider lifetime.

The local SIGTERM drain (FR-12) is the only path that ends the
provider process. Implementations MUST keep these two drain paths
distinct — conflating them (i.e., calling `exit()` on coordinator
drain) breaks tunnel-direct buyer traffic during every coordinator
restart and is a critical bug. This was discovered the hard way in
phase3-binary v1.1.2 during the first coordinator redeploy on
2026-05-28 (see Decision log Entry 15).

#### Warm-up command (C->P) — no-op acknowledgement (reconciled v1.7)
```json
{
  "type": "warm_up"
}
```

The shipped provider treats `warm_up` as a **no-op**: it emits
`state_update: degraded` (`reason: "coordinator warm_up requested"`)
immediately followed by `state_update: ready` (`reason: "warm_up complete"`),
running **no** synthetic inference in between (`CoordinatorClient.swift`). It is
a stateless two-message acknowledgement — the ≤ v1.6 "runs the warm-up
inference" contract was never shipped. Real prewarming is idle-triggered
(FR-16, `IdlePrewarmer`), independent of this command.

#### Negative acknowledgement (P->C) — protocol error response
```json
{
  "type": "nak",
  "in_reply_to": "preflight",
  "error": {
    "code": "unknown_message_type",
    "message": "Unrecognized message type: 'foo'"
  }
}
```

Sent when the binary receives a malformed or unrecognized coordinator
message. The binary continues operating; a `nak` is informational.

### 6.6. Inference message types (WS-tunneled mode)

**Normative scope.** This section applies ONLY to providers operating
in WS-tunneled mode (determined by the absence of `endpoint_url` in
their `hello` AND the absence of a corresponding `endpoint_url` in the
coordinator's `config.providers[]` entry). Providers operating in
HTTP-forwarding mode MUST NEVER receive these messages from the
coordinator. If an HTTP-forwarding provider receives an
`inference_request`, it SHOULD respond with
`nak code=unknown_message_type` per § 6.5 nak semantics.

Four message types enable the coordinator to deliver buyer inference
requests to providers over the existing WebSocket connection, receive
streamed responses, and propagate cancellations.

#### inference_request (C→P)

Sent by the coordinator when routing a buyer request to a WS-tunneled
provider.

```json
{
  "type": "inference_request",
  "request_id": "req-550e8400-e29b-41d4-a716-446655440000",
  "stream": true,
  "body": "{\"model\":\"mlx-community/Qwen2.5-7B-Instruct-4bit\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":100,\"stream\":true}"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | string | Yes | Always `"inference_request"` |
| `request_id` | string | Yes | UUID assigned by coordinator. Format: `req-{uuid}`. Used for response correlation and cancellation. |
| `stream` | boolean | Yes | Whether the buyer requested streaming. Determines whether the provider sends `inference_response_chunk` per token (true) or a single chunk with the full response (false). |
| `body` | string | Yes | The buyer's original request body, JSON-serialized as a string. The provider parses this as if it were a `POST /v1/chat/completions` request body per § 6.2. |

**Why `body` is a string, not an embedded object:** The buyer's
request may contain fields the coordinator does not parse
(forward-compat). Serializing as a string preserves the exact byte
sequence, avoiding any JSON round-trip lossy-ness (e.g., floating-point
precision, key ordering). The provider parses `body` through its
existing request validation pipeline (§ 6.2).

**Size limit:** The coordinator MUST NOT send an `inference_request`
whose total WS frame size exceeds 16 MB. This accommodates the largest
legal request body (10 MB per FR-8 Stage 1) plus envelope overhead.

#### inference_response_chunk (P→C)

Sent by the provider for each SSE chunk (streaming) or for the
complete response (non-streaming).

```json
{
  "type": "inference_response_chunk",
  "request_id": "req-550e8400-e29b-41d4-a716-446655440000",
  "seq": 0,
  "data": "data: {\"id\":\"chatcmpl-abc123\",\"object\":\"chat.completion.chunk\",\"created\":1716768000,\"model\":\"mlx-community/Qwen2.5-7B-Instruct-4bit\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}\n\n"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | string | Yes | Always `"inference_response_chunk"` |
| `request_id` | string | Yes | Matches the `inference_request.request_id` |
| `seq` | integer | Yes | Zero-based monotonically increasing sequence number within this `request_id`. Used for gap detection and debugging. |
| `data` | string | Yes | For streaming: one SSE event line (including `data: ` prefix and trailing `\n\n`). For non-streaming: the complete JSON response body (no SSE framing). |

**Streaming (`stream: true`):** The provider emits one
`inference_response_chunk` per SSE event that it would have written
to an HTTP response. This includes the `data: [DONE]\n\n` event,
sent as the final chunk before `inference_response_end`.

**Non-streaming (`stream: false`):** The provider emits a single
`inference_response_chunk` with `seq: 0` containing the complete JSON
response body (same shape as § 6.2 non-streaming response). The `data`
field contains the raw JSON string (no `data: ` prefix, no SSE framing).

#### inference_response_end (P→C)

Sent by the provider when inference is complete, cancelled, or failed.

```json
{
  "type": "inference_response_end",
  "request_id": "req-550e8400-e29b-41d4-a716-446655440000",
  "status": "complete",
  "chunks_sent": 47,
  "usage": {
    "prompt_tokens": 25,
    "completion_tokens": 46,
    "total_tokens": 71
  }
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | string | Yes | Always `"inference_response_end"` |
| `request_id` | string | Yes | Matches the `inference_request.request_id` |
| `status` | string | Yes | One of: `"complete"`, `"cancelled"`, `"error_model_not_loaded"`, `"error_context_exceeded"`, `"error_queue_full"`, `"error_internal"` |
| `chunks_sent` | integer | Yes | Total `inference_response_chunk` messages sent for this request. Coordinator verifies it received all chunks. |
| `usage` | object | No | Token usage. Present when `status` is `"complete"` and when `status` is `"cancelled"` in response to `cancel_request`. Contains `prompt_tokens`, `completion_tokens`, `total_tokens`. |
| `error` | string | No | Human-readable error message. Present when `status` starts with `"error_"`. |

When `inference_response_end` is sent in response to a `cancel_request`
(per § 6.6's cancel handling), the provider MUST include a `usage` field
in the `inference_response_end` message with:

- `prompt_tokens`: the tokens consumed for the input prompt.
- `completion_tokens`: the actual number of tokens generated before
  cancellation was honored (may be 0 if cancel arrived before generation
  started).
- `total_tokens`: `prompt_tokens + completion_tokens`.

This requirement enables downstream consumers (gateways per SPEC-006,
accounting systems, billing infrastructure) to settle usage exactly
rather than estimating. Estimation produces small but consistent under-
or over-counts that compound across high-volume cancellation scenarios.

Pre-v1.2.4 phase3-binaries (v1.2.3 and earlier) MAY omit the `usage`
field in cancel-response `inference_response_end`. Consumers SHOULD
fall back to estimation when usage is absent (gateway example:
`ceil(bytes_emitted_so_far / 4)` per SPEC-006 v0.4 D-CROSS-1).

**Invariant:** After sending `inference_response_end`, the provider
MUST NOT send any more `inference_response_chunk` messages for that
`request_id`.

#### cancel_request (C→P)

Sent by the coordinator when the buyer disconnects or the request
times out.

```json
{
  "type": "cancel_request",
  "request_id": "req-550e8400-e29b-41d4-a716-446655440000",
  "reason": "buyer_disconnected"
}
```

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | string | Yes | Always `"cancel_request"` |
| `request_id` | string | Yes | The `request_id` of the inference to cancel |
| `reason` | string | Yes | One of: `"buyer_disconnected"`, `"timeout"`, `"coordinator_shutdown"` |

**Provider behavior on receipt (reconciled v1.7 — capacity-1 relay, no queue):**
1. If the `request_id` is currently being processed: abort inference,
   release the slot, send `inference_response_end` with
   `status: "cancelled"`.
2. If the `request_id` is unknown: behavior is path-dependent in the shipped
   relay (`InferenceRelay.swift`). On the plaintext relay path it acknowledges
   idempotently (`inference_response_end status: "cancelled"`, `chunks_sent: 0`);
   on the Tier-2 path an unknown ID **silently returns** with no ack. The ≤ v1.6
   "always send a cancelled ack for unknown IDs" contract does not hold uniformly.
3. There is **no case-3 queue removal** — the relay has only an *active* request
   map (capacity 1) and no pending queue (FR-25), so a not-yet-started queued
   request cannot exist. The ≤ v1.6 "remove from queue" step is struck.

#### Request ID lifecycle and error handling

**Unknown request_id (coordinator-side).** If the coordinator receives
an `inference_response_chunk` or `inference_response_end` with a
`request_id` it did not issue (or that has already been cleaned up),
the coordinator MUST log at warn level and discard the frame. The
coordinator MUST NOT propagate unknown-`request_id` data to any buyer.
The coordinator MUST NOT close the WebSocket — the stale frame may be
from a request that completed or timed out moments ago.

**Duplicate active request_id (provider-side).** The coordinator MUST
NEVER reuse a `request_id` while the prior request with that ID is
still in-flight (i.e., no `inference_response_end` received and no
coordinator-side timeout expired). If a provider receives an
`inference_request` with a `request_id` that is already in its active
map, this is a coordinator protocol error. The provider MUST send
`nak` with `code: "duplicate_request_id"` and the original request
continues unaffected. The provider MUST NOT start a second inference
for the duplicate ID.

**Completed request_id cleanup.**
- **Coordinator:** Removes a `request_id` from its active map after
  receiving `inference_response_end` OR after the coordinator-side
  timeout expires (SPEC-002 `routing.request_timeout_s`, default 300 s).
- **Provider:** Removes a `request_id` from its active map upon
  sending `inference_response_end` OR upon receiving `cancel_request`
  and sending the acknowledging `inference_response_end`.

#### Ordering guarantees

**Within a single `request_id`:** The provider MUST send
`inference_response_chunk` messages in `seq` order (0, 1, 2, ...).
The coordinator MUST relay them to the buyer in `seq` order. If a
chunk arrives out of order, the coordinator buffers it for up to 5
seconds waiting for the missing chunk. If the gap is not filled, the
coordinator treats it as a provider error, sends `cancel_request`, and
returns HTTP 502 to the buyer.

**Across `request_id` values:** No cross-request ordering guarantee, and the
`request_id` is the demultiplexing key. In practice, however, the shipped WS
relay is **capacity 1** (§6.6 Multiplexing / FR-25), so on a single WebSocket
only one request is in flight at a time and cross-request chunk interleaving
does not actually occur; the "may interleave freely" allowance is a protocol
statement for a hypothetical multi-capacity relay, not current behavior.

#### Multiplexing

A single provider WebSocket carries at most **one** in-flight inference
request (reconciled v1.7): the shipped `InferenceRelay` fixes capacity to
**1** (`maxActiveRequests = 1`) regardless of advertised `max_concurrency`, and
hard-rejects a concurrent second with `error_queue_full` (FR-25/FR-27). The
`max_concurrency` advertisement governs only the *local HTTP* semaphore (FR-11),
not the tunnel; a coordinator MUST NOT send a second concurrent
`inference_request` on one WS while the first is in flight. Each WS text frame is
one complete JSON message — no multi-frame messages, no application-layer
fragmentation. (The ≤ v1.6 "up to N = `max_concurrency`" multiplexing contract
was never shipped for the tunnel.)

#### Retransmission policy

**No retransmission at the application layer.** If the WS connection
drops, all outstanding requests on that connection are failed. TCP
guarantees in-order delivery on an established connection. WS frame
loss only happens on connection failure, at which point all in-flight
state is lost. Application-layer retransmission adds complexity without
benefit for the v1 single-WS architecture.

#### Backpressure — provider-side write buffer

The provider maintains a bounded write buffer for outgoing
`inference_response_chunk` messages per active `request_id`:

- **Buffer size:** 256 chunks per request. At 30 tok/s, this absorbs
  ~8.5 seconds of WS write latency.
- **High-water behavior:** If the per-request buffer fills, the
  provider pauses token generation for that request. The provider
  MUST NOT drop chunks — every generated token must be delivered or
  the response is corrupt.
- **Buffer drain:** The provider resumes generation when the buffer
  drops below 50% capacity (128 chunks). This hysteresis prevents
  rapid pause/resume oscillation.

### 6.7. v2 `auth_request` handshake (NEW in v1.3)

Locked SPEC-001 v1.2.4 §6.5 documents the legacy `hello` handshake.
The v2 `auth_request` two-stage handshake has been in code since
SPEC-001 v1.2.x but was never normatively documented in SPEC-001; this
section closes that gap. **Reconciled v1.7 — handshake selection is
mode-based, not first-connect-vs-reconnect.** Every (re)connect re-enters the
same connect path (`connectAndRun()`): a **WS-tunneled or credential-bootstrap**
connection performs a **fresh v2 `auth_request` challenge/proof handshake on
each reconnect** (re-negotiating identity/attestation and the encrypted leg);
the legacy `hello` handshake at §6.5 is used **only** by legacy
HTTP-forwarding-mode connections. So `hello` is not a universal "back-compat
reconnect path" — a WS-tunneled provider re-runs the full v2 handshake when it
reconnects.

#### 6.7.1. Initial-stage frame (P->C)

R-6.7.1 **When the v2 handshake applies** (WS-tunneled or credential-bootstrap
mode — R-6.7.8; a legacy HTTP-forwarding connection sends `hello` at §6.5
instead), the binary MUST send the v2 initial-stage frame with
`type == "auth_request"`, `version == 2`, and `stage == "initial"` per
SPEC-010 v1.5 R-3.1.1 through R-3.1.10 and the parser-required field
table in SPEC-010 v1.5 §3.1.A.

The initial-stage frame field table is the SPEC-010 v1.5 §3.1.A table:

| Field | JSON name | Type | Parser requiredness | Notes |
|---|---|---|---|---|
| Message type | `type` | string, exactly `"auth_request"` | REQUIRED by frame validator | parser rejects with `bad_message_type` otherwise |
| Protocol version | `version` | int, exactly `2` | REQUIRED by frame validator | parser rejects with `bad_version` otherwise |
| Stage | `stage` | string, exactly `"initial"` here | REQUIRED by frame validator | parser routes to `parseAuthInitial` for `"initial"`, `parseAuthProof` for `"proof"` |
| Provider ID | `provider_id` | string (operator-provided; **not** constrained to ULID by the provider — an arbitrary configured string is accepted, else a generated UUID; `Config.swift` / `CoordinatorClient.swift`) | REQUIRED by `parseAuthInitial` | ULID is the *recommended* operator format, not a provider-enforced constraint |
| Hostname | `hostname` | string | REQUIRED by `parseAuthInitial` | struct tag is `omitempty` but parser requires it |
| Loaded model | `model_id` | string | REQUIRED by `parseAuthInitial` | struct tag is `omitempty` but parser requires it |
| Model hash | `model_hash` | string sha256-hex | optional | SPEC-008 Pillar A |
| Model params (B) | `model_params_b` | float | REQUIRED by `parseAuthInitial` | |
| RAM (GB) | `ram_gb` | int | REQUIRED by `parseAuthInitial` | |
| Max context tokens | `max_context_tokens` | int | REQUIRED by `parseAuthInitial` | |
| Max concurrency | `max_concurrency` | int | REQUIRED by `parseAuthInitial` | |
| Throughput TPS estimate | `throughput_tps_estimate` | float | REQUIRED by `parseAuthInitial` | |
| Model load time | `model_load_time_ms` | int64 | optional | |
| Binary version | `binary_version` | string | REQUIRED by `parseAuthInitial` | |
| Endpoint URL | `endpoint_url` | string pointer (nullable) | optional | |
| Provider ECDH public key | `provider_ecdh_public_key` | string **unpadded base64url** (32-byte x25519) | REQUIRED by `parseAuthInitial` | SPEC-008 Tier-2; base64url per SPEC-008, not standard padded base64 |
| Provider receipt public key | `provider_receipt_public_key` | string standard padded base64 of 32-byte ed25519 public key | optional, ADDED by SPEC-015 v0.1.3 / SPEC-001 v1.6 | parser-optional; initial-stage only; absent means the provider is not receipt-issuing |
| Provider admission public key | `provider_admission_public_key` | string standard padded base64 of 32-byte Ed25519 public key | optional, SPEC-026 §4.3 | current local key; during explicit recovery, the staged recovery key |
| Provider next admission public key | `provider_admission_next_public_key` | string standard padded base64 of 32-byte Ed25519 public key | optional, SPEC-026 §4.3 | one idempotently staged rotation candidate; transcript-bound |
| Admission recovery marker | `provider_admission_recovery` | bool | optional, SPEC-026 §4.3 | true only for operator-authorized lost/App-custody recovery |
| Tier-2 capabilities | `tier2_capabilities` | object `{encrypted_leg: bool, attestation: bool, aead_suites: []string, response_chunk_plaintext_envelope: bool, in_band_aead_rekey_v1: bool}` | REQUIRED by `parseAuthInitial` | SPEC-008 Tier-2; the v1.8 implementation sends all booleans `true` and `aead_suites:["A256GCM"]`. The additive sub-field transport is carried in §6.15.1; SPEC-008 v0.5 owns in-band rekey semantics |
| Supported models | `supported_models` | array of strings | optional, ADDED by SPEC-010 v1.5 | rules per SPEC-010 v1.5 R-3.1.1 through R-3.1.9 and R-3.6.1 through R-3.6.3 |
| Publishes supported models | `publishes_supported_models` | bool | optional, ADDED by SPEC-010 v1.5 | rules per SPEC-010 v1.5 R-3.1.6 and R-3.6.4 |

R-6.7.2 The binary MUST populate the frame from the same flag
resolution as legacy `hello`: `provider_id` from CLI > ENV > config and
`model_id` from `--model`, plus SPEC-010 fields resolved per §6.2 and
SPEC-010 v1.5 R-3.6.1 through R-3.6.4.

R-6.7.3 The `supported_models[]` and `publishes_supported_models`
fields are SPEC-010 fields controlled by `--supported-models` /
`--publish-supported-models` per SPEC-010 v1.5 R-3.6.1 and R-3.6.4,
independent of the SPEC-011 heartbeat/control-socket gate per
SPEC-011 v0.5 R-3.1.0 and R-3.3.0. `supported_models[]` is ALWAYS
emitted by a v1.3 binary on the v2 `auth_request` initial-stage
frame: when `--supported-models` is set after CLI/ENV/config
resolution, the resolved list is emitted; when unset, the binary
MUST emit `supported_models: [model_id]` (single-entry) per SPEC-010
v1.5 R-3.6.2 and AC-19. `publishes_supported_models` is the bool
that the operator opts into; when `false` (default), the field is
OMITTED from the wire per SPEC-010 v1.5 AC-21; when `true`, the
field is emitted as `publishes_supported_models: true`. They MUST
NOT be treated as warm-swap heartbeat fields.

Wire example with all parser-required fields plus SPEC-010 additions
(structure copied from SPEC-010 v1.5 §3.1.B):

```json
{
  "type": "auth_request",
  "version": 2,
  "stage": "initial",
  "provider_id": "p_01HK4Z3VYE...",
  "hostname": "mac-mini-01.local",
  "model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "model_params_b": 7.6,
  "ram_gb": 64,
  "max_context_tokens": 32768,
  "max_concurrency": 1,
  "throughput_tps_estimate": 42.5,
  "binary_version": "1.8.32",
  "provider_ecdh_public_key": "<unpadded-base64url-32-byte-x25519-public-key>",
  "tier2_capabilities": {
    "encrypted_leg": true,
    "attestation": true,
    "aead_suites": ["A256GCM"],
    "response_chunk_plaintext_envelope": true,
    "in_band_aead_rekey_v1": true
  },
  "supported_models": [
    "mlx-community/Qwen2.5-7B-Instruct-4bit",
    "mlx-community/Llama-3.1-8B-Instruct-4bit",
    "mlx-community/Mistral-7B-Instruct-v0.3-4bit"
  ],
  "publishes_supported_models": true
}
```

**Reconciled v1.7, extended v1.8.** Binary 1.8.31 unconditionally advertises
`tier2_capabilities` with `encrypted_leg: true`,
`attestation: true`, `aead_suites: ["A256GCM"]`, the 4th sub-field
`response_chunk_plaintext_envelope: true`; binary 1.8.32 adds the v1.8 5th
sub-field `in_band_aead_rekey_v1: true` (`CoordinatorClient.swift`) — the
earlier all-`false`/empty example reflected the never-shipped "v1.3 adds no
encrypted-leg/attestation behavior" stance and is corrected above.
`provider_ecdh_public_key` is **unpadded base64url** (not standard padded
base64) per SPEC-008. Tier-2 fields (`provider_ecdh_public_key`,
`tier2_capabilities`) are parser-required in the v2 initial-stage frame; their
semantics and the encrypted-leg / attestation pipeline are owned by **SPEC-008**
(§6.15). See §6.15.1 for the additive capability fields.

#### 6.7.2. Proof-stage frame (P->C)

R-6.7.4 The binary MUST send the v2 proof-stage frame with the
SPEC-010 v1.5 §3.1.C field set and MUST echo the coordinator-generated
`auth_attempt_id` from the prior `auth_challenge` per SPEC-010 v1.5
R-3.1.10.

| Field | JSON name | Type | Parser requiredness | Notes |
|---|---|---|---|---|
| Message type | `type` | string, exactly `"auth_request"` | REQUIRED by frame validator | shared with initial stage |
| Protocol version | `version` | int, exactly `2` | REQUIRED by frame validator | shared with initial stage |
| Stage | `stage` | string, exactly `"proof"` | REQUIRED by frame validator | parser routes to `parseAuthProof` |
| Auth attempt ID | `auth_attempt_id` | string | REQUIRED by `parseAuthProof` | echoes coordinator-generated value from prior `auth_challenge` |
| Provider ID | `provider_id` | string | REQUIRED by `parseAuthProof` | must match initial-stage provider ID |
| Attestation token | `attestation_token` | JSON raw | conditional per SPEC-008 Tier-2 | |
| Supported models | `supported_models` | array of strings | optional, ADDED by SPEC-010 v1.5 R-3.1.10 | absent is not a mismatch |
| Publishes supported models | `publishes_supported_models` | bool | optional, ADDED by SPEC-010 v1.5 R-3.1.10 | absent is not a mismatch |
| Identity signature | `identity_signature` | string standard base64 of 64-byte Ed25519 signature | conditional, SPEC-026 §4.3 | proves coordinator-selected admission key |
| Identity transcript hash | `identity_signature_transcript_sha256` | string standard base64 of 32-byte SHA-256 | conditional, SPEC-026 §4.3 | hash of canonical initial frame, including rotation/recovery fields |

R-6.7.5 The coordinator generates `auth_attempt_id` at
`phase4-coordinator/internal/ws/server.go` (`authAttemptID := "auth-" +
s.newUUID()`, ~L1091). The binary MUST NOT
generate this value; it echoes the value received on `auth_challenge`
on the proof-stage frame per SPEC-010 v1.5 R-3.1.10.

R-6.7.6 If the binary re-sends `supported_models[]` or
`publishes_supported_models` on the proof-stage frame, the values MUST
be byte-identical to the initial-stage values per SPEC-010 v1.5
R-3.1.10.

#### 6.7.1.5. Coordinator-sent handshake frames — inbound schema carried here (reconciled v1.7)

The coordinator's two handshake responses carry fields that the shipped binary
**requires** but that no downstream spec fully names; SPEC-001 carries them as
transport owner of last resort (`CoordinatorClient.swift`):

**`auth_challenge` (C->P), after the initial-stage `auth_request`:**

| Field | JSON name | Type | Requiredness | Notes |
|---|---|---|---|---|
| Type | `type` | string `"auth_challenge"` | REQUIRED | else the binary aborts the handshake |
| Version | `version` | int `2` | REQUIRED | |
| Assigned ID | `assigned_id` | string | REQUIRED | coordinator-assigned session/provider id |
| Coordinator ECDH key | `coordinator_ecdh_public_key` | string | REQUIRED | SPEC-008 Tier-2 key agreement |
| Selected AEAD suite | `selected_aead_suite` | string | REQUIRED | e.g. `A256GCM` |
| Auth attempt ID | `auth_attempt_id` | string | REQUIRED | echoed on the proof frame |
| Bootstrap identity key | `bootstrap_identity_public_key` | string standard base64 | **conditional** | when present, the binary selects and persists the matching durable receipt-identity signing key for this bootstrap (SPEC-003 credential bootstrap pairing); absent otherwise |
| Admission identity key | `admission_identity_public_key` | string standard base64 | **conditional** | exact local key the coordinator requires for this proof; recovery challenges the staged recovery key |
| Admission identity generation | `admission_identity_generation` | positive int | **conditional** | authoritative generation before the proposed transition |

**Accepted `auth_response` (C->P), after the proof-stage frame** — the binary
requires **all** of:

- `type: "auth_response"`, `version: 2` (rejected otherwise);
- `status: "accepted"` (a non-accepted status is treated as a rejection);
- `tier2_session.encrypted_leg` with `enabled: true` and matching `alg` (the
  provider-selected AEAD) and `kid` (the session key id), optionally
  `response_chunk_plaintext_envelope: true` and
  `in_band_aead_rekey_v1: true` (§6.15.1). Absence of the latter keeps the
  authenticated epoch valid but the binary MUST reject in-band rekey frames;
- `catalog_compatible: true` **when the provider advertised a signed-catalog
  admission block** (i.e. `catalog_release_id` was sent). A catalog-bearing
  session whose `auth_response` lacks `catalog_compatible: true` is rejected by
  the binary. This boolean is not named by SPEC-010 (which leaves catalog
  signing out of scope) or SPEC-022; SPEC-001 carries it here.
- for signed CLI admission, `admission_identity_public_key` (authoritative active
  key), `identity_generation`, and `identity_admission_key_role` (`current`,
  `previous`, or `recovery`). The binary commits local Keychain mutation only when
  these authenticated fields match the staged transaction; previous-key admission is
  degraded and never overwrites local custody.

A spec-only coordinator MUST emit these fields or the shipped binary fails
admission.

#### 6.7.2.1. `pair_ot` and `claim_url` on accepted `auth_response` (NEW in v1.5)

The v2 proof-stage-accepted `auth_response` MAY include the same optional
pairing fields defined for `hello_ack` in §6.5.1. The example below is
**abbreviated** to the pairing fields only — a real accepted `auth_response`
also carries the required `version: 2`, `status: "accepted"`, `tier2_session`,
and (for catalog-bearing sessions) `catalog_compatible: true` per §6.7.1.5:

```json
{
  "type": "auth_response",
  "version": 2,
  "status": "accepted",
  "assigned_provider_token": "<64-hex-token>",
  "pair_ot": "<opaque-token>",
  "claim_url": "https://portal.example/claim?ot=<opaque-token>"
}
```

| Field | JSON type | Required | Encoding / meaning |
|---|---|---|---|
| `pair_ot` | string | No | Opaque pairing token matching `^[A-Za-z0-9_\-]{1,256}$`. |
| `claim_url` | string | No | HTTPS URL of the form `https://<portal-host>/claim?ot=<pair_ot>`. |

The reference coordinator wire struct is the existing `AuthResponse` in
`phase4-coordinator/internal/ws/messages.go`, with the additive Go fields:

```go
PairOT   string `json:"pair_ot,omitempty"`
ClaimURL string `json:"claim_url,omitempty"`
```

These fields are valid only on proof-stage-accepted `auth_response`
frames. They MUST NOT appear on `auth_challenge` frames or on
rejection-shaped `auth_response` frames; a rejected handshake carrying
usable pairing material is a protocol violation. The coordinator-side
conditions for including the fields on an accepted response are defined
by SPEC-003 v0.10 FR-C10.

Compatibility matches §6.5.1: pre-v1.5 Swift binaries ignore unknown
accepted-response keys, and v1.5 binaries treat absent fields from a v1.4
coordinator as empty optionals with no behavior change.

#### 6.7.3. Two opt-ins, four matrix cells

R-6.7.7 The binary MUST treat SPEC-010 catalog publication and
SPEC-011 warm swap as orthogonal opt-ins per SPEC-010 v1.5 R-3.6.1 /
R-3.6.4 and SPEC-011 v0.5 R-3.1.0 / R-3.3.0.

The cells below describe the `auth_request` **field content** in the mode where
the v2 handshake applies (WS-tunneled / credential-bootstrap — R-6.7.8). These
opt-ins do **not** select v2 vs legacy `hello`; the transport mode does. In
legacy HTTP-forwarding mode the equivalent catalog fields ride the `hello` frame.

| `--supported-models` | `--enable-warm-swap` | Behavior cell |
|---|---|---|
| unset | unset | LEGACY-EQUIVALENT: v2 `auth_request` initial-stage frame emits `supported_models: [model_id]` (single-entry) per SPEC-010 v1.5 R-3.6.2 / AC-19; `publishes_supported_models` is OMITTED per SPEC-010 v1.5 R-3.6.4 / AC-21; no `model_hash` or `loading` heartbeat fields per SPEC-011 v0.5 R-3.3.0; no control socket per SPEC-011 v0.5 R-3.1.0. This is the L-1 baseline cell: no NEW SPEC-010 or SPEC-011 surface beyond the single-entry catalog (which SPEC-010 v1.5 §4.1 establishes as observably indistinguishable from a pre-SPEC-010 binary on routing, `/v1/status`, and `/v1/models`). Buyer HTTP behavior is unchanged from SPEC-001 v1.2.4. |
| set | unset | SPEC-010 only: provider publishes the explicit catalog list per SPEC-010 v1.5 R-3.6.1, with `publishes_supported_models: true` (when `--publish-supported-models=true`) per SPEC-010 v1.5 R-3.6.4. No warm swap; no `model_hash` / `loading` heartbeat fields per SPEC-011 v0.5 R-3.3.0; no control socket per SPEC-011 v0.5 R-3.1.0. |
| unset | set | SPEC-011 only: warm swap enabled per SPEC-011 v0.5 R-3.1.0; heartbeat carries `model_hash` / `loading` per SPEC-011 v0.5 R-3.3.0 / R-3.3.1; effective catalog is `supported_models: [model_id]` (single-entry, from R-3.6.2 default resolution) and `publishes_supported_models` remains OMITTED per SPEC-010 v1.5 R-3.6.4 / AC-21. |
| set | set | BOTH: explicit catalog emitted per SPEC-010 v1.5 R-3.6.1 / R-3.6.4 and warm swap surfaces enabled per SPEC-011 v0.5 R-3.1.0 / R-3.3.0. |

> **Socket caveat (reconciled v1.7).** The "no control socket" phrasing in the
> two warm-swap-*unset* cells is scoped to the SPEC-011 warm-swap surface. A
> third orthogonal opt-in — **receipt rotation** (`--enable-receipts` with a
> provider ID + coordinator) — opens the *same* control socket independently of
> warm swap (R-6.9.1, `enableWarmSwap || receiptRotator != nil`). So a
> warm-swap-unset binary in receipts mode **does** have an open control socket
> (which answers `status_request` but rejects `switch_request`). "No control
> socket" holds only when neither warm-swap nor receipts is enabled.

#### 6.7.4. Back-compat with legacy hello

R-6.7.8 (reconciled v1.7) A v1.3 binary selects the first-connection handshake
**by mode**, not universally: a **WS-tunneled or credential-bootstrap**
connection uses the v2 `auth_request` two-stage handshake per SPEC-010 v1.5 §3.1
and R-3.1.1 through R-3.1.10; a **legacy HTTP-forwarding-mode** connection uses
the legacy §6.5 `hello` (`CoordinatorClient.swift` `connectAndRun()` selects on
`wsTunneledMode` / credential-bootstrap; the first-connect test confirms
`wsTunneledMode=false` sends `hello`). The SPEC-010 catalog / SPEC-011 warm-swap
opt-ins do not themselves force v2 — the transport mode does. The coordinator
accepts the v1 `hello` path unless encrypted-leg enforcement is enabled
(`server.go`).

R-6.7.9 (reconciled v1.7) The legacy `hello` handshake at §6.5 is the reconnect
mid-session path **only for legacy HTTP-forwarding-mode connections** (per
SPEC-011 v0.5 §3.8 / R-3.8.3, including WS drop reconnect after a
warm-swap-in-flight in that mode). A **WS-tunneled or credential-bootstrap**
connection instead re-runs the **full v2 `auth_request` challenge/proof
handshake on every reconnect** (`CoordinatorClient.swift` `connectAndRun()`); it
does not fall back to `hello`. The mode, not the connect/reconnect distinction,
selects the handshake.

R-6.7.10 A pre-v1.3 (v1.2.x) binary uses legacy `hello` on first
connect; the coordinator accepts both paths per SPEC-010 v1.5 §3.1 and
SPEC-011 v0.5 R-3.8.3 compatibility notes.

#### 6.7.5. SPEC-015 receipt pubkey initial-stage field (NEW in v1.6)

SPEC-015 v0.1.3 §7.2 adds the optional initial-stage field
`provider_receipt_public_key` to publish the provider's receipt
verification key for non-streaming inference receipts. When present,
the field value MUST be standard padded base64 of exactly 32 bytes of
ed25519 public key material. The coordinator parser MUST accept an
absent field so pre-v1.6 binaries continue to admit; an absent field
means the provider is not receipt-issuing for SPEC-015 v0.1.x.

The field is valid on the v2 `auth_request` initial-stage frame only.
The proof-stage field table in §6.7.2 is unchanged; the binary MUST NOT
echo `provider_receipt_public_key` on proof-stage frames. SPEC-015
v0.1.3 deliberately restricts this absorption to one additive field and
does not introduce any receipt-specific WebSocket control frame.

### 6.8. Warm-swap opt-in gate + runtime state machine (NEW in v1.3)

SPEC-011 v0.5 §2 L-1 locks the byte-identical default and L-2 locks
operator initiation. The §6.8 state machine and §6.10 heartbeat extension
activate ONLY when the operator invokes `serve` with `--enable-warm-swap`. In
disabled mode, the binary follows the SPEC-001 v1.2.4 synchronous-load path: the
current `ModelRuntime` actor populates a single immutable container at boot.
**Reconciled v1.7:** the §6.9 control *socket* itself is **not** exclusive to
warm-swap — receipt rotation opens the same socket independently (R-6.9.1). Only
the warm-swap *frames* and state machine are gated on `--enable-warm-swap`; a
receipts-only socket exists but rejects `switch_request`.

#### 6.8.1. ModelRuntime refactor (REQUIRED when warm swap enabled)

R-6.8.1 When `--enable-warm-swap` is enabled, the existing immutable
`let container` / `let modelID` / `let modelHash` fields in
`ModelRuntime` (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
lines 25-68, 86-147) MUST be refactored to actor-isolated mutable state
per SPEC-011 v0.5 R-3.2.1.

R-6.8.2 The actor MUST expose `currentContainer() -> ModelContainer`
for snapshot reads and `swap(new: ModelContainer, newID: String,
newHash: String)` for atomic replacement per SPEC-011 v0.5 R-3.2.1 and
R-3.2.4.

#### 6.8.2. State enumeration

R-6.8.3 Runtime state values are `ready`, `loading`, `draining`, and
`failed` with the semantics of SPEC-011 v0.5 R-3.2.3. The SPEC-011
v0.5 §3.2 state machine diagram is incorporated by reference and MUST
NOT be redrawn here.

#### 6.8.3. Inference-while-loading rejection

R-6.8.4 In `loading` or `draining`, NEW HTTP inference requests to the
binary MUST be rejected with HTTP 503 and OpenAI envelope
`{error: {type: "service_unavailable", code: "provider_loading"}}` per
SPEC-011 v0.5 R-3.2.3 and R-3.4.4. In-flight requests started in
`ready` MUST continue to completion using their snapshot reference per
SPEC-011 v0.5 R-3.2.2.

#### 6.8.4. No-starve rule

R-6.8.5 The async load task MUST run on Swift task isolation distinct
from the WebSocket receive loop, the WebSocket send loop including
heartbeat emission, and the HTTP inference server accept loop per
SPEC-011 v0.5 R-3.2.5. Heartbeat MUST continue at the negotiated
cadence throughout `loading` and `draining`, anchoring SPEC-002 §11
J.1's v1.1.6 35s heartbeat-miss kill incident as cited by SPEC-011
v0.5 R-3.2.5.

#### 6.8.5. Rollback semantics

R-6.8.6 If async load fails, `current_container` remains unchanged,
state transitions `loading -> failed -> ready`, heartbeat emits
`loading: false` with the OLD `model_id` and OLD `model_hash`, the CLI
receives typed `switch_progress` with `state: "failed"` and REQUIRED
`reason`, and the CLI exits code 5 per SPEC-011 v0.5 R-3.2.6.

#### 6.8.6. Boot path unchanged

R-6.8.7 Startup-time synchronous load (`--model X` at boot) populates
`current_container` once and transitions directly to `ready` without
going through `loading` per SPEC-011 v0.5 R-3.2.7. This preserves
existing boot semantics and L-1 back-compat.

### 6.9. Control socket protocol (NEW in v1.3)

R-6.9.1 (reconciled v1.7) The serve process opens the control socket when
**either** `--enable-warm-swap` (SPEC-011 v0.5 R-3.1.0 / R-3.1.5) **or**
receipt-key rotation is enabled — the latter requires `--enable-receipts` with a
non-empty `provider_id` and a configured coordinator (`MacProviderCLI.swift`:
`enableWarmSwap || receiptRotator != nil`). The ≤ v1.6 "socket absent unless
`--enable-warm-swap`" wording was too narrow: it would make receipt rotation
impossible in receipts-only mode and understates when this same-EUID privileged
surface exists. The socket is absent only when **neither** warm-swap nor receipt
rotation is enabled. (The SPEC-011 warm-swap *frames* remain gated on
`--enable-warm-swap`. Note the detection nuance: the server answers
`status_request` **whenever the socket is open** — including receipts-only mode
(`ControlSocket.swift`), so `models list` against a receipts-only socket gets a
`status_response` and treats the socket as *present and responsive*, **not** the
§6.9.3 case-3 "warm-swap not enabled" path. There is in fact **no
machine-distinguishable "warm-swap disabled" result** on a receipts-only socket:
a `switch_request` is rejected with a **generic** error (`ControlSocket.swift`
returns `.other`; `models` prints only "switch rejected", `ModelsSubcommand.swift`),
which an operator *interprets* as warm-swap-not-enabled but which is not a
distinct status code. The `status_request` probe never surfaces it at all.)

The macOS-native default path is `$TMPDIR/macprovider-cli/ctl.sock`,
resolved via `FileManager.default.temporaryDirectory`, per SPEC-011
v0.5 R-3.1.5. Why not `$XDG_RUNTIME_DIR`: that variable is a Linux /
freedesktop convention and is not set on stock macOS; SPEC-011 v0.5
R-3.1.5 records the empirical platform check.

#### 6.9.1. Wire format

R-6.9.2 The control socket protocol is newline-delimited JSON and every
frame MUST include a REQUIRED `type` field per SPEC-011 v0.5 R-3.1.5.
Messages with missing or unknown `type` MUST be discarded, and the
receiver MUST close the connection with an error log line per SPEC-011
v0.5 R-3.1.5.

The SPEC-011 v0.5 R-3.1.5 field reference table is incorporated here:
`type`, `target_model_id`, `requested_at_ms`, `accepted`, `reason`,
`current_target`, `seconds_remaining`, `state`, `elapsed_ms`,
`current_model_id`, and `runtime_state` retain the requiredness and
enum constraints from SPEC-011 v0.5 R-3.1.5.

#### 6.9.2. Frame types

R-6.9.3 The binary MUST implement the SPEC-011 v0.5 R-3.1.5 frame
schemas for `switch_request`, `status_request`, `switch_ack`,
`switch_progress`, and `status_response`.

R-6.9.4 `switch_ack` frames MUST include the REQUIRED `type:
"switch_ack"` field and the REQUIRED `accepted` field per SPEC-011
v0.5 R-3.1.5 and R-3.7.3.

R-6.9.3a **Full frame inventory (reconciled v1.7).** SPEC-001 owns the
control-socket **transport** (§6.9.1 wire format, §6.9.4 permissions/
lifecycle); the `ControlSocketFrame` enum shipped in the binary
(`ControlSocket.swift`) carries **15** frame `type`s. The five above are the
SPEC-011 warm-swap set; the remaining ten were added by later specs and
their **semantics are owned by those specs** — SPEC-001 enumerates them here
for transport completeness but does not re-specify their behavior (the
cross-referenced spec governs on any conflict). A binary MUST accept/emit
only these `type`s and MUST reject unknown types per §6.9.1.

| `type` | Direction (app↔serve) | Owner spec | SPEC-001 §6.9 |
|---|---|---|---|
| `switch_request` | app → serve | SPEC-011 v0.5 | specced |
| `status_request` | app → serve | SPEC-011 v0.5 | specced |
| `switch_ack` | serve → app | SPEC-011 v0.5 | specced |
| `switch_progress` | serve → app | SPEC-011 v0.5 | specced |
| `status_response` | serve → app | SPEC-011 v0.5 | specced |
| `rotate_receipt_key_request` | app → serve | **SPEC-015** (receipt-key rotation); field `provider_id` | schema here (see note) |
| `rotate_receipt_key_result` | serve → app | **SPEC-015**; fields `status` (`accepted`/`rejected`/`committed_unconfirmed`), `accepted` (bool = `status==accepted`), conditional `error` | schema here (see note) |
| `metrics_request` | app → serve | **SPEC-025 §5.2** (App track) | transport only |
| `metrics_response` | serve → app | **SPEC-025 §5.2** (carries `ControlMetricsSnapshot`) | transport only |
| `pause_request` | app → serve | **SPEC-025** | transport only |
| `pause_ack` | serve → app | **SPEC-025** | transport only |
| `resume_request` | app → serve | **SPEC-025** | transport only |
| `resume_ack` | serve → app | **SPEC-025** | transport only |
| `shutdown_request` | app → serve | **SPEC-025** (carries `grace_seconds`) | transport only |
| `shutdown_ack` | serve → app | **SPEC-025** | transport only |

The receipt-key-rotation and App-track metrics/pause/resume/shutdown frames are the
App-track control surface (SPEC-015 / SPEC-025). Admission identity signing is not a
local-control operation: `macprovider-cli` owns the durable admission key and signs
the coordinator proof directly (SPEC-026 §4.3). None of these ten alter the §6.9.3
`models`-CLI detection precedence, which keys only on `status_response`.

**Peer authentication is EUID-only.** The control socket authenticates its peer
by matching effective UID (`ControlSocket.swift`), **not** by verifying it is
Malibu.app; any same-EUID local process can connect and may initiate receipt
rotation. Admission proofs and admission-key material never traverse this socket.
Hardening the receipt-rotation peer check is a carried follow-up.

**Receipt-rotation frame schema owner.** SPEC-015 §7.5 defines reconnect/Keychain
rotation semantics but **not** the local `rotate_receipt_key_*` request/result
wire schema, and SPEC-025 only names the pair; neither is sufficient for an
independent compatible implementation. SPEC-001 therefore carries the concrete
schema inline (request `provider_id`; result `status` ∈
{`accepted`,`rejected`,`committed_unconfirmed`}, `accepted` bool, conditional
`error`) as the transport owner of last resort until a downstream spec fully
specifies it.

**App-track frame schemas (SPEC-025) — carried here.** SPEC-025 §5.2 gives only
abbreviated signatures for the App-track control frames; the shipped
`ControlSocketFrame` codec (`ControlSocket.swift`) is the concrete schema, carried
here as owner of last resort:

- `metrics_request` — `{type}` (no payload).
- `metrics_response` — `{type}` plus these members (types from
  `ControlMetricsSnapshot.swift`; the decoder coerces via `NSNumber`, so integer
  fields tolerate fractional/boolean JSON with truncation rather than strictly
  rejecting): REQUIRED
  `earnings_usdc` (number/Double), `malibu_accrued` (number/Double),
  `uptime_sec` (int); OPTIONAL (omitted when nil) `gpu_c` (number/Double),
  `latency_p50_ms` (int), `requests_served_today` (int),
  `requests_served_all_time` (int), `requests_per_minute` (number/Double),
  `input_tokens_today` (int64), `output_tokens_today` (int64),
  `input_tokens_all_time` (int64), `output_tokens_all_time` (int64),
  `queue_depth` (int).
- `pause_request` / `resume_request` — `{type}` (no payload).
- `pause_ack` / `resume_ack` — `{type, accepted: bool}` plus optional
  `reason` (string).
- `shutdown_request` — `{type, grace_seconds: int}`; `shutdown_ack` — `{type}`.

#### 6.9.3. Detection precedence

R-6.9.5 The `models` CLI MUST use the SPEC-011 v0.5 R-3.1.5.x
three-case detection precedence: ENOENT exits 4 with
`"malibu-cli serve is not running on this host (no control socket
at <socket_path>)"`; ECONNREFUSED exits 4 with `"stale control socket
at <socket_path> (no listener); remove the file and restart serve"`;
connect-success plus missing `status_response` within 2s exits 4 with
`"serve is running but warm-swap is not enabled (or serve is
unresponsive); restart serve with --enable-warm-swap"`.

#### 6.9.4. Permissions and lifecycle

R-6.9.6 Socket parent directory mode MUST be `0700` and socket mode
MUST be `0600`; the socket opens on `serve` startup when `--enable-warm-swap`
**or** receipt rotation is enabled (R-6.9.1 reconciled v1.7) and closes on
`serve` shutdown per SPEC-011 v0.5 R-3.1.5. Stale-socket reclaim after
ECONNREFUSED requires operator removal of the socket file before restart per
SPEC-011 v0.5 R-3.1.5.x case 2. **Implementation note (v1.7):** the shipped
server sets these modes with `chmod` but does **not** check the return value —
it proceeds to listen even if `chmod` fails (`ControlSocket.swift`); the
independent EUID peer check (§6.9.2) is the load-bearing access control, with the
`0700`/`0600` modes as defense-in-depth.

### 6.10. Heartbeat extension (NEW in v1.3, additive when warm-swap opt-in is enabled)

§6.10 specifies what the BINARY emits. COORDINATOR-side handling,
including the hash-clearing REPLACEMENT for `ApplyHeartbeat` at
`phase4-coordinator/internal/pool/provider.go:411-432`, is covered by
the SPEC-002 v1.3.5 candidate per SPEC-011 v0.5 §6.2 and is NOT in
scope for SPEC-001 v1.3.

#### 6.10.1. Opt-in gating

R-6.10.1 The `model_hash` and `loading` heartbeat fields MUST be
emitted by the binary ONLY when `--enable-warm-swap` is enabled (per
R-3.1.0 of SPEC-011 v0.5); in disabled mode, both fields MUST be omitted
from the wire entirely per SPEC-011 v0.5 R-3.3.0. This preserves L-1
byte-identical default.

#### 6.10.2. Field definitions

R-6.10.2 `model_hash` MUST be a raw 64-character lowercase hex string
matching the output of `modelWeightArtifactManifestHash()` at
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:294-325`
(which formats the SHA-256 of the artifact manifest via the
`hexString()` byte→hex helper at
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:340`) per
SPEC-011 v0.5 R-3.3.1.

R-6.10.3 `loading: bool` MUST reflect the §6.8 state machine:
`true` in `loading` or `draining`, `false` in `ready`, per SPEC-011
v0.5 R-3.3.3 and R-3.2.3.

#### 6.10.3. Emission cadence

R-6.10.4 Heartbeat MUST continue at the SPEC-002 §7.1 negotiated
cadence throughout all state-machine states per SPEC-011 v0.5 R-3.2.5.
The `loading: true` transition is communicated by the first heartbeat
after state enters `loading`; the new `model_hash` is communicated by
the first heartbeat after atomic swap into `ready` per SPEC-011 v0.5
R-3.2.4 step 4.

#### 6.10.4. Hash source-of-truth on reconnect (WS drop)

R-6.10.5 (scope reconciled v1.7) After a WS drop mid-swap **in legacy
HTTP-forwarding mode**, the binary reconnects via legacy `hello` per SPEC-011
v0.5 §3.8 and R-3.8.3, and the `hello.model_hash` field MUST carry the hash of
the container currently referenced by `current_container` at reconnect time, not
the in-progress load target. (A WS-tunneled / credential-bootstrap connection
re-runs the v2 handshake on reconnect instead — R-6.7.9 — and communicates the
same `model_hash` continuity via the post-reconnect heartbeat, not a `hello`.)
If the swap was mid-`loading` when the WS dropped, the load continues
independently of the WS; on reconnect `hello.model_hash` is the OLD
hash, and the next post-reconnect heartbeat carries the new hash once
the swap completes per SPEC-011 v0.5 R-3.8.3.

### 6.11. Concurrent switch + WS drop policies (NEW in v1.3)

#### 6.11.1. Concurrent operator-pushed switch

R-6.11.1 If `models switch <Y>` arrives while a prior `models switch
<X>` is still in `loading` or `draining`, the serve process MUST reply
with typed `switch_ack` `{type: "switch_ack", accepted: false, reason:
"loading_in_progress", current_target: "X"}` per SPEC-011 v0.5 R-3.7.1.
The CLI MUST exit code 3 per SPEC-011 v0.5 R-3.1.2.

R-6.11.2 The serve process MUST NOT queue the second switch per
SPEC-011 v0.5 R-3.7.2.

#### 6.11.2. WS drop mid-load

R-6.11.3 WS drop MUST NOT abort an in-flight load; the in-process state
machine continues independently of WS connectivity per SPEC-011 v0.5
R-3.8.1 and R-3.8.5.

R-6.11.4 (scope reconciled v1.7) **In legacy HTTP-forwarding mode**, reconnect
uses legacy `hello` per SPEC-011 v0.5 R-3.8.3, not v2 `auth_request`, carrying
the same `provider_id` identity and the OLD `model_hash` while the load remains
in progress, using the §6.10.4 source-of-truth rule per SPEC-011 v0.5 R-3.8.3. A
**WS-tunneled or credential-bootstrap** connection instead re-runs the full v2
`auth_request` handshake on reconnect (R-6.7.9 / R-6.10.5) and carries the same
`model_hash` continuity on its post-reconnect heartbeat rather than via `hello`.

#### 6.11.3. Cooldown soft guard

R-6.11.5 The CLI tracks last-switch timestamp at the macOS-native state
file path defined by §6.2 `--switch-state-path`; default cooldown window
is 10s. v1.3 stated that `--force` suppresses ONLY this soft guard;
v1.4 §6.13 extends `--force` to also bypass the new fit guard.
SPEC-011 v0.5 R-3.1.4 and R-3.1.3 references are unchanged at the
SPEC-011 layer.

---

### 6.12. Ownership server-pushed frames (NEW in v1.5)

SPEC-001 v1.5 defines two coordinator-to-provider ownership frames on
the existing server-push WebSocket channel used by §6.5 coordinator
commands and status coordination. `ownership_event` reports a concrete
ownership metadata change. `ownership_status` reports current ownership
status hints that do not themselves represent a completed ownership
change.

#### 6.12.1. `ownership_event`

`ownership_event` is a coordinator-to-provider frame on the existing
server-push WebSocket channel used by §6.5 coordinator commands and
status coordination. It notifies a connected binary that ownership
metadata for its `provider_id` changed in the coordinator.

```json
{
  "type": "ownership_event",
  "provider_id": "p_01HK4Z3VYE...",
  "github_login": "octocat",
  "event": "bound"
}
```

| Field | JSON type | Required | Description |
|---|---|---|---|
| `type` | string | Yes | Exactly `"ownership_event"`. |
| `provider_id` | string | Yes | Provider identifier whose ownership metadata changed. |
| `github_login` | string | Yes | GitHub login associated with the ownership change. |
| `event` | string | Yes | `"bound"` or `"unbound"`. |

`event: "bound"` is the v1.5 value consumed by the current downstream
GitHub-auth flow. `event: "unbound"` is reserved for a post-v1.5
operator-unlink flow; v1.5 binaries that receive `"unbound"` SHOULD log
the event and otherwise ignore it unless a later spec defines local
cleanup behavior. The coordinator-side conditions for emitting each
variant are defined by SPEC-003 v0.10 FR-C10; SPEC-001 v1.5 defines the
frame shape only.

Forward compatibility: a pre-v1.5 binary that does not decode
`ownership_event` SHOULD handle it as an unknown coordinator message
using the existing §6.5 `nak code=unknown_message_type` extensibility
path while continuing to heartbeat and serve traffic.

#### 6.12.2. `ownership_status`

`ownership_status` is a coordinator-to-provider status frame for
ownership-related hints that are not ownership changes. It carries the
`needs_claim` signal defined in §6.5.2.

```json
{
  "type": "ownership_status",
  "provider_id": "p_01HK4Z3VYE...",
  "needs_claim": true
}
```

| Field | JSON type | Required | Description |
|---|---|---|---|
| `type` | string | Yes | Exactly `"ownership_status"`. |
| `provider_id` | string | Yes | Provider identifier whose ownership status is described. |
| `needs_claim` | boolean | No | Optional claim-needed hint. Absent means `false`; see §6.5.2. |

`ownership_status` MUST NOT carry `github_login` because it does not
assert a GitHub owner. The coordinator-side conditions for emitting this
frame are defined by SPEC-003 v0.10 FR-C10; SPEC-001 v1.5 defines the
frame shape only.

Forward compatibility: a pre-v1.5 binary that does not decode
`ownership_status` SHOULD handle it as an unknown coordinator message
using the existing §6.5 `nak code=unknown_message_type` extensibility
path while continuing to heartbeat and serve traffic.

### 6.13. `models switch` RAM fit guard (NEW in v1.4)

**R-6.13.1 Verdict tiers.** Before the CLI sends `switch_request` over
the control socket, it MUST evaluate the local fit verdict for the
target model id against the host's physical RAM (via Foundation's
`ProcessInfo.physicalMemory`, rounded up to whole GB). Weights are
estimated from the model id using the same name-parsing rules as the
installer (SPEC-003 v0.9 FR-D2.1 step 4): a "NxMB" Mixture-of-Experts
prefix takes precedence over a plain `[0-9]+(\.[0-9]+)?B` suffix; the
quantization byte cost is inferred from `4bit|q4` (0.5 B/param),
`8bit|q8` (1.0), `bf16|fp16|-f16` (2.0), or 2.0 as the unknown-quant
fallback.

The verdict has four cases:

| Verdict | Condition | Default action without `--force` |
|---|---|---|
| `.fits` | `ramGB >= estGB + 6` | silent, proceed |
| `.tight` | `ramGB >= estGB + 2` and not `.fits` | stderr warning, proceed |
| `.wontFit` | otherwise | stderr error, `ExitCode(2)`, do not proceed |
| `.unknown` | model id name cannot be parsed | see R-6.13.3 |

The headroom constants 6 GB (comfortable) and 2 GB (tight) MUST equal
the SPEC-003 v0.9 FR-D2.1 step 4 constants. Drift between the two
surfaces is a SPEC violation.

**R-6.13.2 `--force` override.** When `--force` is set, `.wontFit`
MUST log a one-line warning to stderr and proceed; `.tight` MUST be
silent (consistent with `--force` meaning "I know what I'm doing,
don't shout"); `.fits` is silent as before.

**R-6.13.3 `.unknown` fail-closed for HF-shape ids.** When the parser
cannot extract a size from the target id, the binary MUST inspect the
id shape:
- If the id contains `/` and does not start with `.` or `/` (i.e. it
  looks like a HuggingFace `org/name` reference), `.unknown` MUST
  fail closed with `ExitCode(2)` unless `--force` is set. This blocks
  malicious or oddly-named oversized HF repos from bypassing the
  guard silently.
- Otherwise (synthetic test IDs, local paths starting with `./` or
  `/`, single-segment names), `.unknown` MUST log a one-line note
  ("skipping fit check") and proceed.

**R-6.13.4 Ordering.** The fit guard MUST run AFTER
`SupportedModels.validate` (so an out-of-catalog id is rejected with
the catalog error, not a fit error) and BEFORE the cooldown soft
guard (so a `.wontFit` fails before we burn the cooldown window).

**R-6.13.5 Output discipline.** All fit-guard messages MUST go to
stderr. Stdout of `models switch` is reserved for the existing
control-socket progress lines per §6.9.

---

### 6.14. `models browse` subcommand (NEW in v1.4)

**R-6.14.1 Action.** `malibu-cli models browse` performs an
unauthenticated GET against the HuggingFace API at
`https://huggingface.co/api/models` with the following query params:

- `author=mlx-community` (fixed in v1.4; future revisions MAY add
  `--author` and `--all-authors` flags per the SPEC-001 v1.4 change
  log architect MAJOR-1 forward-looking note)
- `sort=downloads`
- `direction=-1`
- `limit=<--limit>`
- `search=<--family>` (omitted if `--family` is unset)

**R-6.14.2 Flags.**

| Flag | Type | Default | Constraint |
|---|---|---|---|
| `--family` | string | unset | substring search, passed verbatim |
| `--limit` | int | 30 | `1 <= N <= 200`; violations exit code 2 |
| `--fits-only` | flag | off | drop rows where verdict is not `.fits` |
| `--max-gb` | int | unset | when set, MUST be `> 0`; drops rows whose estimated GB exceeds the cap |

**R-6.14.3 Authentication.** If the `HF_TOKEN` environment variable
is set and non-empty, the request MUST carry
`Authorization: Bearer <HF_TOKEN>`. The underlying `URLSession` MUST
refuse cross-origin redirects (different scheme or host than the
original request) to prevent the bearer header from leaking on an
HF or edge 3xx to an attacker-controlled origin.

**R-6.14.4 Status code routing.** Response status is routed as:

| Status | CLI behavior |
|---|---|
| 200 | parse JSON, annotate with fit verdict, render |
| 401, 403 | exit code 4, stderr advises setting `HF_TOKEN` |
| 429 | exit code 4, stderr advises retry-after-a-minute |
| other | exit code 4 with the numeric status |
| network error (DNS / TLS / offline / timeout) | exit code 4, one-line `localizedDescription` |

**R-6.14.5 Resource limits.** The CLI MUST set a request timeout
(default 15 s) and resource timeout (default 30 s) on the
`URLSession` configuration. v1.4 hardcodes both; future revisions
MAY expose them as flags.

**R-6.14.6 Output.** Stdout receives a tab-separated table with
columns `model_id`, `est_gb`, `fit`. The `fit` column is one of the
stable strings `fits`, `tight`, `wont_fit`, or `unknown`. Stderr
receives a one-line summary (`N models on a M GB Mac` or
`no models match the current filters on a M GB Mac`).

**R-6.14.7 Output sanitization.** HF-returned ids are user content
(anyone can publish to HuggingFace). Before rendering, the CLI MUST
replace U+0000–U+001F and U+007F in the id with U+FFFD so a
malicious model name cannot break the TSV layout (embedded tab or
newline) or paint terminal escape sequences. Characters at U+0080 and
above MUST pass through unchanged.

**R-6.14.8 Module placement.** v1.4 places the `HFClient` and
`ModelFit` types in the existing `MacProviderCore` library next to
`SupportedModels`. A future revision SHOULD extract these into a
`MacProviderModelCatalog` target once the next consumer set lands —
expected drivers include download-at-switch with byte-accurate
sizing (via `/api/models/<id>` per-id metadata), multi-model
`supported_models` mutation, and a gated-repo flow via `HF_TOKEN`
at switch time. The catalog target is named here so reviewers of
future PRs can refer to a stable concept, but the boundary is not
yet enforced at the package level.

### 6.14a. Model command taxonomy and legacy JSON compatibility oracle (BYOM preflight)

SPEC-001 owns the provider CLI command taxonomy and the legacy Malibu
model-management compatibility surface. SPEC-046 and SPEC-047 may reserve new
BYOM behavior, but they MUST NOT silently redefine these live commands,
capabilities, manifest tokens, or fallback assumptions.

For compatibility with shipped CLI/Malibu model management, the accepted
compatibility oracle is:

- `specs/design/BUILD_SPEC_953_MALIBU_MODEL_SWITCHING.md` sections
  BS953-DC001A through BS953-DC001C for the legacy JSON command envelopes.
- The checked-in Swift CLI wire tests for `models_list.v1`,
  `models_browse.v1`, `model_catalog_error.v1`, `model_switch_event.v1`, and
  `model_adoption_event.v1`.
- The checked-in Malibu capability manifest for `model_catalog_json_v1` and
  the command-schema tokens `models list.v1`, `models browse.v1`,
  `model_catalog_error.v1`, `models switch.v1`, and
  `models adopt-recommendation.v1`.
- The BYOM contract-lock regression test that asserts the exact strings above
  remain present before `models discover`, `models evaluate`, `models offer`,
  or `models admission` ships provider-visible behavior.

The exact v1 taxonomy is:

| Command | Authority | Output / behavior boundary |
|---|---|---|
| `models list` | SPEC-001 plus BUILD_SPEC_953 BS953-DC001B | Current MacProvider runtime / installed serving model management. `--json` emits `schema_version: "models_list.v1"` under capability `model_catalog_json_v1`. Rows may carry an `action_model_id` only when the model is a real CLI action target. |
| `models switch` | SPEC-001 plus BUILD_SPEC_953 BS953-DC001B / BS953-R014 | Launchd-managed switch of the installed serving model with CLI-owned RAM/cooldown preflight. `--json` emits `schema_version: "model_switch_event.v1"` under capability tier `model_ready_switch_v1` (command-schema token `models switch.v1`). A live runtime-mutation command; SPEC-046/047 MUST NOT redefine it or reuse its schema token for BYOM discovery/admission. |
| `models adopt-recommendation` | SPEC-001 plus BUILD_SPEC_953 BS953-R015 | One-tap adoption of a signed autotune recommendation into a launchd-managed switch transaction. `--json` emits `schema_version: "model_adoption_event.v1"` under capability tier `model_recommendation_apply_switch_v1` (command-schema token `models adopt-recommendation.v1`). A live runtime-mutation command; SPEC-046/047 MUST NOT redefine it or reuse its schema token for BYOM discovery/admission. |
| `models browse` | SPEC-001 plus BUILD_SPEC_953 BS953-DC001C | Signed MacProvider/HuggingFace MLX catalog browsing and fit annotation. `--json` emits `schema_version: "models_browse.v1"` under capability `model_catalog_json_v1`. Browse rows are advisory and MUST keep `action_model_id: null` and `actionable: false`. |
| `models discover` | SPEC-046 | Provider-local BYOM inventory across supported adapters. JSON MUST use `schema: "provider_byom_discovery.v1"` and MUST NOT be decoded as `models_browse.v1` or as a signed catalog row. |
| `models evaluate` | SPEC-046 | Bounded local evaluation for a discovered candidate. JSON MUST use the SPEC-046 evaluation envelope and MUST NOT mutate production serving config or coordinator state. |
| `models offer --dry-run` | SPEC-047 | Local/coordinator preflight explanation without submitting state. JSON MUST use `schema: "model_admission_offer_dry_run.v1"`. |
| `models offer` | SPEC-047 | Provider-signed offer submission to the coordinator. Submission authority requires SPEC-047 signing, replay, privacy, and state-machine checks. |
| `models admission status` | SPEC-047 | Coordinator-backed admission readback. JSON MUST use `schema: "model_admission_status.v1"` and consume, not infer, coordinator admission state. |
| `models admission withdraw` | SPEC-047 | Provider-initiated withdrawal of a previously offered or admitted candidate. JSON MUST use `schema: "model_admission_withdraw.v1"` and append a SPEC-047 withdrawal event without deleting local artifacts. |

**Earning-verdict-first human output (BYOM provider surface).** For the
BYOM commands `models discover`, `models evaluate`, `models offer` (including
`--dry-run`), and `models admission status`, the provider-facing human
(non-`--json`) rendering of each candidate MUST lead with exactly one plain
earning-verdict line, deterministically mapped from the
`provider_guidance.earning_path_class` of that candidate, before any
machine-state, capability, or price detail. The `provider_guidance` object
shape and its closed `earning_path_class` enum are defined by SPEC-046-R003 and
carried through the SPEC-047-R002 offer/status envelopes; `models discover` and
`models evaluate` MUST render the verdict from that same `earning_path_class`
(for a purely local candidate that is `local_inventory_only`) and MUST NOT defer
the verdict line until admission or dry-run logic exists:

- `settlement_capable` -> **"Earning now"**.
- `not_earning_yet_catalog_or_receipt_path_exists` -> **"Not earning yet — "**
  followed by the single concrete next action from
  `provider_guidance.next_action`.
- `no_earning_path_in_v0_1` -> **"Can't earn in this release"**.
- `local_inventory_only` -> **"Local only — not offered to the network"**.

The verdict line is a v0.1 slice-1 contract requirement, not a later Malibu
surface concern; the 13 machine admission states remain in `--json` unchanged.
Provider-facing human output MUST NOT imply earning from a candidate whose
`earning_path_class` is `no_earning_path_in_v0_1` or `local_inventory_only`,
consistent with SPEC-047-R004. Malibu and the CLI human surface MUST source the
verdict from `earning_path_class`; they MUST NOT re-derive an earning claim from
runtime-reported model names, provider-proposed prices, or admission state alone.

Malibu MUST continue to treat absence of `model_catalog_json_v1`, malformed
legacy envelopes, missing command-schema manifest tokens, or stale local-status
capabilities as a fallback condition for the legacy static/current-model UI.
Malibu MUST NOT inspect local runtime files, model caches, or BYOM adapter
endpoints directly to bridge a missing CLI capability.

New provider-visible model-command PRs MUST include tests proving that:

- `models list` and `models browse` keep their existing JSON schema values,
  manifest tokens, and non-actionability/actionability boundaries.
- Browse/catalog rows cannot be confused with SPEC-046 BYOM candidates.
- `provider_byom_discovery.v1`, `model_admission_offer_dry_run.v1`,
  `model_admission_status.v1`, and `model_admission_withdraw.v1` remain
  separate schema values owned by their respective specs.
- Old Malibu/current-model fallback behavior remains available when capability
  negotiation does not prove the exact required tier.

### 6.15. Additive coordinator-wire surface reconciled in v1.7 and extended in v1.8

Between SPEC-001 v1.6 (2026-06-22) and the current binary (`binary_version`
1.8.32) the coordinator↔binary wire gained fields and frames that later specs
own but that transit the SPEC-001 binary. SPEC-001 enumerates them here for
wire completeness; **the cross-referenced spec owns the semantics** and governs
on any conflict. All are additive — a coordinator that ignores an unknown field
sees pre-v1.7 behavior. (This section is §6.15 — it follows the existing §6.12
"Ownership server-pushed frames", §6.13, and §6.14; the earlier v1.7 draft
mis-numbered it §6.12 and collided with the ownership section.)

#### 6.15.1. `auth_request` fields (beyond §6.7.1)

Builder: `CoordinatorClient.swift` (`authInitialMessage` for the initial stage,
plus `appendCatalogAdmissionMetadata`).

Initial-stage fields:

- `tier2_capabilities.response_chunk_plaintext_envelope: true` — a 4th sub-field
  beyond the §6.7.1 `{encrypted_leg, attestation, aead_suites}` schema. SPEC-008
  defines only the first three capability fields, so SPEC-001 carries this one as
  transport owner of last resort (schema below).
- `tier2_capabilities.in_band_aead_rekey_v1: true` — provider support for the
  single-WebSocket four-frame fresh-epoch handoff in SPEC-008 v0.5 §6.9. The
  coordinator confirms selection at
  `tier2_session.encrypted_leg.in_band_aead_rekey_v1: true`; the binary MUST
  accept rekey frames only after that confirmation.
- `credential_bootstrap: true` — provider opt-in to the provisional
  credential-bootstrap / TOFU token-mint path (**SPEC-003** open onboarding,
  FR-C9 / `allow_tokenless_provisional_bootstrap`). SPEC-026 §4.3 does **not**
  define this flag — it owns only the identity-signature binding it pairs with.
- `referral_code: <string>` — OPTIONAL untrusted admission input from the
  CLI-owned onboarding journal. It MUST be omitted outside a referral attempt,
  bounded to the SPEC-034 code limit, and redacted from logs. Its presence never
  grants admission by itself.
- Signed-catalog admission block: `catalog_release_id`, `catalog_policy_version`,
  `catalog_candidate_sha256`, `catalog_signer_key_id`, `catalog_row_identity`
  (**SPEC-010 / SPEC-022** signed-catalog admission). This block is **also**
  appended to the legacy `hello` frame (`CoordinatorClient.swift`), not only to
  the initial-stage `auth_request`. Neither SPEC-010 (which leaves catalog
  *signing* out of scope) nor SPEC-022 (which delegates hash authority to
  SPEC-008) defines this block's wire schema, so SPEC-001 carries it (schema below).

**`response_chunk_plaintext_envelope` — schema carried here (SPEC-008 owns only
the capability bit).** The provider advertises the capability `true` in the
initial-stage `tier2_capabilities`. The coordinator confirms it in the
**auth-response** at `tier2_session.encrypted_leg.response_chunk_plaintext_envelope:
true` (`CoordinatorClient.swift`). When confirmed, each encrypted
`inference_response_chunk` wraps its plaintext in an inner JSON envelope
**before** AEAD sealing: `{ "type": "inference_response_chunk_plaintext", "seq":
<int>, "data": <string> }` (serialized with Foundation `JSONSerialization`
`.sortedKeys` — lexicographic key ordering, **not** full RFC 8785 JCS —
`Tier2ProviderSession.swift`); when
not confirmed, the sealed plaintext is the raw UTF-8 string with no envelope.

**Signed-catalog admission block — schema carried here.** Five **independent
optional strings** (`catalog_release_id`, `catalog_policy_version`,
`catalog_candidate_sha256`, `catalog_signer_key_id`, `catalog_row_identity`;
`CoordinatorClient.swift`). None is individually required; the provider emits any
partial subset that is populated, subject to model-match and
catalog-invalidation guards (a field is dropped if its catalog admission was
invalidated). A coordinator MUST treat each field as independently optional.

Proof-stage `auth_request` (the second handshake message) can additionally
carry `credential_bootstrap` and the same `referral_code` (**SPEC-003**
FR-C9/FR-C9.7), `identity_signature`, and
`identity_signature_transcript_sha256` (**SPEC-026 §4.3** identity binding;
`CoordinatorClient.swift`).

#### 6.15.2. Heartbeat fields (beyond §6.5 / §6.10)

Builder: `CoordinatorClient.swift` heartbeat frame.

- `hardware_summary` — optional provider-reported hardware descriptor consumed
  as a **display-capacity fallback** through the **SPEC-017** stats-rollup
  pipeline; it is **untrusted** and verified `chip_hardware_profiles` inventory
  overrides it (`beta/DECISION_CRITERIA.md` Entry 105/109). It is explicitly
  **not** a trusted capacity source and cannot confer attestation. SPEC-017
  defines the *aggregate stats output* fields, not this provider-heartbeat
  *input* object, so SPEC-001 carries its wire sub-schema (owner of last resort,
  `ProviderHardwareSummary.swift`): an object of up to five optional members —
  `chip` (string), `bandwidth_gb_per_s` (number), `network_power_kw` (number),
  `gpu_cores_total` (int), `cpu_cores_total` (int); each member is omitted when
  zero/empty (and `chip` is additionally omitted when it is the literal
  `"unknown"`), and the whole object is omitted if all are absent.
- All six speculative-decoding fields (**SPEC-028**): `spec_decode_enabled`,
  `spec_decode_draft_model_id`, `spec_decode_num_draft_tokens`,
  `spec_decode_drafted_tokens_since_last`, `spec_decode_accepted_tokens_since_last`,
  `spec_decode_acceptance_rate`.
- `last_autoupdate_event` — last auto-update transition. This is a **SPEC-001
  wire-schema extension** (SPEC-020 R-6.3 consumes it) emitted on **both** the
  heartbeat **and** `state_update` payloads (`CoordinatorClient.swift`); the
  value is a structured object ≤4096 UTF-8 bytes.

These are additive to the §6.10 opt-in-gated `model_hash` / `loading` fields.
**Correction (v1.7):** unlike the §6.10 warm-swap fields, several of these ride
the heartbeat **independently of `--enable-warm-swap`** — in particular
`hardware_summary` is built and emitted unconditionally
(`CoordinatorClient.swift`; the warm-swap-*disabled* test explicitly expects it,
`CoordinatorClientTests.swift`). So the §6.10 "L-1 byte-identical heartbeat when
warm-swap is disabled" invariant does **not** hold once these v1.7 fields are
present; the byte-identical claim is scoped to the SPEC-011 `model_hash` /
`loading` additions only, not to `hardware_summary` / spec-decode /
`last_autoupdate_event`.

#### 6.15.3. New inbound (coordinator server-push) frames

Dispatch: `CoordinatorClient.swift`. The dispatcher recognizes the documented
frame set and otherwise replies `nak unknown_message_type`.

- `se_liveness_challenge` → binary replies `se_liveness_response` (§6.15.4) —
  Secure-Enclave liveness challenge (**SPEC-008 Pillar C**). This is the only new
  inbound *server-push control* frame in v1.7. (The `losslessness_probe_v1.*`
  probe family below is also inbound, but is a distinct request/result protocol
  owned by SPEC-030, not a control-frame push.)
- `aead_rekey_request` → after validating the current assigned ID, old key ID,
  AEAD, expiry, capability selection, and relay-idle boundary, the binary replies
  `aead_rekey_response` with a fresh X25519 public key and derived key ID.
- `aead_rekey_commit` → fresh C→P sequence-0 AEAD proof. The binary validates
  every outer/proof binding, installs that candidate epoch only after the relay
  is idle, and replies `aead_rekey_committed`. Both frames and all failure
  semantics are owned by SPEC-008 v0.5 §6.9.

> **Not wire frames.** `encrypted_leg_invalidated`, `tier_demoted`,
> `token_revoked`, and `attestation_state_degraded` are **not** inbound
> coordinator frames — the earlier v1.7 draft wrongly listed them as such. They
> are internal string labels: `encrypted_leg_invalidated` is produced by a local
> `InferenceRelay` AEAD-failure callback, and the other three are internal
> auto-update / trust demotion *reason* labels (`CoordinatorClient.swift`). A
> coordinator MUST NOT send them as frames; the binary would `nak` them.

These extend the §6.7 / §6.6 inbound frame set (`hello_ack`, `ownership_event`,
`ownership_status`, `preflight`, `inference_request`, `cancel_request`, `drain`,
`warm_up`).

#### 6.15.4. New outbound (binary → coordinator) frames

- `idle_prewarm_event` — the **single** frame type emitted by the `IdlePrewarmer`
  (FR-16). Its `event` field carries the raw transition string forwarded
  unchanged from `IdlePrewarmer`: `idle_prewarm_fired`, `idle_prewarm_completed`,
  `idle_prewarm_failed`, `idle_prewarm_cancelled_by_real_request`, or
  `idle_prewarm_skipped`; a `reason` is attached only on the skipped event. There
  is **no** distinct `idle_prewarm_skipped` frame type, and one prewarm run emits
  *multiple* lifecycle frames (e.g. `idle_prewarm_fired` then
  `idle_prewarm_completed`). Owner: SPEC-001 (FR-16) — this frame is SPEC-001's
  own, new in v1.7.
- `se_liveness_response` — reply to `se_liveness_challenge`; fields `version`,
  `nonce`, `timestamp`, `public_key`, `signature` (**SPEC-008 Pillar C**). Per
  SPEC-008, the coordinator verifies the signature against the stored
  attestation-time key, **not** the response's `public_key`.
- `aead_rekey_response` — reply to `aead_rekey_request`; fields `version`,
  `rekey_id`, `assigned_id`, `old_kid`, `new_kid`, and
  `provider_ecdh_public_key`.
- `aead_rekey_committed` — fresh P→C sequence-0 AEAD proof echo after local
  epoch installation; its clear binding carries `version`, `rekey_id`,
  `assigned_id`, `old_kid`, and `new_kid`, plus `encrypted:true` and `enc`.
  SPEC-008 v0.5 §6.9 owns both outbound frames.

**Losslessness-probe frames (SPEC-030).** The binary also handles a
`losslessness_probe_v1.*` family (`LosslessnessProbeProtocol.swift`). The
**top-level dispatched** wire types are: inbound `losslessness_probe_v1.request`
and `losslessness_probe_v1.encrypted_request`; outbound
`losslessness_probe_v1.result` and `losslessness_probe_v1.encrypted_result`. The
`.request_plaintext` / `.result_plaintext` variants are **not** top-level frames
— they exist only *inside* the encrypted envelope (`Tier2ProviderSession.swift`)
and are never dispatched directly. Owner: **SPEC-030** (losslessness-probe
protocol / transport; the canonical owner), with SPEC-008 owning the tier-2
verification semantics that consume it; SPEC-001 carries the transit only.

These extend the §6.5 outbound set (`auth_request`, `hello`, `heartbeat`,
`state_update`, `drain_status`, `nak`, `preflight_ack`).

The rekey exchange is control traffic on the existing WebSocket. It does not
retransmit an inference request/response and does not alter §6.6's application
retransmission policy, capacity-1 relay, or request-ID lifecycle.

---

## 7. Dependencies and references

### 7.1. Direct dependencies (use as libraries)

| Dependency | License (SPDX) | Version pin | Purpose |
|---|---|---|---|
| [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-examples) | MIT | Tag `2.29.1`, commit `9bff95ca5f0b9e8c021acc4d71a2bbe4a7441631` (verified 2026-05-27). Build session may bump with documented reason in implementation-notes.html. | MLX model loading and inference |
| [swift-nio](https://github.com/apple/swift-nio) | Apache-2.0 | 2.65.0 (starting pin) | HTTP server and WebSocket client |
| [swift-log](https://github.com/apple/swift-log) | Apache-2.0 | 1.6.0 (starting pin) | Structured logging |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | Apache-2.0 | 1.5.0 (starting pin) | CLI flag parsing |
| [Yams](https://github.com/jpsim/Yams) | MIT | 5.1.0 (starting pin) | YAML config parsing |

**Runtime requirements:** Swift 5.9+, macOS 14+ (Sonoma), Apple Silicon.

Version pins are starting points. The build session may bump versions
after testing, with a documented reason in `implementation-notes.html`.

Provider-authentication **policy and coordinator-side validation** are specified
in SPEC-002 (and SPEC-008 / SPEC-026 for attestation/identity). The binary-side
credential transport and proof generation (bearer token, the mode-selected v2
challenge/proof handshake used in WS-tunneled / credential-bootstrap mode per
R-6.7.8, attestation-token generation) are in scope and shipped — see FR-13,
§6.7, and §6.15 (reconciled v1.7).

### 7.2 Reference hygiene — strict clean-room for d-inference

This binary is built strict clean-room with respect to d-inference.

PROHIBITED references for this spec and the Phase 3 binary build:
- The d-inference GitHub repository (https://github.com/Layr-Labs/d-inference)
- Any d-inference source files, including the README and config files
- Any third-party analyses that quote or reproduce d-inference source
- Reverse-engineered analyses of any compiled Darkbloom binary

Reason: the DARKBLOOM LICENSE AGREEMENT (Eigen Labs, Inc., copyright 2026;
SPDX NOASSERTION; canonical URL https://github.com/Layr-Labs/d-inference/blob/master/LICENSE
as inspected 2026-05-27) explicitly prohibits in Section 3 the use of the
Software to "provide, operate, or enable any hosted service, platform,
marketplace, or product that offers AI inference coordination, private
inference services, or decentralized compute marketplace capabilities
that compete with Darkbloom." Mac Provider fits this description.

PERMITTED references:
- Darkbloom / Eigen Labs published academic papers (cite by URL/DOI)
- Darkbloom blog posts, conference talks, marketing pages (public)
- Third-party reviews that do NOT reproduce d-inference source
- mlx-swift-lm (MIT, Apple/mlx-swift-examples, unrelated to Darkbloom)
- swift-nio, swift-log, swift-argument-parser (Apache 2.0)
- Yams (MIT)
- Apple MLX documentation
- OpenAI API reference (https://platform.openai.com/docs/api-reference)
- HuggingFace tokenizer_config.json schema
- This repository: Phase 1 docs/legacy/phase1/PHASE1_REPORT.md, Phase 2 DECISION_CRITERIA.md,
  harness.py, workloads_adversarial.py

Patent analysis is separate from license. Darkbloom holds patents around
their privacy/attestation model. Tier 1 of this binary does not implement
that model. **Reconciled v1.7:** the original *middleware hooks*
(`TrustGate` / `InputDecryptor` / `ResponseSeal` / `AttestationProvider`) remain
designed-in but unimplemented — however Tier-2 itself is **no longer entirely
future**: a coordinator-wire Tier-2 pipeline owned by **SPEC-008** (v2
`auth_request` `tier2_capabilities`, proof-stage `attestation_token`,
`se_liveness`; §6.15) has shipped in `binary_version` 1.8.31 via a different
mechanism than the middleware hooks. Patent-risk analysis for the SPEC-008
Tier-2 pipeline lives in SPEC-008, not here.

If during implementation you are uncertain how Darkbloom solved a problem,
STOP and add an open question to implementation-notes.html. Do not resolve
it by reading their source.

### 7.3. Public spec sources

- Darkbloom / Eigen Labs published academic papers (cite by URL/DOI)
- [Apple MLX documentation](https://ml-explore.github.io/mlx-swift/latest/)
- [OpenAI API reference](https://platform.openai.com/docs/api-reference/chat)
- [HuggingFace tokenizer_config.json](https://huggingface.co/docs/transformers/main_classes/tokenizer) schema

### 7.4. Internal sources

- Phase 1 evidence: `docs/legacy/phase1/PHASE1_REPORT.md`
- Phase 2 decision log: `beta/DECISION_CRITERIA.md`
- Phase 2 adversarial workloads: `beta/workloads_adversarial.py`
- Phase 2 stop-token derivation: `beta/stop_tokens.py`
- Phase 2 harness: `beta/harness.py`

---

## 8. Phase 1 + 2 findings the binary must encode

This section maps every decision log entry from
`beta/DECISION_CRITERIA.md` to functional requirements.

### Coverage matrix

| Decision log entry | Coverage | FRs | Notes |
|---|---|---|---|
| D1 — 502 vs 530 routing | Fully covered (binary scope) | FR-13, FR-15 | Backoff/tunnel-signal logic is coordinator-side; deferred to SPEC-002 |
| D2 — Post-wake throughput dip | Fully covered | FR-16 | |
| D3 — Stop-token leakage status | Fully covered | FR-6 | Defensive; may be no-op if upstream clean |
| D4 — Cross-provider throughput inversion | Fully covered (binary scope) | FR-17, FR-20 | Buyer-facing model choice is coordinator-side; deferred to SPEC-002 |
| D5 — Timeline compression | Process-only | — | No binary behavior; accelerated Phase 3 timeline by 11 days |

### v1.2.4 audit lesson — advertised vs enforced capability

Advertised provider capability MUST match enforced runtime capability.
Spec values that the code never realizes are a drift class equivalent to
Entry 18's SIGTERM=drain conflation and Entry 19's WithTokenValidator
always-on: both produce silent failures of the form "the system
describes a capability that does not exist in practice." Future spec
revisions documenting capacity MUST cite the code path that realizes
them.

### D1 — 502 vs 530 routing distinction

**Observation:** M4 sleep transition produced two distinct failure modes:
HTTP 502 (Cloudflare tunnel up, mlx_lm.server down, persisted ~14 min)
then HTTP 530 (full tunnel disconnect). Tunnel API `conns_active_at`
lagged actual buyer-visible failure.

**FR mapping:**
- **FR-15** (health state reporting): The binary reports `degraded` vs
  `unavailable` states via `state_update` messages.
- **FR-13** (coordinator WebSocket): Clean WebSocket close protocol
  allows the coordinator to distinguish graceful shutdown from crash.

Backoff behavior (e.g., short 30s retry for degraded providers) and
tunnel-signal monitoring (`cfd_tunnel` connection count) are coordinator
responsibilities, deferred to SPEC-002.

### D2 — Post-wake throughput dip

**Observation:** M4 post-wake first request was -12% throughput vs
baseline. mlx weights survived sleep but first inference was slower.

**FR mapping (reconciled v1.7):**
- **FR-16** (idle prewarmer): the shipped mitigation is an idle-triggered
  `IdlePrewarmer`, **not** wake detection. It runs a synthetic inference after
  an idle period (default ≥ 30s) to keep the model cache warm; it does **not**
  detect wake events and does **not** change the health state. The coordinator
  `warm_up` command is a no-op two-message acknowledgement (§6.5). The ≤ v1.6
  "detects wake events / reports `degraded` during warm-up" contract was never
  shipped.

### D3 — Stop-token leakage status

**Observation:** Day-0 showed 0% stop-token leakage on both Qwen (M4)
and Llama (M1), contradicting Phase 1 which observed leakage on every
short response. Likely upstream `mlx-lm` update fixed stripping.

**FR mapping:**
- **FR-6** (defensive stripping): Still implemented, but no longer
  considered critical-path. The binary reads `tokenizer_config.json`
  and strips defensively. If upstream is clean, the stripping is a no-op
  with negligible cost.

### D4 — Cross-provider throughput inversion

**Observation:** Llama 3B on M1 8GB (22-25 tok/s) outperformed Qwen 7B
on M4 16GB (17-20 tok/s). Even TTFT favored M1 (646 vs 708 ms).

**FR mapping:**
- **FR-17** (capacity includes model + throughput): The capacity
  heartbeat includes `model_params_b` and `throughput_tps_estimate`.
  The coordinator MAY use these to route by actual measured performance.
- **FR-20** (startup self-test): The self-test measures tok/s, which
  becomes the `throughput_tps_estimate` in the capacity advertisement.

Buyer-facing model-size choice or auto-routing by latency/quality
preference is a coordinator responsibility, deferred to SPEC-002.

### D5 — Timeline compression

**Observation:** Day 0 already captured 3 Phase 3 spec changes. 14-day
timeline compressed to 3 days.

**Classification:** Process-only. No binary behavior; this decision
accelerated Phase 3 start by 11 days. Intentionally excluded from FR
mapping per the "every row maps" rule because it has no binary-level
requirement.

### Additional Phase 1 findings (from REPORT.md)

**Metal GPU OOM at ~26K tokens on M1 8GB:**
- **FR-8** (context pre-flight): Tokenize and reject before inference.
- **FR-9** (per-RAM capacity): 8 GB tier capped at 20K tokens.

**SSE keepalive comments (`: keepalive N/M`):**
- **FR-5** (no keepalive comments): Binary generates its own SSE; does
  not proxy `mlx_lm.server`.

**Extra response fields (`system_fingerprint`, `tool_calls`):**
- **FR-2, FR-3**: The binary's responses include only the standard
  OpenAI fields. No extra fields. Clean contract.

**Server stops on client disconnect (BrokenPipeError):**
- **FR-10** (disconnect cleanup): *aspirational* — the 5-second slot release is
  **not shipped** (streaming runs in a detached task with `shouldCancel: false`,
  no channel-close → cancel wiring; see FR-10 reconciled v1.7). Carried
  follow-up, not a current guarantee.

**mlx_lm.server omits usage from SSE streams:**
- **FR-7** (usage synthesis): Binary counts tokens and emits usage chunk.

---

## 9. Acceptance criteria

**AC-1 through AC-10 must ALL pass for the binary to be considered
build-complete. No partial passes. No operator waivers without an
explicit waiver entry in `implementation-notes.html` explaining why.**

**AC-1. Phase 2 cooperative workload parity.**
All 6 cooperative workloads from `beta/workloads.py` (`short_chat`,
`medium_with_system`, `long_context`, `code_completion`, `agent_style`,
`streaming_check`) pass when the Phase 2 harness targets the binary's
HTTP endpoint instead of `mlx_lm.server`. Pass means: HTTP 200,
response content non-empty, throughput within 10% of Phase 2 baseline
for the same model and hardware. Baseline values are in
`beta/DECISION_CRITERIA.md` pre-launch facts table.

**Run by:** `cd beta && python harness.py --config config-phase3-test.yaml --batch cooperative --verbose`
where `config-phase3-test.yaml` points `tunnel_url` at the binary's local endpoint.
The build session creates this fixture file.

**AC-2. Phase 2 adversarial workload survival.**
Each adversarial workload (`retry_storm`, `concurrent_burst_8way`,
`midstream_disconnect`, `malformed_tool_call`, `long_context_oom_probe`)
must complete with NO HTTP 500 responses. Acceptable responses during
adversarial load are: 200 (success), 400 (malformed request),
413 (payload too large). The local HTTP inference path has **no** 429 —
excess concurrent requests block on the FR-11 semaphore rather than being
rejected (the ≤ v1.6 429/queue-full response was never shipped); WS-tunneled
capacity is signalled out-of-band via `error_queue_full` (FR-27), not an HTTP
status. The binary
must remain healthy (passes `GET /v1/health` with 200) within 30
seconds of workload completion. Any 500 response or process crash is
a hard failure of AC-2.

**Run by:** `cd beta && python harness.py --config config-phase3-test.yaml --batch adversarial --verbose`

**AC-3. 24-hour soak test.**
On M4 hardware with a 7B 4-bit model, the binary runs for 24 hours
under continuous load (one request every 5 seconds, mixed workloads).
Criteria: zero crashes, zero process restarts, memory RSS growth <5%
from post-startup baseline, no file descriptor leaks, no degradation
in throughput beyond 5% from hour-1 to hour-24.

**Run by:** `phase3-binary/scripts/soak-test.sh` — created during the
build session. Wraps a long-running harness invocation with a
memory-pressure monitor that samples RSS every 60 seconds.

**AC-4. Harness swap compatibility.**
`beta/harness.py` can be configured (by changing `tunnel_url` in
`config-phase3-test.yaml` to the binary's local endpoint) and run with
`--batch cooperative` with zero test failures. The harness's SSE
parsing, stop-token detection, and response validation all pass
without modification.

**Run by:** Same command as AC-1. AC-4 verifies that the existing
harness code requires zero modifications.

**AC-5. Coordinator mock integration.**
The binary connects to a mock coordinator (a simple WebSocket echo
server that validates JSON message shapes) **in legacy HTTP-forwarding mode**
(the `hello`-handshake mode; a WS-tunneled / credential-bootstrap connection
would instead run the v2 `auth_request` handshake — R-6.7.8) and successfully:
1. Sends a `hello` message with all required fields.
2. Receives a `hello_ack` and honors the `heartbeat_interval_s`.
3. Sends at least 3 capacity heartbeats with all FR-17 fields.
4. Responds to a `preflight` request with a valid `preflight_ack`.
5. Responds to a `drain` command by entering draining state, sending
   `drain_status` messages, and closing the WebSocket.

**Run by:** `phase3-binary/scripts/test-coordinator.sh` — created during
the build session. Spins up a mock WebSocket server that exchanges
handshake, 5 heartbeats, a preflight check, and a drain command.

**AC-6. Graceful SIGTERM drain.**
With 3 in-flight streaming requests, sending SIGTERM causes the binary
to drain all requests to completion within 30 seconds. `drain_status`
messages are logged. Zero mid-stream response truncations. The binary
exits with code 0.

**Run by:** Manual test during build. Start 3 concurrent streaming
requests, send `kill -TERM <pid>`, verify all 3 complete and binary exits 0.

**AC-7. Warm-up command + idle prewarm (reconciled v1.7).**
Two independent checks, since `warm_up` no longer performs inference:
1. **`warm_up` no-op ack.** Sending a `warm_up` command produces exactly the
   `state_update: degraded` → `state_update: ready` pair with no intervening
   synthetic inference and no throughput change attributable to the command.
2. **Idle prewarm.** After an idle period ≥ `idle_prewarm.idle_threshold_seconds`
   (with prewarm enabled, on AC power, model loaded), the binary emits an
   `idle_prewarm_event` (`event: "idle_prewarm_fired"` then
   `"idle_prewarm_completed"`) and the next real
   request shows throughput within 95% of the long-running baseline (tok/s on
   `short_chat`). The prewarmer does **not** move the health state.

**Run by:** (1) Send `warm_up` via mock coordinator; assert the two `state_update`
frames and no inference. (2) Idle the binary past the threshold; assert the
`idle_prewarm_event` frames on the mock coordinator, then fire `short_chat` via
harness and compare tok/s to the AC-1 baseline.

**AC-8. Health endpoint.**
`GET /v1/health` returns 200 with JSON containing at minimum: `status`,
`model`, `uptime_s`, `requests_in_flight`, `requests_queued`,
`capacity.max_concurrency`. Returns 503 with same JSON shape when the
binary is in `degraded` or `unavailable` state.

**Run by:** `curl -s http://localhost:8080/v1/health | python -m json.tool`
during AC-1 run (healthy) and during model-load-failure test (unhealthy).

**AC-9. Config precedence.**
Override `port` at each precedence layer and verify the binary binds
to the correct port: CLI flag beats env var beats config file beats
default.

**Run by:** Manual test during build with 4 invocations.

**AC-10. Startup self-test failure.**
Point the binary at a nonexistent model path. Verify: exits with code 1,
prints diagnostic to stderr, no HTTP server starts, no partial state.

**Run by:** `malibu-cli --model /nonexistent/path 2>&1; echo "exit: $?"`

**AC-11. WS-tunneled inference (non-streaming).**
A mock coordinator sends `inference_request` with `stream: false` over
the WebSocket. The binary processes it through the existing inference
pipeline, returns `inference_response_chunk` with the complete response
and `inference_response_end` with `status: "complete"`.

**Run by:** `phase3-binary/scripts/test-ws-inference.sh`

**AC-12. WS-tunneled inference (streaming).**
A mock coordinator sends `inference_request` with `stream: true`. The
binary returns multiple `inference_response_chunk` messages (one per
SSE event) with monotonically increasing `seq` values, followed by
`inference_response_end`. Time-to-first-chunk is within 100 ms of the
local HTTP streaming baseline.

**Run by:** `phase3-binary/scripts/test-ws-streaming.sh`

**AC-13. Cancellation acknowledgement.**
A mock coordinator sends `inference_request` then `cancel_request`
after 2 chunks are received. The binary aborts inference and sends
`inference_response_end` with `status: "cancelled"` within 5 seconds.
The request slot is freed (verifiable via `/v1/health`).

**Run by:** `phase3-binary/scripts/test-ws-cancellation.sh`

**AC-14. WS capacity-1 rejection (reconciled v1.7).**
A mock coordinator sends a second `inference_request` on a WebSocket while the
first is still in flight. The relay (fixed capacity 1) accepts the first and
rejects the second with `inference_response_end status: "error_queue_full"`
(FR-25/FR-27); the first completes normally with correct `request_id`
correlation. (The ≤ v1.6 "3 concurrent requests all succeed with
`max_concurrency_override: 3`" test does not hold — the tunnel is fixed at 1
regardless of `max_concurrency`.)

**Run by:** `phase3-binary/scripts/test-ws-multiplexing.sh`

**AC-15. Backward compatibility — unknown message type.**
A mock coordinator sends `{"type": "inference_request", ...}` to a
binary running in HTTP-forwarding mode (or a v1.1.x binary). The
binary responds with `nak code=unknown_message_type` per § 6.5 nak
semantics. The binary remains healthy and continues heartbeating.

**Run by:** `phase3-binary/scripts/test-ws-nak-fallback.sh`

**AC-16. Post-drain reconnect.**
With the binary running and joined to a local coordinator at
`state: ready`, the operator sends a drain directive (for example,
`POST /admin/drain?provider_id=<id>` on the coordinator's provider
port). The binary MUST:

1. Reply `drain_status: complete` per § 6.5.
2. Close the WS.
3. Within 30 seconds of the close, re-connect over a new WS using the
   **mode-selected handshake** (R-6.7.8): a fresh `hello` in legacy
   HTTP-forwarding mode, or a fresh v2 `auth_request` challenge/proof in
   WS-tunneled / credential-bootstrap mode.
4. Reach `state: ready` again in the coordinator pool within 60 seconds
   total elapsed from drain initiation.

**Run by:** Tail both the binary log (look for `reconnect attempt 1`)
and the coordinator's `/poolz` endpoint while issuing the drain
directive.

**AC-17. Cancel-usage normative reporting.**
With the binary running and joined to a local coordinator, the
coordinator sends a `cancel_request` mid-stream after `N` tokens of
generated output. The binary MUST: (1) honor the cancel within the
existing cancellation latency budget; (2) send `inference_response_end`
with `usage.prompt_tokens` > 0, `usage.completion_tokens` == `N` (the
actual generated count), and `usage.total_tokens` ==
`prompt_tokens + N`.

**Run by:** Mock coordinator unit test plus hardware integration test
against a local coordinator.

**AC-18.0. L-1 baseline default — no NEW SPEC-010/SPEC-011 surface.**
A v1.3 binary built per this spec, invoked with neither
`--supported-models` nor `--enable-warm-swap`, MUST satisfy ALL of:
(a) **when the connection is WS-tunneled or credential-bootstrap** (the modes
that use the v2 handshake; in legacy HTTP-forwarding mode the equivalent fields
ride the legacy `hello` — R-6.7.8) the v2 `auth_request` initial-stage frame
emits `supported_models: [model_id]` (single-entry) per SPEC-010 v1.5
R-3.6.2 / AC-19 and OMITS `publishes_supported_models` per SPEC-010
v1.5 R-3.6.4 / AC-21;
(b) heartbeat frame OMITS `model_hash` and `loading` fields entirely
(byte-identical **with respect to the SPEC-011 warm-swap fields**, not
"additional fields tolerated") per SPEC-011 v0.5 R-3.3.0 / AC-18. **Reconciled
v1.7:** this byte-identical guarantee is scoped to `model_hash` / `loading`; the
v1.7 additive heartbeat fields (`hardware_summary`, spec-decode,
`last_autoupdate_event`, §6.15.2) may still be present, as they ride the
heartbeat independently of `--enable-warm-swap`;
(c) no control socket file exists at
`$TMPDIR/macprovider-cli/ctl.sock` while serve is running per
SPEC-011 v0.5 R-3.1.0 / R-3.1.5 / AC-18 — **provided receipt rotation is also
disabled** (R-6.9.1 reconciled v1.7: receipts-mode opens the socket
independently of warm swap);
(d) coordinator-observable routing, `/v1/status`, and `/v1/models`
behavior is indistinguishable from a pre-SPEC-010 binary per SPEC-010
v1.5 §4.1 back-compat analysis.
This is the L-1 BASELINE cell, scoped to "no NEW SPEC-010/SPEC-011
fields, sockets, or runtime state" — the single-entry catalog default
is part of SPEC-010 v1.5's locked binding contract and is the
back-compat-equivalent baseline. Traces to SPEC-011 v0.5 AC-18 and
SPEC-010 v1.5 AC-2 + AC-19 + AC-21.

**AC-18.1. SPEC-010 opt-in.**
A v1.3 binary invoked with `--supported-models A,B,C
--publish-supported-models=true --model A` **and connecting in WS-tunneled or
credential-bootstrap mode** (the mode, not the catalog opt-in, is what selects
v2 — R-6.7.8) MUST send v2 `auth_request` initial-stage with
`supported_models: [A, B, C]`, `publishes_supported_models: true`, and
`model_id: A`. (In legacy HTTP-forwarding mode the same catalog fields ride the
legacy `hello`.) Traces to SPEC-010 v1.5 AC-1 and AC-21.

**AC-18.2. SPEC-010 pre-flight.**
A v1.3 binary invoked with `--supported-models A,B --model C` MUST
exit code 2 BEFORE opening the coordinator WS with stderr containing
`"--model C not in --supported-models"`. Traces to SPEC-010 v1.5 AC-9.

**AC-18.3. SPEC-011 opt-in gate — disabled mode (ENOENT path).**
A v1.3 binary `serve` started with **neither** `--enable-warm-swap` **nor**
receipt rotation enabled (i.e. not `--enable-receipts` with a provider ID +
coordinator; see R-6.9.1 reconciled v1.7) MUST NOT
create any file at `$TMPDIR/macprovider-cli/ctl.sock`. A
`malibu-cli models list` invocation against that binary MUST
take the R-6.9.5 / R-3.1.5.x ENOENT case-1 path: exit code 4 with
stderr containing `"malibu-cli serve is not running on this
host (no control socket at"` (followed by the resolved socket path).
Traces to SPEC-011 v0.5 AC-18 case-1 and SPEC-001 v1.3 R-6.9.5. (Note: a
receipts-only socket **does** exist and answers `status_request`; a
`switch_request` against it is rejected with a generic error, not a distinct
"warm-swap disabled" status — see R-6.9.1.)

**AC-18.4. SPEC-011 opt-in gate — enabled mode.**
A v1.3 binary `serve --enable-warm-swap` MUST create the control socket
with mode `0600` and parent dir mode `0700`. Traces to SPEC-011 v0.5
AC-22 and AC-26.

**AC-18.5. macOS-native socket path.**
The default control socket path resolves to
`$TMPDIR/macprovider-cli/ctl.sock` via
`FileManager.default.temporaryDirectory`. Linux/freedesktop runtime-dir
environment paths MUST NOT appear anywhere in the binary's runtime path
resolution; they are unset on stock macOS. Traces to SPEC-011 v0.5
AC-26.

**AC-18.6. Atomic swap.**
Under `models switch <Y>` while serving an in-flight inference request,
the in-flight request MUST complete using the OLD weights; a NEW
request arriving AFTER atomic swap completion MUST be served by the NEW
weights. No caller observes mixed state. Traces to SPEC-011 v0.5 AC-9.

**AC-18.7. No-starve heartbeat.**
Heartbeat cadence MUST NOT pause during `loading` or `draining`. A
SPEC-002 §7.1 heartbeat-miss threshold MUST NOT be triggered by a model
swap. Traces to SPEC-011 v0.5 AC-12.

**AC-18.8. Heartbeat hash format.**
When `--enable-warm-swap` is set, `model_hash` on heartbeat frames MUST
be a 64-char lowercase hex string with no `sha256:` prefix and no
uppercase characters. Traces to SPEC-011 v0.5 AC-10 and AC-20.

**AC-18.9. Four matrix cells.**
Test matrix exercises all four cells of the SPEC-010 × SPEC-011 opt-in
matrix per §6.7.3, **with the connection in WS-tunneled or credential-bootstrap
mode** so the v2 `auth_request` frame is the one emitted (transport mode, not the
opt-ins, selects v2 vs legacy `hello` — R-6.7.8; the four-cell matrix varies only
the catalog/warm-swap field *content*, not the handshake choice). Each cell's
expected wire behavior is verified by capturing the v2 `auth_request` frame and
first heartbeat:
- Cell 1 (unset/unset): frame carries `supported_models: [model_id]`
  per SPEC-010 v1.5 R-3.6.2 / AC-19; OMITS `publishes_supported_models`
  per SPEC-010 v1.5 R-3.6.4 / AC-21; heartbeat OMITS `model_hash` /
  `loading` per SPEC-011 v0.5 R-3.3.0 / AC-18.
- Cell 2 (set/unset): frame carries the explicit `supported_models[]`
  list; `publishes_supported_models: true` when
  `--publish-supported-models=true`; heartbeat OMITS SPEC-011 fields.
- Cell 3 (unset/set): frame carries `supported_models: [model_id]`
  per R-3.6.2; OMITS `publishes_supported_models`; heartbeat carries
  `model_hash` (raw lowercase hex) and `loading` per SPEC-011 v0.5
  R-3.3.1 / AC-10 / AC-20.
- Cell 4 (set/set): frame carries explicit catalog + heartbeat carries
  SPEC-011 fields.
Each cell's expected shape is byte-asserted against the captured frame,
not "additional fields tolerated." Traces to SPEC-010 v1.5 AC-1, AC-2,
AC-19, AC-21 and SPEC-011 v0.5 AC-10, AC-18, AC-20, AC-23.

**AC-18.10. NEW §6.7 v2 handshake documented (scope reconciled v1.7).**
The check is a **projection test, not set-equality**: restricted to the fields
**owned by the SPEC-010 v1.5 §3.1.A table**, the SPEC-001 §6.7 handshake
documentation matches it byte-for-byte (no SPEC-010-owned field appears in one
and not the other). Every field SPEC-010 does **not** own is explicitly **exempt**
from this comparison — including, non-exhaustively, the 4th `tier2_capabilities`
sub-field, `credential_bootstrap`, the signed-catalog admission block, the
coordinator-sent `auth_challenge` / accepted-`auth_response` fields (§6.7.1.5),
`provider_receipt_public_key` (SPEC-015 v0.1.3 / SPEC-001 v1.6), and the
proof-stage `identity_signature` / `identity_signature_transcript_sha256`
(SPEC-026 §4.3). These are owned/carried by their respective specs (§6.15.1) and
are outside SPEC-010's field-table authority, so a literal whole-frame set-equality
test is **not** the criterion. Traces to SPEC-010 v1.5 AC-16 and AC-18.

**AC-18.11. No drift in §6.5.**
SPEC-001 v1.3 §6.5 (Coordinator WebSocket envelope — legacy `hello`
handshake) is byte-identical to SPEC-001 v1.2.4 §6.5. v1.3 adds the v2
handshake as a new §6.7; it does NOT modify the legacy `hello`
documentation. Verifiable by `diff` of the two versions' §6.5 sections.
Traces to SPEC-011 v0.5 AC-18 and SPEC-010 v1.5 AC-16.

**AC-18.12. Control-socket detection precedence — ECONNREFUSED.**
A v1.3 binary `serve --enable-warm-swap` running with a stale socket
file at `$TMPDIR/macprovider-cli/ctl.sock` left by a prior crashed
process (file exists but no listener) MUST cause `macprovider-cli
models list` to take the R-6.9.5 / R-3.1.5.x ECONNREFUSED case-2
path: exit code 4 with stderr containing `"stale control socket at"`
and `"remove the file and restart serve"`. Traces to SPEC-011 v0.5
R-3.1.5.x case 2 and SPEC-001 v1.3 R-6.9.5.

**AC-18.13. Control-socket detection precedence — handshake timeout.**
If the binary connects to the control socket successfully but no
`status_response` arrives within 2 seconds, `malibu-cli models
list` MUST take the R-6.9.5 / R-3.1.5.x case-3 path: exit code 4
with stderr containing `"serve is running but warm-swap is not
enabled (or serve is unresponsive)"`. Traces to SPEC-011 v0.5
R-3.1.5.x case 3 and SPEC-001 v1.3 R-6.9.5.

**AC-18.14. Cooldown soft guard + `--force` bypass.**
A v1.3 binary `serve --enable-warm-swap` that has successfully
processed a `models switch <X>` within the last 10 seconds MUST cause
the next `malibu-cli models switch <Y>` to exit code 6 with
stderr containing `"swap on cooldown for"` and `"Re-issue with
--force to bypass"` per SPEC-011 v0.5 R-3.1.4 / R-3.1.2 step 4. The
same invocation with `--force` MUST bypass the cooldown soft guard
per SPEC-011 v0.5 R-3.1.3 AND, as of v1.4, MUST ALSO bypass the
§6.13 fit guard per R-6.13.2 (`.wontFit` becomes a warning, `.tight`
is silenced, HF-shape `.unknown` fail-closed is overridden). The
v1.3 spelling of this AC said "ONLY the cooldown soft guard"; v1.4
explicitly supersedes that "ONLY" claim because PR #70 (R2) extended
the override to the fit guard. `--force` MUST NOT bypass either the
SPEC-010 R-3.6.3 pre-flight validation (verified by AC-18.2 path)
or the server-side concurrency rejection (an in-flight load still
returns `loadingInProgress` per SPEC-011 v0.5 R-3.1.x).
Traces to SPEC-011 v0.5 R-3.1.2 / R-3.1.3 / R-3.1.4, AC-24, and
v1.4 R-6.13.2.

**AC-18.15. WS drop reconnect — legacy `hello` in HTTP-forwarding mode (scope reconciled v1.7).**
This AC applies to a warm-swap-enabled binary running in **legacy
HTTP-forwarding mode**: when its WebSocket drops mid-load it reconnects using the
legacy §6.5 `hello` handshake per R-6.11.4 and SPEC-011 v0.5 R-3.8.3 / §3.8 —
NOT a fresh v2 `auth_request` — and the reconnect `hello.model_hash` MUST carry
the hash of the container currently referenced by `current_container` at
reconnect time per R-6.10.5 (the OLD hash if the swap is still in-flight), with
the first post-reconnect heartbeat after atomic swap carrying the new
`model_hash`. **A WS-tunneled or credential-bootstrap connection instead re-runs
the full v2 `auth_request` handshake on reconnect** (R-6.7.9) — the `hello`
reconnect assertion does not apply there; that path preserves model-hash
continuity via the §6.10.4 reconnect rule on the post-reconnect heartbeat rather
than via a `hello` frame. Traces to SPEC-011 v0.5 R-3.8.3 / §3.8 and SPEC-001
v1.3 R-6.10.5 / R-6.11.4.

**AC-18.16. Runtime state-value enumeration.**
A v1.3 binary `serve --enable-warm-swap` runtime MUST expose
exactly the four observable state values defined in §6.8.2 /
SPEC-011 v0.5 R-3.2.3: `ready`, `loading`, `draining`, `failed`.
Status responses on the control socket MUST report one of `ready`,
`loading`, `draining` per SPEC-011 v0.5 R-3.1.5 `runtime_state`
enum (the `failed` state is internal-only-transient per R-3.2.3 and
MUST NOT appear in `status_response.runtime_state`). Traces to
SPEC-011 v0.5 R-3.2.3 and R-3.1.5 field reference.

---

## 10. Open questions for operator

**OQ-1. Streaming usage chunk — client compatibility.** _RESOLVED 2026-06-26 (`docs/OPEN_QUESTIONS.md` triage): closed implicitly — gateway `chat_proxy.go:439` actively forwards this shape and 6+ months of production traffic produced no client-compat report._
FR-7 specifies the usage chunk with `choices: []`. Some clients (e.g.,
LiteLLM, certain OpenAI SDK versions) may not expect a chunk with empty
choices. Alternative: embed usage in the final content chunk alongside
`finish_reason`. The spec picks `choices: []` (matches OpenAI's current
behavior as of May 2025). Operator should confirm which downstream
clients will consume this and test.

**OQ-2. Tier announcement format.** _RESOLVED 2026-06-26 (`docs/OPEN_QUESTIONS.md` triage): closed as superseded — SPEC-008 v0.3 locked the tier scheme; tier-1.5 never surfaced as a real requirement. If it does, file a new SPEC._
FR-14 sends `tier: 1` as an integer. Should this be a version string
(`"tier-1"`) or a structured object (`{"level": 1, "capabilities": [...]}`)
to allow for tier 1.5 or partial upgrades? The spec picks integer for
simplicity. This is **settled**: SPEC-008 v0.3 locked the tier scheme and the
shipped Tier-2 uses the v2 `auth_request` `tier2_capabilities` object (§6.15),
not a `hello.tier` string/upgrade — so the legacy integer `tier: 1` stays as-is
and there is no open revisit.

**OQ-3. Binary distribution method.** RESOLVED in SPEC-003 v0.3
FR-C1, FR-C2. Distribution channel is GitHub Releases via
`https://get.malibu.tech/install.sh`. No longer an open question.

**OQ-4. WS frame size limit for large completions.**
A 32K-token streaming response at ~5 bytes/token generates ~160 KB of
SSE data, split across ~32,000 `inference_response_chunk` messages
(one per token). Each chunk is small (~200-500 bytes including
envelope). The concern is not individual frame size but total message
count and WS throughput. At 30 tok/s, that's 30 WS frames/s — well
within typical WS capacity. But a non-streaming response for a 32K
completion would be a single `inference_response_chunk` with a ~200 KB
`data` field, which fits in one WS text frame (gobwas/ws default max:
unbounded; network MTU handles fragmentation).

**Current position:** No explicit frame size limit in the protocol.
The 16 MB coordinator-side limit on `inference_request` (§ 6.6) is
sufficient. Non-streaming responses are bounded by `max_tokens`
(provider-enforced) and should not exceed a few MB. Monitor during
AC-12 testing. If WS throughput is a bottleneck, consider chunking
non-streaming responses.

**OQ-5. Provider-side WS write buffer sizing.**
FR-28 specifies 256 chunks per request as the provider-side write
buffer (§ 6.6 "Backpressure — provider-side write buffer"). This is a
starting estimate — 256 absorbs ~8.5 seconds of WS write latency at
30 tok/s. In practice the buffer should rarely fill because WS writes
are fast on local networks.

**Scope:** This OQ concerns the **provider-side** buffer only
(gobwas/ws or URLSessionWebSocketTask config on the binary). The
coordinator-side write buffer sizing is SPEC-002 v1.1.1 OQ-10.

**Current position:** 256 is a conservative default. Tune based on
production telemetry.

---

## 11. Implementation hand-off

### Hand-off to implementer

The build session should follow this sequence. Each step has a clear
deliverable that can be tested before moving to the next.

**Step 1. Create Swift package.**
Initialize `phase3-binary/` as a Swift Package Manager project. Add
dependencies per Section 7.1 version pins. Verify the package resolves
and compiles an empty main.

**Step 2. CLI entry and config loader.**
Implement argument parsing (FR-19) and YAML config loading. The binary
accepts `--port`, `--model`, `--coordinator`, `--config`, `--log-level`.
Deliverable: `malibu-cli --help` prints usage.

**Step 3. Model loader.**
Wrap `mlx-swift-lm` to load a model from a HuggingFace path. Read
`tokenizer_config.json` and extract special tokens for FR-6. Deliverable:
binary loads a model and prints its parameter count to stdout.

**Step 4. /v1/models endpoint.**
Stand up a minimal Swift NIO HTTP server. Implement `GET /v1/models`
returning the loaded model, plus global 404/405 handling. Deliverable:
`curl localhost:8080/v1/models` returns valid JSON matching Section 6.1.

**Step 5. /v1/chat/completions non-streaming.**
Implement `POST /v1/chat/completions` with `stream: false`. Wire the
full request validation chain (Section 6.2), inference, stop-token
stripping, and response formatting. Deliverable: valid completion with
usage; malformed requests return 400.

**Step 6. SSE streaming.**
Add `stream: true` support. Implement the SSE framing (FR-4), usage
chunk synthesis (FR-7), and stop-token stripping on streamed tokens.
Deliverable: streaming response with clean deltas, usage chunk before
`[DONE]`.

**Step 7. Context pre-flight and capacity.**
Implement FR-8 (two-stage pre-flight) and FR-9 (per-RAM capacity at
startup). Deliverable: a prompt exceeding the context cap returns
HTTP 413.

**Step 8. Semaphore serialization and concurrency.**
Implement FR-11 (blocking `AsyncSemaphore`, value = `max(1, max_concurrency)`;
excess requests await a permit via an **unbounded FIFO waiter list** — not a
depth-capped queue — and no 429). Deliverable: requests beyond max concurrency
block on the semaphore until a permit frees (FIFO); the WS-tunneled relay
(capacity 1) rejects a concurrent second with `error_queue_full`. **Carried
follow-up (not shipped):** FR-10 mid-stream disconnect detection →
`Task.cancel` and 5-second slot release is *not* wired in the shipped binary
(detached tasks, `shouldCancel: false`); implementers should treat it as
outstanding, not done. (The ≤ v1.6 "bounded queue + HTTP 429" plan was
never shipped and is retired in v1.7.)

**Step 9. Coordinator WebSocket client.**
Implement FR-13 (outbound WebSocket), FR-14 (hello + tier), FR-15
(health states + state_update), FR-16 (warm-up), FR-17 (capacity
heartbeat with all fields), and the §6.7 v2 `auth_request` handshake. Test
against a mock WebSocket server. Deliverable: binary connects (legacy `hello`
in HTTP-forwarding mode, v2 `auth_request` in WS-tunneled / credential-bootstrap
mode — R-6.7.8), heartbeats, responds to preflight and drain.

**Step 10. Graceful shutdown and self-test.**
Implement FR-12 (SIGTERM drain with drain_status messages) and FR-20
(startup self-test). Deliverable: binary passes self-test on start;
SIGTERM drains and exits cleanly.

**Step 11. Acceptance testing.**
Run AC-1 through AC-10. Fix issues. Deliver a binary that passes all
acceptance criteria.

### File structure (expected)

```
phase3-binary/
├── Package.swift
├── Sources/
│   └── macprovider-cli/
│       ├── main.swift
│       ├── Config.swift                 # FR-19
│       ├── ModelLoader.swift            # Step 3, FR-6
│       ├── StopTokenFilter.swift        # FR-6
│       ├── HTTPServer.swift             # Swift NIO server setup
│       ├── Router.swift                 # Route dispatch, 404/405
│       ├── RequestValidator.swift       # Section 6.2 validation chain
│       ├── ModelsHandler.swift          # FR-1
│       ├── ChatCompletionsHandler.swift # FR-2, FR-3
│       ├── HealthHandler.swift          # FR-18
│       ├── SSEWriter.swift              # FR-4, FR-5, FR-7
│       ├── ContextPreflight.swift       # FR-8 (both stages)
│       ├── CapacityManager.swift        # FR-9, FR-11
│       ├── CoordinatorClient.swift      # FR-13, FR-14, FR-15, FR-17
│       ├── ModelsSubcommand.swift       # §6.2, §6.9 models list/switch/status
│       ├── ControlSocket.swift          # §6.9 newline-delimited JSON control socket
│       ├── RuntimeStateMachine.swift    # §6.8 state machine + atomic swap
│       ├── IdlePrewarmer.swift          # FR-16 (idle prewarm; shipped name — was WarmupManager.swift in the v1.3 design layout)
│       ├── SelfTest.swift               # FR-20
│       ├── Middleware/                   # NOTE (v1.7): original design layout —
│       │   ├── TrustGate.swift          #   these Tier-2 middleware-hook files
│       │   ├── InputDecryptor.swift     #   were NEVER created; shipped Tier-2
│       │   └── ResponseSeal.swift       #   is SPEC-008 wire (Tier2ProviderSession.swift)
│       └── Logging.swift                # NFR-7
│   └── MacProviderCore/
│       └── SupportedModels.swift        # §6.2 SPEC-010 resolution/pre-flight
├── Tests/
│   └── macprovider-cliTests/
│       ├── RequestValidatorTests.swift
│       ├── StopTokenFilterTests.swift
│       ├── ContextPreflightTests.swift
│       ├── SSEWriterTests.swift
│       ├── CoordinatorClientTests.swift
│       └── CapacityManagerTests.swift
├── scripts/
│   ├── soak-test.sh                     # AC-3
│   └── test-coordinator.sh              # AC-5
├── implementation-notes.html            # Populated by build session
└── THIRD_PARTY_NOTICES.md
```

Expected v1.3 implementation modifications to existing files:

- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` —
  refactored per §6.8.1 from immutable `let` fields to actor-isolated
  mutable `current_container`.
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift` —
  extended v2 `auth_request` builder to emit SPEC-010 fields when
  opt-in flags are set; heartbeat builder gains opt-in-gated
  `model_hash` / `loading` fields per §6.10. Existing `helloMessage`
  hash source-of-truth follows §6.10.4 on reconnect.
- `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift` — adds
  `models` subcommand to the existing subcommand list (currently lines
  7-15).

---

## Appendix A: References used during spec writing

| Source | What was taken |
|---|---|
| `docs/legacy/phase1/HANDOFF.md` | Full project context, Phase 1 findings, strategic decisions, differentiation |
| `docs/legacy/phase1/PHASE1_REPORT.md` | Phase 1 evidence: OOM at ~26K, SSE quirks, latency data, concurrency data |
| `beta/PHASE2_UPGRADED_PLAN.md` | Phase 2 design upgrades: adversarial crons, corpus sampling, companion telemetry |
| `beta/DECISION_CRITERIA.md` | Decision log entries D1-D5: 502/530 routing, post-wake dip, stop-token status, throughput inversion, timeline compression |
| `beta/harness.py` | SSE parsing approach, per-model leak detection pattern, adversarial workload runner interface |
| `beta/workloads_adversarial.py` | Adversarial workload definitions: retry_storm, OOM probe, burst, disconnect, malformed |
| `beta/stop_tokens.py` | Stop-token derivation from tokenizer_config.json: extraction logic, caching, fallback |
| OpenAI API reference | Chat completions request/response schema, SSE streaming format, error envelope |
| `specs/SPEC-001-audit.md` | Audit findings (2 CRITICAL, 17 MAJOR, 9 MINOR) driving v1.1 revision |

**Clean-room note:** v1.0 (2026-05-27) consulted the d-inference public
README for repo structure and license verification. v1.1 established
strict clean-room policy (Section 7.2). No d-inference source files
were read during either v1.0 or v1.1. The v1.0 README consultation
predates the clean-room policy and is recorded here for transparency.
No further d-inference references are permitted.
