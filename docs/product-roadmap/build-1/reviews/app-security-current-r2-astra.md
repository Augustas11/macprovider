# Build 1 preliminary app security re-review — current r2

Date: 2026-09-10. Independent native security lane.
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`.
Branch: `codex/product-build-1`.

**Verdict: 0 Critical, 0 High, 0 Medium, 0 Low open findings identified in the
reviewed app snapshot. APP-SEC-M1 and APP-SEC-L1 are resolved.**

This reviews the complete ten-file app diff against the supplied base, including
three untracked helpers, with r1 retained as the prior independent assessment.
All six unchanged app files were verified byte-identical to r1; the four changed
files and their complete affected paths were re-inspected in the full app context.
The gate is limited to this preliminary app security lane. It does **not** replace
the final complete combined code, security and architecture audits, or establish
signed-release, actual-model, lifecycle, admission or settlement qualification.
Concurrent CLI transaction-binding work remains outside this frozen app verdict.

No source edits, new tests, runtime launches or recursive agents were performed.
Only this report was written. Existing test logs were independently inspected.

## APP-SEC-M1 — Resolved: durable absence precedes completion and disposal

**Previous severity:** Medium. **Current disposition:** resolved, high confidence.

**Correction evidence:**

- `ModelTransactionControl.swift:216–253`: `clear` now takes both fixed locks
  before loading pending. An absent record follows `durableAbsentPendingLocked`
  instead of returning based on absence alone. Existing pending still requires
  an exact operation/pin and a complete native-verified active or retired payload;
  missing both now throws. Active/retired conflict and malformed pending fail.
- `ModelTransactionControl.swift:240–249`: if pending unlink or its durability
  barrier fails, the intact retired payload remains untouched and the exact
  previous record is restored where storage permits. Failure is propagated.
  When restoration itself cannot succeed, later completion/disposal still cannot
  bypass the durable-absence barrier. The retained retired payload is the approved
  crash-restorable custody form; no partial payload is promoted to execution.
- `ModelTransactionControl.swift:266–282,317–323`: the shared barrier checks
  absence, syncs the directory containing pending, then checks absence again.
  Both direct orphan collection and completion retry use it. The public orphan
  entry point obtains metadata and control locks for the barrier and full
  disposal. Fresh authorization calls the locked variant only while already
  holding those same locks (`:358–372`), avoiding recursive acquisition while
  preserving serialization. The new barrier precedes the first orphan deletion.
- `ModelManagement.swift:1191–1195,2173–2177`: production completion uses the
  off-main worker-backed `finishCatalog`, which always calls the corrected clear
  path. The previous in-store absence-only success branch is removed. UI pending
  and completion state are released only after successful return. Test-only
  FakeModelCLI completion is an explicit fixture implementation, not a
  production native-identity or resource-custody bypass.

**Consequence removed:** A pending unlink with failed or interrupted parent sync
can no longer authorize retired disposal or completion solely because the file
is absent from the live namespace. Successful subsequent disposal first makes
that absence durable. The old pending/intact-retired recovery state remains
restorable after failure; an extant pending record without either payload stays
blocked. This closes the reported crash-ordering hole without deleting installed
resources, CLI artifacts, staging or journals.

**Regression evidence:** `ModelManagementTests.swift:2604–2645` injects failure
after confirming actual pending unlink, verifies exact record restoration and
unchanged retired inventory, rejects orphan collection while pending exists,
and restores the crash-equivalent intact retired payload from a newly loaded
record. It then models death after unlink: failed completion and GC barriers
preserve the payload; successful retries invoke real directory sync before
completion/disposal. `:2647–2661` proves missing-both rejection preserves pending.
These tests exercise production custody functions with a narrow explicit native
fixture identity and sync fault seam; no shipping trust override was added.

**Required correction:** None for M1 at this snapshot. Keep the barrier and
fixed-lock ordering in both completion and new-authorization maintenance paths.

## APP-SEC-L1 — Resolved: complete bundles require metadata

**Previous severity:** Low. **Current disposition:** resolved, high confidence.

`ModelTransactionPayload.swift:73–80` now requires Info.plist at one permitted
flat or Contents location for each selected known bundle. Existing duplicate
logical-location rejection, bounded plist parsing, and CFBundleExecutable/native
image rejection remain intact. The separate incomplete disposal predicate still
permits missing metadata and grants no execution authority.

`ModelManagementTests.swift:2663–2683` covers both known bundles in both layouts,
rejects missing metadata for complete scans, permits deletion-only scans, and
verifies incomplete disposal. Shared fixtures now contain valid bounded plist
metadata. The native-image negative restores valid plist metadata before testing
Mach-O bytes, so it does not pass merely because the bundle is already invalid.

**Required correction:** None for L1 at this snapshot. Real signed released
payload layouts still require their separate qualification; fixture acceptance
is not a production release-layout claim.

## Complete app assessment and remaining limits

No new security findings were identified when composing these corrections with
the full app diff. The r1 findings about strict source/native identity, private
closed resource custody, exact operation/config/context binding, single retained
resource worker, short-child lease/deadline/output controls, cancellation intent,
terminal-plus-fresh-projection gating, and non-economic local activation remain
applicable. The unchanged helpers/views/recommendation/resources are bound by the
manifest below. The correction introduces no new CLI flags, resource paths,
runtime environment overrides, arbitrary deletion roots or authority labels.

The inherited short-helper lease is still a separate process-lifetime authority
from the metadata lock; mutation owners remain unsignaled by the app. The new
maintenance wrapper holds both locks; a live inherited control lease prevents
cleanup through the same nonblocking acquisition. Direct production callers of
the locked collector were inspected: only authorization calls it, under both
locks. Narrow test injection is not a remotely selectable/runtime option.

The full existing resource qualification suite now has 16 tests. Deterministic
post-unlink persistence and bundle-metadata regressions are sufficient evidence
for these two specific findings. Broader r4/SR obligations remain independent:
real production-signed snapshots and candidate lifecycle; GUI death at real
spawn and persistence boundaries; all blocked signature/snapshot/request-cutoff
seams; exhaustive kernel/power-loss behavior; actual prepared-model/admission/
request/receipt/settlement journeys. Existing worker-marker and resource tests
must not be relabeled as all of those qualifications. Startup's synchronous
bounded pending metadata read remains an informational responsiveness limit,
unchanged by this patch. No new claim of an end-to-end performance or timing
qualification is made.

## Verification

- The corrected manifest contains exactly all ten changed/untracked app files
  against the explicit base; every direct source hash matched at review and report
  generation. Its corrected SHA-256 is
  `12be3a3ad277944b795c0350ff80b83158c35bf6a37750e2adf37eb6f6964c1c`.
  The lead clarified that the earlier `cf0eba…` handoff included two unchanged
  neighbors; the corrected manifest changed its file list, not source bytes.
- `git diff --check -- phase3-binary/app`: exit 0.
- Existing fresh full command in `/tmp/build1-app-security-fix-full.log`:
  `xcodebuild -project phase3-binary/app/Malibu.xcodeproj -scheme Malibu -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test`.
  Log reports **TEST SUCCEEDED, 641 tests, 0 failures**, including **16 resource
  tests, 0 failures**. The new unlink/barrier, missing-both and bundle-layout tests
  passed, as did the real Metal/MLX resource tests. The full suite reports 53.229
  seconds. This supersedes the pre-final-test-fix targeted 135-test result for
  current-snapshot evidence; this reviewer did not rerun Xcode.
- Full log SHA-256: `e11aafa80db2fe094996d67e65136148d9d5d9db94b87f158ba6f94f95824375`.
- Exact approved plan/test/control/resource hashes remain unchanged and match the
  gate-log/independent approvals listed below.
- No d-inference source, operator secrets, production services or credentials were
  accessed.

## Complete reviewed app source manifest

SHA-256 of the exact following `hash  relative-path\n` manifest:
`12be3a3ad277944b795c0350ff80b83158c35bf6a37750e2adf37eb6f6964c1c`.

```text
12505b4c3acfc38ac14b393e97a8cc26e642da7d2e77114d6e9b78ae24b5a9d5  phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift
d58e93591efd68cdfdc36818e5cac84cbe23e4140f07074ae060033d2f1d7d98  phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagementViews.swift
5a98a8d2e963a97789514adef788298b5fc966e7e6aef6605819bbbddc359398  phase3-binary/app/Sources/Malibu/ModelManagement/ModelTransactionControl.swift
0caefc0546bc5433ae718fed718a0aafa0da31417224b113000fa25419facb6c  phase3-binary/app/Sources/Malibu/ModelManagement/ModelTransactionPayload.swift
f11ecc5074ffc7f8bbd617e3f7c5872778c0ea861acf4a733e62c20d5d1c3a4b  phase3-binary/app/Sources/Malibu/ModelManagement/ModelTransactionRequest.swift
5314cf4664e3624f0740b0032f19db2c50cdfbacbcd15672c006277322fdc602  phase3-binary/app/Sources/Malibu/ModelManagement/RecommendationManagement.swift
ed349d9b79104fea56863db7b476f2e7086ece83203c32b71e19c3ab7144ff58  phase3-binary/app/Sources/Malibu/Resources/MalibuFeature.xcstrings
0651a6561ca428d1e8a404c6cac7351423c24af24c9b0d5e1b9b3a6c136e8227  phase3-binary/app/Sources/Malibu/Resources/MalibuModelCapabilities.json
dc94845a00212cd25a2ce8f2a45d4861ac70d92d125717d50224ea27041c0517  phase3-binary/app/Sources/Malibu/System/InstalledProviderMonitor.swift
c88fd0644c37fb29572bdbf51739d565e31cb288c9a5f292208a4b6a02709b73  phase3-binary/app/Tests/MalibuTests/ModelManagementTests.swift
```

## Approved contract hashes

| File | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/plan-r4.md` | `a5c7a56a68d3ea111289b122cd0a44d41aa4690900ed6f4b6257cf75c3c36e0d` |
| `docs/product-roadmap/build-1/test-spec-r4.md` | `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be` |
| `docs/product-roadmap/build-1/transaction-control-addendum-r4.md` | `3bd808b21557a22a979446f300b22a2013f1717f06670c616ee9c858877679e3` |
| `docs/product-roadmap/build-1/snapshot-resources-r2.md` | `4f00c0e3f4c91d6dffcb234f1bd7aa3ef122e19d1cdb7e13707c6c10cd76b015` |
