# Build 1 preparation private store plan v2 — Sol adversarial review

Reviewer: native Codex subagent `gpt-5.6-sol`, high reasoning.
Result: rejected. Gate criterion was not met: 0 Critical, 0 High, 2 Medium.

## Medium

- M-1: private state final-file layout was underspecified and conflicted with same-parent temp writes. Required correction: specify exact descriptor-relative final state directory and temp naming convention; update tests to assert exact paths and reject cross-root/cross-parent temp-to-final writes.
- M-2: read custody requirement contradicted proposed `readRecord(kind:rootLocator:)` API and tests. Required correction: either make reads custody-bound or explicitly define lockless read descriptor validation and align tests.

## Disposition in v3

- M-1 resolved by defining `authorityRoot/state/<leaf>` as the only final state layout, with temp siblings named `<targetLeaf>.<writerUUID>.tmp`, and rejecting `state-tmp`/cross-parent writes.
- M-2 resolved by defining reads as lockless descriptor-validation operations that reopen authority/artifact/root identity/final state and never repair or mutate, while write/recovery require lock custody.
