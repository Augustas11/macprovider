# AUDIT_SPEC_018_v0_2_IMPL_r2 (codex 4-lane + Claude blind-spot, shared brief)

## Task

Round 2 audit of the SPEC-018 v0.2.4 IMPL diff at commit `42476b7` on
`impl/spec-018-v0-2`. This is after r1 absorption (2C + 10H + 13M closures).

Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM across all 6 lanes → READY TO MERGE.

## What changed since r1

Commit `42476b7` (r1 absorption):
- StreamChunk refactor (real token-incremental streaming)
- Downgrade/kill-switch actually buffer (not just header flip)
- Error envelope `retryable` per-code lookup table (Swift + Go)
- AC-48a (openai-python) + AC-48b (Vercel AI SDK) actually consume SSE through real SDKs
- Provider/coordinator/gateway emit timing headers; `/metrics/streaming` now finds samples > 0
- AC-25a `run_fixture.py` drives macprovider stack as separate process (mock-provider mode)
- AC-46 self-test now treats non-hex from "known" branch as mismatch
- Qwen3 byte-exact SHA-256 pin + Llama-3.3 structural pin
- Package.swift unhandled-resources fix
- IMPL-NOTES.md: 50 → 262 lines (full AC coverage + operator surface + v0.3 deferred index)
- docs/operations/spec-018-v0.2-deploy.md: 11 → 203 lines (real operator runbook)
- Manual StreamChunk refactor completion (after codex r1 absorption session was killed mid-flight)

## Authoritative inputs

1. **The IMPL diff**: `git show 42476b7 --stat` shows 29 files / +2679 / −251
2. The full IMPL diff from origin: `git diff 7e50832..HEAD`
3. SPEC: `specs/SPEC-018-agentic-tool-calling.md` v0.2.4 LOCKED
4. r1 audit files (your prior verdicts):
   - `specs/SPEC-018-v0_2-IMPL-architect-r1-audit.md` (0/3/1/0/1)
   - `specs/SPEC-018-v0_2-IMPL-code-r1-audit.md` (0/2/2/0/1)
   - `specs/SPEC-018-v0_2-IMPL-security-r1-audit.md` (1/1/2/0/1)
   - `specs/SPEC-018-v0_2-IMPL-product-design-r1-audit.md` (0/1/2/1/1)
   - `specs/SPEC-018-v0_2-IMPL-critic-r1-audit.md` (1/3/3/2/3)
   - `specs/SPEC-018-v0_2-IMPL-narrative-r1-audit.md` (0/0/3/4/2)
5. r1 absorption prompt: `specs/SPEC-018-v0_2-IMPL-r1-absorption-prompt.md`
6. Updated IMPL-NOTES: `specs/SPEC-018-v0_2-IMPL-NOTES.md` (262 lines)
7. Updated deploy doc: `docs/operations/spec-018-v0.2-deploy.md` (203 lines)

## Smoke evidence

- `cd phase3-binary && swift test` — 577 tests / 0 failures / 7 skipped (~37.3s)
- `cd phase4-coordinator && go vet ./... && go test -count=1 ./internal/buyer` — ok

## Per-lane lens

**Architect lane** — structural coherence after StreamChunk refactor; protocol/conformance integrity; downgrade-buffering separation from kill-switch; tokenizer pin file design (byte-exact vs structural); module boundary between provider streaming + coordinator forwarding.

**Code lane** — verify each r1 finding closure mechanically:
- Error envelope per-code `retryable` lookup table matches SPEC §10d.0 table EXACTLY (check each code)
- StreamChunk refactor compiles + tests + no protocol mismatches remain
- Downgrade branch actually changes behavior in `forwardStreaming` + `forwardWSStreaming`
- Timing headers EMITTED at the cited code locations (not just declared)
- `/metrics/streaming` now finds samples > 0 (was 0 in r1)
- AC-48a/b SDK consumption real (not hand-rolled parser)
- Qwen3 SHA-256 matches the actual pinned file

**Security lane** — re-verify money-path posture (no regression). New surface: per-(buyer, provider) downgrade state in `streaming_downgrade.go` — confirm process-restart isolation + multi-coordinator caveat is correctly noted in deploy doc. AC-48a/b SDK gates ACTUALLY exercise the SDK terminal-error path now. AC-46 self-test mismatch detection. AC-44 timing-header information disclosure (do they leak attack-useful state?).

**Product-design lane** — Cline UX after r1 absorption: (1) error envelope `retryable` actually helps Cline decide retry-vs-abandon; (2) AC-25a transcript now reflects real macprovider behavior, not self-validated synthetic; (3) deploy doc actionable for ops who pages at 3 AM; (4) IMPL-NOTES coherent for an IMPL reviewer.

**Claude critic blind-spot** — Verify what codex misses on absorption rounds. Specifically check:
- Did the StreamChunk refactor inadvertently break test fakes outside `InferenceRelayTests` (e.g., `HTTPServerSwapTests`, `HTTPServerReceiptTests`)? Verify by reading the test files, not trusting the smoke result.
- Does the manual `containsMacProviderHeader` extension fix in `HTTPServerReceiptTests.swift:1083` correctly preserve the receipt-leak guard intent? Check the receipt-bearing prefixes that the original test was guarding (not just the timing/streaming-mode headers).
- AC-48b: does `createOpenAICompatible` actually get invoked in the test path, OR does the test still import-and-ignore the SDK? Read the .test.ts file end-to-end.
- StreamChunk closure-captured `streamedAnyToolCallDelta` flag has Sendable warnings. In Swift 5 these are warnings; in Swift 6 they'd be errors. Is the fix robust (actor-isolated state vs atomic) or is it papering over?
- Tokenizer pins: is the SHA-256 actually correct (`shasum -a 256` against the fetched file)? Is the structural Llama-3.3 pin honest about NOT being byte-exact?
- AC-25a mock-provider simulation: does it actually validate provider behavior, or is it just a deterministic-fixture generator dressed up as integration test? Read run_fixture.py end-to-end.
- IMPL-NOTES claims 577 tests pass — is that actually true post-r1-absorption (you can re-verify by `cd phase3-binary && swift test`).

**Claude narrative blind-spot** — does the expanded IMPL-NOTES + deploy doc form a complete audit trail? Run the 3 reader tests again (IMPL-reviewer cold / PR-reviewer security review / future-Claude v0.3 IMPL author). Does the v0.3-deferred index correctly enumerate everything that's not landing?

## Output format

Write findings to `specs/SPEC-018-v0_2-IMPL-{lane}-r2-audit.md` (lane ∈
{architect, code, security, product-design, critic, narrative}) with standard
structure: verdict, tally C/H/M/m/Q, closure status per r1 finding, fresh
findings, verdict justification.

## Severity bar

- **CRITICAL** — IMPL breaks money-path, ships a SPEC violation, test claim is wrong
- **HIGH** — IMPL bug that causes Cline failures, AC harness structurally unsound, normative interpretation diverges from SPEC
- **MEDIUM** — code-citation drift, AC test fixture under-specified, edge case unhandled
- **minor** — polish
- **Q** — design clarification

Goal: 0/0/0 across all 6 lanes = READY TO MERGE.
