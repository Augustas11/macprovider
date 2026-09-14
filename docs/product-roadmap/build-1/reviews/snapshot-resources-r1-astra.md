# Snapshot resources r1 — independent architecture plan gate

Verdict: **CHANGES REQUIRED — 0 Critical, 0 High, 2 Medium, 0 Low.** The zero-C/H/M plan gate is not met. No implementation is approved by this architecture report.

Exact reviewed proposal SHA-256: `db89bfd4b1d9aaa27a4c30bcaad7082eb90ef22bc85408e5b9876ff355418358` (verified).
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Snapshot: 2026-09-10T07:51:43.178718+00:00. Other implementation work is active; hashes below scope this report.

Read-only architecture review except this artifact; no source edits, subagents, model execution, secrets access or d-inference inspection. No runtime acceptance tests were run. Read the revised resource proposal, approved control r4 and Build 1 plan/test requirements, actual pinned MLX lookup, app custody/launcher seams and release/update packaging.

## SR-ARCH-M1 — resource preflight is outside the bounded control lifecycle

**Severity:** Medium. **Confidence:** High.

**Evidence:** Proposal lines 147–154 require the complete configured-source resource closure/hashes and private payload inventory/hashes/signature before every owner/control invocation. Lines 125–128 allow a 512-MiB payload. Neither those steps nor SR-01 through SR-08 assign resource preflight a monotonic request budget, an off-main execution boundary, a cancellation/late-completion fence or bounded resource-worker ownership. Existing `ModelTransactionControl.swift:234–309` is a `@MainActor` extension: `runCatalog` performs synchronous configured/snapshot reads and signature verification before awaiting the bounded process runner. Its ten-second timer starts only inside `MalibuBoundedCatalogProcess.execute` at line 335, after these checks. The proposal carries forward r4's bounded controls and one-request/coalesced-cancellation contract but does not integrate the new full-resource scans into that lifecycle.

**Consequence:** A valid but slow/stalled source or snapshot read can freeze the app's main actor or keep a requested status/cancel in unbounded preflight while the actual helper watchdog has not started. Finite byte/count limits do not bound one filesystem call. Moving this work to a background Swift task alone would still permit late spawn after timeout or an unreclaimed task/lock that blocks later cancellation unless ownership and completion are fenced explicitly. The actual helper's ten-second success would not prove the user's control request was bounded.

**Required correction:** Specify resource preflight as an explicit part of the control request lifecycle before implementation. Start the monotonic app request deadline before resource inspection; keep all bulk read/hash/signature work off the main actor; allow one owned validation request with the existing cancellation priority; define timeout/abandonment and prohibit every late spawn or pin/pending mutation after that request loses authorization. Define how stalled validation releases or safely retains its exact descriptors/metadata/control leases without opening a second execution or unbounded task queue. Preserve full resource integrity checks and the inherited control bound: do not silently remove hashes, increase ten seconds, launch from unverified payloads or treat UI timeout as cancellation success. If satisfying bounded reclamation requires a process-isolated validator or a CLI pre-journal validation seam, reopen that narrow ownership/interface contract explicitly rather than assuming the current app-only implementation already provides it. Initial capture may have a separately disclosed bounded preparation lifecycle, but must likewise remain responsive and cannot commit/dispatch after abandoned authorization.

**Required tests:** Pause a real resource read/hash before the process runner is entered for longer than ten seconds. Assert UI/event delivery and cancel intent remain responsive, the request reports bounded unavailable/uncertain status, no helper spawns when the read later completes, no pending authorization is rebound, and a subsequent request has the specified bounded busy/retry/reclamation behavior. Repeat while a payload/source descriptor or control/metadata lease is owned, during GUI shutdown, and near the maximum payload budget. Observe actual preflight and helper timing separately.

## SR-ARCH-M2 — partial payload deletion needs a distinct closed recovery predicate

**Severity:** Medium. **Confidence:** High.

**Evidence:** The fixed launch closure requires the CLI, metallib, compatibility envelope/local tree/catalog tree and a known resource bundle. Proposal lines 155–171 correctly retire an intact payload before clearing pending, then delete only after pending removal is durable. Lines 167–168 promise that interrupted deletion can resume. However lines 173–178 tell orphan maintenance to validate recognized descendants against the same closure before removal; no separate incomplete-tree predicate or durable deletion inventory is defined. The saved inventory lives in the pin that has just been cleared. The same ambiguity affects a crash during initial `.payload-<uuid>` construction, before mandatory files or complete bundle metadata exist.

**Consequence:** A straightforward reuse of complete-payload validation rejects the first orphan missing a required member after a crash, permanently blocking subsequent authorization under the plan's fail-closed orphan policy. Making the execution validator broadly tolerate missing files would instead weaken the resource closure for pending execution. Crash-safe reclamation needs a separate authority and completeness rule, not an implicit parser exception introduced during implementation.

**Required correction:** Separate complete executable-payload validation from no-pending deletion-only validation. Define a closed deletion state/predicate for recognized temporary/retired/published orphan names, with no pending record, both fixed locks, pinned private root/directory identities, bounded relative traversal, allowlisted surviving members and no unsafe/unknown nodes. Explicitly permit missing mandatory members and partially written allowed data only for deletion, never restoration or launch; alternatively persist a bounded deletion inventory/tombstone before clearing pending and resume against it. Define which approach proves ownership for an incomplete pre-pin capture and for a post-pin-clear retired tree, including crash ordering and final marker removal. Retain complete inventory/hash/native checks for any active/retired payload that still backs pending authorization. Never follow links or use broad recursive removal to resolve the ambiguity.

**Required tests:** Crash after each individual file unlink and directory removal, including after deleting the CLI, mandatory metallib, bundle Info.plist, envelope and inventory-bearing metadata, and during each initial-copy member. Restart must reclaim the safe no-pending partial orphan and permit a fresh authorization while never executing/restoring the partial payload. Inject an extra file, unsafe node, substitution or conflicting pending record into those same partial trees and assert preservation/blocking. The existing intact-retired/pending recovery tests must remain strict.

## Confirmed foundations and remaining acceptance boundaries

**The binary-only defect is real.** Pinned mlx-swift commit `dc43e62d7055353c7f99fa071a4e71d29dfddc44` matches Package.resolved. `backend/common/utils.cpp:9–17` obtains the linked MLX image directory using `dladdr`. `backend/metal/device.cpp:136–175` tries colocated `mlx.metallib`, colocated Resources/mlx, SwiftPM default, framework Resources/default, then METAL_PATH. Package.swift sets the final path to relative `default.metallib`. The local debug CLI's `otool -L` output contains no MLX dynamic library. `CandidateProviderRunner.swift:389–397` selects its current executable and `MacProviderCLI.swift:1476` excludes autotune candidates from canonical-install re-exec. A snapshot must preserve executable adjacency; fallback to installation/cwd is not an acceptable correction.

**The named closure is grounded in packaging.** `dist/package.sh:180–238`, release.yml's archive/app staging, and `SelfUpdate.swift:2659–2713` carry the required metallib, compatibility/local/catalog files and resource bundle. The proposal correctly distinguishes native CLI signature authority from owner-UID resource consistency: standalone adjacent metallib bytes do not inherit the CLI signature. Existing signed-envelope/catalog trust and current feed/adoption checks remain decisive. No new native executable, dynamic library, bundle executable, environment path override or trust-root import is authorized. The local built NIO bundle contains only `PrivacyInfo.xcprivacy`, which the allowlist permits. Actual released flat/Contents fixtures still need SR-01 validation; no necessary member may be added by unreviewed wildcard expansion.

**Publication and pending recovery direction is sound.** Fixed derived paths, streaming/count limits, source/destination revalidation, file/child/parent fsync, atomic directory rename and pending persistence before dispatch avoid exposing partial copies as authorized payloads. Version-1 pins remain blocked rather than rebound. Retirement-before-pending-clear preserves an intact recoverable executable until authorization is gone; M2 concerns only the separate no-pending deletion phase. Changed installed resources conservatively block pending controls just as changed native code does. Full source and frozen payload validation must remain independent; metadata/hash pins grant neither signed provenance nor paid authority.

**Testing claims remain distinct.** SR-05 proves actual Metal library loading only. SR-06 must use the pinned MLX expression/helper and cannot be replaced by a handwritten lookup simulation. In the inspected local debug products, the CLI exists (113,042,608 bytes), the NIO privacy bundle exists, and adjacent `mlx.metallib` and `mlx-swift_Cmlx.bundle` are absent. This is a local resource prerequisite gap, not an executed MLX result. SR-08 signed-positive owner/control/candidate qualification and B1-T10 actual-model inference/settlement remain separate requirements; no new positive signing qualification was performed or inferred from fixtures. The proposal's signing-identity statement was not independently queried in this review. Earlier app test passes predate this correction and cannot qualify it.

## Snapshot and verification evidence

Verified the proposal SHA and pinned MLX checkout commit; read actual package/update/release rules; ran read-only `otool -L` on the local debug CLI and inspected only the named local resource paths. No acceptance suite was executed. The code and plan must be independently rereviewed after corrections; a full combined implementation audit remains required.

Snapshot manifest SHA-256: `3ccf33a6b144d1fabd3c05a640f84f3a919f252a06392906c16b40698b719db6`.

| File | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/snapshot-resources-r1.md` | `db89bfd4b1d9aaa27a4c30bcaad7082eb90ef22bc85408e5b9876ff355418358` |
| `docs/product-roadmap/build-1/transaction-control-addendum-r4.md` | `3bd808b21557a22a979446f300b22a2013f1717f06670c616ee9c858877679e3` |
| `docs/product-roadmap/build-1/plan-r4.md` | `a5c7a56a68d3ea111289b122cd0a44d41aa4690900ed6f4b6257cf75c3c36e0d` |
| `docs/product-roadmap/build-1/test-spec-r4.md` | `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be` |
| `phase3-binary/Package.resolved` | `3214cee41e5fb4ec7c26164b4536688bc6f2287b3323d490beb9283a5e7c9562` |
| `phase3-binary/app/Sources/Malibu/ModelManagement/ModelTransactionControl.swift` | `0036b65ac85da537f10317fb0077d83d6ce1ec0f4f51ee6a09181071ed5e0532` |
| `phase3-binary/Sources/macprovider-cli/CandidateProviderRunner.swift` | `30e760c9caf91eef949ed223c8be8b0a67f21015d291ecd0ddec93883701e514` |
| `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift` | `f9605c97d5728634492c7aaaebfeac52bc184ae00546640e79072464bdf4d994` |
| `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift` | `c240942ca1a32720c1292ae534b688ec49fb66cd6cbde82e04123d5ab39c8e70` |
| `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift` | `742e22fcf9c44930acc00aba7c3efffd6986c71f02fab23c26cdb0639d6f1166` |
| `phase3-binary/Sources/macprovider-cli/CompatibilitySetManifest.swift` | `9242bbd5d226144cde3c1be6fa87b0a3bc35fd0f7395d2db521d6b993dd41710` |
| `phase3-binary/dist/package.sh` | `d12c6373ed0b8268c6e78c5846f6f63f008937795352d2a96e4cf24aa135743b` |
| `.github/workflows/release.yml` | `b2110c54aab491f9fc21b058754e03e8fe6d99a1dcf17e174b8f5149cd9a255f` |
| `phase3-binary/.build/checkouts/mlx-swift/Package.swift` | `062cc367fe217874439e75dafa35b1396d2e7d3f6782bb2aef0ce8d41f7d4aec` |
| `phase3-binary/.build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/backend/common/utils.cpp` | `f831b4e6576cb76519fddcbab2e424dc53e8f75811cce448f4a877ec1885331e` |
| `phase3-binary/.build/checkouts/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/device.cpp` | `d2000ba53a5f4137c91f0a6222ae86cc3c2c0c3d69dfda2f421f60bd55813a98` |
