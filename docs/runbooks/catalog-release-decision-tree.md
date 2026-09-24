# Catalog release decision tree (SPEC-023 §3.7.8-§3.7.10, #1688, #1693)

Pick the lane from what changed against the **live** release, not from what the
PR title says. Every lane below fails closed; none of them re-signs on Pearl.
Normative rules: `SPEC-023-R013` to `SPEC-023-R018` in
`specs/SPEC-023-installer-autotune-recommend.md`; the money invariants of a
price change are `SPEC-005-R013` (`specs/SPEC-005-billing.md` §5.6).

## Which lane

Walk the list top to bottom and stop at the first match. It follows
`catalog-release.py content-gate` lane order (most restrictive first).

1. **Release or feed `policy_version`, schema versions, feed `source`, any
   signer key id (including the Tier-2 key), `trusted-keys.json` bytes, the
   CLI payload, or artifact-bound on/off changed**: **full provider-app
   release**. Cut a signed CLI/Malibu.app release with a refreshed baked
   catalog (`docs/runbooks/provider-cli-release-verification.md`). The content
   lane refuses with `lane=full-provider-app`.
2. **`rate-card.json` changed** (after stripping restamp fields). Split by
   what changed:
   - `usd_per_million_credits`, or any row's `provider_share_bps` or
     `global_multiplier_ppm`: **runtime lane** (item 6). These are coordinator
     globals (`rewards.provider_share`, `rewards.global_multiplier`,
     `stats.rollup.usd_per_million_credits`). The content lane refuses with
     `lane=pricing-globals`.
   - The `default` row is removed: **invalid**, never ship it. The content lane
     refuses with `lane=invalid-release`.
   - Only the three credit fields of `rows` entries changed, rows were added,
     or non-`default` rows were removed: **catalog-content lane, pricing path**
     ([Pricing corrections](#pricing-corrections-operator-procedure)). This
     needs the enabling coordinator runtime release (the one that carries
     #1693) to be live on Pearl. Until it is, preflight is NO_GO on
     `pricing_host_state` ("#1693 enabling runtime release") and rows-only
     pricing still ships through the runtime lane (item 6). A served model
     that moves onto `default` or onto a different row without an entry in
     `acknowledged-pricing-moves.json` is refused with
     `lane=pricing-unacked-move`. Pricing may ride with the content changes of
     item 3 in one release.
3. **Candidate, demand, Tier-2 model entries, or the not-buyer-serving list
   changed, and nothing above**: **catalog-content lane**
   (`scripts/catalog-content-release.sh`, below). Eligible only when all of
   these hold:
   - policy, schema, keyring, signers and artifact-bound are unchanged vs live;
   - any rate-card change is rows-only (item 2) and goes through the pricing
     path;
   - the candidate feed is fresh (not older than 30 days, not more than 10
     minutes in the future);
   - the live content reconstructs a row of the release ledger (predecessor
     known, not `unknown-predecessor`);
   - the release is byte-equal to a reviewed full-40-hex commit that is an
     ancestor of `origin/main`, and that commit carries the release ledger and
     `not-buyer-serving.json`.
4. **Only dates and signatures changed** (candidate/demand/rate-card
   `version` + `generated_at`): **freshness-only renewal**. Weekly and
   automatic (Wednesday 16:00 UTC, `docs/runbooks/autotune-feed-renewal.md`).
   Do nothing by hand. The content lane refuses these with
   `lane=freshness-or-noop`. A renewal never carries a price change: rate-card
   drift vs live fails the renewal and names the pricing path or the runtime
   lane (`SPEC-023-R016`).
5. **Only the Tier-2 `issued_at`/`expires_at` (and its signature,
   `catalog_id`, `version`) changed**: **Tier-2 expiry renewal**. Merge the
   re-signed `tier2-catalog.json` to `main`. The next Wednesday renewal copies
   it from `main` and its continuity check strips the Tier-2 signing envelope,
   so an expiry-only re-sign passes as freshness. Any Tier-2 model-entry change
   is content (item 3).
6. **Runtime-only coordinator deploy** (`phase4-coordinator/dist/deploy-pearl-vps.sh`).
   The deploy classifies its tag-pinned catalog against live with
   `catalog-release.py compare-live`:
   - `equivalent` (equal modulo restamp, and live Tier-2 does not expire before
     the tag's): no `current` swap, no window change. Live release is verified
     after restart.
   - `descends` (live reconstructs a row of the tag's ledger): activates the
     tag's release under the window and coverage rules below.
   - `regression` (live matches no ledger row): aborts before any mutation.
     `CATALOG_REGRESSION_OVERRIDE_REASON='<why>'` (1-200 printable ASCII, one
     line) activates anyway and logs the record. Prefer deploying a tag that
     carries the live catalog.
   - A pricing transaction journal (`/opt/macprovider/.pricing-txn`) makes the
     deploy abort right after it takes the lease, before step 0 (exit 12,
     `refusing: pricing transaction journal present`). Resolve it first
     ([Pricing txn](#pricing-txn)). Deploy tags older than #1693 lack this
     check: never run one while a journal exists.

A merged content PR **must be deployed through the content lane before the
next Wednesday renewal**. The renewal copies catalog files from `main`, detects
the content drift against live, and fails (`content drift vs live feed`). The
feed then ages toward the 30-day expiry until someone ships the content.

## Content lane: operator procedure

`scripts/catalog-content-release.sh` runs on the operator's machine. It needs
no signing key and never re-signs. The release is built from
`git archive <commit>`, never from the working tree.

### Prerequisites

- A clean checkout whose `scripts/` tooling is byte-equal to the commit
  (`tooling_matches_commit`). The commit must be on `origin/main`.
- Pearl SSH: `PEARL_SSH`, `PEARL_SSH_IDENTITY`, `PEARL_SSH_KNOWN_HOSTS`. These
  are the same variables `renew-autotune-static-feed.sh` uses.
- Canary: `CATALOG_CANARY_PROVIDER_ID`, `CATALOG_CANARY_SSH_TARGET`,
  `CATALOG_CANARY_SSH_KEY`, `CATALOG_CANARY_INSTALL_DIR`, and a bearer through
  one of `CATALOG_CANARY_AUTH_TOKEN`, `CATALOG_CANARY_AUTH_TOKEN_FILE`, or
  `CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_*`. The deploy script documents the same
  variables. The bearer must be the coordinator operator key. The script proves
  that by digest only and passes the bearer only through `curl --config` on
  stdin.
- Optional: `REMOTE_AUTOTUNE_DIR` (default `/opt/macprovider/autotune`),
  `COORDINATOR_UNIT` (default `macprovider-coordinator`),
  `CATALOG_EVIDENCE_WATCH_SECONDS` (600), `CATALOG_EVIDENCE_POLL_SECONDS` (30),
  `CATALOG_CANARY_RECOVERY_SECONDS` (180), `CATALOG_EVIDENCE_SETTLE_SECONDS`
  (30), `AA_LEASE_MAX_SECONDS` (2700).
- No coordinator deploy, renewal, Pearl update, or Tier-2 enforcement
  transaction is in progress (`pearl_locks_free`), and no pricing transaction
  journal exists (`pricing_txn_absent`).

### Run

```bash
scripts/catalog-content-release.sh --preflight --commit <40-hex sha>
# read the verdict; fix every failing check; then:
scripts/catalog-content-release.sh --deploy --commit <same sha>
```

`--preflight` prints one JSON line on stdout and changes nothing:

```json
{"go": false, "checks": [{"name": "window_coverage", "ok": false, "detail": "..."}]}
```

`go` is true only when every check passes. Read the `detail` of each
`ok: false` check. The checks are `commit`, `tooling_matches_commit`,
`release_assembled`, `canary_config`, `pearl_reachable`, `pearl_locks_free`,
`pricing_txn_absent`, `config_applied`, `rollback_preconditions`,
`content_gate`,
`buyer_serving_e2e`, `coordinator_dry_load`, `window_coverage` (or
`window_override`), `canary_token_operator_key`, and `canary_reachable`. A
release that changes rate-card rows adds `pricing_release`,
`pricing_host_state`, `pricing_effective_diff`, and `pricing_gate`, and its
verdict carries a `pricing` object (`null` otherwise).
`--deploy` runs the same preflight in the same invocation. It proceeds only on
GO, and it re-runs coverage and config identity under the Pearl lease before
mutating anything.

### Exit codes

| Code | Meaning | Action |
| --- | --- | --- |
| 0 | preflight GO, or deploy activated and every evidence step passed; `--recover-pricing-txn`: journal resolved or none | none |
| 1 | usage, environment or operational error, with no activation (or before it) | fix and rerun |
| 3 | preflight NO_GO, or a pricing release without the matching `--pricing-diff-sha256`; nothing was mutated | fix the failing checks, or review the price table and acknowledge |
| 4 | activated, evidence failed, rolled back to the prior release | read the failing evidence step; do not rerun unchanged |
| 5 | rollback incomplete; `--recover-pricing-txn`: stopped with the journal kept | [Rollback failed](#rollback-failed); pricing: [Pricing txn](#pricing-txn) |
| 6 | Pearl lease lost after activation may have started; state unknown, NOT rolled back | [Lease lost](#lease-lost); pricing: [Pricing txn](#pricing-txn) |
| 71 | interrupted, or lease lost before activation (rolled back first through the lease if already activated) | confirm state per the log, then rerun |

### Evidence after activation

- **(a)** The coordinator serves feeds and sigs byte-equal to the release, and
  `/v1/autotune-release` reports its release id.
- **(b)** journald shows an `autotune_feed_sighup_reload` event for this
  version with the release's Tier-2 id and sha, and no `... reload rejected`
  line. The applied-config record has `source=sighup` with the pre-HUP
  digests.
- **(c)** The canary restarts onto the release, and the coordinator admits it
  on the new release id and candidate sha with catalog source `coordinator`.
- **(d)** For the watch window, no `catalog_incompatible` rejection appears
  after the SIGHUP for a `(release id, candidate sha)` key that the
  pre-activation validation admitted, and catalog-unavailable does not
  increase. Rejections of keys that were already inadmissible before
  activation are logged as chronic diagnostics only (SPEC-023-R017(d)): the
  release did not cause them, and failing on them would block every release
  while any stale provider is connected.
- **(e)** A model that is newly buyer-serving, or re-hashed vs live, needs a
  strict-pin buyer request and a settlement row. No noninteractive production
  harness exists for that, so today **(e) is a preflight NO_GO**
  (`buyer_serving_e2e`). Such a release must go through the runtime lane with
  its E2E. A successful content deploy always logs "(e) not required".

When (a) and (b) passed, the failure was (c), and `/poolz` shows live adopters
of the failed release, the rollback keeps that release in the window instead of
stranding its adopters. It never evicts a retained release that has adopters.

## Pricing corrections: operator procedure

A rows-only rate-card correction (item 2) goes live through the content lane
without a runtime release (`SPEC-023-R018`). Billing reads the base-yaml
`rewards.rate_card` rows and refuses any load whose rows differ from the
signed `rate-card.json` (`SPEC-005-R011`), so the lane changes both in one
journaled host transaction: Pearl's live `coordinator.yaml` gets the reviewed
commit's `rate_card` block, `current` and the window move to the release, and
one SIGHUP applies them together.

Needs the enabling coordinator runtime release (the one that carries #1693)
live on Pearl, with its recovery helper, units, and guard-bearing writers
installed. Without it, `pricing_host_state` is NO_GO.

### Enabling rollout (once)

A full coordinator deploy alone does not enable pricing: it installs the
coordinator binary, the recovery helper, the closer unit and the shell guard,
but not the Pearl updater, the Tier-2 enforcement watchdog or the Python guard
module, and preflight hashes all of them against the commit
(`scripts/pricing-lane-installed-writers.txt`). Do these steps in order, all
from a clean checkout of the same signed tag on `main`:

1. **Updater bundle first.** Run `ops/pearl-updater/install-pearl-updater.sh`
   from the tag. This installs the guard-bearing `macprovider-pearl-update`,
   `macprovider-tier2-enforcement-watchdog` and
   `/usr/local/share/macprovider/scripts/coordinator_config_guard.py`. It is a
   prerequisite here, not deferred maintenance.
2. **Full coordinator deploy** with `phase4-coordinator/dist/deploy-pearl-vps.sh`
   (never a binary swap). This installs the coordinator carrying #1693, the
   applied-config record fields, `coordinator-pricing-recover`, the recovery
   unit with both `ExecStart=` lines, the closer unit, the guard drop-in with
   `Wants=`, and `/opt/macprovider/coordinator-config-guard.sh`.
3. **Verify the host.** `/healthz` reports the tag;
   `systemctl show -p Requires,Wants macprovider-coordinator` lists the recovery
   and closer units; `systemctl show -p LoadState --value macprovider-pearl-updater-alert@macprovider-coordinator-pricing-close.service.service`
   is `loaded` (the closer's `OnFailure=` instance); `/run/macprovider/coordinator-applied-config.json` carries
   `rate_table_sha256`, `signed_rate_card_sha256`, `autotune_release_id` and
   `billing_snapshot_id`; and every line of
   `scripts/pricing-lane-installed-writers.txt` hashes equal on the host and at
   the tag.
4. **Clean preflight.** `scripts/catalog-content-release.sh --preflight --commit
   <tag commit>` must reach GO on a no-op or content release before the first
   pricing correction. Any `pricing_host_state` NO_GO names the step above that
   was skipped.

If a later tag changes any file in the installed-writers list, repeat step 1
from that tag before the next pricing correction.

### Author the PR

One PR, reviewed by CODEOWNERS, carrying all of:

- `phase3-binary/catalog/autotune/rate-card.json` (and the rest of the
  release: signatures, `release.json`, ledger row), cut and signed as in
  `docs/runbooks/catalog-artifact-feed-release.md`. Change only the three
  credit fields of `rows`, add rows, or remove non-`default` rows. Leave
  `usd_per_million_credits`, `provider_share_bps`, `global_multiplier_ppm`,
  `policy_version`, and schema versions alone.
- The matching `rewards.rate_card` block of
  `phase4-coordinator/dist/coordinator.yaml`
  (`python3 scripts/catalog-release.py emit-coordinator-rate-card`, pasted
  over the old rows). The lane installs this block verbatim, so price
  provenance comments go inside it. Edit nothing else in the file: the lane
  proves the rest of Pearl's live yaml is unchanged, and a
  `rewards.provider_share` / `rewards.global_multiplier` change is runtime
  lane.
- `phase3-binary/catalog/autotune/acknowledged-pricing-moves.json`: one entry
  `{"model": "<served name>", "from_row": "<old row key>", "to_row": "<new row key>"}`
  for every served model that resolves to a different row after the change
  (a removed row drops it to `default`; an added row can capture names that
  resolved to `default` or to another row before). A pure price change inside
  the same row needs no entry. The file is read from the reviewed commit, so
  a move you missed shows up as a `pricing_effective_diff` NO_GO after merge
  and needs a follow-up PR.

Before deploying, check the overlay: `/etc/macprovider/coordinator.pearl-overlays.yaml`
must carry no `rate_card`, `provider_share`, `global_multiplier`, or
`usd_per_million_credits` key (preflight refuses otherwise).

### Preflight and the price table

```bash
scripts/catalog-content-release.sh --preflight --commit <40-hex sha> > verdict.json
```

On Pearl, preflight splices the commit's block into a copy of the live yaml
(live yaml bytes never leave the host), dry-loads it with the live binary, and
computes the effective-price diff. The pricing checks:

| Check | NO_GO means |
| --- | --- |
| `pricing_txn_absent` | a journal exists: [Pricing txn](#pricing-txn) first |
| `pricing_release` | the commit lacks `coordinator.yaml` or `acknowledged-pricing-moves.json`, or its `rate_card` block does not match the release rows |
| `pricing_host_state` | foreign recovery state (deploy snapshot, updater or Tier-2 transaction, live journal temp dir); pricing keys in the overlay; the installed helper, units, or guard-bearing writers differ from the commit; served card, on-disk `current` card, and applied-config record disagree (prior not settled); or the coordinator lacks the #1693 applied-config fields |
| `pricing_effective_diff` | a served name moves rows without an acknowledgement, or the splice/dry-load disagrees with the applied config |
| `pricing_gate` | the content gate, rerun against the fetched diff, refused (`pricing-globals`, `pricing-unacked-move`, or a digest mismatch) |

The price table goes to stderr, one line per affected served name:

```text
[catalog-content] pricing: effective price changes (credits per Mtok: prompt / cache-hit / completion)
[catalog-content]   <model>: <old p> / <old c-h> / <old c> -> <new p> / <new c-h> / <new c> (row <old> -> <new>)
[catalog-content] pricing: acknowledge with --pricing-diff-sha256 <64 hex>
```

The name set covers catalog keys and served model ids of the candidate,
current, and window releases, every row key of both tables, and the distinct
`request_log.model` values of the last 30 days. Those last names are
buyer-controlled: control characters are shown escaped (`\xNN`). Read every
line. The digest on the last line is the ack: it names exactly this table.
The same value is `pricing.pricing_diff_sha256` in `verdict.json`.

### Deploy

```bash
scripts/catalog-content-release.sh --deploy --commit <same sha> \
  --pricing-diff-sha256 <digest from the table> --preflight-verdict verdict.json
```

- Without `--pricing-diff-sha256`, or with a different digest, deploy exits 3
  and prints the digest to acknowledge. Review the table again; do not copy the
  digest blindly.
- `--preflight-verdict` reuses the name set the reviewed preflight pinned, so
  a name that aged out of the 30-day window since does not invalidate the ack.
  Under the lease the diff is recomputed over those names plus newly seen
  ones; only a new name with an unacknowledged move refuses.
- Under the lease every pricing check reruns. Any moved digest (live yaml,
  overlay, applied record, diff) stops the deploy with nothing mutated: rerun
  preflight.
- Then the lane writes the journal (`/opt/macprovider/.pricing-txn`), installs
  the candidate yaml, swaps `current` and the window, sends one SIGHUP, and
  collects evidence. Any failure rolls yaml, `current`, and the window back
  together and re-HUPs (exit 4).

### Evidence and alerts

On top of content-lane evidence (a)-(d):

- **(a)** also covers `/v1/rate-card` and `/v1/rate-card.sig`.
- **(b)** also needs an applied-config record with `source=sighup`, loaded at
  or after the SIGHUP, whose config digest is the candidate, overlay
  unchanged, `rate_table_sha256` and `signed_rate_card_sha256` equal the
  preflight's expected values, and `billing_snapshot_id` greater than the
  prior. `autotune runtime economics reload rejected` counts as a rejection.
- **(s)** before `verified`, still under the lease, on-disk yaml, overlay,
  `current`, window, and release set equal the journal's candidate.

A success ends with
`pricing: rate table <sha> and signed card <sha> live (diff <sha>)`. Record
the commit, the diff digest, the rate-table digest, and the new
`billing_snapshot_id` in the PR or issue.

After the lease is released the lane polls the public card
(`CATALOG_GATEWAY_RATE_CARD_URL`, default `https://api.malibu.tech/v1/rate-card`)
for up to `CATALOG_GATEWAY_CONVERGENCE_SECONDS` (660). `ALERT (informational,
not rolled back)` means the gateway cache has not caught up. Billing switched
at the SIGHUP (`SPEC-005-R013` I2/I3); the public card is a recommendation
feed. Check the gateway, never roll back a correct price for it.

`ALERT: the pricing journal could not be marked verified/finalized; the
candidate is live` means the price is live but the journal remains, so every
config writer refuses. Run `--recover-pricing-txn` ([Pricing txn](#pricing-txn)).

### Wholesale statements

The same coordinator release changed how D1a wholesale statements price
(`SPEC-005` §11.7):

- Each `request_log` row is priced at its own rate generation (its linked
  `config_snapshot_id`, else the snapshot in effect at `ts_utc`), not at the
  current table. A price change never re-prices earlier requests.
- Lines group by `(model, resolved rate row, global_multiplier_ppm)`, so a
  model repriced mid-month shows one line per generation.
- A model-month above 10,000,000 tokens is no longer zeroed (the per-request
  cap does not apply to the aggregate). A regenerated draft for such a month
  now shows the real amount; issued statements change only with `force=true`. A total above int64 fails the statement.
- A row with no billing snapshot linked and none in effect at its timestamp
  fails the statement closed (`wholesale row has no billing config
  generation`); it does not bill at the current table.

## Window semantics

- `.previous-target` holds **at most 3** `releases/<id>` lines. Activation
  prepends the outgoing `current`, removes the incoming release, and dedupes.
  A fourth line makes the coordinator fail closed. `scripts/autotune_window.py`
  is the only writer.
- The window is a **retention and rollback rule, not a compatibility
  guarantee**. `SPEC-023-R010` row-continuity is the durable fix for older
  catalogs.
- **Coverage** comes from the coordinator's own admitted set. The live
  coordinator binary dry-loads the incoming release with the planned window
  (`--validate-autotune-release DIR --previous-target FILE`). Same-version
  restamps are scanned from the live `releases/`. Then
  `autotune_window.py coverage --admitted-json <verdict> --poolz-json <poolz>`
  compares that `admitted` list with the `(catalog_release_id,
  catalog_candidate_sha256)` pairs that connected providers advertise on
  `/poolz`. Exit 4 means a connected provider would be stranded. An
  unreadable `/poolz` or verdict is a refusal, not a pass. There is no Python
  re-implementation of admission.
- Overrides are for activations only, and each one is logged:
  - `CATALOG_WINDOW_OVERRIDE_REASON='<why>'`: activate although coverage
    reports uncovered providers. Used by the content lane and
    `deploy-pearl-vps.sh`.
  - `CATALOG_REGRESSION_OVERRIDE_REASON='<why>'`: runtime deploy over a
    `regression` verdict.
- Audit log: `/var/lib/macprovider/catalog-window-overrides.jsonl` (root-only,
  append-only). Record kinds:
  - `content_lane_window_coverage`: content-lane coverage override (reason,
    uncovered, incoming, live, commit, ts).
  - `window_coverage`: runtime-deploy coverage override.
  - `renewal_coverage_loss`: renewal published with coverage lost or unknown
    (no override involved).
  - A regression override record has no `kind`. It carries `reason`,
    `incoming`, `live`, `tag`, and `commit`.

### Renewal coverage loss

Each weekly freshness renewal mints a new `release_id`. SPEC-023 §3.7.8
forbids rebinding an id to new bytes, so every renewal consumes one of the 3
retained `.previous-target` slots. A provider that has not restarted across 3
renewals falls out of the admissible set on the 4th renewal. It is rejected
`catalog_incompatible` at its next hello.

Before swapping `current`, the renewal reads `/poolz` on Pearl loopback and
runs `autotune_window.py coverage`. It takes the operator key from the running
coordinator's environment and never prints it. The renewal **always
publishes**, because an expired feed strands everyone. On loss it emits:

- `::warning title=Autotune renewal coverage loss::` in Actions;
- `"kind":"renewal_coverage_loss"` in
  `/var/lib/macprovider/catalog-window-overrides.jsonl`;
- a journald entry (`journalctl -t macprovider-renew`).

"Coverage unknown" means `/poolz` or the key was unreadable, so check coverage
by hand. Remedy: restart the listed providers onto the current feed. Do not
roll back the renewal.

## Applied-config identity

The coordinator writes `/run/macprovider/coordinator-applied-config.json`
(schema `macprovider.coordinator-applied-config.v1`) after every successful
boot or SIGHUP. The record holds the path and sha256 of `coordinator.yaml` and
of the overlay it actually applied. The content lane requires the on-disk
digests to equal that record, both at preflight and under the lease, because
its SIGHUP would otherwise also apply unrelated pending config edits.

`config_applied` NO_GO means one of:

- `applied identity unknown`: the record is missing or unparseable;
- `pending config edits not yet applied` / `pending overlay edits not yet
  applied`: someone edited the config without reloading it.

Fix: decide deliberately whether the pending edit should go live. Then either
SIGHUP or restart the coordinator on its own, confirm the reload in journald
and the new record, and rerun preflight. Alternatively, revert the on-disk edit.
Never let a catalog activation apply someone else's config change.

## Rollback failed

Exit 5 (`ROLLBACK INCOMPLETE`). The automatic rollback did not converge, so
Pearl may be serving the new release, the old one, or a mixed window.

**Pricing release** (`/opt/macprovider/.pricing-txn` exists): do not run the
steps below. They do not restore `coordinator.yaml`, and a hand swap of
`current` leaves a mixed yaml/card pair. Follow [Pricing txn](#pricing-txn).

1. **Freeze writers.** Disable the renewal workflow
   (`renew-autotune-static-feed-signed.yml`) and stop
   `macprovider-pearl-updater.timer`. On Pearl, open and hold both locks,
   `/run/lock/macprovider-pearl-updater.lock` and
   `/opt/macprovider/.coordinator-deploy.lock` (`flock -n`), for the whole
   procedure. If either lock is held, find the holder before you continue.
2. **Inspect the state.** Record the current target and the window:
   `readlink <root>/current`, `cat <root>/.previous-target`, and
   `ls <root>/releases/`. The script log names the prior target and window,
   and the new release directory.
3. **Journald.** Run `journalctl -u macprovider-coordinator --since <activation time>`
   and look for `autotune_feed_sighup_reload` (which `autotune_catalog_version`
   was loaded) and any `... reload rejected` line.
4. **Applied config.** Read `/run/macprovider/coordinator-applied-config.json`
   and confirm that its `source` and timestamps match the last reload you saw.
5. **Restore** to the prior release, in this order:
   - Write the prior window bytes from the log to a file (empty file when there
     was no window).
   - Swap `current` atomically: `ln -sfn <prior target> <root>/.current.rollback && mv -Tf <root>/.current.rollback <root>/current`.
   - Run `python3 -I <autotune_window.py> restore --root <root> --from-file <file> --expect-current <prior target>`.
   - SIGHUP the coordinator:
     `kill -HUP "$(systemctl show -p MainPID --value macprovider-coordinator)"`.
6. **Verify.** Journald shows `autotune_feed_sighup_reload` for the prior
   version. Coordinator-direct feeds and sigs are byte-equal to
   `releases/<prior>/`. `/v1/autotune-release` reports the prior release id.
   Then restart the canary onto the prior release.
7. Release the locks, and re-enable the updater timer and the renewal workflow.
   Leave the failed release directory in `releases/`. The next run refuses a
   directory name that already exists, so rename or remove it deliberately
   before any retry.

## Lease lost

Exit 6 (`LEASE LOST`). The Pearl lease ended while activation may have
started. **The state is unknown and was not rolled back. Do not rerun the
script**, because a rerun judges a half-known state as live.

**Pricing release**: the log adds `pricing: the journal at
/opt/macprovider/.pricing-txn is kept`. Do step 1 below, release the locks
again, then run `--recover-pricing-txn` ([Pricing txn](#pricing-txn)) instead
of deciding by hand.

1. Establish ownership. Confirm that no lease runner or activation process from
   the run survives on Pearl. Then take both Pearl locks yourself and hold them
   (as in [Rollback failed](#rollback-failed) step 1). If another deploy,
   renewal, or update holds a lock, wait for it and read its log first.
2. Establish the state: `current`, `.previous-target`, `releases/`, the
   journald reload events since the activation time, and the applied-config
   record.
3. Decide manually:
   - `current` is the prior release and the window is unchanged: nothing
     happened. Release the locks and rerun preflight.
   - `current` is the new release, and the reload plus evidence (a) and (b)
     hold on inspection: **roll forward**. Verify served bytes and
     `/v1/autotune-release`, check (c) and (d) by hand (canary admission, no
     new `catalog_incompatible`), then release the locks.
   - Anything else, or doubt: **roll back** with
     [Rollback failed](#rollback-failed) steps 5-7.

## Pricing txn

A pricing release keeps a root-only journal at `/opt/macprovider/.pricing-txn/`
(mode 0700) from its first mutation until it finalizes: `txn.json` (id,
phase, history, prior and candidate digests, the acknowledged verdict),
`prior-coordinator.yaml`, `candidate-coordinator.yaml`, `prior-window` (when
there was one), and `candidate-window`. While it exists, every writer of the
live `coordinator.yaml` or overlay refuses. Read it on Pearl without changing
anything:

```bash
sudo python3 -I /opt/macprovider/coordinator-pricing-recover status   # {"id": ..., "phase": ...}
sudo cat /opt/macprovider/.pricing-txn/txn.json
```

| Phase | Meaning |
| --- | --- |
| `prepared`, `mutating`, `hup-intent`, `verifying` | forward publish in flight or abandoned |
| `verified` | candidate proven live; finalize pending |
| `rolling-back` | rollback in flight or abandoned |
| `rolled-back` | prior proven live; finalize pending |
| `restored-unverified` | prior pair restored on disk, not yet proven live (below) |

The helper's own exit codes: 0 ok or nothing to do; 1 refused before changing
anything; 3 state mismatch (compare-and-swap refused, nothing further
changed); 5 stopped with the journal kept.

### Recover an abandoned journal

First confirm no lane process from the run survives (on the operator machine,
and no lease runner on Pearl). Do not hold the Pearl locks yourself: the
command takes the lease.

```bash
scripts/catalog-content-release.sh --recover-pricing-txn
```

Run it from a clean checkout whose
`phase4-coordinator/dist/coordinator-pricing-recover` is byte-equal to the
installed `/opt/macprovider/coordinator-pricing-recover`; otherwise it stops
with `the installed ... is not this tooling's reviewed copy`. It acts on the
journal only:

- `verified` / `rolled-back`: re-hashes the on-disk state (full
  `verify-directory`, expired Tier-2 allowed) against the candidate or prior,
  then finalizes. No SIGHUP.
- `restored-unverified`: repeats the prior restore (idempotent), accepts a
  matching boot record or sends one SIGHUP, and finalizes on proof.
- Any other phase: rolls back to the prior pair by compare-and-swap (yaml,
  then `current`, then window). If the coordinator runs, it sends one SIGHUP
  and finalizes only when an applied-config record loaded after it has the
  prior config, rate-table, and signed-card digests and the coordinator serves
  the prior card bytes. Recovery never rolls forward: rerun the pricing
  release afterwards.
- Coordinator not running: restores the disk, sets `restored-unverified`, and
  stops (exit 5). Start the coordinator; the closer finalizes.

Exit 0: resolved, or no journal. Exit 5: stopped, journal kept. The helper's
log line says why:

| Line | Meaning | Action |
| --- | --- | --- |
| `coordinator-pricing-recover: refused: ...` | refused before changing anything | fix the named cause, rerun |
| `coordinator-pricing-recover: state mismatch: ...` | yaml, `current`, window, or overlay is neither the journal's prior nor candidate | [State mismatch](#state-mismatch) |
| `coordinator-pricing-recover: STOP: ...` | restored on disk but not proven live, or a journal file is missing or corrupt | read the reason; get the coordinator running; rerun |

### State mismatch

Something wrote outside the guard (a pre-#1693 deploy tag, a hand edit, an
overlay edit). Nothing further was changed.

1. Freeze writers as in [Rollback failed](#rollback-failed) step 1.
2. Compare each item with `txn.json`: `sha256sum /opt/macprovider/coordinator.yaml`
   with `prior.yaml_sha256` / `candidate.yaml_sha256`;
   `readlink /opt/macprovider/autotune/current` with `prior.current` /
   `candidate.current`; `sha256sum /opt/macprovider/autotune/.previous-target`
   with `prior.window` / `candidate.window`; the overlay with `overlay`. Find
   the writer in journald and the deploy logs.
3. Put each mismatching item back to the journal's prior: yaml from
   `/opt/macprovider/.pricing-txn/prior-coordinator.yaml` with the recorded
   `yaml_uid`, `yaml_gid`, and `yaml_mode` (decimal in `txn.json`; 420 is
   0644); window from `prior-window` (or remove it when `prior.window.present`
   is false); `current` to `prior.current`; revert the overlay edit.
4. Release the locks and rerun `--recover-pricing-txn`, or start the
   coordinator if that is what was blocked.

### Coordinator start blocked

`macprovider-coordinator-deploy-recovery.service` (required by the
coordinator) runs `coordinator-pricing-recover --pre-start` first, then
`coordinator-deploy-recover --pre-start`. With a journal and the lock set
free, pricing pre-start finalizes a `verified` / `rolled-back` journal after a
bytes-only check, or restores the prior pair on disk and sets
`restored-unverified`. A held lock set means a live holder: pre-start skips,
and a boot on a mixed pair fails rate-card parity closed (an outage, never
mis-billing). Read `journalctl -u macprovider-coordinator-deploy-recovery`:

- `coordinator-pricing-recover: state mismatch`: [State mismatch](#state-mismatch),
  then `sudo systemctl start macprovider-coordinator`.
- `coordinator deploy rollback snapshot AND pricing transaction journal ...
  present; not restoring either`: the deploy-and-pricing conflict below.

### Deploy-and-pricing conflict

A coordinator deploy rollback snapshot (`/opt/macprovider/.coordinator-deploy-rollback/`)
and a pricing journal both exist. Deploy pre-start recovery refuses to restore
either, so the coordinator does not start. The guarded tools cannot create
this state (the content lane refuses on a deploy snapshot; the deploy refuses
on a journal), so a pre-#1693 deploy tag or a hand change ran during a pricing
transaction. Two operators, by hand:

1. Freeze writers as in [Rollback failed](#rollback-failed) step 1. Delete
   neither the snapshot nor the journal. Leave the coordinator stopped.
2. Record `txn.json`, `ls -la /opt/macprovider/.coordinator-deploy-rollback/`,
   the sha256 of its `coordinator.yaml`, and its `catalog-current-target`.
3. Continue only if the snapshot's `coordinator.yaml` equals the journal's
   prior or candidate yaml, its `catalog-current-target` equals the journal's
   prior or candidate `current`, and the live overlay equals the journal's
   overlay. Otherwise stop here and escalate with the recorded state; do not
   start the coordinator on a hand-assembled pair.
4. Resolve the deploy first, with the journal set aside under a name no tool
   reads:
   ```bash
   sudo mv -T /opt/macprovider/.pricing-txn /opt/macprovider/.pricing-txn-held
   sudo /opt/macprovider/coordinator-deploy-recover --recover
   sudo mv -T /opt/macprovider/.pricing-txn-held /opt/macprovider/.pricing-txn
   ```
   The deploy restore may restart the coordinator on the restored pair. A
   consistent pair passes parity; a mixed one fails closed.
5. Check that `/opt/macprovider/coordinator-pricing-recover` and the pricing
   units still hash to the reviewed #1693 copies (the deploy restore puts back
   the pre-deploy set). Reinstall them if not.
6. Run `--recover-pricing-txn`. If the coordinator is stopped, start it and
   let the closer finalize.

### Closer failure alert

`macprovider-coordinator-pricing-close.service` runs after every coordinator
start (the coordinator's guard drop-in `Wants=` it) and is a no-op unless the
journal is `restored-unverified`. It waits up to 300 s for the lock set, then
up to 120 s for a `source=boot` applied-config record of this boot (bound to
the boot id and the restore nonce, from a coordinator start later than the
restore) with the prior config, rate-table, and signed-card digests and the
prior served card bytes. Then it finalizes.

On failure `OnFailure=` starts
`macprovider-pearl-updater-alert@macprovider-coordinator-pricing-close.service.service`.
Causes: the coordinator did not boot or was slow; the lock set stayed held;
the restore was made in an earlier boot; or the
boot record does not match the prior. Action:
`journalctl -u macprovider-coordinator-pricing-close -u macprovider-coordinator`,
get the coordinator running, then run `--recover-pricing-txn`.

### `restored-unverified`

The prior yaml, `current`, and window are back on disk, checked by digest,
but no live evidence has proven them yet. Billing is safe: the coordinator can
only have booted the prior pair (parity-valid) or failed parity closed. The
transaction is not over: the journal still exists, so deploys, renewal, the
updater, the Tier-2 scripts, the content lane, and manual SIGHUPs keep
refusing until the closer or `--recover-pricing-txn` finalizes it. A
coordinator restart in this phase repeats the restore idempotently.

### Lease loss

Confirmed lease loss never rolls back a pricing release from a separate
session. The lane exits 6 and keeps the journal. Once the lock set is free,
run `--recover-pricing-txn`. An interrupt or deadline while the lease is still
provably held rolls back in-lane (exit 71, 4, or 5).

### Other writers: exit 75 and 76

Every writer of the live `coordinator.yaml` or overlay (coordinator deploy,
host updater, Tier-2 activation and enforcement scripts and watchdog, deploy
recovery, freshness renewal, content lane) uses
`scripts/lib/coordinator-config-guard.sh` (Python:
`scripts/lib/coordinator_config_guard.py`): it takes the updater lock, then
the deploy lock, and refuses while a journal exists.

| Code | Meaning | Action |
| --- | --- | --- |
| 75 | refused: `refusing: pricing transaction journal present at /opt/macprovider/.pricing-txn`; nothing written | resolve the journal, rerun the writer |
| 76 | pre-start callers only: a journal exists | nothing of its own to restore: no-op; its own snapshot too: [Deploy-and-pricing conflict](#deploy-and-pricing-conflict) |

`deploy-pearl-vps.sh` aborts with exit 12 and the same message; the content
lane is NO_GO on `pricing_txn_absent`. Manual SIGHUPs and hand config edits
(including the payout runbook's SIGHUP step) check
`test -e /opt/macprovider/.pricing-txn` first and do not proceed while it
exists.

### Pre-#1693 deploy tags

Deploy tags older than the enabling release lack the journal check, the
writer guard, and the pricing recovery units. **Never run one while a journal
exists.** Deploying one with no journal is allowed but removes the pricing
prerequisites: pricing preflight is NO_GO on `pricing_host_state` until a tag
carrying #1693 is deployed again.
