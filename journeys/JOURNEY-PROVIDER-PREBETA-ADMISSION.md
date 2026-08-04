# JOURNEY-PROVIDER-PREBETA-ADMISSION

Mapped SPECs: SPEC-010, SPEC-023, SPEC-032, SPEC-033, SPEC-034
Mapped authority domains: model-catalog-identity, installer-autotune-policy, hardware-evidence-admission, hardware-evidence-verifier, referral-advocacy-policy
Related provider-prebeta context: SPEC-003, SPEC-013, SPEC-025, SPEC-026
Issue: https://github.com/Augustas11/macprovider/issues/895
Status: contract-defined; physical evidence pending

## Purpose

This journey defines the provider-prebeta proof needed to sign and admit new
providers without expanding #614 into full buyer/API/money-path reconciliation.
It maps only to the stable requirements listed in `specs/CONFORMANCE.json`.
Provider onboarding, autotune, app, and browserless onboarding specs remain
related context until their provider-prebeta obligations are migrated into
stable requirement IDs and explicitly mapped.

It is not itself evidence. The mapped requirements stay pending until a real
run on physical Macs produces a redacted, recomputable artifact under
`journeys/evidence/` and any sensitive conformance promotion also satisfies
the signed journey-result contract required by `specs/PROCESS.md`.

## Required Roles

- Coordinator: Pearl production coordinator or the production-equivalent
  canary selected for this evidence run.
- Provider: a fresh or reset Apple Silicon Mac representative of the
  provider-prebeta cohort.
- Operator: the provider signer/admission operator with access to the intended
  private-prebeta authorization path.
- Buyer smoke probe: authenticated buyer request path used only to prove that
  the admitted provider serves after onboarding and lifecycle completion.

## Required Capture Fields

The evidence artifact must record enough information to recompute and audit the
claim without trusting screenshots or prose:

- journey ID, SPEC IDs, requirement IDs covered, capture timestamp, operator
  role or stable redacted operator fingerprint, repository commit, candidate
  release or build identity, and artifact expiry;
- redacted provider identity, hardware profile, macOS version, install channel,
  provider binary path, binary version, binary SHA-256, launchd label, and
  redacted local account fingerprint or non-identifying account role;
- authorization path used for private pre-beta entry, including referral or
  invite identifiers only as stable redacted fingerprints;
- registration and admission state before and after launch, including provider
  ID, accepted/rejected reason, token class, and any capability gates applied;
- catalog and autotune inputs/outputs: selected model, catalog row identity,
  model hash or signed row digest, RAM/fit verdict, recommendation transcript,
  and operator-visible warnings;
- hardware evidence and verifier state: submitted evidence identity, verifier
  verdict, admission gate result, and whether the provider is sandboxed,
  route-eligible, or buyer-serviceable;
- provider runtime state: local health, model-loaded status, coordinator
  heartbeat, ready/routing-eligible status, encrypted leg status when
  applicable, and restart/reconnect behavior if exercised;
- buyer smoke proof: request ID, selected provider, response status, observed
  model identity, and coordinator request-log reference;
- exact pass/fail assertion for each covered requirement and the raw command or
  log snippets needed to recompute those assertions.

Secrets, tokens, LAN IPs, wallet private keys, operator identity, local account
names, and machine-unique identifiers must be redacted before the artifact is
committed. Redaction must preserve stable correlation across provider,
coordinator, catalog, verifier, and buyer events.

## Procedure

1. Prepare Pearl or the selected production-equivalent coordinator with the
   provider-prebeta configuration under test. Record the coordinator commit,
   deployed version, relevant feature flags, catalog authority, referral/invite
   posture, hardware-evidence posture, and payout-registration posture.
2. Prepare the provider Mac from a fresh or reset state. Record hardware,
   OS, existing provider identity if any, installed app/CLI state, launchd
   state, and local config.
3. Authorize the provider through the intended private-prebeta path. If the
   active path uses referral or invite admission, record the redacted sponsor
   or invite fingerprint and the admission decision. If referral is disabled or
   not required for the cohort, record that exact posture rather than treating
   old referral exceptions as live blockers.
4. Install or launch the provider through the intended App or CLI flow. Record
   signed artifact identity, notarization/Gatekeeper status where applicable,
   local service identity, provider registration result, and provider token
   class.
5. Run autotune and catalog selection for the target cohort model. Record model
   fit, recommendation transcript, signed catalog row identity, model artifact
   identity, and operator-visible warnings.
6. Submit or refresh hardware evidence. Record verifier outcome, coordinator
   admission gate result, sandbox/credential state, and whether the provider is
   ready/routing-eligible.
7. Start serving the selected model. Record local `/v1/models` or equivalent
   health, model-loaded telemetry, heartbeat state, encrypted leg state if
   applicable, and Pearl pool state.
8. Exercise a minimal buyer smoke request through the public buyer path only
   to prove the provider is routable and serving after admission. Record the
   response status, request ID, selected provider, and observed model identity.
9. If restart/reconnect is part of the candidate launch path, restart the app
   or service and repeat the provider ready/routing-eligible and buyer-smoke
   assertions.
10. Package the redacted evidence under `journeys/evidence/`, compute its
    SHA-256 from repository bytes, and map that digest into
    `specs/CONFORMANCE.json` only when the signed journey-result contract and
    applicable evidence rules are satisfied.

## Requirement Assertions

Provider onboarding and admission pass only if the artifact proves the intended
private-prebeta authorization path, provider identity, token class, launch
state, and coordinator admission decision for a real provider Mac.

Model readiness passes only if the artifact proves catalog row identity,
autotune recommendation, model fit, model-loaded state, hardware/verifier
admission posture, and route eligibility for the selected cohort model.

Referral or invite admission passes only for the provider-prebeta admission
claim. Advocacy rewards, X dwell rewards, and broad referral economics remain
outside this journey unless explicitly enabled for the cohort and captured as
separate assertions.

Buyer smoke passes only if the public buyer path routes one authenticated
request to the newly admitted provider and receives a successful response with
the expected model identity. It does not establish full buyer API, billing,
settlement, or receipt conformance.

## Stop Conditions

Stop and mark the run failed if any of the following occur:

- the provider authorization path cannot be tied to the configured
  private-prebeta policy;
- provider identity, token class, launchd state, binary hash, model identity,
  hardware evidence, verifier verdict, or coordinator admission state cannot be
  identified before and after launch;
- catalog/autotune selection cannot be tied to a signed or otherwise
  authoritative model row;
- the provider is marked ready but buyer smoke cannot route to it through the
  selected coordinator;
- redaction removes the ability to correlate provider, coordinator, catalog,
  verifier, and buyer events;
- the run exposes a real product failure, in which case split that failure into
  a CODE_BUG or SPEC_BUG issue instead of closing this journey as passing.

## Non-Evidence

The following do not satisfy this journey by themselves:

- CI green checks, unit tests, or static validation.
- Screenshots without raw command/log evidence.
- A local health probe that bypasses coordinator admission and buyer routing.
- Historical referral exception text that is no longer the current production
  posture.
- A successful buyer request to an already-admitted incumbent when the claim is
  fresh provider-prebeta admission.
- A payout registration run; provider payout setup is covered by
  `JOURNEY-SPEC-016-PAYOUT-ADDRESS-REGISTRATION`.
