# Audit prompt — ISS-203 R1

## What's under review

Branch `fix/iss-203-v2-auth-stale-model` against `origin/main`
(HEAD `327b02e`). Closes [#203](https://github.com/Augustas11/macprovider/issues/203).

## Background

Pre-existing bug in `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
`authInitialMessage(attempt:providerReceiptPublicKeyOverride:)` (the
v2 auth payload sent on initial connect AND on every reconnect)
sourced `model_id`, `model_hash`, and `supported_models` from
`ProviderStatus.snapshot()` rather than `ModelRuntime.currentSnapshot()`.

`helloMessage()` already routed through the runtime snapshot when
`warmSwapEnabled` is true. `authInitialMessage` historically did
not.

## Failure mode

1. Warm-swap completes from model A → model B.
2. Heartbeat send wedges (#189-class hang).
3. Bounded-send timeout → close → reconnect.
4. Reconnect calls `authInitialMessage`.
5. PRE-FIX: payload reports model A (stale ProviderStatus).
6. Coordinator re-admits provider under stale routing metadata.
7. Routing decisions in the window between reconnect and the next
   regular heartbeat use the wrong `model_id`.

POST-FIX: `authInitialMessage` mirrors `helloMessage`'s warm-swap
branch — sources `model_id` and `model_hash` from
`modelRuntime.currentSnapshot()` when `warmSwapEnabled`; falls back
to `ProviderStatus` otherwise. `supported_models` validation now
uses the resolved (post-swap) model id.

## What this PR does (small)

- `CoordinatorClient.swift` `authInitialMessage`: extract
  `resolvedModelID` + `resolvedModelHash` via the same
  warm-swap branch helloMessage uses; thread them into `model_id`,
  `model_params_b` (which is per-modelID), `supported_models`
  validation, and `model_hash`.
- 2 new XCTests:
  - `testAuthInitialEnabledModeReadsFromModelRuntime` — mirror of
    `testHelloEnabledModeReadsFromModelRuntime`. Asserts post-swap
    runtime values appear; pre-swap values do NOT leak.
  - `testAuthInitialDisabledModeReadsFromProviderStatus` —
    confirms warmSwapEnabled=false path is unchanged.

## Severity bar (CRITICAL/HIGH only)

Three independent lanes. Report only CRITICAL or HIGH. Optional
advisory MEDIUM noted but doesn't gate merge.

## CODE lane

1. Does the new resolved-modelID get threaded through ALL relevant
   payload fields? (model_id, model_params_b, supported_models,
   model_hash — anything else that depends on the model identity?)
2. `model_params_b` switched from `snapshot.modelID` to
   `resolvedModelID`. Is `ProviderCapacity.modelParamsB(modelID:)`
   safe when modelID changes mid-flight?
3. `supported_models` validation: pre-fix validated against
   `snapshot.modelID`; post-fix uses `resolvedModelID`. Could this
   change reject a previously-accepted catalog (e.g., if runtime
   modelID is empty in some boot state)?
4. Concurrency: `providerStatus.snapshot()` and
   `modelRuntime.currentSnapshot()` are two separate async reads.
   Could they tear if a swap completes between them? (helloMessage
   has the same pattern — is the race acceptable there too?)

## SECURITY lane

1. Could a malicious provider exploit the auth_request payload by
   triggering an in-flight swap during reconnect to publish a
   model_id it doesn't actually have loaded? (Risk model: provider
   is semi-trusted; coordinator routes based on this metadata.)
2. `model_hash` semantic change — coordinator may use it for
   integrity verification. Does publishing the runtime hash (vs
   boot hash) on reconnect open any pinning/verification gap?

## ARCHITECT lane

1. SPEC-002 / SPEC-010 — any contract that constrains
   auth_request `model_id` to be the boot-time value?
2. Consistency: `helloMessage` and `authInitialMessage` now share
   the same warm-swap source. Should they share a helper to make
   future divergence harder?
3. The fix doesn't address `sendHeartbeat`'s already-correct
   warm-swap branch (line ~1566). Does this PR create any
   inconsistency with other auth-related messages (auth_step2,
   etc.)?

## Output format

```
SEVERITY: <CRITICAL|HIGH>
TITLE: <short>
FILE: <path>:<line>
DETAIL: <what fires / why wrong>
SUGGESTED FIX: <action>
```

If 0 CRITICAL/HIGH: output exactly `0 CRITICAL / 0 HIGH`.
