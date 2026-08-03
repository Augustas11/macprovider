# JOURNEY-SPEC-016-PAYOUT-ADDRESS-REGISTRATION

Status: contract-only; no conformance or production-readiness claim
Owner: payout/release verification
Spec: SPEC-016
Requirement: R002

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

## Physical steps

1. Capture the candidate version, effective configuration, database
   namespace, and clean starting state. Confirm no payout runner or payout
   settlement action is enabled.
2. Fetch a payout challenge over the TLS coordinator endpoint using the
   provider token. Verify that the challenge is scoped to the provider and
   includes the expected domain, chain ID, verifying contract, nonce, and
   expiry. Record only redacted identifiers and artifact hashes.
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
   provider scoping, persisted address, audit record, and initial
   payout_allowed/cooling-off state. Confirm no payout settlement is
   attempted.
6. Re-submit the same signed request and a request with a consumed or
   mismatched nonce. Verify rejection and prove that no second registration,
   audit mutation, or payout permission is created.
7. Exercise invalid signature, expired challenge, wrong domain, wrong chain,
   wrong provider, and timestamp-skew cases. Verify fail-closed rejection
   before any durable registration or payout-permission mutation.
8. After the controlled cooling-off interval or an approved test-clock
   advance, rotate to a second disposable address. Verify the documented
   old/new-address semantics, replay protection, audit trail, and
   payout_allowed transition. Do not shorten or bypass the production
   policy in the candidate configuration.
9. Exercise registration rate limiting and provider pre-authorization pause.
   Verify the expected error responses, no durable mutation on denied
   requests, and cleanup of all loopback listeners and temporary state.
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
- one result entry for every physical step, with pass/fail status, assertion
  identifiers, and SHA-256 references to retained artifacts;
- effective payout configuration before and after the run;
- redacted challenge/domain/nonce/address fingerprints sufficient to prove
  binding and replay behavior without exposing secrets;
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
