# SPEC-008 Phase 1 Acceptance Runbook

This runbook covers the remaining production activation for SPEC-008 Phase 1
observe mode. It is intentionally split into two gates:

- Catalog activation proves the coordinator has loaded the signed model catalog
  and is disclosing Tier-2 model-hash state with enforcement off.
- Full provider acceptance proves at least one upgraded provider is reporting a
  catalog-verified model hash.

The separate C2 enforcement flip is included at the end only as a guarded
follow-up. Do not run it as part of C1 observe-mode acceptance.

Do not run the apply command unless a coordinator restart is acceptable for the
current pool. The activation script refuses to restart connected providers unless
`FORCE_RESTART=1` is set, and refuses to assume an empty pool when health
parsing fails unless `FORCE_RESTART=1` is set.

## Local Artifacts

Expected local artifacts before activation:

| Artifact | Expected evidence |
|---|---|
| `phase3-binary/dist/phase3-binary-m4-v1.2.5.tar.gz` | `scripts/check-tier2-release-artifacts.sh` logs the observed SHA-256, or compares it when `PROVIDER_SHA256=<expected>` is set; extracted `macprovider-cli --version` prints `1.2.5` |
| `phase4-coordinator/dist/coordinator-linux-amd64` | SHA-256 `8b8bbb58f1062e504d414aaec3712660bf4c98b53a8d49a7554a2288687b1a91`; binary contains `tier2 catalog loaded` |
| `.omc/tier2/tier2-catalog.json` | Signed Ed25519 catalog with two `artifact_manifest` model entries |
| `.omc/tier2/catalog-signing-key.pub` | Public key `IVH2aAlTudARJSK3e7XGmcGjxAqwm6lReGiS-0U9aFQ` |

Private signing keys stay local under `.omc/tier2/` and must not be printed,
committed, or copied into the runbook.

## Preflight

Run these from the repository root:

```bash
bash -n scripts/activate-tier2-observe.sh
bash -n scripts/verify-tier2-live.sh
bash -n scripts/enforce-tier2-hash.sh
scripts/test-tier2-activation-safety.sh
scripts/test-tier2-enforcement-safety.sh
scripts/check-tier2-release-artifacts.sh
scripts/activate-tier2-observe.sh --plan
scripts/enforce-tier2-hash.sh --plan
```

The safety harness, artifact check, and plan command are non-mutating. The
safety harness is hermetic: it generates ephemeral signed Tier-2 catalogs that
match or conflict with the repo autotune release, replaces `ssh`, `scp`, and
`curl` with local fakes, and proves the apply path (1) refuses conflicting /
stale-backup-shaped Tier-2 catalogs before any remote command (#608),
(2) refuses connected-pool restarts before remote commands, (3) fails closed
when health JSON cannot be parsed, (4) rolls back after config-merge and
gateway disclosure failures, and (5) can reach health, journal, and gateway
checks on a fake success path when binding agrees. The artifact check proves
the local provider tarball checksum/version, coordinator binary
checksum/log string, public key, signed catalog signature/body, and
autotune/Tier-2 identity binding when `AUTOTUNE_CANDIDATES` is present. It
extracts the provider artifact under `TMPDIR` or `/tmp` and only cleans up
directories matching its own `tier2-artifacts.*` pattern. The plan command
validates the activation inputs again with the same signed-catalog verifier
and `check-tier2-binding` before printing a plan-only validation summary that
refers live mutation to `deploy-pearl-vps.sh` (no remote action sequence).

The C2 enforcement harness uses fake `ssh` and verifier commands to prove the
guarded apply path reaches reload plus enforced verification on success, refuses
remote mutation when the full preflight verifier fails, and restores the config
backup when enforced verification fails.

## Gate 1: Catalog Activation

Live Tier-2 identity mutation must go through the full Pearl release deploy
(`phase4-coordinator/dist/deploy-pearl-vps.sh`), which pins Tier-2 bytes and
runs `catalog-release.py check-tier2-binding` inside one release transaction
(#608). Do **not** use `scripts/activate-tier2-observe.sh --apply` on Pearl;
that path is retired for live hosts and remains available only as `--plan`
(binding + signature validation) plus hermetic safety tests.

```bash
# Plan-only local validation (non-mutating):
scripts/activate-tier2-observe.sh --plan

# Production activation (preferred):
# phase4-coordinator/dist/deploy-pearl-vps.sh  # with Tier-2 pin + binding check
```

Historical observe-helper apply behavior (retired for live use) previously:

- uploaded the signed catalog;
- uploaded the rebuilt coordinator binary unless `DEPLOY_COORDINATOR_BINARY=0`;
- backed up the remote catalog, coordinator binary, and config where present;
- merged only the top-level `tier2:` block into the live config;
- restarted the coordinator because `catalog_path` and `catalog_public_key` are
  startup-only;
- verified public coordinator health, recent catalog-loaded journal evidence,
  and gateway `/v1/models` Tier-2 disclosure;
- restored available backups, stopping the coordinator before restoring a prior
  binary, or removed a newly created catalog if catalog upload, binary upload,
  config merge, restart, or verification failed.

The gateway must preserve the coordinator's top-level `tier2` block in
`/v1/models` while still replacing any upstream `tier1_disclosure` with the
gateway-owned disclosure. If a deployed gateway strips `tier2`, activation will
fail closed at the post-restart disclosure check.

Catalog activation is accepted when the Pearl deploy completes successfully and
a read-only catalog verifier also exits 0:

```bash
DEMO_TOKEN=<redacted> scripts/verify-tier2-live.sh --catalog-only
```

Expected verifier evidence:

- `gateway_status` is `up`;
- `coordinator_status` is `ok` or `up`;
- `tier2_phase` is `1`;
- `model_hash_state` is present;
- `require_verified` is `false`;
- `catalog_available` is `true`.

## Gate 2: Full Provider Acceptance

Roll out `phase3-binary/dist/phase3-binary-m4-v1.2.5.tar.gz` to at least one
provider after catalog activation. Prefer the signed public installer path over
the legacy `phase3-binary/dist/install-m4*.sh` scripts: those older scripts run
the binary directly and do not install the current websocket provider launch
arguments.

Before asking an operator to upgrade a provider, confirm the GitHub Release is
published and latest:

```bash
gh release view v1.2.5 --repo Augustas11/macprovider \
  --json tagName,assets,url,publishedAt,isDraft,isPrerelease

gh release view --repo Augustas11/macprovider --json tagName
```

The release must include:

- `macprovider-cli-v1.2.5-darwin-arm64.tar.gz`;
- `checksums.txt`;
- `checksums.txt.sig`.

Run one provider first. On the provider Mac, capture the current identity and
model, then invoke the installer non-interactively:

```bash
provider_id="$(cat ~/.config/macprovider/provider_id 2>/dev/null || true)"
model="$(awk -F'"' '/^model:/ {print $2; exit}' ~/.config/macprovider/config.yaml 2>/dev/null || true)"
printf 'provider_id=%s\nmodel=%s\n' "$provider_id" "$model"

curl -fsSL https://get.malibu.tech/install.sh | \
  MACPROVIDER_NO_PROMPT=1 \
  MACPROVIDER_MODEL="$model" \
  bash
```

For the current live pool, the provider IDs must remain `air5` and `air8gb`.
The expected models are:

| Provider | Expected model |
|---|---|
| `air5` | `mlx-community/Qwen2.5-7B-Instruct-4bit` |
| `air8gb` | `mlx-community/Llama-3.2-3B-Instruct-4bit` |

If the installed provider is already running and the operator prefers the
self-update path, use the same public release API as the installer:

```bash
MACPROVIDER_RELEASES_API_URL=https://api.github.com/repos/Augustas11/macprovider/releases/latest \
  ~/macprovider/macprovider-cli update --check

MACPROVIDER_RELEASES_API_URL=https://api.github.com/repos/Augustas11/macprovider/releases/latest \
  ~/macprovider/macprovider-cli update
```

The installer path remains preferred because it verifies `checksums.txt.sig` and
rewrites the launchd plist with the current websocket coordinator arguments.

After the provider command returns, verify locally on that Mac:

```bash
~/macprovider/macprovider-cli --version
launchctl list | grep live.malibu.provider
curl -fsS http://127.0.0.1:8080/v1/models
tail -n 80 ~/Library/Logs/macprovider/macprovider.err.log
```

Then run the full verifier from the operator/dev machine:

```bash
DEMO_TOKEN=<redacted> OPERATOR_KEY=<redacted> scripts/verify-tier2-live.sh --full
```

Full Phase 1 acceptance is reached when the verifier exits 0 and reports at
least one provider with:

- `binary_version` `1.2.5` or newer;
- nonempty `model_hash`;
- `hash_status` equal to `hash_verified`.

The verifier fails if `/poolz` contains `hash_mismatch`, `hash_invalid`, or
`catalog_unavailable` for any provider.

Current live provider evidence after provider rollout and full verification:

- `air5`: `binary_version` `1.2.5`, nonempty `model_hash`, `hash_status`
  `hash_verified`;
- `air8gb`: `binary_version` `1.2.5`, nonempty `model_hash`, `hash_status`
  `hash_verified`.

Phase 1 C1 acceptance completed in observe mode. C2 production enforcement was
then applied and verified separately.

## C2 Enforcement Follow-up

C2 changes routing behavior from observe mode to hard filtering.

Before the flip, prove the live pool is ready:

```bash
DEMO_TOKEN=<redacted> OPERATOR_KEY=<redacted> scripts/verify-tier2-live.sh --full
```

Then apply only the `tier2.require_hash_verified` change on the coordinator and
send `SIGHUP`. `require_hash_verified` is hot-reloadable; `catalog_path` and
`catalog_public_key` are startup-only and must not change in this step. Prefer
the guarded script:

```bash
DEMO_TOKEN=<redacted> OPERATOR_KEY=<redacted> scripts/enforce-tier2-hash.sh --apply
```

The script runs the full verifier before mutation, backs up the live
coordinator config, changes only `tier2.require_hash_verified`, sends `SIGHUP`,
checks recent `tier2 config reloaded` journal evidence, runs the enforced
verifier, and restores the config backup plus SIGHUPs again if reload or
verification fails.

After the reload, verify C2 with:

```bash
DEMO_TOKEN=<redacted> OPERATOR_KEY=<redacted> scripts/verify-tier2-live.sh --enforced
```

Expected C2 evidence:

- `require_verified` is `true`;
- `model_hash_state` is `all`;
- at least one provider is `binary_version` `1.2.5` or newer with
  `hash_status` `hash_verified`;
- no provider reports `hash_mismatch`, `hash_invalid`, or
  `catalog_unavailable`.

Current C2 live evidence:

- `scripts/enforce-tier2-hash.sh --apply` exited 0 after backing up
  `/opt/macprovider/coordinator.yaml` to
  `/opt/macprovider/coordinator.yaml.bak-c2-20260531074241`;
- the live config now has `require_hash_verified: true`;
- `macprovider-coordinator` logged `tier2 config reloaded` at
  `2026-05-31T07:42:45Z`;
- `scripts/verify-tier2-live.sh --enforced` exited 0 with
  `require_verified: true`, `model_hash_state: all`,
  `verified_provider_count: 2`, and both `air5` and `air8gb` on
  `binary_version` `1.2.5` with `hash_status` `hash_verified`.

## Rollback Notes

Do **not** restore `/opt/macprovider/tier2-catalog.json` alone from a backup.
Use the catalog-release / Pearl deploy recovery transaction so autotune and
Tier-2 restore as one release set (`ops/runbooks/catalog-release-provider-upgrade.md`).
The retired `activate-tier2-observe.sh --apply` helper must not be used for
manual incident rollback.

After manual rollback, restart `macprovider-coordinator` and re-run the
read-only health checks before retrying activation.
