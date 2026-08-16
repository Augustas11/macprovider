# SPEC-015 v0.3 operator runbook — model-hash receipt binding

**Audience:** Pearl operator landing v0.3 receipt + verifier + coordinator surface.

**Scope:** After the SPEC-015 v0.3 IMPL bundle merges to `main`, this runbook walks the production cutover.

## Pre-deploy state (what's on `main` after PR merge)

- **SPEC**: `specs/SPEC-015-receipts.md` at v0.3.3 LOCKED.
- **Provider** (`phase3-binary/`): emits v0.3 9-field receipts. Tuple shape: `model_hash`, `model_id`, `output_hash`, `prompt_hash`, `provider_pubkey`, `receipt_version="3"`, `tokens_out`, `ttft_ms`, `unix_ts` (JCS canonical order). `model_hash` is the SHA-256 of the loaded MLX container at the request-start snapshot, OR JSON `null` when warm-swap is disabled.
- **Coordinator** (`phase4-coordinator/`): `/poolz` emits new top-level `catalog_id`, `catalog_url`, `catalog_pubkey_url` fields when a tier-2 catalog is effectively active. New public endpoints `GET /catalog/<catalog_id>` and `GET /catalog/pubkey` on the buyer port (8443).
- **Nginx**: `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf` proxies `/catalog/` to 127.0.0.1:8443. Deploy gate `check_nginx_catalog_routes_test.sh` asserts the block is present + correctly ordered before any remote mutation.
- **Verifier** (`phase7-verify/`): 5 new CLI flags (`--catalog`, `--catalog-url`, `--catalog-pubkey`, `--catalog-pubkey-url`, `--require-model-hash`). Tri-state `model_hash_verified` in JSON output. Catalog-cache layer (§M.3.4 three-band TTL).

## Pre-deploy checklist

Run from a clean working tree on `main` after the v0.3 IMPL PR squash-merges:

```bash
git fetch origin
git reset --hard origin/main

# 1. SPEC version reads v0.3.x LOCKED
head -3 specs/SPEC-015-receipts.md

# 2. All builds clean
cd phase3-binary && swift build && swift test && cd ..
cd phase4-coordinator && go vet ./... && go test ./... -count=1 && cd ..
cd phase7-verify && go vet ./... && go test ./... -count=1 -race && cd ..

# 3. AC manifest covers v0.3
cd test/integration && go test ./spec015/ -count=1 -timeout 120s -run "TestSpec015AcceptanceCriteria|TestSpec015V03AcceptanceCriteria"
cd ../..

# 4. Pre-deploy gates green
make test-dist
```

If any of the above fails, do NOT proceed with the deploy.

## Deploy choreography (Pearl coordinator)

### 1. Coordinator binary + nginx conf

The Pearl coordinator at `coordinator.malibu.tech` needs:

- The new binary built from the IMPL bundle.
- The updated `nginx-coordinator.malibu.tech.conf` with the `/catalog/` proxy block.
- The `coordinator.yaml` field `tier2.public_catalog_base_url: "https://coordinator.malibu.tech"`. The five tier-2 `require_*` flags STAY at the Entry 80 defaults (all `false`).

Use the existing `phase4-coordinator/dist/deploy-pearl-vps.sh` script. It now runs `check_nginx_catalog_routes_test.sh` in step 0 (pre-SSH) — if the local nginx conf is stale, it exits 5 with `aborting deploy: nginx /catalog/ routes missing or misconfigured`.

```bash
cd phase4-coordinator/dist
GATEWAY_CONFIG=../../phase5-gateway/dist/gateway.yaml bash deploy-pearl-vps.sh
```

### 2. Smoke check `/poolz` + `/catalog/...`

After SSH + binary install + nginx reload:

```bash
# /poolz should include catalog_id, catalog_url, catalog_pubkey_url
OP=$(gh secret list ...)  # operator key
curl -s -H "Authorization: Bearer $OP" https://coordinator.malibu.tech/poolz | jq 'keys'
# Expect: ["catalog_id", "catalog_pubkey_url", "catalog_url", "pool", "summary"]

# /catalog/pubkey should return the operator-configured pubkey
curl -s https://coordinator.malibu.tech/catalog/pubkey
# Expect: {"pubkey":"<43-char base64url>","alg":"Ed25519"}

# /catalog/<id> should return the on-disk signed catalog bytes verbatim
CID=$(curl -s -H "Authorization: Bearer $OP" https://coordinator.malibu.tech/poolz | jq -r '.catalog_id')
curl -s "https://coordinator.malibu.tech/catalog/$CID" | jq '.catalog_id, .version, (.models | length)'
```

If `/poolz` does NOT include the three new fields, check:

- Is `Tier2Config.CatalogPath` set on Pearl `coordinator.yaml`?
- Did `tier2.Default().Active()` return true? Check coordinator logs for `event:"catalog_loaded"`.
- Is the configured `CatalogPublicKey` the base64url-unpadded form of the matching pubkey?

If `/catalog/pubkey` returns 404, check the same three conditions.

### 3. Provider binary distribution

The v0.3 provider binary emits the new 9-field receipt. **Existing v0.1/v0.2 verifiers (locked releases) will report v0.3 receipts as `invalid` per §M.1.2.** Coordinate the verifier upgrade BEFORE the provider upgrade reaches buyers:

1. Build + sign the new provider binary.
2. Build + release the new `phase7-verify` binary (v1.1.0+). Announce on the release page.
3. THEN roll out the provider binary to Macs (M1, M4, air5, etc.).

For warm-swap-enabled providers, every receipt will carry the loaded MLX container's SHA-256. For warm-swap-disabled providers (the SPEC-011 R-3.3.0 default), every receipt will carry `model_hash: null` and the verifier will report `valid` without catalog-check unless the buyer passes `--require-model-hash`.

### 4. Buyer-side rollout

Buyers should:

- Upgrade to `macprovider-verify` v1.1.0+. The v1.0.x line VERIFIES v0.1/v0.2 receipts only and will REPORT v0.3 receipts as `invalid` (§M.1.2 forward-incompat).
- Optionally pass `--catalog-url https://coordinator.malibu.tech/catalog/<id>` + `--catalog-pubkey-url https://coordinator.malibu.tech/catalog/pubkey` to get model-hash attestation when the receipt carries a non-null hash.
- Buyers wanting STRICT hash attestation (fail-closed on null hash, fail-closed on missing catalog match) should add `--require-model-hash`. This rejects every receipt from a warm-swap-disabled provider.

## Monitoring

Pearl journald already shows `model_hash_verified` events from the coordinator-side observation mode. After v0.3 deploys, watch:

```bash
ssh -i ~/.ssh/pearl_operator_ed25519 root@159.223.165.194 \
  'journalctl -u macprovider-coordinator --since "24h" --no-pager | grep -E "model_hash_verified|catalog_loaded|catalog_signature_invalid"'
```

- `catalog_loaded` should appear once at coordinator startup and on every SIGHUP reload.
- `model_hash_verified` should continue to fire on heartbeats; the `decision`+`reason` fields tell you what the coordinator-side check decided.
- `catalog_signature_invalid` is an alarm; means the operator-configured `CatalogPublicKey` doesn't match the catalog file.

## Rollback

If anything regresses (auth, routing, or `/poolz` shape), follow the
canonical rollback procedure at
[`audits/2026-06-10/ROLLBACK_PROCEDURE.md`](../2026-06-10/ROLLBACK_PROCEDURE.md).
TL;DR for the v0.3 IMPL bundle:

```bash
# Restore the previous binary. The deploy script at
# phase4-coordinator/dist/deploy-pearl-vps.sh step 4/9 snapshots the
# pre-upload binary to /opt/macprovider/coordinator.prev. Issue #244
# R4+R5 tightened ownership to `root:macprovider 0750`. Swap in place:
ssh -i ~/.ssh/pearl_operator_ed25519 root@159.223.165.194 \
  'systemctl stop macprovider-coordinator && \
   install -o root -g macprovider -m 0750 \
     /opt/macprovider/coordinator.prev /opt/macprovider/coordinator && \
   systemctl start macprovider-coordinator'
```

**Nginx rollback.** The deploy script does NOT automatically snapshot
`/etc/nginx/sites-available/coordinator.malibu.tech.conf` before the
new conf is installed. If you want a runtime rollback for the nginx
site, snapshot it BEFORE the deploy:

```bash
ssh -i ~/.ssh/pearl_operator_ed25519 root@159.223.165.194 \
  "cp /etc/nginx/sites-available/coordinator.malibu.tech.conf \
      /etc/nginx/sites-available/coordinator.malibu.tech.conf.bak-$(date -u +%Y%m%dT%H%M%SZ)"
```

To roll back nginx, restore the timestamped backup you took above,
then `nginx -t && systemctl reload nginx`.

`RequireHashVerified` was NOT flipped, so no routing-policy rollback
is needed. The `/catalog/*` endpoint surfaces are additive and zero-
risk if rolled back (verifiers fall back to file-mode `--catalog`).

## Entry 80 invariant

**This deploy does NOT flip `Tier2Config.RequireHashVerified`.** Per `beta/DECISION_CRITERIA.md` Entry 80 (2026-06-22), the flag stays at its `false` default until the team has a buyer-side reason to flip it. v0.3 makes the RECEIPT bind the hash; the coordinator's route/reject policy is independent and unchanged. AC-40 + §M.6 #1 are the spec anchors.

## DECISION_CRITERIA close-out

After v0.3 IMPL ships and the coordinator deploy is queued/landed:

- Append an entry to `beta/DECISION_CRITERIA.md` covering: IMPL step count, audit-round count, what landed, what's deferred to v0.4+, explicit reference to Entry 80 preservation.
- README.md line 22 + lines 113-137 update: v0.3 closes the `model_hash` binding gap; v0.3 receipts are verifiable end-to-end against an operator-signed catalog.

## v0.4+ candidates (deferred per §M.6)

- Streaming receipts (§15 Q5).
- Multi-hash receipts for swap-spanning streaming responses (§15 Q7).
- Cross-catalog federation.
- On-chain anchoring of catalog Merkle roots (§15 Q1 / Cluster D).
- Quantization-aware verification (one `model_id` accept-list of multiple hashes).
- TUF / signed-root upgrade of the catalog-pubkey trust root (§15 Q1).

None of these are landing in v0.3.
