# Runtime Release Train — Pearl coordinator / gateway

**This file is the single source of truth for Pearl runtime releases** (the
coordinator and gateway binaries plus the Pearl-side deploy assets). The
provider CLI has its own train: `docs/releases/cli-release-train.md`. Work
happens across many sessions and agents: read this file before cutting or
applying a runtime release, and update it in the same commit or PR after any
release-affecting action. If reality and this file disagree, fix this file.

## How to track the next runtime

The table below is the net change against the **live** Pearl runtime.

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
3. A runtime release is cut and applied. Move the live row, delete the shipped
   rows, and start a new table.

Do not list spec-only or CONFORMANCE-only PRs. List catalog-content releases
under "Catalog on Pearl", not as runtime rows: since #1706 they do not need a
runtime release (see "Which lane" below).

## Core rules (do not violate)

- **Runtime tags share the `v1.8.N` namespace with CLI candidates.** For
  example, `v1.8.176`, `v1.8.181` and `v1.8.186` are CLI candidate numbers.
  - Take the next unused number.
  - Record it here and in the CLI train, so the two trains never reuse a tag.
  - Check with `git tag -l 'v1.8.*' | sort -V | tail`, and read both train files.
- **A runtime release never changes the provider binary recommendation.**
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
| Coordinator/gateway code, config template, units, nginx, deploy scripts | **This train** (runtime release) |
| Catalog content only: model hash/row/Tier-2 correction, same policy/keys/signers | Catalog-content lane (`scripts/catalog-content-release.sh`), no runtime release |
| Rate-card rows (pricing) | This train, until #1693 lands |
| Weekly feed freshness | Automatic renewal (Wednesday); never a runtime release |
| `policy_version`, keyring, CLI payload | Full provider-app release (CLI train) |

A runtime deploy compares the tag's catalog with live (`compare-live`):
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

### Recent runtime releases

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

## Next runtime — net changes vs v1.8.188

| Net change in coordinator / gateway / Pearl assets | Status | PR |
|---|---|---|
| Keep unchanged catalog rows admitted across catalog publishes | merged | #1714 (#1705) |
| Node operator status, safe context changes, model diagnostics | in progress | #1713 (#1689) |
| Build 1 Lane A orchestrated PR | in progress | #1658 (#1642) |

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

## Apply checklist (per runtime release)

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
5. Update this file: "Live on Pearl", "Recent runtime releases", and reset the
   net-changes table. Put an entry in the CLI train only if the tag number or
   the recommendation matters there.

## Session protocol

- Update this file when a runtime-affecting PR merges, a runtime tag is cut or
  applied, or a catalog-content release goes live. If the update is **only**
  this file (or other docs), push direct to `origin/main`: no PR, and do not
  wait for CI. If it rides with a code change, put it in that PR.
- If a live incident needs a hotfix runtime cut, record the owner and the tag
  here **before** dispatch, so a parallel session does not cut the same number.
