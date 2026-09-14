# Reservation maximum-shape measurement r3 — independent plan/test-spec gate

Verdict: **APPROVED AT PLAN LEVEL — 0 Critical, 0 High, 0 Medium, 0 Low.**
RMSM2-M1 is completely corrected without weakening the fixture, operation
budget, observations, preservation checks, or six-call acceptance rule. No new
blocking defect was identified in the exact R3 proposal.

Exact reviewed proposal SHA-256:
`2320b84909c1d0eec24e317af2bedf5bc33c3fc81fc87e7c2149a8b0de57dd77`.
Independent native GPT-5.6 Sol review. Base and observed HEAD:
`914f7cafcdbcfc1805a10f4f34167218341d5587`; worktree
`/Users/augstar/.codex/worktrees/macprovider/product-build-1`. Reviewed R3,
its pinned R2, the prior Sol review, the pinned R1 method, the approved R4
structural fallback and review, the Swift36 log, the unchanged actual
measurement test, and the production reservation/budget seams. Only this
report was written. No SwiftPM command, runtime/test edit, service action, or
delegation was performed.

## Critical

No findings.

## High

No findings.

## Medium

No open findings.

### RMSM2-M1 — closed

**Prior severity:** Medium.

**Evidence:** The prior review found that R2 authorized only setup
instrumentation while the pinned test allowed decision-critical XCTest
assertions to continue into later calls or the queued transition. R3 removes
that scope conflict explicitly. Lines 39–46 authorize test-only conversion of
every decision-critical nonthrowing assertion throughout the measurement class,
and prohibit any such failure from reaching a later reservation call or the
terminal-to-queued transition. Lines 48–64 require each replacement to preserve
the production-derived predicate, emit a structured `RESERVATION_MAX_ABORT`,
record an XCTest failure, and immediately throw the correct measurement error.
The test must remain red; contrary evidence cannot be converted into an expected
error or accepted result.

R3 then closes every concrete continuation path present in the pinned test:

| Current test surface | R3 fail-fast requirement |
|---|---|
| Per-record event and byte assertions at lines 61–62; active-index and baseline maintenance assertions at lines 80–81 | Exact shape, production validation, 1,024 active entries, and absent baseline maintenance must throw before the first call (R3 lines 68–75). |
| Maximum decode and combined receipt/proof timing at lines 84–98 | Both unchanged under-eight-second predicates throw `perRecordFeasibility`; zero reservation calls follow (R3 lines 71–75). |
| Per-call elapsed, phase counters, read attempts, index bytes/metadata, and maintenance assertions at lines 147–157 | The complete unchanged decision set is one throwing validation after each logged call and before the next attempt (R3 lines 77–91). |
| Metadata/sidecar preservation at lines 161–173 and terminal digest checks at lines 103–105 | Full preservation plus exact terminal primary/origin digests must throw before queued replacement is reachable (R3 lines 93–99). |
| Queued receipt assertions and the nonthrowing allocated-provenance return at lines 111–120 | Exact saved bytes/metadata, allocated initial-primary binding, single queued event, state/freshness predicates, and locked receipt validation must throw before any queued call (R3 lines 101–106). |
| Final preservation and queued digest assertion at lines 122–124 | Full preservation and final digest equality must throw and terminate (R3 lines 108–112). |

R3 also accounts for optional values: `XCTUnwrap` may remain only where its
throw already prevents later measurement work; decision-critical optional
state requiring the structured abort must use the throwing guard. Existing
production errors still propagate rather than being relabeled. Finally, lines
123–126 require a source-review mapping of every current decision-critical
assertion before execution, preventing an implementation from treating the
enumerated examples as an incomplete allowlist.

**Consequence:** A later call cannot be interpreted as part of the same
experiment after a prerequisite, falsifying observation, or preservation
failure. In particular, the queued fixture cannot be written after terminal
mutation evidence. Fewer than six calls after an abort remain contrary or
incomplete evidence and cannot be combined across reruns. This directly
resolves the coherence defect from RMSM2-M1.

**Criteria preservation:** The correction changes only test control flow and
diagnostics. R3 retains R2 by exact digest and restates the unchanged decisive
criteria: 1,024 distinct sorted production-valid records; exactly 4,194,304
real bytes per primary; 2,048 valid events on every terminal record; production
decode/origin/provenance validation; exactly three `terminal_last` and three
`queued_last` calls; fresh default eight-second budgets; typed `busy`; elapsed
time at least eight seconds; exact phase counters; more than 65 honest
`bulk_read` attempts; byte-identical index and metadata; absent maintenance and
forbidden artifacts; exact terminal/queued digest preservation; and a red,
non-pass outcome for every abort or contrary observation. It authorizes no
production change, artificial latency, clock, byte-cap, fixture, event, or
budget adjustment.

## Low

No findings.

## Setup/resource and decisiveness assessment

The 1,500-second setup ceiling remains evidence-justified. Swift36 reached 128,
256, 384, and 512 records at 150.812428917, 279.846198375, 413.755973834, and
550.185567459 seconds. The four block times were 150.812428917,
129.033769458, 133.909775459, and 136.429593625 seconds. Doubling the measured
512-record cumulative time projects 1,100.371134918 seconds for 1,024 records;
repeating the slowest observed block eight times projects 1,206.499431336
seconds. The ceiling preserves margins of 399.628865082 seconds (36.3%) and
293.500568664 seconds (24.3%), respectively. It is checked monotonically and
does not alter the production eight-second call budget. Another setup expiry is
still an explicit inconclusive abort with zero reservation evidence.

The resource plan remains bounded and sufficient for the specified attempt.
The exact primary corpus is 4,294,967,296 real bytes. The 12 GiB preflight is
three times that corpus before bounded origins, the at-most-1-MiB index, and one
saved 4-MiB queued primary. Swift36 began with 76,998,303,744 available bytes;
this review observed 75,216,936 KiB available on the same data volume. R3
inherits the initial fail-before-write threshold, per-128 current-space and
timing observations, no adaptive fixture reduction or deadline extension, one
test-owned `0700` root, and exact-root deferred cleanup on success or throw.

Together with the fail-fast correction, a completed run is decisive for the
stated natural-storage question: six coherent passing observations support
repeated-prefix starvation, while a completed scan/allocation or other mismatch
is preserved as contrary evidence. A setup/resource or per-record feasibility
abort remains explicitly distinct and cannot be presented as starvation.

## R4 relationship and approval limit

The approved R4 structural fallback remains independently pinned at
`3bb911a0793f569226c9ca103e3607f9563e864fb688dbb5a57e0594d6071b21`, with
its zero-Critical/High/Medium architecture review pinned at
`0a311a1aca39c60953943f43e47f6a2adc506bff736bddfe003fda69fb05ddbf`.
R4 requires maximum-shape evidence after the smaller index correction and does
not permit its structural persistence layer merely because the plan exists.
R3 is consistent with that ordering: it authorizes only the corrected natural
storage measurement and neither approves a result nor implements or reapproves
R4. Its full maximum-shape fixture and per-record feasibility checks preserve
the evidence needed to decide whether the structural fallback is necessary.

This approval authorizes the narrowly specified future test correction only.
It does not certify the unchanged current test, a future implementation, a
measurement result, SwiftPM execution, R4 implementation, or the complete
Build 1 gate. The execution owner must first map and correct the source as R3
requires, then run only the named selected test and archive its exact output
and SHA-256.

## Snapshot manifest

| Evidence | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/reservation-max-shape-measurement-r3.md` | `2320b84909c1d0eec24e317af2bedf5bc33c3fc81fc87e7c2149a8b0de57dd77` |
| `docs/product-roadmap/build-1/reservation-max-shape-measurement-r2.md` | `2e8991bb8db13e857b5913d1b0a91c49d4729c9758a298564eedb70c2472671b` |
| `docs/product-roadmap/build-1/reviews/reservation-max-shape-measurement-r2-sol.md` | `579013a6478652ca0af03908ffbd832587a5b996f04fa14a6f5801497bda1628` |
| `docs/product-roadmap/build-1/reservation-max-shape-measurement-r1.md` | `33e130ae641b711907eec4b5b5ec50e7953ce5093933ba7bd0ef4aa11a6f95e5` |
| `docs/product-roadmap/build-1/reservation-search-progress-addendum-r4.md` | `3bb911a0793f569226c9ca103e3607f9563e864fb688dbb5a57e0594d6071b21` |
| `docs/product-roadmap/build-1/reviews/reservation-search-progress-r4-astra.md` | `0a311a1aca39c60953943f43e47f6a2adc506bff736bddfe003fda69fb05ddbf` |
| `docs/product-roadmap/checkpoint.md` | `4502fa10b6b67c1200f426d43b37be2fc7e330383ff1ed55b5034a0d89068e6a` |
| `/tmp/build1-capacity-swift36.log` | `20e5a291c536415d5b419934b16f24f7b3315065c1ad51fb73746b434add4516` |
| `phase3-binary/Tests/macprovider-cliTests/ModelCatalogReservationCapacityMeasurementTests.swift` | `3c4426a3bf50da25c56891c873ec4acc8a830aa7626b2e8aada1ed3a65cec33a` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift` | `8140d9ee9f6d76b9784a1d92da73653b8c6a5c573ad40794c99d23d10886665f` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift` | `e79db53d8e7dd6d3bbe2bcc0554a05a33f13e5a22ad732a24b9b731a6a861f53` |
