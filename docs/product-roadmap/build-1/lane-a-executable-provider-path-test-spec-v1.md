# Build 1 Lane A executable provider path test spec v1

Status: selected planning test spec. No executable behavior is changed by this
document.
Date: 2026-09-15.
Branch: `codex/build1-lane-a-provider-path`.
Base: `origin/main` at `e7213fa1`.

## Scope

This test spec covers the selected Lane A provider path from
`lane-a-executable-provider-path-prd-v1.md`. The current PR is docs-only. Future
implementation PRs must use this spec to decide which tests and evidence are
required for the slice they touch.

The lane is staging-only and limited to
`meta-llama/llama-3.2-3b-instruct` with
`mlx-community/Llama-3.2-3B-Instruct-4bit`. It excludes production activation,
rewards, payout, public earnings claims, general BYOM, and app UI.

## Required Checks For This PR

1. `git diff --check`
   - Must report no whitespace errors.
2. Spec governance validator using the PR body event against `origin/main`.
   - Must accept the governance declaration for this docs-only planning change.

No Swift, Go, shell, Python, staging, or audit-gate implementation tests are
required for this PR because it changes no executable code.

## Future Local Test Matrix

Future implementation PRs must choose the smallest relevant subset from this
matrix and explain any omitted groups.

- CLI parse and guard tests for `models prepare`: exact Lane A tuple only,
  staging coordinator only, `--yes` required for mutation, JSON output stable,
  no production URL acceptance, no rewards/payout fields, no private path leaks.
- Catalog-economics projection tests: the Lane A row exposes preparation only
  when artifact authority, storage budget, and tuple identity are valid; all
  other rows and invalid states fail closed; v1 public JSON remains compatible.
- Artifact-feed tests: corrupt feed, bad signature, wrong signer, stale feed,
  missing primary artifact, unsupported runtime, wrong model id, wrong artifact,
  null/non-positive size, hash mismatch, and cross-release identity mismatch all
  block preparation.
- Preparation transaction tests: staging directory creation, measured byte
  accounting, manifest/hash validation, durable-store adoption, private-store
  record write/read, event JSONL order, cancellation before verification,
  cancellation after staging, interrupted-run recovery, and cleanup of abandoned
  temporaries.
- Runtime/status tests: `serve` uses the durable artifact path and exposes the
  selected model, artifact digest, snapshot/weights manifest evidence, process
  identity, and binary/version fields expected by the evidence validator.
- Admission tests: coordinator status binds the exact candidate/model/catalog
  identity; rejected, stale, future, cross-candidate, cross-model, and
  cross-catalog statuses remain non-actionable and do not imply settlement.
- Receipt/settlement tests: one non-streaming request can be correlated by
  request id, provider id, model id, token counts, receipt/audit event, gateway
  response, and settlement retrieval.
- Evidence-driver tests: generated bundles redact local private paths and
  secrets, reject fixture-only claims as physical acceptance, preserve source
  capture digests, and pass the existing Build 1 narrow MVP validator only when
  the required files are present.

## Candidate Commands

Exact commands may change during implementation, but the proof shape must stay
stable:

```bash
cd phase3-binary
swift test --filter 'ModelCatalogEconomicsTests|ModelsSubcommandTests|AutotuneArtifactFeedTests|DurableModelArtifactStoreTests|ModelPreparationPrivateStoreTests|ModelPreparationPrivateCodecTests|BYOMAdmissionTests'
```

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_build1_narrow_mvp_evidence
```

```bash
make test-coordinator
make test-gateway
make test-integration
```

Implementation PRs do not need every broad command when the touched surface is
narrow, but physical acceptance cannot be claimed without the staging journey
below.

## Physical Staging Acceptance

Build 1 Lane A is accepted only when a real Apple Silicon staging provider
produces a redacted evidence bundle containing all of the following:

1. Signed artifact-feed capture for the approved tuple.
2. Local preparation transaction events from request through durable adoption.
3. Local status capture proving the running provider uses the adopted artifact.
4. Staging coordinator admission/status capture for the same candidate/model.
5. Staging gateway non-streaming buyer request/response.
6. Provider receipt/audit capture correlated to the gateway request.
7. Verified settlement retrieval for that request.
8. Validator report over the bundle, plus source capture digests.

Skipped, timed-out, simulated, fixture-only, or validator-only evidence is
non-proof.

## Audit Gate

This docs-only PR does not require the implementation audit gate. Any future PR
that changes executable Swift, Go, shell, Python, release, workflow, schema, or
runtime behavior must run code, security, and architecture review lanes over the
complete diff. The gate remains zero Critical, zero High, and zero Medium
findings.

## Stop Conditions

- This PR stops after docs validation and governance validation pass.
- A future implementation PR stops after its selected tests pass and its
  remaining blockers are written down.
- The Build 1 Lane A product journey stops only after physical staging
  acceptance evidence is collected and validated without crossing the
  production, rewards, payout, or public-earnings boundary.
