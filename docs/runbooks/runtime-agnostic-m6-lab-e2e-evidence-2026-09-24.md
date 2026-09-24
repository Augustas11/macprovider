# #1690 M6 lab e2e: llama-server serves a Trusted Pool buyer request (2026-09-24)

**Issue:** #1690 M6, lab rehearsal before the merge. **Branch:** `wip/1690-m6`
(base `85f087ee`, plus the M6-fix commits listed below). **Host:** Mac Studio
(M3 Ultra, 256 GB), isolated loopback. **Rig:** `scripts/lab/1690-m6/`.

## Result

An external engine (llama.cpp `llama-server` b11149) served real buyer
requests as a member of a SPEC-042 Trusted Pool, through a branch-built
coordinator, gateway, and provider CLI in enforce mode. Each paid request
produced a CLI-signed v0.4 receipt that the coordinator verified, a
`pool_operator_attested` attempt, a provider ledger credit, and finality
`token_source: pool_operator_attested`. The fail-closed cases held.

This needed three fixes on the branch, all found by this run. Without the two
CLI fixes, no llama-server member can ever be pool-selected. Without the
gateway fix, the buyer debit of every pool request stays held forever.

| Case | Result | Key evidence |
|---|---|---|
| 1. Paid path, non-streaming + streaming | PASS | 4/4: snapshot `pool_id`, `runtime_source=llamacpp_loopback`, `pool_generation`, `pool_operator_account_id`; receipt `4`/`valid`/`verified_settlement`; `pool_operator_attested`; provider credit > 0; finality `pool_operator_attested` |
| 1a. Attested usage equals llama-server usage | PASS | attested `[(44,32),(45,32),(49,32),(50,32)]` == upstream tap `[(44,32),(45,32),(49,32),(50,32)]` |
| 1b. llama-server omits usage | PASS (fail-closed) | `byte_estimated`, billable `(0,0)`, no receipt, credit 0, later `quarantined`, buyer refunded |
| 2. Same member on a global route | PASS | 503 `byom_non_settlement_unavailable` (plain, streaming, and provider-pinned); no dispatch, no route snapshot, no upstream call |
| 3. v1 core / empty v2 allowlist / runtime not allowlisted | PASS | pools B (v1), E (v2, `[]`), C (v2, `["ollama_loopback"]`): all 503, no dispatch |
| 4. Spoofed hello `runtime_source` | PASS | hello `ollama_loopback` and hello without a source (native claim) on the `llamacpp_loopback` candidate: dropped from pools A and C and from global |
| 5. Disputed label (manifest bumped mid-flight) | PASS | `label_disputed`, `byte_estimated`, billable `(0,0)`, `quarantined`, credit 0, buyer refunded |
| 5a. Generation bump only (member added mid-flight) | PASS | stays `pool_operator_attested`, label `verified` |
| 6. Streaming and non-streaming both settle; 12 streams at concurrency 4 | PASS | 12/12 intact; buyer (content sha, usage) set equals the llama-server set; 12/12 valid receipts, attested |
| Gateway reconcile (after the fix) | PASS | after the 300 s missing-receipt deadline: 17 reservations `settled` with `usage_events.token_source = pool_operator_attested`, 17 `refunded` (503s, quarantined), 0 held |

The table is the second, from-scratch run (`$LAB/fresh`, fresh lab keys, all
fixes in). Run 1 found the defects and staged the same cases; its numbers match.

## Rig design

Everything binds `127.0.0.1` on 19101-19131, every key is a lab key generated
under `/Users/a1/lab-1690-m6`, and nothing touches the live provider
(`:8080`, `~/.config/macprovider`, `live.malibu.*`, its control socket) or any
production host. `lsof` on the serve PID showed only loopback sockets.

```
buyer ──> gateway :19110 ──> coordinator :19101 (buyer) / :19102 (provider WS + admin)
                                   │ ws-tunneled, encrypted leg
                                   v
                         macprovider-cli serve :19120 (lab build)
                                   │ loopback_origin
                                   v
                         usage tap :19131 ──> llama-server :19130 (Qwen2.5-0.5B Q4_K_M GGUF)
```

- **Model.** `Qwen/Qwen2.5-0.5B-Instruct-GGUF` @ `9217f5db79a29953eb74d5343926648285ec7e67`,
  `qwen2.5-0.5b-instruct-q4_k_m.gguf`, sha256
  `74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db` (equals the
  HF LFS oid; `macprovider.gguf-file.v1` is the plain file sha256).
- **Lab static release** (`labtool static-release`, lab ed25519 key
  `lab-1690-m6-static`): one recommendable candidate row `qwen2.5-0.5b-instruct`
  (`model_id mlx-community/Qwen2.5-0.5B-Instruct-4bit` @ `a5339a41…`), demand
  rank, rate card, and a catalog-artifacts feed whose row carries the MLX
  primary and a **verified GGUF sibling** with `source_ref.kind =
  huggingface_revision`, `repo_id`, `revision`, `file_path`, and
  `allowed_runtime_sources = ["llamacpp_loopback"]`. The MLX primary's
  `model_sha256` is a lab placeholder digest; no MLX session is ever served.
  A lab Tier-2 catalog (`scripts/sign-catalog.go`) names the same row.
- **Coordinator:** branch build, `autotune.*` feeds + `public_keys` =
  the lab key, Tier-2 observe with `require_hash_verified`,
  `verified_model_settlement_mode: enforce`, `trusted_pools.enabled` (no
  `production_activation`; roots are `launch_environment: candidate`), a
  provider token from `coordinator-cli issue-token`, per-actor
  `auth.operator_keys`.
- **Gateway:** branch build, a seeded buyer account + key,
  `features.trusted_pools` with `coordinator_authorizes: true`.
- **Lab CLI:** the branch CLI built with the lab static release compiled in
  (the generated file is swapped for the build and restored). It trusts only
  the lab key. `cli.sh` sets `CFFIXED_USER_HOME`, `TMPDIR`,
  `MACPROVIDER_CONFIG`, lifecycle, control-socket, and watchdog paths under
  `$LAB`, so every home-derived path (credentials, BYOM digest cache,
  discovery namespace, lifecycle, locks) stays in the lab.
  `credential_store: protected_file`, `enable_receipts: true`,
  `model: llamacpp:qwen2.5-0.5b-instruct-q4_k_m`, and the row pin
  `model_catalog_key` + `model_catalog_model_id`.
- **Admission:** `models offer … --yes`; the coordinator resolved the GGUF
  hash through the feed (`catalog_match_state: catalog_matched`, member
  `artifact_feed`/`gguf-q4-k-m`), then operator `lab_a` decided
  `catalog_priced`. The candidate never reaches `settlement_capable`.
- **Pools** (`pool_setup.py` + `labtool pool-root/pool-manifest`: P-256 root
  registration, Ed25519 authority log and policy signer, policy-core/v2):
  A = v2 `["llamacpp_loopback"]` enforce; B = v1; C = v2
  `["ollama_loopback"]`; E = v2 `[]`; F = v2 `["llamacpp_loopback"]` for the
  manifest bump. Creator `acct-lab-1690-creator`, member admitted without a
  delegation (creator-owned), buyer authorized, promoted.
- **Usage tap** (`usage_tap.py`): a loopback pass-through that records the
  usage and a content hash llama-server returned, and on demand strips
  `usage` (case 1b) or slows the stream (cases 5/5a).
- **Buyer:** `buyer.py` sends `X-MacProvider-Pool-Select` to the gateway.

Reproduce:

```bash
scripts/lab/1690-m6/rig.sh model && scripts/lab/1690-m6/rig.sh build
scripts/lab/1690-m6/rig.sh build-spoof     # lab-only hostile client for case 4
scripts/lab/1690-m6/rig.sh up
python3 scripts/lab/1690-m6/cases.py --spoof-binary "$LAB/bin/macprovider-cli-lab-spoof"
scripts/lab/1690-m6/rig.sh down
```

## Code defects found

Fixed on `wip/1690-m6` (one commit each):

1. **The WS-tunneled auth hello never sent `runtime_source`** (CLI). Only the
   legacy `endpoint_url` hello carried it, and `serve` is tunneled by default.
   The coordinator recorded every loopback session as native (no FR-HG8
   sandbox, no allowlist binding). Observed: `/poolz` `runtime_source: null`
   for a llama-server session. Fix: `M6-fix: declare runtime_source on the
   WS-tunneled auth hello`.
2. **A loopback serve never sent a catalog release envelope** (CLI). The
   loopback path skipped the catalog preflight, so the coordinator admitted
   the session in `legacy` mode: no artifact identity, no GGUF member pin, and
   `PoolExternalRuntimeRoutingEligible` excludes `legacy`. The
   SPEC-047-R003(iv) pool route-time member derivation could never run. Fix:
   `M6-fix: bind a pinned loopback model to its signed catalog row envelope`.
   With the row pin, the session is admitted `current`, `hash_verified`,
   bound to the candidate with the GGUF `verified_member`.
3. **The gateway reconciler rejected `pool_operator_attested` finality.**
   `finalityTokenTotals` accepted only `coordinator_observed`, and
   `usage_events.token_source` had no such value. Observed: 28 reservations
   stuck `active`/`settlement_hold=1` and `coordinator finality token_source
   "pool_operator_attested" is not settlement-capable` every 5 s. Fix:
   `M6-fix: settle pool_operator_attested finality in the gateway reconciler`
   (schema v14 widens the CHECK; the live lab DB migrated v13 to v14 and all
   28 settled on the next pass).

Found, not fixed here:

4. **`HTTPServerReceiptTests.testHTTPStreamingClientDisconnectIsBuyerCancelNotProviderFailure`
   fails deterministically** (added by `e47dc403`, M5-fix; first execution of
   the M5 Swift tests, run locally under Xcode). On the legacy HTTP path the
   `CancellationError` reaches the generic catch because
   `ResponseWriter.isClientConnected` (`channel.isActive`) is still `true`: NIO
   has not read the peer's EOF while no write is pending, so the buyer-cancel
   branch never matches (`errorsTotal` 1, no `receipt_omitted`). The
   WS-tunneled production path is not affected. The fix needs input-close
   detection on the HTTP channel. The other 203 tests in the M5 suites
   (InferenceRelay, HTTPServerReceipt, ReceiptBuilder, PoolRuntimeAuthorization,
   OpenAICompatibleLoopbackRuntime, ServeCommand) passed.
5. **Routing projects the highest accepted policy, not the active window**
   (the final audit's finding, reproduced). Pool D: v1 `["llamacpp_loopback"]`
   valid until t+240 s; v2 `[]` accepted at t with `not_before = t+240 s`.
   Immediately after acceptance, admin `get-pool` and the buyer policy show
   `manifest_version: 2`, `runtime_allowlist: []`, and a request that served
   seconds earlier (v1, attested) is refused 503 while v1 is still the active
   window.
   Case 5 uses this behaviour: the mid-flight acceptance of manifest v2 on
   pool F changed the settlement-time label at acceptance time. The disputed
   outcome itself is the correct fail-closed result; the timing of the switch
   is the bug.
6. The Swift compiler's Swift 6 diagnostics flag the streaming relay's
   batching state (`InferenceRelay.swift:990-1021`, captured `pendingContent`
   / `pendingCount` mutated in concurrently-executing code), which matches
   the audit's data-race finding. Case 6 did not observe corruption: 12
   streams at concurrency 4 matched llama-server byte for byte (content
   sha) and token for token.

## Case evidence

Sanitized. Request ids are lab ids; no prompt or completion text is kept.

### 1. Paid path

Admission (run 2): offer `catalog_matched`, member `{source: artifact_feed,
artifact_id: gguf-q4-k-m, hash_algorithm: macprovider.gguf-file.v1, hash:
74a4da8c…}`; decision `catalog_priced` by `operator:lab_a`. Session:
`runtime_source: llamacpp_loopback`, `model_hash_algorithm:
macprovider.gguf-file.v1`, `hash_status: hash_verified`,
`catalog_admission_mode: current`, bound to the candidate.

One streaming request (`dd9b63f8…`):

```
route_snapshot: pool_id=cSyqvIYmDXpePZvp_iNUVg manifest_version=1
  manifest_core_digest=3344f53d… runtime_source=llamacpp_loopback
  pool_generation=7 pool_operator_account_id=acct-lab-1690-creator
  route_snapshot_mode=enforce expected_catalog_model_hash=74a4da8c… (gguf-file.v1)
attempt:   usage_source=pool_operator_attested billable=(44,32) terminal=normal_done
verdict:   receipt_version=4 receipt_result=valid settlement_outcome=verified
           reason=verified_settlement pool_label_status=verified profile=spec015-v0.4
ledger:    provider_credits=49 quarantined=0
finality:  outcome=verified token_source=pool_operator_attested prompt=44 completion=32
upstream:  llama-server usage prompt=44 completion=32, content sha 1ec904ed… == buyer content sha
gateway:   quota_reservation settled; usage_events token_source=pool_operator_attested
```

`pool_runtime_authorization` reached the CLI: the coordinator attaches it
exactly when the snapshot's `runtime_source` is set, the CLI signs a loopback
receipt only when it matches (the runtime itself is not receipt-eligible),
and the CLI's M5 honest-bug guard, which runs only for an authorized GGUF
request, logged `pool_usage_recount` with the pool id and runtime source. In
run 1, with the sibling MLX tokenizer cached in the lab home, the recount
was `consistent` (reported 64 / recounted 64; 36 / 35). The tunneled frame is
encrypted, so the frame itself was not captured. The buyer receipt view
(`/internal/settlement/receipts`) shows the attempt `verified`/`valid` with
the route snapshot digest and receipt key fingerprint. The raw receipt is
not exposed on the tunneled path, so `phase7-verify` was not run.

The ledger charges the coordinator's bounded prompt tokens where the
provider-reported prompt exceeds the independent prompt bound (for example,
attested 45 and charged 38 in run 2; a `WARN provider reported prompt tokens
exceeded independent bound` line each time). That is the SPEC-022 R-12.4
ceiling. The receipt usage still equals the attested usage.

The CLI always calls llama-server with `stream: true` and
`stream_options.include_usage: true`, including for non-streaming buyers.

### 1b. llama-server omits usage

With the tap stripping `usage`: the non-streaming request failed 502
`upstream_provider_error` (the relay retried twice); the streaming one sent the
content, then ended without a finish chunk. Both attempts:
`usage_source=byte_estimated`, billable `(0,0)`, `terminal_state=provider_error`,
no receipt (`missing_receipt`), ledger `null_error` with credit 0, then
`quarantined` (`missing_receipt_deadline_elapsed`), and the gateway refunded.
Missing usage is never fabricated into billable usage.

### 2. Global route

`POST /v1/chat/completions` without a pool header, streaming and not, and with
`X-MacProvider-Provider` / `X-MacProvider-Pref` naming the member: all 503
`byom_non_settlement_unavailable` ("No settlement-capable BYOM provider"),
`inference_ran: false`. The route-snapshot count and the upstream tap were
unchanged.

### 3. v1 / empty allowlist / runtime not allowlisted

All three pools were `active`/`routeable`. The buyer policy disclosed
`runtime_allowlist: []` / `runtime_scope: native_mlx_only` (B, E) and
`["ollama_loopback"]` / `native_mlx_and_allowlisted_external_runtimes` (C).
Pool A disclosed `["llamacpp_loopback"]`. Every request to B, C, and E got 503
with no dispatch; pool A kept serving in between.

### 4. Spoofed hello

A lab-only client (`rig.sh build-spoof`) overrides only the auth
`runtime_source`. With `ollama_loopback` the coordinator recorded the hello value
(`/poolz` `runtime_source: ollama_loopback`), kept the session `hash_verified`,
and left it bound to the `llamacpp_loopback` candidate. The route binding
refused it on pool A (allowlisted class differs), pool C (hello allowlisted but
not equal to the signed offer), and global. With no source (the pre-fix CLI's
wire shape) the session is a native claim on a GGUF-verified pair: also refused
everywhere. No dispatch, no snapshot.

### 5. Disputed label

With a slowed stream in flight on pool F (v1), manifest v2 (same allowlist)
was accepted:

```
route_snapshot manifest_version=1 → verdict pool_label_status=label_disputed
attempt usage_source=byte_estimated billable=(0,0)
verdict receipt_result=invalid reason=usage_not_cross_checked settlement_outcome=quarantined
ledger usage_source=byte_estimated provider_credits=0 quarantined=1
       quarantine_reason=loopback_runtime_not_settlement_eligible
gateway: refunded
```

The buyer still received the full stream. 5a: adding a second member to pool A
mid-flight (a generation bump, no manifest change) stayed
`pool_operator_attested`, label `verified`, credited.

### 6. Streaming, non-streaming, concurrency

Both modes settle (case 1). With `max_concurrency` 4 (`llama-server -np 4`),
three rounds of 4 concurrent streams (up to 300 tokens): 12/12 complete with a
finish reason and `[DONE]`, and the multiset of (content sha, prompt, completion) seen by
the buyer equals the one llama-server produced, 12 of 12. 12/12 receipts are
valid and attested. In run 1, 8 concurrent streams against 4 slots gave 4
served and 4 × 503 `no_provider_available` (capacity, no queueing), plus 4
concurrent non-streaming requests all served.

## Not staged

- **A member whose provider account is not the pool creator** (a delegated
  member). It needs provider-owner delegation keys and signatures. It is
  covered by the M4 unit tests only.
- **Production.** This is the pre-merge lab rehearsal. The production run
  inside the M1 pool, with a signed journey, is the next M6 step.
- **`phase7-verify` on the raw receipt.** The tunneled path does not surface
  the raw receipt to the buyer.

## Other observations

- The gateway answered two byte-identical repeat requests from its dedupe
  cache (`X-MacProvider-Dedupe`), without routing. `buyer.py` now makes each
  prompt unique.
- `/v1/models` lists nothing for the buyer: the loopback model is not globally
  routable. Pool buyers name the row's `model_id`.
- The coordinator logs a harmless `mkdir /run: read-only file system` warning
  for its applied-config record outside Linux.
