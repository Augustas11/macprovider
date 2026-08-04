# Shared context — SPEC-038 continuous-batching scaffold BUILD audit

Worktree: the isolated SPEC-038 scaffold worktree.
Branch: `feature/232-continuous-batching` (one commit `709efbb5` ahead of `origin/main`).

## How to read the change under audit
Run exactly:
```
git diff origin/main...HEAD
```
That range IS the entire change you are auditing. Read the full files it touches
for context, and read the normative spec:
`specs/SPEC-038-continuous-batching.md`
(authority domain `continuous-batching-serving`, requirements `SPEC-038-R001..R016`).

## What this change IS (audit against THIS intent — do not fault it for being this)
This is the **integration-surface-only scaffold** for SPEC-038 continuous batching.
It deliberately wires NO batch engine and runs NO shared forward. The pinned
dependency `mlx-swift-lm` 3.31.4 ships no reviewed batch API (upstream PR #263
pending), so `ContinuousBatchingPolicy.reviewedUpstreamBatchRevision` is
intentionally `nil` and strict `on` mode is designed to fail closed.

Concretely the scaffold adds:
- A default-OFF operator knob `continuous_batching: off | canary | on`
  (config key / `MACPROVIDER_CONTINUOUS_BATCHING` env / `--continuous-batching`
  CLI) plus a bounded `continuous_batch_queue_limit`.
- `ContinuousBatchingPolicy` — a pure policy layer computing a capability and:
  - `off` (default): serial path, fully inert.
  - `on` (strict): fails preflight with a named reason
    (`continuous_batching_unavailable` / `..._unsupported_kv_bits` /
    `draft_model_capacity_shortfall`) because no engine is pinned.
  - `canary` (permissive): serial-routes and emits an observable
    `event=continuous_batching_unsupported action=serial_routed reason=...`
    telemetry line. Never a silent downgrade.
- `ModelRuntime` wiring that threads the mode/queue-limit and calls the policy
  at preflight / non-streaming / streaming entry points.
- An MSB aggregate-throughput helper that computes total decoded tokens over a
  common wall-clock interval (never a sum of per-request durations).
- Unit tests for config precedence, strict rejection, permissive routing,
  draft exclusion, queue-limit validation, runtime threading, MSB math.

## DO NOT FLAG THESE (intended and correct)
- "No batch engine / no shared forward is implemented." Intentional and correct
  for a scaffold; SPEC §1 and the mode matrix (§5) require flag-off byte-parity
  and gate the real engine behind FR-CB10/FR-CB15. Absence of an engine is not a
  defect here.
- "`reviewedUpstreamBatchRevision` is nil." Intentional — there is no reviewed
  upstream pin yet; strict `on` must fail closed until one exists (FR-CB10).
- Pre-existing Swift-6 `Sendable` warnings in files this diff does not touch.

## Severity bar
Report findings as CRITICAL / HIGH / MEDIUM / LOW / INFO. Convergence bar is
0 CRITICAL / 0 HIGH / 0 MEDIUM. For each finding give: severity, file:line,
the concrete problem, why it matters, and a specific fix. If you find nothing at
a severity, say so explicitly. Do not invent findings to fill the report; a
clean scaffold legitimately converges at 0/0/0. Anchor every claim to a real
line in the diff — no speculative "could in a future engine" findings unless the
scaffold code itself is wrong today.
