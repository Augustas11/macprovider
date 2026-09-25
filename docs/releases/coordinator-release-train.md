# Coordinator Release Train — Pearl coordinator / gateway

**This file is the single source of truth for Pearl coordinator releases** (the
coordinator and gateway binaries plus the Pearl-side deploy assets). The
provider CLI has its own train: `docs/releases/cli-release-train.md`. Work
happens across many sessions and agents: read this file before cutting or
applying a coordinator release, and update it in the same commit or PR after any
release-affecting action. If reality and this file disagree, fix this file.

## How to track the next coordinator release

The table below is the net change against the **live** Pearl coordinator/gateway.

1. A PR that changes what Pearl runs **merges**. Add one row the same day,
   with status `merged`. That covers:
   - `phase4-coordinator/` (binary, config, `dist/` units, nginx, deploy scripts);
   - `phase5-gateway/`;
   - `ops/pearl*`;
   - the catalog/feed tooling that deploy ships (`scripts/catalog-release.py`,
     `scripts/autotune_window.py`, `scripts/lib/`,
     `scripts/catalog-verifier-bundle.txt`).
2. A PR is open but not merged. Status `in progress`; it is **not** in the
   next cut.
3. A coordinator release is cut and applied. Move the live row, delete the shipped
   rows, and start a new table.

Do not list spec-only or CONFORMANCE-only PRs. List catalog-content releases
under "Catalog on Pearl", not as coordinator rows: since #1706 they do not need a
coordinator release (see "Which lane" below).

## Core rules (do not violate)

- **Coordinator tags share the `v1.8.N` namespace with CLI candidates.** For
  example, `v1.8.176`, `v1.8.181` and `v1.8.186` are CLI candidate numbers.
  - Take the next unused number.
  - Record it here and in the CLI train, so the two trains never reuse a tag.
  - Check with `git tag -l 'v1.8.*' | sort -V | tail`, and read both train files.
- **A coordinator release never changes the provider binary recommendation.**
  `recommended_binary_version` stays at the promoted CLI stable (`1.8.123`)
  until the CLI train promotes.
- **One cut of current `main`.**
  - Do not dual-dispatch `pearl-runtime-release.yml` from two sessions.
  - Record owner, payload and tag here before and after apply.
- **Build from a signed tag on `main`.** `pearl-runtime-release.yml` (environment
  `production-release`) builds `coordinator-linux-amd64` and
  `gateway-linux-amd64` from an existing tag, with `-X main.version=<tag>`.
- **Apply from a clean checkout of that tag.**
  - `phase4-coordinator/dist/deploy-pearl-vps.sh` for the coordinator, and
    `phase5-gateway/dist/deploy-pearl-vps.sh` for the gateway.
  - Only the full deploy script installs the `dist/` assets: systemd units,
    nginx, and the catalog verifier bundle. A binary-only swap leaves those at
    their previous version (see "Open Pearl actions").
- **Money-path, auth, gateway router and coordinator changes go through PR
  review** before they can be cut (AGENTS.md).

## Which lane (since #1706)

Full decision tree: `docs/runbooks/catalog-release-decision-tree.md`.

| Change | Lane |
|---|---|
| Coordinator/gateway code, config template, units, nginx, deploy scripts | **This train** (coordinator release) |
| Catalog content only: model hash/row/Tier-2 correction, same policy/keys/signers | Catalog-content lane (`scripts/catalog-content-release.sh`), no coordinator release |
| Re-hash of a buyer-serving row (`model_sha256` of a recommendable, rate-carded, Tier-2-pinned row changes) | **This train**: content-lane evidence (e) needs a strict-pin buyer request + settlement row, which has no noninteractive harness, so the content preflight is `buyer_serving_e2e` NO_GO |
| Rate-card rows (pricing) | This train, until #1693 lands (in progress: after its enabling coordinator release, rows-only corrections move to the catalog-content lane; `usd_per_million_credits` / share / multiplier stay on this train) |
| Weekly feed freshness | Automatic renewal (Wednesday); never a coordinator release |
| `policy_version`, keyring, CLI payload | Full provider-app release (CLI train) |

A coordinator deploy compares the tag's catalog with live (`compare-live`):
- `equivalent`: keeps live.
- `descends`: activates the tag's catalog.
- `regression`: aborts unless `CATALOG_REGRESSION_OVERRIDE_REASON` is set (the override is logged).

## Live on Pearl

Probed 2026-09-25 about 10:20Z (`/healthz`, catalog routes and read-only host checks).

| Field | Value |
|---|---|
| Coordinator | **v1.8.200** @ `ca809589`. Applied 2026-09-25 about 10:03Z by the signed updater, then the full `deploy-pearl-vps.sh` (DEPLOY_EXIT 0, exact-byte canary OK) |
| Gateway | **v1.8.200** (`gateway.db` schema 14 from #1719; `coordinator.require_settlement_trailers` off) |
| Release | [Pearl runtime v1.8.200](https://github.com/Augustas11/macprovider/releases/tag/v1.8.200), run [36120742231](https://github.com/Augustas11/macprovider/actions/runs/36120742231); updater transaction `1790330246291811116-v1.8.200` |
| `recommended_binary_version` | 1.8.123 (CLI train owns this) |
| Includes | Everything on `main` through `ca809589`: #1738 (90-day stats overview), #1741 (#1721: CLI and stats sidecars from the release), #1744 (#1735 catalog), #1719 (#1690 engine-agnostic Trusted Pools), and the 2026-09-25 deploy-tooling fixes: #1746, `c6c32692`, `ee061fc3`, `4936a062`, `ca809589` (see the note below) |
| nginx | `/v1/stats/routability` route added on Pearl 2026-09-24 10:24Z, additively and verbatim from `phase4-coordinator/dist` (backups `*.bak-routability-20260924T102404Z`). Pearl's nginx still lags the repo on `/v1/catalog-artifacts`, `/v1/portal/session` and `/v1/provider/malibu-reward-audit`, and carries a hand-deployed `/v1/provider/model-admission/` (BYOM) route the repo lacks, so **do not copy the repo site file over it**. |

Signed prerelease `v1.8.189` at `0ac51afa` exists and is immutable, but it was
**not applied**. Its full deploy failed closed before any Pearl mutation because
repository-level catalog verification was invoked from a history-free bounded
archive (#1717). #1718 fixed that deploy boundary; replacement runtime
`v1.8.190` was signed and applied successfully. The next runtime tag is reserved
as `v1.8.191` for the post-v1.8.190 changes listed below.

**2026-09-25 v1.8.194 apply (partial).** The signed updater applied the v1.8.194 binary pair at 03:05Z (`rollout_completed success`; updater reinstalled from the tag first). The full `deploy-pearl-vps.sh` at 03:22Z reached `compare-live` = `descends` with 0 uncovered providers, then failed its SPEC-023 exact-byte canary and **rolled back** at about 03:35Z. There was about 30 s of public 502 during the rollback restart. Why: the canary Mac `mp-26592d…` runs CLI 1.8.123. Its `~/macprovider/catalog-release` holds the Sep 8 baked `published-2026-09-02-gpt-oss-120b-v1` files, and only a signed CLI payload writes that directory, so no restart can make it byte-equal to the new release. Live now: coordinator/gateway v1.8.194 binary, catalog still `published-2026-09-23-tier2-buyer-closure-v1`. `stats-inventory-sync` is left stopped by the rollback: #1738 migration 030 is applied and the old sidecar is held. Recover per the coordinator-deploy-recover runbook. #1735 catalog activation still needs a canary whose installed CLI payload carries `published-2026-09-25-artifact-hash-correction-v1`. Fleet impact of the attempt: the new catalog was live 03:31:04–03:35:11Z. Coordinator-sourced providers picked it up, and after the rollback the Studio mp-5aad… was closed 3 times with `4001 catalog_incompatible` (03:35:51–03:37:27Z) until it refetched the old release. No closes after 03:37:40Z. By 03:45Z all 5 providers were back and `current` on `published-2026-09-23-tier2-buyer-closure-v1`, with no model-admission revocations. A rolled-back activation therefore briefly kicks every provider that fetched the new release. Providers load the coordinator's live signed catalog, and a baked catalog is only a fallback, so a CLI carrying a newer baked catalog advertises whatever Pearl serves.

**2026-09-25 catalog deploy, v1.8.196–v1.8.200.** Taken over from the #1735 session. The #1735 catalog went live only with v1.8.200. Each earlier attempt hit a separate deploy-tooling defect:
- **v1.8.196.** The exact-byte canary built its expected set from 7 of the 9 files the Mac proof hashes, missing the rate card and its sidecar, so it could never pass. Fixed by #1746.
- **v1.8.196 retry.** The canary passed, but the new `stats-billing-mirror` unit read the empty `/var/lib/macprovider/request-log.sqlite`, and its initial run aborted the deploy. Fixed by `c6c32692`, which reads `coordinator.db`.
- **v1.8.197.** Codex R1 found that the unit also listed `coordinator.db` in `InaccessiblePaths`. Fixed by `ee061fc3`; R2 passed.
- **v1.8.198.** The root disk was 100% full because the updater keeps every transaction snapshot. Staging vanished, and the watchdog restore failed with ENOSPC; it recovered after space was freed. On retry the canary passed, but the stats smoke hit the post-restart `stats_stale` 503. Fixed by `4936a062` (bounded 360 s retry).
- **v1.8.199.** #1719's billing migration ran a whole-DB `PRAGMA quick_check` (4.8 GB) before listening, and the updater health window rolled it back, with about 8 min of coordinator downtime. Fixed by `ca809589` (schema-only verification).
- **v1.8.200.** Applied with the updater health timeout temporarily at 300 s, then restored to 60. The deploy completed.

The canary Mac mp-26592d… now runs signed CLI candidate v1.8.195, whose payload `catalog-release/` is byte-identical to this release. Pearl `accepted_ids` carries `v1.8.195@03627cda…` in place of v1.8.172 (backup `coordinator.yaml.bak-accept-195-20260925T054520Z`).

### Recent coordinator releases

| Tag | Commit | Head PR |
|---|---|---|
| v1.8.200 | `ca809589` | #1719 (#1690) with the quick_check fix; #1738, #1741, #1744 catalog, #1746 and the deploy fixes — **live** |
| v1.8.199 | `4936a062` | #1719; binary rolled back by the updater (startup quick_check), never live |
| v1.8.196–v1.8.198 | `1148185e`, `c6c32692`, `ee061fc3` | binaries applied by the updater; each full catalog deploy rolled back (see note above) |
| v1.8.194 | `98ff77ca` | #1744 (#1735) binaries only; full deploy rolled back on the canary |
| v1.8.193 | `9e5aac90` | #1713 (#1689) coordinator side; `fe4b4a0c` |
| v1.8.191 | `98e3e4af` | #1728 settlement-hold recovery |
| v1.8.190 | `0a63ddab` | #1718 deploy-boundary replacement; also includes #1714/#1715 and the feed-bundle fix |
| v1.8.188 | `57022da8` | #1711 WAL maintenance no longer starves completed buyer work |
| v1.8.187 | `afbee248` | #1710 recover held settlements after transient finality failures |
| v1.8.185 | `a89bef31` | #1704 receipt verification off the contended money writer |
| v1.8.183 / v1.8.184 | `b0ebce88` | #1699 route-snapshot evidence pressure (two tags on one commit) |
| v1.8.182 | `710255f4` | #1692 signed Tier-2 buyer identity coverage (17 models) |
| v1.8.180 | `34a835e1` | #1686 Qwen3.6 artifact identity |
| v1.8.179 | `3554fedd` | #1685 buyer settlement evidence classification |
| v1.8.178 | `6cb08488` | #1684 serving after delayed WS occupancy reports |
| v1.8.177 | `025036b2` | #1674 four seats admit four chats after late busy report |

## Catalog on Pearl

| Field | Value |
|---|---|
| `autotune/current` | `published-2026-09-25-artifact-hash-correction-v1` (activated 2026-09-25 about 10:13Z) |
| Tier-2 catalog | `macprovider-tier2-model-catalog-2026-09-25-artifact-hash-correction-v1`, 17 models, expires **2026-12-25** |
| Retained window | `…2026-09-23-tier2-buyer-closure-v1`, `…2026-09-22-qwen36-27b-hash-fix-v1`, `…2026-09-19-openrouter-priced-v1` |

Renew the Tier-2 catalog before 2026-12-25. An expiry-only re-sign stays in
the freshness lane.

The scheduled feed renewal on 2026-09-23 **failed closed**, with no mutation. The
renewal shipped only `catalog-release.py` to Pearl, so the under-lock
continuity-check could not import `openrouter_pricing_engine.py`. It is fixed on
`main` in `314d3fbc` (see the table below). The live feed still dates from the
v1.8.182 release on 2026-09-23, so the 30-day provider freshness limit falls
around 2026-10-23. The fix takes effect at the next renewal (Wed 2026-09-30
16:00 UTC), or earlier with a manual dispatch of
`renew-autotune-static-feed-signed.yml`.

## Next coordinator release — net changes vs v1.8.200

| Net change in coordinator / gateway / Pearl assets | Status | PR |
|---|---|---|
| Build 1 Lane A orchestrated PR | in progress | #1658 (#1642) |
| Pricing corrections through the catalog-content lane (SPEC-005-R013, SPEC-023-R018, SPEC-006-R008 amended). Coordinator: request billing table and served signed rate card switch under one economics lock (release lock → economics lock → feed lock), prices resolved once before the billing write context; `--validate-autotune-release` gains `--expect-base-equivalent` and `--resolve-model-names` plus `rate_table_sha256` / `signed_rate_card_sha256` verdict fields; applied-config record gains `rate_table_sha256`, `signed_rate_card_sha256`, `autotune_release_id`, `billing_snapshot_id`. **Wholesale statements change**: each request is priced at the generation it was recorded under (uncapped aggregate math), so a model-month above 10M tokens is no longer zeroed — affected partner statements go **up**; a period with no billing snapshot now fails closed. Lane tooling that deploy ships: `scripts/catalog-release.py` (splice / extract / effective-price diff / gate), new `acknowledged-pricing-moves.json`; still to land in the same PR: journal + pre-start recovery + post-start closer units, the one-writer guard on every live-config writer, lane preflight/evidence/rollback. **Enabling rollout is two steps from the same tag, in order**: (1) reinstall the Pearl updater bundle (`install-pearl-updater.sh`: guard-bearing updater, Tier-2 watchdog, Python guard module), then (2) a full `deploy-pearl-vps.sh` (new units, recovery helper, shell guard, verifier bundle) — never a binary swap. Pricing preflight hashes every installed writer against the commit, so a deploy without step 1 stays NO_GO. Procedure: `catalog-release-decision-tree.md` §Enabling rollout. Afterwards rows-only pricing needs no coordinator release. Plan (approved 0C/0H/0M): [#1693 comment](https://github.com/Augustas11/macprovider/issues/1693#issuecomment-5800624020) | in progress (draft; merge gated on the e2e fake-Pearl run) | #1732 (#1693) |

## Open Pearl actions (not new code)

- **Gateway settlement trailers enforced (2026-09-25 about 10:21Z).** The #1690 session set `coordinator.require_settlement_trailers: true` in `/opt/macprovider/gateway.yaml` (backup `gateway.yaml.bak-require-trailers-20260925T102055Z`) and restarted the gateway. Proof requests settled with hold 0 and `spec022_verified`, with no `missing_settlement_finality_trailer`.
- **Coordinator start-to-listen budget.** v1.8.198 takes 25–44 s from start to listen on Pearl, against the updater's 60 s health window. Most of it is `normalizeBillingTimeTextColumns`, which rescans 11 timestamp columns on every start, plus the unindexed `provider_reported_prompt_tokens` backfill. Make both one-time (a done-marker) or run them after the listener before the DB grows further.
- **Held reservation backlog (pre-existing).** `gateway.db` has 47,408 `status=active AND settlement_hold=1` reservations: 46,028 on `acct_902fdfc…` (likely the synthetic buyer) and 1,368 on the OpenRouter account, dating back before 09-11, with none new since 10:00Z on 09-25. The periodic reconciler re-queries all of them on every sweep. They need an operator resolution pass.
- **Pearl updater snapshot retention (2026-09-25).** `macprovider-pearl-update` keeps every transaction snapshot under `/var/lib/macprovider-pearl-updater/transactions` (about 6 GB each, a DB copy) with no retention. It filled `/` to 100%. 29 old snapshots were removed at about 09:03Z, and v1.8.197 onwards remain. Each apply also stops the coordinator for about 6 min while it copies the DB. Both need an updater change: retention, plus a snapshot that doesn't block serving.

These came with #1706 but are not active on Pearl, because the recent releases
were applied as binary swaps. Evidence: the live unit file is dated 2026-07-23,
while the binary is dated 2026-09-23.

1. **Install the current `macprovider-coordinator.service`**, which adds
   `RuntimeDirectory=macprovider`. Without it the coordinator cannot write
   `/run/macprovider/coordinator-applied-config.json`: the record is missing
   today, so the catalog-content lane's `config_applied` preflight is **NO_GO**.
   The next full `deploy-pearl-vps.sh` run from a tag ≥ `2b352720` installs it.
2. **Reinstall the Pearl updater** (`ops/pearl-updater/install-pearl-updater.sh`)
   so it ships the full verifier bundle and `autotune_window.py`. Its installed
   scripts are still `catalog-release.py` and `sign-catalog.go` only. The updater
   timer is disabled, so this is not urgent on its own — but it becomes a
   **prerequisite of the #1693 enabling rollout** (step 1 there; pricing preflight
   hashes the installed updater, watchdog and guard module).
3. After (1), run `scripts/catalog-content-release.sh --preflight --commit
   <main sha>` once to confirm the lane reaches GO on a real content change.
4. **After the coordinator carrying #1714 is live (≥ `3abf42a8`)**, list the
   fleet's CLI-baked catalog as row-continuity evidence. Until then, idle
   1.8.123 providers on the baked `published-2026-09-02-gpt-oss-120b-v1` are
   kicked (`4001 catalog_incompatible`) by every content cut until Malibu
   restarts. The 2026-09-23 recurrence was #1705.
   - Confirm `/opt/macprovider/autotune/releases/published-2026-09-02-gpt-oss-120b-v1*`
     still has `autotune-candidates.json` + `.sig`.
   - Write that `releases/<dir>` line to
     `/opt/macprovider/autotune/.row-continuity-target` (at most 8 lines;
     deploy, renewal and rollback never rewrite it), then SIGHUP the coordinator.
   - Verify: the journal shows no `autotune row-continuity catalog … ` load
     error, and `/admin` shows those providers with
     `catalog_admission_mode = row_continuity`.
   - Exact commands: `docs/runbooks/autotune-feed-renewal.md` → "Row-continuity
     evidence".
   - Add a line for each future CLI whose baked catalog the fleet still runs.
     Remove a line once no provider advertises that release.
   - SPEC-023-R010 stays `pending` in CONFORMANCE until a content cut is
     observed that does not kick unchanged-row providers.

## Apply checklist (per coordinator release)

1. All in-scope rows above are `merged`; no row you need is `in progress`.
2. Pick the next unused `v1.8.N` (check both trains), create a signed tag on
   the `main` tip, and dispatch `pearl-runtime-release.yml` once.
3. Apply with the full deploy scripts from a clean checkout of the tag, not a
   binary swap, whenever `dist/`, units, nginx, or the verifier bundle changed
   since the last full deploy.
4. Verify:
   - `/healthz` on coordinator and gateway reports the tag;
   - the deploy's catalog step logged `equivalent`, `descends`, or an
     intentional override;
   - the retained window still holds the immediate predecessor;
   - `verify-live-coordinator-release-rollout` passes.
5. Update this file: "Live on Pearl", "Recent coordinator releases", and reset the
   net-changes table. Put an entry in the CLI train only if the tag number or
   the recommendation matters there.

## Session protocol

- Update this file when a coordinator-affecting PR merges, a coordinator tag is cut or
  applied, or a catalog-content release goes live. If the update is **only**
  this file (or other docs), push direct to `origin/main`: no PR, and do not
  wait for CI. If it rides with a code change, put it in that PR.
- If a live incident needs a hotfix coordinator cut, record the owner and the tag
  here **before** dispatch, so a parallel session does not cut the same number.
