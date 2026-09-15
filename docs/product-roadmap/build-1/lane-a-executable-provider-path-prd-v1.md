# Build 1 Lane A executable provider path PRD v1

Status: selected planning artifact. No executable behavior is changed by this
document.
Date: 2026-09-15.
Branch: `codex/build1-lane-a-provider-path`.
Base: `origin/main` at `e7213fa1`.

## Decision

Build 1 continues on Lane A from the control ledger: a single physical staging
provider path for `meta-llama/llama-3.2-3b-instruct` using the
`mlx-community/Llama-3.2-3B-Instruct-4bit` artifact. The selected executable
surface is the standalone `macprovider-cli` staging journey, not Malibu app UI,
buyer portal UI, production coordinator activation, rewards, payout, or a
general BYOM workflow.

The next implementation work must make this exact path executable and
evidence-producing:

1. `macprovider-cli models catalog-economics --json` identifies the Lane A row,
   its artifact authority, storage state, admission state, and blocking reasons.
2. `macprovider-cli models prepare <catalog-key> --profile build1-lane-a
   --coordinator-url <staging> --json --yes` verifies the signed artifact feed,
   stages the exact MLX snapshot, validates the snapshot manifest/hash, adopts
   it into the provider-owned durable store, records private preparation state,
   and emits a transaction JSONL event stream.
3. `macprovider-cli serve` runs or reloads using the durable artifact path and
   exposes local status that includes the exact model, artifact identity, and
   weights/snapshot manifest evidence needed by the staging validator.
4. `macprovider-cli models admission status` or the existing offer/status flow
   proves coordinator admission against staging only.
5. One non-streaming buyer request through the staging gateway proves the
   physical MLX runtime, provider receipt/audit correlation, and verified
   settlement retrieval for the selected tuple.
6. The evidence driver captures a redacted bundle that the Build 1 narrow MVP
   evidence validator can structurally validate. Validator success is not
   physical acceptance unless the source captures are from the real staging
   journey above.

## Requirement Sources

- `build1-control-recovery-plan-v1.md` freezes new implementation until the
  work names one lane, states the proof boundary, and starts with this PRD plus
  test spec.
- `narrow-mvp-plan-v6.md` defines the Build 1 target: one staging provider, one
  approved MLX model/artifact/rate row, staging enforcement, and no production,
  reward, payout, or public-earnings activation.
- `narrow-mvp-test-spec-v6.md` defines the physical acceptance bar and rejects
  skipped, timed-out, fixture-only, or validator-only evidence.
- `SPEC-044` owns the Malibu model economics UX and preparation-action
  contract. Preparation is locally motivated provider custody; it must not imply
  paid admission or earnings.
- `SPEC-023`, `SPEC-047`, and `SPEC-005` remain authority sources for artifact
  feed trust, admission, and settlement/rate behavior where this path touches
  those domains.

## Current Anchors

- `ModelsSubcommand.swift` has public `models catalog-economics`,
  `models admission`, `models offer`, `models switch`, and
  `models adopt-recommendation` surfaces, but no public `models prepare`
  transaction.
- `ModelCatalogEconomics.swift` has v2 preparation/action data structures and
  storage projection fields, but preparation actions still fail closed.
- `AutotuneArtifactFeed.swift` decodes artifact-feed entries with MLX runtime
  identity, hash, source reference, size, and verification status.
- `DurableModelArtifactStore.swift` can adopt a verified staged artifact into
  provider-owned durable storage.
- `ModelPreparationPrivateStore.swift` can persist private preparation state
  outside the public projection.
- `CandidateProviderRunner.swift` can construct a no-join candidate `serve`
  invocation with model artifact path/hash inputs, but it is not the full
  provider acceptance path by itself.
- `ReceiptAudit.swift` emits receipt correlation fields needed by the evidence
  bundle.

## Implementation Scope

Future implementation may touch the Swift CLI preparation path, artifact-feed
loading, durable/private preparation stores, catalog-economics v2 action
availability, local status evidence fields, and a Build 1 evidence driver. It
may add targeted tests around those surfaces.

Future implementation must not activate production enforcement, production
rate-card exposure, rewards, payout jobs, payout wallets, public earnings copy,
or broad model preparation. The only model/artifact accepted for Lane A is the
approved tuple above.

## Proof Boundary

This PRD proves only the selected executable path. It does not prove that Build
1 works.

A future code PR proves implementation readiness only after local tests pass.
Build 1 acceptance is proved only by a physical Apple Silicon staging run that
prepares the exact artifact, serves it, admits it, routes a real gateway request,
correlates provider receipt/audit evidence, and retrieves verified settlement.

Preparation alone is not admission. Admission alone is not settlement. A valid
validator report without physical source captures is not acceptance.

## Acceptance Criteria

- The selected Build 1 lane is Lane A and the selected execution surface is the
  standalone `macprovider-cli` staging path.
- Future slices can be mapped to a blocker in this PRD, the control ledger, or
  the v6 narrow MVP plan/test spec.
- The no-production boundary is explicit and testable.
- Evidence requirements distinguish proof from non-proof.
- This PRD and its paired test spec are merged before further Lane A
  implementation begins.

## Planned Sequence

1. Add the narrow `models prepare` transaction and keep it unavailable unless
   the exact Lane A tuple, staging coordinator, signed artifact authority, and
   explicit `--yes` confirmation are present.
2. Wire live artifact-feed and durable/private-store adoption evidence, with
   negative tests for every trust and identity mismatch.
3. Add or update the evidence driver and perform the physical staging run.

These are not authorization for endless slices. Each follow-up PR must close a
named blocker, preserve the proof boundary, and stop once its evidence is
collected.

## Rollback

Rollback for future implementation is to hide or remove the Lane A profile and
`models prepare` transaction while preserving existing public
`models catalog-economics` v1 behavior. This document has no runtime rollback
because it changes no executable behavior.

## Stop Condition

This planning gate is complete when this PRD and
`lane-a-executable-provider-path-test-spec-v1.md` are merged. The next allowed
Build 1 slice is the smallest implementation PR that makes the first part of
the selected CLI path executable under staging-only guards.
