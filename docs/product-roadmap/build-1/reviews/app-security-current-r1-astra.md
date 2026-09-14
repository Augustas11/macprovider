# Build 1 preliminary app security review — current r1

Date: 2026-09-10. Independent native security lane.
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`.
Branch: `codex/product-build-1`.

**Verdict: 0 Critical, 0 High, 1 Medium, 1 Low. The scoped security gate is not clear.**
This is a preliminary review of the frozen app surface, including every tracked
change and untracked file under `phase3-binary/app` against the supplied base.
It does **not** replace the final complete combined code, security and architecture
audits. Concurrent CLI transaction-binding implementation is not a final reviewed
snapshot. No source edits, new tests, runtime executions or recursive agents were
performed. Only this report was written.

## APP-SEC-M1 — Orphan disposal can follow a pending unlink whose durability failed

**Severity:** Medium. **Confidence:** high in the control-flow defect; the crash
outcome is an inference from the missing persistence barrier, not an observed
power-loss experiment.

**Evidence:** `ModelTransactionControl.swift:216–238` retires and syncs the intact
payload, then calls `saveLocked(nil)`. At `:293–294`, that function unlinks
`pending.json` before syncing its parent. If the parent sync throws, there is no
restoration or durable-absence recovery branch. The pending pathname is already
absent in the running filesystem despite the unsuccessful durability operation.
`ModelManagement.swift:2168–2175` retries completion by treating `absentPending`
alone as success; it does not retry the failed parent sync. Independently,
`ModelTransactionControl.swift:252–287` permits orphan disposal using pathname
absence alone and syncs only the `executables` root afterward. `removePartial`
likewise syncs the payload's parent, not the directory containing pending.

**Trigger and consequence:**

1. A verified terminal operation retires its payload and successfully persists
   that rename.
2. Pending unlink succeeds, but syncing `ModelTransactions` fails (or the app
   dies before that sync and another app instance observes the still-cached
   absence).
3. Completion retry or a replacement app accepts absence. A fresh authorization
   reclaims the retired payload before any successful sync establishes durable
   pending removal.
4. A subsequent storage/system crash can preserve retired deletion while losing
   the unsynced pending unlink. Recovery can then find the old pending record
   without either intact payload. This strands exact recovery custody after the
   app has accepted completion; it does not authorize arbitrary execution or
   create payment authority.

The approved resource r2 contract explicitly makes pending-removal durability a
prerequisite for deleting retired contents and calls for preserving/restoring the
intact payload on pending-clear failure. The current error path does not uphold
that ordering. `clear` also falls through to pending deletion when both active
and retired are absent (`:223–232`), rather than validating intact custody.

**Required correction:** Make completion retries and no-pending orphan disposal
establish durable pending absence under the fixed metadata/control locks before
any payload deletion or completion claim. Preserve the intact payload when that
barrier fails; implement the approved failure/restoration behavior without
converting an uncertain pending write/removal into authorization. Reject the
missing-both-payload case for an extant pending record. An absence check alone is
not the persistence barrier.

**Required regression evidence:** Inject failure after pending unlink and before
its parent sync, retry completion, and attempt orphan maintenance/new capture
from another instance. Assert no retired member is removed until pending absence
has been made durable, and failure retains recoverable intact custody. Cover the
crash-equivalent old-pending/intact-retired state and missing-both case.
`ModelManagementTests.swift:2570–2594` currently injects only immediately after
retirement, before pending unlink; it does not cover this boundary.

## APP-SEC-L1 — Complete bundle inventory does not require bundle metadata

**Severity:** Low. **Confidence:** high.

**Evidence:** `ModelTransactionPayload.swift:73–77` requires one known bundle
directory but no `Info.plist` in a present bundle. An empty known bundle passes
that complete predicate when the other mandatory files are present. The common
fixture at `ModelManagementTests.swift:2514–2516` contains a NIO privacy file but
no Info.plist, and is treated as complete by the capture/retirement tests.

**Consequence:** Complete capture can freeze a partially constructed bundle as
its original pin. This weakens the intended distinction between complete
execution resources and deletion-only subsets: resource r2 (`snapshot-resources-r2.md:309–312`) specifically permits
missing Info.plist only for disposal. The required adjacent metallib and strict
native signature remain enforced, so this is not evidence of native-code or
feed-authority injection.

**Required correction:** Enforce the approved required metadata for every
selected bundle and cover valid flat and Contents layouts plus missing metadata
negatives. If a real released data bundle intentionally has no Info.plist,
resolve that concrete layout in the approved resource contract rather than
silently treating every empty bundle as complete. Keep incomplete bundles
eligible only for the separate no-pending disposal predicate.

## Security assessment and test adequacy

The implementation retains meaningful boundaries: production Apple anchor,
team, identifier and CDHash validation; fresh live PID identity for initial
owners; no pending-selected executable destination; exact UUID/target/key/kind/
generation binding; config inode/hash and opaque context expectation; no-follow,
single-link and owner/ACL checks; bounded 64 KiB resource streaming, count/depth/
byte limits and a closed selected resource closure. Destination hashes/native
identity and final source identity/bytes are checked before publication. Resource
hashes freeze installed bytes within the trusted operator-UID boundary; they do
not mint catalog/feed/coordinator authority. No observed app change promotes local
preparation into pricing, admission or settled credit.

The retained serial worker and independent timeout completion bound resource
preflight concurrency and reject late validation results. Controls inherit the
same flock description and use private context/lifetime descriptors; the normal
spawn loop bounds control output and terminates/reaps only its exact short child.
Mutation owners are not signaled. Queued cancellation stays visibly pending.
The adjacent CLI control-lease source was read as interface context only; final
config-consumption, early guardian and operation-generation composition must be
reviewed at the final combined snapshot.

Ordinary result restoration without pending is explicitly permitted by control
r4 on a fresh live peer and newly validated exact adoption selector; it is not
counted as an offline-control bypass. Existing general-runner supervision is a
different path from the new pinned offline-control launcher. No new claim about
its full process-lifetime qualification is made here.

The 13 resource tests provide useful capture/mutation/link/oversize/partial-tree,
retirement, worker timeout, real Metal and MLX evidence. They do not exhaust the
approved SR-04/SR-09/SR-10/SR-11 obligations: the post-unlink fsync boundary above,
all publication/pending-write cutoffs, signature/snapshot pause seams, committed
spawn races, and every unlink/rmdir interruption are not established by these
fixtures. The worker tests exercise scan plus an authorization marker, not an
actual late authorizeCatalog/runCatalog spawn. The Metal test loads via the test
process using an explicit copied URL; the separate MLX helper supplies stronger
actual executable-adjacency evidence. Neither substitutes for production-signed
owner/control/candidate execution. The implementation report accurately leaves
signed production, actual-model, incumbent lifecycle and settled-credit
qualification separate. Those gaps remain outside any zero-finding assertion.

Startup still calls the bounded pending-file loader synchronously from the
MainActor initializer (`ModelManagement.swift:1675`). This is not bulk payload
hashing, but its filesystem syscall can delay initialization; the off-main
resource-worker timeout evidence does not cover it.

## Verification performed

- Read repository AGENTS.md and CLAUDE.md; reviewed all changed/untracked app
  files listed below and the relevant approved contracts and test evidence.
- Exact plan/test/control/resource SHA-256 values match their independent review
  and gate-log declarations. Their older historical plan base is not substituted
  for the explicit implementation-review base above.
- `git diff --check -- phase3-binary/app`: exit 0.
- Independently read the existing `/tmp/build1-app-resources-full.log`: Xcode
  reports **638 tests, 0 failures**, including **13 resource tests**, and
  `TEST SUCCEEDED`. SHA-256 matches implementation-app.md:
  `9528c99383b5d8e0c01e0b084889b43564e1656dff7a96efc3b7dac80892809e`.
  This review did not rerun Xcode or independently reproduce those tests.
- No d-inference source or operator secrets were inspected.

## Reviewed source hash manifest

SHA-256 of the following canonical `hash  relative-path\n` source manifest:
`590e37c6f961c81d2ad5a661d5f051e7609ec6daca1974d8074fed32026d241f`.

```text
fbdeea7430c45f8d953f958f718778537e96bcf11de1b77882ab522369912410  phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift
d58e93591efd68cdfdc36818e5cac84cbe23e4140f07074ae060033d2f1d7d98  phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagementViews.swift
07576b421a9a438433f3e8ade15f5451ebe8dde65a15c9839229850edf201aa2  phase3-binary/app/Sources/Malibu/ModelManagement/ModelTransactionControl.swift
d7232fe2cd5dd02ef41782b8f5c61433749fe230e40962f5d53c029774af862d  phase3-binary/app/Sources/Malibu/ModelManagement/ModelTransactionPayload.swift
f11ecc5074ffc7f8bbd617e3f7c5872778c0ea861acf4a733e62c20d5d1c3a4b  phase3-binary/app/Sources/Malibu/ModelManagement/ModelTransactionRequest.swift
5314cf4664e3624f0740b0032f19db2c50cdfbacbcd15672c006277322fdc602  phase3-binary/app/Sources/Malibu/ModelManagement/RecommendationManagement.swift
ed349d9b79104fea56863db7b476f2e7086ece83203c32b71e19c3ab7144ff58  phase3-binary/app/Sources/Malibu/Resources/MalibuFeature.xcstrings
0651a6561ca428d1e8a404c6cac7351423c24af24c9b0d5e1b9b3a6c136e8227  phase3-binary/app/Sources/Malibu/Resources/MalibuModelCapabilities.json
dc94845a00212cd25a2ce8f2a45d4861ac70d92d125717d50224ea27041c0517  phase3-binary/app/Sources/Malibu/System/InstalledProviderMonitor.swift
f0e5da43b5d025020f0b4d4813b90cc534a636604963001dbdbac5a6bdf85d72  phase3-binary/app/Tests/MalibuTests/ModelManagementTests.swift
```

## Contract and adjacent read-context hashes

The CLI context hash records the bytes available during this preliminary read;
concurrent CLI work is explicitly outside the frozen app verdict.

| File | SHA-256 |
|---|---|
| `AGENTS.md` | `18a1a8ff354354d51612fd424fc9fdf3b5df6a9fd036a7a82a75a99cc5ba2a29` |
| `CLAUDE.md` | `a2bb6aafa9d938a0602a7990a72090180ae8178e07e42a574d3779f9aec5cda8` |
| `docs/product-roadmap/build-1/plan-r4.md` | `a5c7a56a68d3ea111289b122cd0a44d41aa4690900ed6f4b6257cf75c3c36e0d` |
| `docs/product-roadmap/build-1/test-spec-r4.md` | `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be` |
| `docs/product-roadmap/build-1/transaction-control-addendum-r4.md` | `3bd808b21557a22a979446f300b22a2013f1717f06670c616ee9c858877679e3` |
| `docs/product-roadmap/build-1/snapshot-resources-r2.md` | `4f00c0e3f4c91d6dffcb234f1bd7aa3ef122e19d1cdb7e13707c6c10cd76b015` |
| `docs/product-roadmap/build-1/reviews/gate-log.md` | `c82b68a87cc65d3b65909946e79108cf911573504c1c80adc9a8f6807a731120` |
| `docs/product-roadmap/build-1/implementation-app.md` | `55782296feb1f3d4d0fae2e4fd1bda35c3d3a628b463e422caa5ce98518b80b9` |
| `phase3-binary/Sources/macprovider-cli/ModelTransactionContext.swift` | `dc5a867aaab1fc85b1e4822a9c3c9ffed16b3a701f94e4add79466d78f548377` |
| `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift` | `742e22fcf9c44930acc00aba7c3efffd6986c71f02fab23c26cdb0639d6f1166` |
