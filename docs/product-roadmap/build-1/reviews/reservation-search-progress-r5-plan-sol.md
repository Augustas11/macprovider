# Build 1 reservation search progress R5 — independent plan gate (Sol)

Date: 2026-09-11. Reviewer: independent GPT-5.6 Sol plan-gate lane.

Verdict: **FAIL / NOT APPROVED FOR IMPLEMENTATION**. Architectural status:
**BLOCK**. Findings: **0 Critical, 3 High, 1 Medium, 0 Low**.

R5 contains sound local corrections for the frozen R4 defects, but the combined
protocol is not yet implementable at the retained 1,024-entry, eight-second,
per-entry-concurrency, and permanent-history contracts. The gate requires zero
Critical, High, and Medium findings, so source or test changes must not begin
from this revision.

## Frozen inputs

The review independently recomputed and matched all requested SHA-256 values:

| Input | SHA-256 |
|---|---|
| `reservation-search-progress-addendum-r5.md` | `051eb952608bf05810211d4c4a9f68133b185ff8fe3a41d34756944621859e78` |
| `test-spec-r11-reservation-r5-corrections.md` | `96a51cb48d27fcd2f960158a9b1adde93bb72782802b477dc4cf30559c7a5ae0` |
| Governing `reservation-search-progress-addendum-r4.md` | `3bb911a0793f569226c9ca103e3607f9563e864fb688dbb5a57e0594d6071b21` |
| Frozen R4 code audit | `db50512be6b61a9dc509a5add0d7987bb0d8b69eeb8130cd0f2381cfab77f112` |
| Frozen R4 security audit | `c07a7034ed92b9734bc07b8bd4a106cd8aa47e3c05d0ad1d6185b85bad673ec7` |
| Frozen R4 architecture audit | `1250819d1d24351abe55fca163bcfdf962ccd4d403b7810b78de8a9920d25c4e` |

The six current source files also match the R4 frozen implementation manifest:
`ModelCatalogTransactionBindings.swift` `60abe294...`,
`ModelCatalogTransactionEvidence.swift` `b49c13fa...`,
`ModelCatalogTransactionMigration.swift` `5bc526e3...`,
`ModelCatalogTransactionReservationMigration.swift` `c8505d5d...`,
`ModelCatalogTransactionRetention.swift` `0a6b4873...`, and
`ModelCatalogTransactions.swift` `65cbb0e9...`. The source was inspected only
to test plan feasibility; it was not edited.

## Finding R5-PLAN-H1 — all-member predecessor validation has an unbounded maximum-state fanout

**Severity:** High. **Confidence:** High.

**Evidence.** R5 requires every production mutation to capture and revalidate
the all-member reservation graph (`reservation-search-progress-addendum-r5.md:
154-161`). A pending member must validate its receipt and predecessor rules
(`:174-185`), and recovery must open and hash that receipt's full predecessor
index and progress documents (`:269-310`). At the same time, R4's retained
contract permits per-entry pending publications so UUID B can heartbeat without
acquiring or finishing UUID A (`reservation-search-progress-addendum-r4.md:
453-474`). The active limit remains 1,024 and each predecessor root remains
accepted up to 1,048,576 bytes (`reservation-search-progress-addendum-r5.md:
51-57,281-286`). Therefore a legal index can contain as many as 1,024 unrelated
pending publications whose independent proof fanout approaches 2,048 MiB of
predecessor bodies before receipt and per-entry evidence are counted. R5 gives
no bounded aggregate, checkpoint, validation cache with authenticated
invalidation, or maximum pending-work rule that reconciles this graph with one
eight-second caller budget.

R11 tests only two simultaneous pending UUIDs (`test-spec-r11-reservation-r5-
corrections.md:170-191`). Its 1,024-entry cases cover the owner sweep, a completed
origin/class/left graph, and acknowledged maximum-shape progress (`:84-103,
215-236`), not 1,024 legal pending receipts followed by an unrelated heartbeat,
cancel, commit, reservation, or retirement. The current code demonstrates why
this matters: ordinary heartbeat captures and commits an active receipt every
five seconds (`ModelCatalogTransactions.swift:807-827`), and R4 explicitly
forbids a global pending gate.

**Consequence.** A valid maximum-capacity journal can make every unrelated
writer exhaust its unchanged budget while proving other UUIDs' predecessor
graphs. This recreates a migration-wide availability gate, can cancel live work
when heartbeat capture fails, and makes the stated per-entry concurrency and
eight-second guarantees mutually unprovable. Two-UUID tests cannot establish
the maximum-state bound.

**Required correction.** Define a bounded authenticated transition structure
whose validation cost is independent of the number and historical size of
unrelated pending receipts, while preserving each target receipt, concurrent
refs, and exact predecessor semantics. State the maximum bytes, opens, decodes,
and lock-held work for every ordinary mutation at 1,024 pending members. Extend
R11 with the exact maximum pending graph and run heartbeat, cancel, commit,
reserve, allocation recovery, and retirement through it under the original
budget; prove UUID B does not acquire or finish UUID A and does not lose its
heartbeat. If R5 instead limits concurrent pending work, that is a changed R4
availability contract and requires a separately reviewed governing revision.

## Finding R5-PLAN-H2 — permanent full predecessor snapshots have no storage bound or failure contract

**Severity:** High. **Confidence:** High.

**Evidence.** Before each class or first-left receipt, R5 writes the exact full
predecessor index and progress bytes and retains both content-addressed files
forever, including unreferenced prepared predecessors (`reservation-search-
progress-addendum-r5.md:269-286`). The index and progress limits remain 1 MiB;
one maximum source lifecycle can perform up to 1,024 first-class publications
and 1,024 later first-left publications. Even with content-addressed
deduplication of identical complete progress, the admitted envelope is roughly
2 GiB of distinct index predecessors plus up to 1 GiB of classifying-progress
predecessors, before receipts (up to 128 KiB each) and other immutable evidence.
Later allocate/depart/retire cycles continue producing unique predecessor
indexes without a lifetime bound.

Neither R5 nor R11 defines free-space admission, a maximum archive size,
`ENOSPC`/quota behavior at predecessor publication and fsync, safe compaction,
or an operational way to recover capacity while preserving authority. R11-01
tests individual size envelopes and collisions; R11-04 tests `EMFILE`; R11-09
tests process death. None tests storage exhaustion or long-run retained-history
growth (`test-spec-r11-reservation-r5-corrections.md:15-34,84-103,193-213`).

**Consequence.** Normal bounded-capacity transaction churn can consume disk
without bound. Exhaustion can leave a pending or classifying journal unable to
publish the predecessor evidence required for forward recovery, globally
blocking reservation and eventually unrelated transaction mutation. The plan's
"retained forever" rule prevents an operator from recovering space safely.

**Required correction.** Replace full per-publication snapshots with a bounded
closed predecessor representation or specify a reviewed compaction/checkpoint
scheme whose retained root still proves every authorized transition. Publish a
worst-case per-operation and lifetime storage budget. Define preflight and
`ENOSPC`/quota outcomes before and after every durable boundary, including how a
blocked journal recovers without deletion of live authority. Add maximum-envelope,
long-run churn, near-full-disk, injected-`ENOSPC`, crash, and retry cases with
exact byte-growth assertions.

## Finding R5-PLAN-H3 — retirement can still orphan post-completion departure authority

**Severity:** High. **Confidence:** High.

**Evidence.** R5 says current complete-phase departure evidence is monotonic and
retirement cannot strand a receipt, class, left, progress acknowledgment, or
predecessor link (`reservation-search-progress-addendum-r5.md:240-247,342-346`).
It does not define the durable root that preserves a first-left publication made
after the frozen migration projection. The current retirement CAS removes the
entire active entry (`ModelCatalogTransactionRetention.swift:612-630`). The
retirement certificate schema binds the origin and terminal result/primary
snapshot, but contains no reservation class digest, left digest, publication
receipt digest, or predecessor lineage (`ModelCatalogTransactionBindings.swift:
77-103`; `ModelCatalogTransactionArchive.swift:62-100`). For an allocated record
that first departed while running and was later retired terminal, its left file
binds the first nonreusable primary, which need not equal the terminal primary
stored by the retirement certificate (`ModelCatalogTransactionReservationMigration.swift:
318-340`). The frozen completion projection cannot bind that later left.

R11-03 proves only the immutable migration-completion graph and later current
membership separation; R11-07 and R11-11 require pending recovery before
retirement but do not require an archived authority root for a post-completion
left after membership removal (`test-spec-r11-reservation-r5-corrections.md:
60-82,145-168,238-259`). File retention alone is not a reference or an authority
graph.

**Consequence.** Retirement can clear the only active-index reference to a
valid post-completion departure receipt/left. The bytes may remain on disk, but
after restart no durable accepted artifact proves which later left digest was
authoritative. This violates R5's monotonic-exclusion and no-stranding claims and
leaves rollback/replay validation incomplete for retired dynamic members.

**Required correction.** Define a versioned retirement/archive artifact that
binds the exact reservation class, anchored left, completed publication receipt,
and required predecessor lineage before membership removal. Specify compatibility
for existing v1 retirement certificates and exact crash ordering between the
new archive publication and index removal. Add a post-completion allocated
record that starts, publishes its first left, later terminates, retires, and
restarts; deletion/substitution/replay of each class/left/receipt/predecessor
must fail archived validation, and no old or new path may re-add or run the UUID.

## Finding R5-PLAN-M1 — restart-time same-byte inode rejection is not representable by the proposed schemas

**Severity:** Medium. **Confidence:** High.

**Evidence.** R5 requires finalizing recovery to reject a same-byte new inode
before writing complete (`reservation-search-progress-addendum-r5.md:193-205`),
and R11-01 applies the same-byte-new-inode case to predecessor, install, and
projection schemas (`test-spec-r11-reservation-r5-corrections.md:15-30`). The
proposed completed projection and install-v2 fields persist hashes, UUIDs,
generations, and lineage, but no filesystem identity (`reservation-search-
progress-addendum-r5.md:207-238`). Current `ModelTransactionFileEvidence`
captures `stat` identity only in memory and compares it from capture through the
final CAS (`ModelCatalogTransactionEvidence.swift:35-95`). After process death,
a same-byte replacement performed before recovery's first capture has the same
path, digest, decoded fields, mode, owner, and link count; no proposed durable
value distinguishes its inode.

**Consequence.** A conforming implementation cannot satisfy the literal R5/R11
restart matrix. A test can prove replacement during one capture/CAS interval,
but cannot honestly prove replacement that occurred before a fresh recovery
capture. This can yield a false pass through test timing or force an
unreviewed filesystem-identity authority into source.

**Required correction.** Choose and state one coherent contract. Prefer treating
identical bytes at a content-addressed path as equivalent before capture, while
requiring inode/metadata stability from capture through final CAS; update R5 and
R11 to distinguish pre-capture byte-equivalent replacement from mid-capture
replacement. If durable inode identity is truly required, define its persisted
schema, filesystem/backup semantics, compatibility, and recovery behavior and
review that new authority explicitly.

## Disposition of every frozen R4 finding

| Frozen finding | R5 disposition |
|---|---|
| R4-CODE-H1 / architecture H2 | Sequential owner probes and detached witnesses correct descriptor-proportional ownership locally. Not closed because H1 shows the combined pending graph is still unbounded in bytes/work. |
| R4-CODE-H2 / R4-SEC-H2 | The global typed allocating-intent gate and three-way generation equality are sufficient at plan level. R11-06 directly exercises the hostile table. |
| R4-CODE-M1 / R4-CODE-M2 / architecture H1 | The pre-mutation all-member validator and pre-write finalizing validation address the original omissions. H1, H3, and M1 identify remaining feasibility and authority gaps in that replacement design. |
| R4-CODE-M3 / R4-SEC-H1 / architecture M2 | Same-owner stabilization, pending-first-left rollback rejection, and pre-retirement recovery address the direct defects. H3 shows the plan does not preserve the resulting post-completion authority after retirement. |
| R4-SEC-M1 | The content-addressed install/projection chain closes coherent different-byte replacement and the original UUID-only lookup. M1 requires correction of the stronger inode claim. |
| R4-SEC-M2 | Exact predecessor snapshots and monotonic merge rules close the two-UUID lineage defect logically. H1 and H2 show this representation is not bounded or sustainable at the retained maximum and lifetime contracts. |
| Architecture M1 | Typed busy for queued cancellation without custody is sufficient and R11-07 includes the controlling race. |
| R4-CODE-M4 / architecture H3 | R11 is substantially broader and correctly requires real child death and frozen evidence. It cannot prove the current plan because it omits maximum pending-graph work, permanent-history storage/ENOSPC, and post-retirement dynamic-left authority. |

## Positive review results

The sequential journal-locked owner sweep has a coherent nonblocking lock-order
argument provided the actual supported prior binary proves every named final
format fence. The allocation correction blocks all fresh search/allocation on
any unresolved intent and adds the missing exact generation equality. The
same-owner stabilization rule removes the current double-flock path, the queued
cancel rule prevents false success, and pre-retirement pending recovery preserves
the active interlock. The install/projection digest arrangement avoids the R4
hash cycle and binds different content at direct validated paths.

These positive results do not offset the four gate findings.

## Verification and gate decision

Verification was static and adversarial because this is a pre-implementation
plan gate. It included exact hash verification, line-level tracing of allocation,
publication, finalization, active receipt, heartbeat, cancellation, and retirement
paths, maximum FD/body/index limits, authority roots, crash ordering, rollback,
replay, concurrency, compatibility, and the complete R11 matrix. No test command
was treated as evidence for unimplemented R5 behavior.

Final recommendation: **REQUEST CHANGES / FAIL**. Revise the plan and paired test
spec to close R5-PLAN-H1 through H3 and R5-PLAN-M1, freeze new SHA-256 values, and
obtain a fresh independent zero-Critical/High/Medium plan gate before any source
or test edit.
