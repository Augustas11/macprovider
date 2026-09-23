# Catalog release decision tree (SPEC-023 §3.7.8-§3.7.9, #1688)

Pick the lane from what changed against the **live** release, not from what the
PR title says. Every lane below fails closed; none of them re-signs on Pearl.
Normative rules: `SPEC-023-R013` to `SPEC-023-R017` in
`specs/SPEC-023-installer-autotune-recommend.md`.

## Which lane

Walk the list top to bottom and stop at the first match. It follows
`catalog-release.py content-gate` lane order (most restrictive first).

1. **Release or feed `policy_version`, schema versions, feed `source`, any
   signer key id (including the Tier-2 key), `trusted-keys.json` bytes, the
   CLI payload, or artifact-bound on/off changed**: **full provider-app
   release**. Cut a signed CLI/Malibu.app release with a refreshed baked
   catalog (`docs/runbooks/provider-cli-release-verification.md`). The content
   lane refuses with `lane=full-provider-app`.
2. **A `rate-card.json` row changed** (after stripping restamp fields):
   **pricing**. There is no pricing lane yet (#1693). Until it exists, ship
   pricing through the runtime lane (item 6). The content lane refuses with
   `lane=pricing`.
3. **Candidate, demand, Tier-2 model entries, or the not-buyer-serving list
   changed, and nothing above**: **catalog-content lane**
   (`scripts/catalog-content-release.sh`, below). Eligible only when all of
   these hold:
   - policy, schema, keyring, signers and artifact-bound are unchanged vs live;
   - no rate-card row changed;
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
   `lane=freshness-or-noop`.
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
  transaction is in progress (`pearl_locks_free`).

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
`config_applied`, `rollback_preconditions`, `content_gate`,
`buyer_serving_e2e`, `coordinator_dry_load`, `window_coverage` (or
`window_override`), `canary_token_operator_key`, and `canary_reachable`.
`--deploy` runs the same preflight in the same invocation. It proceeds only on
GO, and it re-runs coverage and config identity under the Pearl lease before
mutating anything.

### Exit codes

| Code | Meaning | Action |
| --- | --- | --- |
| 0 | preflight GO, or deploy activated and every evidence step passed | none |
| 1 | usage, environment or operational error, with no activation (or before it) | fix and rerun |
| 3 | preflight NO_GO; nothing was mutated | fix the failing checks |
| 4 | activated, evidence failed, rolled back to the prior release | read the failing evidence step; do not rerun unchanged |
| 5 | rollback incomplete | [Rollback failed](#rollback-failed) |
| 6 | Pearl lease lost after activation may have started; state unknown, NOT rolled back | [Lease lost](#lease-lost) |
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
