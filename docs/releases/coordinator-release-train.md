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
- **A runtime-only updater apply is the narrow lane when only coordinator or
  gateway binaries changed and catalog activation must remain held.** It must
  use a signed `pearl_runtime` prerelease and leaves Pearl's live catalog path
  unchanged. Do not follow it with a full deploy when that would activate a
  held catalog descendant.
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

Probed 2026-10-02 (`/healthz`).

| Field | Value |
|---|---|
| Coordinator | **v1.8.211** @ `5550efd47`. Applied 2026-10-02 at 13:12Z through the signed runtime updater; local and public `/healthz` reported `v1.8.211`. |
| Gateway | **v1.8.211** (`gateway.db` schema 17; `coordinator.require_settlement_trailers: true`). The live `api.malibu.tech` nginx carries certbot TLS and `/ws/provider` routes absent from the repo template. **Never run the gateway `deploy-pearl-vps.sh`**; use the signed runtime updater for binary-only releases. |
| Release | [Pearl runtime v1.8.211](https://github.com/Augustas11/macprovider/releases/tag/v1.8.211), immutable runtime-only prerelease; build run [37007168564](https://github.com/Augustas11/macprovider/actions/runs/37007168564). The apply preserved the live September 25 catalog; no full deploy followed it. |
| `recommended_binary_version` | 1.8.207 (CLI train owns this) |
| Includes | Everything on `main` through `5550efd47`, including #1801, #1812, #1818, #1822/#1823/#1825, #1831 and #1833. |
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
| v1.8.211 | `5550efd4` | #1833 crash-safe bounded settlement maintenance — **live** |
| v1.8.210 | `6756706b` | #1831 bounded SQLite evidence maintenance; also #1801, #1812, #1818 and runtime dependency updates |
| v1.8.209 | `5245dc9f` | #1804 Qwen3.6 OpenRouter capabilities |
| v1.8.208 | `bc276ea5` | #1783 (#1752 operator drain) |
| v1.8.206 | `40ed8752` | #1779 (#1775 money-writer starvation), #1781 (updater snapshot timeout), #1782 (gateway schema-15 upgrade); also carries #1754, #1763, #1769, #1732, #1658 |
| v1.8.205 | `3ca8e792` | rolled back: gateway schema-15 migration (`no such column: operator_review`) |
| v1.8.204 | `dfd1586f` | rolled back: updater snapshot integrity_check exceeded 300 s |
| v1.8.200 | `ca809589` | #1719 (#1690) with the quick_check fix; #1738, #1741, #1744 catalog, #1746 and the deploy fixes |
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

Catalog-content and pricing rollout state is tracked in
`docs/releases/catalog-release-train.md`. This section records Pearl's currently
served catalog state and coordinator-train interactions.

| Field | Value |
|---|---|
| `autotune/current` | `published-2026-09-25-artifact-hash-correction-v1` (activated 2026-09-25 about 10:13Z) |
| Tier-2 catalog | `macprovider-tier2-model-catalog-2026-09-25-artifact-hash-correction-v1`, 17 models, expires **2026-12-25** |
| Retained window | `…2026-09-23-tier2-buyer-closure-v1`, `…2026-09-22-qwen36-27b-hash-fix-v1`, `…2026-09-19-openrouter-priced-v1` |

Renew the Tier-2 catalog before 2026-12-25. An expiry-only re-sign stays in
the freshness lane.

**First artifact-feed activation (GGUF), pending — held.** #1754 put the first
GGUF catalog artifact in the source: `gguf-q4-k-m` for
`meta-llama/llama-3.2-3b-instruct`, the verified
`bartowski/Llama-3.2-3B-Instruct-GGUF@5ab33fa9` Q4_K_M file. It also added the
17 measured MLX `size_bytes`. `catalog-release.py status` passes every check
except "current release_id is new". Activation is a **full-provider-app**
lane cut:
1. Choose a new `release_id`.
2. Cut and sign with the operator-held `streamvc-autotune-static-v4` key.
3. Deploy with `autotune.catalog_artifacts_path` and the additive
   `/v1/catalog-artifacts` nginx route.

A coordinator older than the #1719 build cannot start on a feed that carries
`file_path`, so every coordinator rollback afterwards needs runbook §9 step 4a.
CLIs before #1754 (SPEC-023 v0.19.1) reject a feed with the GGUF Hugging Face
tuple as `catalog_artifact_feed_integrity_failure`. That fails closed for
artifact-derived features only, but the CLI train should ship a #1754-bearing
candidate first. Not started: the user holds Pearl changes.

The scheduled feed renewal on 2026-09-23 **failed closed**, with no mutation. The
renewal shipped only `catalog-release.py` to Pearl, so the under-lock
continuity-check could not import `openrouter_pricing_engine.py`. It is fixed on
`main` in `314d3fbc` (see the table below). The live feed still dates from the
v1.8.182 release on 2026-09-23, so the 30-day provider freshness limit falls
around 2026-10-23. The fix takes effect at the next renewal (Wed 2026-09-30
16:00 UTC), or earlier with a manual dispatch of
`renew-autotune-static-feed-signed.yml`.

## Next coordinator release — tag unassigned, net changes vs v1.8.211

`v1.8.211` was applied through the signed runtime-only updater on 2026-10-02.
The next tag must be selected only after checking the shared coordinator/CLI
namespace. Do not deploy this train before the current v1.8.211 evidence window
is captured at **2026-10-03 13:12:23 UTC**, 24 hours after the final successful
v1.8.211 coordinator start. That boundary supersedes the earlier v1.8.210
09:15:09 UTC boundary.

| Net change in coordinator / gateway / Pearl assets | Status | PR |
|---|---|---|
| Stage 3A money-path evidence journal: provider credit and compact attempt-output evidence commit atomically in SQLite; indexed bounded materialization, poison-safe retention, receipt-time on-demand projection, fail-closed evidence checks, and journal health metrics. | merged `502516d52` 2026-10-03; not live | [#1835](https://github.com/Augustas11/macprovider/pull/1835) |

### Stage 3A release and next-development sequence

1. **Finish the v1.8.211 baseline window first.** At or after
   2026-10-03 13:12:23 UTC, attach the uninterrupted-window evidence to #1775
   and #1793: coordinator start identity, hot-path wait/error counters, newest
   and aged payability cohorts, terminal evidence-loss counts, route-journal
   health, audit-outbox pending/poison/oldest-age and drain-rate deltas, weekly
   catch-up status, and rollback-snapshot disk usage. Do not call a merely
   shrinking backlog steady-state proof.
2. **Cut one reviewed runtime-only release from current `main`.** Select the
   next unused shared `v1.8.N` tag, reserve it in both release trains, build the
   signed coordinator/gateway pair through `pearl-runtime-release.yml`, obtain
   the protected-environment approval, and run the independent repository
   release verifier. Preserve the live catalog, provider recommendation,
   operator nginx, and normal 60-second updater health setting.
3. **Apply Stage 3A through the transactional updater.** Record the preflight
   disk budget and rollback snapshot, apply once, and prove local/public health,
   provider recovery, buyer serving, schema initialization, updater
   `already_current`, and no armed transaction. Any restart establishes a new
   24-hour acceptance boundary.
4. **Run the Stage 3A evidence window.** Require zero hot-path write failures,
   zero terminal evidence loss or false missing-evidence refunds, bounded
   journal pending age, zero unacknowledged poison growth, materialization that
   keeps pace with arrivals, and an audit outbox whose drain rate exceeds its
   arrival rate. Also prove settlement catch-up completes and record buyer
   latency before declaring the SQLite stage complete.
5. **Then begin Stage 4 under #1793.** Land the Postgres ledger/evidence schema,
   migration and reconciliation tooling, and async dual-write while SQLite
   remains read-authoritative. No production schema migration, read switch, or
   settlement cutover occurs before the protected staging run sustains 30
   requests/s for 24 hours with parity and rollback evidence. Read, settlement,
   and hot-path cutovers remain separate later gates; retention/export,
   backup/restore, updater snapshot retention, and operator runbooks remain
   Stage 6.

**2026-10-02 v1.8.211 apply.** The protected release built the immutable signed
runtime from exact tag commit `5550efd47`; repository verification passed and
the runtime-only lane preserved the provider recommendation, operator nginx,
and live catalog. The first apply failed closed at 12:51Z because creation of
the new recovery/outbox indexes on the 9+ GB money database exceeded the normal
60 s coordinator health window. The updater rolled coordinator and gateway
back to v1.8.210, restored serving and provider readiness, and left no armed
transaction. Following the bounded precedent used for v1.8.200, the service
health window was temporarily raised to its supported 300 s maximum. The
second transaction created its snapshot at 13:08:49Z, completed one-time store
initialization in about 204 s, began listening at 13:12:23Z, and passed local
and public health, provider recovery, serving, TLS identity, and ready-provider
gates at 13:12:30Z. The configured health window was then restored to 60 s;
the updater reports `already_current` and no transaction is armed.

Immediate evidence at 13:14Z: six of seven providers were policy-ready; the
outbox gauge was fresh and declined from the pre-release 210,406 rows to
170,402, with 8,642 rows drained since process start and 106 poisoned rows
still open. Short 200 ms drain attempts recorded 425 successes and 131 deadline
errors, so the drain is making progress but has not yet proven sustained
capacity. Route evidence recorded 37 durable journal inserts, 727 successful
materializations and one materializer error; primary route inserts recorded 35
successes and two errors. The bounded weekly settlement catch-up is active but
still reports more historical unmarked windows after each four-window pass.
The failed and successful attempts retained two new 12 GB rollback snapshots;
68 GB remained free. This production observation does not satisfy #1793's
30 requests/s for 24 hours acceptance gate or close its retention, backlog,
SLO, Postgres, and rollback work.

**2026-10-02 v1.8.210 apply.** The protected release built the signed runtime
pair from exact tag commit `6756706b`; the repository release verifier passed,
and Pearl's updater completed the schema-15-to-17 transaction with an 11 GB
rollback snapshot. Public coordinator and gateway health both reported
`v1.8.210`, the updater reported `already_current`, services were active, and
the live catalog symlink remained
`published-2026-09-25-artifact-hash-correction-v1-d9e402203f81679e`.
Demand telemetry recorded three privacy-bucketed paid smokes: one served Llama
request, one capacity-constrained Qwen request, and one unknown-model request.
The new checkpoint owners were non-busy and successful; all 78 observed billing,
settlement-output and settlement-receipt transactions succeeded. Route snapshot
materialization recorded 163 successes and one classified deadline error, while
the durable journal recorded 89 successes. The outbox drainer demonstrated its
bounded five-batch catch-up (five consecutive 100-row batches), but its
stats/prune queries continued to hit short deadlines and later drain passes were
skipped under active buyer traffic. The initial zero-pending gauge was therefore
stale, not proof of an empty backlog: a direct indexed count at 09:22Z found
210,406 pending rows, 106 unacknowledged poisoned rows, and 756,281 retained
rows. The deferred billing startup scan also reached its designed 30 s timeout
after listeners were already serving. Durable evidence and buyer serving stayed
healthy, but the growing historical outbox remains open scaling work under
#1793 rather than a quiet-rollout or backlog-closure claim.

## Open Pearl actions (not new code)

- **Gateway settlement trailers enforced (2026-09-25 about 10:21Z).** The #1690 session set `coordinator.require_settlement_trailers: true` in `/opt/macprovider/gateway.yaml` (backup `gateway.yaml.bak-require-trailers-20260925T102055Z`) and restarted the gateway. Proof requests settled with hold 0 and `spec022_verified`, with no `missing_settlement_finality_trailer`.
- **Coordinator start-to-listen budget — code merged, rollout pending.** v1.8.198 takes 25–44 s from start to listen on Pearl, against the updater's 60 s health window. #1763 makes the timestamp normalization and prompt-token split repairs one-shot and moves the settlement startup scan behind the listeners under a 30 s timeout. The next coordinator release must prove listener timing and check for `billing startup scan failed` before this action is closed; a timed-out scan is recovered by the existing nightly/admin reconcile paths.
- **Held reservation backlog — bounded code merged, operator drain pending (#1752).** The 2026-09-25 snapshot found 47,408 `status=active AND settlement_hold=1` reservations: 46,028 on `acct_902fdfc…` (likely the synthetic buyer) and 1,368 on the OpenRouter account, dating back before 09-11, with none new since 10:00Z on 09-25. #1763 prevents repeated full sweeps by selecting due rows, persisting backoff/review state and exposing backlog age/count telemetry, but deliberately does not move money or release quota for ambiguous rows. After the release is live, audit the backlog categories, resolve them through the operator procedure, and record the drain evidence on #1752.
- **Raw coordinator config boundary — code merged, rollout pending.** #1763 keeps the raw Pearl `coordinator.yaml` and overlay on Pearl during deploy validation/migration; only sanitized normalized projections leave the host. Confirm the next full deploy reports exact remote config hashes and completes its config-mode/C2 precheck without creating local raw-config artifacts.
- **Auto-prefix cache billing — code merged, rollout pending (#1769 / #1768).** After the coordinator rollout, send a growing multi-turn streaming conversation with `stream_options.include_usage`. On a warm first attempt, verify that flat `usage.cached_prompt_tokens` is positive and equals `usage.prompt_tokens_details.cached_tokens`; then confirm the matching `ledger_request_credits.cached_prompt_tokens` is positive, the prompt charge uses the uncached-at-prompt-rate plus cached-at-cache-hit-rate split, and the billing-time routing decision records the same effective cached count. `sticky_result = no_key` is expected for this authenticated cache-only path and must not quarantine the row. A provider CLI or gateway rollout is not part of this fix.
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
   - if the release includes #1769, the warm-turn buyer usage and matching
     ledger/routing evidence pass the auto-prefix cache-billing check above.
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
