# Build 1 Control Recovery Plan v2

Status: active control ledger
Date: 2026-09-26
Tracker: #1642
Execution PR: #1658
Supersedes: `build1-control-recovery-plan-v1.md` where the two conflict

## Decision

Continue Build 1 Lane A as a staging-only BYOM proof, but separate the existing
catalog Llama implementation from the final acceptance target:

- `meta-llama/llama-3.2-3b-instruct` /
  `mlx-community/Llama-3.2-3B-Instruct-4bit` is the plumbing-control tuple. It
  may prove preparation, private-record, status-correlation, staging-input, and
  evidence-driver mechanics.
- Final Build 1 acceptance requires one explicitly pinned non-catalog/private
  MLX tuple. The tuple must be absent from the active public catalog and must be
  carried by signed, measured staging authority.
- Evidence from the plumbing-control tuple cannot be relabeled as final BYOM
  acceptance.

The selected surface remains standalone `macprovider-cli` on physical Apple
Silicon. Production activation, public catalog publication, rewards, payouts,
public earnings claims, and automatic paid-provider qualification remain
disabled.

## Current Repository Truth

- PR #1649 landed guarded staging, verification, and durable adoption for the
  Llama plumbing-control tuple.
- PR #1658 contains private preparation recording, local status correlation,
  and measured staging-input work, but its original branch was based on an old
  mainline, became conflicted, and failed the SPEC index after modifying mapped
  coordinator selectors.
- The coordinator binding changes formerly carried by #1658 were independently
  superseded by #1664 and #1667 and must not be replayed.
- The #1658 recovery branch starts from current `origin/main` and selectively
  ports only the provider-side preparation, status, staging-input, and lab-feed
  work.
- Runtime, artifact, catalog, admission, receipt, and settlement contracts have
  changed since the original #1658 head. Fresh tests and full-diff audits are
  required; historical green results are supporting evidence only.

## Execution Milestones

### M0 - Recover PR #1658 on current main

- Rebuild the branch from current `origin/main` in a fresh hidden worktree.
- Preserve current-main status and runtime fields when resolving conflicts.
- Port the private preparation record, status correlation, staging-input, and
  measured lab-feed helper.
- Omit superseded coordinator changes and stale conformance evidence edits.
- Update #1658 and #1642 so the private-tuple acceptance correction is visible.

Stop condition: current-base provider-side code builds, focused tests and SPEC
governance pass, the PR is reviewable, and no physical acceptance is claimed.

### M1 - Prove the Llama plumbing control

- Generate signed, measured staging artifact authority for the Llama tuple.
- Run `models prepare`, private-record verification, local status correlation,
  and `models staging-input` on physical Apple Silicon.
- Treat this as implementation preflight only.

Stop condition: a redacted control bundle proves the mechanics and records any
defects without claiming final Build 1 acceptance.

### M2 - Pin the private acceptance tuple

Record one exact private tuple before implementing or running acceptance:

- provider/model identifier and revision;
- runtime format and source kind;
- artifact identifier;
- snapshot-manifest algorithm and digest;
- measured positive size;
- staging release and signer identity;
- evidence that the tuple is not present in the active public catalog.

The authority must be source-reviewable without exposing private credentials,
repository access tokens, local paths, or private key material.

Stop condition: the tuple and authority are deterministic inputs to tests and
the physical journey. A placeholder or arbitrary runtime-selected model does
not satisfy this milestone.

### M3 - Extend the guarded path to the private tuple

- Reuse the durable store, private preparation store, receipt, and status
  correlation contracts recovered in M0.
- Keep the Llama control profile available only as control evidence.
- Accept the private tuple only through explicit staging profile selection and
  verified signed authority; do not create general arbitrary-repository
  preparation.
- Preserve public `models catalog-economics --json` v1 compatibility.
- Fail closed for catalog presence, identity drift, stale authority, signer or
  release mismatch, unmeasured size, unsupported runtime, and status mismatch.

Stop condition: targeted tests prove the control tuple and private tuple cannot
be confused and neither grants admission, settlement, or production status.

### M4 - Physical private-tuple preparation and serving

- Prepare, verify, durably adopt, and serve the private tuple on physical Apple
  Silicon.
- Capture transaction events, private receipt digests, binary identity, local
  status, model hash, weights-manifest evidence, and the runtime proof boundary.
- Use an isolated provider port and do not disturb the live `127.0.0.1:8080`
  provider.

An unsigned, ad-hoc-signed, locally built, or unreleased CLI must not connect to
the live Malibu coordinator. Local builds may use `--no-join` or a local
coordinator/gateway stack. Live network proof requires an appropriately
reviewed and signed release candidate explicitly authorized for that path.

### M5 - Staging admission and gateway routing

- Use the reviewed staging candidate to obtain exact-tuple coordinator
  admission.
- Route one non-streaming gateway request to the physical provider.
- Capture request, route, provider, model, artifact, and binary identities.
- Keep production activation, rewards, and payouts disabled.

### M6 - Receipt, audit, settlement, and evidence validation

- Correlate the gateway request to provider receipt/audit evidence by request
  id and provider identity.
- Retrieve verified settlement output for the same request.
- Produce a redacted bundle containing the signed authority, preparation
  events, status, admission, gateway response, receipt/audit evidence,
  settlement output, source digests, and validator report.

Skipped, timed-out, fixture-only, local-only, simulated, or validator-only
evidence is non-proof.

### M7 - Final landing gate

- Run relevant Swift, Go, script, integration, governance, and diff-hygiene
  checks on the final head.
- Run code, security, and architecture audits over the complete final diff.
- Resolve every Critical, High, and Medium finding.
- Obtain fresh green CI, update #1642 with evidence links, and obtain explicit
  owner greenlight before merging #1658.

## Current Next Action

Complete M0. Do not begin the hardware campaign from the stale #1658 branch and
do not connect a branch-built CLI to the live Malibu coordinator. Once the
current-base recovery is reviewable, use the Llama control to validate the
provider-side mechanics before pinning and implementing the private acceptance
tuple.

## Final Stop Condition

Build 1 Lane A is complete only when a schema-valid, source-reviewable bundle
proves the pinned non-catalog/private tuple was prepared and served on physical
Apple Silicon, admitted through the approved staging path, routed through the
staging gateway, correlated to provider receipt/audit evidence, and verified
through settlement output, while production activation, public catalog
publication, rewards, payouts, public earnings claims, and automatic paid
provider qualification remain disabled.
