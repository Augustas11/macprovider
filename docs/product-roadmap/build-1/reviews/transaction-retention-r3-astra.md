# Transaction retention r3 — independent security plan gate

Verdict: **CHANGES REQUIRED — 0 Critical, 0 High, 1 Medium.** R1's lifetime-cap defect and r2's queued-reuse discovery defect are resolved in the proposed design. The pointer/cleanup lifecycle below still prevents implementation approval of this exact revision.

Reviewer: independent native GPT-6 Astra, high reasoning; not the proposal author. Base/HEAD: `914f7cafcdbcfc1805a10f4f34167218341d5587`. This review covers the complete r3 proposal, its delta from r2, prior retention findings, and current store behavior. It is not final implementation acceptance.

Exact reviewed proposal:

```text
268f72d851b59d7bc3fc371d654586bb3eb930fb0575d6701433c5ff1d552a8e  docs/product-roadmap/build-1/transaction-retention-addendum-r3.md
```

Corroborating current source snapshot (other lanes remain active):

```text
ccf517366232ad36787c8542a677b04b83914ea5dc482acb68769935f771bf53  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
```

## M1 — Legitimate cleanup invalidates an already published recommendation pointer

**Evidence.** R3 line 17 binds a recommendation pointer to the final record digest and result digest; lines 48 and 68 capture/revalidate original record byte digests. The new normal-completion rule (line 74) explicitly permits indexing successful evaluations with `cleanupRequired == true`, before storage retirement. Existing supported cleanup writes `original.cleanupRequired = failed` back to the original primary record (`ModelCatalogTransactions.swift:734`), so successful cleanup changes `true` to `false` and changes the primary record's byte digest. R3 lines 23 and 66 prohibit replacing a mismatched pointer and require preserving it with unavailable/recovery status.

**Consequence.** A measured result can be correctly indexed and discoverable while cleanup is required, then become unavailable after its legitimate cleanup succeeds. Reindexing sees the old pointer's digest mismatch; retirement cannot finish its pointer-validation step either. The original result is preserved, but ordinary recovery creates a persistent discovery/capacity blockage. Allowing arbitrary mismatch replacement would weaken the tamper boundary rather than resolve this state transition safely.

**Required correction.** Define a recommendation commitment that remains stable through explicitly permitted cleanup bookkeeping changes, or define an equally explicit crash-safe protocol for authorized record/pointer updates. A versioned canonical digest over the immutable successful evaluation identity, authority/context, complete original terminal event evidence and committed result digest can be suitable if it excludes only precisely identified mutable cleanup bookkeeping. Continue to validate the complete primary record separately, preserve original terminal truth and original result bytes, and reject changes to protected commitment fields. Do not broadly accept or overwrite a pointer whose binding no longer matches.

**Required tests.** Publish a pointer for a successful evaluation with unresolved cleanup; prove initial discovery. Complete actual cleanup, restart, and prove immediate discovery of the same original result and successful retirement without a history scan. Repeat with cleanup failure/retry and interruption at each relevant persistence boundary. Tamper with UUID, authority/context, committed result digest, original success events and pointer fields and prove fail-closed behavior. The safe bookkeeping transition must not serve as permission to repair unrelated mismatches.

## Prior findings and retained acceptance obligations

- **R1 M1 resolved at plan level:** active capacity is separate from indefinite UUID history; resolved records retire without deletion; tests exercise more than 1,024 completed and cancelled transactions and recover capacity through supported lifecycle operations.
- **R2 M1 resolved at plan level:** indexing occurs at durable completion and independently before every adoption projection. Fresh queued reuse no longer skips indexing. A/B successor, old/absent pointer, restart and pointer-failure tests cover the original trace.
- Success remains authoritative after an indexing failure; indexing cannot fabricate a terminal result. The shared result-commitment helper, explicit lock ownership contracts and reconciliation outside outer lock scopes avoid competing result truth and recursive locking.
- Descriptor-relative custody, bounded migration/index operations, allocating intent before record publication, no history scans, stable owner/journal inodes and nonblocking owner rechecks remain appropriate. The complete resulting diff must enforce these rules across all mutation paths.
- Pointer publication before retirement and direct original UUID reads preserve history. Pointer metadata grants no adoption or economic authority; existing context, signature, hardware, freshness and config validation remain required.

These conclusions are design findings, not proof that an implementation satisfies the specified crash and race tests. The full combined code/security/architecture audit remains required after implementation.

## Validation

Verified the exact r3 digest, compared the full r2-to-r3 delta against previously reviewed unchanged sections, and traced current cleanup's primary-record write. No runtime tests were executed for this plan-only review and no source files were changed.
