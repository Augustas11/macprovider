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

One immutable network release is the publication and activation unit. Its
catalog member contains:

- exact `autotune-candidates.json`, `demand-rank.json`, and signed
  `tier2-catalog.json` bytes;
- detached Ed25519 sidecars for the autotune and demand feeds, plus the
  Tier-2 catalog's embedded Ed25519 signature;
- a manifest that binds release ID, timestamps, signer key IDs, and SHA-256;
- an append-only `release-ledger.json` entry that permanently binds the release
  ID to those hashes and signer identities;
- the generated Swift baked resources derived from those exact JSON bytes;
- the model artifact identities consumed by provider evidence (autotune
  `model_sha256` / `macprovider.snapshot-manifest.v1`).

### Tier-2 identity binding (#608 Partial → finish slice: derived-only mutate)

`tier2-identity-binding.json` is a **repository-local derived projection**
written by `catalog-release.py generate`. It is **not** a member of the
signed autotune release envelope (`release.json` / ledger / Pearl immutable
release directory / provider package). Operators must not treat it as a
substitute for the signed Tier-2 file.

A **signed** `tier2-catalog.json` (the `sign-catalog.go`-produced file, not
the derived binding above) is a mandatory third `release.json` /
`release-ledger.json` feed member alongside `autotune-candidates.json` and
`demand-rank.json`. `generate`, `verify`, and `verify-directory` fail closed
when it is absent, drifts from its manifest record, conflicts with autotune,
or fails Ed25519 authentication against the exact configured Tier-2 trust
root. Provider packaging, compatibility-set metadata, acceptance promotion,
Pearl updater, and direct Pearl deploy all carry and validate the same bytes.

Historical two-feed ledger rows remain valid as immutable history. A legacy
current release may be enriched once with the canonical Tier-2 member only
when its release metadata and both existing feed records remain byte-for-byte
identical; no new two-feed row or later Tier-2 removal is accepted.

Pearl release directories are content-addressed as
`<release_id>-<catalog asset-set sha256 prefix>`, where the digest binds every
signed catalog envelope member (`release.json`, `trusted-keys.json`, all three
feed files, and detached feed signatures). A keyring-only or signature-only
catalog change therefore creates a new immutable directory instead of
overwriting an existing directory with the same release ID. After Entry 190,
the coordinator reads Tier-2 only from
`/opt/macprovider/autotune/current/tier2-catalog.json`. Updater and direct
deploy stage all three signed feeds inside the immutable release directory,
then atomically switch the single `autotune/current` pointer. During the
one-time Step D migration, any independent
`/opt/macprovider/tier2-catalog.json` must exactly match the active
release-bound feed before mutation; the rollback-armed transaction removes it
instead of copying new bytes to it. Rollback from that first cutover restores
the prior config, pointer, and legacy bytes together. Later rollback changes
only the pointer and preserves the legacy path as absent.

Step D does not flip `tier2.require_hash_verified`, enable canary, or clear a
compatibility exception before production journey evidence. Those actions
remain gated by the later #608/#609 serial steps.

Autotune admission identity and the Tier-2 attestation catalog remain separate
signed feed members inside one release envelope. The
`exc-catalog-compatibility-bridges` exception stays active until Pearl proves
the physical single-authority cutover and three exact buyer-serving journeys.
Until then the interim rule is **derived-only mutate**:

1. `scripts/catalog-release.py generate` writes
   `phase3-binary/catalog/autotune/tier2-identity-binding.json` from the
   current autotune rows (HighestClaimedTier semantics) for operator tooling.
2. `scripts/catalog-release.py derive-tier2` is **disabled** until Tier-2 gains
   an explicit `macprovider.snapshot-manifest.v1` hash_scope (emitting under
   existing SPEC-008 scopes would mislabel the digest). Operators continue to
   author/sign Tier-2 with `scripts/sign-catalog.go` after review, using
   `tier2-identity-binding.json` + `check-tier2-binding` as the drift gate.
   Signing alone does **not** authorize a live catalog.
   `scripts/catalog-release.py stage-tier2-republish` helps close a detected
   conflict: it projects autotune-derived hashes from
   `tier2-identity-binding.json` onto an operator-supplied template (e.g. the
   current live Tier-2 file) for overlapping `model_id`s only, leaving every
   other reviewed field (`hash_scope`, `artifact_kind`, `min_ram_gb`, `notes`,
   `source`) untouched, and refuses to write output unless the staged body
   already passes `check-tier2-binding`. It is a staging aid for
   `sign-catalog.go`, not a second identity authority. See
   `ops/runbooks/608-llama-tier2-republish.md` for a worked example.
3. `scripts/catalog-release.py check-tier2-binding` and Pearl
   `deploy-pearl-vps.sh` fail closed when an overlapping `model_id` has a
   Tier-2 `sha256` that disagrees with the autotune `model_sha256`. Deploy
   pins the verified Tier-2 bytes before upload.
4. `scripts/activate-tier2-observe.sh` is **not** a second authority: `--plan`
   refuses before any mutation when `check-tier2-binding` fails against
   `AUTOTUNE_CANDIDATES` (default:
   `phase3-binary/catalog/autotune/autotune-candidates.json`). Live `--apply`
   is retired; prefer `deploy-pearl-vps.sh` for the full release transaction.
   Never restore `/opt/macprovider/tier2-catalog.json` as a standalone
   authority. Only the rollback-armed first-cutover transaction may restore
   that legacy path, and it restores the matching prior config and
   `autotune/current` pointer in the same rollback.
5. Coordinator startup and Tier-2 SIGHUP reload fail closed on the same
   conflict (`internal/catalogbind`). Stale Tier-2 backups cannot be
   restored against a newer autotune release when they drift on shared rows.
6. Admission identity remains autotune-only (Entry 170 / #609). This binding
   check does **not** add a Tier-2 fallback.

Follow-up on #608 remains blocked for exception clearance until Pearl proves
the legacy path absent, the coordinator cold-started against the release-bound
feed, three authenticated gateway requests with unique request IDs and exact
physical-provider/model attribution plus a matching post-request
`buyer_serving` catalog-admission proof, and zero `model_hash_uncatalogued` or
`model_hash_mismatch` events for active-release rows.
`tier2.require_hash_verified` stays false throughout this step.

The same signed network-release manifest also binds:

- provider version `1.8.31`, Malibu build `31`, the provider executable, and
  every adjacent catalog/keyring resource shipped in its archive;
- the compatible coordinator and gateway Linux binaries as one backend pair;
- the exact catalog release directory selected as the next `current`; the
  activation transaction derives `previous` from the verified live pointer and
  snapshots it before mutation;
- coordinator configuration that advertises the same provider version. The
  stable public release gate must prove live
  `/healthz.recommended_binary_version` equals the provider CLI release before
  undrafting and moving `latest`; prerelease canaries do not require fleet-wide
  advertisement.

No generated output is edited independently. CI, packaging, coordinator
startup, and deploy all verify the same release before accepting it.
The signed Pearl updater is the unattended activation authority for the
backend binary pair plus catalog pointers. It may not advance any member alone.

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
- provider version, Malibu build ledger, archive payload, and every coordinator
  advertisement agree at `1.8.31` / build `31`;
- the signed Pearl manifest includes the coordinator, gateway, and all seven
  catalog payload files under one catalog release identity;
- no backend or provider payload member is present outside its manifest, and no
  manifest member is absent from the staged release;
- every canonical non-retired key is present with identical bytes in generated
  Swift and coordinator configuration;
- known-key and unknown-key regression cases (v4 today; v4/v5 after the
  approved v5 public key is added).

`package.sh`, release CI, the signed Pearl updater, and direct Pearl deploy call
the same verifier. A test that only trims, reparses, or semantically compares
JSON is insufficient.

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

### 5.1 Bounded provider migration bridge

The bridge is coordinator-first; there is no provider success exception for a
legacy coordinator.

1. Activate the signed coordinator+gateway+catalog payload with
   `autotune.enforce_provider_admission: false` and an absolute RFC3339
   `autotune.provider_admission_bridge_deadline` no more than 24 hours in the
   future. Missing, expired, malformed, or farther deadlines prevent startup.
   Metadata-free providers are
   classified `legacy_bridge`, remain serving-capable, and remain visible in
   capacity telemetry. Partial catalog metadata, invalid signatures, stale or
   mismatched release identity, and artifact mismatch still fail closed in
   bridge mode.
2. Before backend activation, capture the operator-controlled canary Mac's prior
   signed tag and prefetch the candidate without mutating the live provider:

   ```bash
   ~/macprovider/macprovider-cli --version | tee canary-prior-provider-tag.txt
   KEEP_DOWNLOADS=1 scripts/verify-tier2-provider-release.sh --tag v1.8.31
   ```

   The verifier downloads the complete provider asset set, verifies the signed
   checksum manifest and artifact hash, and checks the release payload. Keep the
   prior provider live; do not run the installer against the legacy coordinator,
   because its exact buyer-serving admission gate correctly rolls back a
   non-serving candidate.

   Start the signed Pearl updater in one operator terminal. Only after the new
   coordinator is locally healthy, its startup telemetry proves the configured
   bridge deadline is active, and the updater's transaction remains rollback
   armed, start the already pinned installer from a second terminal on this one
   canary:

   ```bash
   curl -fsSL https://get.streamvc.live/install.sh | \
     MACPROVIDER_VERSION=v1.8.31 MACPROVIDER_NO_PROMPT=1 bash
   ```

   The installer must commit only after this bridge coordinator returns the
   exact `current` buyer-serving envelope. The still-armed Pearl updater then
   requires the same provider ID, release/policy/digest/signer/row, exact seven
   catalog files, and live text vnode before it can persist backend success. If
   the canary installer fails, its own transaction restores the prior provider
   while the Pearl updater remains able to roll back the backend. Do not raise
   the general recommendation to v1.8.31 until both transactions commit.
3. Upgrade v1.8.31 provider cohorts. Each update commits only after that
   coordinator authoritatively reports the exact provider
   `buyer_serving:true` with `catalog_admission_mode:current|previous`. Missing
   catalog compatibility from a legacy coordinator is not accepted.
4. Before apply, capture a protected `/poolz` baseline containing the exact
   provider IDs, `summary.ready`, `summary.free_slots`, and each provider's
   routing/admission state. Record an operator-approved minimum buyer-capacity
   floor. The signed updater commit policy must prove all of the following while
   rollback is still armed: the local `/healthz` `pool_ready` value is at or
   above that floor, the configured bridge is active with enough time remaining
   for provider and backend rollback, metadata-free capacity remains admitted as
   `legacy_bridge`, and the exact catalog-aware canary passes. One successful
   buyer request or one current provider is not a fleet-capacity proof.

   Track `legacy_bridge` session count, the startup
   `autotune_provider_admission_bridge_deadline` / remaining-duration log
   fields, and provider-version adoption. Before activation, record
   `BRIDGE_STARTED_AT` and set `BRIDGE_DEADLINE` to the exact configured
   deadline, no later than 24 hours after activation. At the deadline, the
   coordinator mechanically reclassifies every connected `legacy_bridge`
   session as `legacy` and excludes it from buyer routing/capacity. Before that
   happens, either
   proceed to strict enforcement because the zero-bridge gate passed, or stop
   recommendations, restore upgraded providers to their prior complete release,
   verify legacy capacity, and then roll back the backend bridge payload.
   Extension requires a new dated decision-log entry and a new explicit config
   deadline; an operator note or silent timer reset is invalid.

   The rollback branch is executable only if its provider artifacts and cohort
   inventory were prepared before activation. Store a root-owned inventory with
   exact provider ID, operator SSH target, prior provider tag, retained model,
   model artifact provenance, absolute path and SHA-256 of a retained
   owner-only (`0600`) copy of the complete pre-upgrade config, and upgrade time
   for every admitted cohort member. Create that backup on each Mac before
   activation and record the emitted digest:

   ```bash
   PRIOR_CONFIG_BACKUP="$HOME/.config/macprovider/emergency-backups/${PRIOR_PROVIDER_TAG}-config.yaml"
   mkdir -p "$(dirname "$PRIOR_CONFIG_BACKUP")"
   chmod 700 "$(dirname "$PRIOR_CONFIG_BACKUP")"
   install -m 600 "$HOME/.config/macprovider/config.yaml" "$PRIOR_CONFIG_BACKUP"
   PRIOR_CONFIG_SHA256="$(shasum -a 256 "$PRIOR_CONFIG_BACKUP" | awk '{print $1}')"
   printf 'backup=%s sha256=%s\n' "$PRIOR_CONFIG_BACKUP" "$PRIOR_CONFIG_SHA256"
   ```

   Do not use the live config path as its own backup. Emergency targets must be the
   immediate prior signed release, must be older than the installed release,
   and must be `v1.8.30` or newer; `v1.7.11` predates the config-compatible
   emergency contract and is not a rollback target. For each distinct prior tag, download
   `checksums.txt` and `checksums.txt.sig`, verify the detached signature with
   the pinned release public key, confirm the exact Darwin package or tar asset
   is listed, and fetch that asset successfully. A tag without its complete
   signed asset set is not a rollback candidate.

   First stop recommendations by setting the coordinator's
   `coordinator_advertised_version.latest_binary_version` to the exact
   `$PRIOR_PROVIDER_TAG` version and restarting it. Prove the public health
   response reports that exact value before touching a Mac:

   ```bash
   test "$(curl -fsS https://coordinator.streamvc.live/healthz | \
     jq -r .recommended_binary_version)" = "${PRIOR_PROVIDER_TAG#v}"
   ```

   Then restore every inventoried Mac through the
   signed operator-pinned installer channel:

   ```bash
   curl -fsSL https://get.streamvc.live/install.sh | \
     MACPROVIDER_VERSION="$PRIOR_PROVIDER_TAG" \
     MACPROVIDER_EMERGENCY_ROLLBACK=1 \
     MACPROVIDER_EMERGENCY_CONFIG_BACKUP="$PRIOR_CONFIG_BACKUP" \
     MACPROVIDER_EMERGENCY_CONFIG_SHA256="$PRIOR_CONFIG_SHA256" \
     MACPROVIDER_NO_PROMPT=1 bash
   ```

   This is an explicit operator-authorized emergency downgrade. The installer
   still verifies the release signature/checksums and complete payload and takes
   the unified mutation locks. It also requires the coordinator advertisement
   proof above, restores the exact inventoried config bytes, and transactionally
   adds the v1.8.30-compatible top-level autoupdate opt-out. Nested YAML is
   preserved byte-for-byte. Before commit, the installer proves the activated
   config hash matches its staged restored copy and that the prior model is
   unchanged, preventing the restored binary from immediately upgrading itself.
   Re-enable provider autoupdate only after the backend decision is complete.
   This mode is valid only with an explicit older
   pinned tag while the bounded bridge is active and unexpired. It may commit
   only when the exact provider ID is authoritatively `buyer_serving:true` in
   `catalog_admission_mode:legacy_bridge`; `legacy`, an expired bridge, missing
   evidence, or any other admission mode fails and restores the candidate-side
   transaction. Coordinator autoupdate remains upgrade-only and MUST NOT gain an
   automatic downgrade exception. For every inventory row, verify the local
   binary reports the exact prior tag, the installer log contains the expected
   `source_sha256` and an `activated_sha256`, and the coordinator reports that provider
   buyer-serving through `legacy_bridge`. Persist those results. Only after all
   upgraded cohorts are restored and legacy capacity is proven may the backend
   bridge payload be rolled back.
5. Prove zero `legacy_bridge` continuously for 15 minutes from the protected
   operator `/poolz` surface. Prepare a root-only curl config containing the
   operator bearer header, set `POOLZ_CURL_CONFIG` to it, and run this on the
   trusted operator host; any HTTP, JSON, or nonzero-count sample resets the
   decision and requires a fresh complete run:

   ```bash
   set -euo pipefail
   umask 077
   : "${POOLZ_CURL_CONFIG:?root-only curl config is required}"
   : "${MIN_READY:?protected ready-provider floor is required}"
   : "${MIN_FREE_SLOTS:?protected free-slot floor is required}"
   EVIDENCE="bridge-zero-$(date -u +%Y%m%dT%H%M%SZ).jsonl"
   SAMPLE="$(mktemp -t macprovider-poolz.XXXXXX)"
   trap 'rm -f "$SAMPLE"' EXIT
   STARTED=$(date +%s)
   UNTIL=$((STARTED + 900))
   while :; do
     curl --fail --silent --show-error --max-time 10 \
       --config "$POOLZ_CURL_CONFIG" \
       https://coordinator.streamvc.live/poolz >"$SAMPLE"
     python3 - "$SAMPLE" "$EVIDENCE" "$MIN_READY" "$MIN_FREE_SLOTS" <<'PY'
   import datetime, json, pathlib, sys
   payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
   pool = payload.get("pool")
   summary = payload.get("summary")
   if not isinstance(pool, list) or not isinstance(summary, dict):
       raise SystemExit("invalid protected pool snapshot")
   counts = {}
   for provider in pool:
       mode = provider.get("catalog_admission_mode", "")
       counts[mode] = counts.get(mode, 0) + 1
   record = {
       "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
       "legacy_bridge": counts.get("legacy_bridge", 0),
       "legacy": counts.get("legacy", 0),
       "current": counts.get("current", 0),
       "previous": counts.get("previous", 0),
       "ready": summary.get("ready"),
       "free_slots": summary.get("free_slots"),
   }
   with pathlib.Path(sys.argv[2]).open("a", encoding="utf-8") as handle:
       handle.write(json.dumps(record, sort_keys=True) + "\n")
   if record["legacy_bridge"] != 0:
       raise SystemExit("legacy_bridge is not zero")
   for key, minimum in (("ready", int(sys.argv[3])), ("free_slots", int(sys.argv[4]))):
       value = record[key]
       if type(value) is not int or value < minimum:
           raise SystemExit(f"{key} buyer capacity is below the protected floor")
   PY
     NOW=$(date +%s)
     [ "$NOW" -ge "$UNTIL" ] && break
     sleep 30
   done
   test "$(wc -l <"$EVIDENCE")" -ge 31
   ```

   Preserve the resulting root-only JSONL with the release evidence. Then set
   `autotune.enforce_provider_admission: true` and restart the
   coordinator. Restart is mandatory so every session re-admits under strict
   policy. Metadata-free sessions then classify as `legacy`: operator-visible
   but excluded from buyer routing and serving-capacity totals.

   After this closure, every later protected release must select
   `provider_admission_policy: strict_post_migration` in the release workflow,
   and Pearl must run with
   `PEARL_UPDATER_PROVIDER_ADMISSION_POLICY=strict_post_migration` plus
   `PEARL_UPDATER_MINIMUM_BRIDGE_REMAINING_S=0`. The signed strict policy
   transactionally stages `enforce_provider_admission: true` and removes any
   old bridge deadline. Never select `bridge_required` after closure unless a
   new dated migration decision explicitly authorizes reopening a bounded
   bridge.
6. Verify zero `legacy` buyer-serving rows, exact current/previous admission for
   every serving provider, and buyer canary success. Roll back the complete
   backend+catalog payload if strict enforcement unexpectedly removes required
   capacity.

Outside the single controlled, local-only commit-witness staging in step 2, do
not run provider-first against a coordinator that predates this bridge. Do not
count `legacy_bridge` as migration completion merely because it is serving.

## 6. Pearl deployment authorities

The signed updater and direct deploy share the global mutex and catalog
verification rules, but they have different mutation authority and rollback
boundaries. Do not treat them as interchangeable deployment commands.

### 6.1 Shared serialization

1. Acquire `/run/lock/macprovider-pearl-updater.lock` before reading or changing
   any live backend, catalog, pointer, configuration, unit, database-writer, or
   nginx state. The signed Pearl updater and direct deploy use this same
   root-owned, no-follow global mutex; contention fails closed. Direct deploy
   may retain the older coordinator controller lease and operation barrier only
   inside this global ownership boundary for watchdog/recovery compatibility.
   No path may acquire the global mutex while holding a legacy inner lock.

### 6.2 Signed updater: backend pair plus catalog

The signed updater is the only unattended authority allowed to replace the
coordinator/gateway pair. It verifies the signed network-release manifest as
one complete payload before snapshot or service drain. Coordinator, gateway,
and all seven catalog files must be present and hash-exact. It additionally runs
the canonical `catalog-release.py verify-directory` verifier over the candidate
directory so both feed Ed25519 signatures, strict schemas, canonical bytes, and
manifest bindings are verified inside the signed outer release. It rejects a
binary-only or catalog-only manifest.

The updater snapshots and activates the backend pair and catalog together. It
keeps rollback armed through binary health, the generic buyer canary, exact
catalog status, and an explicit exact provider canary. Configure
`PEARL_UPDATER_CATALOG_CANARY_PROVIDER_ID`, its root-only deployment bearer-token
file, a host-key-pinned SSH target/key, and the canary install directory. Before
success persistence, the selected provider must report `buyer_serving:true`,
`catalog_admission_mode:current`, and the exact release/policy/digest/signer/row
envelope. Independently, the updater reads all seven installed catalog files on
that Mac through no-follow handles, binds provider ID and local status to the
same row, and proves the live launchd PID's actual text vnode and listener use
that installation. Only then may it persist success and disarm rollback.

### 6.3 Direct deploy: catalog/config validation only

Direct deploy is not a backend-pair release authority. Run the signed updater
first whenever coordinator or gateway bytes must change. Direct deploy proves
the uploaded coordinator is byte-identical to the already installed signed
coordinator and refuses coordinator-only replacement. Inside that boundary it
may update catalog/config/operator sidecars and restart the installed pair.

The direct-deploy recovery procedure is:

1. If `/opt/macprovider/.coordinator-deploy-rollback` exists, run the installed
   recovery helper before drift checks. Never delete or replace that snapshot.
   A `committed` marker means only cleanup was interrupted; an uncommitted
   snapshot restores the old release.
2. Install the root oneshot recovery guard and remote deploy watchdog. The
   watchdog waits for both the controller lease and an exclusive operation
   barrier, then restores an uncommitted snapshot. Each live mutation holds the
   shared side of that barrier, so controller SIGKILL or network loss cannot
   race rollback against an SSH command still writing release files. On every
   coordinator start, the guard independently restores an orphaned transaction
   whenever the controller lock is no longer held, covering Pearl reboot.
3. Build a complete snapshot of every release artifact changed after this
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
4. Upload a versioned directory such as
   `/opt/macprovider/autotune/releases/<release-id>/`.
5. On Pearl, verify manifest hashes, signatures, schemas, file ownership, and
   coordinator config before changing the active pointer.
6. Record the old `current` symlink target and old `previous` target record.
7. On the first rollout, create `current.bootstrap` at the verified staged
   release before config can refer to `current`; on later rollouts, record the
   previous target in root-owned `/opt/macprovider/autotune/.previous-target`.
8. Stop/drain the old serving graph, prove the staged coordinator bytes equal
   the installed signed coordinator, switch only the catalog/config surfaces
   direct deploy owns, set `previous` to the former verified current release,
   and restart the already installed pair. Any partial activation is failure and
   restores the complete direct-deploy snapshot.
9. Fetch each JSON and sidecar endpoint separately. Compare exact SHA-256 with
   staged files and re-verify public signatures.
10. Confirm coordinator and gateway health report the installed signed pair and
   coordinator catalog status reports the intended release/signer.
11. Set `CATALOG_CANARY_PROVIDER_ID` to a real enrolled canary provider and
   provide the coordinator operator key, not the gateway/coordinator service
   token. Prefer a stable local secret source on the operator Mac rather than a
   raw shell variable: either `CATALOG_CANARY_AUTH_TOKEN_FILE` pointing at a
   `0600` one-line bearer-token file, or a macOS Keychain generic-password item
   selected by `CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_SERVICE`
   (default `macprovider.catalog-canary.operator-token`) and
   `CATALOG_CANARY_AUTH_TOKEN_KEYCHAIN_ACCOUNT` (default current `USER`).
   `CATALOG_CANARY_AUTH_TOKEN` remains accepted only as an explicit override.
   For file-based operation, keep the token file outside the repo and verify
   `/usr/bin/stat -f %Lp "$CATALOG_CANARY_AUTH_TOKEN_FILE"` reports `600`.
   For Keychain operation, provision the item once from the trusted
   operator-held token by running `/usr/bin/security add-generic-password -U -s macprovider.catalog-canary.operator-token -a "$USER" -w`,
   then entering the token at the prompt; do not pass the token in argv.
   Do not copy the operator key out of Pearl during deploy. The deployment
   compatibility view is `/v1/pool/check?details=deployment`, which is
   operator-only; the deploy script proves this token against the Pearl
   coordinator operator-key digest before any upload or restart.
   The deploy must poll `/v1/pool/check` until that exact provider reports
   `buyer_serving: true`, `catalog_admission_mode: current`, the exact active
   release/policy/digest/signer envelope, a valid selected row identity, and
   `catalog_evidence_source: provider_reported`. These authenticated hello fields
   prove coordinator admission compatibility; they are not independent proof of
   the provider's on-disk bytes.
12. Set `CATALOG_CANARY_SSH_TARGET` to the operator-controlled canary Mac and
   `CATALOG_CANARY_SSH_KEY` to a dedicated read-only operator key. Ensure its SSH
   host key is already present in `known_hosts`. The deploy reads the seven shipped
   files below `CATALOG_CANARY_INSTALL_DIR` (default
   `macprovider/catalog-release`) through no-follow directory handles and
   compares every SHA-256 with the locally verified release before commit. The
   remote proof must also match `~/.config/macprovider/provider_id`, the live
   `live.streamvc.macprovider` launchd PID and executable path/device/inode from
   `lsof`, that PID's configured listening port, and its local catalog status.
   Its policy version and selected row identity must exactly match the
   coordinator-admitted envelope. This prevents an
   admitted provider and a different host with matching bytes from satisfying
   the same canary gate. A legacy bridge, previous release, byte mismatch, truly
   degraded provider, missing identity, unknown canary, or SSH trust failure is
   a deployment failure.

Only after all direct-deploy checks pass, write its committed marker, remove
its snapshot, and release `/run/lock/macprovider-pearl-updater.lock`. If rollback
itself fails, preserve the snapshot, emit exit status 70, and stop; never
suppress a partial restore. An HTTP 200 alone is not deployment success.


## 7. Provider install and upgrade transaction

Config is the sole mutable runtime authority. launchd may pass the executable,
`serve`, and config path; it must not pin model, provider ID, coordinator, or
port over values managed in config.

Every installer, manual CLI update, coordinator autoupdate, and Malibu update
uses the same transaction contract:

1. Snapshot binary, adjacent resources, config, launchd plist, recommendation
   state, and the prior service state.
2. Stage the complete signed release payload without overwriting active files:
   versioned executable, manifest, both catalog JSON files, both detached
   sidecars, and trusted verifier keyring.
3. Verify binary signature/hash, manifest binding, and exact resource
   completeness. Extra security-critical or unmanifested payload members fail
   as closed as missing members.
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
   `details=readiness` response confirms `buyer_serving: true` and a current or
   explicitly recognized previous release for the exact provider; rejection is
   `not_buyer_serving`, and timeouts/rate limits are `buyer_serving_unknown`.
   Malibu invalidates a prior serving verdict whenever status refresh fails.
   Readiness limiting uses a high-capacity per-source aggregate ahead of a
   provider-scoped burst bucket. This bounds rotating-ID abuse while preserving
   headroom and provider fairness for cohorts behind one NAT, with `Retry-After`
   plus provider-jittered retries. The installer and self-update commit only on
   authoritative `buyer_serving`. A busy provider with zero free slots remains
   serving-capable and may satisfy this gate even though its instantaneous
   `RoutingEligible()` result is false. Never require or report “full routing
   eligibility” for that busy state. A truly degraded, draining, legacy,
   incompatible, or sanctioned provider cannot satisfy the gate.
9. On failure, restore every snapshot component and previous service state.

Every provider writer first takes the same kernel-held, no-follow outer mutex at
`~/.config/macprovider/install.lock`. This includes the shell installer, manual
CLI update, coordinator autoupdate, Malibu update, watchdog, and install or
autoupdate recovery. Autoupdate writers and observers then take the existing
inner `~/.local/share/macprovider/autoupdate/update.lock`. The only permitted
order is outer `install.lock`, then inner `update.lock`; release is inner then
outer, and no code may wait for the outer lock while holding the inner lock.
The installer/recovery owner record binds PID, process start, boot identity,
operation, and transaction ID, so PID reuse cannot steal installer ownership;
Swift mutators validate that record in addition to taking the same outer kernel
lock. A durable pending marker continues to fence new installers/updaters until
exact admission commit or recovery. Lockfiles use stable/no-follow inodes; an
unheld stale file is not contention.

The shell installer acquires that outer lock before provider identity selection. It
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

CLI self-update and coordinator autoupdate retain complete release-directory
backups, a durable pending marker, and stable advisory-lock inodes. Manual
self-update and coordinator autoupdate complete their marker only after the new
process receives exact current-or-previous buyer-serving readiness. Self-update
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
2. Publish the complete v1.8.31/build 31 provider payload and signed Pearl
   backend-pair-plus-catalog payload without advertising the provider update.
3. Activate coordinator verification and atomic release activation with
   `autotune.enforce_provider_admission:false` plus an RFC3339
   `autotune.provider_admission_bridge_deadline` no more than 24 hours away;
   verify the startup deadline telemetry and that the catalog-aware canary
   receives authoritative current/previous admission.
4. Raise the coordinator recommendation to v1.8.31, upgrade canary providers,
   then bounded cohorts. Commit each only on exact authoritative buyer-serving
   readiness; automatically restore the complete prior provider release on
   failure.
5. Observe bridge telemetry until `legacy_bridge` remains zero for 15 minutes,
   within the 24-hour bridge deadline. Then set
   `autotune.enforce_provider_admission:true` and restart so all sessions
   re-admit strictly. Roll back if the deadline expires or required
   buyer-serving capacity is lost.
6. Provision and recovery-test the approved v5 signer, add its public key to
   the canonical keyring, then ship v4+v5 bridge clients while continuing v4
   publication.
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
- [ ] Repo-local `tier2-identity-binding.json` matches the current autotune
      release; Pearl deploy pins Tier-2 bytes and `check-tier2-binding` rejects
      overlapping model/hash drift before upload; coordinator refuses
      conflicting Tier-2 on start/reload; `activate-tier2-observe.sh` refuses
      conflicting Tier-2-only plan/apply before SCP (#608 finish interim).
- [ ] Controller loss during a live mutation is serialized behind the remote
      operation barrier; rollback restores the exact prior Tier-2 catalog.
- [ ] Signed Pearl updater and direct deploy contend on
      `/run/lock/macprovider-pearl-updater.lock`; no test can activate a binary
      pair or catalog pointer independently.
- [ ] Bridge starts with `autotune.enforce_provider_admission:false`, rejects
      partial/mismatched metadata, reaches zero `legacy_bridge` continuously
      for 15 minutes before its 24-hour deadline, then restarts with enforcement
      true and proves no legacy buyer-serving capacity.
- [ ] launchd contains no mutable config overrides.
- [ ] Existing config fields survive installer and recommendation.
- [ ] Recommendation uses staged config plus a reserved non-live benchmark
      port; live config is unchanged and weight-loading benchmarks do not begin
      until the old provider stops.
- [ ] Restart failure returns failure and restores binary/resources/config/plist.
- [ ] SIGKILL/reboot-orphaned installer transaction is restored by the recovery
      LaunchAgent before another install proceeds.
- [ ] Every Mac-side mutator acquires `install.lock` before any inner
      `update.lock`; cross-writer, PID-reuse, boot-change, pending-fence, and
      SIGKILL tests leave no mixed release and no deadlock.
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
