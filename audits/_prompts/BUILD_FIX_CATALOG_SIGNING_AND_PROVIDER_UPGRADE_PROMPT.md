# Build: catalog signing recovery and provider upgrade safety

## Objective

Eliminate the production split-brain between the macprovider-cli baked
autotune catalog, the deployable signed static feed, and coordinator
admission. Make first install, existing-provider upgrade, relaunch, paid
mode, and donor mode recover safely when the catalog changes or a feed is
unavailable.

This is an implementation task. Do not merely re-sign and deploy the current
files: the release pipeline and upgrade flow must prevent this failure from
recurring.

## Mandatory workspace setup

Work in a fresh sibling worktree. Do not edit the canonical checkout.

```bash
git status -sb
git worktree list
git fetch origin
git worktree add ../macprovider-catalog-upgrade -b fix/catalog-upgrade origin/main
cd ../macprovider-catalog-upgrade
```

Read `CLAUDE.md` before editing. Do not inspect `d-inference`.

## Confirmed root cause

The current state is a signed-but-stale catalog split brain:

- `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift` contains a
  baked candidate catalog version `published-2026-07-10-llama32-hash-repair`.
  Its Llama 3.2 row has artifact hash
  `e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90`.
- `phase3-binary/dist/static/autotune-candidates.json` is an older
  `published-2026-07-07-p2-qwen3-8b` feed. Its equivalent row has
  `3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a`.
- `bash phase3-binary/dist/test/check_baked_static_feed_sync.test.sh` fails
  with baked SHA `19702e...` and static SHA `dd55e...`.
- The existing static sidecar is valid for the old bytes and v4 public key.
  This is stale valid content, not a cryptographically invalid sidecar.
- Clients reject a valid live feed older than their baked snapshot and fall
  back to baked content. The coordinator loads its static feed for the
  autotune hello gate, so client evidence and coordinator admission use
  different catalog digests and/or artifact hashes.

## Security constraints

1. Do not fabricate a replacement v4 key. A newly generated key cannot sign
   for the released v4 public key.
2. Never commit any private signing key, seed, token, or KMS credential.
3. The v4 key was deliberately off-repository and is currently unavailable.
   Recovery options are:
   - restore the authorized v4 key from escrow/KMS and sign the exact repaired
     feed; or
   - release a bridge CLI that trusts an explicit v4+v5 keyring, then publish
     a v5-signed feed using a recoverable signing system.
4. A v5 feed alone cannot repair v4-only clients. They need an update/recovery
   path with clear operator messaging, not a generic hash mismatch.
5. Do not weaken model artifact verification, catalog provenance, or the
   coordinator admission cap to make the current mismatch pass.

## Required implementation

### 1. One canonical catalog publication pipeline

Create a single release-oriented source of truth that produces all of:

- `phase3-binary/dist/static/autotune-candidates.json`;
- its detached `.sig` sidecar;
- the baked CLI fallback payload;
- expected SHA/version fixtures used by tests.

The pipeline must make byte drift impossible to ship. It may generate the
Swift embedded payload from static content, or generate both from one canonical
input. Do not maintain both JSON representations manually.

Every release/publish check must fail on:

- baked/static byte drift;
- invalid sidecar JSON, key ID, algorithm, encoding, or Ed25519 signature;
- semantically invalid candidate or demand-rank content;
- a candidate model SHA that is not a lowercase 64-hex digest;
- failed local endpoint digest/signature verification after deployment.

The existing parity script is useful but insufficient; ensure it is run by the
appropriate release/CI/deploy path.

### 2. Recoverable v5 signing process

Replace the single-operator-local-key process with a recoverable restricted
signing procedure. The concrete secret store is an operator decision, but the
repository must support an injected secret file/environment value without
logging it and must document the required provisioning and rotation procedure.

Implement a v4+v5 verifier keyring in the bridge CLI. A sidecar must select a
specific key ID from the release-pinned keyring; unknown keys fail closed.
Existing v4 feeds remain accepted by bridge clients during rollout. Once the
bridge release is available, publish the repaired v5 feed and retain v4
fallback behavior for old binaries.

Update:

- `scripts/resign-autotune-static.sh`;
- `phase3-binary/dist/static/keys/README.md`;
- `AutotuneStaticInputs` in `AutotuneRecommend.swift`;
- key-rotation tests.

Do not generate or print a production private key during ordinary tests.
Use deterministic test-only keys/fixtures.

### 3. Coordinator must verify, not merely read, its feeds

`phase4-coordinator/internal/buyer/autotune_feeds.go` presently loads literal
JSON and sidecar bytes without verifying the sidecar. Change this so startup
fails closed unless each configured feed pair has:

- exactly one strict JSON signature object;
- expected key ID and `ed25519` algorithm;
- valid base64 signature of the exact served bytes using a configured/release
  pinned public key;
- nonempty content.

The candidate feed must additionally parse through the existing catalog
validator before it becomes input to the proof-of-weights hello gate. Ensure
the trust configuration supports the v4+v5 bridge, not a hardcoded one-key
dead end.

Add Go tests for valid fixture, byte tamper, sidecar tamper, wrong key ID,
wrong algorithm, duplicate/trailing JSON, bad base64, and invalid candidate
schema.

### 4. Deployment must prove production bytes

Harden `phase4-coordinator/dist/deploy-pearl-vps.sh` and its tests.

- Stage each JSON/signature pair together and install atomically.
- Verify the pair locally before upload and on the target before coordinator
  restart/reload.
- After restart, fetch every public `/v1/demand-rank`,
  `/v1/demand-rank.sig`, `/v1/autotune-candidates`, and
  `/v1/autotune-candidates.sig` endpoint.
- Compare served bytes to the staged SHA-256 values and cryptographically
  verify each returned sidecar.
- Fail deployment on any mismatch; an HTTP 200 alone is not success.

### 5. First-install catalog UX

The installer must not choose from manual RAM tables that disagree with the
signed/autotune catalog. Existing examples include 32–47 GB defaulting to a
model whose actual catalog minimum is 48 GB.

Use the same verified catalog-selection semantics as the CLI, with the baked
snapshot only as the documented signature/network fallback. Preserve a clear
distinction between:

- network degraded but safe fallback selected;
- signature/catalog mismatch, which requires client update or operator action;
- no eligible paid model;
- donor-mode configuration applied;
- actual artifact hash mismatch.

No user should discover a catalog split only after model download, benchmark,
or relaunch.

### 6. Existing-provider upgrade and relaunch safety

Fix `phase3-binary/dist/install.sh` and the launchd lifecycle.

- `autotune --recommend --apply` must atomically result in the service using
  the new model, artifact path/hash, catalog provenance, and mode.
- The LaunchAgent must not pin `--model`, provider identity, or coordinator in
  a way that overrides config written by autotune. It should use the durable
  config path as the source for mutable values.
- Installer config updates must semantic-merge rather than replace the file
  with four fields. Preserve unowned fields, comments where feasible, token,
  endpoint, supported-model settings, receipt settings, autoupdate policy,
  warm-swap settings, and valid existing mode/provenance.
- Preserve old binary, config, and loaded service until the replacement has
  passed recommendation, startup, local health, and coordinator checks.
- On any failure, restore/restart the last known-good provider and report the
  precise recovery state. Do not leave a provider offline with a partial
  configuration.
- Repair old catalog provenance through an explicit migration/recommendation
  flow. Do not enter an endless launchd crash loop on a known obsolete hash.
- Correct the invalid installer handoff command that advertises unsupported
  `autotune --provider-id`.

### 7. App status contract

If Malibu still treats CLI exit code 6 plus local health as successful, split
the result/status contract so it cannot report a provider live after an
autotune/configuration failure. Distinguish local-network degradation from
catalog, autotune, donor-mode, and launch failures.

## Required regression matrix

Add targeted tests plus appropriate end-to-end coverage for at least:

1. 8, 16, 32, and 48 GB new-provider journeys using the canonical catalog.
2. valid live feed, old-but-valid feed, invalid signature, wrong key ID, bad
   sidecar shape, future feed, and stale feed.
3. wrong artifact hash before download, during cached snapshot repair, and on
   relaunch.
4. v4-only old client behavior, bridge client on v4 feed, bridge client on v5
   feed, and explicit update-required recovery messaging.
5. an existing provider with token, endpoint/mode, warm-swap, receipts,
   supported models, and autoupdate settings upgraded without loss.
6. paid-to-paid re-tune followed by LaunchAgent restart; prove the effective
   process reads the newly applied config.
7. donor-to-paid and paid-to-donor transitions.
8. interrupted download, interrupted apply, failed recommendation, failed
   local health, and failed coordinator visibility; prove rollback.
9. deployment endpoint bytes and signatures exactly match staged artifacts.

Run the smallest targeted tests while iterating, then the relevant full Swift,
Go, installer-shell, and deployment-test suites. Run the repository-required
code, security, and architecture audit lanes before completion; resolve all
critical/high/medium findings.

## Production rollout order

1. Recover v4 signing authority from approved escrow **or** provision a
   recoverable v5 signer.
2. Release the bridge CLI before any v5-only static deployment.
3. Publish static feed pairs through the hardened pipeline.
4. Deploy coordinator only after local cryptographic verification passes.
5. Verify public endpoints return exact signed staged bytes.
6. Exercise a new installation and an old-provider upgrade/relaunch on real
   Apple Silicon before declaring rollout complete.

## Completion criteria

Completion requires fresh evidence that the canonical catalog, CLI fallback,
coordinator admission feed, and publicly served static feed use the same
verified bytes; autotune results survive a service restart; upgrade failure
rolls back safely; and no known old-client recovery path ends in a generic
hash/config crash loop.
