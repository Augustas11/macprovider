# JOURNEY-PROVIDER-AUTOUPDATE-PHYSICAL

SPEC: SPEC-020 - Provider autoupdate
Authority domain: provider-autoupdate
Issue: https://github.com/Augustas11/macprovider/issues/614
Status: contract-defined; physical evidence pending

## Purpose

This journey defines the physical proof required before SPEC-020-R001 through
SPEC-020-R004 can move from `pending` to `conformant`.

It is not itself evidence. The mapped requirements stay pending until a real
run on physical Macs produces a redacted, recomputable artifact under
`journeys/evidence/` and the signed journey-result contract required by
`specs/PROCESS.md` exists.

## Required Roles

The run must use the current production-base provider CLI and release assets.
It must not depend on pre-production archaeology or the obsolete pre-1.8.61
update path.

- Coordinator: Pearl production coordinator or the production-equivalent Pearl
  canary selected for this evidence run.
- Provider A: an 8 GB Apple Silicon Mac on the same LAN/Wi-Fi, running the
  current feasible Llama model selected by catalog and admission. Prior
  operator proof that Llama can run on this class of Mac is operational input,
  not repository evidence until captured in the result artifact.
- Provider B: a higher-memory Apple Silicon Mac running the incumbent
  production model family, such as Qwen or the then-current admitted model.
- Buyer probe: authenticated buyer request path able to route through the
  coordinator to each provider after update/recovery.

## Required Capture Fields

The evidence artifact must record enough information to reproduce and audit the
claim without trusting screenshots or prose:

- Journey ID and SPEC requirement IDs covered.
- Capture timestamp, operator, hostnames redacted or hashed consistently, and
  artifact expiry.
- Repository commit, release tag, candidate ID, candidate asset URL, asset
  SHA-256, checksums SHA-256, signature identity, discovery head sequence,
  discovery transport tag, discovery head SHA-256, compatibility-set ID, and
  compatibility-set SHA-256.
- For each provider: provider ID, hardware role, memory size, macOS version,
  CPU architecture, model ID, model hash or catalog row identity, binary path,
  binary version before update, binary version after update, and `whoami` user.
- Coordinator state before and after: provider admission verdict, ready/not
  ready state, advertised recommendation, signed-release authority mode, and
  buyer-serving status.
- Local update state: mutation-lock acquisition, pending marker fields,
  rollback backup path/hash, release rollback path/hash, launchd service label,
  launchd PID before/after, one-shot helper state, local health result, success
  sentinel result, and cleanup result.
- Recovery state: disconnected/rejected manual recovery result, startup
  recovery result if exercised, rollback trigger, rollback target hash before
  restore, rollback target policy verdict, binary/hash after restore, and
  rollback event class.
- Buyer proof: buyer request IDs, provider selected, response status, model
  identity observed by the buyer path, and coordinator request-log references.
- Exact pass/fail assertion for each requirement and the raw command/log
  snippets needed to recompute those assertions.

Secrets, tokens, LAN IPs, and machine-unique identifiers must be redacted before
the artifact is committed. Redaction must preserve stable correlation across the
artifact.

## Procedure

1. Prepare Pearl with the current production coordinator configuration and the
   current signed release/discovery assets. Record the coordinator commit,
   coordinator version, advertised recommendation, and discovery head.
2. On Provider A and Provider B, record the installed CLI version, launchd
   service identity, running model identity, local health, coordinator admission
   state, and buyer-serving state.
3. Exercise SPEC-020-R001 by proving signed recovery discovery can select the
   target release without relying on an accepted coordinator session. The run
   must show the signed monotonic discovery head, bounded immutable transport
   selection, selected target, compatibility manifest, downgrade/revocation
   gate result, mutation-lock ownership, update apply, launchd restart, local
   health, cleanup, coordinator reconnection, and buyer-serving result.
4. Exercise SPEC-020-R002 by running `malibu-cli update` while the
   provider has no live accepted coordinator session, or while the coordinator
   rejects the current installed version. The run must show that manual recovery
   ignores automatic-update opt-out and coordinator admission while still
   enforcing signature, archive, signed compatibility-manifest, downgrade,
   revocation, mutation-lock, activation, local-health, and rollback gates.
5. Exercise SPEC-020-R003 by proving local update integrity is committed or
   rolled back from local signed-set identity, launch, and provider health
   rather than coordinator network readiness. At least one successful update
   must show local success even when network readiness is unavailable or
   separately not ready, and at least one controlled failure must show rollback
   only for activation, launch, self-test, local-health, or signed-set identity
   failure.
6. Exercise SPEC-020-R004 by proving the shared mutation lock, launchd helper
   fencing, listener-bound first-hop authorization, rollback-entry fencing,
   one-shot launchd reload, and rollback cleanup on physical machines. Legacy
   first-hop bridge compatibility may be included as compatibility evidence,
   but it cannot be the only evidence for the current production-base update
   and rollback path.
7. After the provider restarts or recovers, issue buyer probes through Pearl to
   Provider A and Provider B. Record coordinator admission, route selection,
   buyer request IDs, response status, and model identity.
8. Package the redacted evidence under `journeys/evidence/`, compute its
   SHA-256 from repository bytes, and map that digest into
   `specs/CONFORMANCE.json` only after the signed journey-result contract
   exists.

## Requirement Assertions

SPEC-020-R001 passes only if the artifact proves signed recovery discovery,
bounded immutable discovery transport, current production-base update apply,
restart, local health, coordinator rejoin, and buyer-serving on both provider
roles without using coordinator admission as the discovery authority.

SPEC-020-R002 passes only if the manual command recovers from disconnected or
rejected coordinator state and enforces the same cryptographic, compatibility,
mutation, local-health, and rollback gates as automatic update.

SPEC-020-R003 passes only if local success and rollback decisions are bound to
signed target identity, process launch, local health, and signed-set identity,
with coordinator readiness recorded separately and never used alone as a
rollback trigger.

SPEC-020-R004 passes only if physical logs and state prove shared mutation-lock
ownership, exact launchd helper fencing, exact listener-bound handoff/commit
authorization, one-shot restart semantics, rollback-entry fencing, and complete
payload rollback behavior.

## Stop Conditions

Stop and mark the run failed if any of the following occur:

- The target asset, checksum, signature, discovery head, transport sequence, or
  compatibility manifest cannot be cryptographically tied to the selected
  release.
- The run cannot identify the launchd service, launchd PID, binary hash, model
  identity, or provider ID before and after update/recovery.
- The provider swaps over in-flight buyer inference.
- Coordinator connectivity is used as the authority for manual or signed
  recovery discovery.
- Network readiness failure alone rolls back a locally healthy, signed newer
  release.
- Mutation locks, pending markers, rollback backups, launchd helpers, or
  rollback restoration cannot be observed directly.
- Buyer probes cannot prove the updated/recovered provider serves through
  Pearl after the operation.
- Redaction removes the ability to correlate provider, coordinator, release,
  model, and buyer events.

## Non-Evidence

The following do not satisfy this journey by themselves:

- CI green checks, unit tests, or static validation.
- Matching `malibu-cli --version` output without signed discovery,
  compatibility-set, launchd, rollback, and buyer-serving proof.
- Gatekeeper success or notarization success alone.
- A curl health probe that bypasses Pearl and buyer routing.
- Screenshots without raw command/log evidence.
- Proof that an old updater bridge worked for pre-1.8.61 providers.
- Operational knowledge that an 8 GB Mac can run Llama unless captured in the
  structured journey artifact.
