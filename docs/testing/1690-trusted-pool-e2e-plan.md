# #1690 fake-Pearl VM end-to-end test plan (engine-agnostic Trusted Pools, delivered-only billing, signed settlement finality)

Goal: find bugs in the #1690 settlement changes by **running the real
coordinator and gateway binaries on a Pearl-shaped host and executing
`docs/runbooks/trusted-pool-production-launch.md` section 9 literally**, the
way the #1693 pricing lane found its deploy blockers on a real-host VM tier.
No further audit rounds; every failure here is a bug until shown otherwise.

Harness: `test/e2e-1690/`. Evidence of a run: `/root/e2e/evidence/` in the VM
(copied to `$E2E_WORK/evidence.tgz` on the host by `run-all.sh`).

Run it from the host with the inputs set (`test/e2e-1690/env.sh` requires
them; nothing host-specific is hardcoded):

```bash
export E2E_STUDIO=<ssh host holding the branch under test>
export E2E_STUDIO_WT=<that branch worktree path on E2E_STUDIO>
export E2E_CANON=<local checkout with the baseline ref, default origin/main>
export E2E_WORK=<host scratch dir, default $TMPDIR/e2e-1690-work>
bash test/e2e-1690/00-setup-vm.sh && bash test/e2e-1690/01-sources.sh
bash test/e2e-1690/run-all.sh 2 ABC
```

## Hard boundaries

- The fake Pearl is the Lima VM `macprovider-1690` (x86_64 Ubuntu 26.04 under
  qemu, 4 CPU, 6 GiB, same image as `macprovider-1693`). **Every build and test
  runs inside the VM.** The Mac host runs only `limactl`, `ssh`, file copies and
  one outside-the-host `curl` (the nginx 503 check).
- Never touched: `macprovider-1693`, `macprovider-540`, Pearl, the Studio's
  live provider, GitHub (no push, no PR, no issue). The Studio worktree is only
  read (`git bundle create`).
- Every key is generated inside the VM (`/root/e2e/keys`, never printed).

## Code under test

| side | tree | tag in the VM repo |
|---|---|---|
| old (production baseline, v1.8.193, gateway schema 13) | `origin/main` of the canonical checkout | `v1.8.193` |
| new (#1690) | Studio `bench/1690-loopback-vs-native` HEAD (`d5dd3334` at the time of these runs) | `v1.8.194` |

Both are built in the VM with the repo's own `make build-linux`
(`ALLOW_NON_RELEASE_COORDINATOR_BUILD=1`: the scratch tags are not the protected
signed release tags).

## Host shape (what makes it Pearl-like)

- systemd `macprovider-coordinator` and `macprovider-gateway` with the units
  from each tree's `dist/`; `/opt/macprovider`, `/etc/macprovider/*.env`
  (0640 root:macprovider), `/var/lib/macprovider`;
- coordinator on `127.0.0.1:8443` (buyer mux) / `:8444` (provider + admin),
  live config `/opt/macprovider/coordinator.yaml` rendered from the tree's
  `phase4-coordinator/dist/coordinator.yaml` (`lib/live-config.py`: stats and
  app-track onboarding off, Pearl's `request-log.sqlite` db path, pinned fake
  providers) plus the Pearl overlay; **`settlement.verified_model_settlement_mode:
  enforce` as in production**; the committed, production-signed static
  catalog release under `/opt/macprovider/autotune/releases/<id>` + `current`;
  Postgres with the SPEC-017/026 schema (the coordinator opens it at start);
- billing store as in production: the SQLite ledger shares
  `/var/lib/macprovider/request-log.sqlite` with the request log;
- gateway on `127.0.0.1:9443`, SQLite `/var/lib/macprovider/gateway.db`,
  reaching the coordinator directly at `http://127.0.0.1:8443` (no nginx on
  that hop); deployed **only** by the real `phase5-gateway/dist/deploy-pearl-vps.sh`
  run from inside the VM against `root@127.0.0.1` (the operator lane), with a
  `dig` shim and `/etc/hosts` pinning `api.malibu.tech` to the VM;
- nginx on 443 with the repo's `nginx-api.malibu.tech.conf` (installed by that
  deploy script), a test CA at the Let's Encrypt paths, Pearl's shared
  http-context zones (`ws_provider_*`, `buyer_conn`);
- buyer traffic always enters through nginx (`https://api.malibu.tech`).

### Fake providers

`fakeprov/` is the #1693 fake (a port of the integration harness provider;
real `/ws/provider` v2 auth, catalog identity from the live coordinator feeds,
SPEC-015 v0.4 receipts), extended for #1690:

- configurable response shape (`-stream-chunks`, `-chunk-delay-ms`,
  `-nonstream-delay-ms`) so a buyer can disconnect mid-stream or before a
  non-streaming body; receipt content always equals the delivered content;
- **loopback pool member** (`loopback.go`): `-runtime-source llamacpp_loopback`,
  a GGUF model identity (`-model-hash-algorithm macprovider.gguf-file.v1`), a
  durable admission key enrolled through the v2 identity signature, and
  `fakeprov offer` (the signed model-admission offer). No real engine is
  needed: every coordinator check is identity, signature and exact usage.

`faultproxy/` sits between the gateway and the coordinator (gateway
`coordinator.buyer_url` pointed at it) and rewrites only chat 200 finality:
`pass`, `strip-trailers`, `strip-outcome` (MAC kept), `tamper` (flip the
reason), `drop-after-body` (abort after the body, before the trailers). The
mode is read per request from `/run/e2e-faultproxy/mode`.

## Oracle (checked after every traffic run, `tools/oracle.py`)

Traffic (`tools/loadgen.py`) records each request's UUID `X-Request-ID` and
kind: `ns` non-streaming, `st` streaming read to `[DONE]`, `st_dc` buyer
disconnects after 3 SSE events, `ns_dc` buyer closes the socket before the
non-streaming response. After the reconciler drains (the runbook's own
`POST /admin/settlement/reconcile`, until no reservation of the run is active
and no hold remains), the oracle joins gateway rows (`quota_reservations`,
`usage_events`) with coordinator rows (`request_log.external_request_id` ->
`ledger_request_credits`, `spec022_payable_request_credits`,
`settlement_receipt_verdicts`, `settlement_attempt_outputs`):

- I1 no reservation left `active`, no `settlement_hold=1`;
- I2 `settled` => usage row total == `settled_tokens`; refunded => no debit;
- I3 buyer debit tokens == provider payable tokens (debit without payable
  evidence, or payable without a debit, both fail);
- I4 under enforce, no payable 200 credit outside enforce evidence;
- I5 no verdict left open past its pending deadline (reported, not blocking:
  a `ns_dc` 502 attempt keeps an open `missing_receipt` verdict, see F-7);
- EXPECT per-kind reservation outcome where the scenario states one.

`tools/compare-shape.py` compares per-kind outcome shapes against the
baseline for the "must behave exactly like the baseline" pairings.

## Scenarios

| id | script | what |
|---|---|---|
| S1 | `vm/s1-baseline.sh` | old coordinator + old gateway, all four kinds |
| S2 | `vm/s2-rollout.sh` | runbook s9 step 0 (drain recovery), step 1 (new coordinator; pools none on a fresh host), traffic new coordinator + OLD gateway vs baseline shape, step 2 (real gateway deploy, schema 14), traffic + finality probe (trailers + MAC), step 2a (pin on), traffic, hold count |
| S3 | `vm/s3-newgw-oldcoord.sh` | new gateway + OLD coordinator vs baseline shape; then pin on against the old coordinator (every 200 held) and every hold must still terminate |
| S4 | `vm/s4-faults.sh` | faultproxy modes x pin off/on; coordinator store failure after delivery (exclusive SQLite lock while a non-streaming attempt records after its write) |
| S5 | `vm/s5-pool.sh` | after S2: lab-signed static release with a GGUF member, loopback fake member, signed offer, operator `catalog_priced` decision, runbook s4 pool order with a v2 policy core (`runtime_allowlist: llamacpp_loopback`, settlement enforce), gateway trusted-pool feature, pool traffic (expect `pool_operator_attested`), global traffic, gateway-rollback pre-check (must forbid), pools paused + `pool-rollback-preflight` |
| S6 | `vm/s6-rollback.sh` | runbook s9 rollback, literally: nginx 503 (+ outside curl from the Mac), drain holds, pin off, gateway pre-check, stop, named snapshot + binary, export rows after the snapshot, recipe restore without start, re-apply, start; coordinator preflight + rollback; resume; no ledger row lost or duplicated; post-rollback traffic |

`run-all.sh [passes] [chains]` runs, per pass and each from a fresh bootstrap:
chain A = S1, S2, S4, S6; chain B = S3; chain C = S1, S2, S5. Merge gate as in
#1693: every scenario green on two consecutive full passes, or each failure
filed as a finding with a repro.

## Deviations and harness limitations (not tested here)

- H1 coordinator deploy: installed by a binary swap that mirrors the deploy
  (`.prev`, ownership, the tree's unit, graceful restart), not by the 4.9k-line
  `phase4-coordinator/dist/deploy-pearl-vps.sh` or the Pearl updater (both need
  signed release tags, GitHub release assets and a catalog canary Mac; #1690
  does not change them; the #1693 harness exercises them). So "confirm the
  updater transaction committed" is not testable here.
- H2 S5 catalog: production's static release has no catalog-artifacts feed or
  GGUF member, so S5 installs a lab-signed release (the Studio lab `labtool`,
  keys generated in the VM) and re-points `autotune`/`tier2` at it.
- H3 S5 pool is `launch_environment: candidate`; runbook sections 1-3 and 5-7
  (on-call authority, production_activation evidence, lifecycle owner, timing
  floor) are out of scope.
- H4 provider CLI (runbook s9 step 3) is the fake; real engines are covered on
  the Studio.
- H5 `settlement.pending_deadline_seconds` stays at production's 300 s, so every
  run that has a disconnected stream waits ~5 min for its verdict to close.

- H6 pass 1 chain C (S5) ran before two harness fixes (pool member must
  advertise `tier2_capabilities.trusted_pool_v1`; pool setup must survive F-5)
  and is invalid; chain C was re-run as passes 3 and 4.

## Results (branch head d5dd3334, baseline 27a1bb14)

Evidence: `$E2E_WORK/evidence-pass1-2.tgz`, `$E2E_WORK/results-pass1-2.jsonl`
(every assertion, with the oracle's failing rows inline) and
`$E2E_WORK/evidence-pass3-4.tgz` on the host (not committed); `/root/e2e/evidence/` in the VM.
Passes 1-2 ran chains A, B, C each from a fresh bootstrap. Caveat: in passes
1-2 chains A and C both wrote `p<pass>s1*`/`p<pass>s2*` oracle files, so those
files hold chain C's copy; `results-pass1-2.jsonl` holds both (fixed for later
runs: run ids now carry the chain, e.g. `p1As2b`).

Oracle codes: I3 buyer debit != provider payable, I6 debit on a non-200,
EXPECT delivered request not settled, I5 (non-blocking) verdict left open.

| scenario | 1A | 1C | 2A | 2C | finding |
|---|---|---|---|---|---|
| S1 old/old baseline | PASS | FAIL I6 | FAIL I6 | FAIL I6 | F-3 (pre-existing); 1A's `ns_over` hit a busy 503, not the 502 path |
| S2 step 0 recovery drained | PASS | PASS | PASS | PASS | F-9 |
| S2 step 1 new coordinator `/healthz` | PASS | PASS | PASS | PASS | updater txn untestable (H1) |
| S2 new coord + OLD gw | PASS | FAIL I3 I6 | FAIL EXPECT I6 | FAIL I3 I6 | F-4, F-3 |
| S2 same, outcome shape == baseline | PASS | FAIL | FAIL | FAIL | only the F-4 row differs |
| S2 step 2 real gateway deploy, schema 14 | PASS | PASS | PASS | PASS | F-8 |
| S2 new/new | FAIL I6 | FAIL EXPECT I6 | FAIL I6 | FAIL I6 | F-3, F-4 |
| S2 negotiated 200 has trailers + MAC | PASS | PASS | PASS | PASS | |
| S2 step 2a pin on | FAIL EXPECT I6 | FAIL I6 | FAIL I6 | FAIL I6 | F-3, F-4 |
| S2 step 2a no missing-finality holds | PASS | PASS | PASS | PASS | |
| S4 pass / strip-outcome / tamper, pin off and on | PASS | | PASS | | |
| S4 strip-trailers, pin off | FAIL I3 | | FAIL I3 | | F-2 |
| S4 strip-trailers, pin on | PASS | | PASS | | |
| S4 drop-after-body, pin off and on | FAIL I3 | | FAIL I3 | | F-1 |
| S4 store failure after delivery (x2) | PASS | | PASS | | |
| S6 nginx 503 on buyer routes, healthz 200 | PASS | | PASS | | outside-host curl: 1A not recorded (host driver hung), 2A `503` |
| S6 drain, pin off, gw pre-check, export, restore, re-apply, start | PASS | | PASS | | F-10 |
| S6 coordinator preflight | literal fails, `/opt` path rc 0 | | same | | F-6 |
| S6 coordinator rollback, old healthy on migrated DB | PASS | | PASS | | |
| S6 no ledger/gateway rows lost or duplicated | PASS | | PASS | | F-12 |
| S6 traffic after rollback | FAIL I3 I6 | | FAIL I6 | | F-4 (on the OLD coordinator), F-3 |

| scenario | 1B | 2B | finding |
|---|---|---|---|
| S3 old/old re-baseline | FAIL I6 | FAIL I6 | F-3 |
| S3 new gw + OLD coord | FAIL I6 | FAIL I6 | F-3 |
| S3 shape == old/old | PASS | PASS | |
| S3 pin on vs OLD coord: every hold terminal | PASS | PASS | F-11 |

S5 (chain C): pass 1 invalid (H6). Pass 2: offer PASS, `catalog_priced`
decision PASS, pool create PASS (after F-5), pool traffic settles as
`pool_operator_attested` PASS (6 of 10 pool requests 503: F-13), global
traffic PASS, gateway-rollback pre-check forbids rollback PASS (3 rows),
`pool-rollback-preflight` exits 0 with pools paused PASS.

Pass 3C (pool traffic 2 buyers wide): offer, decision, pool create (F-5
again), pool traffic 10/10 with the oracle clean (`ns`/`st` settled 28 = 28
payable, disconnects refunded), `pool_operator_attested` on every settled pool
request, global traffic PASS, gateway-rollback pre-check forbids (9 rows),
`pool-rollback-preflight` rc=3 right after pause (`open_pool_verdicts: 1`)
then rc=0 after the pending window. S1/S2 in 3C: same F-3/F-4 pattern as
passes 1-2. Pass 4C was stopped during S2 at the wrap-up request and is not
counted. S5 is therefore green on two runs (2C, 3C) apart from F-5 and F-13.

## Findings

Severity is about money correctness and operator safety on Pearl. "#1690"
means introduced or made reachable by the branch; "pre-existing" means the
same result on the old/old pair.

**F-1 MEDIUM, code (#1690 delivered-only premise).** A non-streaming 200 whose
body reached the gateway hop but whose connection broke before the trailers:
the buyer gets 502 and is refunded, the provider credit is verified and
payable. Repro: S4 `drop-after-body`, pin off and on, both passes, 3/3
non-streaming requests each (`p{1,2}s4dropafterbodypin{f,t}.oracle.json`:
`ns:refunded:debit=0:pay=28`). Root cause: the coordinator records after a
successful socket write and treats that as delivered
(`phase4-coordinator/internal/buyer/settlement_trailers.go` negotiated
record-after-write), while the gateway refunds on any body-read error without
consulting finality or telling the coordinator
(`phase5-gateway/internal/router/chat_proxy.go:982-987`,
`forwardNonStreamingChat`, unchanged since origin/main). Any hop reset
(coordinator or gateway restart mid-write) pays the provider for an undelivered
response.

**F-2 MEDIUM, code + runbook.** With the pin off (runbook s9 step 2, before
2a), stripping the trailer declaration on a stream downgrades to the
gateway's byte estimate: completed streams debited 74 tokens against 28
observed and payable; a mid-stream disconnect (normally refunded) debited 50
with no provider credit. Repro S4 `strip-trailers` pin off, both passes
(`p{1,2}s4striptrailerspinf.oracle.json`). Root cause: for a stream with a
route snapshot the negotiating coordinator sends finality only as trailers,
no header tuple (`phase4-coordinator/internal/buyer/settlement_trailers.go:117`
`prepareStreamingSettlementFinality`); the gateway without the pin treats an
undeclared response as legacy (`phase5-gateway/internal/router/settlement_trailers.go:147`,
`:209`), and a buyer who closes right after `[DONE]` (before upstream EOF) is
classified `client_disconnect` (`chat_proxy.go:1754` -> `settleCancelled`,
`:1370`) and billed the byte estimate even though reported usage was read.
Runbook `docs/runbooks/trusted-pool-production-launch.md:244` says a proxy that
drops trailers makes the gateway hold `missing_settlement_finality_trailer`
"(fail closed)"; that is only true after step 2a. Pin on: PASS both passes.

**F-3 MEDIUM, code, pre-existing (not #1690).** A buyer who receives 502
`invalid_provider_usage` (provider returned more completion tokens than
`max_tokens`) is debited the coordinator-verified usage. Repro: `ns_over`
kind (max_tokens 16, fake returns 20) in every pairing including old/old
(`p1s3base`, `p2s1`: `I6 buyer got HTTP 502 but was debited 28 tokens`).
Root cause: `chat_proxy.go:1079-1083` calls `settleWithFinality(promptEstimate,
0, ...)`, but verified coordinator finality overrides the local numbers, so
the full coordinator usage is debited before the 502 is written; the
coordinator also verifies a receipt whose completion exceeds `max_tokens`.

**F-4 MEDIUM, code, pre-existing race.** `settlement_attempt_outputs` insert
fails fast with `database is locked (5)` / `(517)` (SQLITE_BUSY /
SQLITE_BUSY_SNAPSHOT) at 4 concurrent buyers: 5 of ~330 requests on the new
coordinator (1A S2c, 1C S2a, 1C S2b, 2A S2a, 2C S2a) and 1 of ~140 on the old
one (1A S6 after rollback), so the race predates #1690. Root cause:
`phase4-coordinator/internal/billing/settlement_output.go:408` opens a deferred
transaction, reads (overlap SELECT) and then writes; a writer on another
handle to the same file (`routeSnapshotDB`,
`phase4-coordinator/cmd/coordinator/main.go:254`) commits in between and the
upgrade fails without honouring busy_timeout; the in-call retry
(`internal/buyer/billing_recorder.go:689-706`) loses too. Effect: old gateway
pairing (and old/old after rollback) debits the buyer while the enforce credit
is never payable (2C S2a, 1A S6 after rollback: `debit=28:pay=0`); a negotiating gateway
gets the evidence-failure refund, so a delivered response is unbilled on both
sides (1A S2c, 1C S2b, 2A S2a streaming: log `database is locked (517)` then `buyer_finality: refund`). Fix direction: `BEGIN IMMEDIATE` on a dedicated conn (as
`internal/billing/quarantine.go:150` does) or retry the whole transaction on
517.

**F-5 MEDIUM, code (#1690 made it worse).** Trust-pool admin writes answer
`500 registry_refresh_failed` for an event that is already durable, and the
whole routing registry is disabled until the next refresh. Repro: S5 pool
creation, 3 of 3 attempts (1C: root event; 2C: promote; 3C: an event;
`p1-s5`, `p2-s5`, `p3C-s5/pool-create.txt`), with `trusted_pools.refresh_interval_s: 1`.
Root cause: check-then-act in `phase4-coordinator/internal/trustpool/admin_handler.go:1770-1788`
(`refreshRegistryIfAhead` reads `Registry.Revision()` unlocked, then
`LoadRouteableSnapshotsAtRevision`), racing the periodic refresher; the load
treats an equal revision as an error (`internal/trustpool/registry.go:754`).
The race exists on origin/main; #1690 added `h.deps.Registry.Disable()` on
that path (`admin_handler.go:1779`, `:1784`), turning a harmless race into an
all-pools routing outage plus a 500 that makes an operator script abort
mid-sequence (the runbook s4 order). Fix: treat revision <= current as
already published inside the lock.

**F-6 LOW, runbook + code.** Runbook rollback command
`coordinator pool-rollback-preflight --config /etc/macprovider/coordinator.yaml`
(`trusted-pool-production-launch.md:377`) names a file that does not exist on
Pearl (live config `/opt/macprovider/coordinator.yaml` + overlay
`/etc/macprovider/coordinator.pearl-overlays.yaml`): rc=1 `open
/etc/macprovider/coordinator.yaml: no such file`. The subcommand has no
`--config-overlay` (`flag provided but not defined`), so it cannot evaluate
Pearl's effective config; with `--config /opt/macprovider/coordinator.yaml`
and the env file it exits 0 as documented (S6 and S5, both passes).

**F-7 LOW, pre-existing.** A non-streaming attempt that ends 502 because the
buyer hung up first (`ns_dc`) leaves a `settlement_receipt_verdicts` row
`pending/missing_receipt` open forever (every run, old and new); the expiry
sweep closes only pool verdicts.

**F-8 LOW, script/runbook, pre-existing.** `phase5-gateway/dist/deploy-pearl-vps.sh`
step 2c always refuses (exit 4) because the gateway `/healthz` has no
`in_flight_requests`; every s9 gateway deploy needs `FORCE_RESTART=1` and
writes `/var/lib/macprovider/last-deploy-bypass.json`. Runbook step 2 does not
say so.

**F-9 LOW, runbook.** Step 0 gives no command to trigger or confirm the
ledger-recovery drain; the startup scan logs only on failure
(`cmd/coordinator/main.go:2119`). Step 1 "resume the pools" names no command
(resume is `promote` after `set-lifecycle paused`).

**F-10 LOW, runbook.** Gateway rollback step 6 "reconcile daily quota totals"
has no referent: the gateway has no totals table (quota derives from
`usage_events`/`quota_reservations`). The step 4 export list omits
`audit_events`, `signup_events`, `feedback_events`, `public_issuance_events`,
`settlement_fallback_candidates`, `settlement_reconcile_attempts`; their
post-snapshot rows are lost by the restore. The literal procedure otherwise
worked: 187-188 rows re-applied, every gateway count and token sum identical
after the rollback, both passes.

**F-11 INFO, runbook.** Rollback step 3 says that with the pin on "every 200"
of an older coordinator "would be held". Observed: held, then settled
correctly within seconds by the reconciler's finality lookup (S3 pin-on, both
passes). Turning the pin off first is still right, but the stated hazard is
milder than written.

**F-12 INFO.** After the coordinator rollback, the old coordinator's startup
scan inserts ledger rows (`recovery_source=startup_scan`) for new-coordinator
attempts whose post-delivery record failed (S4 store-failure); none is payable
under enforce, so no money moves (both passes).

**F-13 LOW, code, pre-existing (SPEC-042).** A pool whose only member is busy
answers the non-retryable `pool_no_eligible_member` instead of queueing or a
retryable busy error: with 4 concurrent buyers against a 2-slot member, 6 of
10 pool requests got 503 (`p2s5pool`). Root cause:
`phase4-coordinator/internal/buyer/server.go:7313`: the non-members dropped by
the pool filter make `ReasonPoolNotMember > 0` even when the member was only
slot-limited.

## Resolution

Each finding was re-checked against `origin/main` at `8d6e99ee` (the VM
tested `d5dd3334`, which predates the Studio e2e fixes merged in
`747557cc`); all thirteen were still present. Fixes are on branch
`feat/1690-m1-catalog-gguf`, one commit per finding (subject prefix
`#1690 VM F-<n>`), each with a regression test that fails without it.

| id | still on origin/main | resolution |
|---|---|---|
| F-1 | yes | fixed `b0010777`: a 200 that declared finality trailers and whose body read fails is held as `missing_settlement_finality_trailer`, not refunded; the reconciler settles it to the coordinator's finality. Streaming already held. Test `TestDropAfterBodySettlesToCoordinatorFinality` (real wire, pin on/off, verified/quarantined). |
| F-2 | yes (by design until the pin) | runbook `32f10d7c`: s9 step 2 says the hold is fail-closed only for dropped trailer values until step 2a; a stripped declaration settles from headers or the byte estimate. The pin (on in production) is the code fix. |
| F-3 | yes | carried. The coordinator verified the receipt and credited the provider; refunding the buyer on the gateway's own `max_tokens` check would make buyer and provider disagree the other way. The right fix is coordinator-side (refuse or cap a receipt whose completion exceeds `max_tokens`, and send refund finality), a SPEC-022 receipt-validation change that needs the spec first. Pre-existing on old/old. |
| F-4 | yes | fixed `07ae2d56`: `InsertSettlementAttemptOutput` runs under `sqliteutil.Transact` (BEGIN IMMEDIATE), the money-path pattern. Test `TestInsertSettlementAttemptOutputSurvivesConcurrentRouteSnapshotWriter` (50-70 of 160 inserts fail without it). |
| F-5 | yes | fixed `ec395367`: `Registry.PublishRouteableSnapshotsIfAhead` checks and replaces under one lock; an equal or older revision is a no-op success, so the refresher race no longer 500s or disables the registry. Tests `TestAdminHandler_RefresherRaceIsNotARefreshFailure`, `TestRegistryPublishRouteableSnapshotsIfAheadIsIdempotent`. |
| F-6 | yes | fixed `dbbb1b6a`: `pool-rollback-preflight --config-overlay`; runbook s9 gives the exact command (`/opt/macprovider/coordinator.yaml`, the Pearl overlay, the env file) and the step 4a feed check reads the same files. Test `TestPoolRollbackPreflightHonorsConfigOverlay`. |
| F-7 | yes | carried. The open `pending/missing_receipt` verdict of a native (non-pool) `ns_dc` 502 moves no money (the buyer is refunded, no payable credit) and only the pool expiry sweep closes verdicts. Closing native verdicts is a SPEC-022 verdict-lifecycle change for all traffic; it needs the spec and its own review, not a VM follow-up. |
| F-8 | yes | fixed `000986d4`: deploy step 2c falls back to counting in-flight (active, unheld, unexpired) reservations in the live gateway DB, read-only, and still fails closed on any error. Test `phase5-gateway/dist/test/gateway_deploy_inflight.test.sh` in `make test-dist`. |
| F-9 | yes | runbook `af2b94d3`: step 0 states there is no admin trigger (startup scan at every start, nightly at 00:00 UTC) and gives the read-only 7-day missing-ledger-row check that must print 0; step 1 names pause (`set-lifecycle paused`) and resume (`promote`). |
| F-10 | yes | runbook `e5b3e0cd`: the gateway rollback export lists every durably written table from the gateway schema (adds `audit_events`, `signup_events`, `feedback_events`, `public_issuance_events`, `settlement_fallback_candidates`, `settlement_reconcile_attempts`, `demo_session_events`, `wallet_identities`, `capacity_signal_events`, `relay_blind_replays`, `runtime_config`) and names the ones deliberately skipped; the non-existent "reconcile daily quota totals" step is gone. The harness `tools/gw-rollback-export.py` is kept as run. |
| F-11 | yes | runbook `e061942c`: rollback step 3 says pin-on 200s of an older coordinator are held and then settled by the reconciler, and why the pin still goes off first. |
| F-12 | yes | carried (INFO). The old coordinator's startup scan backfills ledger rows for new-coordinator attempts whose post-delivery record failed; under enforce none is payable, so no money moves. Expected recovery behaviour. |
| F-13 | yes | carried. The pool path does queue a busy member (`slotQueueCandidates` applies the pool gates). The 503s came from public-traffic overflow shedding (`splitQueuedCandidates` drops a provider whose advertised `slots_free` is positive but already reserved; the fake always advertises `slots_free: 2`), after which the non-member count makes the answer the terminal `pool_no_eligible_member` where global traffic gets the retryable `no_provider_available`. Changing that mapping is a SPEC-042 R005/R010 error-contract change; it needs the spec first. |

