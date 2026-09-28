# JOURNEY-NATIVE-MTP-SERVING

Status: draft journey contract; no implementation evidence
Owner: native MTP serving and supporting owner-spec conformance
Specs: SPEC-023, SPEC-030, SPEC-031, SPEC-036, SPEC-038, SPEC-039, SPEC-048
Requirements: SPEC-023-R024, SPEC-030-R021, SPEC-031-R033, SPEC-036-R018,
SPEC-038-R018, SPEC-039-R015, SPEC-048-R001, SPEC-048-R002, SPEC-048-R003, SPEC-048-R004,
SPEC-048-R005, SPEC-048-R006, SPEC-048-R007, SPEC-048-R008, SPEC-048-R009,
SPEC-048-R010, SPEC-048-R011, SPEC-048-R012, SPEC-048-R013, SPEC-048-R015,
SPEC-048-R016
Authority domains: installer-autotune-policy, losslessness-probe,
canary-sanction-lifecycle, compute-integrity-settlement,
continuous-batching-serving, paged-kv-attention, native-mtp-serving
Issue: https://github.com/Augustas11/macprovider/issues/1770
Execution mode: provider-native-mtp-serving

## Purpose

This journey defines the signed physical evidence required to enable one exact
native-MTP serving tuple. It proves target-authoritative greedy output,
transactional state, mixed-row scheduling, fail-closed admission, accounting
invariance, and the preregistered real-hardware performance gate.

This document is a test contract. It is not evidence that the journey passed
and does not make any SPEC-048 requirement conformant by itself.

## Out of scope

- Classic external-draft speculation under SPEC-028.
- Sampling, tools, structured output, logprobs, cache reuse, or multimodal
  native-MTP requests.
- A general MXFP8 format or catalog contract outside SPEC-023/SPEC-010.
- Live-coordinator testing with an unreleased local provider binary.

## Required steps

The signed result MUST contain these passing steps for one exact qualified
tuple:

1. `step-01-bind-tuple` — Record hardware/SoC/RAM, OS/toolchain, provider and
   MLX revisions, model/tokenizer/artifact/MTP-manifest digests, quantization,
   cache/state classes, depth, slot count, benchmark-policy digest, and the
   source commit plus reproducible-build digest. Release-candidate verification
   belongs to SPEC-048-R014 after this journey; the journey does not self-cover
   R014.
2. `step-02-capability-negatives` — Reject missing, extra, duplicate,
   silently filtered, wrong-shape, wrong-dtype, wrong-quantization, and
   digest-mismatched MTP tensors; reject stale, replayed, wrong-signer,
   unavailable, and tuple-targeted emergency revocation state; and preserve
   otherwise valid ordinary decode.
3. `step-03-artifact-security-negatives` — Reject path traversal, symlink
   escape, unexpected local/network references, malformed safetensors
   metadata, size overflow/mismatch, decompression bombs, and above-bound
   allocations before tensor load.
4. `step-04-serial-token-oracle` — Compare native MTP with isolated ordinary
   greedy decode and prove identical token IDs, bytes, usage, and terminal
   reasons across all/none/partial acceptance.
5. `step-05-cache-state-boundary` — Force rejection at every proposal
   position and at an admitted cache or hybrid-state boundary; prove exact
   subsequent-token and state parity.
6. `step-06-streaming-stop` — Prove streaming and non-streaming parity for
   EOS, token stop, a stop string spanning proposal/round boundaries, max
   tokens, early consumer stop, and a post-output injected failure with no
   retry or stitching.
7. `step-07-mixed-multirow` — Run ordinary and native-MTP rows together at
   the tuple's maximum advertised slots with unequal offsets, depths,
   accepted prefixes, admission times, and completion times; prove no state,
   output, terminal, or metric bleed.
8. `step-08-capacity-and-depth-zero` — Exhaust verification-window capacity
   before output and after stickiness; prove pre-output fallback, in-path depth
   reduction to zero, bounded failure when depth zero cannot fit, and no memory
   overcommit or advertised-slot change.
9. `step-09-cancellation` — Cancel during proposal, verification, commit, and
   streaming; prove exact rollback/release and no cache persistence or
   duplicate terminal event.
10. `step-10-warm-swap` — Swap model identity while work is in flight; prove
   old requests remain bound to the complete old tuple while new requests
   cannot inherit its capability or counters.
11. `step-11-accounting` — Compare buyer response, usage, receipt, billing,
    reward, routing, and settlement surfaces with ordinary decode and prove
    there is no native-MTP field or internal-token attribution.
12. `step-12-native-canary` — Pass the local no-join self-test and the distinct
    coordinator-issued SPEC-031-R033 canary. Prove wrong digest, timeout,
    expiry, ordinary/classic fallback, and unsupported-path outcomes disable
    only the affected tuple; prove SPEC-030/036 path binding is inconclusive,
    never a TV/integrity pass, on mismatch; emit no receipt or settlement.
13. `step-13-mxfp8-independent-and-combined` — When this journey's tuple uses
    MXFP8, attach its independent SPEC-023/SPEC-010 format/fit/quality record.
    The combined tuple receives its own journey result and MUST execute every
    step 1 through 15; a base-artifact journey is not reused as the combined
    tuple's result.
14. `step-14-studio-and-tier-benchmark` — Execute the frozen SPEC-048-R015
    matrix on the 256 GB Mac Studio and every advertised lower hardware/RAM
    tier; preserve negative, failed, and incomplete cells and verify the
    predeclared material production-economics gate.
15. `step-15-redaction-review` — Review all captured artifacts for model
    weights, credentials, payout material, raw prompts/completions, private
    paths, tensor values, and unbounded diagnostics.

## Required evidence contract

The reviewed redacted evidence manifest MUST be committed under:

```text
journeys/evidence/native-mtp-serving-*.redacted.json
```

It is one manifest per exact tuple and MUST be the exact closed object below;
unknown/missing/duplicate keys or wrong types fail before signing:

```json
{
  "schema_version": "macprovider.native-mtp-serving-evidence.v1",
  "journey_id": "JOURNEY-NATIVE-MTP-SERVING",
  "native_mtp_admission_tuple_sha256": "<lowercase sha256>",
  "requirement_ids": ["<sorted unique exact IDs from this journey>"],
  "captured_at": "<RFC3339 UTC seconds>",
  "expires_at": "<RFC3339 UTC seconds, <= captured_at + 90 days>",
  "sidecar_sha256": "<lowercase sha256>",
  "benchmark_policy_sha256": "<lowercase sha256>",
  "steps": [{"step_id":"step-01-bind-tuple","status":"pass","artifact_sha256":"<lowercase sha256>"}],
  "observations": {"<every closed boolean named below>": true},
  "mxfp8": null,
  "redaction_manifest_sha256": "<lowercase sha256>"
}
```

`steps` contains each applicable step exactly once in numeric order and no
other id; every status is `pass`. `mxfp8` is null for a base artifact and is the
exact object `{independent_qualification_sha256,
combined_requalification_sha256}` for MXFP8, both lowercase SHA-256.
`native_mtp_admission_tuple_sha256` is recomputed exactly from the full
SPEC-023-R024 domain-separated admission object; a generic tuple id or a digest
over a partial entry is invalid. Runtime canary artifacts additionally bind the
distinct `native_mtp_runtime_tuple_sha256`; they MUST NOT substitute it for the
admission identity in this manifest. Every referenced artifact is an immutable
canonical file in the reviewed bundle; paths and URLs are not evidence
identities.

The signer workflow may produce a generic signed journey-result only after the
tuple binding, required steps, benchmark policy/result digests, redaction
review, and every owner-spec requirement named in this journey all validate. A schema validator and
signer test MUST enforce the closed field set and recompute every digest and
boolean from referenced artifacts; self-asserted booleans are insufficient.
`captured_at` and `expires_at` MUST be present, and expiry MUST be no more than
90 days after capture.

## Required observations

The redacted evidence and signed result MUST set these booleans to `true`:

- `artifact_manifest_fail_closed_verified`
- `emergency_tuple_revocation_verified`
- `path_traversal_rejected_verified`
- `external_reference_rejected_verified`
- `allocation_and_decompression_bounds_verified`
- `ordinary_decode_remained_available_verified`
- `exact_greedy_token_parity_verified`
- `exact_transaction_rewind_verified`
- `streaming_and_terminal_parity_verified`
- `mixed_multirow_isolation_verified`
- `capacity_bound_verified`
- `cancellation_release_verified`
- `cache_persistence_exclusion_verified`
- `warm_swap_tuple_isolation_verified`
- `receipt_and_accounting_invariance_verified`
- `benchmark_preregistered_verified`
- `material_production_economics_gate_verified`
- `all_advertised_hardware_tiers_verified`
- `native_path_canary_verified`
- `native_path_selftest_verified`
- `losslessness_claimed_path_diagnostic_inconclusive_verified`
- `compute_integrity_claimed_path_diagnostic_inconclusive_verified`

They MUST set these booleans to `false`:

- `classic_spec_evidence_reused_as_native_mtp`
- `post_output_path_switch_observed`
- `cross_row_state_bleed_observed`
- `memory_overcommit_observed`
- `native_mtp_field_entered_receipt_or_billing`
- `unreleased_local_binary_connected_to_live_coordinator`
- `secret_or_model_private_material_persisted`

The `observations` object contains exactly the booleans listed in this section,
including the required-false booleans; optional MXFP8 booleans are not used.
The typed `mxfp8` object above carries that evidence without changing the
boolean field set.

## Completion

The journey is complete only when every required step applicable to the tuple
passes, the signed result names every requirement from every owner spec still
mapped to this journey (and no unmapped requirement), every evidence digest
resolves, and the evidence has not expired. Three-lane review is deliberately
outside this evidence object and remains the later SPEC-048-R014 release gate.
