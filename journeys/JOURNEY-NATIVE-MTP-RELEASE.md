# JOURNEY-NATIVE-MTP-RELEASE

Status: draft journey contract; no implementation evidence
Owner: SPEC-048 release enablement
Specs: SPEC-048
Requirements: SPEC-048-R014
Authority domains: native-mtp-serving
Issue: https://github.com/Augustas11/macprovider/issues/1770
Execution mode: provider-native-mtp-release

## Purpose

This journey is the acyclic post-build evidence for SPEC-048-R014. It runs only
after the implementation/evidence diff and serving journey are frozen, reviewed,
merged, finally signed, and packaged. It does not regenerate or self-hash the
pre-release sidecar or serving-journey evidence.

## Required steps

For one exact tuple and release candidate, the signed result MUST prove:

1. `step-01-preconditions` — SPEC-048-R001..R013/R015/R016 and the supporting
   requirements named by R014 are conformant, and the exact tuple has current
   signed sidecar plus `JOURNEY-NATIVE-MTP-SERVING` evidence.
2. `step-02-review-verdicts` — the frozen implementation/evidence diff has
   independent code, security, and architecture verdict artifacts, each with
   zero Critical, High, or Medium findings and the identical base/head/tree,
   binary-diff digest, and reviewed-path-set digest.
3. `step-03-final-binary-binding` — record release id, tag, source commit,
   reproducible-build digest, signing identity, notarization/stapling result,
   provider/MLX revisions, and canonical
   `native_mtp_admission_tuple_sha256`.
4. `step-04-isolated-loopback` — run the exact final signed candidate in
   isolated/no-join loopback; pass the local native-MTP self-test, token/state
   oracle smoke, and sidecar tuple binding without contacting the live Malibu
   coordinator.
5. `step-05-release-assets` — where both Malibu.app and standalone tarball ship,
   prove SHA-256 byte identity of their embedded final `macprovider-cli` and
   pass the previous-stable updater path.
6. `step-06-production-config` — prove the production configuration references
   only this admitted tuple, rejects an altered tuple/expired result, and has no
   unreleased-local-to-live binary pairing.
7. `step-07-redaction` — verify the evidence contains no credential, payout
   material, model weight/tensor value, raw private prompt/output, or private
   local path.

## Evidence contract

The committed redacted manifest path is
`journeys/evidence/native-mtp-release-*.redacted.json`. It is the exact closed
object `{schema_version, journey_id, requirement_ids,
native_mtp_admission_tuple_sha256, release_id, base_commit, head_commit,
head_tree_oid, production_repository, production_ref, target_commit,
target_ref_attestation_sha256, diff_sha256, reviewed_paths_sha256, dirty, source_commit,
build_sha256, serving_journey_result_sha256, sidecar_sha256,
code_review_sha256, security_review_sha256, architecture_review_sha256, steps,
captured_at, expires_at, redaction_manifest_sha256}`. `schema_version` is
`macprovider.native-mtp-release-evidence.v1`; `journey_id` and
`requirement_ids` are exactly this journey and `["SPEC-048-R014"]`; every
SHA-256 digest is lowercase 64-hex; `base_commit`, `head_commit`,
`head_tree_oid`, `target_commit`, and `source_commit` are full lowercase Git object ids matching
the repository object format and are exactly 40 or 64 hex characters;
`source_commit == head_commit`; `dirty` is exactly `false`; timestamps are
RFC3339 UTC seconds and expiry is no later than 30 days after capture; and
`steps` contains the seven ordered exact ids above as closed
`{step_id,status,artifact_sha256}` objects with `status="pass"`. Unknown,
missing, duplicate, out-of-order, or wrong-typed fields fail before signing.

The review subject is the complete frozen implementation plus serving-evidence
change, excluding only the subsequently generated
`native-mtp-release-*.redacted.json`, its detached signature, and the three
review-verdict artifacts whose hashes that manifest carries. `head_commit` is
the final candidate source/evidence commit. `production_repository` is exactly
`Augustas11/macprovider`, `production_ref` is exactly `refs/heads/main`, and
`target_commit` is the protected ref tip captured immediately before the
campaign review freeze through the authenticated hosting API.
`target_ref_attestation_sha256` identifies the immutable canonical API response
plus repository/ref query and authenticated principal. The signer MUST fetch
and authenticate that evidence independently; a caller-supplied ref resolution
is insufficient. `base_commit` MUST equal both `target_commit` and
`git merge-base(target_commit,head_commit)`, MUST be a strict ancestor of
`head_commit`, and the review subject MUST be nonempty. If protected main moves
before merge, the candidate is rebased on the new tip and all three audits
rerun. The
review-subject path list is exactly every path changed between those commits
minus only the named exclusions; callers cannot submit a narrower list. With `LC_ALL=C`,
`reviewed_paths_sha256` is SHA-256 of the UTF-8 repository-relative
review-subject paths sorted bytewise, each followed by one LF.
`diff_sha256` is SHA-256 of the exact stdout bytes from
`git diff --binary --full-index --no-ext-diff --no-textconv <base_commit> <head_commit> --
<those paths in the same bytewise order>`, with textconv and external diff
disabled. `head_tree_oid` MUST equal the tree object referenced by
`head_commit`, and the signer MUST recompute the path set, tree, and diff
digests from the repository rather than trust submitted values.

Each of `code_review_sha256`, `security_review_sha256`, and
`architecture_review_sha256` identifies one immutable canonical closed review
artifact with schema `macprovider.native-mtp-review-verdict.v1` and exact fields
`{schema_version,lane,reviewer_id,tool_version,production_repository,
production_ref,target_commit,target_ref_attestation_sha256,base_commit,head_commit,
head_tree_oid,diff_sha256,reviewed_paths_sha256,captured_at,critical,high,
medium,low,info,verdict}`. `lane` is respectively `code`, `security`, or
`architecture`; finding counts are unsigned integers; `verdict` is `approved`;
and `critical`, `high`, and `medium` are zero. The three artifacts MUST bind the
same values recorded in the release manifest. After the first review artifact
is produced, any mutation to a reviewed path invalidates all three verdicts and
requires every lane to rerun. The release-evidence generator may then write
only the excluded manifest, signatures, and verdict artifacts; any other dirty
path or any index/worktree difference at signing fails closed.

The signed generic journey result MUST name only SPEC-048-R014 and bind this
manifest digest. Only this result may promote R014 to conformant. Expiry or a
release/tuple/build mismatch disables native MTP while preserving ordinary
decode.
