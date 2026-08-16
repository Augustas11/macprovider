# Integration Audit Report (Round 2 — Claude)

**Auditor:** Claude Opus 4.6 (1M context)
**Prior audit:** GPT-5.5 Round 1 at `specs/INTEGRATION-audit.md` (2026-05-28T07:13Z)
**Streams audited at HEAD:**
  - Stream A (Swift) commit 5cc278d
  - Stream B (Go) commit 5cc278d
  - Stream C (Distribution) commit 596460b

**Audit completed:** 2026-05-28T22:30:00Z

---

## TL;DR verdict

**NEEDS REVISION** — 3 CRITICAL, 8 MAJOR, 4 MINOR, 2 QUESTIONS

Confirms all 3 CRITICALs from GPT-5.5 Round 1. Adds 3 new MAJORs
(heartbeat field drop, missing preflight test, missing drain test)
and 4 new MINORs. Total finding count increased from 11 to 17.

Top three integration risks:

1. **NAK wire incompatibility** — Swift nests `code`/`message` inside
   `error` object per SPEC-001; Go expects flat fields. Backward-compat
   fallback (`http_forwarding_only` marking) is completely non-functional.
2. **install.sh coordinator check greps `/v1/models` for `provider_id`**
   but that response contains no provider IDs. AC-1 always fails.
3. **Install directory mismatch** — install.sh uses `~/macprovider/`,
   `macprovider-cli uninstall` hardcodes `~/.local/bin/macprovider-cli`.

Backward-compat: B.1 PASS, B.2 FAIL (NAK mismatch), B.3 PASS.

---

## Wire-compat matrix (Category W)

### hello (P->C)

| Field | Swift sends | Go parses | Verdict |
|---|---|---|---|
| `type` | `"hello"` | must be `"hello"` | matches |
| `version` | `1` (Int) | int, must be `1` | matches |
| `tier` | `1` (Int) | int, must be `1` | matches |
| `provider_id` | config or UUID | non-empty string | matches |
| `hostname` | localized name or `"unknown"` | non-empty string | matches |
| `model_id` | `snapshot.modelID` or `""` | non-empty string | matches |
| `model_params_b` | Double | float64 | matches |
| `ram_gb` | Int | int | matches |
| `max_context_tokens` | Int | int | matches |
| `max_concurrency` | Int (hardcoded 1) | int | matches |
| `throughput_tps_estimate` | Double | float64 | matches |
| `binary_version` | `"1.2.1"` | non-empty string | matches |
| `attestation` | NSNull (JSON null) | json.RawMessage, optional | matches |
| `endpoint_url` | String or **key absent** | `*string`, omitempty | matches |

### hello_ack (C->P)

| Field | Go sends | Swift parses | Verdict |
|---|---|---|---|
| `type` | `"hello_ack"` | switch match | matches |
| `coordinator_version` | `1` | not parsed | matches |
| `assigned_id` | UUID string | optional String | matches |
| `heartbeat_interval_s` | int, default 30 | Int, default 30, min 1 | matches |
| `tier` | `"pinned"`/`"provisional"`, omitempty | optional String | matches |
| `recommended_binary_version` | from config, omitempty | optional String | matches |

### inference_request (C->P)

| Field | Go sends | Swift parses | Verdict |
|---|---|---|---|
| `type` | `"inference_request"` | switch match | matches |
| `request_id` | `"req-"` + UUID | non-empty string | matches |
| `stream` | bool | Bool | matches |
| `body` | `string(rawBody)` | String | matches |

### inference_response_chunk (P->C)

| Field | Swift sends | Go parses | Verdict |
|---|---|---|---|
| `type` | `"inference_response_chunk"` | expected match | matches |
| `request_id` | from request | routes to relay | matches |
| `seq` | 0-based int | parsed, not validated | matches |
| `data` | SSE or JSON string | forwarded as-is | matches |

### inference_response_end (P->C)

| Field | Swift sends | Go parses | Verdict |
|---|---|---|---|
| `type` | `"inference_response_end"` | expected match | matches |
| `request_id` | from request | routes to relay | matches |
| `status` | enum (see below) | enum (see below) | matches |
| `chunks_sent` | Int | int | matches |
| `usage` | object on `"complete"` | json.RawMessage, omitempty | matches |
| `error` | string on errors | string, omitempty | matches |

**Status enum byte-for-byte:**

| Swift | Go | Buyer HTTP (FR-P14.1) | Match |
|---|---|---|---|
| `"complete"` | `"complete"` | 200 | yes |
| `"cancelled"` | `"cancelled"` | (no response) | yes |
| `"error_model_not_loaded"` | `"error_model_not_loaded"` | 503 | yes |
| `"error_context_exceeded"` | `"error_context_exceeded"` | 413 | yes |
| `"error_queue_full"` | `"error_queue_full"` | 503 / re-route | yes |
| `"error_internal"` | default -> 502 | 502 | yes |

### cancel_request (C->P)

| Field | Go sends | Swift parses | Verdict |
|---|---|---|---|
| `type` | `"cancel_request"` | switch match | matches |
| `request_id` | string | non-empty string | matches |
| `reason` | `"buyer_disconnected"` / `"timeout"` | not parsed | matches |

### nak (P->C) — CRITICAL MISMATCH

| Field | SPEC-001 | Swift sends | Go expects | Verdict |
|---|---|---|---|---|
| `type` | `"nak"` | `"nak"` | `"nak"` | matches |
| `in_reply_to` | string | sent | no such field | **MISMATCH** |
| `request_id` | not in spec | not sent | expected (omitempty) | **MISMATCH** |
| `error.code` | nested | nested in `error` obj | flat `code` | **MISMATCH** |
| `error.message` | nested | nested in `error` obj | flat `message` | **MISMATCH** |

Swift sends: `{"type":"nak","in_reply_to":"...","error":{"code":"unknown_message_type","message":"..."}}`
Go expects: `{"type":"nak","request_id":"...","code":"unknown_message_type","message":"..."}`

Go `json.Unmarshal` yields empty `Code`. The check `nak.Code == "unknown_message_type"` never matches.

---

## CLI / HTTP-route compat matrix (Category H)

### install.sh -> Stream A (Swift CLI)

| install.sh passes | Swift accepts | Verdict |
|---|---|---|
| `--port` | `--port` on `serve` | matches |
| `--model` | `--model` on `serve` | matches |
| `--provider-id` | `--provider-id` on `serve` | matches |
| `--coordinator` | `--coordinator` on `serve` | matches |
| no `serve` keyword | `serve` is default subcommand | matches |
| no `--config` | default path `~/.config/macprovider/config.yaml` still read | matches |

### install.sh -> Stream B (Go coordinator)

| install.sh queries | Go serves | Verdict |
|---|---|---|
| `GET /v1/models` (no auth) | buyer port `/v1/models`, no auth | matches |
| greps `provider_id` in response | response has model data only, no provider_id | **MISMATCH** |
| never calls `/poolz` | `/poolz` requires operator auth | N/A |

### install.sh -> Stream A (local self-test)

| install.sh queries | Swift serves | Verdict |
|---|---|---|
| `GET 127.0.0.1:PORT/v1/models` | `/v1/models` with `owned_by: macprovider` | matches |
| greps `"owned_by"..."macprovider"` | present in response | matches |
| greps model name (fixed-string) | `"id"` field has full model ID | matches |

---

## End-to-end flow gaps (Category E)

### E.1 — Stranger runs install.sh

| Step | Status |
|---|---|
| 1. Download tarball | OK — asset name `macprovider-cli-${tag}-darwin-arm64.tar.gz` matches |
| 2. Verify checksum | OK — `checksums.txt` format consistent |
| 3. Verify signature | **BLOCKED** — placeholder public key causes `die 3` |
| 4. Extract to `~/macprovider/` | OK — tarball entries validated |
| 5. Render plist | OK — CLI flags accepted by Swift |
| 6. Load plist | OK — label `live.malibu.provider` consistent |
| 7. Hello to coordinator | OK — provisional admission, WS-tunneled |
| 8. hello_ack | OK — `tier: "provisional"` |
| 9. Local /v1/models | OK |
| 10. Coordinator check | **FAILS** — greps for provider_id, not in /v1/models |
| 11. Print success | Degrades to AC-1a warning |

### E.2 — Buyer request to provisional provider

No cross-stream gaps in the inference hot path. All wire fields match.
Gaps noted by Round 1 (Retry-After header, seq enforcement) are within
Stream B; not cross-stream wire breaks.

### E.3 — macprovider-cli update

Asset names match. SHA-256 verification works. No signature verification
in SelfUpdate (unlike install.sh). No explicit drain before launchd
restart (relies on SIGTERM -> drain, untested).

### E.4 — Uninstall paths

| Aspect | `macprovider-cli uninstall` | `uninstall.sh` | Gap |
|---|---|---|---|
| Binary | `~/.local/bin/macprovider-cli` | `~/macprovider/` | **MISMATCH** |
| Plist | same path | same path | OK |
| Config | optionally removes | does NOT remove | different |
| Logs | `~/Library/Logs/macprovider` | same | OK |
| Data dir | `~/.local/share/macprovider` | not referenced | gap |
| .zshrc | removes PATH line | does not touch | gap |
| Cache | neither removes `~/.cache/macprovider/` | neither | gap |

---

## Findings by severity

### CRITICAL (3)

**C1. NAK wire structure incompatibility (Swift <-> Go)**

Severity: CRITICAL | Category: W.6, B.2 | *Confirmed from Round 1 C1*

Affected files:
- Stream A: `CoordinatorClient.swift:353-362` (sends nested `error.code`)
- Stream B: `messages.go:103-108` (expects flat `code`)
- Stream B: `relay.go:275-299` (checks `nak.Code == "unknown_message_type"`)

Swift sends per SPEC-001: `{"type":"nak","in_reply_to":"...","error":{"code":"unknown_message_type",...}}`
Go struct expects: `{"type":"nak","request_id":"...","code":"...","message":"..."}`

Go's `json.Unmarshal` yields empty `Code` and empty `RequestID`. The
fallback check never fires. The entire nak-to-http_forwarding_only
mechanism is non-functional. Backward-compat scenario B.2 fails.

Fix: **Stream B** must parse SPEC-001 nak shape (nested `error.code`,
`in_reply_to`). Add a cross-stream test fixture using Swift's real nak JSON.

---

**C2. install.sh coordinator check greps for provider_id in /v1/models (not present)**

Severity: CRITICAL | Category: H.1 | *Confirmed from Round 1 C2*

Affected files:
- Stream C: `install.sh:514-525` (`wait_for_coordinator` greps for provider_id)
- Stream B: `buyer/server.go:135-185` (`/v1/models` returns model metadata only)

`/v1/models` response shape: `{"object":"list","data":[{"id":"model-name","object":"model","provider_count":2,...}]}`.
No `provider_id` anywhere. The `grep -Fq "$provider_id"` never matches.

Fix: **Stream B** adds a lightweight public endpoint (e.g.
`GET /v1/pool/check?provider_id=X` -> 200/404). **Stream C** uses it.

---

**C3. Install directory mismatch: ~/macprovider/ vs ~/.local/bin/**

Severity: CRITICAL | Category: H.2, E.4 | *New finding (Round 1 M4 was MAJOR; elevated to CRITICAL)*

Affected files:
- Stream C: `install.sh:17-18` (`INSTALL_DIR="$HOME/macprovider"`)
- Stream A: `UninstallCommand.swift:26` (`~/.local/bin/macprovider-cli`)
- SPEC-003 FR-C2: specifies `~/.local/bin/macprovider-cli`

`macprovider-cli uninstall` after an install.sh installation fails to find
and remove the binary. This is not a cosmetic path difference — it's a
broken user-facing operation.

Fix: **Stream C** changes `INSTALL_DIR` to `~/.local/bin/` (binary) +
`~/.local/lib/macprovider/` (bundles), matching SPEC-003. Or **Stream A**
resolves its own executable path instead of hardcoding.

---

### MAJOR (8)

**M1. Signing key placeholder blocks production install.sh**

Severity: MAJOR | Category: R.3, E.1 | *Confirmed from Round 1 C3 (downgraded: operator can fix without code change)*

Affected: `install.sh:289-304`

The embedded public key is `REPLACE_WITH_MACPROVIDER_RELEASE_SIGNING_PUBLIC_KEY`.
install.sh checks for this and calls `die 3`. Production installs abort.

Fix: **Stream C / Operator** embeds actual key, or makes signature
verification opt-in for v1.

---

**M2. Provisional quota 429 lacks Retry-After header**

Severity: MAJOR | Category: H | *Confirmed from Round 1 M1*

Affected: `buyer/server.go` (writeError has no Retry-After path)

SPEC-002 requires `Retry-After: 3600` on 429. Not implemented.

Fix: **Stream B**.

---

**M3. Go ParseHeartbeat silently drops three fields**

Severity: MAJOR | Category: W.1 | *New finding*

Affected:
- Stream B: `messages.go:34-48` (struct defines all fields)
- Stream B: `messages.go:225-264` (parser stops at `throughput_tps_estimate`)

`requests_served_since_last`, `avg_latency_ms_since_last`, and
`throughput_tps_since_last` are defined in the Go Heartbeat struct but
`ParseHeartbeat()` never extracts them. Swift sends all three. They
are silently discarded.

Fix: **Stream B** either parses them or removes from struct.

---

**M4. No cross-stream test for NAK fallback (mock parity failure)**

Severity: MAJOR | Category: T.1, T.3 | *Confirmed from Round 1, additional detail*

Affected:
- Stream B: `relay_test.go:211` (TestRelayNAKFallbackMarksHTTPForwardingOnly)
- Stream B: `tools/mockprovider/main.go:159-160`

Go's relay_test uses mockprovider which likely sends flat-format NAKs
(matching Go's struct, not SPEC-001). Test passes but doesn't validate
the real Swift wire format. Classic mock-implementation parity failure.

Fix: **Stream B** adds a test fixture with SPEC-001-compliant nested NAK JSON.

---

**M5. Phase 3 has no preflight handling test**

Severity: MAJOR | Category: T.1 | *New finding*

Affected:
- Stream A: `tools/mock-coordinator/mock_coordinator.py` (no preflight scenario)
- Stream A: `CoordinatorClient.swift:164-165,215-257` (preflight handler)

mock_coordinator.py implements scenarios: nonstream, stream, cancel,
multiplex, nak. It never sends `preflight`. Phase 3's `preflight_ack`
construction is untested by any test in any stream.

Fix: **Stream A** adds preflight scenario to mock + test script.

---

**M6. Phase 3 has no drain handling test**

Severity: MAJOR | Category: T.1 | *New finding*

Affected:
- Stream A: `CoordinatorClient.swift:186-192` (drain handler)
- No test covers this path

Phase 3 receives `drain` and should emit `drain_status` progression.
Phase 4 tests drain with mockprovider, but Phase 3 itself has no test.

Fix: **Stream A** adds drain scenario to mock + test script.

---

**M7. Self-update does not prove graceful drain during launchd restart**

Severity: MAJOR | Category: E.3, T.1 | *Confirmed from Round 1 M3*

Affected: `SelfUpdate.swift` (bootout/bootstrap with no explicit drain)

No test proves `launchctl bootout` -> SIGTERM -> drain_status sequence
completes during active WS inference before restart.

Fix: **Stream A** adds integration test or explicit drain call.

---

**M8. uninstall.sh and macprovider-cli uninstall inconsistent cleanup**

Severity: MAJOR | Category: E.4 | *Confirmed from Round 1 M4, expanded*

Affected: `uninstall.sh:88-114`, `UninstallCommand.swift`

Beyond the path mismatch (C3): uninstall.sh keeps config, Swift
optionally removes it. Neither removes `~/.cache/macprovider/`.
uninstall.sh doesn't touch .zshrc or `~/.local/share/macprovider`.

Fix: **Stream A + C** align on a single artifact manifest.

---

### MINOR (4)

**m1. ProcessType: spec says Background, implementations use Adaptive**

Severity: MINOR | Category: C.1 | *New finding*

Affected: SPEC-003 FR-C5, `install.sh:473`, `launchd-plist-template.plist:52`

Implementations consistently use `Adaptive` (better for inference bursts).
Spec should be updated to match.

---

**m2. install.sh plist bypasses config.yaml via direct CLI flags**

Severity: MINOR | Category: C.1 | *New finding*

Affected: `install.sh:438-449` (plist ProgramArguments)

SPEC-003 FR-C5 shows `serve --config`. install.sh passes
`--port --model --provider-id --coordinator` directly. CLI flags override
config values, so user edits to config.yaml have no effect when plist is active.

---

**m3. Log paths differ from SPEC (implementations consistent)**

Severity: MINOR | Category: I.1 | *New finding*

SPEC-003: `~/.local/share/macprovider/logs/stdout.log`
Implementations: `~/Library/Logs/macprovider/macprovider.out.log`

Stream A and Stream C agree with each other. Spec should be updated.

---

**m4. ~/.cache/macprovider/ not cleaned by any uninstall path**

Severity: MINOR | Category: E.4 | *New finding*

`SelfUpdate.swift:76` creates `~/.cache/macprovider/latest-release.json`.
Neither uninstall path removes it. ~100 bytes leftover.

---

### QUESTIONS (2)

**Q1. Does mockprovider send SPEC-compliant or Go-struct NAKs?**

Category: T.3

If mockprovider sends flat NAKs (matching Go's struct), relay_test passes
but doesn't test Swift's real format. If it sends nested NAKs, relay_test
should already fail. Auditor suspects the former — masking C1.

---

**Q2. Does coordinator.malibu.tech reverse proxy route /v1/models to buyer port?**

Category: H.1

Go serves `/v1/models` on buyer port 8443. install.sh hits
`https://coordinator.malibu.tech/v1/models` (port 443). The reverse proxy
(Caddy) must route to 8443, not 8444. Infrastructure concern, not code.

---

## Backward-compat verification

| Scenario | Result | Detail |
|---|---|---|
| B.1: M4 v1.1.4, no endpoint_url in hello, config has endpoint_url | **PASS** | Go mode resolution: pinned + config endpoint_url -> HTTP_FORWARDING. No S 6.6 sent. |
| B.2: M4 v1.1.4 receives inference_request, sends nak | **FAIL** | Swift/v1.1.x nak uses nested `error.code`. Go parses flat `code` -> empty. Provider NOT marked `http_forwarding_only`. |
| B.3: M4 upgrades to v1.2, config still has endpoint_url | **PASS** | Swift reads config `endpoint_url` -> includes in hello. Go uses it for HTTP_FORWARDING. |

---

## Recommendation

**NEEDS REVISION.** 3 CRITICALs must be resolved before integration testing.

### Per-stream fix ownership

**Stream B (Go coordinator):**
- C1: Parse SPEC-001 nak shape (nested `error.code`, `in_reply_to`)
- C2: Add public endpoint for install verification
- M2: Add `Retry-After: 3600` on 429
- M3: Complete ParseHeartbeat or remove dead fields
- M4: Add SPEC-compliant nak test fixture

**Stream A (Swift binary):**
- C3 (partial): Use resolved executable path instead of hardcoded `~/.local/bin/`
- M5: Add preflight scenario to mock + test
- M6: Add drain scenario to mock + test
- M7: Add update-during-inference drain test
- m4: Add `~/.cache/macprovider` to uninstall cleanup

**Stream C (Distribution):**
- C2 (partial): Use new verification endpoint instead of /v1/models grep
- C3 (partial): Change INSTALL_DIR to `~/.local/bin/` per SPEC-003
- M1: Embed real signing key or make signature optional
- M8: Align uninstall artifact manifest with Stream A
- m1-m3: Update spec references

### Integration test plan (after fixes)

1. Start coordinator locally (no pinned providers, admission enabled)
2. `bash install.sh` with `MACPROVIDER_NO_PROMPT=1`
3. Verify provider in pool via new public endpoint
4. `POST /v1/chat/completions` (streaming + non-streaming)
5. Buyer disconnect mid-stream -> verify cancel propagation
6. Force SPEC-shaped nak -> verify `http_forwarding_only` marking + 503
7. `macprovider-cli update --check` -> verify release discovery
8. SIGTERM coordinator -> verify drain sequence
9. `macprovider-cli uninstall --yes` -> verify all artifacts removed
10. `bash uninstall.sh` on fresh install -> verify that path works
11. Release fixture with real checksum signature -> verify install.sh e2e
