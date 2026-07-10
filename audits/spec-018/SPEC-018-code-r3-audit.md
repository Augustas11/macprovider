# SPEC-018 v0.1.2 — CODE-lane round-3 audit (lock confirmation)

You are the **code** lane of a round-3 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.1.2. This is a lock confirmation round.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.2 (commit `4cc4f9f`)
- Round-2 code findings: `specs/SPEC-018-code-r2-audit.md`

## Round-3 lane scope

1. **Verify r2 absorption.** For each r2 finding:
   - **M-1** (mixed-sentinel not in IMPL deltas): §1 IMPL deltas now enumerate §3.6 alongside §3.2 and §8.4. §3.6 itself names the IMPL delta. Confirmed?
   - **M-2** (§10a #2 wrong citation): §10a #2 now cites `phase4-coordinator/internal/pool/provider.go:132-133` and `:1001-1052`. Verify these ranges contain ModelHash field + heartbeat update.
   - **M-3** (§8.4 source phrasing): §8.4 source paragraph now reads "current commit-signal path to patch" with the v0.1.2 IMPL prompt commitment. Adequate framing?
   - **Q-1** (AC-19 verifiable after parser patch): §1 IMPL deltas paragraph now explicitly states the as-built does OR-based detection. Is AC-19 now mechanically traceable to the v0.1.2 IMPL prompt obligation?
   - **Q-2** (AC-20 docs/harness): §1 IMPL deltas enumeration lists exact files (README.md, examples/tool_calling_demo.py, test/integration/tool_calling/README.md:38-53, openai_tool_call_e2e.py:78-85) plus required phrase. Adequate enumeration?
   - **Q-3** (Qwen3 ambiguity): §3.1 predicate is now `qwen2.5` OR `qwen3` (case-insensitive). Does this match `Qwen3-32B-4bit` modelID?
2. **New citation verification.** v0.1.2 added:
   - §10a #2: `provider.go:132-133`, `:1001-1052`. Verify.
   - §8.4 source paragraph: same `phase4-coordinator/internal/buyer/server.go:2482-2605`, `:1982-2195`, `:2320-2473`, test `server_internal_test.go:70-103`. Verify all exist + still anchor correct concepts.
   - §1 IMPL delta #1: `ToolCallParser.swift:482-487` (as-built OR-based detection), `ToolCallParserTests.swift:46-57`. Verify both exist.
3. **AC-23 (new) is mechanically verifiable?** "v0.2-or-later regression test replays v0.1.2 fixtures and verifies a v0.1.2-targeted client parser parses each response." Is this implementable when v0.2 ships? The wording references "OpenAI Python SDK 1.x at the version locked when v0.1.2 ships" — but no version is named. Should v0.1.2 pin the exact OpenAI SDK semver this AC will use?

## Output format

Same as r2. Keep tight.

```
## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## r2-absorption verification

## Findings

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**.

## Final prompt

# SPEC-018 v0.1.2 — CODE-lane round-3 audit (lock confirmation)

You are the **code** lane of a round-3 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.1.2. This is a lock confirmation round.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.2 (commit `4cc4f9f`)
- Round-2 code findings: `specs/SPEC-018-code-r2-audit.md`

## Round-3 lane scope

1. **Verify r2 absorption.** For each r2 finding:
   - **M-1** (mixed-sentinel not in IMPL deltas): §1 IMPL deltas now enumerate §3.6 alongside §3.2 and §8.4. §3.6 itself names the IMPL delta. Confirmed?
   - **M-2** (§10a #2 wrong citation): §10a #2 now cites `phase4-coordinator/internal/pool/provider.go:132-133` and `:1001-1052`. Verify these ranges contain ModelHash field + heartbeat update.
   - **M-3** (§8.4 source phrasing): §8.4 source paragraph now reads "current commit-signal path to patch" with the v0.1.2 IMPL prompt commitment. Adequate framing?
   - **Q-1** (AC-19 verifiable after parser patch): §1 IMPL deltas paragraph now explicitly states the as-built does OR-based detection. Is AC-19 now mechanically traceable to the v0.1.2 IMPL prompt obligation?
   - **Q-2** (AC-20 docs/harness): §1 IMPL deltas enumeration lists exact files (README.md, examples/tool_calling_demo.py, test/integration/tool_calling/README.md:38-53, openai_tool_call_e2e.py:78-85) plus required phrase. Adequate enumeration?
   - **Q-3** (Qwen3 ambiguity): §3.1 predicate is now `qwen2.5` OR `qwen3` (case-insensitive). Does this match `Qwen3-32B-4bit` modelID?
2. **New citation verification.** v0.1.2 added:
   - §10a #2: `provider.go:132-133`, `:1001-1052`. Verify.
   - §8.4 source paragraph: same `phase4-coordinator/internal/buyer/server.go:2482-2605`, `:1982-2195`, `:2320-2473`, test `server_internal_test.go:70-103`. Verify all exist + still anchor correct concepts.
   - §1 IMPL delta #1: `ToolCallParser.swift:482-487` (as-built OR-based detection), `ToolCallParserTests.swift:46-57`. Verify both exist.
3. **AC-23 (new) is mechanically verifiable?** "v0.2-or-later regression test replays v0.1.2 fixtures and verifies a v0.1.2-targeted client parser parses each response." Is this implementable when v0.2 ships? The wording references "OpenAI Python SDK 1.x at the version locked when v0.1.2 ships" — but no version is named. Should v0.1.2 pin the exact OpenAI SDK semver this AC will use?

## Output format

Same as r2. Keep tight.

```
## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## r2-absorption verification

## Findings

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**.

## Raw output

```text
## Counts
CRITICAL: 0  
HIGH: 0  
MEDIUM: 0  
MINOR: 0  
QUESTIONS: 0

## r2-absorption verification

M-1: Confirmed. §1 now enumerates §3.6 as IMPL delta #2, alongside §3.2 and §8.4. §3.6 also names itself as `v0.1.2 IMPL delta (§1 #2)`.

M-2: Confirmed. `phase4-coordinator/internal/pool/provider.go:132-133` contains `ModelHash` + `HashStatus`; `:1001-1052` contains heartbeat `ModelHash` input fields and update/verification into `p.ModelHash` / `p.HashStatus`.

M-3: Confirmed. §8.4 now frames the cited code as “current commit-signal path to patch,” not proof of already-compliant AC-21 behavior. The cited code still accepts any non-empty `tool_calls[]`, so this framing is accurate.

Q-1: Confirmed. §1 explicitly says as-built `ToolCallParser.swift:482-487` is OR-based detection and that v0.1.2 requires modelID match. AC-19 is now traceable to the IMPL obligation.

Q-2: Confirmed. §1 enumerates exact AC-20 target files/line ranges and the required phrase. Current files do not yet contain the phrase, but §1 correctly scopes that as IMPL work.

Q-3: Confirmed. §3.1 predicate `qwen2.5` OR `qwen3` case-insensitive matches `mlx-community/Qwen3-32B-4bit`.

## Findings

None.

Citation checks passed:
- `ToolCallParser.swift:482-487` is OR-based detection; `ToolCallParserTests.swift:46-57` locks delimiter-only parsing with non-matching modelID.
- §8.4 cited coordinator ranges exist and anchor the claimed concepts: WS forwarding/pass-through, direct HTTP streaming pre-commit, commit predicate, and existing tests.
- `server_internal_test.go:70-103` contains existing commit-signal tests to extend.
- AC-23 is mechanically implementable: the repo already has a hashed lock with `openai==1.30.1` in `test/integration/spec015/sdk_compat/python/requirements.lock:47-50`, and the tool-calling runner installs that lock. Naming the semver in SPEC would improve self-contained readability, but is not required for mechanical verification if v0.1.2 ships with this lockfile.

## Verdict
READY TO LOCK

