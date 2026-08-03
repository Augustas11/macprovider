# JOURNEY-SPEC-016-PAYOUT-ADDRESS-REGISTRATION

Status: contract-only; no conformance or production-readiness claim
Owner: payout/release verification
Spec: SPEC-016
Requirement: R002
Authority domain: payout-lifecycle
Issue: https://github.com/Augustas11/macprovider/issues/614

## Purpose

This journey defines the physical evidence required to reconcile provider
payout-address registration. It covers challenge retrieval, EIP-712
proof-of-possession, replay protection, cooling-off, rotation, and the
operator-visible Add Wallet flow.

This document is a test contract. It is not evidence that the journey has
passed, that payout is deployed, or that payout activation is permitted.

## Preconditions

- Run against a named candidate commit or release artifact, with the exact
  commit recorded in the result.
- Use an isolated test provider, a disposable wallet, and a disposable
  database or namespace. Do not use a funded production wallet.
- Capture the effective payout configuration before and after the journey.
  payout.enabled must remain false for this contract-only run.
- Use a short-lived provider token through the approved secret-injection
  mechanism. Do not place bearer tokens or private key material in logs,
  screenshots, result JSON, or uploaded artifacts.
- Record the configured chain ID, EIP-712 domain, verifying contract, and
  coordinator endpoint from the candidate under test.
- Execute the physical journey in the candidate-derived handler-only
  conformance harness. The harness must mount the exact challenge and
  registration handlers with isolated SQLite, real provider-token and pause
  validation, and controlled test dependencies, but must not construct the
  production payout runner, external RPC clients, or settlement signer.
  It must keep payout.enabled false. If this harness cannot be built from the
  named candidate, mark the run blocked and produce no passing evidence.

## Physical steps

1. Capture the candidate version, effective configuration, database
   namespace, harness identifier, and clean starting state. Confirm
   payout.enabled=false, runner_started=false, no external RPC client or
   settlement signer is constructed, and no payout settlement action is
   enabled. Use the handler-only harness for HTTP registration and the
   candidate's read-only selection query/fixture for cooling-off assertions.
2. Fetch a payout challenge over the TLS coordinator endpoint using the
   provider token. Verify that the token subject and URL path bind to the
   test provider and that the response contains the actual challenge fields:
   domain name/version, chain ID, chain, verifying contract, and
   server_ts_utc. Compare the verifying contract with the candidate hot
   wallet and record only redacted identifiers and artifact hashes. The
   endpoint does not issue a nonce or expiry; request freshness is proven by
   the signed POST timestamp/skew rejection and anti-replay nonce checks below.
3. Start the Malibu Add Wallet flow. Verify that the callback listener binds
   only to loopback, uses a fresh state and nonce, accepts one valid callback,
   and tears down on cancellation, timeout, malformed input, oversized input,
   and listener-start failure.
4. Sign the challenge with the disposable wallet in the non-custodial
   browser signer. Verify that the private key stays in the signer and that
   the CLI/Malibu boundary carries only the signed payload and expected
   address material. Record the signed digest and address fingerprint, never
   the signature payload if it contains secrets.
5. Submit the registration over TLS. Verify the expected success response,
   provider scoping, persisted address, success audit record, and initial
   payout_allowed=1 plus a future pending_until_utc cooling-off deadline.
   Confirm the runner selects no address for payout before that deadline and
   no payout settlement is attempted.
6. Re-submit the same signed request and a request with a consumed or
   mismatched nonce. Verify rejection and prove that no second registration
   row, success/change audit event, or payout-permission mutation is created.
   Require exactly one structured rejection event for each rejected attempt,
   including the replay reason.
7. Exercise invalid signature, wrong domain, wrong chain, wrong provider,
   typed-data field mismatch, and stale timestamp cases. Verify fail-closed
   rejection before any durable registration or payout-permission mutation;
   stale-request rejection is the expiry/freshness proof because the
   challenge response has no expiry field.
8. With an existing allowed row whose prior cooling-off has elapsed, rotate
   to a second disposable address. Verify a 200 response, rotated_from,
   a new future pending_until_utc deadline, and payout_allowed remains 1.
   During that new cooling-off, verify runner selection uses the previous
   address; after the deadline, verify it uses the new address. Separately
   seed an existing payout_allowed=0 row and submit a valid rotation. Require
   409 payout_not_allowed, unchanged address and payout_allowed values, and
   exactly one rejection event. Do not shorten or bypass the production
   cooling-off or compliance policy.
9. Set runtime.registration_paused=1 and send challenge and registration
   requests both with and without a token. Require identical 503 status/body
   pairs and the exact rejection events
   provider_payout_address_challenge_rejected and
   provider_payout_address_change_rejected with reason=registration_paused.
   Use the harness pause hook to flip the flag after the registration
   pre-authentication check but before the BEGIN IMMEDIATE commit. Require
   rollback, no durable row/permission mutation, and exactly one
   provider_payout_address_change_rejected event with the same reason.
   Exercise the provider-scoped rate limit and require 429 plus exactly one
   provider_payout_address_change_rejected event with reason=rate_limited.
   Verify cleanup of all loopback listeners and temporary state.
10. Inspect logs, database rows, callback captures, screenshots, and exported
    artifacts for bearer tokens, private keys, raw secrets, or unintended
    production identifiers. Hash the redacted evidence set.
11. Re-check effective configuration and runtime activity. Confirm payout
    remains default-off and that this journey produced no production payout,
    settlement, or release-promotion side effect.

## Required journey-result contract

The run must produce a redacted, signed result envelope containing:

- schema_version, journey_id, spec_id, requirement_ids, run_id, candidate
  commit/release, operator, environment class, and UTC timestamps;
- execution_mode, harness identifier/version, payout.enabled,
  runner_started, external_rpc_started, settlement_signer_started, and
  restoration result;
- one result entry for every physical step, with pass/fail status, assertion
  identifiers, and SHA-256 references to retained artifacts;
- effective payout configuration before and after the run;
- redacted challenge/domain/nonce/address fingerprints sufficient to prove
  binding and replay behavior without exposing secrets;
- exact canonical EIP-712 typed-data inputs and signature in an
  access-controlled artifact, with the public result retaining only its
  artifact hash, signer/address fingerprint, digest, verifier version, and
  independent verification output;
- exact candidate coordinator, CLI, Malibu executable/resource hashes,
  canonical envelope encoding, and applicable signer key/trust-root metadata;
- explicit values for payout_enabled, runner_started, settlement_attempted,
  and production_side_effects;
- signer identity and signature metadata, plus the verification result;
- final result, failure details when applicable, and the authorized
  journey-result signature.

Promotion tooling must verify the final result schema, candidate identity,
artifact hashes, signature, and absence of secret material before adding a
journey evidence SHA to specs/CONFORMANCE.json.

## Pass criteria

R002 may be proposed for promotion only when every step passes, the signed
result is reproducible against the named candidate, all required artifacts
are retained and redacted, and the release gate accepts the evidence as
fresh. A passing local or staging run does not by itself authorize production
activation.
