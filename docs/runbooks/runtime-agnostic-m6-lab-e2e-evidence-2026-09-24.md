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

## Run 3 (combined code, 45d0702c)

Branch `bench/1690-loopback-vs-native` at `45d0702c`. This is the combined
tree: the M6-fix CLI commits, the final-audit fixes `35fb3767` and `88824c71`,
and the legacy HTTP disconnect fix `45d0702c`. The final audit replaced the
rig's own gateway `pool_operator_attested` / schema v14 change, which was not
merged. Coordinator, coordinator-cli, gateway, labtool, the lab CLI, and the
spoof CLI were all rebuilt from that tree on the Studio, with `mlx.metallib`
from `/Users/a1/bench-1690/run/`. The run started from scratch in
`/Users/a1/lab-1690-m6/run3`, with fresh lab keys, static release, Tier-2
catalog, provider token, buyer key, and pools. It used the same
127.0.0.1:19101-19131 ports. Every lab process was stopped at the end
(`rig.sh down`, no 191xx listener left).

`cases.py` gained three cases for the final-audit behavior, and case 5 was
rebuilt around them. Routing now uses the ACTIVE policy window, so accepting
a v2 whose window starts in the future no longer changes anything mid-flight.
The old case 5 staging became `future_manifest`. `disputed` now crosses a
real window boundary.

| Case | Result | Key evidence |
|---|---|---|
| 1. Paid path, non-streaming + streaming | PASS | 4/4: snapshot `pool_id`, `runtime_source=llamacpp_loopback`, `pool_generation=7`, `pool_operator_account_id`; receipt `4`/`valid`/`verified`; `pool_operator_attested`; credit 46-51; finality `pool_operator_attested` |
| 1a. Attested usage equals llama-server usage | PASS | attested `[(45,32),(46,32),(50,32),(50,32)]` == upstream tap, same list |
| 1b. llama-server omits usage | PASS (fail-closed) | `byte_estimated`, billable `(0,0)`, `missing_receipt`, ledger `null_error` credit 0; non-stream 502 `upstream_provider_error`, stream ended with no finish chunk |
| 2. Global route | PASS | 503 `byom_non_settlement_unavailable` ×2; no snapshot, no upstream call |
| 3. v1 / empty v2 / non-allowlisted | PASS | pools B, C, E: 503 ×6, no dispatch |
| 4. Spoofed hello | PASS | hello `ollama_loopback` and hello with no source: 503 on A, C, and global; no dispatch |
| 5. Disputed label (active manifest changes mid-flight) | PASS | pool G v1 window 45 s, v2 accepted at once; stream routed on v1 crossed the boundary: `label_disputed`, `byte_estimated`, `(0,0)`, `quarantined`, credit 0; buyer still got 200 with a full stream (134 tokens) |
| 5a. Generation bump only | PASS | generation 8, label `verified`, `pool_operator_attested` |
| 6. Streaming + non-streaming; 12 streams at concurrency 4 | PASS | 12/12 intact; buyer (content sha, usage) set == llama-server set, 12 of 12; 12/12 valid attested receipts |
| NEW: future-window v2 does not take effect early (`future_manifest`) | PASS | pool F: v2 (window starts in 30 days) accepted while a stream was in flight. That stream and a request after it both stayed manifest 1, `verified`, `pool_operator_attested`, credited |
| NEW: routing uses the active window (`active_window`) | PASS | pool D: v1 `["llamacpp_loopback"]` for 90 s, v2 `[]` accepted at once. Right after acceptance: 200 ×2, manifest 1, `verified`, attested. After v1 ends: 503 ×2 `byom_non_settlement_unavailable`, no snapshot, no upstream call |
| NEW: gateway schema v14 settles the buyer reservation | PASS | gateway `schema_migrations` max 14; `quota_reservations`: 21 `settled`, 19 `refunded`, 0 held; `usage_events` `(pool_operator_attested, spec022_verified)` = 21; zero `not settlement-capable` log lines |
| NEW: `coordinator pool-rollback-preflight` | PASS, with a finding | exit 3 during the run (`open_pool_verdicts: 4`, 8 snapshots); exit 3 still after the 300 s deadline (3 open); exit 0 once finality closed those 3 (`open_pool_verdicts: 0`, 26 snapshots) |
| NEW: legacy HTTP disconnect (`45d0702c`) | PASS | lab serve :19120, direct streaming request, client closed after 2 s: in-flight released 0.12 s after the close, `errors_total` 4 → 4, `requests_total` 26 → 27 |

Key lines:

```
paid (75a02f08…, stream): snapshot pool_id=Hf4G9uodj6kNiTjtbMroxg manifest_version=1
  runtime_source=llamacpp_loopback pool_generation=7 artifact_id=gguf-q4-k-m
  attempt usage_source=pool_operator_attested billable=(46,32) terminal=normal_done
  verdict receipt_version=4 valid verified verified_settlement pool_label_status=verified
  ledger provider_credits=50 quarantined=0
  finality closed=true outcome=verified token_source=pool_operator_attested (46,32)
disputed (pool G): snapshot manifest_version=1 -> label_disputed byte_estimated
  settlement_outcome=quarantined ledger provider_credits=0 quarantined=1
active_window (pool D): t+3 s 200,200 (v1 verified attested); t+95 s 503,503
preflight: {"pool_route_snapshots":8,"open_pool_verdicts":4,...,"rollback_blocked":true} exit=3
           {"pool_route_snapshots":26,"open_pool_verdicts":0,...,"rollback_blocked":false} exit=0
```

Run 3 findings:

- **The rollback gate can stay at exit 3 with no time bound** (in contract, an
  operational gap). The non-streaming 1b request got a 502. The gateway
  retried it 3 times (`coord retry … attempts=3`), so the coordinator made 3
  attempts under 3 request ids. The gateway refunded its reservation at once
  and never asks finality for those ids. Their `missing_receipt` verdicts
  stayed `pending`/`closed=0` long after `pending_deadline_unix_ms`, because
  the deadline quarantine is applied only when something re-reads the verdict.
  The streaming attempt, which the gateway reconciler did query, closed at the
  deadline. SPEC-022 R-12.8 says the gate exits 0 only for closed verdicts or
  past-deadline attempts with *no* verdict. So exit 3 is correct, and "wait and
  re-run" would never clear in the lab (`settlement.job_enabled: false`). One
  finality read per request id closed all three
  (`missing_receipt_deadline_elapsed`) and the gate went to exit 0. The case
  now does the same. Before a rollback, an operator has to close open,
  past-deadline pool verdicts the same way. Whether the nightly reconcile
  (`job_enabled`) closes them was not verified here.
  Resolved after run 3 (final-audit R2): the coordinator now runs a
  periodic expiry sweep (`SweepExpiredPoolSettlementVerdicts`, SPEC-022
  R-12.8) that closes these verdicts without a finality read, and the case
  now waits for the gate instead of reading finality. No operator step is
  needed. This run's evidence predates the sweep.
- Resolved from the earlier findings: 4, with `45d0702c` (legacy HTTP
  disconnect; the XCTest runs in CI only); 5, active-window routing
  (`future_manifest`, `active_window`); and the reconciler's
  `pool_operator_attested` settlement at schema v14.
- Harness flake, seen once: the first `pool_setup.py create F` exited 1 after
  the coordinator had applied every event through `promote`, and before the
  script wrote `pool_id`. The error text was lost because stderr was
  captured. The pool (`kdDER_2bE_4ULjoK_VEO-Q`, active, member and buyer
  present) was reused as F. Pools G, D, and H were created cleanly.

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

## M7: buyer engine selection (run 4, 71b8b8b2)

**Branch:** `wip/1690-m7` at `71b8b8b2` (M7a `20f606c9` SPEC-006 0.9.34 /
SPEC-042 0.0.33, M7b gateway + coordinator). Coordinator, coordinator-cli,
gateway, labtool, and the lab CLI were rebuilt from that tree on the Studio
(`rig.sh build`). The run started from scratch in `/Users/a1/lab-1690-m6/m7`
with fresh lab keys, static release, Tier-2 catalog, provider token, buyer
key, and pool A (v2, `runtime_allowlist = ["llamacpp_loopback"]`), on the
same 127.0.0.1:19101-19131 ports. The only member of pool A is the
llama-server member; there is no native member in the rig.

`buyer.py` gained `--engine SEL`, which sends `X-MacProvider-Engine-Select`
and reports the response's `X-MacProvider-Engine`. `cases.py` gained six
cases. Command:
`cases.py --only paid global engine_llamacpp_pool engine_llamacpp_global engine_native_pool engine_ollama_pool engine_absent engine_invalid`.
Every check passed. The M6 `paid` and `global` cases were re-run first as the
baseline.

| Case | Result | Key evidence |
|---|---|---|
| `engine=llamacpp` on pool A | PASS | 2/2 served (non-stream + stream), `X-MacProvider-Engine: llamacpp_loopback`; snapshot `runtime_source=llamacpp_loopback`, `pool_generation=7`, `pool_operator_account_id`; receipt `valid`/`verified`; `pool_operator_attested`; credit 46 and 49; finality `pool_operator_attested`; attested `[(43,32),(44,32)]` == llama-server usage |
| `engine=llamacpp` on a global route | PASS (refused) | 2/2 503 `engine_unavailable` from the gateway before reservation; 0 upstream calls, 0 route snapshots |
| `engine=native` on pool A (only a llama member) | PASS (refused) | 2/2 503 `engine_unavailable` from the coordinator (no session of class `mlx_cache` in scope); 0 upstream calls, 0 snapshots; never served by llama.cpp |
| `engine=ollama` on pool A (allowlist `llamacpp_loopback` only) | PASS (refused) | 2/2 503 `engine_unavailable` (class outside the active allowlist); 0 upstream calls, 0 snapshots |
| No header | PASS (unchanged) | pool A: 200, attested, `verified`, and the served class is still disclosed (`llamacpp_loopback`); global: 503 `byom_non_settlement_unavailable`, the unchanged M6 case 2 refusal |
| Unknown selector (`LLAMACPP`, `vllm`) | PASS (refused) | 2/2 400 `invalid_engine_selection`; 0 upstream calls |

**Coordinator enforces independently of the gateway.** A direct request to the
coordinator buyer port (service-token bearer, lab account, no pool) with
`X-MacProvider-Internal-Engine: llamacpp_loopback` got 503
`engine_unavailable`. With the selector name `native` instead of a runtime
class it got 400 `invalid_engine_selection`.

**Baseline.** `paid`: 4/4 attested, verified, with a ledger credit, and
attested usage equal to llama-server usage `[(46,32),(46,32),(47,32),(48,23)]`.
`global`: 2/2 503 `byom_non_settlement_unavailable`.

**Not staged.** A native member and a llama member in the same pool, where
each selection picks its own class (covered by the coordinator test
`TestSPEC042R014MixedPoolHonoursEachSelection`); pinned and slot-queue
engine refusals (unit tests); Ollama serving (M8).

**Teardown.** Each lab PID's command line was checked against
`/Users/a1/lab-1690-m6/m7` (or `usage_tap.py` on 1913x) before a TERM. The
live provider (PID 811) was not touched, and no 191xx listener was left.

## M8: more engines, mlx_lm.server and Ollama (run 5, f6b34f61)

**Branch:** `wip/1690-m8` at `f6b34f61` (M8a `31e2db0a` SPEC-010 1.12 R009 /
SPEC-023 v0.17.0 / SPEC-042 0.0.34 / SPEC-046 0.3.0 / SPEC-006 0.9.35 /
SPEC-047 0.2.1 / SPEC-032 v0.3.1; M8b the CLI leg, coordinator and gateway).
Everything ran on the Mac Studio. Coordinator, coordinator-cli, gateway,
labtool, and the lab CLI were rebuilt from that tree (`rig.sh build`). The run
started from scratch in `/Users/a1/lab-1690-m6/m8` with fresh lab keys, a
fresh static release, Tier-2 catalog, provider token, and buyer key, on the
same 127.0.0.1:19101-19131 ports. Only one model server ran at a time.

**Lab release.** Row `qwen2.5-0.5b-instruct`, `model_id`
`mlx-community/Qwen2.5-0.5B-Instruct-4bit`, `model_revision`
`a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3`. The row's `model_sha256` is now
the real snapshot-manifest digest of that snapshot
(`1bbee07a0dea46fa6d970fe2f3cebac9da287ba614d02d3319c945e886c0f4ea`, the
M6 placeholder is gone). Its primary artifact allows
`["mlx_cache","mlxlm_loopback"]` (SPEC-023 v0.17.0). Two GGUF siblings: the
M6 llama.cpp file (`huggingface_revision`, `llamacpp_loopback`), and the
Ollama `qwen2.5:0.5b` model blob (`ollama_library_tag`, digest
`sha256:c5396e06af294bd101b30dce59131a76d2b773e76950acc870eda801d3ab0515`,
397807936 bytes, `ollama_loopback`). The coordinator loaded the feed without
an integrity failure.

**Engines.**

- mlx_lm.server: `mlx-lm` 0.31.3 in `/Users/a1/lab-1690-m6/m8/venv`
  (Python 3.12), serving the snapshot downloaded into
  `$LAB/models/mlx/Qwen2.5-0.5B-Instruct-4bit` (`.cache` removed). `HF_HOME`
  is `$LAB/home/hf`, and `HF_HUB_OFFLINE=1`.
- Ollama: the macOS release binary, 0.34.4, in `$LAB/ollama`, with
  `OLLAMA_MODELS=$LAB/ollama-models`. `qwen2.5:0.5b` was pulled with a
  lab-only `ollama serve` on 19130, which was stopped by its recorded
  identity. Nothing was installed system-wide.

**Rig changes.** `ENGINE=llamacpp|mlxlm|ollama` picks the one server behind
the usage tap, the served ref (`mlxlm:<snapshot dir name>` or
`ollama:qwen2.5:0.5b`), the offer command, and the engine's pool (A
llamacpp, M `mlxlm_loopback`, O `ollama_loopback`). The provider config's
`model:` line changes per engine, and the protected credentials stay as
imported. `rig.sh server-start|server-stop` restarts only the model server.
labtool takes `--mlx-runtime-sources` and an optional Ollama artifact.
`cli.sh` exports `MACPROVIDER_MLXLM_MODEL_PATH` (default is the catalog
snapshot, overridable with `MLXLM_SNAPSHOT`), `MACPROVIDER_MLXLM_ORIGIN` (the
tap), and `OLLAMA_MODELS`. Two rig fixes came out of the run:

- mlx_lm.server answers `GET /v1/models` with a 200 header and an empty body
  when its Hugging Face cache directory does not exist. The CLI then
  correctly refused the origin (`loopback origin does not answer as
  mlxlm_loopback`). The rig now creates `$HF_HOME/hub`.
- Ollama keeps the upstream connection alive with a chunked body. The tap
  read the raw socket to EOF, so it served the CLI but never logged usage.
  It now reads the decoded body (`resp.readline()`). The llama.cpp paid case
  was re-run on the fixed tap.

**Commands.**
`ENGINE=mlxlm rig.sh up`, then
`cases.py --only mlxlm_paid mlxlm_refused mlxlm_identity_mismatch`
(25/25 PASS), `rig.sh down`, then `ENGINE=ollama rig.sh up`, then
`cases.py --only ollama_paid ollama_refused` (21/21 PASS). Last,
`ENGINE=llamacpp rig.sh up` and `cases.py --only paid engine_llamacpp_pool`
(26/26 PASS) confirmed that the rig default and the M6/M7 path are
unchanged.

| Case | Result | Key evidence |
|---|---|---|
| mlx_lm.server pool member, `engine=mlxlm` on pool M | PASS | 4/4 served (2 non-stream, 2 stream), `X-MacProvider-Engine: mlxlm_loopback`. Session `runtime_source=mlxlm_loopback`, `macprovider.snapshot-manifest.v1`, `hash_verified` (the row's own pair, through the SPEC-047 v0.2.1 `candidate_row` member). Snapshot `runtime_source=mlxlm_loopback`, `pool_generation`, `pool_operator_account_id`, enforce. Receipt v4 `valid`/`verified`, `pool_label_status=verified`; `pool_operator_attested`; credits 46/33/49/50; finality `pool_operator_attested`. Attested `[(44,32),(44,32),(50,16),(50,30)]` == mlx_lm.server usage |
| mlxlm member on pools without `mlxlm_loopback` (A llamacpp, O ollama) and global | PASS (refused) | `engine=mlxlm`: 503 `engine_unavailable` on A, O, and global. No header: 503 `byom_non_settlement_unavailable` on A, O, and global. 0 upstream calls, 0 route snapshots |
| MLX snapshot not in the catalog | PASS (fails closed) | mlx_lm.server restarted on a clone of the snapshot plus one extra file (manifest `29c1cd24...`). The CLI reported that pair and the session is `hash_mismatch`. Pool M refused both `engine=mlxlm` and no header with 503, 0 upstream calls, 0 snapshots. The coordinator appended `revoked` / `runtime_identity_drift` for the `catalog_priced` candidate (SPEC-047-R006). Restoring the catalog snapshot alone stayed refused. A fresh offer, priced again, restored the paid path: 200, `pool_operator_attested`, `verified` |
| Ollama pool member, `engine=ollama` on pool O | PASS | 4/4 served, `X-MacProvider-Engine: ollama_loopback`. Session `ollama_loopback`, `macprovider.gguf-file.v1`, `hash_verified` (the `ollama_library_tag` member). Snapshot `runtime_source=ollama_loopback`, `pool_generation=20`. Receipt v4 `valid`/`verified`; `pool_operator_attested`; credits 33/48/49/50; finality `pool_operator_attested`. Attested `[(44,18),(44,32),(47,32),(50,32)]` == Ollama usage |
| Ollama member on pools without `ollama_loopback` (A, M) and global | PASS (refused) | `engine=ollama`: 503 `engine_unavailable` on A, M, and global. No header: 503 `byom_non_settlement_unavailable`. 0 upstream calls, 0 snapshots |
| llama.cpp regression on the M8 rig | PASS | `paid` 4/4 and `engine=llamacpp` 2/2 attested, `verified`, usage equal to llama-server |

**Usage re-count guard.** `pool_usage_recount` was `consistent` for all 10
mlxlm pool requests: the CLI re-counts with the tokenizer inside the served
snapshot itself. For the GGUF runtimes it was `tokenizer_unavailable` (no
cached sibling snapshot at the lab Hugging Face path). The guard is
check-and-alert only, so settlement is unaffected either way.

**Not staged.** A hello that claims `mlxlm_loopback` while its verified pair
is a GGUF member is covered by the coordinator test
`TestSPEC010R009MLXLMClaimServingGGUFFailsClosed` (no member binds), not the
lab. The spoof binary was not rebuilt for M8. Pinned and slot-queue refusals
for the new classes reuse the M7 code path and its unit tests. LM Studio and
oMLX are not implemented: neither has an identity leg (SPEC-010-R009(e),
SPEC-046-R009).

**Teardown.** `rig.sh down` stopped every lab process by its recorded,
re-verified identity. No `lab-1690-m6/m8`, `mlx_lm.server`, `ollama serve`,
or 191xx listener was left. The live provider (PID 811,
`/Users/a1/macprovider/`) was not touched.
