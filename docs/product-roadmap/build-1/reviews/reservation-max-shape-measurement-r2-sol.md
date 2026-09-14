# Reservation maximum-shape measurement r2 — independent plan/test-spec gate

Verdict: **REJECTED — 0 Critical, 0 High, 1 Medium, 0 Low.** The 1,500-second
setup ceiling is evidence-justified and the exact maximum-shape/resource
constraints remain sound, but the correction scope does not authorize the
fail-fast changes needed for the current test to produce the plan's decisive
six-call evidence.

Exact reviewed proposal SHA-256:
`2e8991bb8db13e857b5913d1b0a91c49d4729c9758a298564eedb70c2472671b`.
Independent native GPT-5.6 Sol review. Base and observed HEAD:
`914f7cafcdbcfc1805a10f4f34167218341d5587`; worktree
`/Users/augstar/.codex/worktrees/macprovider/product-build-1`. Reviewed r2,
its pinned r1, the approved R4 structural fallback and review, the Build 1
checkpoint, the exact Swift36 log, the measured test source, and the current
reservation/budget seams. Only this report was written. No SwiftPM command,
runtime/test edit, service action, or delegation was performed.

## RMSM2-M1 — The permitted edit scope leaves nonfatal prerequisites and contrary observations in place

**Severity: Medium.**

**Evidence:** R2 limits the implementation to changing “only the measurement
test's setup instrumentation and ceiling” (`reservation-max-shape-measurement-r2.md:47-49`).
It separately requires that no reservation call begin unless the individual
capture plus strict-validation proof completes below eight seconds
(`:70-74`, `:100-102`) and that a completed scan or other unexpected
measurement observation abort the applicable scenario (`:103-107`). The
current pinned test does not enforce those stop conditions. Its combined
capture/proof timing uses `XCTAssertLessThan` and then unconditionally enters
`measureThreeCalls` (`ModelCatalogReservationCapacityMeasurementTests.swift:89-101`).
Within each measured call, only an unexpected thrown error, a returned
reservation, or non-`busy` outcome throws. Scan completion, retirement/cursor
publication, a wrong index-decode count, inadequate read evidence, changed
index bytes/metadata, and a new maintenance cursor use nonthrowing
`XCTAssert*` checks, after which the loop continues (`:141-158`). The
post-scenario preservation helper likewise records nonfatal failures and
returns (`:161-173`), allowing the test to replace the terminal primary and
run the queued scenario after contrary mutation evidence. XCTest assertion
failures make the final test red but do not stop this control flow.

**Consequence:** A run can execute later reservation calls after the stated
per-record feasibility prerequisite has failed, or can continue after a
completed scan, unexpected publication, changed index/cursor state, or primary
or origin mutation. In the latter case it can overwrite the final primary and
produce queued-scenario lines from a fixture already shown not to satisfy the
required baseline. The ultimate nonzero test result prevents formal
acceptance, but the six emitted call lines are no longer one coherent
experiment and the later observations cannot be interpreted under r2's
preserved-state assumptions. Leaving the current nonfatal control flow while
claiming the plan was implemented would also violate r2's explicit abort rule;
changing it would exceed the plan's stated setup-only edit scope.

**Required correction:** Expand the authorized test-only correction narrowly
to make every experiment prerequisite and falsifying per-call/preservation
condition fail-fast before the next reservation call or scenario transition.
The individual capture/proof duration must throw
`perRecordFeasibility` when it is not below eight seconds. After logging each
call, validate the complete required counter/outcome/index/maintenance set with
a throwing guard (or equivalent helper) and throw `unexpectedProgress` on any
mismatch. Preservation failure after `terminal_last` must throw before writing
the queued replacement; preservation failure after `queued_last` must also
terminate. Keep the final XCTest failure, exact diagnostic line, six-call
acceptance rule, unchanged eight-second production budgets, and every r1/r2
fixture and evidence criterion. Do not convert a contrary or aborted run into
a pass and do not modify production code.

## Ceiling, resource, shape, and evidence assessment

The proposed setup ceiling is adequately grounded for a bounded measurement
retry. Swift36's raw checkpoints were 150.812428917, 279.846198375,
413.755973834, and 550.185567459 cumulative seconds at 128-record intervals.
Doubling the 512-record cumulative time yields 1,100.371134918 seconds; repeating
the slowest observed block eight times yields 1,206.499431336 seconds. A
1,500-second ceiling adds 399.628865082 seconds (36.3%) over the linear
projection and 293.500568664 seconds (24.3%) over the conservative block
projection. The prior run ended only on its 600-second setup deadline after
602.827 seconds, before any reservation call. Because r2 treats another setup
expiry as inconclusive and forbids adapting record shape or operation budgets,
the larger test-only ceiling does not manufacture reservation evidence.

The resource contract remains bounded and proportional. Swift36 began with
76,998,303,744 available bytes; the current filesystem reports about 72 GiB
available, and r2 retains a fail-before-write 12 GiB threshold for 4 GiB of
real primary bytes plus bounded origins, a maximum 1 MiB index, and one 4 MiB
saved queued primary. Construction retains bounded per-record buffers, uses one
test-owned `0700` temporary root, emits available bytes at every 128-record
checkpoint, does not adjust shape from those observations, and removes only
that exact root. Setup errors and deadline expiry remain non-evidence and clean
the same root.

R2 also preserves the valid maximum terminal shape: exactly 1,024 sorted,
distinct production-schema records, exactly 4,194,304 real bytes each, and
exactly 2,048 valid identity-bound events per terminal-scenario record. Every
padded primary must pass production closed decoding and its distinct allocated
origin/digest/provenance validation before publication. The queued-last phase
changes only the final primary to its exact origin-bound initial bytes; its one
queued event is the necessary valid reuse shape, while the preceding 1,023
records remain maximum-event bodies. Sparse or malformed stand-ins, fixture-only
validation, artificial latency, clocks, helper budgets, and production-limit
changes remain forbidden.

With RMSM2-M1 corrected, the six-call contract is decisive for the stated
question: three `terminal_last` and three `queued_last` calls, each under a
fresh unchanged eight-second budget, must all return typed `busy`, start but
not complete the scan, publish no retirement/cursor state, decode one active
index, demonstrate more than one full-primary read worth of attempts, and
preserve exact index, primary, origin, receipt, and sidecar state. A completed
scan/allocation or any malformed/mutated state remains contrary evidence. This
natural-storage measurement can establish repeated-prefix starvation or
falsify that expectation; it does not approve R4, implement v4, or establish
the complete Build 1 gate.

## Snapshot manifest

| Evidence | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/reservation-max-shape-measurement-r2.md` | `2e8991bb8db13e857b5913d1b0a91c49d4729c9758a298564eedb70c2472671b` |
| `docs/product-roadmap/build-1/reservation-max-shape-measurement-r1.md` | `33e130ae641b711907eec4b5b5ec50e7953ce5093933ba7bd0ef4aa11a6f95e5` |
| `docs/product-roadmap/build-1/reservation-search-progress-addendum-r4.md` | `3bb911a0793f569226c9ca103e3607f9563e864fb688dbb5a57e0594d6071b21` |
| `docs/product-roadmap/build-1/reviews/reservation-search-progress-r4-astra.md` | `0a311a1aca39c60953943f43e47f6a2adc506bff736bddfe003fda69fb05ddbf` |
| `docs/product-roadmap/checkpoint.md` | `4502fa10b6b67c1200f426d43b37be2fc7e330383ff1ed55b5034a0d89068e6a` |
| `/tmp/build1-capacity-swift36.log` | `20e5a291c536415d5b419934b16f24f7b3315065c1ad51fb73746b434add4516` |
| `phase3-binary/Tests/macprovider-cliTests/ModelCatalogReservationCapacityMeasurementTests.swift` | `3c4426a3bf50da25c56891c873ec4acc8a830aa7626b2e8aada1ed3a65cec33a` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift` | `8140d9ee9f6d76b9784a1d92da73653b8c6a5c573ad40794c99d23d10886665f` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift` | `e79db53d8e7dd6d3bbe2bcc0554a05a33f13e5a22ad732a24b9b731a6a861f53` |

