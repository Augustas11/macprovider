# Build 1 catalog read lifecycle — independent Astra plan review r1

Date: 2026-09-10. Reviewer: independent native GPT-6 Astra high security lane.
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`, branch `codex/product-build-1`.

**Verdict: NOT APPROVED FOR IMPLEMENTATION — 0 Critical, 0 High, 1 Medium, 0 Low.**
The proposed quick/selected-verification design addresses the established defects in principle, but its older-peer branch has an unresolved lifecycle contract. This review does not close runtime findings B1-SEC-M1/M2 or replace the final whole combined code/security/architecture audits.

## Scope and evidence

Reviewed all ten proposed CR tests and the complete app/CLI lifecycle, verification, output and recovery contract in `catalog-read-lifecycle-addendum-r1.md`, exact SHA-256 `9d98dbf4ea3acd639005ec04f1275e68197ce5158dd9e9b8a2f40eb5b58cb16d`, against the approved plan/test/control/snapshot documents listed below. Independently inspected actual producer/consumer arguments, capability routing, config preparation, both canonical-hash call sites, verifier implementation, result parsing, network-input loading, and projection/recovery wire shapes. This is static plan review: no runtime changes, fixture runs, service starts or hardware verification. Concurrent retention work is outside this approval and the source hashes below identify only the code observations supporting this report.

## CR-PLAN-M1 — Medium — unsupported-peer catalog reads lack a closed ownership policy

**Evidence.** Addendum section 1 requires exactly one app-owned catalog read through child exit/reap, including app restart. Section 3 defines inherited lifetime/lock argv for “Negotiated quick mode,” preserves default protocol-1 CLI behavior and standalone overrides, and section 7 depends on the child implementing the new pre-config lifetime monitor. It does not define the actual app branch when the installed peer supports catalog economics but does not support these new options/monitor. CR-02's unchanged protocol-1 parsed CLI regression does not exercise that app branch.

That branch exists today: `ModelManagement.swift:1839` checks catalog-economics capability independently of local activation at line 1846; refresh enters `refreshCatalogEconomics` on catalog capability alone at line 1956. The actual argv at lines 2342–2347 adds local activation only conditionally. `MalibuModelCapabilities.json:16` enables catalog economics from 1.8.90, while transaction/local-activation tiers begin at 1.8.123. Approved plan-r4 requires conservative legacy capability negotiation, and B1-T05 explicitly requires old-CLI fallback. A protocol-1 codec test alone does not prove these runtime callers remain safe.

**Consequence.** Retaining the old argv fallback without a compatible lifetime guard leaves the parent-only termination mechanism unable to enforce the proposed finite child lifetime after the GUI dies. Inheriting a lock into that old child cannot make it monitor pipe EOF or its own deadline; it may instead retain the replacement application's read lease until its uncontrolled work finishes. Sending new options to an unsupported parser fails the existing fallback without a reviewed product policy. The plan currently leaves implementers choosing between these incompatible outcomes. This is a plan completeness and local availability/resource-ownership finding, not a demonstrated remote exploit or a claim that every historical CLI hashes weights.

**Required correction.** Specify the compatibility matrix and capability/version evidence for all actual app catalog-read branches before implementation. For every branch the app can launch, require a demonstrated finite read lifecycle across parent death, or explicitly choose a conservative view-only/update-required state without spawning an unsupported catalog helper. Preserve standalone protocol-1 semantics separately; do not silently weaken the app lifetime invariant or invent support from the presence of the older catalog capability. Any fallback product change must be stated in the amendment rather than inferred during coding.

Extend CR-01/CR-02/CR-06 with actual app refresh routing for (a) supported guarded peer, (b) catalog-capable peer lacking the guard/options, and (c) absent/stale capability evidence. Assert the exact spawn/no-spawn result, truthful UI/action state, and no generic-run fallback that escapes ownership. Where a compatibility helper is permitted, prove its parent-death/reap and restart behavior using the real owned process seam. Update the exact proposal digest and obtain a new zero-C/H/M review.

**Disposition/confidence.** Open; high confidence in the existing reachable branch and missing decision. No runtime correction is approved by this report.

## Design checks with no additional blocking finding

- **Actual argv binding:** CR-01 captures the array received by the production spawn seam and feeds those unchanged bytes to real `parseAsRoot`/`run(context:)` with genuine fixture descriptors. This is the required composition proof for B1-SEC-M1. The forbidden-override negatives correctly keep CLI authority checks intact; mocks of equivalent arrays would not satisfy the test.
- **Current integrity and TOCTOU:** One request-local inspection shared by durable discovery and action construction covers both currently independent full-hash sites. Quick never grants byte readiness. Exact signed target/revision/hash plus final feed identity refresh, no-follow descriptor-relative file access, before/after identity/size/mtime/ctime and complete bounded placement snapshots are coherent obligations. They do not promise permanent immutability after publication. The existing prepared-context finalizer alone is insufficient to detect every same-path config mutation; the amendment's explicit changed-config rejection and CR-07 must be implemented, using the captured identity/content evidence without a second authority-bearing config load.
- **Deadlines, processes and FDs:** Reservation before preflight, nonce checks before spawn, separate cross-instance read lock, inherited lifetime pipe, independent early child monitor, exact unreaped-child TERM/KILL and retaining busy until reap address late workers and parent death on supported peers. The proposed direct helper spawns no subprocess family. CR-04–CR-06 require real process evidence, including a slow read beyond ten seconds, and preserve transaction-control availability. None of those outcomes is established by a continuation timeout or cooperative cancellation check alone.
- **Network and finalization feasibility:** Existing input loading awaits catalog/rate/artifact sources, and coordinator admission queries are performed per candidate. The proposed total and initial/final phase budgets must bound those actual awaits and final snapshot work as well as hashing. A heartbeat from an independent timer is not progress evidence. The amendment already requires phase expiry and no-byte limits, permits truthful incomplete outcomes and keeps custody, so this is an implementation obligation rather than a new plan finding. Do not allow a fresh internal work budget per consumer to reset the request budget.
- **Recovery and UI truthfulness:** Terminal-plus-fresh-verified-projection before successful prepare/evaluate clear remains intact. The verified completion projection must itself satisfy freshness without a second full scan. Failed/cancelled/cleanup terminal recovery can use quick observations where no readiness assertion is required. Interruptions retain exact pending custody and retry only the read. Current-serving evidence and historical seals never promote local readiness. Result restoration retains exact UUID/kind/generation, same consumed config/context and independent ten-second ownership.

## INFO — final-line capacity needs a supported-state feasibility check

Section 6 caps the completed JSONL line, including the full projection, at 1 MiB, compared with 8 MiB total output. Current `ModelCatalogEconomicsWire.Recovery` contains target ID, model key and a complete action, and the active transaction index allows 1,024 entries (`ModelCatalogTransactionRetention.swift`, `activeTransactionLimit`). Cleanup projection deduplicates targets, so 1,024 active entries do not establish 1,024 recovery rows or a demonstrated overflow. No supported-size counterexample was measured in this review; this is not an additional Medium finding.

CR-08 already requires overflow to fail closed. Add an encoding/capacity check for the maximum supported catalog/recovery shape when implementing it, and document the actual supported bound. If a supported state exceeds the line cap, an overflow test alone cannot prove the required successful pending-recovery path: revise the transport/bounds within review or specify an explicit truthful unavailable/recovery policy. Do not truncate recoveries silently, repeatedly rehash a deterministically oversized response, or clear pending custody on that failure.

## INFO — quick reservation work and recovery share the same finite budget

The actual action builder loops signed candidates and invokes `reserveOperation` for each eligible action (`ModelCatalogTransactions.swift:1177–1197`). That API constructs a fresh `ModelTransactionWorkBudget` (`ModelCatalogTransactionRetention.swift:323–325`), whose default is eight seconds (`ModelCatalogTransactionEvidence.swift:7`). The command constructs actions before loading recoveries. Thus the proposed ten-second child deadline bounds resource lifetime but does not by itself prove a supported larger catalog/history can produce its recovery projection before expiry. No such timing failure was measured in this static review.

The implementation must carry/check the request's remaining budget through action/recovery consumers, rather than repeatedly resetting it, and CR coverage should include a supported high-row/history quick projection and an injected late reservation. State explicitly how incomplete action work affects the final document: never present an omitted recovery as proof that none exists, publish fabricated completeness, or release pending custody after a timed-out projection. If a reviewed partial projection is needed, its semantics require an amendment; they cannot be inferred from the current full-document contract. Retention retirement/capacity changes and the separate unapproved reservation proposal are not approved by this read-lifecycle review.

## Gate disposition

B1-SEC-M1 and B1-SEC-M2 remain open runtime findings pending an approved amendment, implementation and CR evidence. The one Medium above prevents this exact r1 proposal from reaching its pre-implementation gate. Signed app/CLI identity, physical model performance and the full hardware journey remain separate qualification requirements; prior app-suite results and fixture arithmetic do not establish them.

## Exact artifact and observed-source SHA-256 manifest

These are direct file hashes at report generation; they are not a claim that every byte of each neighboring implementation file received a complete combined audit.

```text
9d98dbf4ea3acd639005ec04f1275e68197ce5158dd9e9b8a2f40eb5b58cb16d  docs/product-roadmap/build-1/catalog-read-lifecycle-addendum-r1.md
a5c7a56a68d3ea111289b122cd0a44d41aa4690900ed6f4b6257cf75c3c36e0d  docs/product-roadmap/build-1/plan-r4.md
20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be  docs/product-roadmap/build-1/test-spec-r4.md
3bd808b21557a22a979446f300b22a2013f1717f06670c616ee9c858877679e3  docs/product-roadmap/build-1/transaction-control-addendum-r4.md
4f00c0e3f4c91d6dffcb234f1bd7aa3ef122e19d1cdb7e13707c6c10cd76b015  docs/product-roadmap/build-1/snapshot-resources-r2.md
12505b4c3acfc38ac14b393e97a8cc26e642da7d2e77114d6e9b78ae24b5a9d5  phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift
0651a6561ca428d1e8a404c6cac7351423c24af24c9b0d5e1b9b3a6c136e8227  phase3-binary/app/Sources/Malibu/Resources/MalibuModelCapabilities.json
01d1a5a54ca96a6cbae7fddb8e7a22bb46dd00db396acf7411feef90e309230f  phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift
04bc959b8317fb94688b02e325817c143c47f1ae1b73f5767ebb25d40745e93e  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
e7f5b9da2ec4be6ab9baa7713318fc34a0524c8796de42c116f4901e53a7f3a6  phase3-binary/Sources/macprovider-cli/DurableModelDiscovery.swift
f9605c97d5728634492c7aaaebfeac52bc184ae00546640e79072464bdf4d994  phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift
91fd91b8d769a5bd50a7ac3caa80eb30b63f8fbd0fb12081cbdc074bf7684df9  phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift
dc5a867aaab1fc85b1e4822a9c3c9ffed16b3a701f94e4add79466d78f548377  phase3-binary/Sources/macprovider-cli/ModelTransactionContext.swift
397817cebf43cd56b6c6e007d679e8ea22b9de3bc4b61a840b6845040aff06b7  phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift
74b67ff7a6945c3fe4c64b5178ed7b03814a97098d61a90dcfcd72a59550852a  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift
63b48848570125b1d329d8810fd85d0e38919ba2b71d84d3e9fa08a72287d1de  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift
```
