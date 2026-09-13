# Build 1 preparation contracts — PR 1491 rebase handoff

## Scope

This artifact records the non-overlapping Build 1 preparation-contract slice resumed after PR #1501 merged.

Base for this slice after clean rebaseline: `origin/main` at `14e0159f` (`Require measured runtime evidence before SPEC-038 attach`).
Historical PR head inspected: PR #1491 `b310e06e9a58b2328d3509425a4d0c9663875f9c`.
Local working branch: `codex/build1-preparation-runtime-rebased` in `/Users/augstar/.codex/worktrees/macprovider/build1-next-rebaseline`, reset to current `origin/main` before restoring only this contract slice.

The prior v22 reservation/preparation plan and test specification remain the applicable plan gate for this correction. PR #1501 changed coordinator rate-card/runtime billing parity and demoted the signed journey conformance items to pending; it did not change the Swift preparation private-state contracts covered by the v22 gate.

## Corrections implemented in this slice

- Replaced the unauthoritative draft cleanup/reservation/private-state shapes with v22 contract codecs:
  - `model_catalog_reservation.v4` with source-bound cleanup-staging branches and `model_catalog_reservations_history.v1` / `model_catalog_terminal_history.v1`;
  - kind-bound `model_catalog_private_state_envelope.v1` payload validation;
  - second-precision `model_catalog_cancel_marker.v1` timestamps;
  - closed `model_catalog_cleanup_record.v2` variants:
    - staging cleanup uses source transaction/attempt/source-record identity and never carries publication receipts;
    - published cleanup uses receipt SHA and artifact identity digest and never carries staging source identity.
- Bound cleanup leaves to v22 paths:
  - staging: `work/staging/<source_transaction_id>/<source_attempt_id>` and `work/staging/<source_transaction_id>/.tombstone-<cleanup_transaction_id>`;
  - published: `objects/<artifact_identity_digest>` and `objects/.tombstone-<cleanup_transaction_id>`.
- Added durable private cancellation and staging-source contract records:
  - `model_catalog_cancel_marker.v1`;
  - `model_catalog_staging_source.v1`;
  - `model_catalog_staging_sources.v1`.
- Expanded the private-state envelope inventory from five to seven record kinds:
  - `reservations`, `active`, `cancel`, `published_inventory`, `deletion`, `staging_sources`, `failed_dispatch_pending`.
- Updated the generic JSON shape allowlist so the new closed contract shapes are validated before typed decode.
- Added expected-type and parent-context raw-key checks for schema-less registry entries so a full reservation or cleanup record cannot be silently decoded as a `staging_sources.entries[]` item.
- Added a bounded JSON nesting limit to the raw duplicate-key scanner and recursive shape validator so malformed local state fails closed before typed decode.
- Added explicit-null encoders and round-trip tests for cleanup targets and terminal results whose decoders require present nullable fields.
- Tightened present progress payloads so `bytes_expected` cannot be the only live progress signal while preserving nullable progress on nonterminal events.
- Preserved SPEC-044 public timestamp compatibility by accepting RFC3339 timestamps for transaction events and cancel acknowledgements while keeping fixed second-precision timestamps only for private cancel markers.
- Added raw-byte publication receipt validation: top-level receipt and cleanup-record decodes must match the contract encoder's canonical bytes before their receipt SHA/artifact identity binding is accepted; descriptor-read callers can use `publicationReceiptSHA256(from:)` to hash validated raw receipt bytes.
- Added reservations-history cross-array immutable identity checks when a terminal entry shares a projected reservation transaction ID.
- Resolved the round-3 architecture Medium finding by adding schema-specific raw-key validation for `model_catalog_failed_dispatch.v1` and `model_catalog_terminal_history.v1`, with regressions proving a failed-dispatch record carrying terminal-history-only `completed_at` is rejected through direct decode, reservations-history union decode, and `failed_dispatch_pending` private-state envelope validation.

## Fresh local verification

Run from `/Users/augstar/.codex/worktrees/macprovider/build1-next-rebaseline/phase3-binary`:

```bash
swift test --filter ModelPreparationPrivateCodecTests
```

Result on 2026-09-13 after the final validator hardening, clean rebaseline, and timestamp/receipt architecture fixes: passed, `Executed 28 tests, with 0 failures (0 unexpected)`. The final run covered RFC3339 public event/ack timestamps, RFC3339 non-marker durable timestamps, invalid calendar/clock/offset rejection, duplicate-key isolation, and raw-byte publication receipt canonicalization.

`git diff --check origin/main` passed after the final timestamp fixes. Unrelated SwiftPM `Package.resolved` churn was restored before handoff.

## Not proven by this slice

This slice is contract/codec-only. It does not prove runtime worker adoption, durable storage integration, coordinator admission, settlement, or the physical Mac journey required for Build 1 acceptance. The signed journey conformance items demoted by PR #1501 remain pending until fresh end-to-end evidence exists.
