# Snapshot resources r2 — independent architecture plan gate

Verdict: **APPROVED at plan level — 0 Critical, 0 High, 0 Medium, 0 Low.** Both r1 Medium findings are closed by the exact revised contract and required tests. No new blocking architectural finding was identified. This approval does not claim the implementation, runtime qualification or complete Build 1 audit is finished.

Exact proposal SHA-256: `4f00c0e3f4c91d6dffcb234f1bd7aa3ef122e19d1cdb7e13707c6c10cd76b015` (verified).
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Snapshot time: 2026-09-10T07:58:22.264791+00:00.

Read-only review except this artifact. No source edits, subagents, model execution or new runtime tests. Reviewed the complete r2 proposal against approved control r4, Build 1 plan/test contracts and the actual current app/candidate/resource seams. Sources are evolving; the hashes below identify this review snapshot.

## SR-ARCH-M1 — closed

**Previous severity:** Medium. **Confidence in plan closure:** High.

**Evidence:** R2 lines 113–180 place resource preflight inside the absolute ten-second control request budget, before signature/config/resource work or spawn. A single non-main worker owns immutable request identity, deadline, nonce, completion fence, descriptors and leases. The independent timer revokes authorization and completes UI once; a blocked syscall retains exactly that worker and lease in an explicitly visible busy state until unwind. Subsequent requests do not create more workers. Cancellation remains coalesced, and the UI distinguishes unsaved intent from durable cancellation. The launcher accepts the already-held control lease and remaining absolute deadline rather than reopening the lock or starting a new ten seconds.

Lines 182–207 explicitly cover the difficult commit races: capture has a disclosed 30-second budget, actor handoff cannot revive a stale pin, every authorization-advancing operation requires a live commit transition, and no validation finishing after revocation can dispatch. A write or spawn already committed before revocation is handled according to its actual outcome. A late-durable exact pending record remains launch-not-confirmed for recovery; it is never erased or rebound. A cutoff-racing committed control child is rejected/reaped, while an already-committed mutation owner is preserved. The worker releases the validation slot after owner spawn registration, so it does not serialize all subsequent controls behind the long owner lifetime.

**Prior consequence removed:** Slow resource checks no longer run on MainActor or hide outside the request timeout. Timeout cannot create an unbounded retry queue or allow a completed stale validation to spawn. The design does not falsely claim that Swift can terminate a blocked filesystem/Security call: UI completion and bounded worker-count retention are distinct from eventual descriptor reclamation. This truthful busy outcome is permitted during a stuck call; successful validation is never asserted.

**Required correction:** None at plan level. SR-09 and SR-10 must prove real stalled preflight, one retained worker, UI/cancel responsiveness, remaining helper budget, no late dispatch/pin mutation, exact lease ownership and the already-committed write/spawn distinction. Implementation must change both runner and store seams: current `ModelManagement.swift:2067–2068,2097,2242–2245` still authorizes/saves synchronously, and current `ModelTransactionControl.swift:318–360` starts a fresh timer and acquires its own lease. The proposal explicitly authorizes those narrow asynchronous internal changes; updating only the resource-copy helper would not satisfy this gate.

## SR-ARCH-M2 — closed

**Previous severity:** Medium. **Confidence in plan closure:** High.

**Evidence:** R2 lines 281–340 define separate functions/result types for complete launch/restoration validation and deletion-only approval. Deletion requires genuine no-follow pending absence, both fixed leases and the owned worker slot; malformed/unsupported/unreadable/dangling pending metadata blocks it. Only canonical recognized private names qualify. Surviving paths must be a bounded safe subset of the fixed closure. Missing required resources, incomplete bytes and missing metadata are explicitly permitted only for disposal, never pin construction, restoration or execution. No removed pin/deletion receipt is needed to resume disposal. A complete bounded inventory is checked before deletion, and each unlink/rmdir rechecks original node/parent identity. Unexpected or unsafe nodes remain blocked.

A retired directory still backing pending authorization retains the complete original pin/hash/native signature requirement. No-pending retired, unpublished temporary and published orphan subsets share only disposal authority. Thus a crash after any allowed unlink or incomplete initial copy produces another safe subset without weakening executable completeness.

**Prior consequence removed:** Interrupted orphan deletion can resume after the native file, metallib, plist or envelope has disappeared, without treating those absent members as valid for launch. The no-pending and fixed-namespace conditions remain mandatory, so partial-tree handling cannot authorize recovery execution or deletion of installed/CLI-owned state.

**Required correction:** None at plan level. SR-11 explicitly covers every member/chunk/unlink/rmdir, malformed/dangling/conflicting pending records, substitutions and unsafe/unknown survivors. SR-04 continues to require strict intact-retired restoration when pending still exists. These tests are mandatory implementation evidence.

## Full revised-contract assessment

**Resource and signing authority:** The fixed closure and pin-v2 schema remain unchanged from r1. The required adjacent metallib addresses the actual pinned MLX lookup and self-executable candidate path. Source and frozen payload still undergo complete bounded resource hash/inventory and native signature checks; there is no positive cache, environment override, alternative executable or resource-to-feed trust promotion. Standalone resource SHA pins remain consistency evidence within the trusted operator-UID boundary. Native Apple/team/identifier/CDHash/live-peer authorization and existing signed compatibility/catalog/adoption checks remain independent. Version-1 pending records stay blocked and visible rather than being silently upgraded.

**Capture and source-update races:** Source paths derive only from the trusted configured native installation. Full selected closure stability and destination verification precede atomic directory publication and durable pending authorization. Resource changes before final validation reject; subsequent source replacement can only leave the already-verified frozen bytes runnable. Expired capture may leave a disposal-only orphan; a possibly committed pending write instead preserves the exact authorization and payload. No post-revocation cleanup may erase that pending state.

**Locks and process ownership:** Expensive work is outside MainActor. Nonblocking fixed leases serialize cross-app validation/maintenance and hand off the same control description to the actual helper. Timeouts never close another running worker's raw FD, avoiding descriptor reuse. A retained pre-spawn worker has no child and releases process-owned descriptors on GUI death. Spawned controls retain r4's inherited lease/parent-lifetime guard and exact child reap rules. Long owners do not inherit the short-control lease or deadline; candidate/runtime lifecycle remains the existing CLI responsibility. Queued cancellation begins a fresh request only after the revoked worker unwinds, with the same saved operation tuple and truthful persistence status.

**History and cleanup:** Intact payload retirement is durable before pending clear; deletion starts only after clear durability. Pending-plus-retired startup requires complete verified restoration. Active/retired conflicts and missing required execution payload remain blocked. The subset disposal rule has no authority over model artifacts, journals, staging, credentials or the installed payload. Count/byte/depth limits and unknown-node rejection remain intact.

**Timing and acceptance limits:** The ten-second request limit is not a promise that the OS will finish every resource syscall or reap immediately; the plan explicitly separates UI outcome, retained blocked-worker lifetime and helper execution. Required full hashing may truthfully make a maximum-sized payload unavailable on slow storage. No integrity check is omitted to force a pass. SR-05 proves real Metal library loading; SR-06 proves the pinned MLX expression lookup; SR-08 proves signed released owner/control/candidate behavior; B1-T10 remains actual-model/receipt/settlement qualification. These are separate evidence claims. The lead's metallib artifact preparation is not an executed SR-05/SR-06 result and is not treated as qualification here.

## Verification and handoff

Verified the exact r2 digest and compared the r1 snapshot hashes. The app control source, pinned MLX lookup/package source, packaging/update rules and approved contracts were unchanged. `CandidateProviderRunner.swift` changed during independent work; its current candidate launch checks and self-executable path were reread and do not alter this resource-closure conclusion. The current app store's synchronous authorization/persistence and control scheduling seams were inspected for integration feasibility.

No new runtime or signed-positive tests were executed for this document-only gate. All r4 tests plus SR-01 through SR-11 remain required after implementation. A complete combined code/security/architecture audit and any independent outstanding gates are still prerequisites to completion; this report only approves the exact resource plan.

## Exact snapshot

Manifest SHA-256: `e52c55bb9217a225d08729f46b7b88985fc89ccdff296a4e9729d8a89c995601`.

| File | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/snapshot-resources-r2.md` | `4f00c0e3f4c91d6dffcb234f1bd7aa3ef122e19d1cdb7e13707c6c10cd76b015` |
| `docs/product-roadmap/build-1/transaction-control-addendum-r4.md` | `3bd808b21557a22a979446f300b22a2013f1717f06670c616ee9c858877679e3` |
| `docs/product-roadmap/build-1/plan-r4.md` | `a5c7a56a68d3ea111289b122cd0a44d41aa4690900ed6f4b6257cf75c3c36e0d` |
| `docs/product-roadmap/build-1/test-spec-r4.md` | `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be` |
| `docs/product-roadmap/build-1/reviews/snapshot-resources-r1-astra.md` | `ac1af78d85db68f88af5b7ed2df7ed491ea7c8e1630ffe464928df0469eb6069` |
| `phase3-binary/Package.resolved` | `3214cee41e5fb4ec7c26164b4536688bc6f2287b3323d490beb9283a5e7c9562` |
| `phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift` | `14ad4259d89c3972d2ba438972cce2033d29015bdaccaf7f61bfc888d4388622` |
| `phase3-binary/app/Sources/Malibu/ModelManagement/ModelTransactionControl.swift` | `0036b65ac85da537f10317fb0077d83d6ce1ec0f4f51ee6a09181071ed5e0532` |
| `phase3-binary/Sources/macprovider-cli/CandidateProviderRunner.swift` | `862c33af250924e4450ace7eba8936efeed23a99c592bb98639efc6c6da3c326` |
| `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift` | `f9605c97d5728634492c7aaaebfeac52bc184ae00546640e79072464bdf4d994` |
| `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift` | `c240942ca1a32720c1292ae534b688ec49fb66cd6cbde82e04123d5ab39c8e70` |
| `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift` | `742e22fcf9c44930acc00aba7c3efffd6986c71f02fab23c26cdb0639d6f1166` |
| `phase3-binary/Sources/macprovider-cli/CompatibilitySetManifest.swift` | `9242bbd5d226144cde3c1be6fa87b0a3bc35fd0f7395d2db521d6b993dd41710` |
| `phase3-binary/dist/package.sh` | `d12c6373ed0b8268c6e78c5846f6f63f008937795352d2a96e4cf24aa135743b` |
| `.github/workflows/release.yml` | `b2110c54aab491f9fc21b058754e03e8fe6d99a1dcf17e174b8f5149cd9a255f` |
| `phase3-binary/.build/checkouts/mlx-swift/Package.swift` | `062cc367fe217874439e75dafa35b1396d2e7d3f6782bb2aef0ce8d41f7d4aec` |
| `phase3-binary/.build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/backend/common/utils.cpp` | `f831b4e6576cb76519fddcbab2e424dc53e8f75811cce448f4a877ec1885331e` |
| `phase3-binary/.build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/device.cpp` | `d2000ba53a5f4137c91f0a6222ae86cc3c2c0c3d69dfda2f421f60bd55813a98` |
