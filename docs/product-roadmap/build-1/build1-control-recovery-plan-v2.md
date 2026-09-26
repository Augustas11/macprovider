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
  `mlx-community/Llama-3.2-3B-Instruct-4bit` is retained only as legacy
  regression scaffolding. It gets no physical hardware campaign and produces
  no Build 1 progress evidence.
- The Build 1 execution and acceptance tuple is
  `orcarouter/qwen3.8-27b-uncensored` /
  `orcarouter/Qwen3.8-27B-Uncensored-MLX` at revision
  `38d0ad4e02031658fadd3828634a0174e0b8a282`.
- The acceptance tuple is absent from the active public catalog and must be
  carried by signed, measured staging authority. It must not be added to the
  public catalog as part of Build 1.

The selected surface remains standalone `macprovider-cli` on physical Apple
Silicon. Production activation, public catalog publication, rewards, payouts,
public earnings claims, and automatic paid-provider qualification remain
disabled.

## Current Repository Truth

- PR #1649 landed guarded staging, verification, and durable adoption for the
  Llama regression tuple.
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

### M1 - Retire the catalog Llama campaign

- Do not run the public-catalog Llama tuple on physical hardware for Build 1.
- Keep its existing tests only where they protect recovered preparation,
  private-record, status-correlation, and staging-input behavior.
- Do not generate or promote Llama campaign evidence.

Stop condition: no execution milestone or evidence gate depends on Llama.

### M2 - Pin the private acceptance tuple

Status: complete on the PR head; physical-byte verification remains part of M4.

The selected acceptance tuple is:

- model key: `orcarouter/qwen3.8-27b-uncensored`;
- model repository: `orcarouter/Qwen3.8-27B-Uncensored-MLX`;
- revision: `38d0ad4e02031658fadd3828634a0174e0b8a282`;
- runtime format: `mlx_safetensors` through native MLX;
- source kind: `huggingface_revision`;
- artifact identifier: `mlx-revision-snapshot`;
- artifact scope: the complete pinned revision snapshot;
- snapshot-manifest algorithm: `macprovider.snapshot-manifest.v1`.

The pinned Hugging Face revision contains 80 files totaling 94,723,099,062
bytes. Its deterministic complete-revision `macprovider.snapshot-manifest.v1`
digest is
`8794a87d2041dce5e915809d9e6c16da709d1763e25c4289f279d929aea88dcd`.
The signed repository authority records:

- release `build1-orcarouter-private-2026-09-26-v1`;
- signer `streamvc-autotune-static-v4`;
- the active candidate-catalog byte digest and release;
- a 2026-09-26 catalog-absence check for the exact private model key;
- explicit false values for admission, settlement, production activation,
  public catalog publication, rewards, and payouts.

The authority must be source-reviewable without exposing private credentials,
repository access tokens, local paths, or private key material.

Stop condition: the tuple and authority are deterministic inputs to tests and
the physical journey. A placeholder or arbitrary runtime-selected model does
not satisfy this milestone.

### M3 - Extend the guarded path to the private tuple

Status: implementation and hermetic verification complete on the PR head;
Mac Studio execution is intentionally deferred to M4.

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

The `build1-orcarouter-private` prepare profile now requires the signed local
authority and detached signature, accepts only the exact Qwen tuple, rejects
all coordinator URLs, revalidates authority before durable publication, and
reuses the existing verified staging, durable adoption, private receipt, and
status contracts. The Llama profile remains a separate regression-only path.

### M4 - Physical private-tuple preparation and serving

- This development Mac is planning, implementation, build, and hermetic-test
  only. It cannot provide Build 1 physical or end-to-end evidence.
- Run every physical and end-to-end step exclusively on the designated Mac
  Studio.
- Treat the Mac Studio as an active production-like host because it is already
  running the live provider. Inventory and record the live provider binary
  provenance, coordinator target, process identity, launch mechanism, ports,
  model, current health, free disk, memory headroom, and rollback command before
  installing, staging, starting, stopping, or replacing anything.
- Prepare, verify, durably adopt, and serve the private tuple on the Mac Studio
  only after the authority and host preflight gates pass.
- Capture transaction events, private receipt digests, binary identity, local
  status, model hash, weights-manifest evidence, and the runtime proof boundary.
- Keep the campaign provider isolated from the live `127.0.0.1:8080` provider:
  separate process, port, state/cache roots, logs, credentials, and coordinator
  target. Start with `--no-join` or a local coordinator/gateway stack.
- Do not stop, restart, replace, reconfigure, or resource-starve the live
  provider. If the Mac Studio lacks capacity to run both safely, stop the
  campaign and schedule an explicitly authorized maintenance transition with a
  tested rollback; do not improvise an in-place swap.

An unsigned, ad-hoc-signed, locally built, or unreleased CLI must not connect to
the live Malibu coordinator. Local builds may use `--no-join` or a local
coordinator/gateway stack. Live network proof requires an appropriately
reviewed and signed release candidate explicitly authorized for that path.

Mac Studio preflight stop condition: the live provider remains healthy and
unchanged, the campaign has sufficient isolated disk/memory/ports, the exact
rollback path is recorded and tested without touching live traffic, and the
candidate provenance/coordinator pairing is allowed. Any failed or uncertain
check blocks M4.

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

Freeze and audit the M2/M3 diff, obtain one uninterrupted green CI run, then
perform the read-only Mac Studio M4 preflight. Do not run a Llama hardware
preflight. Do not connect a branch-built CLI to the live Malibu coordinator.
This development Mac must not be used for E2E. The Mac Studio campaign may
start only after separate ports, roots, logs, credentials, coordinator target,
disk and memory headroom, live-provider health monitoring, and a no-touch
rollback boundary are recorded and pass.

## Final Stop Condition

Build 1 Lane A is complete only when a schema-valid, source-reviewable bundle
proves the pinned non-catalog/private tuple was prepared and served on physical
Apple Silicon, admitted through the approved staging path, routed through the
staging gateway, correlated to provider receipt/audit evidence, and verified
through settlement output, while production activation, public catalog
publication, rewards, payouts, public earnings claims, and automatic paid
provider qualification remain disabled.
