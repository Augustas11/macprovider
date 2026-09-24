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
| Rate-card rows (pricing) | This train, until #1693 lands (in progress: after its enabling coordinator release, rows-only corrections move to the catalog-content lane; `usd_per_million_credits` / share / multiplier stay on this train) |
| Weekly feed freshness | Automatic renewal (Wednesday); never a coordinator release |
| `policy_version`, keyring, CLI payload | Full provider-app release (CLI train) |

A coordinator deploy compares the tag's catalog with live (`compare-live`):
- `equivalent`: keeps live.
- `descends`: activates the tag's catalog.
- `regression`: aborts unless `CATALOG_REGRESSION_OVERRIDE_REASON` is set (the override is logged).

## Live on Pearl

Probed 2026-09-24 (`/healthz` and read-only host checks).

| Field | Value |
|---|---|
| Coordinator | **v1.8.188** @ `57022da8` (#1711), running since 2026-09-23 16:30Z |
| Gateway | **v1.8.188** |
| Release | [Pearl runtime v1.8.188](https://github.com/Augustas11/macprovider/releases/tag/v1.8.188), 2026-09-23 16:24Z |
| `recommended_binary_version` | 1.8.123 (CLI train owns this) |
| Includes | Everything on `main` through #1711, including #1706 (content lane code), #1703 and #1702 |

Signed prerelease `v1.8.189` at `0ac51afa` exists and is immutable, but it was
**not applied**. Its full deploy failed closed before any Pearl mutation because
repository-level catalog verification was invoked from a history-free bounded
archive (#1717). #1718 fixed that deploy boundary on `main`; the replacement
runtime cut is reserved as `v1.8.190`.

### Recent coordinator releases

| Tag | Commit | Head PR |
|---|---|---|
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
| `autotune/current` | `published-2026-09-23-tier2-buyer-closure-v1` |
| Tier-2 catalog | `macprovider-tier2-model-catalog-2026-09-23-buyer-closure-v1`, 17 models, expires **2026-12-23** |
| Retained window | 3 entries: `…2026-09-22-qwen36-27b-hash-fix-v1`, `…2026-09-19-openrouter-priced-v1`, `…2026-09-19-openrouter-listed-v1` |

Renew the Tier-2 catalog before 2026-12-23. An expiry-only re-sign stays in
the freshness lane.

The scheduled feed renewal on 2026-09-23 **failed closed**, with no mutation. The
renewal shipped only `catalog-release.py` to Pearl, so the under-lock
continuity-check could not import `openrouter_pricing_engine.py`. It is fixed on
`main` in `314d3fbc` (see the table below). The live feed still dates from the
v1.8.182 release on 2026-09-23, so the 30-day provider freshness limit falls
around 2026-10-23. The fix takes effect at the next renewal (Wed 2026-09-30
16:00 UTC), or earlier with a manual dispatch of
`renew-autotune-static-feed-signed.yml`.

## Next coordinator release — net changes vs v1.8.188

| Net change in coordinator / gateway / Pearl assets | Status | PR |
|---|---|---|
| Keep unchanged catalog rows admitted across catalog publishes (SPEC-023 v0.15.1 R010: `.row-continuity-target` evidence, `row_continuity` admission, re-check on every publication). Also changes `dist/deploy-pearl-vps.sh`, `scripts/lib/autotune-activate.sh`, `scripts/catalog-content-release.sh` and `scripts/autotune_window.py`, so **needs a full deploy**, not a binary swap. Post-apply step: Open Pearl action 4 | merged `3abf42a8` | #1714 (#1705) |
| Preserve served buyer success through transient receipt persistence pressure: bounded in-memory receipt retry, explicit pending coordinator authority, durable deadline closure, and gateway rechecks for held settlement. Requires a signed coordinator/gateway release and fresh Studio buyer soak before acceptance. Cut owner: Studio settlement recovery. `v1.8.189` was signed but its deploy failed closed before mutation; replacement tag `v1.8.190` is reserved. | merged `8056224f` | #1715 (#1680) |
| Feed renewal ships the whole catalog verifier bundle to Pearl. It was fixed because the 2026-09-23 renewal aborted when ssh swallowed the bundle manifest in `aa_install_helpers`. This is renewal tooling that runs from `main`: it needs **no coordinator release** and takes effect at the next renewal. It is not in `v1.8.189`, whose tag predates it; the `v1.8.190` full deploy will also install these current assets. Regression test: `scripts/test-autotune-install-helpers.sh` | merged `314d3fbc` | #1688 follow-up |
| Run repository-level catalog verification from a complete archive of the signed release commit, with isolated Python, replacement objects disabled, and ledger evolution pinned to the signed commit's parent. The bounded verifier bundle remains the authority for staged and remote `verify-directory`. This closes the fail-closed `v1.8.189` deploy blocker and therefore requires the replacement full deploy. | merged `248368f9` | #1718 (#1717) |
| Node operator status, safe context changes, model diagnostics | in progress | #1713 (#1689) |
| Build 1 Lane A orchestrated PR | in progress | #1658 (#1642) |
| Pricing corrections through the catalog-content lane (SPEC-005-R013, SPEC-023-R018, SPEC-006-R008 amended). Coordinator: request billing table and served signed rate card switch under one economics lock (release lock → economics lock → feed lock), prices resolved once before the billing write context; `--validate-autotune-release` gains `--expect-base-equivalent` and `--resolve-model-names` plus `rate_table_sha256` / `signed_rate_card_sha256` verdict fields; applied-config record gains `rate_table_sha256`, `signed_rate_card_sha256`, `autotune_release_id`, `billing_snapshot_id`. **Wholesale statements change**: each request is priced at the generation it was recorded under (uncapped aggregate math), so a model-month above 10M tokens is no longer zeroed — affected partner statements go **up**; a period with no billing snapshot now fails closed. Lane tooling that deploy ships: `scripts/catalog-release.py` (splice / extract / effective-price diff / gate), new `acknowledged-pricing-moves.json`; still to land in the same PR: journal + pre-start recovery + post-start closer units, the one-writer guard on every live-config writer, lane preflight/evidence/rollback. **Needs a full deploy** (new units, recovery helper, verifier bundle), not a binary swap; this is the one enabling release — afterwards rows-only pricing needs no coordinator release. Plan (approved 0C/0H/0M): [#1693 comment](https://github.com/Augustas11/macprovider/issues/1693#issuecomment-5800624020) | in progress (branch `feat/1693-pricing-content-lane`, PR not yet open) | #1693 |

## Open Pearl actions (not new code)

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
   timer is disabled, so this is not urgent.
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
