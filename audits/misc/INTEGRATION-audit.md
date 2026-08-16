# Integration Audit Report

Auditor: Codex GPT-5.5

Streams audited at HEAD:
- Stream A (Swift) commit 5cc278d611401ec2fac421dab8979e574eb950d1
- Stream B (Go) commit 5cc278d611401ec2fac421dab8979e574eb950d1
- Stream C (Distribution) commit 596460bbe1a806e11efc4924d072c2390aa4f98f

Audit completed: 2026-05-28T07:13:19Z

Note: `specs/AUDIT_INTEGRATION_PROMPT.md` asked for Claude CLI coverage, but the local Claude CLI was not logged in. The operator then requested this run via GPT-5.5; this report is the GPT-5.5 integration audit.

## TL;DR verdict

NEEDS REVISION.

Finding counts:
- CRITICAL: 3
- MAJOR: 5
- MINOR: 2
- QUESTIONS: 1

Top three integration risks:
1. Swift emits SPEC-001/SPEC-002 `nak` frames with `in_reply_to` plus nested `error.code`, but Go parses `nak.code` and `nak.request_id` at top level. The v1.1.x fallback path will not mark providers `http_forwarding_only`.
2. `install.sh` waits for `provider_id` to appear in coordinator `/v1/models`, but Go's buyer `/v1/models` response only lists aggregate model entries. Clean install AC-1 will fail after the provider is otherwise connected.
3. Public install cannot verify releases from a stranger Mac because `install.sh` requires a real checksum signing public key but still contains a placeholder. Self-update also verifies only SHA256, not the signature that install requires.

## Wire-compat matrix (Category W)

| Message | Field | Swift serialization/parsing | Go serialization/parsing | Verdict |
|---|---|---|---|---|
| `hello` | `type` | Sends `"hello"` in `CoordinatorClient.helloMessage()` | Requires string `"hello"` in `ParseHello` | matches |
| `hello` | `version` | Sends integer `1` | Requires int; rejects non-1 | matches |
| `hello` | `tier` | Sends integer `1` | Requires int; rejects non-1 | matches |
| `hello` | `provider_id` | Sends config `provider_id` or generated UUID | Requires non-empty string; pinned/provisional admission | matches for public provisional; config comments stale about 4002 |
| `hello` | `hostname` | Sends localized hostname or `"unknown"` | Requires non-empty string | matches |
| `hello` | `model_id` | Sends loaded model/config model | Requires non-empty string | matches |
| `hello` | `model_params_b` | Sends numeric capacity estimate | Requires float | matches |
| `hello` | `ram_gb` | Sends int | Requires int | matches |
| `hello` | `max_context_tokens` | Sends int | Requires int | matches |
| `hello` | `max_concurrency` | Sends int; runtime currently advertises 1 | Requires int | matches |
| `hello` | `throughput_tps_estimate` | Sends double | Requires float | matches |
| `hello` | `binary_version` | Sends `"1.2.1"` | Requires non-empty string; stores on provider | matches |
| `hello` | `attestation` | Sends JSON null | Optional raw JSON accepted | matches |
| `hello` | `endpoint_url` | Omits when config has no endpoint; sends non-empty config endpoint | Optional pointer; absent/null treated as nil; pinned config endpoint wins | matches |
| `hello_ack` | `type` | Parses `"hello_ack"` | Sends `"hello_ack"` | matches |
| `hello_ack` | `coordinator_version` | Ignored | Sends int `1` | matches |
| `hello_ack` | `assigned_id` | Stores optional string | Sends generated UUID string | matches |
| `hello_ack` | `heartbeat_interval_s` | Parses int, defaults/mins to 30/1 | Sends configured interval, default 30 | matches |
| `hello_ack` | `tier` | Parses optional string for status/log | Sends `"pinned"` or `"provisional"` | matches |
| `hello_ack` | `recommended_binary_version` | Parses optional string and semver-nudges | Sends `latest_binary_version` | matches |
| `inference_request` | `type` | Dispatches only in WS-tunneled mode | Sends `"inference_request"` | matches |
| `inference_request` | `request_id` | Requires non-empty string, detects duplicate active IDs | Sends `req-` prefixed request ID | matches |
| `inference_request` | `stream` | Requires bool | Sends bool from buyer request | matches |
| `inference_request` | `body` | Requires JSON body as string, then parses OpenAI request | Sends original request body as string | matches |
| `inference_response_chunk` | `type` | Sends `"inference_response_chunk"` | Parses struct field | matches |
| `inference_response_chunk` | `request_id` | Sends originating request ID | Routes by request ID | matches |
| `inference_response_chunk` | `seq` | Sends monotonically increasing int | Parses int but does not enforce ordering | not covered |
| `inference_response_chunk` | `data` | Sends SSE event string for streaming; JSON response string for non-streaming | Writes/appends raw string | matches |
| `inference_response_end` | `type` | Sends `"inference_response_end"` | Parses struct field | matches |
| `inference_response_end` | `request_id` | Sends originating request ID | Removes active request by ID | matches |
| `inference_response_end` | `status` | Sends `complete`, `cancelled`, `error_model_not_loaded`, `error_context_exceeded`, `error_queue_full`, `error_internal` | Maps same enum in `writeWSEndError` | matches |
| `inference_response_end` | `chunks_sent` | Sends count | Parses int but does not compare to received chunk count | not covered |
| `inference_response_end` | `usage` | Sends on complete | Preserves raw JSON internally; not buyer-visible in non-stream except response body | matches |
| `inference_response_end` | `error` | Sends string on error | Parses string; maps generic buyer error | matches |
| `cancel_request` | `type` | Dispatches only in WS-tunneled mode | Sends `"cancel_request"` | matches |
| `cancel_request` | `request_id` | Requires non-empty string; unknown ID returns cancelled end with 0 chunks | Sends active request ID | matches |
| `cancel_request` | `reason` | Ignored by Swift | Sends `buyer_disconnected` or `timeout` | matches |
| `nak` | `in_reply_to` | Sends per SPEC-001 nested shape | Go `NAK` struct has no `in_reply_to` | mismatch |
| `nak` | `error.code` | Sends nested `error.code` | Go expects top-level `code` | mismatch |
| `nak` | request correlation | Swift does not send top-level `request_id` | Go only unblocks active relay if top-level `request_id` is present | mismatch |
| WS close | 4007/4008/4009 | Swift does not reference close code constants | Go emits close codes for provisional pool/rate/banned | not covered; acceptable because Swift reconnects generically |

## CLI / HTTP-route compat matrix (Category H)

| Assumption | Stream C implementation | Stream A/B implementation | Verdict |
|---|---|---|---|
| launchd invokes `--port` | `install.sh` and plist pass `--port` | `ServeCommand` defines `@Option var port` | matches |
| launchd invokes `--model` | `install.sh` and plist pass `--model` | `ServeCommand` defines `@Option var model` | matches |
| launchd invokes `--provider-id` | `install.sh` and plist pass `--provider-id` | `ServeCommand` defines `providerID`; ArgumentParser maps to `--provider-id` | matches |
| launchd invokes `--coordinator` | `install.sh` and plist pass `--coordinator` | `ServeCommand` defines `@Option var coordinator` | matches |
| launchd may invoke `--endpoint-url` | Public install does not pass it; template does not include it | `ServeCommand` defines `endpointURL`; ArgumentParser maps to `--endpoint-url` | matches if future installer adds it |
| local AC-1 checks `/v1/models` | `wait_for_local_model` curls `127.0.0.1:${PORT}/v1/models` and greps model/owner | Swift `HTTPServer` serves OpenAI-style model list with `owned_by: macprovider` | matches |
| coordinator AC-1 checks `/v1/models` for provider ID | `wait_for_coordinator` curls `https://coordinator.malibu.tech/v1/models` and greps `provider_id` | Go buyer `/v1/models` returns aggregate model entries without provider IDs | mismatch |
| coordinator pool visibility via `/poolz` | README says pool visibility check, but `install.sh` never calls `/poolz` | Go `/poolz` exists on provider/operator surface and requires `Authorization: Bearer <operator_key>` | mismatch |
| `/poolz` auth header | no operator key support in public install | Go expects `Authorization: Bearer <operator_key>` unless auth disabled | mismatch for stranger install |
| buyer `/v1/models` route | public URL `/v1/models` expected | Go buyer server registers `GET /v1/models` | matches |
| buyer `/v1/chat/completions` route | README/buyer stable API expected | Go buyer server registers `POST /v1/chat/completions` | matches |
| coordinator `/healthz` route | SPEC-002 treats it as stable/operator endpoint | Go registers `/healthz` on provider/operator server; deployment comments proxy it there | matches if reverse proxy preserves `/healthz` |

## End-to-end flow gaps (Category E)

### E.1 Stranger runs `install.sh` on a clean Mac

Step result:
1. Download asset names match: `install.sh` expects `macprovider-cli-${tag}-darwin-arm64.tar.gz`, `checksums.txt`, `checksums.txt.sig`; release workflow publishes those names.
2. Signature verification is blocked by placeholder public key in `install.sh`; a public stranger install exits before SHA verification unless an environment variable supplies the key.
3. Tarball checksum naming is consistent with `checksums.txt`.
4. Tar extraction layout is compatible: package contains `macprovider-cli` plus bundles; installer accepts `macprovider-cli` and `*.bundle`.
5. Config and launchd render the same provider ID/model/coordinator flags that Swift accepts.
6. Binary starts in WS-tunneled mode because no `endpoint_url` is written.
7. Go accepts unknown provider IDs as provisional if rate/pool limits allow.
8. The AC-1 coordinator visibility check is wrong: it greps provider ID in `/v1/models`, but `/v1/models` has no provider IDs. `/poolz` has provider IDs but is auth-gated and not called.

### E.2 Buyer sends `POST /v1/chat/completions` to a provisional provider

The main relay path composes: Go selects ready providers, sends `inference_request`, Swift returns chunks and terminal status, and Go streams/assembles the buyer response. Gaps:
- Go returns 429 for exhausted provisional quota but does not set the SPEC-002 `Retry-After: 3600` header.
- Go parses `seq` and `chunks_sent` but does not verify ordering/count, so the field-level contract is not actually enforced.
- Buyer disconnect cancellation is tested at Go relay level and Swift relay level, but not end-to-end across a real Swift provider plus real Go coordinator.

### E.3 `macprovider-cli update`

Release asset name and checksum file lookup match the GitHub Action. Gaps:
- `SelfUpdate.swift` verifies SHA256 but does not fetch or verify `checksums.txt.sig`, while install requires a signed checksum manifest.
- `SelfUpdate.swift` replaces the binary and restarts launchd if installed, but does not explicitly drain the current coordinator session before bootout/restart. The graceful drain behavior is implemented for SIGTERM, but the update flow has no integration test proving launchd bootout produces the required drain during in-flight WS inference.

### E.4 `macprovider-cli uninstall` and `dist/uninstall.sh`

Both paths stop the same launchd label and remove installed binary/log paths, but they are not fully consistent:
- `dist/uninstall.sh` removes `~/macprovider` and logs but keeps `~/.config/macprovider`.
- `macprovider-cli uninstall` removes `~/.local/bin/macprovider-cli`, not `~/macprovider/macprovider-cli`, unless state removal is requested. That path does not match the public installer's `~/macprovider` layout.
- Neither path sends an explicit coordinator drain itself; they rely on service termination behavior if a running service receives SIGTERM.

## Findings by severity

### CRITICAL (3)

**C1 - `nak` envelope mismatch breaks v1.1.x fallback and current Swift-Go NAK handling.**

Severity: CRITICAL

Category: W/B/T

Affected files:
- `specs/SPEC-001-phase3-binary.md`
- `specs/SPEC-002-coordinator.md`
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
- `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift`
- `phase4-coordinator/internal/ws/messages.go`
- `phase4-coordinator/internal/ws/relay.go`
- `phase4-coordinator/internal/ws/relay_test.go`

What's wrong: SPEC-001 and SPEC-002 define provider `nak` as `{ "type":"nak", "in_reply_to":"...", "error": {"code":"unknown_message_type", ...}}`. Swift emits that shape. Go parses `NAK` as top-level `code`, `message`, and optional `request_id`. Therefore a real Swift or v1.1.x provider's fallback NAK will parse with empty `Code`; Go will neither mark `http_forwarding_only` nor unblock the active relay. The Go fallback test uses the Go struct shape and never tests the actual spec/Swift shape.

Fix direction: Stream B should parse the locked SPEC-001/SPEC-002 NAK shape (`in_reply_to`, nested `error.code`, `error.message`) and, for § 6.6 fallback, correlate by active request when `in_reply_to == "inference_request"` and no top-level request ID exists. Add a cross-stream fixture using Swift's emitted NAK JSON.

**C2 - `install.sh` coordinator visibility check greps provider ID in a response that never contains provider IDs.**

Severity: CRITICAL

Category: H/E/C

Affected files:
- `phase3-binary/dist/install.sh`
- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/ws/server.go`
- `README.md`

What's wrong: `wait_for_coordinator` curls `https://coordinator.malibu.tech/v1/models` and waits for the selected `provider_id`. Go's `/v1/models` aggregates models and returns fields like `id`, `provider_count`, `max_context_tokens`, and `total_slots`; it never includes `provider_id`. The endpoint that contains provider IDs is `/poolz`, but that route is mounted on the operator/provider surface and requires `Authorization: Bearer <operator_key>`. A clean public install can have a healthy WS connection and still fail AC-1 after 30 seconds.

Fix direction: Stream C should not grep provider IDs in `/v1/models`. Either check model visibility only, use local `/v1/status` coordinator connection state, or add/use a deliberately public onboarding-safe coordinator visibility contract. If `/poolz` remains the check, Stream C must supply the auth contract and correct port/proxy path, but exposing operator credentials to public installers is not acceptable.

**C3 - Public installer requires release signature verification but ships without the public key.**

Severity: CRITICAL

Category: R/E

Affected files:
- `phase3-binary/dist/install.sh`
- `.github/workflows/release.yml`
- `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift`
- `phase3-binary/README.md`

What's wrong: The release workflow signs `checksums.txt` into `checksums.txt.sig`. `install.sh` downloads the signature and calls `verify_checksum_signature`, but the embedded public key is still `REPLACE_WITH_MACPROVIDER_RELEASE_SIGNING_PUBLIC_KEY`, causing a hard exit for public installs unless `MACPROVIDER_CHECKSUM_PUBLIC_KEY_PEM` is pre-set. A stranger running the README curl command will not have that environment variable. `SelfUpdate.swift` consumes the same release but verifies only SHA256, not the signature, so install and update do not enforce the same trust path.

Fix direction: Stream C must publish/install a real release signing public key before public AC-1, or make signature verification explicitly optional with a clear operator-controlled policy. Stream A should either verify `checksums.txt.sig` in self-update too or the spec/README should stop claiming identical install/update verification.

### MAJOR (5)

**M1 - Provisional quota 429 lacks the required `Retry-After` header.**

Severity: MAJOR

Category: H/T

Affected files:
- `specs/SPEC-002-coordinator.md`
- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/buyer/server_test.go`

What's wrong: SPEC-002 routing says quota-exhausted provisional candidates return HTTP 429 with `Retry-After: 3600`. Go returns status 429 and code `provisional_quota_exceeded`, but `writeError` has no path to set `Retry-After`; the test checks only status/body.

Fix direction: Stream B should attach `Retry-After: 3600` for both pinned provisional quota and all-candidates quota exhaustion, then extend tests to assert the header.

**M2 - Go relay does not enforce `seq` ordering or `chunks_sent` count.**

Severity: MAJOR

Category: W/T

Affected files:
- `specs/SPEC-001-phase3-binary.md`
- `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift`
- `phase4-coordinator/internal/ws/relay.go`

What's wrong: Swift sends `seq` and `chunks_sent` per spec. Go parses both fields, but the relay appends chunks in receive order and accepts terminal frames without comparing `chunks_sent` to the number of chunks received. The protocol contract exists but is not enforced at the stream boundary.

Fix direction: Stream B should track expected `seq` per active request and compare terminal `chunks_sent` to received chunk count. Add tests for out-of-order, duplicate, skipped, and count-mismatch frames.

**M3 - Self-update does not prove graceful drain during launchd restart or in-flight WS requests.**

Severity: MAJOR

Category: E/T

Affected files:
- `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift`
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
- `phase3-binary/dist/install.sh`

What's wrong: `SelfUpdate.swift` downloads, checksum-verifies, extracts, self-tests, replaces, and restarts launchd. It does not explicitly call a coordinator drain path. It may rely on launchd bootout causing SIGTERM, but there is no integration test proving an update during active § 6.6 inference drains before replacement/restart.

Fix direction: Stream A should either explicitly invoke drain-before-replace or add a launchd/update integration test that proves SIGTERM reaches the running service and completes the `drain_status` sequence while in-flight requests finish or cancel per the spec.

**M4 - Public uninstall paths disagree on the install layout.**

Severity: MAJOR

Category: E/C

Affected files:
- `phase3-binary/dist/install.sh`
- `phase3-binary/dist/uninstall.sh`
- `phase3-binary/Sources/macprovider-cli/UninstallCommand.swift`

What's wrong: The public installer installs to `~/macprovider/macprovider-cli`. The shell uninstaller removes `~/macprovider`. The Swift `macprovider-cli uninstall` command removes `~/.local/bin/macprovider-cli` and optionally config/logs, but does not remove `~/macprovider`. Users following the README/public install path can run the CLI uninstall and leave the public install directory behind.

Fix direction: Stream A and Stream C should share the same install manifest or path constants. At minimum, Swift uninstall must remove the public installer's `~/macprovider` layout, or the README should direct public users only to `dist/uninstall.sh`.

**M5 - The required binary version field has no cross-stream behavior.**

Severity: MAJOR

Category: C/I

Affected files:
- `phase4-coordinator/internal/config/config.go`
- `phase4-coordinator/internal/ws/server.go`
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
- `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift`

What's wrong: Stream B config has `coordinator_advertised_version.required_binary_version`, but the WebSocket `hello_ack` sends only `recommended_binary_version` from `latest_binary_version`. Stream A parses `recommended_binary_version` and nudges, but there is no observable handling of `required_binary_version` by `SelfUpdate.swift` or the coordinator handshake. If the field is intentionally dormant, it is configuration drift; if it is required, the integration is missing.

Fix direction: Decide whether `required_binary_version` is inactive future config or an active contract. If active, Stream B must send/enforce it and Stream A must surface/respond to it. If inactive, remove or clearly mark it unused to avoid operator assumptions.

### MINOR (2)

**N1 - Stream A comments still describe unknown providers as rejected with 4002.**

Severity: MINOR

Category: B/C

Affected files:
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`

What's wrong: Comments say generated provider IDs are dev/test only and production coordinators reject with close code 4002. Stream B now admits unknown provider IDs as provisional unless rejected/rate-limited. Behavior composes correctly, but comments are stale.

Fix direction: Update comments to reflect provisional admission and 4007/4008/4009.

**N2 - Distribution docs and install script disagree on pool visibility mechanics.**

Severity: MINOR

Category: H/E

Affected files:
- `README.md`
- `phase3-binary/dist/install.sh`

What's wrong: README says the installer runs a coordinator pool visibility check. The implementation runs only `/v1/models` and does not call `/poolz`, so the term "pool visibility" is misleading.

Fix direction: Align README wording with the actual endpoint used after C2 is fixed.

### QUESTIONS (1)

**Q1 - Is `GET /healthz` intended to be buyer-facing or operator-facing in deployment?**

Severity: QUESTION

Category: H

Affected files:
- `specs/SPEC-002-coordinator.md`
- `phase4-coordinator/cmd/coordinator/main.go`
- `phase4-coordinator/internal/ws/server.go`
- `phase4-coordinator/internal/buyer/server.go`

What's unclear: SPEC-002's changelog says no buyer-facing change to `GET /healthz`, but later sections place `/healthz` with operator endpoints. Go mounts `/healthz` only on the provider/operator HTTP server, not the buyer HTTP server. Deployment comments say nginx proxies `/healthz` to the provider port, which may preserve the public URL, but the implementation itself does not make `/healthz` buyer-server-stable.

Fix direction: Confirm the reverse proxy is the public contract. If yes, clarify SPEC-002 wording. If no, mount `/healthz` on the buyer server too.

## Backward-compat verification

| Scenario | Result | Evidence |
|---|---|---|
| B.1 M4 v1.1.4 connects without `endpoint_url`, but is in coordinator static config with endpoint URL | YES | Go mode resolution checks pinned config endpoint before WS tunneling; pinned providers with configured endpoint become HTTP-forwarding even when hello omits endpoint. Swift v1.2 also preserves config `endpoint_url` if present. |
| B.2 M4 v1.1.4 receives unexpected § 6.6 and NAKs unknown message; coordinator marks `http_forwarding_only` and returns 503 | NO | Spec/Swift NAK shape is nested; Go fallback parser expects top-level `code`/`request_id`. The test uses Go's own non-spec NAK struct, so it does not prove real v1.1.x/Swift fallback. |
| B.3 M4 upgrades to v1.2 binary while still in config with `endpoint_url`; hello keeps endpoint URL | YES | Swift config loader reads `endpoint_url`; `CoordinatorClient` stores non-empty endpoint and `helloMessage()` includes it. Go pinned config endpoint also wins if both are present. |

## Test coverage gaps

Covered by at least one stream:
- Stream A has AC-11..15 scripts for WS non-stream, streaming, cancel, concurrency, and NAK fallback against a mock coordinator.
- Stream B has AC-11..15 scripts/tests for provisional admission, quota, WS relay, cancellation, and NAK fallback against mocks.
- Stream C has installer/update/launchd deliverables, but no visible automated AC-1..3 script in the audited files.

Normative-required but not covered end-to-end:
- Real Swift `nak` JSON into real Go coordinator fallback.
- Clean Mac install against real Go coordinator where provider appears in the correct endpoint.
- Buyer disconnect through Go buyer HTTP to real Swift provider cancellation within the SLA.
- Provisional quota exhausted with `Retry-After` header.
- Drain/update during active § 6.6 request with launchd bootout/restart.
- M1 8GB and M4 16GB public install model selection against real binary startup and coordinator visibility.
- Release signature verification with the real public key used by `install.sh`.

Mock drift:
- Go NAK fallback tests use a top-level `NAK{Code, RequestID}` shape that does not match SPEC-001 or Swift.
- Stream C's coordinator visibility check assumes `/v1/models` has provider IDs; Go tests correctly model `/v1/models` as aggregate model data.

## Recommendation

NEEDS REVISION before integration test.

Per-stream fix list:
- Stream B owns C1: parse SPEC NAK shape and correlate fallback with active § 6.6 dispatch.
- Stream C owns C2: replace the `/v1/models` provider-ID grep with a real, auth-appropriate visibility contract.
- Stream C owns C3 first: embed/publish the release signing public key or change policy; Stream A owns aligning self-update signature behavior afterward.
- Stream B owns M1/M2: add `Retry-After` and enforce `seq`/`chunks_sent`.
- Stream A owns M3/M4/M5 with Stream C coordination: prove update drain, align uninstall paths, and decide the required-version contract.

After those fixes, run an integration test plan:
1. Start a local coordinator with buyer and provider ports.
2. Run the Swift binary as a provisional provider with no `endpoint_url`.
3. Verify hello/hello_ack, tier, recommended version, heartbeat, and `/poolz`/visibility contract.
4. Send non-streaming and streaming buyer requests through Go to Swift and verify chunks/end status.
5. Disconnect buyer mid-stream and verify `cancel_request` plus provider cleanup.
6. Force a SPEC-shaped `nak unknown_message_type` and verify `http_forwarding_only` plus buyer 503.
7. Run installer dry-run/package verification against a local release fixture with real checksum signature.
