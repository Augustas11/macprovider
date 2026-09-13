# Build 1 preparation private store acceptance report v1

Base revision: `4f388d67e23f9aa02a386aef60b225632a722b11`.
Branch: `codex/build1-preparation-runtime-v2`.
Scope: Build 1 local preparation private-store foundation only.

## Newly implemented in this slice

- `ModelPreparationSecureFilesystem` provides descriptor-relative private directory/file helpers for the preparation store.
- `ModelPreparationPrivateStore` bootstraps the authority root, lock files, artifact namespace, raw `root.identity`, and the private `state/` directory.
- Seven private state envelope kinds can be written under `authorityRoot/state/` with live lock custody, root binding, monotonic generations, same-parent temp-to-final rename, fsync barriers, and final readback.
- Lockless reads reopen and validate authority/artifact/root identity/state descriptors, then return only validated payload bytes.
- Conservative recovery scans only `authorityRoot/state/`, never promotes temps, and removes only empty or stale recognized sibling temps after a complete safe scan.
- Caller-controlled path traversal now rejects same-user traversable ancestors that are group/world writable or carry extended ACLs before children are created.

## Explicit non-goals and qualification blockers

This slice does not implement artifact-feed consumption, trusted artifact preparation UX, CLI/app actions, runtime adoption, coordinator admission/probes, pricing authority, billing, settlement, rewards, or physical Mac acceptance. Those remain Build 1 downstream slices and must be separately planned, audited, implemented, and tested.

This slice does not qualify Build 1 product acceptance. Physical Mac preparation -> admission -> correctly settled request remains blocked until the non-overlapping BYOM v0.2 work and subsequent Build 1 CLI/runtime/coordinator/economics slices land and pass their own gates.

## Local acceptance evidence

- `cd phase3-binary && swift test --filter ModelPreparationRootTests`
  - Passed: 6 tests, 0 failures.
- `cd phase3-binary && swift test --filter ModelPreparationPrivateStoreTests`
  - Passed: 10 tests, 0 failures.
- `cd phase3-binary && swift test --filter ModelPreparation`
  - Passed: 44 tests, 0 failures.
- `git diff --check`
  - Clean.

## Independent review evidence

Plan gate:

- v1: rejected by Sol review.
- v2: rejected by Sol review.
- v3: passed with zero Critical/High/Medium findings.

Implementation gate:

- Code audit: PASS, zero Critical/High/Medium findings.
- Security audit: PASS, zero Critical/High/Medium findings.
- Architecture audit: PASS, zero Critical/High/Medium findings.

Durable audit record: `docs/product-roadmap/build-1/reviews/preparation-private-store-implementation-audit-v1.md`.
