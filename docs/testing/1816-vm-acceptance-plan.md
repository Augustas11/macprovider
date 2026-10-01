# #1816 fake-Pearl VM acceptance plan (pool-scoped models, artifact-feed catalog rollout)

Goal: accept #1816 (pool-scoped trust for non-catalog models, and the first
artifact-feed-bound catalog release) by **running the real coordinator,
gateway and Pearl updater on a Pearl-shaped host** and executing
`docs/runbooks/pool-scoped-model-admission.md`,
`docs/runbooks/catalog-artifact-feed-release.md` and the rollback in
`docs/runbooks/trusted-pool-production-launch.md` section 9 literally, the
way the #1690 VM harness did for trusted pools.

No audit rounds; every failure here is a bug until shown otherwise.

Harness: `test/e2e-1816/`, which extends `test/e2e-1690/` (the shared lib:
`fakeprov`, `loadgen.py`, `oracle.py`, `compare-shape.py`, the gateway and
live-config renderers, the in-VM `lib*.sh`, bootstrap, S1 and the s9
rollback). Evidence of a run: `/root/e2e/evidence/` in the VM, copied to
`$E2E_WORK/evidence.tgz` and `$E2E_WORK/results.jsonl` on the host by
`run-all.sh`.

Run it from the host. The ref under test is an input; nothing host-specific
is hardcoded:

```bash
export E2E_NEW_REF=<#1816 commit-ish in this checkout, e.g. feat/1816-fixA>
export E2E_OLD_REF=origin/main          # default: the production baseline
export E2E_WORK=<host scratch dir>      # default: $TMPDIR/e2e-1816-work
bash test/e2e-1816/run-all.sh 2         # two full passes, every scenario
bash test/e2e-1816/run-all.sh 1 "B1 B2 S1 S2"   # a subset (chain order)
```

`run-all.sh` starts the VM (`00-setup-vm.sh`), ships both trees with
`git archive` (`01-sources.sh`), pushes the harness (`02-push-harness.sh`),
and starts the in-VM driver `vm/run-passes.sh` under `systemd-run`, then
waits and copies the evidence back.

## Hard boundaries

- The fake Pearl is the Lima VM `macprovider-1690` (x86_64 Ubuntu 26.04 under
  qemu, 4 CPU, 6 GiB), reused from #1690. **Every build and test runs inside
  the VM.** The Mac host runs only `limactl`, `git archive` and file copies.
- Never touched: Pearl, GitHub (no push, no PR, no issue, no release
  download), the Studio's live provider, and the Lima VMs `macprovider-1693`
  and `macprovider-540` (`env.sh` refuses them).
- Every key is generated inside the VM (`/root/e2e/keys`) and never printed:
  operator and service secrets, the test CA, the P-256 test release key, the
  canary SSH key, the provider-owner Ed25519 key, every pool key
  (`/root/e2e/pools16/<pool>/cli-keys`).

## Code under test

| side | tree | VM tag |
|---|---|---|
| old (production baseline; Pearl runs runtime v1.8.209) | `$E2E_OLD_REF`, default `origin/main` | `v1.8.210` |
| new (#1816) | `$E2E_NEW_REF` | `v1.8.211` |

Both are built in the VM with the repo's own `make build-linux`
(`ALLOW_NON_RELEASE_COORDINATOR_BUILD=1`; the scratch tags are not signed
release tags), so `coordinator --version` prints the scratch tag the updater
compares against `embedded_version`.

## Host shape

Everything in the #1690 plan's "Host shape" holds (systemd units from each
tree's `dist/`, `/opt/macprovider`, the live `coordinator.yaml` rendered from
the tree plus the Pearl overlay, `settlement.verified_model_settlement_mode:
enforce`, the SQLite billing store in `request-log.sqlite`, the gateway
deployed by the real `phase5-gateway/dist/deploy-pearl-vps.sh`, nginx on 443
with the test CA, buyer traffic always through `https://api.malibu.tech`).
#1816 adds (`vm/21-bootstrap-1816.sh`):

- the `coordinator.malibu.tech` vhost **as Pearl has it**: the baseline tree's
  `nginx-coordinator.malibu.tech.conf` with the two `/v1/catalog-artifacts`
  blocks removed (Pearl's live vhost lags the repo), the shared stats
  snippets the coordinator deploy installs into `conf.d`, and the
  http-context zones it references;
- the Pearl updater's host prerequisites: `monitor.env`, the disabled
  buyer-canary posture (the real `canary-buyer` units installed but disabled,
  the empty root-owned `DISABLED` sentinel), the stats billing mirror unit at
  its pinned path, the archive-rotate units, and
  `/opt/macprovider/.pricing-runtime-floor` (the #1693 transaction has run on
  Pearl, so the floor check is live);
- a stand-in for the Better Stack heartbeat API (`uptime.betterstack.com`
  pinned to the VM, TLS from the test CA, `tools/fake-betterstack.py`),
  which records every GET/PATCH;
- the **catalog canary**: a fake CLI (`fakeprov serve`) run as the user
  `e2ecanary` from a LaunchAgent-shaped plist, reached by the updater over
  real `sshd`, which streams the real `ops/pearl-updater/catalog-canary-proof.py`
  to it (`lib/launchctl` answers `launchctl print`; `lsof` is the system one).
  It follows the coordinator's live catalog (`-catalog-from-coordinator`).

### Fake providers

`fakeprov` (shared with #1690) gains, for #1816:

- `-omit-catalog`: no `catalog_*` hello envelope (an uncatalogued pool-model
  member); `-trusted-pool`: `tier2_capabilities.trusted_pool_v1` without a
  `runtime_source` (a native `mlx_cache` member);
- `fakeprov offer -artifact-hash-algorithm -artifact-hash
  -requested-disclosure-class`: the signed model-admission offer for a GGUF
  (`macprovider.gguf-file.v1`) or a snapshot (`macprovider.snapshot-manifest.v1`)
  identity; the offer key is the admission key enrolled by the v2 identity
  signature;
- `/v1/status` reports `catalog.state: live_verified` as the real CLI does.

Members: `e2e-prov-3` llamacpp_loopback with a non-catalog GGUF hash
(creator-owned, pool Q); `e2e-prov-4` native `mlx_cache` with a non-catalog
snapshot hash (pool QN); `e2e-prov-5` llamacpp_loopback, a **non-creator**
member admitted under a signed SPEC-043 `ProviderPoolDelegationV1` grant, its
owner account in `trusted_pools.provider_owner_account_ids` and its
provider-owner key in `provider_owner_public_keys`. A completed response is
always 8 prompt and 20 completion tokens.

### Pools (`tools/pool-models.py`)

Every core is signed by the reviewed `coordinator-cli trust-pool-admin
sign-manifest --encoding 2 [--pool-models FILE]` of the NEW tree; the tool
never encodes a core. It follows the runbook order (creator approval, root
nonce, `pool_created`, signed root, genesis manifest with the staged
`pool_model_entries/v1`, members, buyer, promote) and records a manifest only
once the coordinator accepts it. Windows are `E2E_POOL_WINDOW_S` (120 s): a
**window keeper** re-signs each pool's staged entries into the next window
50 s before the active one ends, so rotation is continuous and an entry
change activates within about one window (runbook section 3: "a new entry
takes effect when the new window starts").

## Oracle

`tools/pool-oracle.py` runs the shared #1690 oracle (I1 no reservation left
active or held, I2 debit shape, I3 buyer debit == provider payable, I4 no
payable credit outside enforce evidence, I6 no debit on a non-200, EXPECT)
and then, for every pool-model request, checks against the entry the harness
signed, with the expected credits computed **independently** of the
coordinator: entry rates from what the creator signed, tokens from what the
fake reports, multiplier and provider share from the live config, through the
SPEC-005 formula with round-half-even:

```
gross    = rhe((P*prompt_rate + C*completion_rate) * multiplier_ppm, 10^12)
provider = rhe(gross * share_bps, 10^4)
```

- P5 one payable ledger row, credited to the expected member;
- P6 `gross_credits` and `provider_credits` equal the expectation;
- P7 ledger rates equal the entry's;
- P8 gateway debit = P + C, `token_source` (`pool_operator_attested` loopback,
  `coordinator_observed` native);
- P9 `settlement_attempt_outputs.usage_source` (same values);
- P10 a verdict `verified` with `pool_label_status=verified`;
- P11 route snapshot `expected_model_hash_source=pool_manifest`, the entry's
  `pool_model_id`, `runtime_source` (the loopback class; null for native by
  contract), the entry's completion rate;
- P12 ledger `usage_source=provider_reported` (the #1750 contract);
- `--zero-credit`: no payable provider credit and no debit (revocations in
  flight); `--refused`: non-200, no debit, no credit, no route snapshot.

## Scenarios

| id | script | what |
|---|---|---|
| B1, B2 | shared `vm/20-bootstrap.sh`, `vm/21-bootstrap-1816.sh` | fresh old/old Pearl-shaped host, then the #1816 host state above |
| S1 | shared `vm/s1-baseline.sh` | old coordinator + old gateway, catalog traffic, all four kinds; the reference shape |
| S2 | `vm/s2-updater.sh` | deploy order gateway-first (old coordinator + new gateway, catalog shape == S1); the new tree's updater bundle; `--plan`; **rollback rehearsal**: `--apply` with the canary Mac down, the updater's transaction rollback must restore `current`, the exact config bytes and the binaries; the real `--apply` of the artifact-bound activation release with a buyer probe running: config gets `catalog_artifacts_path`/`_sig_path`, live release `published-2026-10-01-artifact-feed-activation-v1`, the dead-man paused and restored, the pricing floor admits both binaries, the restart order and what a buyer sees in the mixed window; `/v1/catalog-artifacts` 200 and byte-identical through nginx after the runbook's manual additive step; the real canary proof over ssh (`live_verified`); catalog traffic shape == S1; `test_pearl_updater.py` and the deploy guard tests of the new tree |
| S3 | `vm/s3-pool-models.sh` | runbook config (`trusted_pools` with `pool_model_pricing_bounds`, `provider_owner_account_ids`), pools Q and QN, signed offers bind `catalog_priced` with a `pool_binding`, `get-pool`, `/poolz`, the pool `/v1/models` view, disclosure headers, pool-model traffic of all four kinds through nginx for both members (oracle above), never global; **deploy order coordinator-first** (new coordinator + old gateway) with pool models live: holds and settlement, catalog shape == S1, then holds settle once the new gateway is back |
| S4 | `vm/s4-refusals.sh` | global route; other pool; out-of-bounds price; catalog overlap (artifact-feed GGUF, catalog MLX snapshot; blocked identity is a GAP); unset bounds (manifest and route); non-attested non-creator member (never bound, refused when it is the only server, no credit); runtime outside the allowlist; runtime/format pairing. Each fails closed |
| S5 | `vm/s5-rotation.sh` | rotation keeping the entry under continuous traffic (zero non-200, all settle, `pool_manifest_rebound`); a future-dated core changing the price (current price billed until it activates, then the new one); R016 attestation (binds, paid) and its removal in flight (zero credit, then refused); member revocation in flight (zero credit, then refused); entry removal in flight (settles at the snapshot price, then refused, `pool_manifest_entry_revoked`); SIGHUP of bounds and owner accounts (applies or is refused clearly) |
| S6 | `vm/s6-rollback.sh` | runbook section 7 (pause with an attempt in flight, paused pool refused, catalog untouched, retire after pause); the coordinator rollback preflight with pool-model extension cores present must refuse a target that cannot replay them; the shared #1690 s9 rollback, literally; what the old coordinator does with the extension cores |

`run-all.sh [passes] [steps]` runs, per pass, every step from a fresh
bootstrap. Merge gate: every scenario green on two consecutive full passes,
or each failure filed as a finding with a repro in the Findings section.

## Deviations and harness limitations

- D1 updater inputs: `--source-dir` (test mode,
  `MACPROVIDER_UPDATER_TESTING=1`) instead of the GitHub release assets, and
  the outer P-256 release signature is the VM test key
  (`PEARL_UPDATER_TEST_PUBLIC_KEY`). The catalog files are the tree's
  production-signed bytes, verified by the updater's own catalog checks and
  `catalog-release.py verify-directory`. Test mode also makes the updater's
  trusted gid its egid, so it runs as root with the `macprovider` egid
  (`setpriv`), which reproduces production ownership.
- D2 Better Stack and the canary Mac are VM stand-ins (above); the canary is
  the fake CLI, not `macprovider-cli`.
- D3 the updater cannot roll back after a successful apply (no rollback mode;
  an older `--tag` is refused as a downgrade). "Rollback through the updater"
  is therefore its own transaction rollback, forced before the real apply by
  keeping the canary down; the post-apply rollback is the runbook's (S6).
- D4 the blocked artifact-feed identity (catalog overlap) is not exercised:
  the signed activation release has no blocked row. It needs a lab-signed
  release.
- D5 pools are `launch_environment: candidate`, windows 120 s (production
  uses long windows); runbook sections on production activation evidence are
  out of scope, as in #1690 H3.
- D6 the S5 SIGHUP check edits the live config in place and restores it with
  a restart.
- D7 the updater's `catalog-release.py verify-directory` call has a hardcoded
  30 s timeout and the unchanged verifier takes ~36 s under qemu TCG. The
  harness runs the real verifier first without a timeout and the python3
  shim on the updater's PATH replays that exact output only when every
  catalog file, the Tier-2 config and the verifier are byte-identical
  (`tools/verify-cache.py`); a miss runs the real verifier.
- D8 runtime allowlist and runtime/format pairing errors are refused offline
  by `coordinator-cli sign-manifest` (the runbook's only signer) before
  anything is sent, so the coordinator's own `pool_model_entry_runtime_*`
  codes are not reached (that would need a hand-encoded core).
- D9 `test_pearl_updater.py` has one test that reads a pinned commit with
  `git show`; the VM trees are `git archive` copies, so that test is a GAP.
- D10 the catalog canary is a real provider of the catalog model and serves
  catalog traffic too (3 completion tokens per response, so some catalog
  debits are 11 tokens; the shape oracle compares outcomes, not amounts).

## Results

Acceptance: `a1e059632` (`feat/1816-pool-scoped-models`, fixers A and B),
two full passes, baseline `origin/main` `65ee6791`. Pending (running).

### Shakedown (harness debug, `e7964a233`, baseline `65ee6791`)

One chain, run in pieces while the harness was fixed (S2 twice). Evidence on
the host: `$E2E_WORK/evidence-shakedown-e7964a233.tgz`,
`$E2E_WORK/results-shakedown-e7964a233.jsonl`. Harness faults found and fixed
during the shakedown (none of them is a product finding):

| fault | fix |
|---|---|
| the coordinator vhost includes stats snippets and a cache dir the coordinator deploy installs | `21-bootstrap-1816.sh` installs them as the deploy does |
| the updater's catalog verifier call has a hardcoded 30 s timeout; the unchanged verifier takes ~36 s under qemu TCG | D7: `tools/verify-cache.py` + `lib/python3-shim` replay the REAL verifier's output for the exact verified bytes |
| `gateway.yaml` was macprovider-owned; the updater requires the trusted (root) owner | shared lib: root:macprovider 0640 |
| a global hold count made every later drain wait for another run's hold | shared `drain` waits for the run's own reservations |
| the manual nginx step looked for the route text, which a comment kept | match the `location =` block |
| `journalctl --since` read the harness's UTC marks in the VM's local zone | `mark` emits `UTC` |
| a restarted fake member rotated its receipt key and was refused re-registration (`receipt_rotation_grace_active`), so S5's in-flight cases never had a request in flight | `fakeprov -receipt-key-file`; revocation checks require `--min-routed` |
| an attested member binds only after it re-offers (runbook section 4) | S5 re-offers after the attestation activates |
| the offline `sign-manifest` refuses runtime allowlist/pairing errors before submit | accepted as the refusal (D8) |
| entry rates so low that a price change did not move the rounded credits | rates raised inside the bounds |
| the nginx reload is asynchronous; the 503 check raced it | wait for the 503 |

Per scenario after the fixes (shakedown ref):

| scenario | harness | product signal (provisional, re-checked on the acceptance ref) |
|---|---|---|
| S1 baseline | OK | P-1 disconnect holds outlive the drain |
| S2 updater rollout | OK: plan, rollback rehearsal (exact restore), apply, artifact paths, live release, dead-man, pricing floor, order, canary proof PASS | P-1; P-3 404 during apply; gateway-first catalog shape (P-4) |
| S3 pool models | OK: config, pools, delegation, bind (loopback + native), events, pool `/v1/models`, disclosure, never-global, entry-price oracle PASS | P-1 on pool `st_dc`; P-5 native streams refunded; P-6 `/poolz` hash_status; P-4 coordinator-first catalog |
| S4 refusals | OK | none (blocked identity GAP, D4) |
| S5 rotation/revocation | OK after the receipt-key fix | P-7 SIGHUP of bounds/owner accounts silently ignored |
| S6 rollback | OK | P-8 preflight does not refuse; the old coordinator disables all pools |

## Findings

Provisional, from the shakedown against `e7964a233`. Two fixers were
changing settlement and config code while it ran; each is re-checked on the
acceptance ref before it is filed. Repro: the named step of
`run-all.sh 1 "B1 B2 S1 S2 ..."`; evidence file names are in the result line.

**P-1 (settlement holds, likely pre-existing).** A streaming request whose
buyer disconnects mid-stream (`st_dc`) leaves the gateway reservation
`active` with `settlement_hold=1` long past the 300 s receipt deadline: the
coordinator verdict stays `pending/missing_receipt` with `closed=0` (only the
pool expiry sweep closes verdicts, #1690 F-7), so the reconciler keeps
answering `held`. On old/old the S1 holds cleared after 8-11 min; with the new
gateway (S2 gateway-first, S2 new pair, S3 pool routes) they were still
active after 15-22 min. Repro: S1/S2/S3 `st_dc` rows
(`p1As2new.oracle.json`, request `c1d344b6-…`, verdict deadline 11:24 UTC,
still held 11:41).

**P-3 (buyer-visible during the updater apply).** Right after the new gateway
starts, before providers reconnect, a buyer request answers
`404 model_not_found` ("No provider has advertised the requested model")
instead of a retryable 503 (`p1As2window.load.jsonl`). The window itself is
safe: the updater stops the gateway before the coordinator and starts the
coordinator first, so no request is served by a mixed pair (502 from nginx in
the window, 3.5 s).

**P-4 (mixed pairs, catalog).** Old coordinator + new gateway, and new
coordinator + old gateway: a non-streaming buyer disconnect (`ns_dc`) is
sometimes settled (prompt-only debit) instead of refunded, and once with buyer
debit 8 != provider payable 11 (I3, `p1As3cfcat`). A 502 `ns_over` is debited
(#1690 F-3, pre-existing). Outcome shape therefore differs from S1.

**P-5 (native pool route, streaming).** On the native `mlx_cache` route, 2 of 4
completed streams (`st`, read to `[DONE]`) were refunded: delivered and
unbilled (`p1As3n`, EXPECT).

**P-6 (runbook vs `/poolz`).** Runbook section 4 says a bound pool member's
`/poolz` row shows `hash_status: hash_verified`; the coordinator reports
`uncatalogued` for both members (`p1A-s3/poolz.check`).

**P-7 (config reload).** SIGHUP after tightening
`pool_model_pricing_bounds.max_completion_rate_per_mtok` to 50,000: a core with
an entry at 60,000 was accepted (`p1A-s5/hup-manifest.txt`, v22), and a change
to `provider_owner_account_ids` produced no log line. Neither applied nor
refused (fixer B targets this).

**P-8 (rollback preflight, HIGH for operators).** With pool-model extension
cores in the durable store, `coordinator pool-rollback-preflight` exits 0
(`rollback_blocked:false`, `p1A-s6-pool/preflight.txt`), and the runbook's
coordinator rollback to the baseline binary then logs "trusted pools durable
reconstruction failed; pool support disabled" (`replay event 3: invalid
manifest snapshot`): every pool, not only pool-model ones, stops routing after
the rollback (fixer B targets the preflight).

**Deploy order (fixer A, route_snapshot_v2).** Recorded by
`S2-updater-order` and `S3-order-coordinator-first-*`: the updater never
serves a new-coordinator/old-gateway pair (gateway stopped first, coordinator
started first, nginx 502 in between). The manual runbook order (coordinator,
then gateway) does: on the shakedown ref pool-model traffic settled there (no
`invalid_settlement_policy_version`); the acceptance ref (v2 snapshots) is the
real test.
