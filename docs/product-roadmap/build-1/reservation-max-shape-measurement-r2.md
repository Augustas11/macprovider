# Reservation maximum-shape measurement r2

Status: corrected measurement-only plan for root review. This revision does not
approve or implement reservation-v4, alter production scheduling, change the
eight-second reservation budget, or authorize artificial latency. It replaces
the setup ceiling and failure interpretation in
`reservation-max-shape-measurement-r1.md`; every other r1 fixture, validity,
custody, preservation, and observation requirement remains in force, pinned at
SHA-256 `33e130ae641b711907eec4b5b5ec50e7953ce5093933ba7bd0ef4aa11a6f95e5`. The
separate structural fallback remains
`reservation-search-progress-addendum-r4.md`, SHA-256
`3bb911a0793f569226c9ca103e3607f9563e864fb688dbb5a57e0594d6071b21`, and still
requires its own independent approval before implementation.

## Corrected evidence

Swift36 did not measure reservation search. It failed only with
`setupDeadline` after 602.827 seconds, before `measureThreeCalls` was reached;
therefore zero reservation calls and zero starvation observations were made.
The measured test source had SHA-256
`3c4426a3bf50da25c56891c873ec4acc8a830aa7626b2e8aada1ed3a65cec33a`.
The durable log `/tmp/build1-capacity-swift36.log`, SHA-256
`20e5a291c536415d5b419934b16f24f7b3315065c1ad51fb73746b434add4516`, reported:

| Completed records | Cumulative seconds | Block seconds | Seconds/record in block |
| ---: | ---: | ---: | ---: |
| 128 | 150.812 | 150.812 | 1.178 |
| 256 | 279.846 | 129.034 | 1.008 |
| 384 | 413.756 | 133.910 | 1.046 |
| 512 | 550.186 | 136.430 | 1.066 |

Linear extrapolation from the measured 512-record cumulative rate is 1,100.371
seconds for 1,024 records. Repeating the slowest observed 128-record block eight
times is 1,206.499 seconds. Use a 1,500-second monotonic setup ceiling: this is
399.629 seconds (36.3%) above the linear projection and 293.501 seconds (24.3%)
above the slowest-block projection. It is a bounded allowance for later-volume
variation on this Mac, not a production operation-budget change.

The run began with 76,998,303,744 available bytes. Retain the preflight
requirement of at least 12 GiB available. The fixture remains exactly 1,024
primary files of 4,194,304 real bytes each (4 GiB total), plus their bounded
origins, index, and one saved alternative primary. Never reduce the record,
event, or byte shape to meet time or disk limits.

## Exact corrected protocol

Change only the measurement test's setup instrumentation and ceiling. Do not
modify production code, production limits, the reservation algorithm, other
tests, or the fixture authority. The correction must:

1. Start one 1,500-second monotonic deadline immediately before record
   construction. Check it before and after every record and before publishing
   the completed active index. Keep one test-owned `0700` temporary root and
   the existing exact-root deferred cleanup.
2. At each 128-record checkpoint, emit cumulative seconds, latest block seconds,
   completed records, validated primary bytes, and current available filesystem
   bytes. These values are observations only; they do not adapt the fixture or
   extend the deadline.
3. Construct exactly 1,024 distinct, sorted, production-schema records, each
   exactly 4,194,304 bytes. In the terminal scenario every record has exactly
   2,048 valid sequential identity-bound events. The first 1,023 remain
   unresolved and the last is the legitimate cancelled, uncommitted reclaimable
   slot described by r1.
4. Run every padded primary through production `decodeRetentionRecord`, validate
   its allocated origin and exact digest/provenance, and publish it through the
   descriptor-relative fixture writer. Populate the initialized production
   index with all 1,024 real entries. Sparse files, invalid JSON, unknown fields,
   duplicate keys, impossible event sequences, fixture-only validation, or
   reservation-loop construction remain forbidden.
5. After complete setup, prove the last record's active receipt, index/origin
   provenance, retirement proof, and individual under-eight-second capture plus
   strict-validation feasibility under the production global-lock path. No
   measured reservation call starts before all setup and feasibility assertions
   pass.
6. Run the same six production reservation calls specified by r1: three against
   `terminal_last`, then replace only the final primary with its exact original
   4-MiB queued bytes and run three against `queued_last`. The preceding 1,023
   primaries retain 2,048 events; the reusable queued primary necessarily has
   its one valid queued event. Each call uses the unchanged default eight-second
   budget and fresh operation-local receipts. Supply no delay, substitute clock,
   byte-limit override, helper budget, or timeout extension.
7. Retain r1's exact phase counters and assertions for every call, including one
   index decode, scan start without completion, no retirement/cursor publication,
   typed `busy`, elapsed budget evidence, and unchanged index/maintenance state.
   Retain the final full metadata, digest, sidecar-absence, queued-receipt, and
   exact-root cleanup checks.

## Abort and interpretation rules

- If initial free space is below 12 GiB, fail `insufficientDisk` before fixture
  creation. Do not shrink the fixture.
- If the 1,500-second setup deadline expires, emit one final setup-abort line
  containing completed records, validated bytes, cumulative seconds, the latest
  128-record block rate, and available bytes; fail `setupDeadline`, clean only
  the test root, and run no reservation calls. This result is inconclusive about
  starvation.
- Any setup encode, strict decode, origin/provenance validation, publication, or
  index error fails setup and cleans the test root. It is not reservation-search
  evidence and must not be retried with weaker validity or a smaller shape.
- If one full production capture plus strict validation cannot fit inside eight
  seconds, report `perRecordFeasibility` and run no reservation calls. This is a
  distinct maximum-record feasibility result, not repeated-prefix starvation.
- Once measurement begins, unexpected `unsafe`, malformed evidence, publication
  failure, missing fixture data, completed scan, or successful allocation is
  reported exactly and aborts the applicable scenario. A completed scan or
  allocation falsifies the expected natural-storage starvation result; do not
  add latency or enlarge the operation budget to recover the expectation.
- Only six completed typed-`busy` calls with the required counters and preserved
  state support a repeated-prefix starvation conclusion. Setup progress alone,
  including 512/1,024 records, supports no such conclusion.

## Exact verification and handoff

The execution owner runs only:

```bash
cd phase3-binary
swift test --filter 'ModelCatalogReservationCapacityMeasurementTests/testMaximumShapeNaturalStorageReservationProgress'
```

Acceptance requires one selected test with zero failures; a complete
`RESERVATION_MAX_FIXTURE` line proving 1,024 records, 4,294,967,296 primary bytes,
and terminal-scenario 2,048 events per record; eight 128-record setup checkpoints;
one individual feasibility result below eight seconds; exactly six
`RESERVATION_MAX_CALL` lines (three per scenario), each with the r1 counters and
typed `busy`; preservation assertions after both scenarios; and cleanup of the
exact temporary root. Archive the full command output and its SHA-256. Record a
contrary or aborted result without relabeling it as a pass.

This planning lane performs no SwiftPM invocation and edits neither the test nor
runtime. Root review of this r2 plan is a handoff for measurement correction,
not independent approval of the measurement result or the R4 fallback.
