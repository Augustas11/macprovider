# Independent adversarial review — Build 1 origin/main 1d2 reconciliation R3

Date: 2026-09-11

Reviewer: native GPT-5.6 Sol, high reasoning, independent plan gate

## Reviewed inputs

- Plan: `docs/product-roadmap/build-1/origin-main-1d2-reconciliation-plan-r3.md`, SHA-256 `75381f4352ed4a54726f7b7857c1ba3205352f396ba348ebaa171974c010b41e`.
- Test specification: `docs/product-roadmap/build-1/test-spec-origin-main-1d2-reconciliation-r3.md`, SHA-256 `c68daee5c18636b8dd9528127dfdfe7cd23fee74f6f135696f1bcd430fa34aaa`.
- Failed R2 review: `docs/product-roadmap/build-1/reviews/origin-main-1d2-reconciliation-plan-r2-sol.md`, SHA-256 `3c8ccdf0d6bbb14b7ee0487c449f3b84341b4b32bfacd9d01e12bd9d1f1291cd`.
- Repository/base independently inspected in `/Users/augstar/.codex/worktrees/macprovider/build1-origin-1d2-verify`: exact `origin/main` `1d2c930bad81704dd0acc0322226725d8b64aceb`.
- Frozen dirty Build 1 recovery source remains HEAD `914f7cafcdbcfc1805a10f4f34167218341d5587`; it was inspected only as stated recovery context. No source or test file was edited.
- No `d-inference` source was inspected.

## Active Slice 5 resnapshot

Slice 5 moved repeatedly during this review. At the final read-only observation, `2026-09-11T01:25:01.682894Z`, `/Users/augstar/macprovider-byom-v02-slice5` was on branch `feat/byom-v02-slice5-intake-pipeline`, HEAD `815c8821914d73a2cc102e8895894a94dac8e38b`, merge base `1d2c930bad81704dd0acc0322226725d8b64aceb`, and seven commits above the base. It had 40 committed changed paths, two dirty tracked paths (`phase4-coordinator/cmd/coordinator/main.go` and `phase4-coordinator/internal/config/config.go`), no untracked paths, and 42 cumulative committed/dirty paths. The canonical newline-terminated `SHA256(bytes)  path` manifest digest was `b5d088f9c25caa1902ceabf4eeed5ec4586288ef2410a5c001a8f2226a688166`.

This supersedes both the plan's `2026-09-11T01:15:12.207214Z` snapshot at HEAD `72eeaec7` and an intermediate review observation at `2026-09-11T01:22:26.691252Z`. The plan correctly says movement of unmerged Slice 5 does not invalidate the exact-base docs gate by itself and blocks affected overlapping source work (`origin-main-1d2-reconciliation-plan-r3.md:541-558`). This resnapshot is dependency evidence, not implementation authorization.

**Coordinator source reconciliation must pause.** It may resume only after Slice 5 lands, or its owner explicitly declares the branch stable as a committed/reviewed prerequisite, or explicitly abandons it; origin, the selected dependency base, shared-path bytes, SPEC selectors, and per-Build1 versus cumulative manifests must then be resnapshotted and the affected plan gate reopened. The moving branch must not be copied, rebased, frozen, or treated as landed evidence.

## Verdict

**FAIL — implementation is not authorized.**

Findings: **0 Critical / 4 High / 3 Medium / 0 Low**.

R3 materially improves all nine R2 findings, particularly the package split, immutable persisted price inputs, dispatch lifecycle, deterministic pending-history selection, scoped encrypted cursor, auth error matrix, and Slice 5 stop rules. The following gaps still permit incompatible receipt bytes, incorrect economic finality, an ambiguous active price, or a false provider-visible state.

## Findings

### H1 — The price-contract binding has no compatible route-snapshot and receipt-version contract

**Evidence**

- R3 requires the `byom_price_contract.v1` digest to be “bound into the route digest” (`origin-main-1d2-reconciliation-plan-r3.md:202-209`) without defining whether that digest is the existing `route_snapshot_digest`, a second digest, or a new route-snapshot version.
- The exact base's locked receipt contract says a receipt-version-4 tuple binds `route_snapshot_digest`, and defines that digest as SHA-256 over strict `route_snapshot_v1` with exactly the listed fields (`specs/SPEC-015-receipts.md:3845-3873`, `:3925-3975`). It explicitly requires a `route_snapshot_v2` and corresponding policy version for any additional route-validity fields (`:3972-3975`).
- R3 defers all forward SPEC version numbers until Slice 5 is resolved (`origin-main-1d2-reconciliation-plan-r3.md:121-126`) but Phases 5 and 8 proceed to implement and verify price binding (`:600-609`). T13 and T14 freeze legacy bytes and the new contract digest, yet never freeze the exact new route-digest object, its relationship to `route_snapshot_digest`, or the receipt profile that authenticates it (`test-spec-origin-main-1d2-reconciliation-r3.md:208-245`).

**Consequence**

Two implementations can both claim conformance: one can silently add the price digest to strict `route_snapshot_v1` and break receipt-version-4 verification, while another can create a second route digest that no settlement-capable receipt authenticates. Either path can make a correctly signed receipt impossible to reproduce or let the price contract float outside the route/receipt trust chain. The compatibility assertions do not distinguish these failures.

**Required correction**

Before runtime work, choose and specify one exact contract. If price evidence extends route validity, define the exact strict `route_snapshot_v2` bytes, policy selector, receipt successor/version behavior, verifier rules, and old/new negotiation; receipt version 4 must remain byte-exact and must not settle the successor accidentally. If a separate immutable route/price digest is intended, define its exact canonical fields and prove how the existing route-snapshot digest, provider acceptance, verdict, ledger, and reconciliation bind to it without changing v4. Add independent golden encoders and unknown-version, downgrade, cross-version substitution, and delayed-settlement tests.

### H2 — Candidate-bound BYOM still has no normative buyer reservation and atomic money-finality lifecycle

**Evidence**

- `ReserveBYOMRoute` atomically inserts a route, price contract, and `route_reserved` event, but no buyer quota/balance reservation (`origin-main-1d2-reconciliation-plan-r3.md:192-201`). The reconciliation schema binds a route, verdict, one ledger row, and provider-credit amount, but does not define the buyer reservation/debit row, idempotency key, refund/release state, or atomic relationship between final buyer debit and provider credit (`:294-315`).
- The only test language is outcome-level: T14 expects “the same bounded debit/provider credit once,” and T21 expects “one debit/credit” (`test-spec-origin-main-1d2-reconciliation-r3.md:238-245`, `:355-370`). There is no crash/concurrency matrix around quota reservation, final debit, provider credit, release/refund, or a failed transaction between them.
- This is a required correction from the actual base, not a theoretical addition. The current buyer path passes caller-memory economics to `WriteHotPath` (`phase4-coordinator/internal/buyer/billing_recorder.go:389-446`) and records provider credit before receipt settlement. Governing SPEC-022 requires reservation-first accounting, final debit only after verified receipt, and reservation release/refund with zero provider credit for quarantine, deadline, and zero settlement (`specs/SPEC-022-verified-model-settlement.md:581-656`).

**Consequence**

An implementation can satisfy every planned schema and activity test while retaining the current early-credit path, crediting a provider without a corresponding final buyer debit, double-finalizing after a crash, or leaving buyer quota permanently reserved after quarantine. That does not prove a correctly settled request and can create or strand economic value.

**Required correction**

Define the candidate-bound BYOM accounting state machine and sole transaction owner: pre-dispatch reservation identity/cap, pending receipt state, verified atomic final buyer debit plus provider/operator credit, verified zero, quarantine/deadline release or refund, reversal semantics, and exact idempotency/generation keys. Explicitly bypass the current early-positive hot path for covered BYOM. Specify how request-log fallback and recovery behave without minting credit. Add insufficient-quota, concurrent requests, kill-before/after every reservation/finality write, duplicate workers, delayed receipt, deadline, zero, quarantine, reversal, and restart tests that independently query buyer reservation/debit and every provider/operator ledger row.

### H3 — The v2 config row has no unambiguous activation linearization or effective-row uniqueness rule

**Evidence**

- R3 says reload/startup commits a v2 row before publishing corresponding in-memory config, then route reservation selects “the one v2 row effective at `request_start`” (`origin-main-1d2-reconciliation-plan-r3.md:181-201`). It does not define when the row becomes active, whether committed-but-unpublished rows are eligible, how equal/overlapping effective timestamps are rejected or ordered, or how startup recovers a commit followed by process death before memory publication.
- The base has this exact split boundary: the billing snapshot commits first (`phase4-coordinator/internal/billing/snapshot.go:159-205`) and the buyer's config/snapshot pointer is published later (`phase4-coordinator/cmd/coordinator/main.go:3234-3257`). The current query uses `(effective_at DESC, id DESC)` (`phase4-coordinator/internal/billing/snapshot.go:208-218`), but R3 neither adopts that as normative nor proves that the selected row was the active published generation.
- T12 races all boundaries and accepts a contract “wholly from exactly A or B,” but does not state which one is authoritative for a request starting after DB commit and before memory publication, after publication failure, or at equal effective timestamps (`test-spec-origin-main-1d2-reconciliation-r3.md:191-206`).

**Consequence**

A request can be admitted/routed under in-memory configuration A and priced under durable row B, or different implementations can select different valid rows for the same request timestamp. All contract fields may be internally coherent and still describe the wrong active economic policy, so the independent A-or-B test oracle would pass the split-brain result it is meant to prevent.

**Required correction**

Make activation explicit. Either define durable commit as the sole candidate-BYOM pricing linearization point and treat in-memory data only as a cache loaded from that exact row, or add a durable activation generation/state whose transition is the authority. Define total ordering, equal-timestamp behavior, future rows, failed/retried reloads, restart recovery, and retention. Admission rate checks and route reservation must name the same authoritative generation or make clear why admission carries no price-generation claim. Update T12 with an expected A/B oracle for every barrier, including commit-success/publish-failure and equal timestamps, rather than accepting either coherent row.

### H4 — The activity oracle permits receipt-invalid and overdue attempts to remain open indefinitely

**Evidence**

- The precedence table maps “accepted and open verdict exists” to `receipt_pending` even when the stored receipt result is `invalid` (`origin-main-1d2-reconciliation-plan-r3.md:348-350`). It also maps accepted/no-verdict to `receipt_pending` and uses freshness thresholds only to turn open rows into `stale_open` (`:348-350`, `:385-399`). No row maps receipt deadline expiry to terminal quarantine.
- The immutable price contract contains dispatch, receipt, and reconciliation freshness thresholds but no normative receipt pending deadline or terminal-time basis (`:202-209`). Dispatch recovery covers only pre-write/unknown dispatch states (`:241-250`); no phase defines the worker that closes a missing/inconclusive receipt at the governing deadline and releases the buyer reservation.
- Locked receipt rules require an invalid receipt to map to quarantine immediately, while missing/inconclusive remains pending only until the configured deadline and then becomes quarantined (`specs/SPEC-015-receipts.md:4149-4182`). SPEC-022 requires the same deadline transition and reservation release (`specs/SPEC-022-verified-model-settlement.md:626-644`). T16 explicitly exercises old open rows and delayed verdicts but does not assert deadline closure (`test-spec-origin-main-1d2-reconciliation-r3.md:265-294`).

**Consequence**

The provider can see a cryptographically invalid receipt as merely pending, and a missing receipt can stay `stale_open` forever. Buyer quota can remain reserved, terminal quarantine can be suppressed, and provider-visible state can contradict the authoritative settlement profile.

**Required correction**

Add exact receipt-finality rules to the state table and recovery lifecycle: invalid/mismatched receipts close immediately as quarantine; missing or trust-root-inconclusive receipts remain pending only until the route's immutable `pending_deadline_seconds` measured from authoritative terminal time; the first deadline transition closes quarantine and releases/refunds the buyer with zero provider credit. Distinguish operational verifier retry from a terminal invalid result. Add boundary, worker race, restart, late-receipt, already-terminal, and app last-known tests; a late receipt must not resurrect the economic row.

### M1 — The provider acceptance frame is under-specified at a settlement-critical dispatch boundary

**Evidence**

- Contract 12 names logical fields and a “provider signature under a distinct domain” but not the signing key identity/source, strict canonical bytes, envelope, signature algorithm, maximum frame size, negotiation token, acceptance deadline, or duplicate-byte identity (`origin-main-1d2-reconciliation-plan-r3.md:231-240`). It says a rejection “proves no inference acceptance,” although a provider signature proves only that the provider asserted rejection.
- T13 tests forged/wrong-tuple frames and idempotent duplicates but has no independent encoder, wrong receipt-key versus auth-key case, oversized/unknown/duplicate-field frame, capability downgrade, acceptance timeout, or proof that acceptance is durably appended before any provider output is processed (`test-spec-origin-main-1d2-reconciliation-r3.md:208-227`).

**Consequence**

Implementations can sign different byte strings or validate against different provider keys, a replay/downgrade can create false `receipt_pending`, and the coordinator may expose output before it has durably crossed the acceptance boundary. The reject wording also overstates what provider-authored evidence proves.

**Required correction**

Freeze the wire contract in the forward SPEC: exact strict JCS fields/types, domain-separated signed bytes/envelope, the route-pinned key and algorithm, capability/version negotiation, size/deadline, parser rejection matrix, replay/idempotency identity, and ordering relative to processing the first output byte. Describe rejection as authenticated provider assertion and retain no-charge behavior. Add independent encoder and hostile parser/key/downgrade/timeout/order tests.

### M2 — One previous cursor key cannot guarantee the promised 15-minute validity across repeated rotations

**Evidence**

- R3 retains only a current key and one previous generation while promising that the previous key works through the maximum 15-minute cursor TTL (`origin-main-1d2-reconciliation-plan-r3.md:369-383`). It defines no minimum rotation interval or prohibition on a second rotation within that TTL.
- T16 performs rotation and checks one previous key but does not rotate twice within one cursor lifetime (`test-spec-origin-main-1d2-reconciliation-r3.md:277-285`). Restart is explicitly allowed to invalidate cursors, but ordinary repeated rotation is not.

**Consequence**

Two normal rotations inside 15 minutes evict a still-unexpired generation. A provider following `next_cursor` gets `invalid_cursor` despite neither expiry nor restart, breaking the pagination contract and potentially forcing repeated first-page traversal.

**Required correction**

Either require and enforce a rotation interval at least as long as the maximum TTL plus clock skew, or retain every key generation that can decrypt an unexpired cursor under a bounded ring. Define multi-process behavior or explicitly constrain the endpoint to a single/sticky instance. Test two or more rotations, oldest-still-valid and just-expired cursors, bounded key retention, clock skew, and concurrent pagination.

### M3 — T01 directs mutation of the active Slice 5 worktree while also forbidding interference

**Evidence**

- T01 says to “edit a Slice 5 byte, add/remove/rename a path, and change its HEAD independently” (`test-spec-origin-main-1d2-reconciliation-r3.md:48-55`). The same test says Build 1 must not modify the Slice 5 worktree (`:56-58`), and the plan says Build 1 never freezes or interferes with the other session (`origin-main-1d2-reconciliation-plan-r3.md:541-558`).
- Slice 5 is actively changing during this gate, as the resnapshot above demonstrates.

**Consequence**

A literal implementation of the required test can corrupt or race another session's uncommitted work. Avoiding that mutation leaves the checkpoint response branches untested, so the test is not safely executable as written.

**Required correction**

State that mutation scenarios run only in a disposable synthetic repository/worktree populated from a captured manifest; the active Slice 5 worktree is read-only evidence. Add a sentinel proving no active-worktree HEAD, index, tracked byte, untracked byte, or timestamp was changed by the test. Keep real active resnapshot checks read-only.

## Areas that pass this round

- The R2 structural API finding is materially addressed by the exact `internal/modeladmission` package, closed command constructors, split issuer/verifier graph, one-shot grants, external-package compile fixtures, and runtime caller matrix. The implementation audit must still prove there is no alternate raw SQL mutation path through the shared database handle.
- Pending-history precedence, nullable migration handling, invariant-to-unknown behavior, 24-hour terminal presentation, and memory/SQLite parity are sufficiently concrete for implementation planning.
- Cursor scope privacy, query grammar, fixed high-water traversal, indistinguishable invalid-cursor response, and no raw global ID exposure are sound apart from the key-retention issue above.
- The endpoint-specific provider-token error matrix closes the R2 credential/backend ambiguity while preserving status-v1 compatibility.
- R4 remains correctly blocked behind its own approved plan, fresh tests, isolated implementation checkpoint, and three zero-C/H/M full-diff audits.
- Physical Apple Silicon/actual MLX acceptance remains explicitly **BLOCKED / UNPROVEN** unless every named prerequisite and fresh inference-to-reconciliation artifact exists. No fixture is promoted to hardware, release, deployed, or production evidence.

## Gate disposition

Revise both plan and test specification to resolve H1-H4 and M1-M3, then submit the exact new digests to a fresh independent GPT-5.6 Sol adversarial review. Do not begin the 1d2 reconciliation implementation under R3.
