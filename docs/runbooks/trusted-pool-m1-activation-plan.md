# #1690 M1: first production Trusted Pool activation plan (llama.cpp member)

**Status:** prepared 2026-09-25, not executed. **Issue:** #1690 (epic PR #1719,
merged as `747557cc`). **Governing rules:** SPEC-022 v0.2.2 R-12 / R-12.8,
SPEC-042 v0.0.34 (R001 policy-core/v2, R006 labels, R013, R014), SPEC-023
v0.17.1 §3.7, SPEC-047-R003(iv), SPEC-015 0.4.10 R006. **Operator sequence
this plan follows:** [`trusted-pool-production-launch.md`](trusted-pool-production-launch.md)
§4 and §9. Lab rehearsals:
[`runtime-agnostic-m6-lab-e2e-evidence-2026-09-24.md`](runtime-agnostic-m6-lab-e2e-evidence-2026-09-24.md),
[`runtime-agnostic-e2e-evidence-2026-09-25.md`](runtime-agnostic-e2e-evidence-2026-09-25.md).

Goal: one operator-owned Trusted Pool on the production coordinator, v2 policy
core with `runtime_allowlist = ["llamacpp_loopback"]`, one llama-server member,
one paid buyer request (non-streaming and streaming) with
`X-MacProvider-Engine-Select: llamacpp` that settles `verified` /
`pool_operator_attested`, credits the provider, debits the buyer exactly the
finality tokens, and produces the signed evidence that moves SPEC-022-R012 from
`pending`.

Every Pearl write below is done by the single Pearl actor of the day, in the
order given. Nothing here is executed by the author of this plan.

## 0. Scope decision: M1 is an operator-internal pool, `launch_environment: candidate`

M1 runs on the production coordinator with a root whose `launch_environment`
is `candidate`, and `trusted_pools.production_activation` stays unset.

Why this and not a SPEC-043 production launch:

- The coordinator routes a `candidate` pool when `production_activation` is
  unset (`trustpool/registry.go:513-529`, `durable_store.go:3377-3380`), and
  the R-12 settlement path (route snapshot labels, v0.4 pool-authorized
  receipt, `pool_operator_attested`, signed finality) is the same code for
  either environment. SPEC-022-R012 needs that path in enforce mode with a
  verified receipt and a ledger credit, nothing more.
- A non-candidate root needs the whole SPEC-043 production gate
  (`production_launch` §1-§7: on-call authority key, signed on-call record,
  HSM/MPC root custody, signed launch evidence, lifecycle owner, R007 timing
  floor). Those gates exist for an external creator (#1233, still open). M1's
  creator, member and buyer are all the operator.
- Setting `production_activation` later makes every `candidate` pool
  unroutable (`pool_unavailable`), so M1 cannot leak into an external launch.
  Retire it before that switch (§6).

Consequence to state in the evidence: M1 is "operator-internal Trusted Pool on
production infrastructure", not a SPEC-043 creator launch. No announcement,
no external buyer, no `public-announcement` record.

## 1. Preconditions (each with a read-only check)

Run on Pearl (`ssh pearl`) unless marked. None of these commands writes.

### P1. Coordinator and gateway run a build that contains `747557cc`

`747557cc` is first contained in tag `v1.8.199` (`4936a062`), but that tag
cannot start on a production-sized DB (its billing migration ran a
whole-database `PRAGMA quick_check`; the updater rolled it back). The first
deployable tag is `v1.8.200` (`ca809589`, quick_check fix), live on Pearl since
2026-09-25 10:03Z. `v1.8.196`,
`v1.8.197` and `v1.8.198` do not contain it.

```bash
# local, any checkout with tags
git fetch origin --tags
git merge-base --is-ancestor ca809589 "$(git rev-list -n1 v1.8.200)" && echo contains
# Pearl
for p in 8443 8444 9443; do curl -s http://127.0.0.1:$p/healthz | grep -o '"version":"[^"]*"'; done
```

Pass: all three report `v1.8.200` or a later tag that contains `ca809589`
(check any later tag with the `merge-base` line). Also confirm the updater
transaction committed (`/opt/macprovider/.coordinator-deploy*.lock` absent,
both units `active`).

State 2026-09-25: `v1.8.199` was applied at 09:34Z and rolled back by the
updater (its billing migration ran a whole-database `PRAGMA quick_check` on the
4.8 GB coordinator DB before listening and missed the 60 s health window).
`v1.8.200` (`ca809589`, with the quick_check fix) was applied at about 10:03Z:
updater rc=0, full deploy `DEPLOY_EXIT=0`, both units on `v1.8.200`. A paid
non-streaming and a streaming request through `api.malibu.tech` then settled
`spec022_verified` (v0.4 receipt `verified_settlement`, debit == ledger,
`X-MacProvider-Engine: mlx_cache`). P1 passes.

### P2. Gateway schema 14

```bash
sqlite3 -readonly /var/lib/macprovider/gateway.db 'SELECT MAX(version) FROM schema_migrations;'
sqlite3 -readonly /var/lib/macprovider/gateway.db "SELECT sql FROM sqlite_master WHERE name='usage_events';" | grep -c pool_operator_attested
```

Pass: `14`, and the CHECK names `pool_operator_attested` (count `1`).
State 2026-09-25 10:03Z: `14` (after `v1.8.200`).

### P3. The deploy's step-6 smoke passed

The step-6 smoke is the `deploy-pearl-vps.sh` post-deploy smoke (stats
overview retry landed in `4936a062`). Read the deploy output the Pearl actor
kept for the `v1.8.200` run, then confirm independently:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://coordinator.malibu.tech/healthz          # 200
curl -s -o /dev/null -w '%{http_code}\n' https://api.malibu.tech/healthz                  # 200
curl -s https://coordinator.malibu.tech/v1/autotune-release | python3 -m json.tool | head  # release id served
python3 scripts/verify-live-coordinator-release-gate.py --help                            # then run it as the deploy does
```

Pass: the deploy log shows the step-6 smoke `ok` and the live release gate
passes. A skipped or timed-out smoke is a fail.

### P4. `coordinator.require_settlement_trailers` is on (runbook §9 step 2a)

```bash
sudo grep -n -A0 'require_settlement_trailers' /opt/macprovider/gateway.yaml
```

Pass: `coordinator:` block has `require_settlement_trailers: true`, and the
gateway was restarted after the change (unit start time later than the file
mtime: `systemctl show macprovider-gateway -p ActiveEnterTimestamp; stat -c %y /opt/macprovider/gateway.yaml`).
State 2026-09-25: key absent (default `false`).

Also watch after the flip (must stay 0 on normal traffic):

```bash
sudo journalctl -u macprovider-gateway --since '-1h' | grep -c missing_settlement_finality_trailer
sqlite3 -readonly /var/lib/macprovider/gateway.db "SELECT COUNT(*) FROM quota_reservations WHERE status='active' AND settlement_hold=1;"
```

### P5. A CLI release with #1690's provider side, accepted by Pearl

The provider side (SPEC-015 0.4.10 pool-authorized loopback receipts,
`PoolRuntimeAuthorization`, WS-tunneled `runtime_source`, the loopback
catalog envelope) is first in `747557cc`. No CLI accepted by Pearl contains
it today:

| accepted_ids entry | commit | contains `747557cc` |
|---|---|---|
| `v1.8.192@9e00f8e0` | #1716 campaign | no |
| `v1.8.195@03627cda` | #1742 (CB) | no |
| older (`1.8.117`-`1.8.186`, `1.8.123` target) | | no |

Public "Latest" is `macprovider-cli v1.8.123`. So P5 needs a new signed
acceptance candidate (see §3.5 for why it must be cut after the catalog
release). Check:

```bash
sudo grep -n -A12 'compatibility_set:' /opt/macprovider/coordinator.yaml
# local: the candidate's commit contains the merge
git merge-base --is-ancestor 747557cc <candidate-commit> && echo ok
```

Pass: an `accepted_ids` entry `Augustas11/macprovider:v<ver>@<commit>` whose
commit contains `747557cc` and the §3 catalog release; its acceptance
tarball's `macprovider-cli` sha256 equals the binary the member runs.

### P6. Trusted pools enabled (new; not in the task list, but required)

State 2026-09-25: `/opt/macprovider/coordinator.yaml` and the overlay have no
`trusted_pools:` block, the gateway has no `features.trusted_pools`, and no
`trustpool_*` table exists in `coordinator.db` (the store creates them only
when the feature is enabled). Pass after the change:

```bash
sudo grep -n -A3 '^trusted_pools:' /opt/macprovider/coordinator.yaml /etc/macprovider/coordinator.pearl-overlays.yaml
sudo grep -n -A3 'trusted_pools:' /opt/macprovider/gateway.yaml
sqlite3 -readonly /var/lib/macprovider/coordinator.db "SELECT name FROM sqlite_master WHERE name LIKE 'trustpool_%';"
```

### P7. Artifact feed served (new; required for any GGUF member)

State 2026-09-25: `/v1/catalog-artifacts` is 404 locally and publicly, the
served release `published-2026-09-23-tier2-buyer-closure-v1` is a four-feed
release, `autotune.catalog_artifacts_path` is unset, and Pearl nginx has no
`catalog-artifacts` location. `catalog-release.py status` reports
`pre-activation`, NOT ACTIVATABLE. Pass after §3:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://coordinator.malibu.tech/v1/catalog-artifacts      # 200
curl -s https://coordinator.malibu.tech/v1/catalog-artifacts | python3 -c '
import json,sys; m=json.load(sys.stdin)["models"]["meta-llama/llama-3.2-3b-instruct"]["artifacts"]["gguf-q4-k-m"]
print(m["hash"], m["source_ref"], m["allowed_runtime_sources"])'
```

### P8. No pool traffic can reach an old gateway

With P1 and P2 true this is structural (F10 fix: the coordinator withholds a
pool allowlist from a request that did not negotiate signed finality). Check
that the only gateway is `127.0.0.1:9443` and nothing proxies the
gateway→coordinator hop: `sudo grep -n buyer_url /opt/macprovider/gateway.yaml`
prints `http://127.0.0.1:8443`.

## 2. Current Pearl pool state (read-only, 2026-09-25 09:27-09:36Z)

- `trusted_pools` is not configured on the coordinator; the gateway has no
  `features.trusted_pools`.
- No `trustpool_*` table exists in `/var/lib/macprovider/coordinator.db` (66
  tables, none pool-store). No pool tables in the Postgres `macprovider_stats`
  database either.
- `settlement_route_snapshots`: 271,205 rows, `COUNT(pool_id) = 0`. The table
  has no `runtime_source` column yet (pre-#1690 schema on `v1.8.198`).
- So **no pool exists**: no M1 pool created as v1, no members, no manifest
  versions. M1 is created from scratch as v2. There is nothing to migrate and
  runbook §9 step 1's "pause every pool" is empty.

Re-check right before §4 (after P6):

```bash
sqlite3 -readonly /var/lib/macprovider/coordinator.db "SELECT pool_id, event_type, COUNT(*) FROM trustpool_events GROUP BY 1,2;"
sqlite3 -readonly /var/lib/macprovider/coordinator.db "SELECT pool_id, manifest_version, manifest_core_digest FROM trustpool_manifest_acceptances;"
```

Expect zero rows.

## 3. The catalog tuple and model

### 3.1 Model choice: `meta-llama/llama-3.2-3b-instruct`

No production catalog row carries a GGUF tuple: the served feed is absent and
`phase3-binary/catalog/autotune/autotune-artifacts-source.json` has only MLX
primaries (`mlx_cache`). So M1 adds the first GGUF sibling. It goes on the
smallest row the production catalog carries:

| Row | `min_ram_gb` | MLX primary |
|---|---|---|
| `meta-llama/llama-3.2-3b-instruct` | 4 | `mlx-community/Llama-3.2-3B-Instruct-4bit@7f0dc925…`, `e7e5bff4…` |
| next smallest (`llama-3.1-8b`, `qwen3-8b`) | 12 | |

Reasons: smallest RAM and GPU footprint beside the live Qwen3.6 provider on
the Studio; `rate_class: class-3b` and a coordinator rate row already exist
(`rewards.rate_card["meta-llama/llama-3.2-3b-instruct"]`: 13,500 / 3,375 /
27,000 credits per Mtok); it is the row the existing signed
JOURNEY-BUYER-PAID-PATH envelope used (`rate_card_matched_key`), so the pool
journey compares directly with the native paid-path evidence; Llama 3.2 ships
a chat template llama-server applies with `--jinja`.

### 3.2 The GGUF artifact (SPEC-023 §3.7.3/§3.7.4, v0.16.0 tuple)

Source picked: `bartowski/Llama-3.2-3B-Instruct-GGUF`, ungated, one
single-file Q4_K_M. Values read from the Hugging Face API on 2026-09-25:

| Field | Value |
|---|---|
| artifact id | `gguf-q4-k-m` |
| `runtime_format` | `gguf` |
| `hash_algorithm` | `macprovider.gguf-file.v1` |
| `hash` | `6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff` (LFS `oid`) |
| `size_bytes` | `2019377696` |
| `quantization` | `q4_k_m` |
| `min_ram_gb` | `4` |
| `allowed_runtime_sources` | `["llamacpp_loopback"]` |
| `source_ref` | `{"kind":"huggingface_revision","repo_id":"bartowski/Llama-3.2-3B-Instruct-GGUF","revision":"5ab33fa94d1d04e903623ae72c95d1696f09f9e8","file_path":"Llama-3.2-3B-Instruct-Q4_K_M.gguf"}` |
| `verification_status` / `verified_at` | `verified` / the date the operator re-hashes the downloaded file |

Before committing, the operator downloads the file at that revision and
confirms `shasum -a 256` equals the `hash` (that is what `verified` asserts,
SPEC-023-R004 v0.16.0). Do not put `digest` on a `huggingface_revision`
source (closed schema).

Feed-tuple requirements this satisfies: the closed identity matrix row
`gguf` / `gguf-file.v1` / `huggingface_revision`+`file_path` /
`{llamacpp_loopback}`; `file_path` matches
`^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\.gguf$`; `(hash_algorithm, hash)` is
unique in the feed; the artifact id is new, so no rebinding.

Rollout state of this tuple (SPEC-023 v0.17.2), checked 2026-09-25:

- coordinator: implemented (`buyer/catalog_artifacts_feed.go`,
  `artifactIdentityMatrix`, since `747557cc`);
- provider CLI: implemented by the B3a commit on
  `feat/1690-m1-catalog-gguf` (`AutotuneArtifactFeed.swift` accepts the tuple
  and resolves a llama.cpp GGUF by its file digest). Every CLI before it,
  including `747557cc` and the live `1.8.192`/`1.8.195` candidates, rejects
  the whole feed as `catalog_artifact_feed_integrity_failure`. That fails
  closed for artifact-derived capabilities only; native paid serving is
  unaffected (§3.7.6 rule 6);
- release generator: NOT implemented. `ARTIFACT_IDENTITY_MATRIX` in
  `scripts/catalog-release.py` maps `gguf` to `ollama_library_tag` only, so
  `catalog-release.py status` stays NOT ACTIVATABLE on this entry. The
  generator's `ARTIFACT_FEED_CONSUMER_FLOOR` `(0,16,0)` gates
  `allowed_runtime_sources` only; it never made the generator emit this
  tuple. The generator change (B3b) lands after #1732, which rewrites that
  file.

Do not add `mlxlm_loopback` to the MLX primary in this release either: the
generator refuses it until the floor is raised to v0.17.0.

A coordinator older than `v1.8.200` (the first deployable #1690 tag) cannot start on a feed carrying this tuple
(E2E-F11): from this release on, a coordinator rollback needs §9 step 4a.

### 3.3 Catalog release (PR, then signed cut)

This is the first artifact-bound release, so it is also the artifact-feed
activation (`catalog-artifact-feed-release.md`, "Activation state").

1. PR in a fresh worktree off `origin/main`:
   - add the §3.2 `gguf-q4-k-m` entry under
     `models["meta-llama/llama-3.2-3b-instruct"].artifacts` in
     `phase3-binary/catalog/autotune/autotune-artifacts-source.json`;
   - measure `size_bytes` for all 17 MLX artifacts (`catalog-release.py
     status` lists them unmeasured; activation refuses until they are). Use
     the sum of the Hugging Face LFS/regular file sizes at each pinned
     revision, recorded with the query used;
   - pick a new `release_id`; the repo's current release
     `published-2026-09-25-artifact-hash-correction-v1` is already published
     and may not be enriched.
2. After merge, cut: `python3 scripts/catalog-release.py generate
   --activate-artifact-feed --signer-key-id streamvc-autotune-static-v4 …`,
   sign with `scripts/resign-autotune-static.sh`, then
   `python3 scripts/catalog-release.py verify`. Signing key:
   `streamvc-autotune-static-v4`, operator custody only (never CI, never
   printed; verify identity by deriving its public key and comparing with the
   committed `trusted-keys.json`, which Pearl already trusts as
   `streamvc-autotune-static-v4`).
3. Deploy (Pearl actor): the release directory through the normal catalog
   deploy (`deploy-pearl-vps.sh` stages the feed pair when `release.json`
   binds it), plus in the same deploy
   `autotune.catalog_artifacts_path` / `autotune.catalog_artifacts_sig_path`
   in the coordinator config, plus an additive nginx allow-through for
   `/v1/catalog-artifacts` and `.sig` on `coordinator.malibu.tech` and
   `coordinator.streamvc.live` (copy only those two `location` blocks from
   `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`; never copy the
   site file, which would drop live routes). Then P7 and the live release gate.

### 3.4 Admission of the member's candidate

After the member serves (§4), `models offer` resolves the GGUF hash through
the feed (`catalog_match_state: catalog_matched`, member
`artifact_feed`/`gguf-q4-k-m`). An operator then records
`catalog_priced` through `POST /admin/model-admission/decisions` on `:8444`
(`schema: model_admission_decision_request.v1`, `next_state:
catalog_priced`, `expected_coordinator_event_id` from the offer). That route
is dual-control on Pearl (SPEC-026 policy A/B operator keys). A GGUF member
never reaches `settlement_capable` globally; pool route-time settlement is the
only way it earns.

### 3.5 CLI candidate ordering

`models offer` / `discover` / `evaluate` resolve BYOM identity against the
**compiled-in** release (`catalog-artifact-feed-release.md`, slice 2c). So the
acceptance candidate for the member must be cut from a commit that contains
both `747557cc` and the §3.3 release (its `bakedArtifactFeedBase64` then
carries `gguf-q4-k-m`). Cut it with `.github/workflows/acceptance-candidate.yml`
(`promotion_ready=true`), signed in CI with `MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM`
(`production-release` environment), then add its `v<ver>@<commit>` to
`coordinator.compatibility_set.accepted_ids` (Pearl actor, restart). The live
native provider is not updated by this; it keeps its own candidate.

## 4. The pool manifest

### 4.1 Signing tool and keys

The reviewed tool is `coordinator-cli trust-pool-admin keygen`, `sign-root`
and `sign-manifest` (`phase4-coordinator/cmd/coordinator-cli/trust_pool_sign.go`,
B7). It replaces the lab-only `scripts/lab/1690-m6/labtool` pool commands:
every key id, the launch environment, the custody disclosure and class, the
signer-set version, the attestation tier, the retention policy, the member
floor and the policy window are required flags with no defaults. Private keys
are PKCS#8 PEM files that the tool creates `0600` in a new `0700` directory,
and it reads them only when they are regular, owner-only files owned by the
invoking user. Nothing it prints or writes contains private key material.
Before writing, each command checks its own output with the coordinator's
verifiers (`VerifyRootIssuerRegistrationEvent`,
`VerifyNewestPolicyAcceptance`, `VerifyManifestAcceptedEvent`). It never uses
the network; the Pearl actor submits the JSON events it writes.

The tool is not in `v1.8.200`. Build `coordinator-cli` on the operator Mac
from the first `main` commit that contains it:

```bash
git worktree add ../mp-m1-pooltool <commit-with-trust_pool_sign.go> --detach && cd ../mp-m1-pooltool
(cd phase4-coordinator && GOTOOLCHAIN=local go build -o "$M1/bin/coordinator-cli" ./cmd/coordinator-cli)
```

`$M1` is an operator directory, mode 0700, e.g. on an encrypted volume.
Submission on Pearl still uses the deployed `/opt/macprovider/coordinator-cli`
(`append-event` and `submit-policy` are unchanged).

Three keys, all generated fresh by `keygen` on the offline operator Mac, kept
in operator custody (never in the repo, never on Pearl, never printed):

| Key | Algorithm | Signs | File in `$M1/keys` |
|---|---|---|---|
| root issuer | ECDSA P-256 | `root_issuer_registered` proof, every `manifest_accepted` event | `root-issuer-key.pem` |
| manifest authority root | Ed25519 | genesis authority-log entry (policy signer set 1-of-1); its key id derives `pool_id` | `manifest-authority-key.pem` |
| policy signer | Ed25519 | the policy core, `policy-core-sig/v2 ‖ manifest_core_digest` | `policy-signer-key.pem` |

`keygen` also writes `pool-identity.json` (public: `pool_id`, genesis nonce,
key ids, public keys, root fingerprint), which `sign-root` and
`sign-manifest` read.

M1 key ids and custody (recorded in the pool's durable history, so pick them
once): `m1-manifest-authority-1`, `m1-policy-signer-1`, `m1-root-issuer-1`;
custody disclosure `$M1/custody-m1.json` =
`{"class":"software","description":"<operator Mac, encrypted volume, owner-only files>"}`
with `--custody-class software` (allowed for a `candidate` pool,
SPEC-043-R002). The event carries the sha256 of that file's exact bytes, so
keep the file.

### 4.2 Exact v2 policy-core fields (what `sign-manifest` produces)

| Field | M1 value |
|---|---|
| `Encoding` | `2` (tag `macprovider/spec042/policy-core/v2`) |
| `PoolID` | from `keygen` |
| `ManifestVersion` | `1` |
| `PrevManifestCoreHash` | 32 zero bytes (genesis) |
| `SignerSetVersion` | `1` (`--signer-set-version 1`) |
| `ModelAllowlist` | `["mlx-community/Llama-3.2-3B-Instruct-4bit"]` (the row's `model_id`; buyers name it) |
| `MinBinaryVersion` | `1.8.123` (every candidate CLI reports the shared `binaryVersion` `1.8.123`; a higher floor would exclude the member) |
| `MinAttestationTier` | `hardware` (`--min-attestation-tier hardware`) |
| `RequireEncryptedLeg` | `false` (the tool does not set it) |
| `SettlementMode` | `enforce` (required: a non-empty allowlist in `observe` is `errRuntimeAllowlistObserve`) |
| `RevenueSplitBps` | `0` (the tool does not set it) |
| `SplitExecutionStatus` | `declared_not_executed` |
| `RetentionPolicyID` | `standard` (`--retention-policy-id standard`) |
| `MinEligibleMembers` | `1` (`--min-eligible-members 1`) |
| `PrivacyMode` / `RelayBlindCapable` / `ReceiptContract` | `none` / `false` / `""` |
| `MetadataVisible` / `DowngradePolicy` / `StickyRoutingAllowed` | `standard` / `reject` / `false` |
| `NotBeforeUnix` / `ExpiresAtUnix` | `now-60` / `now + 30 days` (`--not-before` / `--expires-at`, RFC3339) |
| `RuntimeAllowlist` | `["llamacpp_loopback"]` (strictly ascending, no `mlx_cache`) |
| `Extensions` | `[]` |

### 4.3 Commands (Pearl actor, from Pearl, operator key never leaves the host)

Artifacts built on the operator Mac are copied to Pearl as plain JSON events
(they contain signatures and public keys only). Use `coordinator-cli` from
the deployed `v1.8.200` (`/opt/macprovider/coordinator-cli`), admin URL
`http://127.0.0.1:8444`, key from `/etc/macprovider/coordinator.env`
(`OPERATOR_KEY`), exported as `MACPROVIDER_OPERATOR_KEY` inside a root shell
only.

0. Enable the feature (P6): coordinator `trusted_pools: {enabled: true,
   refresh_interval_s: 30}` (requires `coordinator.require_gateway_context:
   true`, already set), gateway `features.trusted_pools: {enabled: true,
   coordinator_authorizes: true}`. Restart coordinator, then gateway. The
   restart creates the `trustpool_*` tables.
1. Creator approval (SPEC-043-R001 shape; values are the operator's own):

   ```bash
   coordinator-cli trust-pool-admin upsert-creator --admin-url http://127.0.0.1:8444 \
     --operation-id m1-creator-1 --input creator-m1.json
   ```

   `creator-m1.json`: `creator_account_id: acct-malibu-ops-m1`,
   `approval_record_id: approval-m1-v1`, `current_approval_version:
   approval-version-1`, `allowed_launch_environment: candidate`,
   `status: enabled`, `allowed_product_category: design-partner`,
   agreement expiry/grace 30/31 days out, the hash fields computed with
   `sha256` over the operator's own text (same keys as
   `scripts/lab/1690-m6/pool_setup.py:ensure_creator`).
2. Keys and pool id (operator Mac):

   ```bash
   "$M1/bin/coordinator-cli" trust-pool-admin keygen --out-dir "$M1/keys" \
     --manifest-authority-key-id m1-manifest-authority-1 --policy-signer-key-id m1-policy-signer-1
   ```

   prints `pool_id=` (`POOL_ID`) and the root fingerprint.
3. Root nonce (Pearl):

   ```bash
   coordinator-cli trust-pool-admin issue-root-nonce --admin-url http://127.0.0.1:8444 \
     --creator-account-id acct-malibu-ops-m1 --approval-record-id approval-m1-v1 \
     --approval-version approval-version-1 --launch-environment candidate \
     --purpose root_issuer_registration --expires-at <now+1h UTC> --operation-id m1-nonce-1
   ```
4. Create the pool:

   ```bash
   coordinator-cli trust-pool-admin create-pool --admin-url http://127.0.0.1:8444 \
     --pool-id "$POOL_ID" --creator-account-id acct-malibu-ops-m1 \
     --approval-record-id approval-m1-v1 --operation-id m1-create-1
   ```
5. Root registration (operator Mac signs, Pearl submits):

   ```bash
   "$M1/bin/coordinator-cli" trust-pool-admin sign-root --identity "$M1/keys/pool-identity.json" \
     --root-issuer-key "$M1/keys/root-issuer-key.pem" --root-issuer-key-id m1-root-issuer-1 \
     --operation-id m1-root-1 --creator-account-id acct-malibu-ops-m1 \
     --approval-record-id approval-m1-v1 --approval-version approval-version-1 \
     --launch-environment candidate --custody-disclosure "$M1/custody-m1.json" --custody-class software \
     --display-name "Malibu M1 operator pool" \
     --nonce <nonce> --nonce-expiry <expires_at_utc> --out root-m1.json
   coordinator-cli trust-pool-admin append-event --admin-url http://127.0.0.1:8444 --input root-m1.json
   ```
6. Manifest v1 (encoding 2):

   ```bash
   NB=$(date -u -v-60S +%Y-%m-%dT%H:%M:%SZ); EXP=$(date -u -v+30d -v-60S +%Y-%m-%dT%H:%M:%SZ)
   "$M1/bin/coordinator-cli" trust-pool-admin sign-manifest --identity "$M1/keys/pool-identity.json" \
     --root-issuer-key "$M1/keys/root-issuer-key.pem" --root-issuer-key-id m1-root-issuer-1 \
     --manifest-authority-key "$M1/keys/manifest-authority-key.pem" \
     --policy-signer-key "$M1/keys/policy-signer-key.pem" --operation-id m1-manifest-1 \
     --encoding 2 --signer-set-version 1 --settlement-mode enforce --runtime-allowlist llamacpp_loopback \
     --models mlx-community/Llama-3.2-3B-Instruct-4bit --min-binary-version 1.8.123 \
     --min-attestation-tier hardware --retention-policy-id standard --min-eligible-members 1 \
     --not-before "$NB" --expires-at "$EXP" --out manifest-m1-v1.json
   coordinator-cli trust-pool-admin submit-policy --admin-url http://127.0.0.1:8444 --input manifest-m1-v1.json
   ```
7. Member and buyer (after §5 has the member connected and priced):

   ```bash
   coordinator-cli trust-pool-admin admit-provider --admin-url http://127.0.0.1:8444 \
     --pool-id "$POOL_ID" --provider-id "$M1_PROVIDER_ID" --operation-id m1-member-1
   coordinator-cli trust-pool-admin authorize-buyer --admin-url http://127.0.0.1:8444 \
     --pool-id "$POOL_ID" --buyer-account-id "$M1_BUYER_ACCOUNT" --operation-id m1-buyer-1
   ```

   No `delegation_id`: a delegated member is disqualified from
   `pool_operator_attested` (`pool_operator_attestation.go:60-111`).
8. R013 disclosure check (runbook §4 step 5): `get-pool` shows the one
   member and a `manifest_core_digest` equal to `manifest-m1-v1.json`'s.
   `get-pool` does not print `runtime_allowlist` or `settlement_mode`; the
   digest binds them (§4.2), and the journey's route snapshots show them in
   force. The pool's `trustpool_events` have no `delegation_granted`. No
   distribution artifact is published for M1.
9. Activate:

   ```bash
   coordinator-cli trust-pool-admin promote --admin-url http://127.0.0.1:8444 \
     --pool-id "$POOL_ID" --operation-id m1-promote-1 --reason "1690-M1 operator-internal"
   coordinator-cli trust-pool-admin get-pool --admin-url http://127.0.0.1:8444 --pool-id "$POOL_ID"
   ```

   Pass: lifecycle `active`, routeable, manifest 1, digest recorded.

## 5. The pool member

### 5.1 Separate provider identity on the Mac Studio

Host: the Mac Studio (M3 Ultra, 256 GB, macOS 26.4.1), which already has
llama.cpp `b11149` at `/Users/a1/bench-1690/llama.cpp-b11149/llama-b11149/llama-server`
from the lab runs.

Use a **second provider identity** (`$M1_PROVIDER_ID`), not the live
`mp-5aad6b654611666e16edf83dc0f326eb`:

- Any `model_admission_events` row for a provider, even revoked or
  withdrawn, removes it from native default routing
  (`buyer/model_admission.go:161-208`, `ws/model_admission.go:1180-1184`,
  SPEC-047-R003 v0.1.5). Offering the GGUF from mp-5aad would take the live
  native Qwen3.6 provider off global traffic, and clearing that needs a
  production DB delete.
- One identity switching engines revokes the other engine's candidate
  (`runtime_identity_drift`, SPEC-047-R006).
- The live provider runs a different CLI candidate (`1.8.192`/`1.8.195`
  line); the member needs the §3.5 candidate.

Safest for the live provider: the member runs as its own process with its own
config, credentials, home, lifecycle, control socket and port, never touching
`/Users/a1/macprovider/`, `~/.config/macprovider`, `:8080`, or any
`live.malibu.*` launchd label, and started/stopped by recorded PID (the lab
`pidguard.sh` pattern). Memory: Q4_K_M 3B is about 2 GB plus KV for
`-c 8192 -np 4`; negligible beside the live model, but it shares the GPU, so
watch the live provider's TPS during the journey.

### 5.2 Registration

The new identity needs a provider token accepted by Pearl
(`require_provider_tokens`). Issue it the operator way on Pearl (Pearl actor):

```bash
sudo -u macprovider /opt/macprovider/coordinator-cli issue-token \
  -db /var/lib/macprovider/coordinator.db -provider-id "$M1_PROVIDER_ID" -provider-name malibu-m1-pool-llamacpp
```

The token goes to the member's protected credential store only. Whether the
production hardware-trust / referral onboarding gates apply to an
operator-issued token identity is open (B5).

### 5.3 Member layout and config

Everything under `M1M=/Users/a1/malibu-m1-pool` (mode 0700):

```bash
# env for every member command (the cli.sh pattern, production URL, no lab flags)
export CFFIXED_USER_HOME=$M1M/home TMPDIR=$M1M/tmp/
export MACPROVIDER_CONFIG=$M1M/provider/config.yaml
export MACPROVIDER_LIFECYCLE_ROOT=$M1M/home/lifecycle
export MACPROVIDER_CTL_SOCKET_PATH=$M1M/tmp/ctl.sock
export MACPROVIDER_SWITCH_STATE_PATH=$M1M/tmp/last-switch.ts
export MACPROVIDER_WATCHDOG_STATE_DIR=$M1M/home/watchdog
export MACPROVIDER_LLAMACPP_MODEL_PATH=$M1M/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf
export MACPROVIDER_AUTO_UPDATE_ENABLED=false
```

Do not set `MACPROVIDER_BYOM_ALLOW_INSECURE_LOOPBACK_COORDINATOR` and do not
use `--isolate-lifecycle` (lab-only; with a production URL it relaxes
nothing, but the env redirection above is the isolation).

`$M1M/provider/config.yaml`:

```yaml
coordinator_url: wss://coordinator.malibu.tech/ws/provider
provider_id: <M1_PROVIDER_ID>
credential_store: protected_file
enable_receipts: true
port: 18120
model: llamacpp:Llama-3.2-3B-Instruct-Q4_K_M
model_catalog_key: meta-llama/llama-3.2-3b-instruct
model_catalog_model_id: mlx-community/Llama-3.2-3B-Instruct-4bit
loopback_origin: http://127.0.0.1:18130
auto_update_enabled: false
```

The provider token is imported, not left in the file:
`macprovider-cli credentials import --config $M1M/provider/config.yaml`.

llama-server (flags proven in the lab, `rig.sh:350`):

```bash
/Users/a1/bench-1690/llama.cpp-b11149/llama-b11149/llama-server \
  -m $M1M/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf \
  --host 127.0.0.1 --port 18130 -c 8192 -np 4 -ngl 99 --jinja
```

- `--jinja`: applies the GGUF chat template; tool calls need it.
- The CLI always calls it with `stream: true`,
  `stream_options.include_usage: true` and `timings_per_token: true`, and
  reads `timings.prompt_n` / `cache_n` / `predicted_n`; no server flag is
  needed for usage. It re-reads `/props` (`model_path`, `n_ctx`) each request,
  so do not swap the file while serving.
- `-np 4` = 4 slots; the CLI's concurrency follows the served slots.
- Ports 18120/18130 are free on the Studio today (live is 8080, the #1745
  lab uses 18099). Re-check with `lsof -nP -iTCP -sTCP:LISTEN` first.

### 5.4 Join and enrolment steps

1. Download the GGUF at the pinned revision; `shasum -a 256` must equal
   `6c1a2b41…c728ff`.
2. Install the §3.5 candidate CLI into `$M1M/bin/` (flat asset dir from the
   `acceptance-candidate-<commit>` artifact; binary sha256 must equal the
   acceptance tarball's).
3. Start llama-server (record PID), then
   `$M1M/bin/macprovider-cli serve --config $M1M/provider/config.yaml`
   (record PID). A LaunchAgent is not needed for M1; if one is used it must
   be a new label, never `live.malibu.*`.
4. Offer: `macprovider-cli models offer llamacpp:Llama-3.2-3B-Instruct-Q4_K_M --yes --json
   --config $M1M/provider/config.yaml --skip-ollama --skip-lmstudio
   --skip-openai-compatible --llamacpp-origin http://127.0.0.1:18130`. Expect
   `catalog_match_state: catalog_matched`, member `artifact_feed/gguf-q4-k-m`.
5. Operator `catalog_priced` decision (§3.4), then restart serve so the
   session binds it.
6. Verify the session on Pearl (read-only):

   ```bash
   curl -s -H "Authorization: Bearer $OPERATOR_KEY" http://127.0.0.1:8444/poolz | python3 -c '
   import json,sys
   for p in json.load(sys.stdin)["pool"]:
       if p["provider_id"]=="'"$M1_PROVIDER_ID"'": print({k:p.get(k) for k in ("runtime_source","model_hash_algorithm","hash_status","catalog_admission_mode","state","slots_total")})'
   ```

   Expect `llamacpp_loopback`, `macprovider.gguf-file.v1`, `hash_verified`,
   `current`, `ready`.
7. §4.3 step 7 admits it; step 9 promotes the pool.

## 5A. Paid production journey

Buyer: a dedicated operator gateway account (`$M1_BUYER_ACCOUNT`, the gateway
`accounts.id`), with an API key issued through the normal console flow, never
printed. `max_tokens` stays at 64 (well under the ~280-frame region E2E-F2
fixed, and cheap).

### Requests

```bash
BASE=https://api.malibu.tech/v1
H=(-H "Authorization: Bearer $M1_BUYER_KEY" -H 'Content-Type: application/json'
   -H "X-MacProvider-Pool-Select: $POOL_ID" -H 'X-MacProvider-Engine-Select: llamacpp')
# non-streaming
curl -sS -D nonstream.headers "${H[@]}" $BASE/chat/completions \
  -d '{"model":"mlx-community/Llama-3.2-3B-Instruct-4bit","messages":[{"role":"user","content":"M1 journey ref <uuid>: name three prime numbers."}],"max_tokens":64}' > nonstream.json
# streaming
curl -sSN -D stream.headers "${H[@]}" $BASE/chat/completions \
  -d '{"model":"mlx-community/Llama-3.2-3B-Instruct-4bit","stream":true,"messages":[{"role":"user","content":"M1 journey ref <uuid2>: count to five."}],"max_tokens":64}' > stream.sse
```

Each prompt carries a fresh uuid (the gateway dedupe cache answers repeats
without routing).

Expected headers on both 200s: `X-MacProvider-Engine: llamacpp_loopback`,
`X-Request-ID: <rid>`, `X-Provider-Id: <M1_PROVIDER_ID>`. Stream ends with a
`finish_reason` chunk and `[DONE]`.

Negative controls in the same session (each must be 503, 0 route snapshots,
0 ledger rows, 0 upstream calls):

- same body, no `X-MacProvider-Pool-Select` → 503 `engine_unavailable`
  (global route, selector set);
- same, no selector and no pool → 503 `byom_non_settlement_unavailable`;
- pool header with `X-MacProvider-Engine-Select: ollama` → 503
  `engine_unavailable`;
- `X-MacProvider-Engine-Select: LLAMACPP` → 400 `invalid_engine_selection`.

### Expected settlement (per request)

| Surface | Expected |
|---|---|
| route snapshot | `pool_id=$POOL_ID`, `manifest_version=1`, `runtime_source=llamacpp_loopback`, `pool_generation`, `pool_operator_account_id=acct-malibu-ops-m1`, `route_snapshot_mode=enforce`, `expected_catalog_model_hash=6c1a2b41…` |
| attempt output | `usage_source=pool_operator_attested`, `terminal_state=normal_done` |
| receipt verdict | `receipt_version=4`, `receipt_result=valid`, `settlement_outcome=verified`, `reason=verified_settlement`, `pool_label_status=verified`, `closed=1` |
| ledger | one payable row, `provider_id=$M1_PROVIDER_ID`, `provider_credits>0`, `quarantined=0`, `settlement_policy_mode=enforce` |
| finality | `closed=true`, `outcome=verified`, `token_source=pool_operator_attested` |
| gateway | `quota_reservations.status=settled`, `settlement_hold=0`; `usage_events.token_source=pool_operator_attested`; debit `(prompt, completion)` == finality |

Known, carried: E2E-F1. With `--jinja` the buyer-visible `usage.prompt_tokens`
exceeds the charged prompt (the coordinator's byte-estimate bound,
SPEC-022 R-12.4 ceiling). Buyer debit == finality == ledger charged tokens
still holds; buyer-visible usage != debit is expected and recorded, not a
failure.

### Read-only proof SQL (Pearl)

```bash
C="sqlite3 -readonly -header /var/lib/macprovider/coordinator.db"
G="sqlite3 -readonly -header /var/lib/macprovider/gateway.db"
RID=<X-Request-ID of the buyer request>
$C "SELECT request_id, attempt_n, status, pool_id FROM request_log WHERE external_request_id='$RID';"
IDS=$($C -noheader "SELECT group_concat(quote(request_id)) FROM request_log WHERE external_request_id='$RID';")
$C "SELECT request_id, attempt_n, json_extract(route_snapshot_json,'\$.pool_id') pool, json_extract(route_snapshot_json,'\$.runtime_source') rt,
           json_extract(route_snapshot_json,'\$.manifest_version') mv, json_extract(route_snapshot_json,'\$.pool_generation') gen,
           json_extract(route_snapshot_json,'\$.pool_operator_account_id') op, route_snapshot_mode
    FROM settlement_route_snapshots WHERE request_id IN ($IDS);"
$C "SELECT request_id, attempt_n, terminal_state, usage_source,
           json_extract(usage_canonical_json,'\$.billable_input_tokens') bin, json_extract(usage_canonical_json,'\$.billable_output_tokens') bout
    FROM settlement_attempt_outputs WHERE request_id IN ($IDS);"
$C "SELECT request_id, attempt_n, receipt_version, receipt_result, settlement_outcome, reason, closed, pool_label_status
    FROM settlement_receipt_verdicts WHERE request_id IN ($IDS);"
$C "SELECT l.id, l.provider_id, l.status, l.charged_prompt_tokens, l.completion_tokens, l.usage_source, l.provider_credits,
           l.quarantined, l.settlement_policy_mode, (p.id IS NOT NULL) payable
    FROM ledger_request_credits l LEFT JOIN spec022_payable_request_credits p ON p.id = l.id WHERE l.request_id IN ($IDS);"
$G "SELECT request_id, status, settled_tokens, settlement_hold FROM quota_reservations WHERE request_id='$RID';"
$G "SELECT request_id, prompt_tokens, completion_tokens, token_source, outcome FROM usage_events WHERE request_id='$RID';"
```

Finality (read-only GET, service token from `gateway.env`, not printed):
`curl -s -H "Authorization: Bearer $COORDINATOR_SERVICE_TOKEN"
"http://127.0.0.1:8443/internal/settlement/finality?account_id=$M1_BUYER_ACCOUNT&request_id=<coordinator request_id>"`.

Pass criteria: every row in the table above; `usage_events (prompt,
completion)` == finality `(prompt_tokens, completion_tokens)` == ledger
`(charged_prompt_tokens, completion_tokens)`; zero `missing_settlement_finality_trailer`
holds; the negative controls left no rows. Wait at least one
`pending_deadline_seconds` before reading verdicts as final.

### Evidence for SPEC-022-R012 (CONFORMANCE)

`SPEC-022-R012` is `pending` and already maps
`journeys: ["JOURNEY-TRUSTED-POOL-EXTERNAL-RUNTIME"]` (B6); what it lacks is
the signed evidence from an enforce-mode pool run. Signed journeys follow the
JOURNEY-BUYER-PAID-PATH pattern:

- definition `journeys/JOURNEY-<ID>.md`;
- redacted evidence `journeys/evidence/<run_id>.redacted.json` (no prompts,
  completions, keys, tokens or account secrets; request ids, digests,
  counts, labels only);
- payload built by `scripts/build-<journey>-journey-result.py`, signed in CI
  by `.github/workflows/promote-signed-<journey>-journey.yml`
  (`production-release` environment, `MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM`,
  key id `macprovider-acceptance-p256-v1`), envelope
  `macprovider.journey-result-envelope.v1`, validated by
  `validate-signed-journey-result.py` and promoted by
  `promote-signed-journey-result.py`;
- promotion adds to the CONFORMANCE row (whose `journeys` already names
  the journey) an `evidence[]` entry `{artifact: "sha256:<envelope>",
  source: "journeys/evidence/<file>", captured_at, expires_at}`.

The journey is `journeys/JOURNEY-TRUSTED-POOL-EXTERNAL-RUNTIME.md` (B6). It
maps SPEC-022-R012, SPEC-042-R013 and SPEC-042-R014 (all still `pending`) and
fixes the capture layout: file names, the `-json` form of the SQL above, and
`run.json` / `preconditions.json` / `gateway-holds.json`.
`scripts/build-trusted-pool-external-runtime-journey-result.py capture` checks
every pass criterion above and writes the redacted evidence;
`.github/workflows/promote-signed-trusted-pool-external-runtime-journey.yml`
builds (`payload`), signs and promotes it. Capture into an operator-local
directory in that layout:

1. P1-P8 outputs with timestamps; deployed commit; `accepted_ids` entry;
   member CLI binary sha256; llama-server build (`b11149`) and GGUF sha256.
2. `get-pool` JSON (manifest 1 digest, `runtime_allowlist`, `settlement_mode`,
   lifecycle, member, buyer) and `trustpool_events` rows for the pool.
3. For each of the 2 paid requests: response status and the three headers,
   `usage`, content sha256 (not content), and every SQL result above plus the
   finality JSON.
4. The 4 negative controls: status, error code, and the zero-row SQL.
5. Gateway hold count and the `missing_settlement_finality_trailer` log count
   before and after.
6. Environment: `class: production-operator-internal-pool`,
   `settlement_mode: enforce`, `enforce_activated: true` (pool scope only),
   `payout_ready_mutated: false` (payout is disabled on Pearl).

## 6. Rollback of the pool

Fastest stop, no manifest change (Pearl actor):

```bash
coordinator-cli trust-pool-admin set-lifecycle --admin-url http://127.0.0.1:8444 \
  --pool-id "$POOL_ID" --lifecycle paused --reason "1690-M1 rollback" --operation-id m1-pause-<n>
```

- New buyer requests for the pool fail closed; global traffic is untouched.
  Resume with `promote` (paused→active).
- In-flight requests keep the route snapshot they were dispatched under
  (manifest 1, generation). Their settlement is decided from that digested
  snapshot and durable history, not from the new lifecycle: a completed
  attempt with a valid v0.4 receipt still settles `verified` /
  `pool_operator_attested`; one without a receipt goes
  `missing_receipt_deadline_elapsed` → quarantined, buyer refunded. The
  expiry sweep (`SweepExpiredPoolSettlementVerdicts`) closes open pending
  verdicts about a minute after their deadline; the gateway reconciler
  settles or refunds the reservation from finality.
- Before any coordinator rollback: `coordinator pool-rollback-preflight
  --config /opt/macprovider/coordinator.yaml --config-overlay
  /etc/macprovider/coordinator.pearl-overlays.yaml`, with
  `/etc/macprovider/coordinator.env` loaded, must exit 0 (runbook §9 has the
  exact command).

Harder stops, in order of reach:

- `revoke-provider --pool-id … --provider-id $M1_PROVIDER_ID` (member out; a
  generation bump; in-flight stays on its snapshot).
- `set-lifecycle --lifecycle retired` (terminal for M1).
- Withdraw the allowlist: a manifest v2 with `runtime_allowlist: []`
  (`sign-manifest --prev manifest-m1-v1.json`, no `--manifest-authority-key`).
  `sign-manifest` refuses a `--not-before` earlier than the current window's
  end, and routing uses the ACTIVE window, so this does not take effect
  immediately. Pause first.
- Stop the member process (by recorded PID) and llama-server. Live provider
  untouched.
- Full #1690 rollback: runbook §9 rollback order, including step 4a (the
  catalog feed now carries `file_path`) and the gateway-rollback ban once any
  `usage_events.token_source='pool_operator_attested'` row exists.

## 7. Blockers and open questions

| # | Blocker | Owner | Unblock |
|---|---|---|---|
| B1 | RESOLVED 2026-09-25: `v1.8.200` live (gateway schema 14, paid non-stream and stream proof settled `spec022_verified`); `v1.8.199` had rolled back on the quick_check stall | #1646 Pearl actor | done |
| B2 | Gateway pin off (`require_settlement_trailers` absent) | Pearl actor | runbook §9 step 2a after P1/P2 |
| B3 | Generator does not emit the v0.16.0 GGUF tuple yet (B3b, after #1732; CLI side B3a done on `feat/1690-m1-catalog-gguf`); no artifact feed in production; activation blocked on 17 unmeasured MLX `size_bytes` and a new `release_id`; nginx route absent | operator (PR + signed cut with `streamvc-autotune-static-v4`, operator-held) + Pearl actor (deploy) | §3.3 |
| B4 | No accepted CLI contains `747557cc`; the candidate must also bake the §3.3 release | operator (acceptance-candidate workflow, `production-release` secret) + Pearl actor (`accepted_ids`) | §3.5 |
| B5 | Registration path for the second identity: does an operator-issued token clear the production hardware-trust / referral onboarding gates, or does it need a dual-control hardware-trust grant (SPEC-026 policy A+B)? | operator | confirm on a dry join; grant if `waiting_trust` |
| B6 | RESOLVED: `journeys/JOURNEY-TRUSTED-POOL-EXTERNAL-RUNTIME.md`, `scripts/build-trusted-pool-external-runtime-journey-result.py` (`capture`, `payload`), `promote-signed-trusted-pool-external-runtime-journey.yml`, `check_spec_governance.py` validator, journey mapped on R012/R013/R014 (still `pending`) | repo | done; a real M1 capture is still needed |
| B7 | RESOLVED: reviewed offline signer `coordinator-cli trust-pool-admin keygen` / `sign-root` / `sign-manifest` with explicit key ids, environment, custody disclosure and class, signer-set version and attestation tier (§4.1, §4.3) | repo | done; build it from `main` (not in `v1.8.200`) |
| B8 | Trusted pools disabled on coordinator and gateway | Pearl actor | §4.3 step 0 |
| B9 | `catalog_priced` decision is dual-control on Pearl | two operator key holders | §3.4 |

Carried findings that affect what M1 shows: E2E-F1 (prompt bound, buyer-visible
usage != debit on templated prompts), E2E-F6 (native only). E2E-F3 (a buyer
disconnect on a llama.cpp stream) and E2E-F13 are fixed in `747557cc`, but
only once the member runs a CLI cut from it. Keep
M1 requests short, non-tool, and not disconnected, and record F1 as expected.
