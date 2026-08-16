# Pre-merge audit prompt — PR #5 (SPEC-001 v1.3 Phase 1A-1E implementation)

Operator-paste prompt for Codex GPT-5 to perform an end-to-end
**code review + security review + architecture review** on
[Augustas11/macprovider#5](https://github.com/Augustas11/macprovider/pull/5)
before squash-merge. This is the external adversarial pass that
complements the per-phase internal audits Claude Opus ran during
implementation.

PR #5 carries five commits implementing SPEC-001 v1.3 Phase 1
(binary surface):

| Commit | Phase | Scope |
|---|---|---|
| 6744d7c | 1A | SPEC-010 catalog flags + `SupportedModels` + v2 `auth_request` field plumbing |
| 5c03e88 | 1B | Warm-swap gate + `RuntimeStateMachine` + `ModelRuntime` actor refactor + HTTP 503 wiring |
| 9a4a6c5 | 1C | `ControlSocket` (NDJSON on Unix-domain socket) + `models` subcommand + R-3.1.5.x detection precedence |
| 3c1da34 | 1D | Heartbeat opt-in fields (`model_hash` + `loading`) + `hello.model_hash` source-of-truth on WS reconnect |
| 5d013f5 | 1E | Cooldown soft guard + `--force` semantics + end-to-end AC matrix |

131 tests pass. Internal audits surfaced only one finding (M.1 on
1A R1, fixed in R2). The operator wants an independent
adversarial pass before merging — looking for what the internal
audit may have missed.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~30-60 min.
This is a READ-ONLY review — Codex MUST NOT modify any file. Do
not commit, do not push, do not create branches.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial pre-merge review of PR #5 in
the Augustas11/macprovider repository. The PR implements SPEC-001
v1.3 binary surface across five commits on branch
`fix/spec-001-v1-3-binary`. The branch is already checked out at
`/Users/augstar/macprovider-poc`.

This is a **read-only review**. You MUST NOT edit any file,
commit, push, or modify the git state in any way. Your only
output is the structured findings report at the end.

## Context

The repository hosts the Mac Provider stack for AntFeed (the P2P
AI marketplace on Base). The codebase under `phase3-binary/`
ships as a signed macOS binary to operator hardware (Mac Minis,
Mac Studios). Operators run this binary to serve inference
requests from buyers and earn USDC on Base.

This PR adds:
- SPEC-010 v1.5 capability advertisement (which models a provider
  can serve)
- SPEC-011 v0.5 operator-pushed warm model swap (change the served
  model without a multi-minute restart loop)

The binary's threat model:
- Operator is trusted (they own the hardware)
- Coordinator (`coordinator.malibu.tech`) is trusted
- Buyers are UNTRUSTED (they send arbitrary inference requests
  over the WS-tunneled path)
- Local processes other than `macprovider-cli` are UNTRUSTED
  (the control socket is local-only at
  `$TMPDIR/macprovider-cli/ctl.sock`)
- Filesystem state files (`last-switch.ts`) are NOT
  security-sensitive (no secrets, no auth tokens)

The binary handles money-path-adjacent code (heartbeats and hellos
to the coordinator determine billing eligibility; a malformed
heartbeat could cost an operator real USDC).

## Required reading (in this order)

1. The five commits via `git log --oneline main..HEAD` and
   `git show <commit>` for each. Read the full diff of each
   commit; the commit messages contain the binding R-rules.

2. The five BUILD prompts that produced the code:
   - `specs/BUILD_SPEC_001_v1_3_IMPL_PHASE_1A_PROMPT.md`
   - `specs/BUILD_SPEC_001_v1_3_IMPL_PHASE_1A_R2_PROMPT.md` (the
     M.1 fix prompt)
   - `specs/BUILD_SPEC_001_v1_3_IMPL_PHASE_1B_PROMPT.md`
   - `specs/BUILD_SPEC_001_v1_3_IMPL_PHASE_1C_PROMPT.md`
   - `specs/BUILD_SPEC_001_v1_3_IMPL_PHASE_1D_PROMPT.md`
   - `specs/BUILD_SPEC_001_v1_3_IMPL_PHASE_1E_PROMPT.md`

3. The locked specs (READ-ONLY, do not edit):
   - `specs/SPEC-001-phase3-binary.md` v1.3 — full file
   - `specs/SPEC-010-model-catalog.md` v1.5 — full file
   - `specs/SPEC-011-operator-pushed-warm-swap.md` v0.5 — full
     file
   - `specs/SPEC-002-coordinator.md` v1.3.5 — focus on §3, §7.1,
     §7.8, §7.10 to verify the binary-side doesn't contradict
     coordinator expectations

4. The implementation files under `phase3-binary/`:
   - `Sources/MacProviderCore/SupportedModels.swift`
   - `Sources/MacProviderCore/Config.swift`
   - `Sources/macprovider-cli/RuntimeStateMachine.swift`
   - `Sources/macprovider-cli/ModelRuntime.swift`
   - `Sources/macprovider-cli/CoordinatorClient.swift`
   - `Sources/macprovider-cli/HTTPServer.swift`
   - `Sources/macprovider-cli/ControlSocket.swift`
   - `Sources/macprovider-cli/ModelsSubcommand.swift`
   - `Sources/macprovider-cli/MacProviderCLI.swift`
   - `Sources/macprovider-cli/SwitchStateStore.swift`

5. The test files:
   - `Tests/macprovider-cliTests/*.swift` — all of them

6. The repo's per-project guidance:
   - `CLAUDE.md` at the repo root

DO NOT inspect any file under `phase3-binary/.build/checkouts/`
(d-inference and other third-party code is strictly clean-room
per the CLAUDE.md rule).

## Three review dimensions

You will produce findings in three distinct categories. A single
issue may surface in multiple categories — list it once in the
PRIMARY category and cross-reference from the others.

### Dimension 1: CODE REVIEW

Focus areas:
- **Correctness** — does the code do what the spec rules say it
  should? Look for bugs the unit tests may have missed.
- **Concurrency** — Swift actor isolation, `Task.detached`
  discipline, cancellation propagation, suspension points,
  reentrancy issues. The `ModelRuntime` actor is the hottest
  surface; check that `currentSnapshot()` never blocks the
  serial executor for long, that the load `Task.detached` in
  `beginSwap` doesn't accidentally close over actor state in a
  racy way, that `swapHeartbeatTask` and `ControlSocketServer`'s
  accept loop don't compete for the same actor.
- **Error handling** — are throws caught at the right layer?
  Are non-fatal errors logged-and-continued vs surfaced to the
  caller correctly? (E.g., `SwitchStateStore.writeLastSwitchMs`
  failure is non-fatal per the spec — verify.)
- **Resource lifecycle** — file descriptors (Unix-domain socket
  fds), `Task` cleanup on `stop()` / cancellation, `AsyncStream`
  continuation teardown, MLX `ModelContainer` releases on swap.
  Look for fd leaks, task leaks, retain cycles via
  `[weak self]` discipline.
- **Idiom violations** — Swift `actor` reentrancy gotchas,
  `Sendable` conformance correctness (look for
  `@unchecked Sendable` and verify it's justified),
  `JSONSerialization` vs `Codable` consistency.
- **Test quality** — do the tests actually exercise the
  invariants their names suggest, or are they
  passing-by-coincidence? Look for tests that only assert on
  the *implementation* rather than the *observable behavior*.
  Look for sleep-based timing assertions that could flake.

Findings format:
```
[code:N.M] [SEVERITY] <short title>
  File: <path>:<line>
  What: <one-paragraph description of the issue>
  Why: <impact — what breaks, when, and how bad>
  Fix: <suggested remediation; cite the binding spec rule if
        applicable>
```

### Dimension 2: SECURITY REVIEW

Threat model recap:
- Trust boundaries: operator (trusted), coordinator (trusted),
  buyer / inference requests (untrusted), other local processes
  (untrusted)
- High-value secrets: ECDH private key (in-memory only via
  `Tier2ProviderSession`), MDA artifact (read-only, on disk),
  the operator's USDC-earning wallet (NOT touched by this
  binary)
- Asset categories:
  - Wire bytes to coordinator (could enable billing manipulation
    if forgeable)
  - Inference traffic (could leak operator data if the path is
    coerced)
  - Local control socket (could enable an unauthorized local
    process to push swap commands)
  - Cooldown state file (low value; no secrets)

Focus areas:
- **Path traversal / TOCTOU** — `--ctl-socket-path` and
  `--switch-state-path` are operator-supplied; what if they
  contain `..`, are symlinks, or point to attacker-controlled
  paths? Does the binary follow the symlink and write through
  it? Is the operator-CLI vs serve-side identity gap exploitable?
- **Unix-domain socket permissions** — the spec mandates parent
  dir `0700` and socket `0600`. Verify:
  - The parent dir is chmod 0700 even if it pre-existed with
    laxer permissions (`mkdir -p` followed by `chmod 0700`).
  - The socket file itself is `0600` after bind (Codex uses
    `chmod(socketPath.path, S_IRUSR | S_IWUSR)` after bind —
    is there a window where the socket is `0666` for other
    processes to grab? umask matters here).
- **Frame injection / parser confusion** — the NDJSON control
  socket parser accepts JSON dicts; what about:
  - Extremely long lines (DoS via memory)
  - Embedded newlines in strings (line framing confusion)
  - Type confusion (`"requested_at_ms": "12345"` as string vs
    int)
  - Unicode tricks in `target_model_id` (HF model IDs have a
    specific shape; is validation enforced?)
- **Heartbeat / hello forgery surface** — can a malicious peer
  trigger the binary to emit a heartbeat with a hash it
  shouldn't? The hash source is the operator's local container —
  not directly controllable by buyer requests, but if a buyer's
  request can drive the state machine into `.loading`...
  actually no, buyer requests trigger HTTP 503 in
  `.loading`/`.draining`. Verify the inverse: can a buyer
  inference request trigger any state machine transition?
- **Tier-2 attestation paths** — 1A's `authInitialMessage`
  changes don't touch attestation, but the
  `provider_ecdh_public_key` and `tier2_capabilities` fields
  remain. Are they still emitted exactly as before? A
  regression here breaks SPEC-008 Pillar A.
- **Coordinator-side trust** — the coordinator-generated
  `auth_attempt_id` is echoed back on proof. Does the binary
  validate it survives serialization round-trips
  byte-identically? A subtle string encoding bug (NFC vs NFD)
  could break the contract.
- **Local privilege escalation via stale socket** — the spec
  says the binary refuses to bind if the socket file already
  exists. Verify there's no race window where a malicious local
  process could create the socket file between the existence
  check and the bind.
- **`--switch-state-path` write target** — could an operator
  attacker (or compromised user-mode process) point
  `--switch-state-path` at a system file (e.g.,
  `/etc/passwd`) and get the binary to write to it? The CLI
  runs as the operator user, so file mode permissions limit
  the blast radius — but verify no privilege escalation.
- **Authentication scope check** — does the
  `ControlSocketServer` perform any authentication on
  connecting clients? The spec relies on Unix-domain socket
  permissions (`0600`) for authorization — verify this is
  actually the only gate (no `getpeereid`-based check is
  needed since the FS perms enforce it, but the code should
  match that assumption explicitly in a comment or assertion).
- **Heartbeat extension info leak** — `model_hash` is the
  SHA-256 of the model weights manifest. The coordinator is
  trusted with this. But is the WS connection guaranteed
  TLS-only? Yes — `coordinator.malibu.tech` is HTTPS-only.
  Verify the WS scheme is `wss://` not `ws://`.

Findings format:
```
[sec:N.M] [SEVERITY] <short title>
  Asset: <what's at risk>
  Vector: <how an attacker exploits it>
  File: <path>:<line>
  Fix: <suggested remediation, e.g., add a check, change a
        permission, validate input>
```

### Dimension 3: ARCHITECTURE REVIEW

Focus areas:
- **Layering** — does the new `models` subcommand correctly
  reuse `ConfigLoader.load`? Are `CoordinatorClient` and
  `ControlSocketServer` correctly isolated from each other
  (they should communicate only through `ModelRuntime`)?
- **State machine completeness** — `RuntimeStateMachine` has
  four states (`ready`, `loading`, `draining`, `failed`). Is
  every reachable transition covered? Is there an unreachable
  `(loading, transitionToLoading)` path that could deadlock?
  What if `stop()` is called mid-swap (state is `.loading`)?
- **Coupling between phases** — the audit-trail BUILD prompts
  documented "out of scope" deferrals per phase. Verify none
  of those deferrals leaked: e.g., 1B's `swap_drain_timeout`
  field is "parked" until 1E, but 1E doesn't actually wire it
  to the drain timeout. Is that OK or a latent gap?
- **Surface area discipline** — 1B added `WarmSwapDisabledError`,
  1C added `ControlSocketError` /
  `ControlSocketConnectError` / `ControlSocketServerError` /
  `ControlSocketConnectionError`, 1A added
  `SupportedModelsValidationError`. Are these consistently
  used? Is there error-type proliferation that suggests a
  refactor opportunity?
- **Reentrancy in `ModelRuntime`** — actor methods that `await`
  release the serial executor. The `complete` / `stream`
  methods grab a `snapshot` at entry and use the snapshot's
  container ref for the rest of the call. Verify this pattern
  is consistent — does ANY actor method re-read mutable state
  AFTER an `await`?
- **The 1A R2 helper refactor (`runSupportedModelsPreflight`)**
  — is this static helper pattern carried through 1E (cooldown
  preflight)? Or did 1E inline the check directly in `run()`?
  Consistency matters.
- **Test architecture** — `EndToEndAcceptanceTests.swift` is
  638 lines (per Codex's report). Is it organized by AC
  number? Does it duplicate setup code across tests that
  could share a fixture? Is the `captureOutput` dup2 helper
  safe under XCTest parallel execution (it mucks with
  process-global stdout/stderr fds)?
- **The 1B `testLoader` / `testCompletion` injection points**
  — does the production init path also expose these or are
  they internal-only? If internal-only, is `@testable import`
  required to use them?
- **Documentation / discoverability** — for a future
  contributor reading just the code without the spec, are
  the binding spec rule citations visible in code comments?
  (Or is the code self-explanatory enough?)

Findings format:
```
[arch:N.M] [SEVERITY] <short title>
  What: <one-paragraph description>
  Trade-off: <what's gained vs lost by the current choice>
  Suggestion: <a concrete refactor or follow-up; NOT required
              for merge unless the severity says so>
```

## Severity scale (consistent across all three dimensions)

- **CRITICAL** — must be fixed before merge. Breaks an invariant
  the spec relies on (L-1 byte-identical default, atomic swap
  isolation, money-path billing correctness), creates a
  security hole that's exploitable by a realistic adversary,
  or crashes the binary on a happy path.
- **MAJOR** — should be fixed before merge OR explicitly
  deferred with a follow-up issue. Real bug, real impact,
  but not on the critical path; OR a security finding that
  requires unusual conditions to exploit.
- **MINOR** — would improve the code but does not block merge.
  Style, test-flakiness, idiom drift, sub-optimal but
  functional. Note for future polish.

## Output format

Return your findings as a single Markdown document with the
following structure:

```
# PR #5 pre-merge audit — Codex GPT-5

## Verdict

<one-line summary: MERGE-READY | MERGE-WITH-FIXES |
BLOCK-MERGE>

## Counts

| Dimension | CRITICAL | MAJOR | MINOR |
|---|---|---|---|
| Code        | <N> | <N> | <N> |
| Security    | <N> | <N> | <N> |
| Architecture| <N> | <N> | <N> |
| **Total**   | <N> | <N> | <N> |

## Findings

### Code review

[code:1.1] [SEVERITY] ...
[code:1.2] [SEVERITY] ...
...

### Security review

[sec:1.1] [SEVERITY] ...
...

### Architecture review

[arch:1.1] [SEVERITY] ...
...

## What I didn't review

<list of files/areas you intentionally skipped, with rationale>

## Cross-cutting observations

<any patterns that span multiple findings; e.g., "three
findings all stem from the same `@unchecked Sendable` choice
on RuntimeSnapshot — addressing that root cause closes all
three">
```

## Discipline

- Be specific. Cite `<file>:<line>` for every finding.
- Be conservative on CRITICAL. A finding is only CRITICAL if
  you can describe the concrete failure mode in one sentence.
- Be honest about uncertainty. If you suspect an issue but
  cannot confirm without running the code, mark it as MAJOR
  with a "needs verification" tag rather than CRITICAL.
- Do not invent findings to fill quota. If a dimension yields
  zero findings, report zero. The internal audit was thorough;
  finding nothing new IS a valid result.
- Cite the binding SPEC rule when claiming a violation. "This
  violates SPEC-011 R-3.2.5" beats "this looks wrong" by a
  mile.
- For security findings, model the attacker explicitly:
  "A local UID-0 attacker can ..." or "A buyer sending a
  crafted inference request can ..." Without the attacker
  model, the finding is just a code smell.

You may run shell commands to explore the repo (git log,
grep, find, file inspection). You MUST NOT run swift build,
swift test, or anything that mutates state. Cap shell
output at a reasonable volume; if you find a large file,
read the specific lines you need rather than dumping the
whole thing.

You may take up to 60 minutes wall-clock. If you finish
earlier with a clean report, that's fine; do not pad.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- Expected wall-clock: 30-60 min for Codex GPT-5 reading ~7000
  LOC of new Swift across five commits plus tests plus specs.
- The findings document is the input to the operator's
  merge/no-merge decision. If Codex returns CRITICAL findings,
  the operator drafts an R6 fix prompt (one per finding) and
  re-dispatches; otherwise PR #5 squash-merges.
- This is the equivalent of the SPEC-010 / SPEC-011 audit
  discipline but at the implementation layer rather than the
  spec layer. The same R1/R2 pattern applies if findings
  emerge.
- Result artifact lives under
  `.omc/artifacts/ask/codex-execute-the-pre-merge-audit-prompt-*`.
