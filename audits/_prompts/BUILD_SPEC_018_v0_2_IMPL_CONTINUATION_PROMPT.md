# BUILD_SPEC_018_v0_2_IMPL_CONTINUATION — Finish the v0.2 IMPL session

## Context

A prior codex session against `specs/BUILD_SPEC_018_v0_2_IMPL_PROMPT.md` was killed before completion. The worktree (`/Users/augstar/macprovider-impl-spec-018-v0-2`, branch `impl/spec-018-v0-2`) contains the partial diff. Your job: finish the remaining work, fix the test failures, verify, and commit.

## Existing state (~80% complete)

**Modified files** (in worktree, uncommitted):
- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift` (+142 — ChatMessage struct extension)
- `phase3-binary/Sources/macprovider-cli/HTTPServer.swift` (+72)
- `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift` (+50)
- `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift` (+69 — multi-turn acceptance)
- `phase3-binary/Sources/macprovider-cli/OutputCanonicalizer.swift` (+13)
- `phase3-binary/Sources/macprovider-cli/ToolCallParser.swift` (+25 — byte cap raise)
- `phase4-coordinator/internal/buyer/server.go` (+348 — §8.4 split + request validation)
- 4 Swift test files extended; 2 Go test files extended

**New files** (in worktree, uncommitted):
- `phase3-binary/Sources/macprovider-cli/ToolPromptRenderer.swift` (4.5 KB — family-keyed multi-turn render)
- `phase3-binary/Tests/macprovider-cliTests/MultiTurnTests.swift` (6.8 KB)
- `phase4-coordinator/internal/buyer/multi_turn_test.go` (6.9 KB)
- `phase4-coordinator/internal/buyer/streaming_downgrade.go` (2.8 KB)
- `phase4-coordinator/internal/buyer/streaming_test.go` (5.8 KB)
- `docs/operations/spec-018-v0.2-deploy.md`

**Smoke test results (run BEFORE you start):**
- ✅ `cd phase4-coordinator && go vet ./... && go test -count=1 ./internal/buyer` — PASS (2.085s)
- ❌ `cd phase3-binary && swift test` — **5 failures (1 unexpected) out of 574 tests**

## Authoritative inputs

1. `specs/SPEC-018-agentic-tool-calling.md` v0.2.4 LOCKED — the SPEC.
2. `specs/BUILD_SPEC_018_v0_2_IMPL_PROMPT.md` — original BUILD prompt.
3. `specs/SPEC-018-v0_2-design-synthesis.md` — design source.
4. `specs/SPEC-018-v0_2_4-DRAFT-NOTES.md` — SPEC absorption notes.
5. The worktree's current diff (read with `git diff HEAD -- phase3-binary phase4-coordinator`).

## Your tasks

### Task 1: Fix the 5 Swift test failures

**Failure A (1 test) — `HTTPServerSwapTests.testInferenceReturns503WhenLoading`**

Test expected v0.1 envelope `{type, code, message, param}`. Your IMPL emits the v0.2 §10d.0 thicker envelope `{type, code, message, param, retryable, request_id, inference_ran, settlement_ran}` for the pre-existing 503 `provider_loading` error.

**SPEC interpretation decision (user-approved Path A — broader interpretation):** Apply the thicker envelope to ALL errors going forward, not just v0.2-introduced ones. This matches your existing IMPL behavior and is cleaner for consistency.

Fix: update the test fixture's expected JSON in `HTTPServerSwapTests.swift` to include the four additional fields (`retryable: false`, `request_id: null`, `inference_ran: false`, `settlement_ran: false` for the loading-state error). Verify the field ordering matches your IMPL output exactly (sorted-keys per JCS convention).

**Failures B–E (4 tests) — JCS canonicalization drift**

`JCSGoldenFixtureTests.testV03JCSFixturesProduceLockedCanonicalBytes` (2 fixtures: `null_hash` + `non_null_hash`), `OutputCanonicalizerTests.testKnownGoodOutputVectorUsesThreeCommittedKeys`, `PromptOutputCanonicalizerParityTests.testSharedCanonFixturesMatchSwiftCanonicalizers` — all failing because canonical SHA-256 hashes changed.

Per v0.2.4 §10d.0.1 and AC-46 normative: `usage.macprovider_model_hash_observed` MUST be **additive, non-canonicalized, observation-only**.

**Investigate**: read your `OutputCanonicalizer.swift` diff (+13 lines). Did you add `model_hash_observed` to the canonical-key set? If YES → this is a SPEC violation. Fix: remove from canonical scope. The field must be present in the response `usage` block but EXCLUDED from JCS canonicalization. The locked SHA-256 fixture values should then pass without regeneration.

If you correctly placed it outside canonical scope and the SHA-256 values are still failing → investigate other causes (e.g., did you change `OutputCanonicalizer.swift` for something else and it cascaded?).

The two NEW fixture cases (`null_hash` + `non_null_hash`) look like fixtures you added to test the new field. If correctly non-canonicalized, the JCS bytes should be IDENTICAL between `null_hash` and `non_null_hash` cases (because the field is excluded from canonicalization in both). Update the fixture expectations accordingly OR remove the new fixture cases (if they were testing the wrong thing).

### Task 2: Land the missing pieces

The original BUILD prompt enumerated work that was not completed:

**A. AC-25a CI-amenable Cline fixture** (`test/integration/cline_session/`)

This is the largest missing piece. Required:
- Pinned Cline VS Code extension version (e.g. `saoudrizwan.claude-dev@4.0.0`)
- Pinned target repo (use a small fixture repo — could be a stub workspace with a few markdown files, including SPEC-018-agentic-tool-calling.md as a `read_file` target per AC-25a + Critic Q-1)
- Pinned deterministic prompt
- Machine-readable transcript schema (JSON: turns, tool_calls, timings, request_ids, streaming_mode header values, raw SSE transcript hashes, model_hash_observed values per turn)
- Automated pass/fail criteria asserting:
  - ≥ 20 provider turns
  - ≥ 30 tool calls/results
  - ≥ 3 file edits across ≥ 2 files
  - ≥ 2 commands with one failure+recovery
  - ≥ 1 assistant-history echo + matching tool result
  - ≥ 1 `write_to_file` ≥ 64 KiB with first delta < 1500 ms + ≥ 3 deltas before `finish_reason:"tool_calls"`
- Tool category mapping documented (legacy extension vs ClineCore tool names)
- Run script `run-cline-session.sh` invokable from CI

If actually running the Cline extension in CI is impractical for this commit, implement the **harness skeleton** + transcript schema + assertion code, with a `SKIP=true` env-var that the IMPL PR documents as "release-gate manual smoke until CI harness is provisioned." This satisfies the SPEC obligation by providing the executable contract; full automated end-to-end can land as a follow-up.

**B. AC-48a (openai-python ecosystem) + AC-48b (Cline-direct via Vercel AI SDK) terminal-error tests**

Add `test/integration/streaming_terminal_error/`:
- AC-48a: Python test that uses `openai==2.44.0` (pin via `tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt`). Replays a mocked SSE stream that incremental-opens a tool call, then emits the terminal `data: {"error": ...}` + `data: [DONE]` sequence per §8.4.3. Asserts that the openai-python accumulator does NOT yield a successful assistant message with dispatchable `tool_calls[]`. Acceptable: SDK raises an exception (`APIError` or similar).
- AC-48b: TypeScript/Node test that imports `@ai-sdk/openai-compatible` (matching Cline's import at `sdk/packages/llms/src/providers/vendors/openai-compatible.ts`). Same mocked SSE. Asserts no dispatchable tool_calls reach the `AgentRuntime`-style accumulator boundary.

If TypeScript test infrastructure doesn't already exist in this repo, add the minimal Node project setup (`package.json` + minimal Vitest/Jest config). Pin `@ai-sdk/openai-compatible` to the version Cline `main@92806c60` uses.

**C. NTP-anchored AC-44 timing instrumentation**

Add to coordinator-side streaming path:
- Provider-side timestamp (`t_tool_call_open_detected`) — provider emits at moment of recognizing native tool-call markup. Surface via heartbeat or response header.
- Coordinator-side (`t_first_forwarded_sse_byte`) — recorded at the moment the coordinator forwards the first tool-call delta chunk to the buyer.
- Gateway-side (`t_first_gateway_byte`) — recorded at gateway.
- Skew bound: NTP heartbeat at request start measures `|t_provider - t_gateway|`. Skip the metric (don't enforce p95) if skew > 100ms.
- Targets: p95 (skew-corrected) ≤ 1500 ms on M4 hardware; ≤ 3000 ms on M2/M3 hardware.
- Surface measurements via coordinator metrics endpoint (Prometheus-style or whatever pattern this repo uses).

Add `phase4-coordinator/internal/buyer/streaming_timing.go` (new file) implementing the three-timestamp collector. Tests in `streaming_timing_test.go`.

**D. AC-46 verification audit**

Even if Task 1 finds that `model_hash_observed` is correctly excluded from canonicalization, verify the field is actually emitted on every v0.2 response (both non-streaming and streaming-final-chunk per §10d.0.1):
- `null` when provider's local hash subsystem reports no known hash
- hex SHA-256 when known
- buyer-side type assertion + provider-side self-test (AC-46 fixture coverage)

Verify by reading `HTTPServer.swift` diff + checking response shape in `MultiTurnTests.swift` and adding explicit AC-46 assertions if missing.

**E. `X-MacProvider-Streaming-Mode` header verification**

Verify the header is emitted on every v0.2 response with one of three values: `incremental`, `buffered_kill_switch`, `buffered_provider_downgrade`. AC-45 + AC-45c require both header presence AND correlation with operator/provider state. Add AC-45c adversarial test (buyer A submitting malformed-stream-eliciting requests does NOT downgrade buyer B's responses).

### Task 3: Verify

After all edits:

```bash
# Verify both languages
cd /Users/augstar/macprovider-impl-spec-018-v0-2

cd phase3-binary && swift test 2>&1 | tail -20
# Expected: 0 failures, all green.

cd ../phase4-coordinator && go vet ./... && go test -count=1 ./internal/buyer 2>&1 | tail -10
# Expected: ok internal/buyer in ~2s, no vet errors.

# Integration tests
cd ../test/integration/cline_session && ./run-cline-session.sh
cd ../streaming_terminal_error && ./run-ac48a.sh && ./run-ac48b.sh
# Expected: transcript artifact + pass for AC-48a/b.

cd .. && git diff --check 2>&1
# Expected: no trailing whitespace / mixed indentation issues.
```

### Task 4: Write `specs/SPEC-018-v0_2-IMPL-NOTES.md`

Cover:
- Per-deliverable summary + AC coverage (1, 4, 6, 7 + supporting AC-25a, AC-46, AC-48a/b, AC-44)
- Test fixture locations (Swift test files, Go test files, integration test dirs)
- Money-path trace evidence (concrete code-line citations for `FaultBreakerQualifying` paths)
- Normative interpretation calls made during IMPL (e.g., §3.8 chat-template structural-spec choice; §10d.0 error envelope broad-vs-narrow interpretation; AC-25a harness-skeleton-vs-full-CI choice)
- Cline session evidence file path (`test/integration/cline_session/output/transcript-<timestamp>.json`)

### Task 5: Commit

Commit incrementally (5+ atomic commits per deliverable, OR one consolidated commit — your choice). Each commit message should reference the AC(s) it closes.

Suggested commit grouping:
1. Multi-turn provider acceptance (Deliverable #1, AC-25 through AC-29, ChatMessage extension + ToolPromptRenderer + ModelRuntime)
2. Request-side validation + tool_call_id (Deliverable #6, AC-30 through AC-34)
3. Byte cap raise to 1 MiB/2 MiB (Deliverable #7, AC-35 through AC-39)
4. Streaming + §8.4 split + per-buyer downgrade (Deliverable #4, AC-40 through AC-45c)
5. AC-46 model_hash_observed field + AC-44 NTP timing
6. AC-25a CI fixture + AC-48a/b terminal-error tests
7. Error envelope §10d.0 + aggregate caps + IMPL-NOTES

OR one big commit with a comprehensive message — easier to revert/audit.

DO NOT push. The IMPL PR opens after codex 4-lane audit on the diff.

## Constraints

- v0.1.5 IMPL (commit `83472ef`) MUST still work (existing AC-1 through AC-24 tests pass).
- v0.2.4 SPEC LOCKED — no SPEC edits.
- Money-path settlement protection preserved end-to-end.
- All 5 currently-failing Swift tests MUST pass after Task 1.
- Both `swift test` and `go test ./internal/buyer` MUST return clean before commit.
- DO NOT bypass tests with `XCTSkip` or `t.Skip()` — fix the test or fix the IMPL.

## Output

When done, the worktree state should be:
- All v0.2.4 deliverables implemented + tested
- All test suites green
- IMPL-NOTES.md written
- Changes committed on `impl/spec-018-v0-2` branch
- Ready for codex 4-lane audit (architect/code/security/PD) on the IMPL diff

Final step is OUT OF SCOPE for you: the audit-loop + Claude blind-spot pass + IMPL PR. Just produce a clean, green, committed worktree.
