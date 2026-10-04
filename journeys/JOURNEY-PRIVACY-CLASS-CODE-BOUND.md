# JOURNEY-PRIVACY-CLASS-CODE-BOUND

Status: draft journey contract; no implementation evidence
Owner: operator-constrained privacy class
Specs: SPEC-049
Requirements: SPEC-049-R024, SPEC-049-R025, SPEC-049-R026, SPEC-049-R027,
SPEC-049-R028, SPEC-049-R029, SPEC-049-R030, SPEC-049-R031, SPEC-049-R032,
SPEC-049-R033, SPEC-049-R034
Authority domains: operator-constrained-privacy-class
Issue: https://github.com/Augustas11/macprovider/issues/1840
Execution mode: provider-privacy-class-code-bound

## Purpose

This journey defines the signed physical evidence required before the SPEC-049
v0.2 `code_bound_attested` assurance label can be served outside an isolated
test coordinator. It proves, on real Apple Silicon hardware running macOS 27 or
later and a signed, notarized Malibu.app release, that the Malibu.app
supervisor's App Attest key enrolls against the pinned Apple App Attestation
Root CA with the required SIP and Full Security aclBlob, that every code-bound
posture carries a verified assertion with a durably increasing counter, that a
re-signed app or re-signed child cannot obtain the label, that a provider
outside the supervisor stays on `device_bound_self_attested_beta`, and that the
buyer sees the exact code-bound disclosure only for work served under that
label.

This document is a test contract. It is not evidence that the journey passed
and does not make any SPEC-049 requirement conformant by itself. The Beta
surface (SPEC-049-R001..SPEC-049-R023) is proven by
`JOURNEY-PRIVACY-CLASS-BETA`; SPEC-049-R023 also requires a signed result of
this journey for the code-bound requirements.

## Out of scope

- Buyer-side verification of the Apple attestation.
- App Attest development environment (`appattestdevelop`), daemons,
  extensions, and the standalone CLI as an attestor.
- App Attest fraud-metric receipt evaluation.
- Trusted Pool or other pool-scoped privacy requests (rejected by SPEC-049-R022).
- Production activation, live-coordinator testing with an unreleased local
  provider or app build, or any change to the production `coordinator.yaml`.

## Required steps

The signed result MUST contain these passing steps:

1. `step-01-bind-signed-app-release` - Record hardware/SoC/RAM, the macOS
   build (27 or later), SIP state, the startup security mode, the Malibu.app
   release tag and `CFBundleVersion`, its team identifier, bundle identifier
   `tech.malibu.app`, notarization and staple status, and the App Attest
   entitlement from the embedded provisioning profile; record the embedded
   `macprovider-cli` cdhash, signing identifier `live.malibu.provider.cli`, and
   hardened-runtime flags from `codesign -dvvv`; record the isolated
   coordinator and gateway commit and config digests with
   `privacy_class.code_bound.enabled: true`, the team pin, and
   `approved_code_identities` populated from that release.
2. `step-02-enroll` - Start Malibu.app with code-bound enabled; capture the
   `privacy_app_attest_enroll_request`, challenge, enrollment, and `enrolled`
   result; prove the coordinator verified the chain to the pinned root
   fingerprint, the nonce extension, keyId, rpIdHash, production aaguid,
   counter 0, credentialId, and the exact aclBlob, and record whether the
   authenticator extensions map was present; prove one `active` row exists in
   `privacy_app_attest_keys` bound to the provider and the pins.
3. `step-03-code-bound-posture` - Prove the provider replaced its privacy key
   records with `code_bound_attested` attestations, that at least three
   consecutive `version: 2` postures verified with strictly increasing,
   durably committed counters, and that the session was granted
   `code_bound_attested`.
4. `step-04-restart-durability` - Restart the coordinator; prove the
   reconnecting provider re-presents its keyId and receives `enrolled` without
   a new attestation, that the first post-restart assertion counter exceeds the
   stored `last_counter`, and that a replayed captured `version: 2` response is
   rejected.
5. `step-05-resigned-app-refused` - Prove an ad-hoc re-signed Malibu.app that
   keeps the App Attest entitlement is refused launch, and that one without the
   entitlement produces an attestation the coordinator rejects with reason
   `app_attest_attestation_invalid` (rpIdHash mismatch) and quarantines; prove
   the quarantine survives a coordinator restart, then unquarantine.
6. `step-06-resigned-child-refused` - Replace the supervised child with an
   ad-hoc re-signed binary that keeps the signing identifier; prove the
   supervisor's check fails, no attestation or assertion is produced, the child
   is terminated and not respawned in privacy mode, and the provider loses
   eligibility.
7. `step-07-standalone-cli-stays-beta` - Run the standalone `macprovider-cli`
   in privacy mode; prove it sends no enrollment request, serves only under
   `device_bound_self_attested_beta`, and that a reservation with
   `X-MacProvider-Privacy-Assurance-Required: code_bound_attested` returns
   `privacy_class_unavailable` while it is the only eligible provider.
8. `step-08-canary-stream-code-bound` - Run the reference client with
   `--privacy-class --privacy-assurance-required code_bound_attested` in stream
   mode with the canary prompt; prove the reservation, key attestation, and
   `X-MacProvider-Privacy-Assurance` all carry `code_bound_attested`, every
   frame decrypts and verifies, and `usage.macprovider.privacy` and the client
   stderr carry the exact code-bound SPEC-049-R020 strings.
9. `step-09-canary-nonstream-code-bound` - Repeat step 8 in non-stream mode.
10. `step-10-label-change-negatives` - Prove an invalid
    `X-MacProvider-Privacy-Assurance-Required` value returns
    `privacy_class_downgrade_rejected` before quota; prove that revoking the
    App Attest key between consume and dispatch burns the reservation, refunds
    held quota, and returns `privacy_class_posture_stale` with no dispatch.
11. `step-11-key-loss-and-revocation` - Remove the supervisor's App Attest key;
    prove a new key enrolls, the previous one is revoked as `superseded`, and
    its keyId is refused afterwards; run `coordinator-cli privacy-class
    revoke-app-attest-key`; prove the live session receives
    `reenroll_required`, loses the code-bound label, and re-enrolls.
12. `step-12-reduced-security-refused` - Documented negative on a dedicated lab
    Mac with SIP disabled or Reduced Security: prove enrollment is rejected
    with `app_attest_acl_mismatch` or the app cannot attest. The lab host
    identity and security state are recorded; this host never joins a live
    coordinator.
13. `step-13-redaction-sweep` - Grep Malibu.app, provider, coordinator, and
    gateway logs, SQLite stores, the provider state directory, the Malibu.app
    container, temporary directories, and crash-report directories for both
    canaries and the buyer key; prove zero matches and that the supervisor
    channel capture contains no request or response plaintext.
14. `step-14-redaction-review` - Review every captured artifact for prompts,
    completions, key material, credentials, payout material, private paths,
    and unbounded diagnostics before signing.

## Required evidence contract

The reviewed redacted evidence manifest MUST be committed under:

```text
journeys/evidence/privacy-class-code-bound-*.redacted.json
```

It MUST be the exact closed object below; unknown/missing/duplicate keys or
wrong types fail before signing:

```json
{
  "schema_version": "macprovider.privacy-class-code-bound-evidence.v1",
  "journey_id": "JOURNEY-PRIVACY-CLASS-CODE-BOUND",
  "requirement_ids": ["<sorted unique exact IDs from this journey>"],
  "captured_at": "<RFC3339 UTC seconds>",
  "expires_at": "<RFC3339 UTC seconds, <= captured_at + 90 days>",
  "macos_build": "<macOS build, 27 or later>",
  "app_release_tag": "<signed Malibu.app release tag>",
  "app_bundle_version": "<Malibu.app CFBundleVersion>",
  "app_binary_sha256": "<lowercase sha256 of the Malibu.app main executable>",
  "team_id": "<Apple team identifier>",
  "bundle_id": "tech.malibu.app",
  "child_code_cdhash": "<40 lowercase hex>",
  "child_signing_identifier": "live.malibu.provider.cli",
  "app_attest_key_id_sha256": "<lowercase sha256 of the enrolled keyId>",
  "apple_root_sha256": "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932",
  "steps": [{"step_id":"step-01-bind-signed-app-release","status":"pass","artifact_sha256":"<lowercase sha256>"}],
  "observations": {"<every closed boolean named below>": true},
  "redaction_manifest_sha256": "<lowercase sha256>"
}
```

`steps` contains each step above exactly once in numeric order and no other
id; every status is `pass`. Every referenced artifact is an immutable canonical
file in the reviewed bundle; paths and URLs are not evidence identities. A
schema validator and signer test MUST enforce the closed field set and
recompute every digest and boolean from referenced artifacts; self-asserted
booleans are insufficient. `captured_at` and `expires_at` MUST be present, and
expiry MUST be no more than 90 days after capture.

## Required observations

The redacted evidence and signed result MUST set these booleans to `true`:

- `attestation_chain_to_pinned_apple_root_verified`
- `acl_blob_sip_full_security_exact_verified`
- `production_aaguid_and_zero_counter_verified`
- `key_bound_to_provider_and_pins_verified`
- `code_bound_posture_assertions_verified`
- `assertion_counter_strictly_increasing_and_durable_verified`
- `enrollment_survives_coordinator_restart_verified`
- `resigned_app_refused_verified`
- `resigned_child_refused_by_supervisor_verified`
- `standalone_cli_stays_beta_verified`
- `assurance_required_header_enforced_verified`
- `code_bound_disclosure_strings_exact_verified`
- `stream_frames_decrypted_and_verified`
- `nonstream_frames_decrypted_and_verified`
- `label_change_after_consume_burns_reservation_verified`
- `key_loss_reenrollment_verified`
- `operator_revocation_reenroll_required_verified`
- `reduced_security_host_refused_verified`
- `canary_absent_from_all_artifacts_verified`

They MUST set these booleans to `false`:

- `plaintext_observed_at_relay`
- `plaintext_on_supervisor_channel`
- `code_bound_label_without_verified_assertion`
- `revoked_key_reactivated`
- `silent_downgrade_observed`
- `unreleased_local_build_connected_to_live_coordinator`
- `secret_or_canary_persisted`

The `observations` object contains exactly the booleans listed in this section.

## Completion

The journey is complete only when every required step passes, the signed result
names every SPEC-049 requirement mapped to this journey (and no unmapped
requirement), every evidence digest resolves, and the evidence has not expired.
The staged canary and three-lane review remain SPEC-049-R023 inputs outside
this evidence object.
