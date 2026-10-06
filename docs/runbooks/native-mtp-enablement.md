# Native MTP production enablement

This runbook takes one qualified native-MTP tuple from a merged campaign to live
serving. It covers the one CLI cut, the one Pearl runtime apply, the one catalog
release, the revocation feed, the coordinator canary, and turning the tuple on
for one provider. Read `docs/runbooks/pearl-coordinator-rollout.md` before any
Pearl step, and state the expected downtime to the operator before you start it.

Scope: SPEC-048 (R014 release gate), SPEC-023 §12.5 (admission sidecar and
revocations), SPEC-031-R033 (native canary). Plan and evidence:
`docs/research/spec048-r014/enablement-plan.md`.

## Preconditions

- The campaign PR is merged, and its freeze audit had 0 Critical, 0 High and
  0 Medium findings.
- The signed JOURNEY-NATIVE-MTP-SERVING result for the tuple is committed and
  promoted (`promote-signed-native-mtp-serving-journey.yml`).
- The corrected continuous-batching policy entry for the tuple exists. It is an
  external input to this campaign.
- No unreleased local binary is joined to the live coordinator (SPEC-048 R014
  item 9).

## Order

Each step depends on the one before it. The CB policy entry and the admission
sidecar both bind the final CLI's CDHash, so the catalog release always comes
after the cut.

1. **CLI cut.** Cut and publish one signed CLI. Publish its release-discovery
   transport before checking the updater path from the previous stable.
2. **Release input.** Read the published tarball's code identity:
   `scripts/provider-code-identity.py --tarball <tar> --binary-version <v>`.
   Fill `phase3-binary/catalog/autotune/native-mtp-admission-release.json`:
   - `release_id` is the catalog release you are about to cut;
   - `source_commit` and `provider_revision` are the tag's commit;
   - `reproducible_build_sha256` is the binary SHA-256;
   - `live_executable_cdhash` is the CDHash;
   - `artifact_manifest_sha256` and `challenge_bank_sha256` are the SHA-256 of
     the committed `native-mtp-artifact-manifest.json` and
     `native-mtp-selftest-bank.json`.

   The tuple input `native-mtp-admission-tuple.json` carries the qualified
   tuple and its evidence digests. It may not contain the all-zero
   placeholders.
3. **Pearl runtime apply.** This ships the coordinator routes
   `/v1/native-mtp-*`, and is a 15-20 minute outage unless the short-quiesce
   updater is installed. State that to the operator first. If the coordinator
   code is unchanged since the last apply, skip this step.
4. **Revocation slots.** Publish them before the catalog release, so the
   release smoke finds a current slot:
   `scripts/publish-native-mtp-revocations.sh --deploy`. This signs 14 days of
   10-minute slots with the static-feed key, off-host, and retargets
   `/opt/macprovider/native-mtp-revocations/current`.
5. **Catalog release.** Generate, sign and verify the release:
   `catalog-release.py generate`, then `resign-autotune-static.sh`, then
   `verify`. The release binds `native-mtp-admission.json` as its seventh feed
   (ledger v4). Then:
   - add the nginx `location` blocks from
     `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`
     (`/v1/native-mtp-*`);
   - edit `coordinator.yaml` in place, under both locks, adding only these keys
     under `autotune:`:

     ```yaml
       native_mtp_admission_path: /opt/macprovider/autotune/current/native-mtp-admission.json
       native_mtp_admission_sig_path: /opt/macprovider/autotune/current/native-mtp-admission.json.sig
       native_mtp_artifact_manifest_path: /opt/macprovider/autotune/current/native-mtp-artifact-manifest.json
       native_mtp_selftest_bank_path: /opt/macprovider/autotune/current/native-mtp-selftest-bank.json
       native_mtp_selftest_bank_sig_path: /opt/macprovider/autotune/current/native-mtp-selftest-bank.json.sig
       native_mtp_revocations_dir: /opt/macprovider/native-mtp-revocations/current
     ```

   - add the coordinator canary under `pool:`. The bank is the same bytes the
     sidecar pins:

     ```yaml
       native_mtp_canary:
         enabled: true
         challenge_bank_path: /opt/macprovider/autotune/current/native-mtp-selftest-bank.json
         signature_path: /opt/macprovider/autotune/current/native-mtp-selftest-bank.json.sig
         signer_key_id: streamvc-autotune-static-v4
         public_keys:
           streamvc-autotune-static-v4: zTKDIdMmKKkO1Cgf5OdTzMOytVqW7U8SGsJ9XrzAltU=
         interval_s: 3600
     ```

   - activate with `deploy-pearl-vps.sh` from the running tag. It is a restart
     of a few seconds. The deploy refuses a release whose six `native_mtp_*`
     keys don't match its binding, and its smoke checks every served member and
     a current revocation slot.
6. **Turn the tuple on for the provider.** Install the cut on the Studio. This
   restarts `live.malibu.provider` and needs operator approval. Then set
   `native_mtp_mode: auto`. The provider fetches the admission set into
   `~/Library/Application Support/macprovider/native-mtp-admission/` and runs
   the local self-test. `GET /v1/status` must show `native_mtp.enabled=true`
   and `mode` of `eligible` or `active`.
7. **Release journey.** Run JOURNEY-NATIVE-MTP-RELEASE on the final signed
   candidate and sign it (`promote-signed-native-mtp-release-journey.yml`).
   Only that result promotes SPEC-048-R014.

## Weekly renewal

`renew-autotune-static-feed-signed.yml` re-binds the sidecar to each new release
ID: `restamp` rewrites the release input's `release_id` and its 89-day window,
and `continuity-check` accepts exactly that change. It also republishes 14 days
of revocation slots. If a renewal is missed, the previous batch still covers at
least one more week.

## Emergency revocation

1. Append the tuple's `native_mtp_admission_tuple_sha256` to
   `phase3-binary/catalog/autotune/native-mtp-revocations-source.json`. The
   list must stay bytewise sorted.
2. From the operator Mac, run
   `scripts/publish-native-mtp-revocations.sh --deploy`. The new batch starts
   one second after now, so every generation exceeds the slot being served.
3. Providers disable the tuple within one 15-minute poll and keep serving
   ordinary decode. Commit the source change afterwards.

A revocation is permanent. Restoring a tuple needs a new release and sidecar.

## Turning it off

- **One provider:** set `native_mtp_mode: off` and restart it.
- **Every provider, at once:** run an emergency revocation.
- **Coordinator canary only:** set `pool.native_mtp_canary.enabled: false`.

None of these touch ordinary decode.
