# Reservation maximum-shape result r3 — independent Sol evidence gate

Verdict: **PASS — 0 Critical, 0 High, 0 Medium, 0 Low.** The exact pinned
measurement result supports repeated-prefix starvation at the supported maximum
fixture shape on the measured Mac. It establishes the need for bounded progress
or an equivalent correction to the current reset-to-prefix search. It does not
approve a structural implementation, a runtime rollout, MLX inference, or
hardware qualification.

Independent native GPT-5.6 Sol adversarial review. Worktree:
`/Users/augstar/.codex/worktrees/macprovider/product-build-1`; observed HEAD
`914f7cafcdbcfc1805a10f4f34167218341d5587`. This review was read-only except
for this report. No SwiftPM command was run and no plan, source, test, evidence,
or log was edited.

## Critical

No findings.

**Evidence:** All five supplied SHA-256 identities match the files reviewed.
The selected XCTest passed, all required fixture and per-call checks are
throwing/fail-fast, and the full log contains no abort or contrary outcome.

**Consequence:** No evidence defect permits a failed prerequisite, successful
scan/allocation, mutation, or incomplete attempt to be accepted as the claimed
six-call experiment.

**Required correction:** None.

## High

No findings.

**Evidence:** The result is explicitly scoped to local production-path storage
behavior on the available Mac. It excludes MLX inference, hardware
qualification, runtime implementation approval, and production evidence.

**Consequence:** The measurement cannot be used as release, hardware, or
complete Build 1 authorization.

**Required correction:** None.

## Medium

No findings.

**Evidence:** Counts, timing, counter semantics, fixture conformance,
preservation, and cleanup all satisfy the approved R3 contract as detailed
below. The interpretation remains bounded to the measured current source and
fixture.

**Consequence:** The zero-Critical/High/Medium result-evidence gate is met.

**Required correction:** None.

## Low

No findings.

**Evidence:** The result's wording that the evidence establishes necessity for
the planned bounded-progress fallback is immediately constrained by its express
statement that the result does not select or approve an implementation. Read in
that stated scope, necessity means that the present reset-to-prefix behavior
needs bounded progress or an equivalent remedy; it does not mean the evidence
alone proves every detail of the separately approved R4 persistence design is
the only possible implementation.

**Consequence:** No editorial change is needed to prevent structural approval
or hardware-qualification overclaim.

**Required correction:** None.

## Artifact integrity

The exact reviewed bytes match the supplied manifest:

| Artifact | SHA-256 |
| --- | --- |
| `reservation-max-shape-measurement-r3.md` | `2320b84909c1d0eec24e317af2bedf5bc33c3fc81fc87e7c2149a8b0de57dd77` |
| `reviews/reservation-max-shape-measurement-r3-sol.md` | `1c06799ac0e2414937fc560170cb009f077b96a48149525179adf57e52ef3267` |
| `ModelCatalogReservationCapacityMeasurementTests.swift` | `69fa2294b0036e4a35bc7d2ec63eecf89b36fb4fb23e5f46a14c7da8de9a5e21` |
| `evidence/reservation-max-shape-measurement-result-r3.md` | `e6365c4b8c638419ac3f47c6998d2af4772a58735c79047fd095530735f87f5c` |
| `.omx/artifacts/build1-reservation-max-shape-r3.log` | `311ce7f23630815e0562ae6c93e57f1eda031dd9d3c5a40883b474bb0b152941` |

The approved measurement plan and its independent approval therefore apply to
the exact test and result under review.

## Counts and timing

Independent parsing of the complete 38-line log found:

- eight `RESERVATION_MAX_SETUP` lines, exactly one for each 128-record boundary
  from 128 through 1,024;
- one fixture line reporting 1,024 records, 2,048 events each, 4,194,304 bytes
  each, 4,294,967,296 total primary bytes, and a 174,293-byte index;
- one feasibility line reporting maximum decode 1.640421416 seconds and capture
  plus proof validation 0.96116775 seconds, both below eight seconds;
- exactly six call lines: three `terminal_last` and three `queued_last`, attempts
  0, 1, and 2 in each scenario;
- six typed `busy` outcomes, six `bulk_read=585`, six `index_decode=1`, and six
  `reservation_scan_started=1` observations;
- zero `RESERVATION_MAX_ABORT` lines; and
- one selected XCTest passed with zero failures, zero unexpected failures, and
  1,223.543 seconds elapsed. The three identical XCTest suite summaries describe
  the same one selected test. The trailing Swift Testing runner selected zero
  tests and is correctly excluded.

All six call durations are at least eight seconds: 8.001900458,
8.44275275, 8.355836667, 8.518523917, 8.835731583, and 8.435250584
seconds. Their sum is 50.589995959 seconds. Setup completed in
1,167.803722042 seconds, 332.196277958 seconds below the reviewed 1,500-second
ceiling. Initial free space was 78,461,747,200 bytes against the exact
12,884,901,888-byte threshold, and every recorded checkpoint retained ample
free space.

## Fixture conformance and fail-fast coherence

The pinned test constructs `ModelCatalogTransactionStore.activeTransactionLimit`
records, which is 1,024 in the inspected production source. Every primary is
padded to the production 4,194,304-byte evidence limit. Every terminal fixture
record has the production maximum 2,048 sequential identity-bound events and is
passed through production `decodeRetentionRecord`; the decoded record validator
enforces UUID/generation, kind, model identity fields, hashes, revision,
nonempty events, the 2,048-event cap, exact event identity, and sequential event
numbers. The allocated origin is validated against the decoded primary digest
before descriptor-relative publication.

The active index is then production-decoded and checked for exactly 1,024
distinct, sorted, active allocated entries. The first 1,023 records are
unresolved `prepare_model` records whose final state is `running`. The last is
an `evaluate_model` record whose final event is `cancelled`, and production
decoding confirms it alone is terminal. The queued scenario writes the saved
exact 4-MiB queued bytes only after the complete terminal preservation boundary,
then checks allocated initial-primary binding, exact digest and metadata, one
queued event, nil `startedAt`, freshness, nonterminal/uncommitted state, and a
production locked receipt validation before its first call.

Every decision-critical check routes through `validate`, `require`, or
`requireValue`. Failure prints `RESERVATION_MAX_ABORT`, records `XCTFail`, and
throws immediately. The passing XCTest plus absence of an abort therefore
establishes that no failed setup, feasibility, per-call, transition, or
preservation predicate continued into later measurement work.

## Counters, state, and preservation

The phase probe prints only counters it observed. The pinned test separately
reads every required counter and fail-fast requires, after each logged call and
before the next call, exactly one scan start, zero scan completions, zero
retirement captures, zero cursor publications, exactly one index decode, and
more than 65 bulk reads. It also requires a byte-identical active index,
identical pinned index metadata, and absent `maintenance.json`. Thus the omitted
zero-valued counter names in each concise log summary are supported by the
passing assertion path; they are not inferred merely from missing text.

Both scenario boundaries compare metadata for all 1,024 primary files and all
1,024 origin files. They also require every per-record retired/result/seal/
cleanup/success-binding sidecar, every staging directory, and the recommendations
directory to remain absent. Finally, each boundary captures a fresh production
receipt and checks the last-slot primary and origin digests against the validated
pre-call receipt. The terminal-to-queued write is unreachable until terminal
preservation passes, and final success is unreachable until queued preservation
passes.

Cleanup is exact-root scoped: the test creates one UUID-named
`ReservationMaximumShape-*` root with mode `0700` and defers removal of that
exact URL. An independent post-run search of the actual Darwin user temporary
directory found zero matching roots. This corroborates the result's teardown
claim; no repository or operator-secret path participates.

## Starvation and necessity conclusion

Production `reserveOperation` decodes the unchanged sorted active index and
enumerates active entries from position zero on every call. It does not publish
or consult a reservation-search cursor before this loop. The first 1,023
records are valid but cannot match an `evaluate_model` reservation because they
are `prepare_model`; the final record is the only relevant slot, terminal and
reclaimable in the first scenario and queued and reusable in the second.

A 4-MiB primary takes 64 successful 65,536-byte reads plus the terminating EOF
read, so 585 observed `bulk_read` callbacks equal nine fully read primaries.
Because all six calls begin from the same byte-identical sorted index, preserve
maintenance absence, and stop without scan completion, the identical 585-read
count represents the same nine-record prefix on every attempt. The final slot
at position 1,024 is therefore not reached in either scenario within the
unchanged default eight-second operation budget.

This is direct evidence of repeated-prefix starvation for the exact measured
source, fixture, filesystem, and Mac. It shows that repeating the current call
cannot accumulate progress and that a bounded-progress/non-reread property, or
an equivalent correction satisfying the same maximum-shape requirement, is
necessary. The independently approved R4 design remains a separately gated way
to supply that property. This result neither implements nor approves R4 and
does not prove that its particular persistence representation is the only
possible implementation.

The result also makes no hardware-performance generalization: it records one
local production-path storage measurement and no MLX inference. Replay is
correctly required if rebasing changes the measured reservation, retention,
evidence, budget, or fixture source.
