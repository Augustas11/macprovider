# SPEC-011 — Operator-Pushed Warm Swap

**Version:** 0.5 (post round-3 polish pass — LOCK candidate)
**Status:** Draft (pre round-4 LOCK-confirmation audit)
**Date drafted:** 2026-06-06
**Depends on (REQUIRED):** SPEC-010 v1.5 (LOCKED 2026-06-06,
Decision-log Entry 54) — SPEC-010 provides `supported_models[]`
and `publishes_supported_models` on the v2 `auth_request`
frame which R-3.1.6 binary-side validation depends on.
**Companion to (LOCKED):** SPEC-001 v1.2.4 (becomes v1.3
candidate per §6.1), SPEC-002 v1.3.4 (becomes v1.3.5
candidate per §6.2), SPEC-004 v0.3.1, SPEC-008 v0.3.

**Change log v0.5 (round-3 polish pass — LOCK candidate):**
Round-3 verdict was LOCK-READY pending narrow polish with
0 CRITICAL / 0 MAJOR / 2 MINOR (specs/SPEC-011-audit.md
round 3). v0.5 closes both MINORs as a final polish before
the round-4 LOCK-confirmation audit (same trajectory as
SPEC-010 v1.4 → v1.5 → LOCK).
- **B3.1 MINOR fix** (AC-26 grep contract was impossible
  to satisfy as written): AC-26 reworded. The contract is
  now: `$XDG_RUNTIME_DIR` MUST NOT appear in any
  **advertised default value, wire example, or config
  block**. It MAY appear in (a) change-log entries
  describing the removed v0.3 default, (b) R-3.1.5 "Why
  not" rationale, (c) R-3.9.2 prohibition rule body, and
  (d) AC-26's own forbidden-token name. The grep contract
  is now a structural assertion ("no advertised default in
  §3.9 config block names $XDG_RUNTIME_DIR; no R-3.x rule
  outside R-3.9.2 names it as a default") rather than a
  literal substring count.
- **F3.1 MINOR fix** (residual editorial drift in 2 spots):
  (a) §6.1 SPEC-001 v1.3 candidate annotation cited
      `SPEC-011 v0.3 §3.1`; updated to `SPEC-011 v0.x
      locked §3.1` (version-agnostic per SPEC-010 v1.5
      G5.1 pattern — survives future patch revisions
      without re-edit).
  (b) R-3.7.3 still contained one untyped shorthand
      `{accepted: false, reason: "cooldown",
      seconds_remaining: N}` — converted to typed
      `switch_ack` frame reference per R-3.1.5 schema
      (the v0.4 sed pass missed it because the literal
      didn't have `switch_ack{` prefix).

**Change log v0.4 (round-2 normative audit response):**
Round-2 produced 0 CRITICAL / 2 MAJOR / 4 MINOR findings at
`specs/SPEC-011-audit.md` round 2. v0.4 closes all 6. Both
MAJORs were narrow citation-consistency drifts: the R-3.1.5
macOS-native socket path was correctly fixed in v0.3, but
§3.9's config summary still cited the old path; and R-3.1.5's
typed control-socket frames were defined correctly, but
§3.1.2 step 4's prose still used untyped shorthand.
- **R2-B2.1 MAJOR fix** (§3.9 advertises stale
  `$XDG_RUNTIME_DIR` default): §3.9 config-additions
  summary now lists `--ctl-socket-path` defaulting to
  `$TMPDIR/macprovider-cli/ctl.sock` (matching R-3.1.5).
  Added `--enable-warm-swap` and `--switch-state-path`
  flags to the same summary block. v0.4 also adds AC-26
  asserting no live default path text mentions
  `$XDG_RUNTIME_DIR`.
- **R2-C2.1 MAJOR fix** (§3.1.2 step 4 untyped shorthand):
  step 4 rewritten to reference R-3.1.5 frame shapes
  explicitly. The CLI sends a typed `switch_request` frame
  with `type`, `target_model_id`, and `requested_at_ms`
  per R-3.1.5; the serve process replies with typed
  `switch_ack` per R-3.1.5. Same fix applied to R-3.7.1
  and R-3.7.3 example references. No untyped shorthand
  remains anywhere in §3.1, §3.7, §3.8.
- **R2-A2.1 MINOR fix** (disabled-vs-no-serve detection
  ambiguous): new R-3.1.5.x sub-rule defines exact
  precedence: CLI attempts socket connect; if connect
  fails with ENOENT (no socket file), report "serve not
  running" (exit 4); if connect fails with ECONNREFUSED
  (socket exists but no listener), report "stale socket;
  remove and restart" (exit 4); if connect succeeds but
  the immediate `status_request` handshake gets no reply
  within 2s, report "serve running but unresponsive
  (likely disabled warm swap)" (exit 4). No new
  mechanism beyond the existing socket connect path.
- **R2-A2.2 MINOR fix** (AC-18 doesn't cover all L-1
  observables): AC-18 extended with explicit assertions
  for `/v1/status`, `/v1/models`, and a representative
  `/v1/chat/completions` request comparison against
  pre-SPEC-011 baseline (with SPEC-010 opt-in
  differences excluded from the oracle).
- **R2-G2.1 MINOR fix** (AC-23 debug hook undefined):
  AC-23 prelude now explicitly requires a
  package-internal test accessor (e.g. unexported
  `runtimeTransitionCount()` reachable from `_test.swift`
  within the binary's package). Same pattern as
  SPEC-010 v1.4 AC-18(d).
- **R2-K2.1 MINOR fix** (editorial residue):
  - §5 footer "Total: 20 ACs" → "Total: 26 ACs" (25 from
    v0.3 + 1 added in v0.4 as AC-26 per R2-B2.1)
  - §6.2 / §6.3 / §6.6 "SPEC-011 v0.2" references → "v0.3"
    where the current draft is meant (kept as "v0.2" only
    where genuinely referring to the v0.2 historical
    version)
  - AC-25 lower-bound label "< 5 min" → "< 5s minimum"
    (5-second minimum per R-3.9.1)

**Change log v0.3 (round-1 normative audit response):** Round-1
produced 2 CRITICAL / 5 MAJOR / 3 MINOR findings at
`specs/SPEC-011-audit.md`. v0.3 closes all 10. Two CRITICALs
were the highest-leverage fixes:

- **A.1 CRITICAL fix** (L-1 lock violation — heartbeat field
  emission in default case): SPEC-011 v0.3 introduces an
  explicit opt-in flag `--enable-warm-swap` (default `false`)
  on the `serve` subcommand. When the flag is `false`:
  - The `models` CLI subcommand is unavailable (R-3.1 returns
    a clear "warm swap not enabled" error if invoked)
  - The binary does NOT emit `loading` or `model_hash`
    heartbeat fields
  - The runtime stays on the legacy synchronous single-load
    path (no state machine, no control socket, no async-load
    surface)
  - All §3 normative surface is dormant; behavior is
    byte-identical to pre-SPEC-011
  When `--enable-warm-swap=true`, all §3 normative behavior
  activates. AC-18 + AC-19 now assert L-1 holds at the
  default (`--enable-warm-swap=false`).
- **C.1 CRITICAL fix** (`$XDG_RUNTIME_DIR` doesn't exist on
  macOS): R-3.1.5 default control socket path changed to
  `$TMPDIR/macprovider-cli/ctl.sock` (macOS-native; standard
  for transient runtime files via `FileManager.default.temporaryDirectory`).
  Cooldown state file moved to a per-user persistent location
  (`$HOME/Library/Application Support/macprovider-cli/`).
  `--ctl-socket-path` override unchanged.

The 5 MAJORs + 3 MINORs:

- **B.1 fix** (control-socket frame `type` field
  consistency): every example in §3.1.5 now includes the
  `type` field; absence of `type` is normatively a
  `bad_request` per R-3.1.5.x.
- **B.2 fix** (503 envelopes not full SPEC-001 shape): §3.4.2
  and §3.4.4 503 examples now use the complete SPEC-001 §6.0
  / SPEC-010 v1.x §4.6.2 OpenAI error envelope shape with
  `error.type`, `error.code`, `error.message`, `error.param`,
  `retry_after_seconds` (where applicable).
- **C.2 fix** (hello.model_hash citation drift): §3.8.3
  reconnect text now cites current code (Go `Hello` struct
  has `ModelHash`; Swift `helloMessage` emits `model_hash`)
  + SPEC-008 §5.4 candidate annotation as source of truth,
  NOT locked SPEC-001 §6.5 (which doesn't document the
  field). Source-of-truth note matches SPEC-010 v1.2's
  pattern for code-only contracts.
- **C.3 fix** (`model_hash` format mismatch): SPEC-011 v0.3
  uses **raw 64-character lowercase hex** for `model_hash`
  everywhere (heartbeat field, audit event payload, all
  examples), matching SPEC-008 §5.3 and current Swift output
  at `ModelRuntime.swift:294-325`. The `"sha256:"` prefix
  used in v0.2 is REMOVED.
- **D.1 fix** (missing AC coverage): 5 new ACs (AC-21
  through AC-25) cover `--force`/cooldown semantics,
  control-socket frame parsing rejection, boot path stays
  non-loading, runtime-vs-CLI cooldown distinction, and
  `swap_drain_timeout_seconds` range validation.
- **D.2 fix** (AC-20 grep too permissive): AC-20 adds a
  positive allowlist of permitted audit payload keys and
  asserts no key outside the allowlist appears, in addition
  to the existing grep on `conv:`, `account_id`, prompt
  text, sticky identifiers.
- **E.1 fix** (§6.4 overstates request_log non-involvement):
  §6.4 reworded — SPEC-011 introduces no new billing or
  ledger semantics; existing `request_log` behavior for
  503 outcomes is unchanged and remains governed by
  SPEC-005.
- **E.2 fix** (§6.1 SPEC-001 §6.6 numbering collision):
  §6.1 now uses explicit "§6.7+" candidate numbering after
  the existing locked §6.6 (Inference message types).

**Outline history (preserved in git):** SPEC-011 v0.1 + v0.1.1
were OUTLINE versions reviewed in two pre-draft outline-audit
rounds at `specs/SPEC-011-outline-audit.md`. v0.2 was the first
full normative draft. v0.2 incorporated:
- **C2.1 fix** (outline round 2 MAJOR): §3.8 WS drop mid-load
  reconnect uses **`hello`** (locked SPEC-001 §6.5 / SPEC-002
  §7.1 reconnect flow), NOT `auth_request`. Outline v0.1.1
  incorrectly cited `auth_request` for reconnect.
- **D2.1 fix** (outline round 2 MAJOR): §6.2 SPEC-002 v1.3.5
  candidate explicitly lists the heartbeat hash-clearing
  REPLACEMENT as a SPEC-002 normative edit (NOT just additive).
  Current `ApplyHeartbeat`
  ([provider.go:420-432](../phase4-coordinator/internal/pool/provider.go))
  clears `ModelHash` on `ModelID` change; v0.2 R-3.3.5 replaces
  this when heartbeat `model_hash` is present.
- **A2.1 fix** (outline round 2 MINOR): AC count target is 20
  (not 16). §5 enumerates 20 ACs.
- **C2.2 decision** (outline round 2 QUESTION): conditional
  `operator_model_swap` emission per R-3.8.4 is documented as
  an explicit "observation-only audit invariant" — events fire
  iff the coordinator observed a `loading: true` heartbeat.
  WS-drop-mid-load completed swaps that bypass observation
  produce no event. No backfill mechanism in v0.2. Operators
  who require complete swap audit MUST keep WS sessions alive
  during loads.

**Trigger:** arm64golf canary run (2026-06-05). Operator pains
#1 (no CLI to change active model on a running provider) and #2
(restart causes WS reconnect + cold load + red dashboard).
SPEC-011 closes both.

---

## 1. Problem statement

### 1.1 Symptom (arm64golf canary)

Operator wanted to change the served MLX model on a running
provider. Today's only option: kill the binary, restart with
`--model <new-id>`, accept multi-minute downtime (cold load +
WS reconnect + admission) and a red dashboard for the duration.
Pain points #1 and #2 from the canary.

SPEC-010 v1.x added `supported_models[]` to the auth handshake
so the operator can declare in advance which models the provider
is willing to serve. SPEC-011 closes the gap: an operator on
the provider host can switch the warm model among the declared
set, in-process, without WS reconnection or coordinator-side
admission churn.

### 1.2 Scope

SPEC-011 is **operator-pushed and binary-local**. The
coordinator is a passive observer of the heartbeat-reported
`ModelID` change. There is NO coordinator → provider control
message; that surface (`set_model`) is SPEC-012's territory.

The arm64golf operator gets:
- A CLI: `macprovider-cli models switch <id>`
- Async load in the binary runtime while in-flight requests
  drain on the old model
- A new audit event the coordinator emits on observing the swap
- No buyer-facing behavior changes

The arm64golf operator does NOT get from SPEC-011:
- Buyer-facing visibility of `supported_models` (SPEC-012)
- Demand-pulled cold-wake (SPEC-012)
- `/v1/status.state` dashboard field (SPEC-012)
- A recommended catalog (SPEC-012 / future SPEC-013)

### 1.3 The four-pain canary closure (honest accounting)

| Pain | SPEC closing it |
|---|---|
| #1 No CLI to change active model | **SPEC-011** R-3.1.x |
| #2 Restart causes red dashboard | **SPEC-011** R-3.2.x async load avoids restart entirely; binary stays connected throughout |
| #3 Buyer picker shows only loaded model | SPEC-012 (with SPEC-008 v0.4 pairing) |
| #4 No HF ID discovery | SPEC-012 or future SPEC-013 |

---

## 2. Locked design decisions

Non-negotiable inputs. Not subject to audit revision.

| Lock | Decision |
|---|---|
| L-1 | **Backward compatible (operator opt-in).** The default for the SPEC-011 binary is `--enable-warm-swap=false`. In that mode: the `models` CLI subcommand is unavailable, the runtime stays on the legacy synchronous load path, the control socket is not opened, and heartbeats DO NOT carry the new `loading` or `model_hash` fields. Behavior is byte-identical to pre-SPEC-011 binary. SPEC-011 normative surface (§3.x) activates only when the operator explicitly sets `--enable-warm-swap=true` on the `serve` subcommand. This means: an operator who upgrades to a SPEC-011 binary but does not change their startup flags sees zero behavior change. (A.1 round-1 CRITICAL fix.) |
| L-2 | **Operator-initiated only.** No coordinator-side trigger for swap. Coordinator is a passive observer of provider-reported heartbeat changes. |
| L-3 | **Single routing-eligible warm model per process at any moment.** During load, the binary still holds the OLD container in memory to serve in-flight requests until drain completes — that container is NOT routing-eligible for new dispatch. The provider has zero *routing-eligible* warm models while `loading: true`, while old-container drain may still be in progress. |
| L-4 | **SPEC-008 Pillar A re-runs on hash arrival; no new hash_status value.** During load the provider is not routing-eligible, so the hash predicate is vacuously satisfied. On post-swap heartbeat with new `model_hash`, SPEC-008 §5.3-5.6 re-runs per R-3.5. |
| L-5 | **No billing change.** Operator-pushed swap is not a billable inference attempt. No SPEC-005 ledger interaction. |
| L-6 | **F-1.5 invariants preserved.** No new wire surface touches sticky derivation, `conv:`, or sticky TTL. The `operator_model_swap` audit event payload contains no buyer prompt text, no raw `account_id`, no sticky identifiers. |
| L-7 | **No coordinator config knob for cooldown.** Cooldown / thrash prevention is the operator-CLI's responsibility (per R-3.1.4 default 10s soft guard, bypassable with `--force`). Coordinator does not gate operator-initiated swaps; that's L-2. |

---

## 3. Wire spec (NORMATIVE)

### 3.1 Provider binary: `models` CLI subcommand

The current binary is `macprovider-cli` with existing
subcommands `serve`, `status`, `self-test`, `update`,
`uninstall` (per
[MacProviderCLI.swift:7-15](../phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift)).
SPEC-011 v0.3 adds a `models` subcommand with three actions,
**gated on the `--enable-warm-swap` flag on `serve`**.

```
macprovider-cli serve --enable-warm-swap [...other flags...]
macprovider-cli models list
macprovider-cli models switch <model-id> [--force]
macprovider-cli models status
```

#### Rules

- **R-3.1.0** **Opt-in gate (A.1 round-1 CRITICAL fix).** The
  SPEC-011 normative surface activates ONLY when the operator
  invokes `serve` with `--enable-warm-swap`. The flag is a
  boolean (presence enables; `--enable-warm-swap=false`
  explicitly disables; `--enable-warm-swap=true` explicitly
  enables; the flag's default state is DISABLED). When
  disabled:
  - The serve process MUST NOT open the §3.1.5 control socket.
  - The serve process MUST NOT host the §3.2 state machine
    (legacy synchronous load path remains).
  - The serve process MUST NOT emit `loading` or `model_hash`
    heartbeat fields (§3.3 fields stay omitted from the wire).
  - Any invocation of `macprovider-cli models <subcommand>`
    MUST detect the disabled state (via control socket
    absence per R-3.1.5) and exit code 4 with stderr
    `"warm swap not enabled; restart serve with
    --enable-warm-swap"`.
  - Coordinator-side R-3.3.5 SPEC-011 path is dormant
    (heartbeats lack `model_hash`, falling to legacy path).
  When enabled: all §3 normative behavior activates.
  Operators who never enable warm swap see byte-identical
  pre-SPEC-011 behavior; this preserves L-1.

- **R-3.1.1** `macprovider-cli models list` MUST print a table
  to stdout showing local model state. Each row:
  - `model_id` (HuggingFace ID or local path)
  - `state` ∈ {`warm`, `idle`}
    - `warm`: model is the current `loaded_model` in the
      running serve process (queried via control socket per
      R-3.1.5)
    - `idle`: model is on disk in the HF cache but not loaded
  - `disk_size_gb` (optional, derived from cache inspection)

  If no serve process is running, output indicates so and lists
  HF cache contents with all rows marked `idle`. Exit code 0 in
  both cases.

- **R-3.1.2** `macprovider-cli models switch <model-id>` MUST
  perform the following sequence in order:
  1. Resolve effective `supported_models` per SPEC-010 R-3.6.1
     priority (CLI flag > ENV > config file).
  2. Per SPEC-010 R-3.6.3, validate `<model-id>` is in the
     effective `supported_models` set (case-folded per SPEC-010
     R-3.1.7). On mismatch, exit code 2 with stderr
     `"switch target <X> not in --supported-models"` BEFORE
     contacting the running process.
  3. Connect to the running serve process via the control
     socket per R-3.1.5 (macOS default
     `$TMPDIR/macprovider-cli/ctl.sock`). Use R-3.1.5.x
     detection precedence to distinguish "serve not
     running" vs "stale socket" vs "serve running but
     warm-swap disabled"; in each case exit code 4 with
     the specific stderr message defined in R-3.1.5.x.
  4. Send a typed `switch_request` frame over the control
     socket per R-3.1.5 schema. **The exact wire payload
     is the R-3.1.5 `switch_request` shape** (REQUIRED
     `type`, `target_model_id`, `requested_at_ms` fields;
     NOT the v0.2 untyped shorthand
     `{target_model_id: <X>}` which is REMOVED in v0.4
     per R2-C2.1 fix). Concretely:
     ```json
     {"type": "switch_request",
      "target_model_id": "<X>",
      "requested_at_ms": <epoch-ms>}
     ```
     The serve process replies with a typed `switch_ack`
     frame per R-3.1.5 schema (REQUIRED `type`, `accepted`
     fields; conditional `reason`, `current_target`,
     `seconds_remaining` fields per R-3.1.5 Field
     reference). Branches:
     - `{type: "switch_ack", accepted: true}` → CLI
       proceeds to step 5.
     - `{type: "switch_ack", accepted: false, reason:
       "loading_in_progress", current_target: "Y"}` →
       CLI exits code 3 with stderr `"provider is already
       loading <Y>; refusing to start a second swap. Wait
       for current switch to complete (macprovider-cli
       models status)"`.
     - `{type: "switch_ack", accepted: false, reason:
       "cooldown", seconds_remaining: N}` → CLI exits
       code 6 with stderr `"swap on cooldown for <N>s.
       Re-issue with --force to bypass"`. Per L-7,
       cooldown is a CLI-side soft guard (default 10s
       since last switch); `--force` bypasses it.
  5. Stream typed `switch_progress` frames per R-3.1.5
     schema from the serve process to stderr. Each frame
     has REQUIRED `type`, `state`, `elapsed_ms`. State
     enum:
     - `loading` (sent immediately by serve after accept)
     - `draining` (sent when load completed; in-flight
       drain in progress)
     - `loaded` (sent on atomic swap success)
     - `failed` (sent on load failure; REQUIRED `reason`
       field per R-3.1.5; serve rolled back to old model)
  6. Exit code:
     - `0` — load succeeded, atomic swap done, new model warm
     - `2` — pre-flight validation failed at step 2
     - `3` — concurrent switch refused at step 4
     - `4` — serve process unreachable at step 3
     - `5` — load failed at runtime; provider rolled back to
       old model with no observable coordinator-side change
     - `6` — cooldown rejection at step 4 (without --force)

- **R-3.1.3** `--force` MUST suppress the R-3.1.2 step 4
  cooldown check ONLY. It MUST NOT suppress step 2
  (supported_models validation) or step 7 below.

- **R-3.1.4** **CLI-side cooldown soft guard (L-7).** The CLI
  MUST track the timestamp of the last successful or in-flight
  `models switch` invocation in a per-host state file at:
  - macOS default:
    `$HOME/Library/Application Support/macprovider-cli/last-switch.ts`
    (durable user-state location; survives reboot, which is
    desirable for short cooldown windows that might span a
    crash)
  - Override via `--switch-state-path` flag
  If `<now> - <last-switch> < 10s`, the CLI MAY exit code 6 in
  step 4 above (this is the SOFT guard; the serve process also
  reports cooldown if its own state indicates an in-flight
  load). `--force` bypasses the soft guard.

- **R-3.1.5** **Control socket (in-process signaling) — macOS
  default (C.1 round-1 CRITICAL fix).** The serve process MUST
  listen on a Unix domain socket at:
  - macOS default: `$TMPDIR/macprovider-cli/ctl.sock`. Per
    macOS convention, `$TMPDIR` is always set to a
    per-process / per-user temporary directory (typically
    `/var/folders/<random>/T/`). Swift code uses
    `FileManager.default.temporaryDirectory` to resolve. The
    socket parent directory MUST be created with mode `0700`
    and the socket itself with mode `0600`.
  - Override via `--ctl-socket-path` flag.
  Why not `$XDG_RUNTIME_DIR`: that variable is a Linux/
  freedesktop convention and is not set on stock macOS.
  Empirically verified by `printenv XDG_RUNTIME_DIR` on the
  target deployment platform: unset.

  **Control socket protocol — newline-delimited JSON. Every
  message MUST include a `type` field (B.1 round-1 fix).**
  Messages with missing or unknown `type` MUST be discarded
  by the receiver and the receiver MUST close the connection
  with an error log line. Exact frame shapes:

  CLI → serve:
  ```json
  {"type": "switch_request",
   "target_model_id": "mlx-community/Llama-3.1-8B-Instruct-4bit",
   "requested_at_ms": 1717696989123}
  ```
  ```json
  {"type": "status_request"}
  ```

  serve → CLI:
  ```json
  {"type": "switch_ack",
   "accepted": true}
  ```
  ```json
  {"type": "switch_ack",
   "accepted": false,
   "reason": "loading_in_progress",
   "current_target": "mlx-community/Llama-3.1-8B-Instruct-4bit"}
  ```
  ```json
  {"type": "switch_ack",
   "accepted": false,
   "reason": "cooldown",
   "seconds_remaining": 7}
  ```
  ```json
  {"type": "switch_progress",
   "state": "loading",
   "elapsed_ms": 1240}
  ```
  ```json
  {"type": "switch_progress",
   "state": "failed",
   "reason": "oom",
   "elapsed_ms": 3812}
  ```
  ```json
  {"type": "status_response",
   "current_model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
   "runtime_state": "ready"}
  ```

  Field reference:
  - `type`: REQUIRED on every frame. One of
    `switch_request`, `status_request`, `switch_ack`,
    `switch_progress`, `status_response`.
  - `target_model_id`: REQUIRED on `switch_request`. String,
    HuggingFace ID or local path per SPEC-001 §6.1 model_id
    shape.
  - `requested_at_ms`: REQUIRED on `switch_request`. Int,
    epoch ms.
  - `accepted`: REQUIRED on `switch_ack`. Bool.
  - `reason`: REQUIRED on `switch_ack` when
    `accepted: false`. String enum: `loading_in_progress`,
    `cooldown`, `not_in_supported_models`, `other`.
  - `current_target`: REQUIRED on `switch_ack` when
    `reason: loading_in_progress`. String.
  - `seconds_remaining`: REQUIRED on `switch_ack` when
    `reason: cooldown`. Int.
  - `state`: REQUIRED on `switch_progress`. String enum:
    `loading`, `draining`, `loaded`, `failed`.
  - `reason`: REQUIRED on `switch_progress` when
    `state: failed`. String.
  - `elapsed_ms`: REQUIRED on `switch_progress`. Int,
    elapsed since CLI's `requested_at_ms`.
  - `current_model_id`: REQUIRED on `status_response`.
    String.
  - `runtime_state`: REQUIRED on `status_response`. String
    enum: `ready`, `loading`, `draining`.

- **R-3.1.5.x** **Disabled-vs-no-serve detection precedence
  (R2-A2.1 round-2 fix).** When `macprovider-cli models
  <subcommand>` attempts to connect to the control socket
  per R-3.1.5, the CLI MUST distinguish three failure modes
  using the existing Unix domain socket primitives — no new
  detection mechanism is required:
  1. **`stat(socket_path)` returns ENOENT** (socket file
     does not exist) → "serve not running on this host."
     Exit code 4 with stderr `"macprovider-cli serve is not
     running on this host (no control socket at
     <socket_path>)"`.
  2. **`connect(socket_path)` returns ECONNREFUSED** (socket
     file exists but no process is listening) → "stale
     socket; serve crashed or was killed without cleanup."
     Exit code 4 with stderr `"stale control socket at
     <socket_path> (no listener); remove the file and
     restart serve"`.
  3. **`connect` succeeds but the immediately-sent
     `status_request` frame gets no `status_response` within
     2 seconds** → "serve running but warm-swap is disabled
     (R-3.1.0 disabled mode does not open the control
     socket; if the socket exists and accepts but doesn't
     respond, either a stale process is wedged OR a
     pre-SPEC-011 binary is squatting the path)." Exit code
     4 with stderr `"serve is running but warm-swap is not
     enabled (or serve is unresponsive); restart serve with
     --enable-warm-swap"`. Note: R-3.1.0 says a serve
     started without `--enable-warm-swap` MUST NOT open the
     socket, so case (3) should not occur with a correctly-
     implemented v0.4 serve. It is included for diagnostic
     robustness against legacy or wedged processes.

  This precedence keeps the disabled-mode UX clear without
  requiring a pid file, lock file, or separate health-probe
  mechanism.

- **R-3.1.6** `macprovider-cli models status` MUST send a
  `status_request` over the control socket and print the
  response to stdout. Exit code 0 on success, 4 if serve is
  not running.

### 3.2 Provider binary runtime: state machine + async load

**Current architecture (locked).** The Swift `ModelRuntime`
actor at
[ModelRuntime.swift:25-68, 86-147](../phase3-binary/Sources/macprovider-cli/ModelRuntime.swift)
stores `modelID`, `container`, `modelHash` as immutable `let`
fields initialized once at startup. SPEC-011 v0.4 requires
refactoring this to a mutable-state runtime.

#### State machine (NORMATIVE)

```
                   ┌───────────┐
                   │   ready   │◄─────────────────┐
                   └─────┬─────┘                  │
                         │ models switch <X>      │
                         ▼                        │
                   ┌───────────┐                  │
                   │  loading  │                  │
                   └─────┬─────┘                  │
                ┌────────┴────────┐               │
                ▼                 ▼               │
          ┌──────────┐      ┌──────────┐          │
          │  loaded  │      │  failed  │──────────┤
          │          │      │ (rollback)│          │
          └─────┬────┘      └──────────┘          │
                │  in-flight?                     │
                ▼                                 │
          ┌──────────┐                            │
          │ draining │── all drained or timeout ──┤
          └─────┬────┘                            │
                │ atomic swap +                   │
                ▼ new heartbeat                   │
          ┌──────────┐                            │
          │   ready  │────────────────────────────┘
          └──────────┘
```

#### Rules

- **R-3.2.1** The runtime MUST maintain a single mutable
  reference `current_container` to the live model weights.
  Access MUST be via Swift actor isolation (e.g. an actor that
  exposes `currentContainer() -> ModelContainer` for snapshot
  reads and `swap(new: ModelContainer)` for atomic
  replacement). The refactor from immutable `let container` to
  isolated `var current_container` is REQUIRED.

- **R-3.2.2** Inference methods MUST snapshot `current_container`
  at request start. An in-flight request uses its snapshot
  reference for the request's full lifetime; an atomic swap
  during the request does NOT change which weights serve that
  request.

- **R-3.2.3** Runtime state values:
  - `ready` — `current_container` is the loaded model;
    inference proceeds normally; coordinator heartbeat carries
    `loading: false` (or omits the field for back-compat).
  - `loading` — an async load is in progress on a background
    task. `current_container` still references the OLD model;
    in-flight inference continues. NEW inference requests
    received by the binary's HTTP server MUST be rejected with
    HTTP 503 and OpenAI envelope
    `{error: {type: "service_unavailable", code:
    "provider_loading"}}`. Coordinator heartbeat carries
    `loading: true`.
  - `loaded` — internal-only transient: load succeeded, atomic
    swap pending drain. Not externally observable; collapses
    into `draining` immediately.
  - `draining` — new container exists; old container is the
    only one serving inference; binary waits for in-flight
    requests to complete (or drain timeout). NEW inference
    requests still rejected with `provider_loading`. Heartbeat
    still carries `loading: true`.
  - `failed` — internal-only transient: load failed; runtime
    keeps the OLD container as live; transitions to `ready`.
    Heartbeat reverts to `loading: false` with unchanged
    `model_id` and `model_hash`.

- **R-3.2.4** **Atomic swap.** Transition from `draining` to
  `ready` MUST atomically:
  1. Release the actor-isolated lock on `current_container`.
  2. Swap `current_container = new_container`.
  3. Update internal `current_model_id` and
     `current_model_hash` to match the new container.
  4. Mark state `ready` and signal heartbeat task to emit a
     new heartbeat with the new fields.

  The four sub-steps MUST be observable to the rest of the
  system as one atomic transition: no caller may see
  `current_container = new_container` AND
  `current_model_id = old_model_id` simultaneously.

- **R-3.2.5** **No-starve rule (C.4 outline-audit fix).** The
  async load task MUST run on a Swift task isolation distinct
  from:
  - The WebSocket receive loop
  - The WebSocket send loop (including heartbeat emission)
  - The HTTP inference server's accept loop

  Specifically: the heartbeat MUST continue to be emitted at
  the negotiated cadence (default 5-10s per SPEC-002 §7.1)
  throughout `loading` and `draining` states. Anchors to
  SPEC-002 §11 J.1 — the v1.1.6 35s heartbeat-miss kill
  incident was caused by long synchronous MLX work starving
  the heartbeat loop.

- **R-3.2.6** **Rollback on failure.** If the async load task
  fails (weights missing, OOM, MLX runtime error, etc.):
  - `current_container` MUST remain unchanged (still points
    to old weights).
  - State transitions `loading → failed → ready` synchronously.
  - Heartbeat MUST emit `loading: false` with the OLD
    `model_id` and OLD `model_hash` (i.e. a heartbeat
    semantically equivalent to one emitted before the swap
    attempt began).
  - CLI receives a typed `switch_progress` frame per
    R-3.1.5 with `state: "failed"` and a REQUIRED `reason`
    field, and exits code 5.
  - NO coordinator-side state change is observable from a
    failed swap (the heartbeat sequence is
    `..., loading: true, loading: true, ..., loading: false`
    with unchanged model — coordinator may have briefly
    marked the provider routing-ineligible, but no
    `operator_model_swap` event fires because the post-load
    heartbeat carries the same `model_id` as the pre-load
    heartbeat).

- **R-3.2.7** **Boot path unchanged.** The startup-time
  synchronous load (`--model X` at boot) populates
  `current_container` once and transitions directly to `ready`
  without going through `loading`. This preserves existing
  boot semantics and L-1 back-compat.

### 3.3 Heartbeat extension

The existing heartbeat
([provider.go:420-432](../phase4-coordinator/internal/pool/provider.go))
accepts `ModelID` changes but CLEARS `Provider.ModelHash` and
sets `HashStatus = HashStatusUncatalogued` on any change.
SPEC-011 v0.4 adds two heartbeat fields and REPLACES the
coordinator-side hash-clearing rule when the new field is
present.

#### New heartbeat fields (additive, optional, opt-in-gated)

```json
{
  "type": "heartbeat",
  ...
  "model_id": "mlx-community/Llama-3.1-8B-Instruct-4bit",
  "model_hash": "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f",
  "loading": false,
  ...
}
```

#### Rules

- **R-3.3.0** **Opt-in gating (A.1 round-1 CRITICAL fix).**
  The `model_hash` and `loading` heartbeat fields are emitted
  by the SPEC-011 binary ONLY when the operator started serve
  with `--enable-warm-swap=true` (per R-3.1.0). In disabled
  mode (default), the binary MUST omit these fields entirely
  from heartbeat frames. This preserves L-1's byte-identical
  default guarantee.

- **R-3.3.1** `model_hash: string`, when present, MUST be the
  provider's SHA-256 hash of the currently loaded weights as
  a **raw 64-character lowercase hex string** (no `sha256:`
  prefix). This matches SPEC-008 §5.3-5.6 wire format and
  current Swift output at
  [ModelRuntime.swift:294-325](../phase3-binary/Sources/macprovider-cli/ModelRuntime.swift)
  (`hexString(SHA256.hash(data: data))`). v0.2's prior
  `"sha256:" + hex` form is REMOVED per C.3 round-1 fix.
  Example: `"a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f"`.

- **R-3.3.2** `model_hash` MAY be absent. Absence indicates
  either:
  - Legacy provider (pre-SPEC-011 binary OR SPEC-011 binary
    with `--enable-warm-swap` disabled) — coordinator MUST
    apply existing `HashStatusUncatalogued`-clearing behavior
    per R-3.3.5 fallback clause.
  - SPEC-011-enabled provider that has not (re-)computed the
    hash for the current model (e.g. after `models switch`
    completed but binary hadn't yet recomputed).

- **R-3.3.3** `loading: bool` (default `false`), when present
  and `true`, signals the provider is in binary-local
  `loading` or `draining` state per §3.2. Coordinator MUST
  treat the provider as routing-ineligible until the next
  heartbeat with `loading: false`. The routing-ineligibility
  mechanism reuses the same path as existing non-`Ready`
  providers; NO new state in SPEC-002 §3 state machine.

- **R-3.3.4** Absence of `loading` field is wire-equivalent
  to `loading: false`. Legacy providers (no
  `loading` field) MUST be treated as routing-eligible per
  existing semantics.

- **R-3.3.5** **Coordinator hash re-verification trigger
  (REPLACES current behavior — D2.1 outline-audit fix).**
  When the coordinator receives a heartbeat where
  `heartbeat.model_id != Provider.ModelID`:
  - **If `heartbeat.model_hash` is PRESENT (SPEC-011 path):**
    1. Coordinator MUST update `Provider.ModelID` to the new
       value.
    2. Coordinator MUST update `Provider.ModelHash` to the
       new value (REPLACES current behavior of clearing
       it).
    3. Coordinator MUST run SPEC-008 §5.3-5.6 Pillar A
       re-verification against the new hash. Result populates
       `Provider.HashStatus` per SPEC-008 §5.5's five-state
       enumeration.
    4. If verification fails AND
       `tier2.require_hash_verified: true`, the provider's
       `HashStatus` reflects the failure state and the
       provider remains routing-ineligible per SPEC-008
       §5.6's existing predicate.
    5. Coordinator MUST emit `operator_model_swap` audit
       event per R-3.6 IF the prior heartbeat from this
       provider had `loading: true` (i.e. the coordinator
       observed the loading window).
  - **If `heartbeat.model_hash` is ABSENT (legacy path):**
    1. Coordinator MUST update `Provider.ModelID` to the new
       value (unchanged from current behavior).
    2. Coordinator MUST set `Provider.ModelHash = ""` and
       `Provider.HashStatus = HashStatusUncatalogued`
       (PRESERVED — current behavior at
       provider.go:420-432). This is the L-1 back-compat
       path for legacy providers.
    3. NO `operator_model_swap` event is emitted (no
       SPEC-011 evidence of an operator swap on the wire).

  This rule REPLACES the current heartbeat model-change
  behavior. SPEC-002 v1.3.5 candidate per §6.2 MUST encode
  this replacement normatively. Until SPEC-002 v1.3.5 lands,
  SPEC-011 v0.4 §3.3.5 IS the source of truth.

- **R-3.3.6** **No new WS message type.** The two new fields
  ride on the existing heartbeat frame. No protocol-level
  changes to message framing.

### 3.4 Drain semantics

- **R-3.4.1** When the runtime transitions `ready → loading`
  per R-3.2.3, the runtime MUST track the set of in-flight
  inference requests as of the transition timestamp. These
  requests continue on the OLD container per R-3.2.2 snapshot
  semantics.

- **R-3.4.2** **Drain timeout (B.2 round-1 fix — full
  envelope).** Configurable per provider via CLI flag
  `--swap-drain-timeout-seconds` (default 20s). After
  `drain_timeout_seconds` of being in `draining` state with
  in-flight requests still pending:
  - The runtime MUST cancel still-in-flight requests on the
    old container. Each cancelled request's caller receives
    the following HTTP 503 response (full SPEC-001 §6.0 /
    SPEC-010 v1.x §4.6.2 OpenAI error envelope shape):
    ```http
    HTTP/1.1 503 Service Unavailable
    Content-Type: application/json

    {
      "error": {
        "type": "service_unavailable",
        "code": "swap_drain_timeout",
        "message": "Inference cancelled by provider warm-swap drain timeout after <N>s. The provider is loading a new model; retry on a different provider or after the swap completes.",
        "param": null
      }
    }
    ```
  - The runtime MUST proceed to the atomic swap per R-3.2.4.

- **R-3.4.3** **Drain timeout is a per-request outcome ONLY.**
  Drain timeout MUST NOT fail the swap. The swap completes
  successfully (transitions to `ready` with the new model)
  after the drain window closes, regardless of how many
  requests were drain-timed-out. The runtime SHOULD log a
  metric for `drain_timed_out_count` to aid operator
  observability.

- **R-3.4.4** **Provider loading rejection (B.2 round-1 fix
  — full envelope).** While in `loading` or `draining` state,
  the binary's HTTP inference server MUST reject NEW requests
  with the following HTTP 503 response:
  ```http
  HTTP/1.1 503 Service Unavailable
  Retry-After: <estimated-load-remaining-seconds-or-30>
  Content-Type: application/json

  {
    "error": {
      "type": "service_unavailable",
      "code": "provider_loading",
      "message": "Provider is loading a new model and is temporarily unavailable. Retry after the indicated interval.",
      "param": null,
      "retry_after_seconds": <estimated-load-remaining-seconds-or-30>
    }
  }
  ```
  The coordinator-side `loading: true` heartbeat (R-3.3.3)
  typically prevents these requests from reaching the
  binary at all, but the binary MUST enforce its own gate.
  `retry_after_seconds` SHOULD be the binary's best estimate
  of remaining load time; if unknown, fall back to 30s.

### 3.5 SPEC-008 Pillar A re-verification (NORMATIVE)

- **R-3.5.1** During `loading` or `draining` state, the
  provider's heartbeat carries `loading: true` per R-3.3.3.
  Coordinator marks the provider routing-ineligible. SPEC-008
  §5.6 routing predicate is vacuously satisfied because the
  provider is not a routing candidate.

- **R-3.5.2** On post-swap heartbeat with new `model_id` +
  new `model_hash`, R-3.3.5 (SPEC-011 path) triggers SPEC-008
  §5.3-5.6 re-verification. The new `HashStatus` reflects the
  verification result per SPEC-008 §5.5's five-state
  enumeration. **No new `hash_status` value is introduced.**

- **R-3.5.3** Under `tier2.require_hash_verified: true`, a
  swap that completes with unverified hash MUST leave the
  provider routing-ineligible per SPEC-008 §5.6 existing
  predicate. The `operator_model_swap` audit event per R-3.6
  fires regardless of verification outcome; the
  `hash_verification_result` payload field records the
  outcome.

### 3.6 Audit-log event (NORMATIVE)

SPEC-011 v0.4 introduces ONE new audit event type. SPEC-002
v1.3.5 candidate per §6.2 adds this to the existing SPEC-002
§11 audit namespace.

#### Event: `operator_model_swap`

Emitted by the coordinator when (per R-3.3.5):
- A heartbeat arrives with `model_id != Provider.ModelID`
- AND `model_hash` is present
- AND the prior heartbeat from this provider had `loading:
  true` (i.e. the coordinator observed the loading window)

Payload schema:

```json
{
  "event": "operator_model_swap",
  "ts": "2026-06-06T14:23:09.123Z",
  "provider_assigned_id": "p_01HK4Z3VYE...",
  "from_model_id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
  "to_model_id": "mlx-community/Llama-3.1-8B-Instruct-4bit",
  "from_model_hash": "a3f1b2c8d4e5f6090807060504030201f0e1d2c3b4a5968778695a4b3c2d1e0f",
  "to_model_hash": "9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b7a6f5e4d3c2b1a0f9e8d",
  "loading_window_ms": 18243,
  "hash_verification_result": "hash_verified",
  "drain_inflight_count_estimate": 2
}
```

#### Rules

- **R-3.6.1** Required payload fields: `event`, `ts`,
  `provider_assigned_id`, `from_model_id`, `to_model_id`,
  `to_model_hash`, `loading_window_ms`,
  `hash_verification_result`.

- **R-3.6.2** Optional payload fields: `from_model_hash` (may
  be empty string or null if the prior `model_hash` was not
  recorded), `drain_inflight_count_estimate` (may be omitted;
  this is observability-only).

- **R-3.6.3** `loading_window_ms` MUST be calculated as the
  wall-clock duration from the FIRST observed `loading:
  true` heartbeat to the FIRST observed `loading: false`
  heartbeat with the new `model_id`. Coordinator clock; not
  provider-reported.

- **R-3.6.4** `hash_verification_result` MUST be one of
  SPEC-008 §5.5's five states: `"hash_verified"`,
  `"hash_mismatch"`, `"hash_invalid"`, `"uncatalogued"`,
  `"catalog_unavailable"`. (No sixth state.)

- **R-3.6.5** **L-6 F-1.5 invariants.** The payload MUST NOT
  include `conv:`, raw `account_id`, sticky session
  identifiers, buyer prompt text, or any input that could
  feed sticky derivation. Verified at v0.2 audit by grep.

- **R-3.6.6** **Conditional emission (C.2.2 outline-audit
  decision).** The event fires ONLY when the coordinator
  observed the `loading: true → loading: false` transition
  on a connected WS session. If the WS dropped during the
  loading window (per §3.8) and reconnected after the swap
  completed, the post-reconnect heartbeat carries the new
  model + hash WITHOUT a preceding `loading: true` from the
  current session, so NO `operator_model_swap` event fires.
  This is a documented observation-only audit invariant.
  Operators who require complete swap audit history MUST
  keep WS sessions alive during swaps (typical: load takes
  20-30s; WS sessions are persistent and rarely drop on
  that scale).

### 3.7 Concurrent operator-pushed switch (NORMATIVE)

- **R-3.7.1** When the runtime receives a `switch_request` via
  the control socket (R-3.1.5) while in `loading` or
  `draining` state for a prior switch (target Y):
  - Runtime MUST reply with `{type: "switch_ack",
    accepted: false, reason: "loading_in_progress",
    current_target: "Y"}`.
  - Runtime MUST NOT start a second async load.
  - The in-flight load to Y proceeds to completion or failure
    normally.
  - The CLI exits code 3 per R-3.1.2 step 4.

- **R-3.7.2** The runtime MUST NOT queue the rejected switch.
  If the operator still wants the second switch after the
  first completes, they MUST reissue `macprovider-cli models
  switch X`.

- **R-3.7.3** When the runtime is in `ready` state but the
  CLI-side cooldown guard (R-3.1.4) hasn't elapsed: the
  runtime MAY also report cooldown via a typed `switch_ack`
  frame per R-3.1.5 with `accepted: false`, `reason:
  "cooldown"`, `seconds_remaining: N` (REQUIRED `type:
  "switch_ack"` field per R-3.1.5 schema). If the CLI uses
  `--force`, it skips its own cooldown check and the
  runtime SHOULD accept (no runtime-side cooldown enforced
  per L-7).

### 3.8 WS drop mid-load (NORMATIVE)

If the WebSocket connection to the coordinator drops while the
provider is in `loading` or `draining` state:

- **R-3.8.1** Provider MUST finish the local load (do NOT
  abort). The state machine continues per §3.2 regardless of
  WS state.

- **R-3.8.2** Provider MUST attempt WS reconnection per
  existing SPEC-002 reconnection rules. Reconnection runs in
  parallel with the ongoing load.

- **R-3.8.3** **Reconnect uses `hello` (C2.1 outline-audit
  fix + C.2 round-1 fix — citation correction).** Per locked
  SPEC-001 §6.5 / SPEC-002 §7.1, provider reconnect is a
  fresh WS open followed by `hello`, `hello_ack`, then
  heartbeats. The reconnect `hello` carries the CURRENT
  runtime model state:
  - If load completed (success or failure) before reconnect:
    `hello.model_id` = final loaded model;
    `hello.model_hash` = final loaded model's hash (if
    available).
  - If load still in progress at reconnect: `hello.model_id`
    = old model (still warm in old container); the first
    post-reconnect heartbeat carries `loading: true` to
    signal the in-flight state.

  **Source-of-truth note on `hello.model_hash` (C.2 round-1
  fix).** Locked SPEC-001 §6.5 and SPEC-002 §7.1 do NOT
  document a `model_hash` field on `hello`. The field exists
  in:
  - Current Go code: `Hello` struct in
    [phase4-coordinator/internal/ws/messages.go:8-15](../phase4-coordinator/internal/ws/messages.go)
    includes `ModelHash string`.
  - Current Swift code: `helloMessage` in
    [phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:675-697](../phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift)
    emits `model_hash` when present.
  - SPEC-008 §5.4 contains a SPEC-001 v1.3 CANDIDATE
    annotation for the `hello.model_hash` field; the
    annotation is not yet locked into SPEC-001.

  SPEC-011 v0.3 cites those code + candidate sources as the
  source of truth for `hello.model_hash` rather than locked
  SPEC-001 §6.5. If SPEC-001 v1.3 lands with a normative
  `hello.model_hash` definition, SPEC-011 v0.3 R-3.8.3
  becomes a cross-reference; if not, R-3.8.3 documents the
  code reality. Same pattern as SPEC-010 v1.2 §3.1.A for
  the v2 `auth_request` flow.

  SPEC-011 v0.3 does NOT extend `hello` with new fields.
  `loading: bool` and `model_hash` per §3.3 are HEARTBEAT
  fields. `hello` carries pre-existing fields only.

- **R-3.8.4** **Conditional `operator_model_swap` emission
  (R-3.6.6 + C2.2 decision).** The coordinator-side rule
  per R-3.3.5 fires `operator_model_swap` IF the prior
  heartbeat (i.e. the immediately preceding heartbeat on
  the current session) had `loading: true`. WS-drop-mid-load
  effects:
  - Reconnect after load completed: coordinator's prior
    heartbeat from this provider (on the old session) is
    gone from session state. The first heartbeat on the new
    session arrives with the new `model_id` and `loading:
    false`. NO `operator_model_swap` event is emitted. This
    is the C2.2 observation-only invariant.
  - Reconnect during load: first post-reconnect heartbeat
    has `loading: true` with the OLD `model_id`. Subsequent
    `loading: false` heartbeat with the NEW `model_id`
    triggers `operator_model_swap` normally per R-3.3.5.

- **R-3.8.5** The provider's reconnect behavior MUST NOT
  start a NEW load. The in-flight load continues
  uninterrupted by the WS drop.

### 3.9 Config additions

Provider binary `serve` subcommand gains the following flags
(all gated on `--enable-warm-swap` per R-3.1.0; if
`--enable-warm-swap` is not present, the other flags are
parsed but have no behavioral effect):

```
--enable-warm-swap                   (bool, default false)
                                     Opt-in for the SPEC-011
                                     normative surface per
                                     R-3.1.0. When absent,
                                     L-1 byte-identical
                                     default behavior is
                                     preserved.

--swap-drain-timeout-seconds <int>   default 20
                                     Drain timeout per R-3.4.2.
                                     Range: 5 ≤ N ≤ 600 per
                                     R-3.9.1.

--ctl-socket-path <path>             default $TMPDIR/macprovider-cli/ctl.sock
                                     Control socket location
                                     per R-3.1.5 (macOS-native
                                     default; see R-3.9.2 for
                                     the prohibited-defaults
                                     rule).

--switch-state-path <path>           default $HOME/Library/Application Support/macprovider-cli/last-switch.ts
                                     CLI cooldown state file
                                     per R-3.1.4.
```

No coordinator-side config additions (per L-7).

- **R-3.9.1** `--swap-drain-timeout-seconds` MUST be ≥ 5s
  (avoid surprisingly-short drains) and ≤ 600s (avoid
  effectively-unbounded drains that defeat the swap
  mechanism). Out-of-range values cause `serve` to exit
  code 2 with stderr diagnostic at startup.

- **R-3.9.2** **No `$XDG_RUNTIME_DIR` references (R2-B2.1
  round-2 fix).** SPEC-011 v0.4 and all subsequent versions
  MUST NOT advertise `$XDG_RUNTIME_DIR` as a default path
  anywhere — control socket, state file, lock file, log
  file, anywhere. `$XDG_RUNTIME_DIR` is a Linux/freedesktop
  convention not set on stock macOS (empirically verified:
  unset on the target deployment platform). SPEC-011's
  default paths use macOS-native locations (`$TMPDIR` for
  transient, `$HOME/Library/Application Support/` for
  durable). AC-26 asserts this absence in spec text.

---

## 4. Backward compatibility

### 4.1 Legacy provider against SPEC-011 coordinator

A legacy provider (pre-SPEC-011 binary):
- Heartbeat lacks `model_hash` and `loading` fields.
- On `model_id` change (e.g. operator restarts with new
  `--model`): R-3.3.5 legacy path applies. Coordinator sets
  `Provider.ModelHash = ""` and `Provider.HashStatus =
  HashStatusUncatalogued`. UNCHANGED from current behavior.
- Coordinator never emits `operator_model_swap` for this
  provider (no `loading: true` ever observed). UNCHANGED.

### 4.2 SPEC-011 provider against legacy coordinator

A SPEC-011 binary connecting to a pre-SPEC-011 coordinator:
- Provider sends heartbeats with `loading` and `model_hash`
  fields. Legacy coordinator's `json.Unmarshal` ignores
  unknown fields by default (verify: no
  `DisallowUnknownFields()` in
  `phase4-coordinator/internal/ws/messages.go` heartbeat
  parsers).
- Provider's `models switch` works locally. Coordinator sees
  it as a regular `model_id` change and applies legacy
  `HashStatusUncatalogued`-clearing per existing behavior.
- No `operator_model_swap` event (legacy coordinator doesn't
  emit it).
- No regression: behavior is identical to today's
  "operator restarts with new --model" path.

### 4.3 What's visible at default config

- `/v1/models`: byte-identical. SPEC-011 doesn't touch.
- `/v1/status`: byte-identical (UNLESS the provider opted
  into SPEC-010 `publishes_supported_models: true`). SPEC-011
  itself adds nothing to `/v1/status`.
- `/v1/chat/completions`: behavior identical for
  warm-model requests. New behavior ONLY during a swap
  window:
  - Coordinator routes around the swapping provider (via the
    existing non-`Ready` exclusion).
  - If the swapping provider was the only one serving the
    requested model, buyer sees the existing
    no-eligible-provider error.
- New observable: `operator_model_swap` audit-log events on
  swaps that the coordinator observed.

### 4.4 What's NOT in SPEC-011 (deferred)

- Coordinator → provider `set_model` wire (SPEC-012)
- Demand-pull cold-wake (SPEC-012)
- Parked-request queue + bounds (SPEC-012)
- `/v1/models` aggregation of cold-supported models (SPEC-012)
- `/v1/status.state` enum field (SPEC-012)
- `model_not_warm` 503 envelope (SPEC-012)
- Recommended catalog (SPEC-012 / SPEC-013)

---

## 5. Acceptance criteria

20 ACs covering the surface above.

### CLI behavior (4 ACs)

- **AC-1** `macprovider-cli models list` with a running serve
  process outputs a table with the current loaded model
  marked `warm` and other HF-cached models marked `idle`.
  Exit code 0.

- **AC-2** `macprovider-cli models switch <X>` happy path:
  pre-flight validation passes (X is in
  `--supported-models`); CLI connects to serve via control
  socket; serve accepts; CLI streams progress events
  (`loading`, `draining`, `loaded`); CLI exits code 0.

- **AC-3** Pre-flight validation fail: invoking
  `macprovider-cli --model A --supported-models B,C models
  switch X` (where X is not in `[B, C]` and not equal to A
  since A is also not in [B, C] but that's a SPEC-010-side
  failure caught at serve startup). For the SPEC-011 case:
  if A is in `[A, B, C]` but operator switches to X not in
  the set, exit code 2 with stderr `"switch target X not in
  --supported-models"` BEFORE control-socket contact.

- **AC-4** `macprovider-cli models status` returns the
  current loaded model and runtime state. Exit code 0 if
  serve is running; exit code 4 if not.

### Async load + state machine (5 ACs)

- **AC-5** **Successful load end-to-end.** Provider starts in
  `ready` state with model A. Operator runs `models switch
  B`. Provider transitions `ready → loading → draining →
  ready` with B as the new loaded model. Throughout: existing
  in-flight requests on A continue on the old container per
  R-3.2.2 snapshot semantics. NEW requests received during
  `loading`/`draining` receive HTTP 503 `provider_loading`.

- **AC-6** **Failed load with rollback.** Provider in `ready`
  with A. Operator runs `models switch B`. Simulate load
  failure (e.g. inject OOM error). Provider transitions
  `ready → loading → failed → ready` with A still as the
  loaded model. `current_container` is unchanged. CLI exits
  code 5. Coordinator observes: heartbeat sequence
  `loading: false (A), loading: true (A), ..., loading:
  false (A)` — NO `model_id` change observed → NO
  `operator_model_swap` event emitted.

- **AC-7** **Drain timeout per-request 503.** Provider in
  `ready` with A; 2 in-flight inference requests on A.
  Operator runs `models switch B` with
  `--swap-drain-timeout-seconds=5`. Inject a long-running
  generation that exceeds 5s. After 5s in `draining`: the
  long-running request receives HTTP 503 with envelope
  `{error: {type: "service_unavailable", code:
  "swap_drain_timeout"}}`. Atomic swap proceeds. Provider
  transitions to `ready` with B.

- **AC-8** **Drain timeout does NOT fail the swap.** Same
  setup as AC-7. After the drain-timed-out request receives
  its 503, the swap MUST complete successfully (not fail).
  Provider's final state is `ready` with B as loaded model
  and B's hash reported. `operator_model_swap` event IS
  emitted per R-3.6.

- **AC-9** **Inference snapshot semantics.** Start an
  inference request on A that takes 30s. While it's
  running, run `models switch B` with
  `--swap-drain-timeout-seconds=60`. The 30s request MUST
  complete using the OLD container's weights (i.e. return
  A's output) even though the atomic swap fires at ~20s
  (load completes faster than drain timeout). After atomic
  swap, NEW requests get B's output.

### Heartbeat extension (3 ACs)

- **AC-10** **New `model_hash` field arrives at coordinator.**
  After a successful swap (AC-5), the post-swap heartbeat
  carries `model_id: B` AND `model_hash:
  <hash_of_B_raw_lowercase_hex>`. Coordinator sets `Provider.ModelID =
  B` and `Provider.ModelHash = <hash_of_B>` per R-3.3.5
  SPEC-011 path. **`Provider.ModelHash` is NOT cleared** —
  this is the REPLACEMENT of legacy behavior.

- **AC-11** **`loading: true` routing ineligibility.** During
  a swap, the coordinator receives a heartbeat with `loading:
  true`. Buyer requests for the (old or new) model that
  would otherwise route to this provider MUST NOT be
  dispatched to it. They route to another eligible provider
  OR receive the existing no-eligible-provider error.

- **AC-12** **No-starve.** Provider in `loading` state for
  30s. Heartbeats MUST be emitted at the negotiated cadence
  (default 5s) throughout. Coordinator MUST NOT close the
  provider for missing heartbeats during this window.
  Anchors to SPEC-002 §11 J.1.

### SPEC-008 Pillar A re-verification (2 ACs)

- **AC-13** **Successful re-verification.** Post-swap
  heartbeat carries new `model_hash` that matches the
  catalogued entry for B. Coordinator runs SPEC-008
  §5.3-5.6, sets `Provider.HashStatus = hash_verified`,
  marks provider routing-eligible for B.
  `operator_model_swap` event payload has
  `hash_verification_result: "hash_verified"`.

- **AC-14** **Unverified post-swap hash with
  `require_hash_verified: true`.** Same as AC-13 but
  `model_hash` does NOT match catalog (simulated). Under
  `tier2.require_hash_verified: true`, provider remains
  routing-ineligible for B. `operator_model_swap` event
  STILL fires with `hash_verification_result:
  "hash_mismatch"`.

### Concurrent switch (1 AC)

- **AC-15** **Second switch refused during in-flight load.**
  Provider in `ready` with A. Operator runs `models switch
  B` (CLI #1). While CLI #1 is showing `loading`, operator
  runs `models switch C` in a second terminal (CLI #2).
  CLI #2 exits code 3 with stderr `"provider is already
  loading B; refusing to start a second swap"`. Runtime
  does not start a second load; B load proceeds normally.

### WS drop mid-load (2 ACs)

- **AC-16** **Drop after load completes, before heartbeat.**
  Provider mid-swap: A → B, load just completed, atomic
  swap done, state `ready` with B. WS drops BEFORE first
  post-swap heartbeat reaches coordinator. Provider
  reconnects with `hello{model_id: B, model_hash:
  hash(B)}` per R-3.8.3. First post-reconnect heartbeat
  carries `loading: false`. Coordinator: NO
  `operator_model_swap` event (no preceding `loading: true`
  on the current session). C2.2 invariant verified.

- **AC-17** **Drop during load.** Provider in `loading`
  state (A → B). WS drops. Reconnect happens while load
  still in progress. Reconnect `hello{model_id: A}` (B not
  loaded yet). First post-reconnect heartbeat carries
  `loading: true`. After load completes: heartbeat
  carries `loading: false, model_id: B, model_hash:
  hash(B)`. Coordinator emits `operator_model_swap`
  normally (loading window WAS observed on current session).

### Backward compatibility (2 ACs)

- **AC-18** **L-1 BYTE-IDENTICAL default — `--enable-warm-swap`
  disabled (A.1 round-1 CRITICAL fix; R2-A2.2 round-2
  expansion).** Coordinator running SPEC-011 v0.4 code;
  provider running SPEC-011 v0.4 binary with `serve` invoked
  WITHOUT `--enable-warm-swap` (default disabled state per
  R-3.1.0). Compared to a pre-SPEC-011 baseline running on
  the same workload:

  **Heartbeat shape:**
  - Heartbeats from this provider MUST NOT include `loading`
    or `model_hash` fields. Field-by-field JSON shape
    comparison MUST be identical.
  - The byte-identical assertion is REAL byte-identical for
    heartbeat frames, not "additional fields are tolerated."

  **Control surface:**
  - No control socket opened at the default path. Test
    asserts: `stat $TMPDIR/macprovider-cli/ctl.sock` returns
    "no such file" while serve is running.
  - `macprovider-cli models list` MUST exit code 4 with
    stderr per R-3.1.5.x precedence rule (case 1: ENOENT →
    `"macprovider-cli serve is not running on this host
    (no control socket at ...)"`).

  **Coordinator-observable behavior:**
  - No `operator_model_swap` events emitted.
  - `Provider.ModelHash` populated from initial admission
    (per SPEC-008 Pillar A) and NOT cleared (because no
    `model_id` change occurred). UNCHANGED.

  **Public HTTP surface (R2-A2.2 round-2 expansion).**
  Direct comparison against pre-SPEC-011 baseline,
  excluding SPEC-010 opt-in differences from the oracle:
  - `GET /v1/status`: byte-identical JSON response.
  - `GET /v1/models`: byte-identical JSON response.
  - `POST /v1/chat/completions` with a representative
    inference request (3 messages, max_tokens=100): the
    HTTP response status, headers, JSON shape, and token
    counts MUST be byte-identical to the pre-SPEC-011
    baseline (modulo nondeterministic output text from
    sampling, which is excluded from the oracle by using
    `temperature: 0` and `seed: <fixed>`).

  **Log surface:**
  - Normalized-log comparison (per SPEC-010 v1.x AC-13
    pattern): no new SPEC-011 event names appear in legacy
    logs. The set/order of log event types, severity levels,
    and stable fields MUST be identical after stripping
    timestamps and request IDs.

- **AC-19** **Legacy provider (pre-SPEC-011 binary) against
  SPEC-011 coordinator.** Pre-SPEC-011 binary connects.
  Operator restarts the binary with a different `--model`.
  Heartbeat lacks `model_hash` and `loading` fields. Per
  R-3.3.5 legacy path: coordinator sets
  `Provider.ModelHash = ""` and
  `Provider.HashStatus = HashStatusUncatalogued`. UNCHANGED
  from current behavior. NO `operator_model_swap` event (no
  SPEC-011 evidence).

### Audit-log (1 AC)

- **AC-20** **`operator_model_swap` event payload (D.2
  round-1 fix — allowlist).** After AC-5 happy path swap,
  the coordinator's audit-log MUST contain exactly one
  `operator_model_swap` event. Assertions:
  - All R-3.6.1 required fields present:
    - `event = "operator_model_swap"`
    - `ts` is a valid ISO-8601 timestamp
    - `provider_assigned_id` matches the swapping provider
    - `from_model_id = A`
    - `to_model_id = B`
    - `to_model_hash` matches the post-swap reported hash
      (raw 64-char lowercase hex per R-3.3.1)
    - `loading_window_ms` is > 0
    - `hash_verification_result` is one of SPEC-008 §5.5's
      five values
  - **Positive allowlist (NEW in v0.3 per D.2 round-1 fix):**
    the payload object's top-level keys MUST be a subset of
    `{event, ts, provider_assigned_id, from_model_id,
    to_model_id, from_model_hash, to_model_hash,
    loading_window_ms, hash_verification_result,
    drain_inflight_count_estimate}`. Any other key present
    fails the AC.
  - **Negative checks (L-6 + R-3.6.5):** payload contains NO
    `conv:` substring, NO raw `account_id` field, NO sticky
    identifier (no `sticky_*` keys, no
    `account_id_hash`, no derived buyer tags), NO buyer
    prompt text. Fixtures planted with raw buyer tag,
    sticky header, prompt text MUST NOT appear under ANY
    key in the emitted event.

### Newly-covered rules (AC-21 through AC-25, D.1 round-1 fix)

- **AC-21** **R-3.1.3 `--force` flag scope.** With
  `--enable-warm-swap` enabled and CLI cooldown active (last
  switch 5s ago):
  - `models switch X --force` SHOULD succeed (cooldown
    bypassed).
  - `models switch <not-supported> --force` MUST still fail
    with exit code 2 (pre-flight validation per R-3.1.2
    step 2 is NOT suppressed by `--force`).

- **AC-22** **R-3.1.5 control socket frame parsing.** Send
  the following invalid frames to the control socket;
  serve MUST close the connection and log an error for each:
  - Frame missing `type` field
  - Frame with unknown `type: "frobnicate"`
  - Frame with `type: "switch_request"` but missing
    `target_model_id`
  Negative case: a frame with `type: "switch_request"` and
  all required fields present MUST succeed.

- **AC-23** **R-3.2.7 boot path stays non-loading (R2-G2.1
  round-2 fix — explicit test accessor).** Start serve with
  `--enable-warm-swap --model A`. Synchronous startup load
  completes; first heartbeat carries `loading: false` AND
  `model_hash: <hash_of_A>`. Runtime state is `ready`, NOT
  `loading`. State machine has NEVER transitioned through
  `loading`.

  **Test accessor (R2-G2.1 round-2 fix).** The
  implementation MUST expose a package-internal test
  accessor for the state-machine transition count, e.g.
  unexported `runtimeTransitionCount() -> int` in the
  binary's `ModelRuntime` package reachable from `_test.swift`
  files within the same module. Same pattern as SPEC-010
  v1.4 AC-18(d) for the coordinator's retention map. No
  production debug endpoint is required.

  Test assertion: `runtimeTransitionCount() == 0` after
  serve startup completes and emits its first heartbeat.

- **AC-24** **R-3.1.4 + R-3.7.3 runtime vs CLI cooldown
  distinction.** With CLI cooldown active (state file shows
  last switch 5s ago) but runtime NOT in loading state:
  - `models switch X` (no `--force`): CLI exits code 6
    (CLI-side cooldown rejection); runtime is never
    contacted.
  - `models switch X --force`: CLI bypasses its cooldown
    guard, contacts runtime; runtime accepts (no runtime-
    side cooldown enforced per L-7); swap proceeds.
  With CLI cooldown NOT active (state file shows last
  switch > 10s ago) AND runtime in `loading` state for
  prior switch Y:
  - `models switch X` (with or without `--force`): runtime
    rejects via a typed `switch_ack` frame per R-3.1.5
    with `accepted: false`, `reason: "loading_in_progress"`,
    `current_target: "Y"`; CLI exits code 3. `--force`
    does NOT bypass runtime-side rejection.

- **AC-25** **R-3.9.1 swap_drain_timeout range validation
  (R2-K2.1 round-2 editorial fix — unit label).** Start
  serve with:
  - `--swap-drain-timeout-seconds 3` (< 5s minimum): MUST
    exit code 2 with stderr indicating range violation.
  - `--swap-drain-timeout-seconds 601` (> 600 max): MUST
    exit code 2 with stderr indicating range violation.
  - `--swap-drain-timeout-seconds 30` (in range): MUST
    start normally.
  - `--swap-drain-timeout-seconds 5` (lower bound): MUST
    start normally.
  - `--swap-drain-timeout-seconds 600` (upper bound): MUST
    start normally.

### Spec-text hygiene (1 AC, added in v0.4 per R2-B2.1)

- **AC-26** **No `$XDG_RUNTIME_DIR` in advertised defaults
  (R2-B2.1 round-2 supporting fix; B3.1 round-3 wording
  fix).** This AC prevents regression of the C.1 / R2-B2.1
  macOS platform-path fix across future revisions.
  Structural assertions (NOT a literal-substring grep —
  that approach fails because the spec must NAME the
  forbidden token in its own prohibition rule and AC):

  1. **§3.9 config block** MUST NOT advertise
     `$XDG_RUNTIME_DIR` as a default value for any flag.
     Test: parse the §3.9 config-additions code block;
     assert no `default <whatever>` line contains the
     substring `XDG_RUNTIME_DIR`.
  2. **Any wire example in §3.1, §3.4, §3.6, §3.8** MUST
     NOT contain `$XDG_RUNTIME_DIR` as a value. Test:
     scan code blocks in those sections; assert no JSON
     field value contains `XDG_RUNTIME_DIR`.
  3. **No `R-3.x.x` rule body outside R-3.9.2** MUST cite
     `$XDG_RUNTIME_DIR` as a recommended default path
     (the token MAY appear as a forbidden-rationale
     reference, e.g. R-3.1.5's "Why not `$XDG_RUNTIME_DIR`"
     paragraph). Test: parse R-rule bodies; allow the
     token only when it appears with prohibition wording
     (`MUST NOT`, `forbidden`, `not set on macOS`,
     `removed`, etc.).

  Allowed locations for the literal token (these are the
  ONLY places it appears in v0.5 spec text):
  - Change-log entries describing the v0.3 removal or v0.4
    R-3.9.2 prohibition
  - R-3.1.5 "Why not `$XDG_RUNTIME_DIR`" rationale
    paragraph
  - R-3.9.2 prohibition rule body (which must NAME the
    forbidden token to forbid it)
  - This AC-26 body (which must NAME the forbidden token
    to assert its absence)

  Verification: a fresh-eyes reviewer can run `grep -n
  '\$XDG_RUNTIME_DIR'
  specs/SPEC-011-operator-pushed-warm-swap.md` and confirm
  every match falls in one of the four allowed locations
  above. As of v0.5, expected match count is in those
  4 sections only.

Total: 26 ACs (20 from v0.2 + 5 added in v0.3 per D.1
round-1 fix + 1 added in v0.4 per R2-B2.1 round-2 fix).

---

## 6. Companion-spec annotations (vNEXT candidates)

These are NOT modifications to locked specs. They describe what
SPEC-001 v1.3 and SPEC-002 v1.3.5 would need to add to fully
house SPEC-011 v0.4.

### 6.1 SPEC-001 v1.3 candidate (provider binary)

SPEC-001 v1.3's BUILD prompt MUST cite SPEC-011 v0.x locked §3.1,
§3.2, §3.4, §3.5, §3.7, §3.8, §3.9 as the binding source-of-
truth for binary-side changes. Concretely:

**Note on SPEC-001 §6 numbering (E.2 round-1 fix).** SPEC-001
v1.2.4's §6 currently has §6.0 through §6.6 occupied. SPEC-011
candidate sections MUST use §6.7 and onwards, not the already-
locked §6.6 (Inference message types — WS-tunneled mode).

- **§6.2 (CLI)**: gain `models` subcommand with `list`,
  `switch`, `status` actions per §3.1. Gain `--force` flag
  per R-3.1.3. Gain `--enable-warm-swap`,
  `--swap-drain-timeout-seconds`, `--ctl-socket-path`,
  `--switch-state-path` flags on `serve` per §3.1 and §3.9.
- **NEW §6.7 (warm-swap opt-in gate and runtime state
  machine)**: document the R-3.1.0 opt-in gate, the
  binary-side state machine per §3.2
  (`ready / loading / draining / failed`), atomic swap
  contract per R-3.2.4, no-starve rule per R-3.2.5, rollback
  semantics per R-3.2.6. This requires a Swift `ModelRuntime`
  refactor from immutable `let` fields to actor-isolated
  mutable state.
- **NEW §6.8 (control socket protocol)**: document the
  R-3.1.5 control-socket message types and JSON shapes
  (`type`-required per B.1 round-1 fix). macOS default path
  per C.1 round-1 fix.
- **NEW §6.9 (heartbeat extension — additive when opt-in
  enabled)**: gain optional `model_hash` (raw lowercase
  64-char hex per R-3.3.1) and `loading: bool` heartbeat
  fields per §3.3. Fields are emitted ONLY when
  `--enable-warm-swap` is enabled per R-3.3.0.
- **NEW §6.10 (concurrent switch + WS drop)**: document the
  §3.7 concurrent-switch policy and §3.8 WS drop reconnect
  behavior. WS drop reconnect uses `hello` per §3.8.3 with
  the C.2 round-1 fixed source-of-truth note on
  `hello.model_hash`.

### 6.2 SPEC-002 v1.3.5 candidate (coordinator) — additive AND replacement edits

SPEC-002 v1.3.5's BUILD prompt MUST cite SPEC-011 v0.4 §3.3,
§3.6 as the binding source-of-truth. **This candidate
includes one REPLACEMENT of locked behavior — see D2.1 fix
below.**

#### Additive surface

- §7.1 (provider WebSocket protocol / heartbeat): gain
  optional `model_hash` and `loading: bool` heartbeat fields
  per §3.3.
- §11 (audit-log): gain `operator_model_swap` event type with
  payload schema per §3.6.
- §3 provider state machine: NO change. SPEC-011 introduces
  no new coordinator-side state machine states.
- §5 routing: NO behavior change beyond existing non-`Ready`
  exclusion (which `loading: true` heartbeat triggers via
  the same path).

#### REPLACEMENT edit (D2.1 outline-audit fix)

SPEC-011's R-3.3.5 SPEC-011 path REPLACES the current
behavior at
[provider.go:420-432](../phase4-coordinator/internal/pool/provider.go)
where `ApplyHeartbeat` clears `ModelHash` and sets
`HashStatusUncatalogued` on any `ModelID` change. Under
SPEC-011, this clearing behavior MUST be retained ONLY for
the legacy path (heartbeat has no `model_hash` field). When
the heartbeat carries `model_hash`, the coordinator MUST:
1. Update `Provider.ModelHash` to the new value (NOT clear).
2. Run SPEC-008 §5.3-5.6 Pillar A re-verification.
3. Populate `Provider.HashStatus` from verification result.
4. Emit `operator_model_swap` audit event IF prior heartbeat
   on the current session had `loading: true`.

SPEC-002 v1.3.5 candidate MUST normatively document this
two-path behavior (legacy clear vs SPEC-011 re-verify).
This is the **D2.1 outline-audit fix**: the replacement was
not explicitly flagged in v0.1.1, leading to risk that
implementers would update the heartbeat struct but miss the
state-transition replacement. v0.2 flags it here unmissably.

### 6.3 SPEC-008 v0.3 interaction (no normative edit needed)

SPEC-011 v0.4 reuses SPEC-008 §5.3-5.6 Pillar A pipeline as
the verification path for post-swap hashes. No SPEC-008
normative edit required. The five-state hash enumeration in
§5.5 is preserved; SPEC-011 introduces no sixth state.

The interaction surface is purely:
- Provider reports new `model_hash` on heartbeat.
- Coordinator runs existing Pillar A verification.
- Result is one of SPEC-008's five existing states.
- Routing predicate per §5.6 applies normally.

### 6.4 SPEC-005 interaction (E.1 round-1 fix — narrowed claim)

**SPEC-011 introduces no new billing or ledger semantics and
no new provider/operator credit path.** Operator-pushed swaps
are not billable inference attempts (L-5).

The 503 outcomes that SPEC-011 introduces
(`provider_loading` and `swap_drain_timeout` per R-3.4.2 /
R-3.4.4) remain subject to SPEC-005 existing
`request_log` semantics for terminal 503 attempts:
- A 503 emitted by the binary (`provider_loading`) reaches
  the coordinator's request-handling path the same way any
  503 reaches it today; SPEC-005's existing rules for
  logging provider-attempted-but-unsuccessful requests
  apply unchanged.
- A 503 emitted by the binary mid-stream
  (`swap_drain_timeout`) similarly follows existing 503
  handling for in-flight cancellation.
- SPEC-011 does NOT add new `request_log` columns, does NOT
  change SPEC-005 settlement ledger row counts, and does
  NOT alter the buyer-debit or provider-credit hot path.

v0.2 incorrectly stated "SPEC-011 does not touch
`request_log`." The accurate statement (per E.1 round-1
fix): SPEC-011 inherits existing `request_log` behavior for
503 outcomes; SPEC-005 remains the authoritative source for
how those rows are written.

### 6.5 SPEC-004 interaction (none in normative behavior)

SPEC-004's dispatch and sticky-affinity rules are unaffected.
A provider with `loading: true` heartbeat is excluded from
candidates via the existing non-`Ready` exclusion path; no
new SPEC-004 predicate is introduced.

### 6.6 SPEC-010 v1.x interaction (REQUIRED dependency)

SPEC-011 R-3.1.2 step 2 depends on SPEC-010 R-3.6.3
(binary-local pre-flight validation that target is in
`supported_models`) and the underlying SPEC-010 R-3.1.4
wire containment invariant.

If SPEC-010 v1.x is NOT deployed:
- The CLI's R-3.1.2 step 2 pre-flight check has no
  `supported_models` set to validate against; it falls back
  to "any model_id the operator passes is accepted."
- Coordinator-side: legacy admission with single `model_id`
  means the operator-swap surface still works
  mechanically, but there's no declared willingness check.
- Recommendation: SPEC-010 v1.x and SPEC-011 v0.4 ship
  together. SPEC-011 v0.4 BUILD prompt MUST gate on SPEC-010
  v1.x being locked.

---

## 7. Open questions

Resolved in v0.2 (outline-audit round-2 decisions):

- **OQ-old-Q2 (Q.2 outline)** Concurrent switch policy:
  resolved in §3.7 — deterministic local rejection, exit
  code 3, no queueing.
- **OQ-old-Q3 (Q.3 outline)** WS drop mid-load: resolved in
  §3.8 — finish local load, reconnect with `hello` per
  locked SPEC-001/SPEC-002, conditional event emission per
  R-3.6.6 / R-3.8.4.
- **OQ-old-C2.2 (C2.2 outline)** Conditional
  `operator_model_swap` audit gap: resolved in R-3.6.6 —
  acceptable observation-only invariant, no backfill. Op
  documentation note: keep WS sessions alive during swaps
  for complete audit history.

Open for v0.5 (if pursued):

- **OQ-1** Control-socket signaling: v0.4 picks Unix domain
  socket at `$TMPDIR/macprovider-cli/ctl.sock` (macOS-native
  per R-3.1.5). If a future cross-platform target (Linux
  servers, containers) needs a different transport, v0.5
  may add a localhost HTTP alternative or a platform-
  conditional default.
- **OQ-2** CLI block-vs-detach: v0.4 picks block-with-stderr-
  progress. v0.5 may add `--detach` for CI fire-and-forget
  if demand surfaces.
- **OQ-3** Audit-backfill for WS-drop-mid-load completed
  swaps: v0.4 explicitly decides "no backfill, observation-
  only." If operators report this gap as painful in
  practice, v0.5 may add a binary-side "swap-completed-while-
  disconnected" signal that the provider emits on reconnect.
- **OQ-4** Heartbeat `loading_target` field: v0.4 keeps
  `loading: bool` only (no target). v0.5 may add
  `loading_target: string` if operator dashboards demand
  "loading X" vs "loading" granularity.

---

## 8. Out of scope (with successor specs)

| Feature | Successor | Why deferred |
|---|---|---|
| Coordinator → provider `set_model` wire | SPEC-012 | Demand-pull concern; needs cold-wake queue + cooldown design |
| Coordinator-initiated demand-pull on buyer request | SPEC-012 | Pulls in parked queue, ETA budget, routing changes |
| Buyer-facing `/v1/models` aggregation with `warm: bool` | SPEC-012 | Requires SPEC-008 v0.4 normative edit to §5.7 hash block |
| `/v1/status.state` field with `loading` / `ready` / `down` | SPEC-012 | Operator-dashboard concern; only meaningful when coordinator-side swap state exists (SPEC-012's `SwapState`) |
| `503 model_not_warm` error envelope | SPEC-012 | Only meaningful when buyers see cold-supported models |
| Recommended catalog (`GET /v1/recommended-catalog`) | SPEC-013 (future) | Closes pain #4 (HF ID discovery) |
| Multi-model serving in a single provider process | (none planned) | Architectural; L-3 |

---

## 9. References

- [SPEC-010 v1.x](SPEC-010-model-catalog.md) (capability
  foundation; R-3.6.3, R-3.1.4 are SPEC-011 dependencies)
- [SPEC-011 v0.1 / v0.1.1 outline](../docs/) (preserved in
  git history; archived)
- [SPEC-011 outline audit history](SPEC-011-outline-audit.md)
  rounds 1-2 — drove the v0.2 normative shape
- [SPEC-012 source draft](SPEC-012-source.md) — wide-scope
  predecessor; SPEC-011 + SPEC-012 split is documented in
  SPEC-010 v1.x history
- [SPEC-001 v1.2.4](SPEC-001-phase3-binary.md) — provider
  binary (SPEC-011 drives v1.2.5 candidate per §6.1)
- [SPEC-002 v1.3.4](SPEC-002-coordinator.md) — coordinator
  (SPEC-011 drives v1.3.5 candidate per §6.2 with one
  REPLACEMENT edit)
- [SPEC-008 v0.3](SPEC-008-tier2.md) §5.3-5.6 Pillar A
  pipeline (SPEC-011 R-3.3.5 / R-3.5 reuse path)
- [SPEC-006 v0.8.1](SPEC-006-buyer-api.md) §F-1.5
  survivability invariants (cited in L-6 and R-3.6.5)
- [phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift](../phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift)
  lines 7-15 (existing CLI structure)
- [phase3-binary/Sources/macprovider-cli/ModelRuntime.swift](../phase3-binary/Sources/macprovider-cli/ModelRuntime.swift)
  lines 25-68, 86-147 (immutable runtime — §3.2 refactor
  target)
- [phase4-coordinator/internal/pool/provider.go](../phase4-coordinator/internal/pool/provider.go)
  lines 420-432 (heartbeat handler — R-3.3.5 REPLACES this)
- arm64golf canary run, 2026-06-05 (trigger)
- Decision-log Entry 21 (no premium positioning), Entry 35
  (SPEC-004 Pillar B dispatch-rewrite)
