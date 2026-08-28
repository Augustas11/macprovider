# JOURNEY-PROVIDER-BYOM-DISCOVERY

Status: draft journey contract; no implementation evidence
Owner: SPEC-046 provider BYOM discovery conformance
Specs: SPEC-046
Requirements: SPEC-046-R001, SPEC-046-R002, SPEC-046-R003, SPEC-046-R004,
SPEC-046-R005, SPEC-046-R006, SPEC-046-R007, SPEC-046-R008
Authority domains: provider-byom-discovery
Issue: https://github.com/Augustas11/macprovider/issues/1240
Execution mode: local-provider-discovery

## Purpose

This journey defines the signed evidence required to promote provider-local
BYOM discovery and evaluation. It proves that `malibu-cli` can discover
local model/runtime candidates, evaluate at least one candidate through a
bounded local harness, and preserve the non-earning boundary.

This document is a test contract. It is not evidence that the journey has
passed, and it does not make any SPEC-046 requirement conformant by itself.

## Out Of Scope

- Buyer traffic, buyer debit, provider credit, payout readiness, or settlement.
- Public, LAN, VPN, or non-loopback endpoint discovery.
- Installing runtimes, downloading weights, or mutating production provider
  serving configuration.
- Raw prompt, raw completion, endpoint credential, local absolute path, wallet,
  or provider-token retention in committed artifacts.

## Required Steps

The signed result MUST contain these passing steps:

1. `step-01-discover-mlx-cache` - Run discovery against a local MLX-cache
   candidate and capture the redacted candidate row.
2. `step-02-discover-loopback-runtime` - Run discovery against one loopback
   runtime adapter such as Ollama, LM Studio, llama.cpp, or an
   OpenAI-compatible loopback endpoint.
3. `step-03-discover-opaque-endpoint` - Run discovery against one explicitly
   configured OpenAI-compatible loopback endpoint whose model identity cannot
   be tied to a catalog match or local artifact hash. Require
   `identity_state: "opaque_endpoint"` and non-earning local-only or
   not-offered state.
4. `step-04-reject-non-loopback` - Attempt a non-loopback adapter endpoint and
   require local rejection before any request leaves the host.
5. `step-05-handle-adapter-failure` - Capture a malformed, timed-out, or
   unavailable adapter as a warning state rather than a trust claim.
6. `step-06-evaluate-candidate` - Run `models evaluate` for one candidate and
   capture bounded health, capability, and performance observations.
7. `step-07-no-production-mutation` - Confirm discovery and evaluation did not
   edit provider config, change the production serving model, install packages,
   download weights, or persist adapter credentials.
8. `step-08-redaction-review` - Review JSON output, stderr, logs, and artifacts
   for secret, prompt, completion, endpoint credential, and local path redaction.
9. `step-09-state-boundary` - Confirm the evaluated candidate remains
   non-routable and non-earning unless SPEC-047 admission state is present.
10. `step-10-local-state-ladder` - Exercise `local_only`, `offerable`, and
   local-default `not_offered` candidates and confirm the CLI reports the
   provider-facing next action and local transition reason for each state.

## Required Evidence Contract

The reviewed redacted evidence artifact MUST be committed under:

```text
journeys/evidence/provider-byom-discovery-*.redacted.json
```

It MUST use:

```json
{
  "schema_version": "macprovider.provider-byom-discovery-evidence.v1",
  "journey_id": "JOURNEY-PROVIDER-BYOM-DISCOVERY"
}
```

The signer workflow converts that artifact into a generic signed journey-result
only after redaction, no-secret, local-only, no-production-mutation, and
required-observation checks pass.

## Required Observations

The redacted evidence and signed result MUST set these booleans to `true`:

- `adapter_failure_warned`
- `candidate_evaluated`
- `loopback_runtime_discovered`
- `local_state_ladder_verified`
- `mlx_cache_discovered`
- `non_loopback_rejected`
- `opaque_endpoint_candidate_discovered`
- `redacted_artifacts_reviewed`
- `state_boundary_preserved`

They MUST set these booleans to `false`:

- `buyer_traffic_sent`
- `provider_credit_created`
- `raw_completion_logged`
- `raw_prompt_logged`
- `runtime_installed`
- `weights_downloaded`

## Completion

The journey is complete only when every required step passes for one reviewed
candidate commit or release artifact and the signed journey-result names only
SPEC-046 requirements that remain mapped to this journey in
`specs/CONFORMANCE.json`.
