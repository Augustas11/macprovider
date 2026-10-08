# JOURNEY-PRIVACY-CLASS-BETA

Status: draft journey contract; no implementation evidence
Owner: operator-constrained privacy class
Specs: SPEC-049, SPEC-022, SPEC-015, SPEC-001
Requirements: SPEC-022-R014, SPEC-015-R007, SPEC-001-R005, SPEC-049-R001, SPEC-049-R002, SPEC-049-R003, SPEC-049-R004,
SPEC-049-R005, SPEC-049-R006, SPEC-049-R007, SPEC-049-R008, SPEC-049-R009,
SPEC-049-R010, SPEC-049-R011, SPEC-049-R012, SPEC-049-R013, SPEC-049-R014,
SPEC-049-R015, SPEC-049-R016, SPEC-049-R017, SPEC-049-R018, SPEC-049-R019,
SPEC-049-R020, SPEC-049-R021, SPEC-049-R022, SPEC-049-R023
Authority domains: operator-constrained-privacy-class,
verified-model-settlement, inference-receipts, provider-wire-protocol
Issue: https://github.com/Augustas11/macprovider/issues/1749 (settlement lane:
https://github.com/Augustas11/macprovider/issues/1851)
Execution mode: provider-privacy-class-beta

## Purpose

This journey defines the signed physical evidence required before the SPEC-049
operator-constrained privacy class can leave `draft`. It proves, on real Apple
Silicon hardware running a signed and notarized release, that privacy mode
hardens the provider runtime before network, refuses debugger attach, core
dumps, diagnostic environments, unsigned builds, and SIP-off hosts, that the
coordinator gate admits only freshly verified posture, that request and response
content stay opaque to relays, and that quarantine and the kill switch fail
closed.

This document is a test contract. It is not evidence that the journey passed
and does not make any SPEC-049 requirement conformant by itself.
This original v1 contract covers the v0.1 requirement set only. The v0.2
automatic-enrollment profile is `JOURNEY-PRIVACY-CLASS-BETA-V2`, which reruns
this full baseline and then adds SPEC-049-R024 through SPEC-049-R028 evidence.
SPEC-049-R023 is mapped here because a signed result of this journey is one of
its required inputs; a signed result MUST NOT promote SPEC-049-R023 on its own,
because that requirement also needs a recorded staged canary and three-lane
audits outside this evidence object. SPEC-022-R014, SPEC-015-R007, and
SPEC-001-R005 are mapped here for their privacy-class leg (steps 9, 13, 14,
and 15). A signed result MUST NOT promote them on its own, because they also
cover plain relay-blind work outside this journey, so the signed result does
not name them; the result's step artifacts are inputs to their later
promotion.

## Out of scope

- Code-bound attestation, a Malibu.app-embedded provider, or any assurance
  label other than `device_bound_self_attested_beta`.
- MDA SIP/SecureBoot OID evaluation.
- Trusted Pool or other pool-scoped privacy requests (rejected by SPEC-049-R022).
- `responses` and `messages` endpoint families.
- Production activation, live-coordinator testing with an unreleased local
  provider binary, or any change to the production `coordinator.yaml`.

## Required steps

The signed result MUST contain these passing steps:

1. `step-01-bind-signed-release` — Record hardware/SoC/RAM, macOS build, SIP
   state, provider `binaryVersion`, release tag, and the release binary's
   cdhash, team identifier, and signing identifier from `codesign -dvvv`; prove
   the binary is notarized, hardened-runtime, and lacks the refused
   entitlements; record the isolated coordinator and gateway commit and config
   digests with `approved_code_identities` populated from that release.
2. `step-02-privacy-mode-start` — Start `macprovider-cli serve
   --privacy-class-beta --relay-blind-enabled` from the signed release; prove
   the hardening sequence completed before any network connection, the privacy
   X25519 key exists only in memory (no key file under the state directory),
   `privacy_key_records` are advertised with valid attestations, and the
   coordinator verifies a posture within one challenge interval.
3. `step-03-debugger-attach-refused` — Attempt `lldb -p` and `dtrace` pid
   attach against the running privacy-mode process; prove both fail and the
   provider stays eligible only while P_TRACED and CS_DEBUGGED stay clear.
4. `step-04-core-dump-and-env-refused` — Prove RLIMIT_CORE is 0 for the
   process; prove startup with each refused `MACPROVIDER_*` diagnostic
   environment variable, the KV disk tier enabled, a loopback runtime, or
   relay-blind disabled exits non-zero before network with a bounded reason
   code. Prove `DYLD_*` variables are inert on the signed binary: with
   `DYLD_INSERT_LIBRARIES` and `DYLD_PRINT_LIBRARIES` set, no injected library
   loads and dyld emits no output (SPEC-049-R007 item 7).
5. `step-05-unsigned-build-refused` — Prove a locally built debug or ad-hoc
   signed binary, and a re-signed release binary, exit non-zero in privacy mode
   before network.
6. `step-06-sip-off-refused` — Documented negative on a dedicated lab Mac with
   SIP disabled: privacy mode exits non-zero before network. The lab host
   identity and SIP state are recorded; this host never joins a live
   coordinator.
7. `step-07-canary-stream` — Run the reference client with `--privacy-class`
   in stream mode with the canary prompt; prove the client decrypts every
   frame, verifies contiguous sequence and one final frame, prints the
   SPEC-049-R020 disclosure on stderr, and receives the exact response headers.
8. `step-08-canary-nonstream` — Repeat step 7 in non-stream mode.
9. `step-09-redaction-sweep` — Grep provider, coordinator, and gateway logs,
   SQLite stores, the provider state directory, temporary directories, and
   crash-report directories for both canaries, the SHA-256 of each canary,
   and the buyer key; prove zero matches. Prove each privacy request produced
   exactly one content-free SPEC-015 §N.13 `relay-blind-settlement-v1`
   receipt and no other receipt artifact (no v0.4 receipt and no
   `X-MacProvider-Receipt` header). Its `response_body_sha256` must equal the
   SHA-256 of the captured ciphertext frames. Prove no telemetry, trace,
   conversation-cache, or disk-tier artifact for the privacy requests.
10. `step-10-downgrade-negatives` — Prove header strip, header inject, plaintext
    body with header, pool-scoped request, replayed envelope, and wrong key
    record each fail with the SPEC-049-R019 code and zero provider dispatch
    where predispatch; prove tampered and truncated responses make the client
    exit with `do not resubmit`.
11. `step-11-stale-posture-and-quarantine` — Pause posture responses past
    `posture_max_age_seconds` and prove ineligibility without quarantine;
    present an unapproved cdhash and prove durable quarantine and privacy key
    revocation that survive a coordinator restart.
12. `step-12-kill-switch` — Run `coordinator-cli privacy-class disable
    --reason`; prove the next reservation, consume, and dispatch are rejected,
    held predispatch privacy reservations are rejected with refund, and plain
    relay-blind and plaintext traffic are unaffected; re-enable and prove
    recovery.
13. `step-13-enforce-canary` — Against an isolated coordinator and gateway
    configured `settlement.verified_model_settlement_mode: enforce` with
    privacy class enabled, run one stream and one non-stream privacy canary.
    For each, prove:
    - a route-snapshot row with entrypoint
      `coordinator_buyer_v1_relay_blind_chat_completions` and basis
      `relay_blind_envelope_digest_v1` committed before dispatch, whose
      `prompt_hash` is the hex SHA-256 of the envelope bytes;
    - a closed `relay_blind_settled` verdict;
    - a payable provider credit in `spec022_payable_request_credits`;
    - a gateway final-debit usage equal to the provider-credited usage; and
    - a zero delta in the verified counter, verified-work rewards, and
      referral qualification.
14. `step-14-no-capability-provider-excluded` — Under the same enforce
    configuration, connect a provider that does not advertise
    `relay_blind_settlement_receipt_v1` (the signed 1.8.214 CLI, or the
    candidate with the capability withheld). Prove it is never reserved for
    relay-blind or privacy-class work, the buyer gets the typed unavailable
    error before quota, and no snapshot, credit, or dispatch exists for it.
15. `step-15-tampered-receipt-quarantined` — With a test-only fault injector
    on the isolated provider build, alter one bound field of the
    `relay-blind-settlement-v1` receipt, and separately withhold it. Prove a
    closed `quarantined` verdict (after the deadline for the withheld case),
    zero payable provider credit, and a refunded buyer reservation. Prove a
    v0.4 receipt presented for a relay-blind snapshot is also quarantined.
    The injector build never joins a live coordinator.
16. `step-16-redaction-review` — Review every captured artifact for prompts,
    completions, key material, credentials, payout material, private paths,
    and unbounded diagnostics before signing.

## Required evidence contract

The reviewed redacted evidence manifest MUST be committed under:

```text
journeys/evidence/privacy-class-beta-*.redacted.json
```

It MUST be the exact closed object below; unknown/missing/duplicate keys or
wrong types fail before signing:

```json
{
  "schema_version": "macprovider.privacy-class-beta-evidence.v1",
  "journey_id": "JOURNEY-PRIVACY-CLASS-BETA",
  "requirement_ids": ["<sorted unique exact IDs from this journey>"],
  "captured_at": "<RFC3339 UTC seconds>",
  "expires_at": "<RFC3339 UTC seconds, <= captured_at + 90 days>",
  "release_tag": "<signed release tag>",
  "binary_sha256": "<lowercase sha256 of the release macprovider-cli>",
  "code_cdhash": "<40 lowercase hex>",
  "team_id": "<Apple team identifier>",
  "signing_identifier": "<code-signing identifier>",
  "steps": [{"step_id":"step-01-bind-signed-release","status":"pass","artifact_sha256":"<lowercase sha256>"}],
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

- `hardening_applied_before_network_verified`
- `privacy_key_memory_only_verified`
- `posture_verified_by_coordinator`
- `debugger_attach_refused_verified`
- `core_dumps_disabled_verified`
- `diagnostic_env_refused_verified`
- `dyld_env_inert_verified`
- `unsigned_or_resigned_build_refused_verified`
- `sip_off_host_refused_verified`
- `stream_frames_decrypted_and_verified`
- `nonstream_frames_decrypted_and_verified`
- `disclosure_strings_exact_verified`
- `canary_absent_from_all_artifacts_verified`
- `downgrade_attempts_rejected_verified`
- `tampered_or_truncated_response_rejected_verified`
- `stale_posture_ineligible_verified`
- `quarantine_durable_across_restart_verified`
- `kill_switch_blocks_all_phases_verified`
- `relay_blind_and_plaintext_unaffected_verified`
- `exactly_one_content_free_settlement_receipt_verified`
- `enforce_snapshot_before_dispatch_verified`
- `relay_blind_settled_verdict_closed_verified`
- `relay_blind_credit_payable_verified`
- `buyer_debit_equals_provider_credit_usage_verified`
- `verified_count_delta_zero_verified`
- `no_capability_provider_excluded_verified`
- `tampered_or_missing_receipt_quarantined_and_refunded_verified`

They MUST set these booleans to `false`:

- `plaintext_observed_at_relay`
- `failover_or_alternate_provider_observed`
- `silent_downgrade_observed`
- `plaintext_derived_receipt_or_telemetry_emitted_for_privacy_request`
- `relay_blind_request_reported_as_verified`
- `privacy_key_written_to_disk`
- `unreleased_local_binary_connected_to_live_coordinator`
- `secret_or_canary_persisted`

The `observations` object contains exactly the booleans listed in this section.

## Completion

The journey is complete only when every required step passes, the signed result
names every requirement mapped to this journey except SPEC-049-R023,
SPEC-022-R014, SPEC-015-R007, and SPEC-001-R005 (and no unmapped
requirement), every evidence digest resolves, and the evidence has not
expired. The staged canary and three-lane review are deliberately
outside this evidence object and remain SPEC-049-R023 inputs.
