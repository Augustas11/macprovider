# #1693 pricing lane — end-to-end test plan

Goal: find bugs in the pricing lane by **running real components at the seams
that matter**, not by more review. Every tier below drives real binaries and
real scripts; a mock is allowed only for a component that is not the seam under
test, and the tier says which one. Audit history (plan rounds, three
implementation rounds) is under `audits/2026-09-23/` and `audits/2026-09-24/`;
findings still open after the last round are listed in
`audits/2026-09-24/AUDIT_1693_IMPL_FINDINGS.md` and each one gets a test here.

## What must hold (the oracle for every scenario)

Checked automatically after every scenario, from the real SQLite ledger, the
real applied-config record and real HTTP responses:

- **O1 billing integrity (SPEC-005-R013 I1).** Every `ledger_request_credits`
  row's prompt/completion rates equal `RateFor(<table of its linked
  config_snapshot_id>, model)`, and that snapshot's `rate_card_json` is a table
  that was in force (prior or candidate), never a mix.
- **O2 publication (I2).** A sampler that reads `/v1/rate-card` and issues a
  priced request back to back every ~50 ms during every SIGHUP never observes a
  request priced at table T while the coordinator served a card other than T in
  a read that completed after the request was recorded.
- **O3 snapshots.** `ledger_config_snapshots` rows added by the scenario are
  exactly the expected count from the transition table in the plan, each equal to
  the prior or candidate table.
- **O4 history (I5).** A wholesale statement for a period spanning the change is
  byte-identical whether generated before or after the change for the rows that
  existed before it, and per-generation for rows after.
- **O5 disk pair (I4).** After every scenario (including crash/reboot), the
  on-disk base `rewards.rate_card` equals the on-disk `current/rate-card.json`
  rows, the overlay is unchanged, and no `.pricing-txn*` remains unless the
  scenario expects it.
- **O6 served == applied.** `/v1/rate-card` bytes == `current/rate-card.json` ==
  applied record `signed_rate_card_sha256` whenever no transaction is open.

## Tier E1 — real coordinator + gateway, in CI (`test/integration`)

Extends the existing harness (`test/integration/harness_test.go`: real
coordinator and gateway binaries, real SQLite, in-process fake provider over
the real `/ws/provider`). The fake provider is fine here: the seam is
coordinator config reload ↔ billing ↔ served feed ↔ gateway. Signed feeds use a
test keyring generated in the test (never operator keys).

| Journey | Drives | Checks |
|---|---|---|
| J1 forward pricing | boot on table A/card A; paid requests; real `catalog-release.py splice-coordinator-rate-card` to B; install card B; SIGHUP | O1–O4, O6; record `rate_table_sha256`/`billing_snapshot_id` advanced; gateway `/v1/rate-card` converges within 300 s + one client TTL (use a shortened test TTL) |
| J2 load across the switch | 20 concurrent buyer streams during J1's SIGHUP (+ `-race` build) | O1, O2 (sampler), no request errors attributable to the reload |
| J3 parity reject | yaml B + card A, SIGHUP | reload rejected, 0 snapshot rows, requests still A, `autotune runtime economics reload rejected` logged |
| J4 feed-load failure | yaml B + unreadable card B | reload continues on card A then parity-rejects; 0 rows |
| J5 billing txn failure | hold an exclusive SQLite write lock during the SIGHUP | `billing config reload rejected`, 0 rows, table/card unchanged |
| J6 reversal | J1 then B → A | O1–O4; A rows before and after the reversal both price at A |
| J7 validator seam | real `--validate-autotune-release --expect-base-equivalent` over yaml variants: comment-only, other-key change, tag/style change, key order, overlay-shadowed rows, `--resolve-model-names` with odd names | accept exactly the rate-card-only variants |
| J8 wholesale edges | model-month > 10M tokens, free SKU alias, zero-rate row, legacy NULL-attempt rows across a change, both-identity conflict | per SPEC-005 §11.7; conflict fails closed; > 10M not zeroed |

## Tier E2 — a real "fake Pearl" host (Lima VM `macprovider-540`, Ubuntu 26.04 amd64, systemd)

The seam is the operator lane ↔ host: real `deploy-pearl-vps.sh`, real systemd
units (recovery, closer, guard drop-in), real `coordinator-pricing-recover`,
real `catalog-content-release.sh` over real SSH, real locks, real reboots. The
VM gets its own test catalog keyring and a local bare git remote that plays
`origin/main` (the lane requires the commit to be on `origin/main`). No
production host, key, or data is touched.

Setup (scripted, `test/e2e-pricing/` — to be written):

1. Start the VM; create the Pearl layout (`/opt/macprovider`, `macprovider`
   user, `/etc/macprovider` overlay, nginx optional).
2. Seed a "pre-#1693 live" state: deploy an `origin/main` tag from before this
   branch, with a signed test release A live and a buyer API key.
3. Run the **enabling rollout exactly as the runbook says**: updater bundle, full
   deploy of the branch tag, host checks, clean preflight. (Tests the runbook as
   written; any step that does not work is a bug.)
4. Canary: a real `macprovider-cli` built from branch HEAD on this Mac, joined to
   the VM coordinator over an SSH tunnel, serving the smallest catalog model; if
   the model cannot be served here, the canary step runs with the CLI's
   catalog-source proof only and the gap is recorded.
5. Load generator: buyer requests through the VM gateway during every run.

Scenarios (each ends with O1–O6):

| # | Scenario | Expected |
|---|---|---|
| V1 | Happy path: reviewed PR changes 3 rows, adds 1, removes 1 (acked) | GO → deploy with ack → verified → finalized; floor marker written |
| V2 | Every preflight NO_GO: foreign deploy marker, stale installed updater, overlay pricing keys, pre-#1693 record, commit block mismatch, dry-load parity mismatch, unacked move (catalog key and request-log-only name), Unicode/bidi name | NO_GO, nothing on the host changed (hash the whole `/opt/macprovider` + `/etc/macprovider` before/after) |
| V3 | Ack mismatch; new request-log name between preflight and deploy (with and without `--preflight-verdict`) | refused / accepted per R019 rule 2 |
| V4 | Kill -9 the lane at each journal phase (poll `txn.json` phase, kill on transition) | `--recover-pricing-txn` restores or finalizes per phase; O1–O6 |
| V5 | Hard power-off the VM (`limactl stop -f`) at each phase, boot | pre-start restores / finalizes; closer finalizes `restored-unverified` from the boot record; coordinator serves a consistent pair |
| V6 | Lease loss (kill the lease runner) | no rollback, journal kept, every writer refuses (75/76, deploy 12), recover restores |
| V7 | Concurrent writers during an open transaction: Tier-2 activation script, renewal, updater run, watchdog, manual payout SIGHUP | each refuses; none changes the yaml or HUPs |
| V8 | Evidence failures: stop the coordinator mid-verify, stale served card, billing lock contention | rollback restores yaml + current + window together |
| V9 | Deploy-and-pricing conflict synthesized (crash a deploy while a journal exists) | `--resolve-deploy-conflict` resolves coherent pairs, refuses mixed; coordinator stays stopped until told |
| V10 | Runtime floor: after V1, deploy the pre-#1693 tag with the new script, with the old script, and via updater; roll back a new deploy onto an old binary | new paths refuse (64/65/updater); old script is the documented operator-rule gap — confirm the runbook's marker check catches it |
| V11 | Weekly renewal after a pricing change, and a content-only release after it | renewal continuity passes; content release unaffected |
| V12 | Wholesale statement for the VM period spanning V1 + V4 + V5 | O4; per-generation totals reconcile with the ledger |

## Tier E3 — production Pearl (operator-run, after the enabling runtime cut)

1. Enabling rollout per runbook from the release tag; host checks; clean
   preflight on a no-op release.
2. One real reviewed pricing correction (smallest safe change, e.g. a single
   row fix) through the lane; evidence (a)–(e); gateway convergence.
3. A strict-pin buyer request on the changed model: ledger row at the new rate,
   identity row linked to the recorded snapshot id.
4. Record the evidence and promote `SPEC-005-R013` / `SPEC-023-R019` CONFORMANCE
   from `pending` only on this evidence.

## Bug handling

Every failure is a bug until shown otherwise: reproduce, add the failing case as
a regression test in the tier where it was found, fix in the PR, re-run the tier.
No further audit rounds; review happens on the PR as usual.

## Exit criteria

E1 green in CI; E2 V1–V12 green on two consecutive full runs; every item in
`AUDIT_1693_IMPL_FINDINGS.md` either fixed with a test or explicitly accepted in
the PR body; E3 is the post-merge live evidence gate for CONFORMANCE promotion,
not a merge gate.
