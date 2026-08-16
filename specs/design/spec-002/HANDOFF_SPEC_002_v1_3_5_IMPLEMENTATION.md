# Handoff — SPEC-002 v1.3.5 coordinator implementation (Phase 2)

**Audience:** A fresh Claude Code session (or a continuation session)
that picks up the Phase 2 coordinator implementation work after PR #5
(SPEC-001 v1.3 binary) merged to `main` on 2026-06-07.

**Date:** 2026-06-07.

**Operator:** Augustas (handle: `Augustas11`, commit identity:
`a11 <augstar@gmail.com>`).

**Methodology:** Draft-build-audit loop — Claude Opus drafts BUILD
prompts + audits, Codex GPT-5 implements via `omc ask codex`. Human
operator approves merge timing. The same pattern that produced PR #5
in 5 sequential phase commits + 3 audit-driven fixes + 4 external audit
passes (final convergence at 0/0/0).

---

## 1. What's already done

### PR #4 (merged 2026-06-06) — BUILD-spec arc

Four LOCKED normative specs landed:
- **SPEC-010 v1.5** — Provider Model Catalog (capability advertisement)
- **SPEC-011 v0.5** — Operator-Pushed Warm Swap
- **SPEC-001 v1.3** — Phase 3 binary (this is the Mac provider Swift CLI)
- **SPEC-002 v1.3.5** — Phase 4 coordinator (this is the Go coordinator)

All four are READ-ONLY going forward. Your Phase 2 implementation
work consumes SPEC-002 v1.3.5 as the binding source-of-truth.

### PR #5 (merged 2026-06-07) — SPEC-001 v1.3 binary implementation

8-commit branch squashed into one main commit (`5d4f69d`). The Swift
binary in `phase3-binary/` now implements:
- SPEC-010 catalog flags + `MacProviderCore/SupportedModels.swift`
- Warm-swap state machine (4 states: `.ready / .loading / .draining
  / .failed`) with atomic swap + drain cancellation
- Control socket protocol (NDJSON on `$TMPDIR/macprovider-cli/ctl.sock`,
  parent 0700 / socket 0600) + `models list / switch / status`
  subcommand
- Heartbeat extension (opt-in `model_hash` raw lowercase hex + `loading:
  bool`) gated on `--enable-warm-swap`
- `hello.model_hash` source-of-truth rule on WS reconnect
- Cooldown soft guard (`SwitchStateStore`, `--force` bypass)
- End-to-end AC matrix covering AC-N.0 through AC-N.11
- Drain timeout cancellation per SPEC-011 R-3.4.2 (HTTP 503 with `code:
  "swap_drain_timeout"`)
- Post-swap `model_id` source-of-truth across heartbeat / hello /
  HTTPServer / InferenceRelay
- Streaming preflight/stream race elimination via `RequestHandle` value
  type

159 tests pass. L-1 byte-identical default preserved (a v1.3 binary
without `--enable-warm-swap` is wire-identical to v1.2.4).

---

## 2. What you need to do — SPEC-002 v1.3.5 implementation

The coordinator is **Go**, lives in `phase4-coordinator/`, deploys to
`coordinator.malibu.tech` (Pearl VPS). It accepts WebSocket
connections from the provider binaries and routes inference requests
from buyers.

SPEC-002 v1.3.5 is the locked spec at `specs/SPEC-002-coordinator.md`.
Read the whole file but focus on:

- **§3.X** (new) — `Provider` data-model extension with
  `SupportedModels[]`, `PublishesSupportedModels`, `HashStatus` enum,
  `LastLoadingState` sticky, `AuthAttemptRetention` map
- **§7.1** — heartbeat field extension + **ApplyHeartbeat
  REPLACEMENT** (this is the most consequential change — two-path
  dispatch at `phase4-coordinator/internal/pool/provider.go:411-432`)
- **§7.4** — `/v1/status` opt-in echo
- **§7.8** (new) — v2 `auth_request` provider handshake (first
  normative coordinator-side documentation)
- **§7.9** (new) — auth-attempt lifecycle with defer-based release
- **§7.10** (new) — audit-log SQLite infrastructure +
  `operator_model_swap` event with 8 REQUIRED + 2 OPTIONAL fields
- 18 new ACs (AC-K.0 through AC-K.17), each cites a binding SPEC-001 v1.3,
  SPEC-010 v1.5, SPEC-011 v0.5, or SPEC-008 v0.3 AC

---

## 3. Recommended phase decomposition

Mirror the PR #5 strategy: sequential phases on a single branch
(`fix/spec-002-v1-3-5-coordinator`), one commit per phase, squash-merge
at the end. Sequential beats parallel because each phase's BUILD prompt
can name the prior phase's concrete signatures.

Proposed split (subject to revision after you read the spec):

| Phase | Scope | Files (approximate) |
|---|---|---|
| **2A** | Provider struct extension (§3.X) — add the new fields, no behavior change yet; tests pin field zero-values for backward compat | `internal/pool/provider.go`, `internal/pool/*_test.go` |
| **2B** | v2 `auth_request` handshake (§7.8) + `auth_attempt_id` lifecycle (§7.9) — parse new fields, retention map with 1024 bound, defer-based release | `internal/ws/server.go`, `internal/ws/messages.go`, `internal/ws/auth.go` |
| **2C** | `ApplyHeartbeat` REPLACEMENT (§7.1) — the two-path dispatch (LEGACY clear / SPEC-011 re-verify); per-heartbeat field-presence selection | `internal/pool/provider.go:411-432`, dedicated tests for both paths |
| **2D** | `/v1/status` opt-in echo (§7.4) — conditional on `PublishesSupportedModels`; minimal change | `internal/api/handlers.go` (or wherever `/v1/status` lives) |
| **2E** | Audit-log infrastructure (§7.10) — SQLite schema, indexes, `operator_model_swap` emission with exactly-once + F-1.5 invariants + conditional emission per R-3.6.6 | `internal/audit/`, new package; `internal/pool/provider.go` (emission hook) |

Each phase: draft BUILD prompt → Codex implements via `omc ask codex` →
internal audit → R2 if needed → commit on branch. After 2E, external
pre-merge audit (mirror `specs/AUDIT_SPEC_001_v1_3_IMPL_PR5_PROMPT.md`).

**Phase 2C (ApplyHeartbeat REPLACEMENT) is the riskiest.** It changes
the semantics of a locked code path. Tests must exercise both paths
(LEGACY clear when SPEC-011 fields absent; SPEC-011 re-verify when
present) with exhaustive coverage of the path selection per
heartbeat.

---

## 4. The exact methodology that worked

### 4.1 BUILD prompt template

For each phase, write `specs/BUILD_SPEC_002_v1_3_5_IMPL_PHASE_<N>_PROMPT.md`
with this structure (PR #5 examples are in `specs/BUILD_SPEC_001_v1_3_IMPL_PHASE_*_PROMPT.md`):

1. **Front matter** — one-line scope summary, locked-spec dependencies,
   files allowed to edit (exhaustive whitelist)
2. **Critical constraints** — numbered list of 10-16 binding rules,
   each citing a SPEC section. Include L-1 byte-identical default
   invariant in every prompt.
3. **Required reading (in order)** — the spec sections, the prior
   phase commits, the production code files Codex will touch
4. **Required edits — exact shape** — Go code snippets showing the
   target shape, named types, signatures. Be precise. If you write
   "do something reasonable here," Codex will improvise; if you write
   the exact Go struct fields, Codex implements verbatim.
5. **Done criteria** — observable invariants (test names, file
   contents, exit codes)
6. **Out of scope** — explicit deferrals
7. **Self-check before reporting done** — a shell command Codex runs
   to verify the work before returning

### 4.2 Audit prompt — internal (Claude) per phase

Read the diff, check each of the 10-16 critical constraints. Verify L-1
holds. If finding, draft R2 prompt naming the specific finding +
fix. PR #5's 1A R2 prompt at
`specs/BUILD_SPEC_001_v1_3_IMPL_PHASE_1A_R2_PROMPT.md` is the canonical
example of an R2 fix prompt.

### 4.3 Audit prompt — external (Codex) before final merge

After all phases land, dispatch
`specs/AUDIT_SPEC_002_v1_3_5_IMPL_PR_PROMPT.md` (model after
`AUDIT_SPEC_001_v1_3_IMPL_PR5_PROMPT.md`). The external audit catches
what the internal audit misses — PR #5 found 8 distinct blocking
findings across 4 external audit rounds that the per-phase audits had
not flagged.

**The pre-merge external audit is the non-negotiable gate.** Money-path
code merits adversarial review.

---

## 5. Critical gotchas learned from PR #5 (apply to Phase 2)

### 5.1 Defense-in-depth on operator-controlled paths

PR #5's [sec:1.1] R1 finding: a same-UID local process could bypass the
CLI's `supported_models` validation by talking directly to the control
socket. Fix was to enforce the same check server-side.

**Phase 2 analog:** does the coordinator trust the binary's
self-reported state, or re-validate? Look for places where the binary's
claim is taken at face value. If a malicious binary could claim
`PublishesSupportedModels: true` without actually supporting the
models it advertises, that's a defense gap. (Probably not exploitable
in practice since providers are operator-authenticated, but worth
auditing.)

### 5.2 Source-of-truth across multiple call sites

PR #5's [code:1.2] R2 finding: post-swap `model_id` came from the
boot-time `ProviderStatus` snapshot on heartbeat / hello / HTTPServer /
InferenceRelay. Four separate call sites needed the source switch.

**Phase 2 analog:** when SPEC-002 v1.3.5 introduces a new field
(e.g., `Provider.SupportedModels`), audit ALL call sites that
historically read the related field. Look for `Provider.<oldField>`
references — each one might need the new source.

### 5.3 The drain timeout cancellation contract

PR #5's [code:1.1] R1+R2 finding: I scoped the drain phase wrong in the
R1 prompt by saying "in-flight requests continue to hold their snapshot
reference per R-3.2.2" — that contradicted SPEC-011 R-3.4.2 which says
cancel them. Reading the spec carefully and quoting the exact rule
matters.

**Phase 2 analog:** the audit-log emission per R-3.6.6 has a similar
"conditional emission" rule. WS-drop-during-loading + reconnect-after-
swap = NO event fires. Get the conditional logic right; tests must
cover the "should NOT emit" cases as explicitly as the "should emit"
cases.

### 5.4 Atomicity invariants under actor isolation

PR #5's [code:1.2] R1 finding: `applySwap` wrote container fields then
awaited the state-machine actor for the completion signal. The await
yielded isolation; concurrent snapshots could observe mixed state.

**Phase 2 analog:** Go uses mutexes not actors, but the same principle
applies. When ApplyHeartbeat updates multiple Provider fields, make
sure they're all written inside the same mutex hold. Avoid
`mu.Lock(); update(...); mu.Unlock(); <something async>; mu.Lock();
update(...); mu.Unlock()` patterns — write everything in one atomic
section if state must be consistent across reads.

### 5.5 The streaming preflight race

PR #5's [code:1.1] R3 finding: two separate actor invocations
(preflight then stream) had a race window between them. Fixed by
introducing a `RequestHandle` value type captured atomically.

**Phase 2 analog:** look for sequences of operations on `Provider`
state that should be a single atomic unit but are currently split.
ApplyHeartbeat's REPLACEMENT pattern (path selection then path
execution) might have this shape if path selection happens outside
the mutex.

### 5.6 BUILD prompt is the source of bugs too

PR #5's 1A R1 finding M.1 was MY prompt instruction telling Codex to
unconditionally call `validate(...)` which regressed L-1. Codex
implemented exactly what I wrote.

**Operator owns spec fidelity. Implementer owns idiom.** When you
write the BUILD prompt, every constraint is a contract. If you write
"always do X" but the spec says "only do X when condition Y," you
just authored a bug.

The fix: re-read the spec section the prompt cites BEFORE dispatching.
Quote rule numbers. Check the prompt against the spec, not just
against your understanding.

---

## 6. Repo conventions to keep in mind

### 6.1 Git identity

The repo uses a per-repo credential helper to route pushes to
`Augustas11`. You don't need to `gh auth switch`. Plain `git push
origin <branch>` just works. See `CLAUDE.md` at repo root for details.

If push fails with `403`, restore the helper per the runbook in
`CLAUDE.md`.

### 6.2 PR workflow

Money-path changes go through PRs. After squash-merge, **reset local
main**:
```bash
git checkout main
git fetch origin
git reset --hard origin/main
git branch -D <dead-branch>
```
Skipping this reset is what causes the "parallel-universe local main"
divergence — see Entry 50 / 56 / 57 / 58 in `beta/DECISION_CRITERIA.md`
for context.

### 6.3 Spec corpus

- `specs/SPEC-*` — normative specs (locked or in-audit)
- `specs/BUILD_SPEC_*_PROMPT.md` — operator-paste BUILD prompts
  consumed by Codex
- `specs/AUDIT_SPEC_*_PROMPT.md` — operator-paste audit prompts
  consumed by Codex
- `beta/DECISION_CRITERIA.md` — running decision log; append entries
  as decisions land. PR #5 = Entry 58.

### 6.4 d-inference clean-room

`d-inference` (https://github.com/layr-labs/d-inference) is **strictly
clean-room**. NOASSERTION license. DO NOT inspect their source. Any
BUILD prompt MUST explicitly forbid reading
`phase3-binary/.build/checkouts/` or any d-inference path.

### 6.5 Coordinator deploy target

Production coordinator: `coordinator.malibu.tech` (Pearl VPS).
Public installer redirect: `get.malibu.tech/install.sh`.

The v1.3.0 release tag deployment is BLOCKED until SPEC-002 v1.3.5 is
implemented AND deployed to production coordinator. PR #5 sits on main
but no binary release ships until your work + a coordinator deploy
land together.

---

## 7. Recommended first move

1. **Read** `specs/SPEC-002-coordinator.md` v1.3.5 fully (§3.X, §7.1,
   §7.4, §7.8, §7.9, §7.10, AC-K.* matrix). Allow yourself 30-45
   minutes. This spec is dense.

2. **Read** the corresponding sections in SPEC-001 v1.3 (§6.7, §6.10,
   §6.11) for the binary-side mirror — your coordinator code must
   accept what the binary sends.

3. **Read** the PR #5 build prompts as methodology examples:
   `specs/BUILD_SPEC_001_v1_3_IMPL_PHASE_1B_PROMPT.md` (the largest /
   trickiest of the phase prompts) and
   `specs/BUILD_SPEC_001_v1_3_IMPL_PR5_PREMERGE_FIX_R2_PROMPT.md` (the
   most surgical / spec-citation-heavy of the fix prompts).

4. **Skim** the PR #5 audit prompt at
   `specs/AUDIT_SPEC_001_v1_3_IMPL_PR5_PROMPT.md` to understand the
   three-dimension review structure (code / security / architect).

5. **Inspect** the current `phase4-coordinator/` codebase:
   - `internal/pool/provider.go:411-432` — the ApplyHeartbeat code
     path SPEC-002 v1.3.5 will REPLACE
   - `internal/ws/server.go:354-355` — where `auth_attempt_id` is
     generated and the 10-min retention timeout lives
   - `internal/ws/messages.go` — the AuthRequest struct + frame
     validator + parseAuthInitial / parseAuthProof

6. **Confirm Phase 2A scope with the operator** before writing the
   first BUILD prompt. Ask: "Should Phase 2A be Provider struct
   extension only (no behavior change), or should it bundle with v2
   handshake parsing?" The operator's answer drives the decomposition.

7. **Branch:**
   ```bash
   git checkout main
   git fetch origin
   git reset --hard origin/main  # ensure clean state per §6.2
   git checkout -b fix/spec-002-v1-3-5-coordinator
   ```

8. **Draft + dispatch Phase 2A:**
   ```bash
   # Write specs/BUILD_SPEC_002_v1_3_5_IMPL_PHASE_2A_PROMPT.md
   # Then:
   omc ask codex "execute the build prompt at specs/BUILD_SPEC_002_v1_3_5_IMPL_PHASE_2A_PROMPT.md verbatim ..."
   ```

9. **Audit, commit, push, move to 2B.**

10. **After 2E lands**, draft the external pre-merge audit prompt and
    dispatch. Iterate fixes until 0/0/0.

11. **Merge to main**, then coordinate with operator on production
    deploy to `coordinator.malibu.tech`. Once coordinator deploy is
    confirmed live, the v1.3.0 binary release tag can ship.

---

## 8. Strategic context (so you understand why this matters)

The macprovider stack powers AntFeed, a P2P AI marketplace on Base
where operators with Mac hardware earn USDC for serving inference.
SPEC-001 v1.3 (binary) and SPEC-002 v1.3.5 (coordinator) together
close two arm64golf canary operator pains:

- **Pain #1:** multi-minute restart loop to change served model
  (closed by SPEC-011 warm swap)
- **Pain #2:** red dashboard / WS reconnect on swap (closed by
  SPEC-011 atomic state machine + hello reconnect preservation)

The arc began with Entry 54 (SPEC-010 lock 2026-06-06) → Entry 55
(SPEC-011 lock) → Entry 56 (SPEC-001 v1.3 lock) → Entry 57 (SPEC-002
v1.3.5 lock) → Entry 58 (PR #5 implementation complete).

Your Phase 2 work is Entry 59-style: the coordinator-side
implementation that, combined with PR #5, lets the network actually
ship warm swap. Without your work, PR #5's warm-swap features are
inert (operators who enable `--enable-warm-swap` against the current
production v1.3.4 coordinator would see degraded heartbeat handling).

---

## 9. Final notes from the previous session

- All 159 PR #5 tests passing. `cd phase3-binary && swift test`
  validates the implementation end-to-end.
- The `beta/DECISION_CRITERIA.md` file has an UNSTAGED Entry 58
  edit in the operator's working tree. Operator may commit that
  separately or as part of your Phase 2 final PR — ask before
  staging it.
- `specs/FOLLOWUP_COORDINATOR_HA_2026_06_03.md` has an unrelated
  unstaged edit. Leave it alone.
- The pre-merge audit pattern was empirically validated: 4 audit
  rounds found 8 blocking issues across ~7000 LOC. Skipping it would
  have shipped real bugs.
- Your single biggest risk: writing a BUILD prompt that contradicts
  SPEC-002 v1.3.5. Quote the rule numbers. Re-read before
  dispatching. The 1A M.1 finding was MY mistake, not Codex's —
  don't repeat that pattern.

Good luck. The methodology compounds. Each phase you ship makes the
next one faster because the prior phase's surface is now real code
your prompts can cite.

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7) by the previous session that produced PR #5.
