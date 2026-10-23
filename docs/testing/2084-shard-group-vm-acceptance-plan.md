# #2084 fake-Pearl VM acceptance plan (SPEC-051 shard groups on Trusted Pools)

Goal: find the deploy blockers and wire bugs of the #2084 campaign (SPEC-051
v0.2.5, PR #2108) by running the real coordinator and gateway binaries on a
Pearl-shaped host, a Trusted Pool whose signed policy names a shard group,
fake providers that speak the real SPEC-051 wire with real Ed25519 keys, and
a real Swift head and member on one Mac. This replaces further audit rounds,
the way #1690, #1693 and #1816 found their deploy blockers on a VM. Every
failure is a bug until shown otherwise.

Harness: `test/e2e-2084/`, which extends `test/e2e-1690/` (shared lib:
bootstrap, `fakeprov`, `loadgen.py`, `oracle.py`, `live-config.py`, gateway
deploy, in-VM `lib*.sh`) and `test/e2e-1816/` (`tools/pool-models.py`,
`tools/pool-oracle.py`, `lib-1816.sh`). Evidence of a run: `/root/e2e/evidence/`
in the VM, copied to `$E2E_WORK/evidence.tgz` and `$E2E_WORK/results.jsonl` on
the host; scenario R writes `$E2E_WORK/real/evidence/`.

## Run it

```bash
# fake-provider chain (B1 B2 U P F), one pass, VM created if missing
bash test/e2e-2084/run-all.sh 1
# acceptance: a fresh VM, then two full passes in a row
E2E_FRESH_VM=1 bash test/e2e-2084/run-all.sh 2
# scenario R (real Swift head + member on this Mac) after a pass left the new pair:
E2E_REAL_CLI=<dir with the lab-harness release macprovider-cli> bash test/e2e-2084/host/r-real.sh
```

`run-all.sh` starts or creates the Lima VM `macprovider-2084`
(`lima-macprovider-2084.yaml`, x86_64 Ubuntu 26.04 under qemu, 4 CPU, 8 GiB,
the image of the #1690 VM), ships `origin/main` and the code under test with
`git archive` (`01-sources.sh`; without `E2E_NEW_REF` the code under test is
the checkout's working tree through `git stash create`, so an uncommitted fix
is tested exactly as it will land), pushes the harness (`02-push-harness.sh`)
and runs the in-VM driver `vm/run-passes.sh` under `systemd-run`.

The lab-harness CLI for scenario R is built on the Studio from the branch
(`swift build -c release -Xswiftc -DMACPROVIDER_LAB_HARNESS`, `nice -n 10`,
`--jobs 4`) and copied here with its `mlx-swift_Cmlx.bundle`.

## Hard boundaries

- Every coordinator and gateway build, key, service and fake provider runs
  inside the VM. The host runs `limactl`, `git archive`/`stash create`, file
  copies and, for scenario R only, the two real `macprovider-cli serve`
  processes, which reach the VM through the loopback-only Lima forwards
  `127.0.0.1:28444` (coordinator provider listener) and `127.0.0.1:29443`
  (gateway).
- Never touched: Pearl, GitHub, the Studio's live provider (the Studio only
  builds and runs CPU tests), the admin Air.
- The live provider on this Mac is paused for scenario R only
  (`live-ctl.py pause`), after 0 requests in flight, with an EXIT trap and an
  independent 900 s watchdog that resume it; the run waits for
  `network_state: buyer_serving` again. It is never stopped or restarted.
- Every key is generated in the VM (`/root/e2e/keys`, `/root/e2e/pools84`,
  the fake providers' receipt and admission seeds) or, for scenario R, by the
  CLI's own `credentials import` into a scratch protected-file store. Nothing
  is printed.

## Code under test

| side | tree | VM tag |
|---|---|---|
| old (production baseline) | `origin/main` | `v1.8.210` |
| new (#2084) | `shard/2084-pipeline-lan` working tree | `v1.8.211` |

Both are built in the VM with the repo's own `make build-linux`
(`ALLOW_NON_RELEASE_COORDINATOR_BUILD=1`).

## Host shape

Everything in the #1690 plan's "Host shape" holds: systemd units from each
tree's `dist/`, the `macprovider` service user, `/opt/macprovider`,
`/etc/macprovider/*.env` (0640 root:macprovider), the live
`coordinator.yaml` rendered from the tree (`lib/live-config.py`) plus the
Pearl overlay, `settlement.verified_model_settlement_mode: enforce` and payout
disabled as in the tracked config, the SQLite ledger in
`/var/lib/macprovider/request-log.sqlite`, Postgres with the SPEC-017/026
schema, the gateway deployed only by the real
`phase5-gateway/dist/deploy-pearl-vps.sh`, nginx on 443 with a test CA, buyer
traffic through `https://api.malibu.tech`. The coordinator is installed by the
deploy-shaped binary swap of the #1690 harness (H1 there).

## Fake shard providers

`test/e2e-1690/fakeprov` gains (`shard.go`):

- `-ws-relay`: inference over the WebSocket tunnel (no `endpoint_url`, plain
  frames), the path every real provider and every shard head uses
  (SPEC-051-R015 item 1, R016 "never over HTTP-direct forwarding");
- `-shard-role head|member`, `-shard-group FILE`, `-shard-knobs FILE`: the
  SPEC-051-R029 messages from a shared group file every process of the group
  re-reads each second (a changed record is an epoch bump or takeover), with
  per-process fault knobs (heartbeat/health/hello withheld, member unhealthy,
  link interface and RTT, record overrides, attestation fault modes,
  pre-first-token and mid-stream failure, delays);
- the head signs the record, the v0.4 receipt, the group attestation and each
  member's sub-receipt with that member's receipt key (all seeds are local in
  the VM); a member session counts and refuses any buyer work; the head counts
  dispatches and dispatches while its last `shard_group_status` was not
  available; all of it is on `/v1/status` under `shard`.

Identities: `e2e-prov-11` head (group provider identity, stage 0),
`e2e-prov-12` stage-1 member, `e2e-prov-13` spare, `e2e-prov-14` a second
owner's Mac; every completed response is 8 prompt and 12 completion tokens.

## Scenarios

| id | script | what |
|---|---|---|
| B1 | shared `vm/20-bootstrap.sh` | fresh old/old Pearl-shaped host |
| B2 | `vm/21-bootstrap-2084.sh` | tokens for the fake group and the scenario-R providers, SPEC-003 ownership claims (D2) |
| U | `vm/u-rollout.sh` | SPEC-051-R027 coordinator first: old/old traffic; new coordinator on the production SQLite file (startup migration creates the three shard tables, no row lost), old gateway traffic; rollback rehearsal (old coordinator on the migrated file serves); new gateway through the real deploy script; new/new traffic |
| P | `vm/s-pool.sh` | trusted pools config, pool S through the real creator/admin paths with a native entry and `pool_shard_groups/v1` (coordinator-cli `--pool-models` with `shard_groups`), R030 disclosure in `pool_policy.json`/`pool_status.json`, the head's signed model-admission offer binds the pool entry, registration, member and spare hellos, durable record and bindings, group available |
| F1 | `vm/s-fake.sh` | paid pool traffic served by the head and settled at the entry price (pool oracle), a verified stored attestation per receipt, members never routed |
| F2 | | never global (pool model id or execution label), member pin and head pin on a global route refused |
| F3 | | R015 reasons: `member_unhealthy`, `link_interface_invalid` (head and member view), `link_rtt_exceeded`, `member_self_unhealthy`, `member_session_missing`, `owner_mismatch`, `member_not_admissible`, `group_heartbeat_stale`, `member_health_stale`; each refuses pool traffic without a dispatch and recovers; a spare's health and session never gate |
| F4 | | R019 faults: `attestation_missing`, `head_signature_invalid`, `receipt_mismatch`, `digest_chain_break`, `coverage_invalid` (member counts, and R3-A1: receipt output above `step_end`), `stage_mismatch`, `key_mismatch`, `member_signature_invalid`, `epoch_unknown`, `segments_invalid`, `takeover_invalid`; the stored verdict, fault member and that the receipt is not verified; a buyer cancel's terminal is attested |
| F5 | | R021 pre-first-token failure (no debit, zero-credit attempt), R022 mid-stream failure (debit at most prompt + delivered) |
| F6 | | slot queue: a 2-slot head serves a queued third stream; a group that goes unavailable while a request is queued is not dispatched |
| F7 | | R3-C03/R3-A2: a record naming another pool model than the bound entry must not route |
| F8 | | R028: rotation removes the group from the extension (refused, disclosure omitted), then restores it (served) |
| F9 | | coordinator restart with a stream in flight: same epoch re-registered without a new row, available, served, attested; the epoch floor survives the restart |
| F10 | | SIGHUP of `shard_groups` (applied or refused with a log line, never silently ignored) |
| F11 | | catalog traffic unchanged; members never dispatched |
| F12 | | epoch bump with a withheld hello (`member_not_joined`), takeover by the spare with a verified takeover attestation, the 12-per-hour registration budget (refused epoch not stored), epoch retention |
| R | `host/r-real.sh` + `vm/r-pool.sh` | real Swift head + member on this Mac (lab loopback interconnect), pool R, the head's `models offer`, a paid non-streaming and streaming request through the VM gateway, attestation verified and stored, route snapshot at the pool model; member killed mid-stream and before the first token |

## Deviations and harness limitations

- D1 the coordinator is installed by the #1690 deploy-shaped binary swap (H1
  of that plan), not the Pearl updater.
- D2 SPEC-003 ownership claims are seeded as the rows the GitHub claim flow
  writes (`github_identities`, `provider_ownership`); the VM cannot reach
  GitHub OAuth.
- D3 relay-blind and privacy-class requests need a SPEC-041/049 client; their
  exclusion of shard sessions is covered by buyer unit tests and recorded as a
  GAP, not driven here.
- D4 `trust_label_above_member` needs a member on a lower provider tier than
  the head; the fake sessions are all provisional, so it is covered by
  `TestEvaluateAvailability`, not driven here.
- D5 the head signs its members' sub-receipts with their keys (all local in
  the VM): the coordinator sees exactly the wire a real group sends; the real
  chain is scenario R.
- D6 scenario R runs both roles on one Mac over loopback, which SPEC-051-R007
  does not admit; `serve --lab-loopback-interconnect` (DEBUG and lab-harness
  builds only, refused unless the join is isolated against a loopback
  coordinator) reports the loopback stage link as `thunderbolt`. The
  coordinator is unchanged.
- D7 scenario R's pool binding uses the harness offer tool (`fakeprov offer`,
  as the #1690/#1816 runs did) signed with each real session's enrolled
  admission identity, because the CLI's own `models offer` accepts only a
  `wss://`/`https://` coordinator; the lab copy is served by its path because a
  pool entry is admitted only for a model id that is not a catalog id.

## Results

Acceptance run: the code under test was `shard/2084-pipeline-lan` at
`f343aaab7` plus the uncommitted `cmd/coordinator/main.go` reload call. The
baseline was `origin/main` `8a44d3f44`. The run used a fresh VM
(`E2E_FRESH_VM=1 bash test/e2e-2084/run-all.sh 2`) and made two full passes in
a row. Evidence: `$E2E_WORK/evidence.tgz` and `$E2E_WORK/results.jsonl` on the
host, `/root/e2e/evidence/` in the VM. Scenario R ran on the state the second
pass left; its evidence is in `$E2E_WORK/real/evidence/`.

**Merge gate: met.** Both passes had 61 PASS, 0 FAIL and 1 GAP, and their
results were identical. The GAP is D3. Each pass also had three INFO lines:
the time to rebind after a restart, epoch retention, and the summary.

| scenario | pass 1 | pass 2 |
|---|---|---|
| U rollout: old/old traffic, new coordinator healthy, migration creates the three shard tables with no row lost, new coordinator + old gateway, old coordinator on the migrated DB (rollback), real gateway deploy, new/new traffic | PASS (7) | PASS (7) |
| P pool S through creator/admin with `pool_shard_groups/v1`, R030 disclosure in `pool_policy.json` and `pool_status.json` (no provider id), head pool binding, registration and hellos, group available, durable record and bindings | PASS (6) | PASS (6) |
| F1 paid pool traffic at the entry price (oracle), a verified attestation per 200, a buyer that closes at `[DONE]` still settled, members never routed | PASS (4) | PASS (4) |
| F2 never global (pool model id, execution label), member pin, head pin on a global route | PASS | PASS |
| F2 relay-blind / privacy-class | GAP (D3) | GAP (D3) |
| F3 the R015 reasons `member_unhealthy`, `link_interface_invalid` (head view and member view), `link_rtt_exceeded`, `member_self_unhealthy`, `member_session_missing`, `owner_mismatch`, `member_not_admissible`, `group_heartbeat_stale` and `member_health_stale`: each refuses without a dispatch and recovers. A spare's health and session never gate | PASS (11) | PASS (11) |
| F4 R019 faults `ok`, `missing`, `bad_head_signature`, `receipt_mismatch`, `chain_break`, `coverage`, `stage_mismatch`, `wrong_key`, `member_signature`, `unknown_epoch`, `two_segments`, `takeover_bad_reason` and `coverage_tokens_out` (R3-A1). Each stores the right verdict and fault member, and no receipt is verified. A buyer-cancel terminal is attested | PASS (14) | PASS (14) |
| F5 R021: no debit and a zero-credit attempt. R022: debit at most the prompt plus the delivered tokens | PASS (2) | PASS (2) |
| F6 slot queue serves a queued head; a group that goes unavailable while a request is queued is not dispatched | PASS (2) | PASS (2) |
| F7 a record that names another pool model does not route (R3-C03) | PASS | PASS |
| F8 the extension is removed by rotation (refused, disclosure omitted), then restored | PASS (2) | PASS (2) |
| F9 coordinator restart with a stream in flight: same epoch with no new row, attested; the epoch floor survives | PASS (2) | PASS (2) |
| F10 SIGHUP of `shard_groups` applied (`link_rtt_exceeded`) | PASS | PASS |
| F11 catalog traffic unchanged; members never dispatched | PASS (2) | PASS (2) |
| F12 `member_not_joined`, epoch bump, takeover attestation (verified, `from_group_epoch` and reason stored), budget refuses the 13th new epoch before storing it | PASS (5) | PASS (5) |

Scenario R, a real Swift head and member on this Mac, ran on the final VM
state:

| check | result |
|---|---|
| pool R with the group in its signed core; both real sessions bind `catalog_priced` to the entry | PASS |
| real group registered (epoch from the head's durable epoch state), member hello accepted, group available | PASS |
| paid non-streaming and streaming requests through the VM gateway with `X-MacProvider-Pool-Select`: 200 with real model output, attestation `verified`, receipt `valid/verified`, ledger credited to the head at the entry rates, route snapshot at the pool model, gateway `settled` | PASS |
| member killed while serving | covered by the earlier run that found V-5: the head failed before the first token, giving one zero-credit `502/breaker_qualifying` attempt, then a buyer `503`, refunded (R021). In the final run the 3B model finished the prompt (9 tokens) before the kill, so it settled as a normal completion. R022 accounting is covered by F5 |
| member down before the first token | buyer `503 pool_no_eligible_member`, no attempt, refunded |
| live provider | paused at 0 in flight, resumed by the EXIT trap, `buyer_serving` again within 70 s in every R run (each window about 6 min) |

### Findings and fixes

Each finding was fixed on the branch with a regression test that fails without
the fix.

| id | sev | found by | finding | fix |
|---|---|---|---|---|
| V-1 | HIGH (deploy blocker) | P | `coordinator-cli trust-pool-admin sign-manifest`, the runbook's only signer, could not encode `pool_shard_groups/v1`, so no creator could authorize a group | `e6b5f5305` |
| V-2 | MEDIUM | F3 | a disconnected session stays in the pool registry as unavailable for the disconnect grace period. A spare that went away made its group unavailable for that window and the route re-check refused the head; a dropped active member was reported `member_not_admissible` | `0ec96572f` |
| V-3 | HIGH (money, every WS-tunnelled provider, pre-existing) | F1 | a buyer that closes the moment it reads the final `[DONE]` lost the provider's terminal frame, so the delivered stream was refunded as a missing receipt and the provider went unpaid. Three races caused it: the buyer handler cancelled on the disconnect; the relay dropped a `complete` terminal for a retired request; and the relay's delivery goroutine chose at random between handing the terminal to `Done` and the buyer context ending | `a2cfb166f`, `8622b7451`, `1faac2fb7`, `f343aaab7` |
| V-4 | MEDIUM | F10 | a SIGHUP that changed `shard_groups` was neither applied nor refused | `74f678629` + the `cmd/coordinator/main.go` reload call (uncommitted, secret hook) |
| V-5 | HIGH (deploy blocker) | R | a real group on a pool entry was never available, because the hello admission sandbox of a pool-entry identity failed the group evaluation, which used the global predicate where the pool route uses the pool one | `b825699c5` |
| R3-A1 | MEDIUM | F4 `coverage_tokens_out` | coverage read a legacy `tokens_out` that real v0.4 receipts lack | `fc00cc487` |
| R3-C03 / R3-A2 | MEDIUM | F7 | the route gate ignored the accepted record's `pool_model_id` | `8c1ac5b10` |
| R3-C06 | LOW | unit | reason precedence was evaluated per member, not per condition | `0ec96572f` |
| R3-C01, R3-C02, R3-C04, SEC-11, R3-C05 | MEDIUM/LOW | Swift unit scenarios (Studio CPU suite, run against the pre-fix source first) | stage fit, replay deadline, `</think>` split, deadline cadence, strict answer parsing | `b94e4fc98`, `3cda2d52d`, `d4d8333b6`, `3cda2d52d`, `d487299fa` |
| harness | n/a | B1 | the shared autotune install lacked the artifact-feed catalog files the tracked config now requires | `fc39f21d9` |

SPEC-051 v0.2.6 (`d8446ad8b`) records the contract side of R3-A1, R3-C03, V-2
and V-4. The lab-only loopback interconnect for scenario R is `20038f307`.

### Observations, carried

- O-1: after a coordinator restart, a pool-bound head is routable again only
  once the pool binding sweep rebinds it. The measured delay was 2 s (F9
  INFO). This is pre-existing #1816 behaviour.
- O-2: the #1690 F-13 slot-queue shedding still applies when a provider's
  advertised `slots_free` is stale. F6 passes once the provider reports a slot
  change at once, as the fake head now does.
- O-3: a non-settlement request, such as the model-admission known-answer
  probe, carries a legacy receipt without `request_id`. A head cannot attest
  it, so the coordinator drops that receipt. No money moves.
- O-4: on pool-entry routes the response `model` field carries the provider's
  local served label. In scenario R that was the lab copy's path. This is
  pre-existing.
- O-5: a pool entry is admitted (the `pool_entry` mode) only for a model id
  that is not a catalog id, and every group member needs its own pool binding.
  The group operator runbook must state both. `models offer` refuses a
  non-TLS coordinator (D7).
- O-6: the in-memory registration budget restarts with the coordinator. The
  re-registration of the current epoch after a restart counts as a new epoch.
- R3-A3: the owner cache delays ownership changes by up to 30 s. Carried, as
  in the PR body.
- D3 and D4 remain GAPs, covered by unit tests.
