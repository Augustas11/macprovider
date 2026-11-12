# Native MTP production enablement

This runbook takes one qualified native-MTP tuple from a merged campaign to live
serving. It covers the one CLI cut, the one Pearl runtime apply, the one catalog
release, the revocation feed, the coordinator canary, and turning the tuple on
for one provider. Read `docs/runbooks/pearl-coordinator-rollout.md` before any
Pearl step, and state the expected downtime to the operator before you start it.

Scope: SPEC-048 (R014 release gate), SPEC-023 §12.5 (admission sidecar and
revocations), SPEC-031-R033 (native canary). The R014 enablement plan is in
the private engineering archive; the evidence code reads stays under
`docs/research/spec048-r014/` and `docs/research/spec048-r015/`.

## Preconditions

- The campaign implementation ships enabled after the full lab campaign passed;
  eligibility still requires its qualified signed deployment profile, and
  its freeze audit over the full diff had 0 Critical, 0 High and 0 Medium
  findings.
- The corrected continuous-batching policy entry for the tuple exists. It is an
  external input to this campaign.
- No unreleased local binary is joined to the live coordinator (SPEC-048 R014
  item 9).

## Optional representative request-shape observations

These observations are optional and do not gate the campaign R005/formal
R015 qualification. The existing v1 collector remains off-only. To observe an already-serving
qualified tuple without changing its actual `off`/`auto` mode, explicitly select
`MACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_SCHEMA=v2` with the existing capture-directory
opt-in and bounded record/byte limits. A mode change starts a new capture file.
The old signed GLM greedy profile keeps its plain-text scope on the new binary;
expanded tools/history/reasoning and sampling require the signed sampled profile.
Observation neither broadens admission nor activates an unqualified tuple.

Before collection, durably preregister the persistable population, period,
limits, omission accounting and modeled replay schedule. Review the exact
sanitized capture/status bytes for privacy before projection. Preserve observed
selection/path separately from candidate pre-capacity shape eligibility and
fresh measured admission. Unknown or unreproducible controls leave qualification
pending; do not drop their request/token weight or collect nonpersistable data.

Use the matching v2 projection/replay with exact capture, tuple-bounds and policy
bindings, including the existing bench-policy bytes. Execute fresh ordinary and
mixed paired loads across the full qualified CB slots with the same frozen
wave-index-times-`arrival_interval_ms` stagger and cache-conflict ordering.
Capture completion order is not an observed arrival schedule. Count ordinary
rows toward the signed native cap; do not split waves by native eligibility.
An observation is not an ordinary control, and offline projection remains
`PENDING_REAL_LAB_REPLAY`. SPEC-048 R015's existing representative, mixed-load
and promotion gates still apply.

## After a CLI cut

A CLI's binary SHA-256, CDHash and decode-path digest are provenance only
(SPEC-048 0.1.81, #2282), so a CLI cut needs no rebind, no binding bundle and
no matched binary/policy transaction. A new or changed admission goes live
through ordinary catalog activation:

```bash
scripts/ops/catalog-activate.sh status
scripts/ops/catalog-activate.sh next
scripts/ops/catalog-activate.sh next --run
```

The signed binary/policy pair transaction, the binding-bundle activation
context and the provider `cached_turns` config step existed only for CLIs that
predate #2282 and were removed from `catalog-activate.sh` (#2302). The gateway
proof is still a real attributed buyer request with unchanged accounting and
settlement.

## Order

Each step depends on the one before it. This order is for the first
native-MTP enablement on a coordinator. The sidecar records a CLI's identity
and decode-path digest as provenance only (SPEC-048 0.1.81): neither gates
admission, so a later tuple or a later CLI cut never waits on the other.
SPEC-048-R014 is promoted only by the signed release journey, so no production
config load may make the tuple selectable before that promotion.

1. **CLI cut.** Cut and publish one signed CLI. Publish its release-discovery
   transport before checking the updater path from the previous stable.
2. **Safe final-shape capture, MTP off.** If final serving/replay evidence needs
   the reviewed signed CLI or reviewed coordinator route code in place, deploy
   only that safe shape with native-MTP still unavailable for selection: set
   provider `native_mtp_mode: off` explicitly (the default is `auto`), leave
   the admission feed paths unset or pointed at a non-selectable staging
   location, and do not load a production config that can advertise the tuple. This stage may prove isolated loopback,
   final binary behavior, and route shape; it is not activation.
3. **Release input.** (First admission of a tuple. A later CLI cut skips
   steps 3 to 7.) Read the published tarball's code identity:
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
4. **Final serving confirmation.** Run JOURNEY-NATIVE-MTP-SERVING on the final
   signed candidate with the release-bound sidecar from step 3, then sign and
   promote it on main (`promote-signed-native-mtp-serving-journey.yml`). This is
   the post-cut confirmation that the actual release tuple, source commit,
   provider revision, CDHash, R015 policy and revocation behavior were tested.
   It is required before any network native-MTP enablement.
5. **Revocation slots.** Publish them before the catalog release, so the
   release smoke finds a current slot:
   `scripts/publish-native-mtp-revocations.sh --deploy`. This signs 14 days of
   10-minute slots with the static-feed key, off-host, and retargets
   `/opt/macprovider/native-mtp-revocations/current`.
6. **Catalog release.** Generate, sign and verify the release:
   `catalog-release.py generate`, then `resign-autotune-static.sh`, then
   `verify`. The release binds `native-mtp-admission.json` as its seventh feed
   (ledger v4).
7. **Release journey.** Run JOURNEY-NATIVE-MTP-RELEASE on the final signed
   candidate and sign it (`promote-signed-native-mtp-release-journey.yml`).
   Only that result promotes SPEC-048-R014. Wait until R014 is promoted
   conformant before the first production config load that can make the tuple
   selectable.

   The signed serving and release journey payloads bind `--source-sha` to the
   final sidecar or release source, not merely to any ancestor of the evidence
   commit. For JOURNEY-NATIVE-MTP-SERVING, `--source-sha` must equal the
   selected `native-mtp-admission.json` entry's `source_commit`, and the entry's
   `provider_revision` must match that source. For JOURNEY-NATIVE-MTP-RELEASE,
   `--source-sha` must equal the release evidence `source_commit`. If the tested
   premerge SHA is not the final post-squash source, rerun or reconfirm the
   candidate evidence and regenerate the sidecar/release evidence on the final
   source. Do not retarget honest pre-squash evidence to a squash commit.
8. **Pearl runtime apply and production config load.** After R014 is conformant,
   ship the coordinator routes `/v1/native-mtp-*` if they are not already
   present, then load the production config that makes the tuple selectable. The
   route apply is about 1-2 minutes of coordinator/gateway restart with the
   installed short-quiesce updater. State that to the operator first. If the coordinator code is
   unchanged since the safe MTP-off deploy, skip the code apply and only perform
   the config load. Then:
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
9. **Turn the tuple on for the provider.** Install the cut on the Studio. This
   restarts `live.malibu.provider` and needs operator approval. The mode
   defaults to `auto` (SPEC-048 0.1.75), so no config change is needed unless
   the provider config sets `native_mtp_mode: off`; remove that line. The
   provider fetches the admission set into
   `~/Library/Application Support/macprovider/native-mtp-admission/` and runs
   the local self-test. `GET /v1/status` must show `native_mtp.enabled=true`
   and `mode` of `eligible` or `active`.

## Later CLI cuts: no admission step

From SPEC-048 0.1.81 native-MTP admission is keyed by model and artifact. The
decode-path digest, metallib, runtime revision, CLI version and CDHash in an
entry are provenance. The CB policy never bound the CLI either: its CLI
version and CDHash are provenance (SPEC-023 v0.22.13). So a CLI cut needs no
rebind of the CB policy or of native-MTP admission, and no requalification for
identity alone.

What decides serving on each Mac is the MTP-16 on-device self-check, which
runs at every model load, and the coordinator's R033 canary. A failing
self-check serves ordinary decode for that load. A provider whose build differs
from an entry's recorded digest logs
`event=native_mtp_admission decode_path=provenance_differs` and still runs the
self-check.

`scripts/ops/cli-release.sh status` reports fact
`native_mtp_admission_decode_path` (`match`, `legacy` or `mismatch`) as
provenance; it never gates the cut. Requalify only when a changed decode-path
line alters how the tuple drafts, verifies or commits tokens (AGENTS.md rule
2). To read the digest a signed binary embeds, run
`python3 scripts/decode_path_digest.py --binary <macprovider-cli>`; a running
provider reports it as `/v1/status` `build_identity.decode_path_digest`.

CLIs before 0.1.51 (1.8.258-1.8.260) reject unknown entry keys. The sidecar
generator therefore still requires the release input's
`provider_decode_path_digest` when an entry carries `decode_path_digest`: its
presence shows the bound CLI parses the field (SPEC-048-R014 item 10). The two
digests need not be equal.

Before any fresh native-bound activation step, `catalog-activate.sh status`
reports `native_mtp_release_match_gate` and the `native_mtp_release_match`
step. The verifier checks the bound signed release payload and compatibility
manifest, verifies the admission signature against that release's trusted
keyring, and checks that every entry has well-formed scope fields and selects a
unique runtime context. Admission scope packaged inside a CLI release and the
release's runtime identity do not gate activation, so a new tuple's admission
goes live by catalog activation without a CLI cut. A failure names its field
and blocks `next --run`. Interrupted-operation recovery remains available.

## Activating a later native-bound release

Once the keys above are in `coordinator.yaml`, a new native-bound catalog
release goes live through `scripts/ops/catalog-activate.sh` with one SIGHUP
and no coordinator restart (SPEC-031-R033 v0.3.9):

- The SIGHUP reload verifies the release's served self-test bank under the
  `pool.native_mtp_canary` keys and installs it as the canary bank before the
  release and its feeds go live. If the canary cannot verify the bank, the
  reload refuses the whole release and the prior release, feeds and bank stay
  live. The coordinator journal then says `autotune feed reload rejected;
  keeping prior catalog, served feeds and native MTP canary bank`.
- The canary keeps the bank it replaced. A provider still on the previous
  release is admitted with that bank while that release is retained as
  compatible-previous.
- Step 7 `canary_bank` reads `/healthz`. `native_mtp_canary_bank_reloads:
  true` with `native_mtp_canary_bank_release_id` equal to the release and
  `native_mtp_canary_bank_sha256` equal to the SHA-256 of the served
  `/v1/native-mtp-selftest-bank` bytes means done; a release id match alone
  does not. A coordinator built before this change does not report the field.
  For one of those, step 7 is the restart that loads the bank, and the
  activation is not done until the restart runs.
- A provider whose offer was rejected with `bank_mismatch` (for example
  against a coordinator built before this change) does not need a model
  reload. It offers its tuple again on its next coordinator session, or once
  the coordinator serves the bank it qualified on (SPEC-048-R016 v0.1.48).
  `event=native_mtp_tuple_offer action=parked` and `action=restored` in the
  provider log show this.

## Adding a second model to the admission set

A sidecar with two or more model entries uses the v2 projection manifest
(`macprovider.native-mtp-artifact-projection.v2`, keyed by `model_key`). A
GLM-5.3-Flash entry also carries 5- and 6-bit overrides and more than 256
exceptions (SPEC-023 v0.22.27). A CLI older than the one that reads these
rejects the whole admission set, and every native-MTP tuple on it falls back to
ordinary decode, Qwen included. SPEC-048-R014 item 10 therefore fixes the order:

1. **CLI cut with the readers.** The campaign CLI cut ships the v2 projection
   reader, the embedded `checkpoint_mtp` observer, and the wider R024 bounds.
   Until step 2 holds, keep publishing the single-model admission set: one
   tuple input, the v1 projection, the existing Qwen entry unchanged.
2. **That CLI is the released one.** Publish it, then wait until it is the
   released CLI (the published stable, with the updater path from the previous
   stable confirmed). Do not publish the multi-model set before this.
3. **Multi-model catalog release.** Commit the tuple file as a JSON array of
   tuple inputs (Qwen and GLM), and render the projection with
   `python3 scripts/native_mtp_admission_sidecar.py projection --models
   <models.json> --out phase3-binary/catalog/autotune/native-mtp-artifact-manifest.json`,
   where `models.json` maps each `model_key` to its
   `{target, mtp, tokenizer, manifest}` artifacts. The GLM `mtp` member is the
   target directory and its `manifest` is the target's `config.json`. Set the
   release input's `artifact_manifest_sha256` to the new manifest's SHA-256
   and continue at step 4 of the order above. All entries share the
   release-owned provenance of that one CLI (SPEC-048-R013).

The Qwen entry's bytes are unchanged by the merge. Its
`native_mtp_admission_tuple_sha256` still changes, because the identity covers
the whole sidecar.

## Same-architecture variant

SPEC-048 0.1.78 (MTP-13). A variant of an admitted, unrevoked tuple inherits
R005, the gated cells and the sustained phase when every row holds:

| Check | Variant against donor |
| --- | --- |
| Equal | `mtp_family_adapter`, `quantization.kind`, `decode_path_digest`, `metallib_sha256`, `hardware_class`, `proposal_depth`, `mtp_head_count`, `decrease_threshold_ppm`, `increase_threshold_ppm` |
| At most the donor's | `qualified_slots`, `max_native_active_rows`, `max_prompt_tokens` |
| Measured on the variant | R012 fit evidence; a self-test bank entry; the native-eligible R015 cells at every slot count from 1 up to its own `max_native_active_rows` (1 unless it measures more), under a frozen policy with the donor's thresholds. For a GLM-5.3-Flash donor (cap 4096, bound 1): `s1-p1536-o128`, `s1-p1536-o512`, `s1-p4096-o128`, `s1-p4096-o512` (`docs/research/spec048-r015/glm53-flash-r015-v2/policy.json`) |
| Each measured cell | exact token parity in every run; passes the donor's R015 native-eligible improvement gate |
| Inherited from the donor | R005, the gated cells (GLM-5.3-Flash: `s2-p1536-o512`, `s4-p1536-o512`) and the sustained phase |

Name the donor's `model_key` and the donor evidence inherited in the variant's
evidence README. Adding the entry then follows "Adding a second model" above.

## Renewal and revocation slots

The admission sidecar and self-test bank no longer expire on the provider
(SPEC-023 v0.22.20), so there is no scheduled re-sign. An on-demand restamp
(`scripts/renew-autotune-static-feed.sh`) still re-binds the sidecar to a new
release ID: `restamp` rewrites the release input's `release_id` and its 89-day
window, and `continuity-check` accepts exactly that change. Run one before the
live admission's `expires_at` only if CLIs older than SPEC-023 v0.22.20 still
serve native MTP then.

Revocation slots are published on demand
(`scripts/publish-native-mtp-revocations.sh --deploy`). Providers keep
enforcing the newest verified revoked set they hold after the batch ages out,
and the coordinator keeps serving the newest issued slot (SPEC-023 v0.22.23),
so a missed publish never turns native MTP off.

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
