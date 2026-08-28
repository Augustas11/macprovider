# JOURNEY-LOCAL-CONSUMER-ENDPOINT

Status: signed staging-or-production promotion evidence for SPEC-045; no
fake-gateway promotion
Owner: SPEC-045 local consumer endpoint conformance
Specs: SPEC-045
Requirements: SPEC-045-R001, SPEC-045-R002, SPEC-045-R003, SPEC-045-R004,
SPEC-045-R005, SPEC-045-R006, SPEC-045-R007, SPEC-045-R008
Authority domains: local-consumer-endpoint
Issue: https://github.com/Augustas11/macprovider/issues/927
Execution mode: staging-or-production-local-consumer-endpoint

## Purpose

This journey defines the signed real-gateway evidence required to promote the
local consumer endpoint mode. It proves that a reviewed `malibu-cli
consume` build can be used by an OpenAI SDK through the loopback base URL and
generated local token while preserving local budget, recovery, and redaction
invariants.

This document is a test contract. It is not evidence that the journey has
passed, and it does not make any SPEC-045 requirement conformant by itself.

## Out Of Scope

- Fake-gateway or injected-transport tests. Those are automated harness
  evidence only.
- Public gateway, coordinator, billing, settlement, provider payout, model
  catalog, or receipt authority changes.
- Any endpoint outside the SPEC-045 v0.1 local subset:
  `GET /v1/models`, `POST /v1/chat/completions`, and local
  `GET /v1/status`.
- Storing raw prompts, raw completions, upstream buyer credentials, or local
  bearer-token values in committed artifacts.

## Preconditions

- Run against a named clean candidate commit or release artifact, with the
  exact commit recorded in the redacted evidence.
- Use a staging or production MacProvider gateway. The journey MUST NOT target
  `ConsumeFakeGatewayUpstreamClient`, a local fake gateway, or a non-production
  injected transport.
- Use a short-lived buyer credential through the approved secret-injection
  mechanism. Record only redacted fingerprints.
- Start `malibu-cli consume` with a positive local budget, explicit model
  allowlist, trusted pricing, and a ledger path whose redacted digest can be
  captured.
- Use an OpenAI SDK configured with the local endpoint base URL and generated
  local bearer token as the SDK `api_key`. The upstream buyer credential must
  stay in CLI custody.

## Required Steps

The signed result MUST contain exactly these passing physical steps, in this
order:

1. `step-01-capture-local-endpoint` - Capture the CLI version, binary digest,
   local endpoint base URL fingerprint, upstream gateway origin fingerprint,
   model allowlist, budget mode, ledger digest, and generated local-token
   fingerprint.
2. `step-02-openai-sdk-local-client` - Configure an OpenAI SDK client with the
   loopback base URL and generated local token as `api_key`. Confirm the SDK
   does not receive the upstream buyer credential.
3. `step-03-permitted-chat-completion` - Send a permitted chat completion
   through the SDK and local endpoint to the staging or production gateway.
   Require an OpenAI-compatible success and trusted usage/settlement evidence
   when available.
4. `step-04-over-budget-denial` - Send a request that exceeds the selected
   local budget or per-request cap. Require local denial before upstream
   forwarding.
5. `step-05-restart-held-reservation` - Create or capture an unreconciled held
   reservation, restart the local endpoint, and prove the held state is still
   visible to the recovery path.
6. `step-06-recovery-release-held-reservation` - Release the held reservation
   with the SPEC-045 recovery command and capture the resulting redacted ledger
   transition.
7. `step-07-redaction-status-logs` - Inspect status output, logs, ledger rows,
   SDK captures, and exported artifacts. Confirm no upstream credential, local
   token, raw prompt, or raw completion is present.
8. `step-08-restore-local-state` - Stop the local endpoint, restore local test
   state, and confirm no active descriptor or held reservation remains from the
   journey.

Each step MUST reference the single artifact id:

```text
redacted-local-consumer-endpoint
```

## Required Evidence Contract

The reviewed redacted evidence artifact MUST be committed under:

```text
journeys/evidence/local-consumer-endpoint-*.redacted.json
```

It MUST use:

```json
{
  "schema_version": "macprovider.local-consumer-endpoint-evidence.v1",
  "journey_id": "JOURNEY-LOCAL-CONSUMER-ENDPOINT"
}
```

The redacted evidence source MUST also include closed `support_artifacts` and
`review` objects. Each required physical step must bind to one or more named
support artifacts, and the review block must confirm that the operator reviewed
the support artifacts, the real staging-or-production gateway basis, the
OpenAI SDK local-token client basis, and the redaction basis before protected
signing. The review manifest that feeds capture must pin each reviewed support
artifact by SHA-256 and byte count; capture must fail if the files have changed
after review.

The signer workflow converts that artifact into a generic signed
journey-result envelope only after:

- the redacted evidence source is repository-relative, non-symlinked, and
  byte-identical at `--evidence-sha`;
- `repository.commit` equals `--source-sha`;
- `--source-sha` is an ancestor of `--evidence-sha`;
- every selected requirement is pending and mapped to this journey in
  `specs/CONFORMANCE.json`;
- selector preflight confirms each requirement's mapped implementation/test
  fragments still match `--source-sha`;
- the workflow is manually dispatched from current `origin/main`;
- redaction, no-secret, real-gateway, and required-observation checks pass.

## Required Observations

The redacted evidence and signed result MUST set these booleans to `true`:

- `bearer_tokens_redacted`
- `generated_local_token_used_as_api_key`
- `held_reservation_survived_restart`
- `local_base_url_configured`
- `openai_sdk_used`
- `over_budget_denial_observed`
- `permitted_chat_completion_observed`
- `raw_prompt_output_redacted`
- `recovery_release_observed`
- `redacted_artifacts_reviewed`
- `staging_or_production_gateway`

They MUST set these booleans to `false`:

- `fake_gateway_used`
- `local_token_logged`
- `raw_completion_logged`
- `raw_prompt_logged`
- `upstream_credential_logged`

## Required Candidate Identity

The redacted evidence and signed result MUST include `candidate_identity` with:

- `buyer_credential_fingerprint`
- `cli_binary_sha256`
- `cli_version`
- `gateway_kind` (`staging` or `production`)
- `ledger_sha256`
- `local_endpoint_base_url_sha256`
- `local_token_fingerprint`
- `log_capture_sha256`
- `model_id`
- `rate_card_sha256`
- `sdk_name`
- `sdk_version`
- `status_capture_sha256`
- `upstream_gateway_origin_sha256`

All digest/fingerprint fields MUST be 64-character lowercase hex strings.
Stable operator, buyer, endpoint, and token identities MUST be represented only
as redacted fingerprints.

## Evidence Workflow

Capture:

```text
scripts/capture-local-consumer-endpoint-evidence.py
```

Capture requires a separate
`macprovider.local-consumer-endpoint-capture-review.v1` manifest. The capture
tool is local-only: it writes the reviewed redacted evidence source and does not
sign, promote, dispatch workflows, or mutate production state.

Protected manual workflow:

```text
.github/workflows/promote-signed-local-consumer-endpoint-journey.yml
```

Builder:

```text
scripts/build-local-consumer-endpoint-journey-result.py
```

Validator:

```text
scripts/check_spec_governance.py
```

Workflow contract test:

```text
scripts/test-signed-local-consumer-endpoint-journey-workflow.sh
```

The workflow exports a short-lived artifact containing only the redacted
evidence, the signed journey-result envelope, and the promoted
`specs/CONFORMANCE.json` ledger. It does not push, open PRs, merge, publish
releases, or print signing material. The exported artifact must be reviewed
before any follow-up PR commits signed evidence and conformance promotion.
