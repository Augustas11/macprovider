# Catalog release and provider upgrade runbook

**Status:** implementation and rollout authority for signed autotune catalogs
**Applies to:** provider CLI, Malibu, coordinator, Pearl deploys, release CI
**Security invariant:** model artifact hashes and signed catalog trust never fail open

This runbook closes the July 6–10 catalog split in which valid but different
catalog bytes were embedded in provider binaries and served by the coordinator.
It also defines the provider upgrade transaction required to keep a catalog
repair from restarting a provider with stale launchd arguments or partial
resources.

## 1. System contract

One immutable catalog release is the publication unit. A release contains:

- exact `autotune-candidates.json` and `demand-rank.json` bytes;
- one detached Ed25519 sidecar per JSON file;
- a manifest that binds release ID, timestamps, signer key IDs, and SHA-256;
- an append-only `release-ledger.json` entry that permanently binds the release
  ID to those hashes and signer identities;
- the generated Swift baked resources derived from those exact JSON bytes;
- the model artifact identities consumed by provider evidence and Tier2.

No generated output is edited independently. CI, packaging, coordinator
startup, and deploy all verify the same release before accepting it.

The v2 ledger also records complete pre-ledger publication history. A release
ID observed with more than one signed byte binding is never assigned a
canonical winner: it is moved to the append-only `tombstones` set with every
observed binding and remains `permanently_rejected`. In particular,
`published-2026-07-07-p2-qwen3-8b` is tombstoned because two different
candidate digests were published under that ID. Generation and verification
must reject any attempt to reuse it. The current coordinator omits a
tombstoned optional previous-release bridge. Deployment rollback is armed
before any live coordinator file is replaced and restores the previous binary,
config, systemd unit, and catalog together. A refusal at the late provider gate
restores the files without restarting the incumbent; a failed restart restores
and restarts the old release. The new binary is never left to reinterpret the
ambiguous historical ID after a failed deploy.

The stable model identity is:

```text
(catalog_key, model_id, model_revision, artifact_sha256, policy_version)
```

The whole-feed digest remains tamper and release evidence. It is not the sole
identity for benchmark reuse or provider admission because unrelated rows,
notes, or whitespace must not invalidate every provider.
Previous-release admission additionally requires semantic equality of the
selected row's `draft_candidates` and `workload_profiles`; those policy-bearing
fields may not cross the compatibility bridge merely because the stable model
identity is unchanged. Cached benchmark row identity appends a cross-language
RFC 8785 digest of those same fields when present. The provider exposes that
verified row identity in local status, and the installer requires it to equal
the coordinator admission envelope instead of maintaining a third canonical
JSON implementation in shell. Omitted and explicit `null` optional policy
fields are equivalent; arrays/objects and their contents remain significant.

## 2. Trust and failure policy

| Condition | Provider behavior | Buyer-serving state |
|---|---|---|
| Valid current signed release | Use live release | Eligible after coordinator confirmation |
| Network timeout or HTTP 5xx | Use baked or last-known-good release, visibly degraded | Not `buyer_serving` until release compatibility is confirmed |
| Valid recognized previous release | Use only inside the coordinator compatibility window | Eligible when the coordinator explicitly accepts it |
| Invalid signature, unknown key, malformed sidecar, invalid schema | Preserve last-known-good; report integrity/update-required | Not eligible on the untrusted release |
| Artifact hash mismatch | Fail closed | Not eligible |
| Coordinator release mismatch | Keep local health separate from network readiness | Not `buyer_serving` |

Clients and coordinators load verifier keys from the canonical release keyring.
The repository currently contains only the authorized v4 public key because no
approved, recoverable v5 signing authority has been provisioned. Do not add a
v5 verifier for an operator-local or throwaway private key. Once an approved
escrow/KMS-backed v5 signer exists, rotate v4 to v5 in this order:

1. Publish a bridge binary and coordinator that trust v4 and v5.
2. Observe bridge adoption and keep publishing with v4.
3. Publish an explicitly bridged v5 release.
4. Retire v4 only after the supported client floor no longer requires it.

A v5-only feed must never be the first rotation step. Provisioning that signer
is a credential-gated production prerequisite, not a repository workaround.

## 3. Build and sign a release

1. Update canonical candidate and demand inputs. Never edit generated Swift or
   `dist/static` copies directly.
2. Assign a new immutable release ID and RFC3339 timestamp. Reusing either for
   different bytes is forbidden. Existing entries in
   `phase3-binary/catalog/autotune/release-ledger.json` may not be changed or
   removed, and a tombstoned ID may never be rehabilitated.
3. Generate release outputs and the manifest.
4. Generate canonical bytes, sign them, and run verification. During the
   current recovery window, explicitly select the authorized v4 signer:

   ```bash
   python3 scripts/catalog-release.py generate \
     --signer-key-id streamvc-autotune-static-v4
   AUTOTUNE_STATIC_KEY_ID=streamvc-autotune-static-v4 \
     AUTOTUNE_STATIC_PRIVATE_KEY_PATH="$HOME/.config/macprovider/keys/autotune-static-v4.private.base64" \
     bash scripts/resign-autotune-static.sh
   make verify-autotune-catalog
   ```

5. Confirm the signing key derives a public key already present in the trusted
   keyring. The signer must refuse an unknown or mismatched key.
6. Sign into a temporary release directory. Verify both signatures, strict
   sidecar shape, strict feed schema, exact hashes, and generated-byte parity.
7. Verify against a fetched `origin/main`; a missing comparison ref is a hard
   failure because immutability cannot otherwise be established.
8. Commit canonical inputs, generated outputs, manifest, release ledger,
   public-key metadata, tests, and release notes together. Never commit a
   private key.

For v5, the secret must be injected from the operator-approved secret store as
a restricted temporary file or environment-backed material accepted by the
signing script. Record the escrow/KMS recovery owner and exercise recovery
before adding the v5 public key. Never use a locally generated unescrowed key
for a production bridge.

## 4. CI and release gates

The following are release-blocking:

- canonical-to-generated exact-byte parity;
- strict candidate and demand schema validation;
- lowercase 64-hex artifact hashes and pinned revisions;
- detached-signature verification against the configured keyring;
- immutable release ID/content binding;
- complete historical bindings and immutable rebound-ID tombstones;
- Swift and Go fixture agreement;
- package inclusion of the verified manifest and feeds;
- every canonical non-retired key is present with identical bytes in generated
  Swift and coordinator configuration;
- known-key and unknown-key regression cases (v4 today; v4/v5 after the
  approved v5 public key is added).

`package.sh`, release CI, and Pearl deploy call the same verifier. A test that
only trims, reparses, or semantically compares JSON is insufficient.

## 5. Coordinator activation

The coordinator loads feeds through a fail-closed verified loader:

1. Read JSON and sidecar pairs from one versioned release directory.
2. Strictly parse each sidecar and reject unknown fields.
3. Resolve `key_id` through the configured public-key map.
4. Verify Ed25519 over the literal JSON bytes.
5. Strictly validate both feed schemas and their configured SHA-256 bindings.
6. Construct the candidate admission view only from verified bytes.
7. Expose release ID, digests, signers, and verification times in operator
   status.

The coordinator currently activates configured feeds at process startup; it has
no in-process catalog reload surface. A cold start with configured but invalid
feeds fails closed. A future hot-reload implementation must retain the active
last-known-good in-memory release on verification failure.

## 6. Pearl deployment

Stage and activate atomically:

1. Acquire the controller-lifetime Pearl deploy lock before reading live state.
   A concurrent deploy must fail. The remote holder has SSH keepalives and
   unexpected holder exit terminates the controller path. Arm the local
   lock-loss watcher before the holder can exit.
2. If `/opt/macprovider/.coordinator-deploy-rollback` exists, run the installed
   recovery helper before drift checks. Never delete or replace that snapshot.
   A `committed` marker means only cleanup was interrupted; an uncommitted
   snapshot restores the old release.
3. Install the root oneshot recovery guard and remote deploy watchdog. The
   watchdog waits for both the controller lease and an exclusive operation
   barrier, then restores an uncommitted snapshot. Each live mutation holds the
   shared side of that barrier, so controller SIGKILL or network loss cannot
   race rollback against an SSH command still writing release files. On every
   coordinator start, the guard independently restores an orphaned transaction
   whenever the controller lock is no longer held, covering Pearl reboot.
4. Build a complete snapshot of every release artifact changed after this
   boundary: coordinator, CLI, and three stats binaries; config and convenience
   backups; catalog pointers and signed Tier-2 catalog; coordinator, recovery,
   watchdog, and stats unit files; timer enablement links and active state;
   request-log ACLs; and all coordinator/stats nginx snippets, vhosts, and
   enablement links. Files that were absent are represented by an absent marker
   and are removed during rollback. Write `complete`, then atomically rename it to
   `/opt/macprovider/.coordinator-deploy-rollback`. Recovery rejects and
   preserves any incomplete publication. Recovery stops sidecar scheduling,
   restores the graph, reloads systemd, restores prior runtime state, validates
   nginx, and reloads the restored nginx graph before consuming the snapshot.
   The deploy likewise freezes all stats timers/services immediately after
   publishing the snapshot and does not reactivate them until every public and
   canary check passes, preventing an uncommitted sidecar binary from producing
   external database effects.
   Package installation, Unix principal/directory creation, TCP tuning, and
   successfully issued ACME certificates are independent idempotent
   infrastructure transactions and intentionally remain in place; ACME stub and
   live nginx configuration files are release artifacts and are rolled back.
5. Upload a versioned directory such as
   `/opt/macprovider/autotune/releases/<release-id>/`.
6. On Pearl, verify manifest hashes, signatures, schemas, file ownership, and
   coordinator config before changing the active pointer.
7. Record the old `current` symlink target.
8. On the first rollout, create `current.bootstrap` at the verified staged
   release before config can refer to `current`; on later rollouts, record the
   previous target in root-owned `/opt/macprovider/autotune/.previous-target`.
9. Atomically switch `current` to the verified release and restart/reload the
   coordinator.
10. Fetch each JSON and sidecar endpoint separately. Compare exact SHA-256 with
   staged files and re-verify public signatures.
11. Confirm coordinator health reports the intended release and signer.
12. Set `CATALOG_CANARY_PROVIDER_ID` to a real enrolled canary provider and
   provide `CATALOG_CANARY_AUTH_TOKEN` for the protected compatibility view.
   The deploy must poll `/v1/pool/check` until that exact provider reports
   `buyer_serving: true`, `catalog_admission_mode: current`, the exact active
   release/policy/digest/signer envelope, a valid selected row identity, and
   `catalog_evidence_source: provider_reported`. These authenticated hello fields
   prove coordinator admission compatibility; they are not independent proof of
   the provider's on-disk bytes.
13. Set `CATALOG_CANARY_SSH_TARGET` to the operator-controlled canary Mac and
   `CATALOG_CANARY_SSH_KEY` to a dedicated read-only operator key. Ensure its SSH
   host key is already present in `known_hosts`. The deploy reads the six shipped
   files below `CATALOG_CANARY_INSTALL_DIR` (default
   `macprovider/catalog-release`) through no-follow directory handles and
   compares every SHA-256 with the locally verified release before commit. The
   remote proof must also match `~/.config/macprovider/provider_id`, the live
   `live.streamvc.macprovider` launchd PID and executable inode, that PID's
   configured listening port, and its local catalog status. This prevents an
   admitted provider and a different host with matching bytes from satisfying
   the same canary gate. A legacy bridge, previous release, byte
   mismatch, truly degraded provider, missing identity, unknown canary, or SSH
   trust failure is a deployment failure.

Only after all checks pass, write the committed marker and remove the snapshot.
If rollback itself fails, preserve the snapshot, emit the distinct exit status
70, and stop; never suppress a partial restore. An HTTP 200 alone is not
deployment success.

## 7. Provider install and upgrade transaction

Config is the sole mutable runtime authority. launchd may pass the executable,
`serve`, and config path; it must not pin model, provider ID, coordinator, or
port over values managed in config.

Every installer, manual CLI update, coordinator autoupdate, and Malibu update
uses the same transaction contract:

1. Snapshot binary, adjacent resources, config, launchd plist, recommendation
   state, and the prior service state.
2. Stage the complete signed release payload without overwriting active files.
3. Verify binary signature/hash and resource completeness.
4. Copy config and provider identity into staging. Validate catalog trust and
   recommendation freshness against the staged binary and staged config while
   the old provider remains live. If benchmarks are required, stop the old
   provider first so two full model processes never compete for unified memory.
   Reserve a separate free benchmark port; never reuse the live provider port.
5. Semantic-merge recommendation-owned keys only in staged config; preserve
   unrelated YAML fields, tokens, endpoints, receipts, warm-swap settings, and
   update policy. Do not write live config during recommendation.
6. Stop the old provider only after staged validation, then atomically activate
   staged binary/resources/config/plist.
7. Restart and read back effective model, artifact digest, catalog release,
   signer, trust source, and mode.
8. Require local health plus the coordinator's authoritative public readiness
   verdict for the exact provider. A WebSocket connection alone is not serving
   proof. `/v1/status` reports `buyer_serving` only after an exact, non-redirected
   `details=readiness` response confirms full routing eligibility and a current
   or explicitly recognized previous release; rejection is
   `not_buyer_serving`, and timeouts/rate limits are `buyer_serving_unknown`.
   Malibu invalidates a prior serving verdict whenever status refresh fails.
   Readiness limiting uses a high-capacity per-source aggregate ahead of a
   provider-scoped burst bucket. This bounds rotating-ID abuse while preserving
   headroom and provider fairness for cohorts behind one NAT, with `Retry-After`
   plus provider-jittered retries. The installer and self-update commit only on
   authoritative `buyer_serving`; the public display state may be `degraded` while a busy
   provider is still buyer-serving, so it is not an additional commit gate.
9. On failure, restore every snapshot component and previous service state.

The shell installer takes a kernel-held, no-follow per-user mutex at
`~/.config/macprovider/install.lock` before provider identity selection. It
persists each transaction under
`~/.config/macprovider/install-recovery-<installer-pid>` before changing live
files and deterministically restores any orphan before a later install begins.
It arms the LaunchAgent `live.streamvc.macprovider-install-recovery`, whose
plist lives in `~/Library/LaunchAgents/` and independently observes the exact
installer process start. The agent serializes behind the same mutex and performs
the persisted rollback if the installer is killed or the host restarts. The
installer removes the recovery LaunchAgent only after exact coordinator
admission and buyer-serving readiness commit.
An existing installation invoked with the start-skipping debug override is
rolled back instead of committing an unverified stopped replacement; the
override remains usable for a first install.

CLI self-update and coordinator autoupdate retain release-directory backups,
a durable pending marker, and a stable advisory-lock inode. Manual self-update
owns and completes its marker only after buyer-serving readiness; coordinator
autoupdate completes its own marker after the new process rejoins. Self-update
accepts only a canonical asset whose filename contains the exact release tag,
then executes the staged binary and requires its reported version to equal that
tag before activation; a valid older signed payload cannot be replayed as a
newer release.

An update that cannot restart successfully returns failure. Malibu must not
clear an update error until the readiness contract passes.

## 8. Recommendation objective

Eligibility remains fail-closed on signed catalog, artifact identity, hardware,
benchmark, and rate-card requirements. Eligible models are ordered by expected
operator earnings adjusted for network need:

```text
provider payout
× measured throughput
× buyer demand weight
× signed supply-deficit multiplier
```

The signed demand overlay may include observed ready-provider count or a bounded
supply-deficit multiplier. Missing supply telemetry is neutral; the client must
not invent a shortage. The multiplier is bounded to `0.5...2.0`. v0.6 preserves
`min_dwell_hours` as signed policy metadata but does not auto-switch models;
fleet diversification remains an observed rollout decision rather than a client
side random choice.

Provider recommendation and coordinator admission use the same benchmark
boundary: thermal throttling, measured TPS below `min_sustained_tps`, or TTFT
above `max_4k_ttft_ms` is a hard eligibility failure. Equality at either signed
threshold passes. Swap remains a surfaced operator warning rather than a hidden
coordinator-only rejection.
The recovered immutable v4 catalog contains historical free-text notes that
call some gates advisory. Those notes are provenance only; the structured,
signed `bench_gate` fields and the coordinator admission cap are normative.
Correct the wording only in a newly signed release—never rewrite the recovered
release in place.

Operator output explains hardware fit, measured throughput, expected payout,
demand/shortage contribution, source age, and confidence. Operators retain an
explicit opt-out.

## 9. Required status vocabulary

Provider CLI status, update output, logs, and Malibu use this state contract:

- `live_verified`
- `safe_offline_fallback`
- `catalog_update_required`
- `catalog_integrity_failure`
- `artifact_mismatch`
- `local_donor`
- `buyer_serving`
- `rollback_restored`

Local process health and buyer-serving readiness are distinct. `buyer_serving`
requires local readiness and an active coordinator session that confirms the
current release or the bounded recognized previous release. It does not claim
that a buyer request is currently queued. Catalog integrity or update-required
warnings stop recommendation before model downloads or benchmark execution;
freshness reports such state as stale. A coordinator connection without an
explicit `network_state` is rendered as connected with serving status unknown;
it must never be promoted to `buyer_serving` by the CLI or Malibu.

## 10. Rollout sequence

1. Repair and publish the exact July 10 catalog with the still-trusted v4 key.
2. Deploy coordinator verification and atomic release activation.
3. Provision and recovery-test the approved v5 signer, add its public key to
   the canonical keyring, then ship v4+v5 bridge clients while continuing v4
   publication.
4. Ship config-authority and transactional provider upgrades.
5. Upgrade canary providers, then cohorts, with automatic rollback.
6. Enable row/release compatibility admission only after catalog convergence.
7. Publish supply-aware demand data in observe-only reporting.
8. Enable shortage-aware selection after comparing predicted and actual buyer
   fill rate, provider revenue, churn, and model concentration.
9. Rotate publication to v5 only after the supported client floor trusts it.

## 11. Verification checklist

- [ ] Canonical generator produces exact static and Swift bytes.
- [ ] Release ledger matches `origin/main`; no binding or tombstone was changed
      or removed, all known historical releases are present, and rebound IDs
      remain permanently rejected.
- [ ] Both current static sidecars verify against a trusted public key.
- [ ] Canonical keyring, generated Swift keyring, and coordinator public-key
      configuration are byte-identical for every non-retired verifier.
- [ ] Unknown key, malformed sidecar, tampered JSON, stale release, and trailing
      data all fail as specified.
- [ ] Coordinator refuses configured unverified feeds on cold start.
- [ ] Coordinator refuses configured unverified feeds on every restart; no hot
      reload path bypasses verification.
- [ ] Deploy verifies exact staged-versus-served hashes, observes the named
      canary buyer-serving on the exact current catalog envelope, independently
      binds the trusted canary Mac's provider identity and live executable to
      its exact installed release bytes, and rolls back atomically on failure.
- [ ] Controller loss during a live mutation is serialized behind the remote
      operation barrier; rollback restores the exact prior Tier-2 catalog.
- [ ] launchd contains no mutable config overrides.
- [ ] Existing config fields survive installer and recommendation.
- [ ] Recommendation uses staged config plus a reserved non-live benchmark
      port; live config is unchanged and weight-loading benchmarks do not begin
      until the old provider stops.
- [ ] Restart failure returns failure and restores binary/resources/config/plist.
- [ ] SIGKILL/reboot-orphaned installer transaction is restored by the recovery
      LaunchAgent before another install proceeds.
- [ ] Malibu distinguishes installed, locally healthy, admitted, buyer-serving,
      and rolled-back states.
- [ ] Provider evidence survives unrelated catalog-row changes.
- [ ] Supply deficit affects ranking only when signed telemetry is present.
- [ ] Swift, Go, shell, package, and deployment regression suites pass.
- [ ] Code, security, and architecture audits report zero CRITICAL/HIGH/MEDIUM.

## 12. Current external rollout gate

Repository implementation and v4 recovery publication can be completed and
tested without production credentials. A v5 bridge cannot honestly be declared
production-ready until an operator provisions a restricted, recoverable v5
signer and supplies only its public key to this repository. Required evidence:

- signer custody and recovery owners are named;
- a recovery exercise produces the same public key;
- CI/deploy can request signing without logging or persisting secret material;
- the bridge binary and coordinator accept v4 and v5 while publication remains
  on v4;
- fleet adoption meets the documented threshold before v5 publication and,
  later, v4 retirement.
