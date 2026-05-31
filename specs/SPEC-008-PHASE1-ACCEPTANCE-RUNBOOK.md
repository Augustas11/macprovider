# SPEC-008 Phase 1 Acceptance Runbook

This runbook covers the remaining production activation for SPEC-008 Phase 1
observe mode. It is intentionally split into two gates:

- Catalog activation proves the coordinator has loaded the signed model catalog
  and is disclosing Tier-2 model-hash state with enforcement off.
- Full provider acceptance proves at least one upgraded provider is reporting a
  catalog-verified model hash.

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
scripts/test-tier2-activation-safety.sh
scripts/check-tier2-release-artifacts.sh
scripts/activate-tier2-observe.sh --plan
```

The safety harness, artifact check, and plan command are non-mutating. The
safety harness replaces `ssh`, `scp`, and `curl` with local fakes and proves the
apply path refuses connected-pool restarts before remote commands, fails closed
when health JSON cannot be parsed, rolls back after config-merge and gateway
disclosure failures, and can reach health, journal, and gateway checks on a fake
success path. The artifact check proves the local provider tarball
checksum/version, coordinator binary checksum/log string, public key, and signed
catalog signature/body using coordinator-compatible catalog validation rules. It
extracts the provider artifact under `TMPDIR` or `/tmp` and only cleans up
directories matching its own `tier2-artifacts.*` pattern. The plan command
validates the activation inputs again with the same signed-catalog verifier
before printing the exact remote actions.

## Gate 1: Catalog Activation

Apply observe-mode activation after accepting the restart window:

```bash
DEMO_TOKEN=<redacted> FORCE_RESTART=1 scripts/activate-tier2-observe.sh --apply
```

The apply path:

- uploads the signed catalog;
- uploads the rebuilt coordinator binary unless `DEPLOY_COORDINATOR_BINARY=0`;
- backs up the remote catalog, coordinator binary, and config where present;
- merges only the top-level `tier2:` block into the live config;
- restarts the coordinator because `catalog_path` and `catalog_public_key` are
  startup-only;
- verifies public coordinator health, recent catalog-loaded journal evidence,
  and gateway `/v1/models` Tier-2 disclosure;
- restores available backups, stopping the coordinator before restoring a prior
  binary, or removes a newly created catalog if catalog upload, binary upload,
  config merge, restart, or verification fails.

The gateway must preserve the coordinator's top-level `tier2` block in
`/v1/models` while still replacing any upstream `tier1_disclosure` with the
gateway-owned disclosure. If a deployed gateway strips `tier2`, activation will
roll back at the post-restart disclosure check.

Catalog activation is accepted when the apply command exits 0 and a read-only
catalog verifier also exits 0:

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

curl -fsSL https://get.streamvc.live/install.sh | \
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
launchctl list | grep live.streamvc.macprovider
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

Current live provider evidence after catalog activation:

- `air5`: `binary_version` `1.2.4`, no `model_hash`, `hash_status`
  `uncatalogued`;
- `air8gb`: `binary_version` `1.2.4`, no `model_hash`, `hash_status`
  `uncatalogued`.

The remaining Phase 1 work is partner/operator rollout of the v1.2.5 provider
artifact to at least one of those Macs, followed by the full verifier above.

## Rollback Notes

If `scripts/activate-tier2-observe.sh --apply` fails during its guarded path, it
attempts rollback automatically. If manual rollback is needed, use the backup
paths printed by the script for:

- `/opt/macprovider/coordinator.yaml`;
- `/opt/macprovider/coordinator`;
- `/opt/macprovider/tier2-catalog.json`.

After manual rollback, restart `macprovider-coordinator` and re-run the
read-only health checks before retrying activation.
