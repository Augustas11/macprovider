# S2 HTTP teardown composition R1 — independent architecture plan gate

Verdict: **APPROVED AT PLAN LEVEL — 0 Critical, 0 High, 0 Medium, 0 Low.**

Exact proposal: `s2-http-teardown-test-addendum-r1.md`, SHA-256 `0b4c178cf0ac083d2295d4d05478d89470a50343580679b81284b87bad9bce35`. Independent native GPT-6 Astra, high reasoning. Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`; worktree `/Users/augstar/.codex/worktrees/macprovider/product-build-1`. Inspected current uncommitted code and the approved promotion R3 contracts independently. Only this report was written; no runtime edits, test execution, services or subagents.

The two compositions are a valid test strategy for the stated HTTP producer/WS publication/artifact consumer relationship. Approval does not establish that either new test passes, that remaining T10/T11 coverage is complete, or that S2 and the full Build 1 gate are closed.

## Findings and evidence

No blocking or Low plan finding. The following records the evidence, consequences and existing acceptance obligations.

### Reachability and the shared production state

**Evidence:** `buyer/model_admission_authority.go:31–33` requires constructor-wired exact-session availability; lines 55–62 additionally require `p.IsWSTunneled()` for primary artifact authority. `pool.Provider.IsWSTunneled` requires the WS inference path and rejects HTTP-forwarding-only providers. The public nonstream buyer handler selects WS dispatch at `buyer/server.go:2496`; HTTP non-200 forwarding delivers actual response status to `handleProviderFailure` at 3254, and HTTP streaming does so at 4192. Terminal 530/3xx handling at 8488–8507 marks the exact registry assignment unavailable and calls `closeProviderConn`. The normal HTTP client returns redirect responses without following them (`providerhttp/client.go:8–20`).

**Consequence:** A single unchanged primary-artifact-positive dispatch cannot also exercise the legacy HTTP-forwarding 530/redirect branch. Requiring that contradictory fixture would encourage an authority or routing bypass. It is legitimate to test the reachable public HTTP producer separately from the artifact consumer while preserving their common production state.

The joining state is concrete: `ws.CloseModelAdmissionTransport` resolves the exact stored provider/assigned session, invokes `closeTransport`, and publishes `beginClosing` before socket Close (`ws/model_admission_transport.go:18–35,62–72`). This transition has no artifact/legacy transport conditional. `ModelAdmissionSessionAvailable` at 51–60 observes the registry assignment and that same stored session's open state. Composition A therefore exercises the actual publication that Composition B must observe; a test-owned Boolean would not establish that link.

**Required correction:** None to the plan. Preserve both status cases, exact callback identity/reason/count, one upstream request and zero redirect-destination requests. Treat HTTP failure as failure, without claiming paid inference, receipts or settlement.

### Producer fixture and ordering

**Evidence:** Production constructor wiring passes both WS methods at `cmd/coordinator/main.go:944`, then checks readiness before installing admission authority at 989–995. `buyer/model_admission_guard.go:15–22` requires both constructor callbacks. `buyer/server.go:8510–8524` uses the supplied close callback; the legacy raw-close fallback does not establish guarded artifact capability.

**Consequence:** A test-only exported WS fixture can supply a real stored session and recording connection to an external `ws_test` composition without adding a production API. The close wrapper has a bounded observational role: confirm the real unavailable mark, restore ready through the real registry updater, and invoke the actual WS close method. The socket boundary can then prove closing became visible while registry/map identity remain present and ready, excluding unavailable state or eventual disconnect as alternative explanations.

**Required correction:** None to the plan. The wrapper must not set closing, synthesize availability, replace the session, swallow an unsuccessful real close as success or skip the actual method. Assert availability before invoking it and refusal at the recording Close boundary, followed by refusal after another real ready update. The publication-pin assertion must execute at that actual socket boundary and demonstrate the lock is released; no sleeps or eventual-cleanup observation can replace it. Missing-read and missing-close constructor cases must each refuse authority readiness. Existing replacement, duplicate close, guard-first/invalidate-first and graceful transport requirements remain in force; this public HTTP composition alone does not satisfy all of T10.

### Artifact consumer evidence remains mandatory

**Evidence:** `buyer/model_admission.go:112–127` resolves current artifact authority before accepting the historical binding, returning found-but-ineligible when resolution fails regardless of revocation persistence. `TestBuild1PaidRouteRejectsClosingBeforeStatusRevocation` uses actual service binaries, a real blacklist producer, ready revival, a still-positive unexpired artifact event and a first buyer HTTP request. Its failure variant rejects SQLite revoked INSERTs and checks the positive event remains. It also checks no inference frames, payable route records or debit. These are relevant assertions, not an executed result of this review.

The current `buyer/model_admission_transport_authority_test.go:53–110` uses a fabricated availability callback for its closing case and exercises several paths on one fixture. That existing predicate-oriented test cannot count as the unchanged T11 real-WS, independent-entry-point composition. The addendum explicitly requires mapping and completing the remaining matrix, so this is an implementation evidence gap rather than a defect in the proposed plan.

**Consequence:** Composition A proves the HTTP producer reaches real monotonic WS closing; Composition B proves actual artifact consumers reject that closing state independently of historical revocation. The positive event, exact live session and other admission predicates must remain valid immediately before each tested entry point. A preceding route/status check that has already revoked the event would destroy this proof.

**Required correction:** None to the plan. Retain T11's actual WS callback wiring, memory/SQLite stores, fresh fixtures for independent default/pinned/queued/direct-binding/HTTP entry points, revocation success and failure, missing wiring, readiness revival and replacement isolation. Preserve its real-producer requirements as expressly inherited. The existing blacklist HTTP integration supplies one portion; it does not establish the full path/producer matrix or excuse callback-only consumer tests.

## Acceptance boundary

The proposal preserves runtime behavior, primary MLX scope, economics and production callback custody. Test-only exports are sufficient for the proposed observation and do not require a runtime authority seam. Both compositions must pass under `-race`, with actual selected tests and leaf counts recorded. The approved promotion serialization, readback, timing, teardown and T11 requirements remain required except for the explicitly reconciled incompatible single-dispatch premise. Fresh implementation review and full combined code/security/architecture gates remain pending.

## Snapshot manifest

SHA-256 values for the inspected shared-worktree snapshot:

| File | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/s2-http-teardown-test-addendum-r1.md` | `0b4c178cf0ac083d2295d4d05478d89470a50343580679b81284b87bad9bce35` |
| `docs/product-roadmap/build-1/promotion-authority-addendum-r3.md` | `6a5bd750addb0180f22a4cf16cc33862a2324a3010cfae66c794c568bfd5d0c4` |
| `docs/product-roadmap/build-1/s2-http-teardown-test-feasibility.md` | `aacb01d00581982f5e0012f4fd9cd99bf51b2d6d494e8bc5e6325daca1ad2186` |
| `phase4-coordinator/internal/buyer/server.go` | `4f3b330034bb681af0189054ff7a488da34566d148aa118c4b14247ceb798d0d` |
| `phase4-coordinator/internal/buyer/model_admission_authority.go` | `aa568bb750e4387e8f1f6b35305b7e5fee32c8ec0bf7431c58020fcfa4b05b15` |
| `phase4-coordinator/internal/buyer/model_admission_guard.go` | `93367426a48dded21057484c19413075fdbb6189fab07cbb82bee82adbbb1200` |
| `phase4-coordinator/internal/buyer/model_admission.go` | `5dbd8410db9a2b699bfe1fbfddc7ba8ebbe53e32dc2b76f316d4ad0c44603549` |
| `phase4-coordinator/internal/ws/model_admission_transport.go` | `e551eac5f7f0085c080f2c8841fda318203cd42ddff0bf35e8f54d70adc3a692` |
| `phase4-coordinator/internal/ws/model_admission_transport_test.go` | `4360b032dc9cf729fcafdfd57f507ee3cc8f17781179aecb4480e9fa13d50acf` |
| `phase4-coordinator/internal/buyer/model_admission_transport_authority_test.go` | `02da2eb0481a46b9937dd8d258284a86390055c57cd2aa32de492cd6e797e15f` |
| `phase4-coordinator/internal/providerhttp/client.go` | `f3848f1e4d253d136c91647ac0d408b6eeddf6c8ff2d1c52ef7b77d7ff33ba7f` |
| `phase4-coordinator/cmd/coordinator/main.go` | `31e78d166f9e5313e25b510b91eca4763fc16757c8e40ffedf18391a8c52e1f2` |
| `test/integration/build1_closing_route_test.go` | `873bb97c04c3a7243ab55c54e037c2188a99c0966d325ddf1e8ab1bcc46c3fd0` |
