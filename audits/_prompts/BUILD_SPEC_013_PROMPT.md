# Build prompt — SPEC-013 v0.3 (`macprovider-cli autotune` subcommand)

Operator-paste prompt to start the SPEC-013 v0.3 build. This wraps
SPEC-013 v0.3 § 0's operator-paste invocation block with the
self-contained context a fresh Codex CLI session needs.

Paste everything between the markers into a fresh **Codex CLI session**
rooted at `/Users/augstar/macprovider-poc`. The agent will read the
spec, add a new `autotune` subcommand to the existing
`phase3-binary/` Swift package, and build incrementally per the
step sequence below. Expected wall-clock: 1–2 weeks of session work
(the spec is one new subcommand inside an existing binary, not a
whole new binary), with operator checkpoints at T+15 min and T+1 h
on day 1.

---

```
=== BEGIN PROMPT ===

You are implementing SPEC-013 v0.3 — the `macprovider-cli
autotune` subcommand. SPEC-013 is at
/Users/augstar/macprovider-poc/specs/SPEC-013-cli-autotune.md and
has been through 3 codex audit rounds (full audit history at
/Users/augstar/macprovider-poc/specs/SPEC-013-audit.md;
round-3 LOCK verdict). It is build-ready. Your output is working
code, NOT spec revisions.

## Wrapper directive (from SPEC-013 § 0, verbatim)

"Implement SPEC-013. As you work, maintain a running
phase3-binary/implementation-notes.html that captures anything I
should know about how the implementation diverges from or interprets
the spec:

- Design decisions: choices made where the spec was ambiguous
- Deviations: places where you intentionally departed from the spec, and why
- Tradeoffs: alternatives considered and why you picked what you did
- Open questions: anything you'd want me to confirm or revise"

This directive is operative throughout the build. Update
implementation-notes.html as you go, not just at the end. The
operator reads it asynchronously to catch divergence early. The
file already exists (created during the SPEC-001 build); append
new sections per-spec like "SPEC-013 design decisions",
"SPEC-013 deviations", etc.

## Implementation choice (PICKED here — SPEC-013 § 10 left this open)

The BUILD prompt picks **Option A: Swift-native subcommand inside
`macprovider-cli`**, not Option B (Python wrapper). Rationale:

- The rest of the binary is Swift; adding a Python runtime to the
  operator install pipeline contradicts SPEC-003 v0.9.2's
  single-binary install promise.
- Drain semantics, atomic config writes, and SIGINT/SIGTERM
  handling all match the patterns already shipped in
  `UninstallCommand.swift` / `SelfUpdate.swift`.
- Future SPEC-011 warm-swap integration (§11 v2 deferral) needs
  Swift-native; Option B paints us into a corner.
- The PR #103 prototype (`beta/autotune.py`) on the
  `spike/provider-model-autotune` branch is the reference for the
  algorithm shape and the schemas — Option A re-implements the
  loop in Swift but reuses the `tune_trials` schema verbatim and
  the `_is_new_best` decision rule verbatim.

If during build you find Option A genuinely blocks something, STOP
and write an Open Question. Do NOT silently pivot to Option B
without operator approval.

## Required reading (in order, fully — do not skim)

1. /Users/augstar/macprovider-poc/specs/SPEC-013-cli-autotune.md
   v0.3 — your specification. The whole document is in scope.
   Particular attention:
   - § 3 architecture (two-stage pipeline + provider-lifecycle
     invariant)
   - § 5.1 FR-A (Stage 1 — STOP-on-first-feasible)
   - § 5.2 FR-B (Stage 2 — knob hill-climb + `_is_new_best`)
   - § 5.4 FR-D (pre-warm contract — pick Shape A or Shape B per
     the implementer's discretion; both are permitted)
   - § 5.5 FR-E (provider-conflict pre-flight + `--no-join`)
   - § 5.6 FR-F (recommendation surface + JSON schema +
     recipe_hash JCS + `--apply`)
   - § 5.7 FR-G (`tune_trials` + `tune_runs` SQLite schema +
     migration)
   - § 8 acceptance criteria (AC-1 through AC-19 — these drive
     your test suite)

2. /Users/augstar/macprovider-poc/specs/SPEC-013-audit.md —
   the audit history (3 rounds). NOT required line-by-line; skim
   for shape. Useful for understanding why certain wordings
   exist (e.g. round-2 N-D.1 closure explains why NFR-4 names
   both Shape A and Shape B).

3. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   — the binary's normative surface. Pay attention to:
   - The existing `serve` flag set (PR #105 added `--kv-bits`,
     `--max-context`, `--max-batch` which autotune wraps)
   - The launchd label `live.streamvc.macprovider` (FR-E.1)
   - The config YAML key names (FR-F.3 owns
     `model`, `kv_bits`, `max_context_override`,
     `max_concurrency_override`)

4. /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md
   v0.9.2 § FR-C5 — launchd interaction details for the
   `--drain` path.

5. The PR #103 prototype on the `spike/provider-model-autotune`
   branch — `beta/autotune.py`. READ-ONLY reference for the
   algorithm, signal handling pattern, `_is_new_best` semantics,
   and `tune_trials` schema. Do NOT port the Python verbatim;
   the Swift implementation re-implements with native types.
   To read without checking out the branch:
   `git show origin/spike/provider-model-autotune:beta/autotune.py | less`

6. Existing Swift files you will touch or reference:
   - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
     — the top-level CLI structure; you ADD an `AutotuneCommand`
     subcommand.
   - `phase3-binary/Sources/MacProviderCore/Config.swift` —
     YAML config parser; `--apply` calls into here.
   - `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
     — HF cache + online-fallback path (relevant for FR-D Shape
     B implementation).
   - `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift`
     and `UninstallCommand.swift` — patterns for launchd
     `bootout/bootstrap` calls; reuse the
     `runProcess("/bin/launchctl", ...)` helper shape.

## Build environment

You are running on macOS Apple Silicon. The operator has the
Swift toolchain available (Xcode 15+; `xcrun swift --version`
returns 5.9+). The `phase3-binary/` Swift Package Manager project
already exists; you ADD a new `Sources/macprovider-cli/AutotuneCommand.swift`
(and supporting files) plus tests under
`phase3-binary/Tests/macprovider-cliTests/`.

Dependencies pinned in SPEC-001 are unchanged; autotune adds NO
new top-level deps. SQLite access uses the same approach as the
rest of the codebase (check for existing SQLite usage in
`phase3-binary/Sources/`; if none, the simplest path is the
system `libsqlite3` via Swift's C-interop wrapper. Document the
choice in implementation-notes.html "SPEC-013 design decisions").

## Branch strategy

This BUILD work lives on a NEW branch
`feat/cli-autotune-impl` branched OFF
`spec/cli-autotune-v1` (the SPEC branch, which has PR #108 open
as DRAFT against `main`). When you start:

```bash
cd /Users/augstar/macprovider-poc
git fetch origin
git checkout -b feat/cli-autotune-impl origin/spec/cli-autotune-v1
```

This way your build PR is STACKED on the SPEC PR. When the SPEC
PR merges to main, this PR rebases onto main cleanly. Do NOT
modify the SPEC file (`specs/SPEC-013-cli-autotune.md`) or any
file under `specs/` from this branch — see Hard Rule 1.

Commit checkpoints (Hard Rule 4) on this branch:
`feat(autotune) Step N: <deliverable>`.

## Reference hygiene (strict clean-room — non-negotiable)

SPEC-001 § 7.2 establishes strict clean-room for d-inference (the
DARKBLOOM LICENSE AGREEMENT prohibits use in competing products).
You MUST NOT:
- Fetch, clone, or read https://github.com/Layr-Labs/d-inference
- Read any d-inference source files, README, or config files
- Consult third-party blog posts that reproduce d-inference source

You MAY consult:
- mlx-swift-lm source (Apple/mlx-swift-examples, MIT)
- Apple MLX documentation
- HuggingFace tokenizer_config.json schema
- This repository's PR #103 prototype on the
  `spike/provider-model-autotune` branch
- This repository's Phase 1+2 materials

SPEC-013 doesn't touch attestation or privacy paths, so the
clean-room concern is small. But the rule is the rule.

## Build sequence

Follow this order. Each step has a clear deliverable; complete
it before moving on. Commit at each step boundary.

**Step 1. Subcommand scaffolding.**
Add `AutotuneCommand: ParsableCommand` to
`phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift`.
Register it under the top-level `MacProviderCLI` parser. Wire
the §7 flag set (CLI surface summary): `--target-context`,
`--candidate-models`, `--max-model-size`, `--min-model-size`,
`--kv-bits-axis`, `--max-batch-axis`, `--max-context-axis`,
`--stage1-replicates`, `--stage2-replicates`, `--gate-ttft-ms`,
`--tps-tie-epsilon`, `--max-duration`, `--drain-grace`, `--port`,
`--db-path`, `--retain-runs`, `--json`, `--apply`, `--drain`,
`--restart-foreground`, `--dry-run`, `--report-only`,
`--verbose`. Each flag with the defaults from §7. Implement
`--dry-run` first (prints candidate plan and exits) as the
cheapest way to prove the parser is wired.
Deliverable: `macprovider-cli autotune --help` prints the full
flag set; `macprovider-cli autotune --dry-run` prints the
default candidate list and exits 0.

**Step 2. `--no-join` flag on `serve` (implementation precondition).**
SPEC-013 FR-E.2 requires `--no-join` semantics on
`macprovider-cli serve`. The flag does NOT exist today; add it
as a tiny additive change to `ServeCommand` in
`MacProviderCLI.swift`. When `--no-join` is set:
- The binary does NOT establish a WS session with the coordinator
- The binary's local `/v1/models`, `/v1/chat/completions` etc.
  surfaces remain reachable on `127.0.0.1:<port>`
- On exit, no `state_update reason: "shutdown"` flows
Audit-grade test in `ServeCommand` tests asserts the WS coordinator
client is never instantiated when `--no-join` is set.
Deliverable: `macprovider-cli serve --no-join --model X --port Y`
serves locally without coordinator handshake; coordinator pool
membership unchanged.

**Step 3. SQLite schema + DB layer.**
Implement `AutotuneDB`:
- Open `~/.config/macprovider/autotune.sqlite` (operator-overridable
  via `--db-path`).
- Create the `tune_trials` table per FR-G.1 if absent, including
  the `stage INTEGER NOT NULL DEFAULT 1` column.
- Run the migration `ALTER TABLE tune_trials ADD COLUMN stage
  INTEGER NOT NULL DEFAULT 1` against an existing prototype DB
  (wrap in a duplicate-column ignore per the prototype's pattern).
- Create the `tune_runs` table per FR-G.2 with the normative
  `exit_reason` enum constraint enforced at the application
  layer (SQLite doesn't have native enums; document this in
  implementation-notes).
- Implement transactional retention sweep per FR-G.1 (single
  SQLite transaction covering both `tune_trials` and `tune_runs`
  deletes; runs after the new `tune_runs` row is created;
  default N=50, operator-overridable via `--retain-runs`,
  enforced N>=1).
Deliverable: a fresh autotune.sqlite is created on first run;
prototype-DB migration works on a fixture; retention sweep is
tested.

**Step 4. Provider lifecycle (start/stop/wait-ready).**
Implement `CandidateProviderRunner`:
- `start(model:, port:, kvBits:, maxContext:, maxBatch:)` —
  spawns `macprovider-cli serve --no-join --model <id>
  --port <N>` with optional knob flags. Use the same
  `Process()` pattern as `SelfUpdate.swift`. Stream stdout/stderr
  to a per-trial log file under
  `~/.cache/macprovider/autotune-logs/`.
- `waitForReady(timeout:)` — poll
  `GET http://127.0.0.1:<port>/v1/models` until 200, the
  process exits (record `notes = "provider exited rc=<n> during
  load"` and tail of stderr), or timeout. The wait time is NOT
  counted against gate-ttft-ms per FR-D.1 measurement-isolation.
- `stop(graceSeconds:)` — SIGTERM the subprocess, poll for port
  free up to the grace window, escalate to SIGKILL only on the
  manually-started foreground path (NEVER on the launchd-managed
  install — FR-E.1).
Invariant: AT MOST ONE provider alive at any moment.
Deliverable: a unit test starts a real `serve`, waits for ready
against a small model, runs one HTTP request, stops cleanly.
Port `:18080` is free post-stop within the grace.

**Step 5. Provider-conflict pre-flight (FR-E.1).**
Implement the pre-flight check:
- Detect launchd-managed install via
  `launchctl list | grep live.streamvc.macprovider`.
- Detect foreground install via PID + argv match on
  `macprovider-cli serve` excluding the autotune's own argv
  (whole-word match on `serve`).
- Default (no `--drain`): refuse with stderr error naming the
  install path; write `tune_runs.exit_reason = 'provider_conflict'`;
  exit non-zero.
- With `--drain`: implement the launchd `bootout/bootstrap` and
  foreground SIGTERM paths per FR-E.1's "Drain sequence" prose.
- With `--drain --apply`: install the new recipe before
  bootstrap so the restart picks it up.
- With `--drain` alone: restore the original config on exit.
Deliverable: with no serve running, autotune proceeds; with a
launchd-managed serve and no `--drain`, autotune refuses cleanly;
with `--drain`, autotune drains and resumes after.

**Step 6. Pre-warm (FR-D — Shape A or Shape B).**
Pick ONE shape and document in implementation-notes:
- **Shape A**: invoke `macprovider-cli models pull <id>` before
  each candidate's probe. This requires shipping a new `models
  pull` subcommand. The subcommand's normative contract is OUT
  of SPEC-013's v1 scope, so spec it narrowly here: synchronous
  online HF fetch into the same cache `ModelRuntime` reads from;
  exit 0 on success, non-zero with a discriminated reason on
  failure (network / HTTP error / signature mismatch).
- **Shape B**: rely on the runtime's online fallback during
  `serve` load. Detect cold-cache by checking the local HF
  snapshot path BEFORE spawning the provider; if missing, spawn
  the provider, time the load phase separately, and ONLY start
  the measurement window after `/v1/models` returns 200 (the
  cold load is excluded from gate-ttft-ms per FR-D.1).
Whichever you pick, classify failures per FR-D.2 (transient =
advance; integrity = abort whole run with
`exit_reason = 'pre_warm_integrity_failure'`).
Deliverable: a unit test that simulates a transient pre-warm
failure for candidate 1 and a successful pre-warm for candidate 2;
autotune records the failure with a transient classification and
proceeds.

**Step 7. Stage 1 — feasibility iteration (FR-A.1-4).**
Implement `Stage1Iterator`:
- Iterate the operator-supplied or default candidate list in
  the GIVEN order. NO internal re-rank by parameter count or
  predicted fit (FR-A.1; AC-17 will catch this).
- For each candidate, pre-warm + start + wait-for-ready + fire
  `stage1_replicates` requests at the target context + stop.
- Apply the FR-A.3 four-condition feasibility gate (HTTP 2xx,
  TTFT ≤ gate, no stop-token leak, no process exit).
- STOP on the first feasible candidate. Return the chosen
  model id. Record per-candidate trial rows with `stage=1`.
- If no candidate is feasible: emit the all-infeasible error
  per FR-A.4 with the SMALLEST candidate's reason surfaced
  first (FR-H.4); write `tune_runs.exit_reason = 'no_feasible'`.
Deliverable: AC-1, AC-2, AC-3, AC-17 pass.

**Step 8. Stage 2 — knob hill-climb (FR-B.1-3).**
Implement `Stage2HillClimb`:
- For the chosen model, evaluate the cartesian product of
  `kv_bits ∈ {unset, 4, 8}`, `max_batch ∈ {1, 2}`,
  `max_context` (default `[--target-context]` single cell; opt-in
  axis per FR-B.1's parse rules).
- Each cell: `stage2_replicates` replicates, median tps, p95
  TTFT, strict-all-feasible-or-cell-fails.
- Apply `_is_new_best` semantics per FR-B.2 — port verbatim
  from the prototype `_is_new_best()` function. The prototype is
  at `beta/autotune.py` on the prototype branch.
- Return the winning `(model, kv_bits, max_batch, max_context)`
  tuple + recorded median tps + p95 TTFT.
- Record per-cell trial rows with `stage=2`.
Deliverable: AC-4, AC-5, AC-16, AC-18 pass.

**Step 9. Recommendation surface (FR-F.1-3).**
Implement `RecommendationEmitter`:
- Terminal output per FR-F.1 — the RECOMMENDATION block with
  model id, knobs, target context, replicated median tps + p95
  TTFT, alternates (smaller candidates from input list by NAME
  ONLY — never probed), exact serve command line.
- `--json` output per FR-F.2 — the full JSON schema with
  `spec_version`, `run_id`, `started_at/ended_at`, machine
  fingerprint, inputs, recommendation, alternates, infeasible,
  recipe_hash, db_path. Use RFC 8785 JCS for the hash input
  canonicalization (the only published Swift JCS implementation
  I'm aware of is small; if you can't find one, vendor a JCS
  encoder following https://datatracker.ietf.org/doc/html/rfc8785).
  Hash: SHA-256 of the JCS form of the §5.6 hash input table;
  format `sha256:<64-lowercase-hex>`. AC-12 tests the
  cross-implementation determinism (the test harness can
  compute the same hash in Python or via shell `jq + sha256sum`
  to verify).
- `--apply` per FR-F.3 — atomic temp-file + rename to
  `~/.config/macprovider/config.yaml`; backup as
  `config.yaml.bak-<unix-ts>-<counter>` (lowest non-negative
  free counter, no overwrite); modify ONLY the 4 owned keys
  (`model`, `kv_bits`, `max_context_override`,
  `max_concurrency_override`); carry all other keys verbatim
  with comments preserved (use Yams' round-trip-preserving
  YAML if available; otherwise document the comment-preservation
  limitation in implementation-notes).
- Print the launchd restart hint per FR-F.3 when `--apply` is
  used without `--drain`.
Deliverable: AC-9, AC-11, AC-12 pass.

**Step 10. Failure modes + signal handling (FR-H.1-4).**
Implement SIGINT / SIGTERM handler: stop the current candidate
provider within `--drain-grace` (default 30s); write the
partial `tune_runs` row with `exit_reason = 'interrupted'`;
write the last in-flight `tune_trials` row; close the DB;
exit code 130. Use Swift `DispatchSource.makeSignalSource(signal:)`
on the main queue or equivalent.
Wall-clock budget enforcement per NFR-1: `--max-duration` is a
hard cap; mid-Stage-1 exhaustion → `exit_reason =
'budget_exhausted_no_model_selected'`; mid-Stage-2 →
`exit_reason = 'budget_exhausted_with_partial_recommendation'`
with the best-so-far recommendation emitted.
Deliverable: AC-10, AC-13 pass.

**Step 11. Acceptance test suite.**
Implement test fixtures and scripts in
`phase3-binary/Tests/macprovider-cliTests/AutotuneTests/`
covering AC-1 through AC-19. Some ACs need real binary
execution (AC-6, AC-7); mark these as integration tests gated
behind a `--enable-integration` swift test flag so unit tests
remain fast.
Deliverable: the full AC suite passes locally with both
unit-only and integration runs.

## Operator checkpoint timing

The operator will check on the build at:
- **T+15 minutes** — Are you reading required files? Do you
  understand the SPEC-013 scope and the picked Option A? Any
  immediate clarifying questions you'd want answered before
  writing code?
- **T+1 hour** — Step 1 should be complete (`autotune --help`
  works, `autotune --dry-run` works). Any spec ambiguity
  surfaced should be in implementation-notes.html Open Questions.
- **End of day 1** — Steps 1-4 done is on track. The DB layer
  and provider lifecycle are the technical risk.
- **Daily during active work** — Operator reads
  implementation-notes.html Open Questions and resolves them.

If you have a question that blocks progress, STOP and write it
to implementation-notes.html Open Questions. The operator will
address it asynchronously. Do not invent answers to substantive
spec ambiguity.

## When to stop and ask vs proceed

**Proceed without asking when:**
- The spec answers your question exactly.
- A trivial design choice has an obvious cheap default (pick it,
  note in implementation-notes "SPEC-013 design decisions").
- You can satisfy a requirement two equivalent ways; pick the
  simpler.

**Stop and ask (via Open Questions) when:**
- A requirement conflicts with another requirement.
- The spec assumes a Swift API that doesn't match the pinned
  version's actual surface.
- An AC is testable only with infrastructure that doesn't exist
  yet (acceptable to defer; flag it).
- You discover the runtime's online-fallback path is not what
  SPEC-013 §5.4 Shape B claims.
- The §10 implementation choice (Option A vs Option B) appears
  to be genuinely blocked on something the BUILD prompt picks
  wrong.

## Acceptance gate

When you believe Step 11 is complete:

1. Run the full Swift test suite (`swift test --package-path
   phase3-binary`). Every AC must pass. Capture pass/fail.
2. Run a smoke test on a real Mac: a fresh
   `macprovider-cli autotune --target-context 2000
   --max-duration 600` end-to-end against the operator's
   actual hardware (or a small candidate list to keep it short).
   The recommendation block must print, the JSON schema must
   validate against the FR-F.2 schema in §5.6, and the
   `tune_runs.exit_reason` must be `'ok'`.
3. Verify a fresh recipe_hash is reproducible: run the same
   `autotune` invocation twice on the same Mac with the same
   flags; both `tune_runs.recipe_hash` values MUST be identical
   even though observed tps/ttft differ. This is AC-12 property 1.
4. Write a final summary in implementation-notes.html:
   "SPEC-013 Acceptance complete" section with per-AC pass/fail
   and any deviations.

Total expected effort: 1-2 weeks of active session work.

## Hard rules

1. **Do not modify SPEC-013 or any file under `specs/`.** This
   build branch is downstream of the SPEC PR. If you find a real
   spec bug, write it to implementation-notes.html Open Questions;
   the operator amends the SPEC on the SPEC branch.

2. **Do not modify code outside `phase3-binary/`.** Specifically:
   do not touch `beta/`, `specs/`, `phase4-coordinator/`,
   `phase5-gateway/`. The autotune subcommand is fully
   self-contained in the binary.

3. **Strict clean-room.** Reference hygiene above is enforceable.
   If you find d-inference content via search, close the tab and
   add an Open Question.

4. **Commit checkpoints.** Commit working code at the end of each
   completed Step (1 through 11). Operator can roll back to a
   step boundary if needed. Commit messages: `feat(autotune)
   Step N: <deliverable>`.

5. **Never silently bump dependency versions.** Pinned versions
   are contract. If a pin breaks, Open Question. Autotune adds
   NO new top-level deps; the SQLite path uses the system
   `libsqlite3` via Swift's C-interop or an existing repo helper
   if one is already present.

6. **Honor the FR contract.** Every FR-X has a binding rule.
   `tune_trials.stage` defaults from migration are for backfill
   ONLY; new inserts MUST set 1 or 2 explicitly. `recipe_hash`
   format is `sha256:<64-lowercase-hex>` — verify in tests.
   The `alternates` list is NAME-ONLY (no metrics) — AC-1 and
   AC-2 verify.

7. **No silent --apply restart.** `--apply` writes the config
   and exits. It NEVER restarts launchd on its own (unless
   `--drain` was also passed). FR-F.3 mandates a stderr hint
   in the no-drain case.

8. **Preserve the biggest-fit objective.** If you find yourself
   considering "score candidates by tps and pick the highest" —
   STOP. That is the prototype's anti-pattern objective that
   SPEC-013 §1 explicitly rejects. The selection rule is
   STOP-on-first-feasible per operator-supplied order. AC-17
   catches this; reading it once before writing Stage 1 is
   cheap insurance.

## Anti-rules

- Do not write build prompts for other SPECs.
- Do not pre-optimize. Get correctness first, profile later.
- Do not skip writing tests. Every FR should have a unit test
  where feasible; every AC has a script or test case.
- Do not implement coordinator-side recipe ingestion (§11 v2
  deferral; SPEC-014 territory).
- Do not implement warm-swap-driven tuning (§11 v2 deferral;
  SPEC-011 coupling).
- Do not implement the v2 `--resume` flag (§11 deferral).
- Do not refactor unrelated files. The autotune subcommand is
  additive. The only non-autotune edit you make is the
  `--no-join` flag on `ServeCommand` (Step 2).

## Open question template

When you write an Open Question to implementation-notes.html,
use this shape:

```
<section><h3>OQ-IMPL-N: <SHORT TITLE></h3>
<p class=meta>Step N · status: <open|resolved> · added: <date></p>
<p><strong>What:</strong> <one sentence>.</p>
<p><strong>Why blocked:</strong> <one sentence on what you'd do
if you had the answer>.</p>
<p><strong>Spec reference:</strong> SPEC-013 § X.Y FR-Z (line ranges).</p>
<p><strong>Proposed default if no operator response:</strong>
<one sentence>.</p>
</section>
```

The proposed-default sentence is critical: if the operator
doesn't respond, you can proceed by adopting your own
proposal and noting that in the resolution. Open Questions
should not be a build blocker by themselves; they're a
forcing function for the operator to check in.

## Final pre-flight before you start

Print to stdout:
- Your understanding of the mission (1 sentence — must include
  "biggest-fit, not max-tps").
- Your understanding of the picked implementation choice (Option A
  Swift-native).
- The first 3 things you'll do in the first 15 minutes.
- Any immediate questions for the operator (none is acceptable).

Then begin Step 1 of the build sequence.

Good luck. The spec is locked at v0.3; the operator is available
asynchronously for substantive questions. Build well.

=== END PROMPT ===
```

---

## How to use

```bash
cd /Users/augstar/macprovider-poc
git fetch origin
git checkout -b feat/cli-autotune-impl origin/spec/cli-autotune-v1

# Fire codex via omc ask:
omc ask codex "$(cat specs/BUILD_SPEC_013_PROMPT.md | sed -n '/=== BEGIN PROMPT ===/,/=== END PROMPT ===/p' | sed '1d;$d')"
```

Or paste the content between `=== BEGIN PROMPT ===` and `=== END
PROMPT ===` into a fresh interactive Codex CLI session.

## What you should see in the first 15 minutes

- Agent reads SPEC-013 (~3-5 min)
- Agent skims SPEC-001, SPEC-003 §FR-C5, the audit report (~5
  min)
- Agent peeks at the prototype on the spike branch (~2 min)
- Agent prints its mission understanding (must include
  "biggest-fit, not max-tps") + first-15-min plan
- Agent begins Step 1: `AutotuneCommand.swift` scaffolding

Red flags to watch for in the first 15 min:

- Agent jumps to coding before reading
- Agent asks for clarification on the picked Option A (it
  should accept the BUILD prompt's pick; if it pushes back,
  that's a legitimate Open Question)
- Agent attempts to read d-inference (clean-room violation)
- Agent attempts to modify SPEC-013 (Hard Rule 1)
- Agent silently pivots to Option B without an Open Question

## Operator checkpoints — concrete actions

**T+15 min:**
```bash
git -C /Users/augstar/macprovider-poc log --oneline -3
cat /Users/augstar/macprovider-poc/phase3-binary/implementation-notes.html | grep -A3 'SPEC-013'
```
Look for any "Open questions" entries tagged OQ-IMPL-N. If
blocking, answer asynchronously.

**T+1 hour:**
```bash
ls /Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift
git -C /Users/augstar/macprovider-poc log --oneline -5
```
Expect `AutotuneCommand.swift` scaffolded, Step 1 commit, and
`macprovider-cli autotune --help` printing the flag set.

**Daily:**
Open implementation-notes.html in a browser, scan the SPEC-013
sections. Resolve any open OQ-IMPL-N entries.

## When build is done

You'll know because:
1. All 19 ACs (AC-1 through AC-19) pass
2. Smoke test on a real Mac produces a valid recommendation +
   recipe_hash
3. `tune_runs.exit_reason = 'ok'` on the smoke test
4. implementation-notes.html has "SPEC-013 Acceptance complete"
   section

At that point: open a PR for `feat/cli-autotune-impl` against
`main` (the SPEC PR will have merged by then, or will merge
just before). The build PR's body should lead with "implements
SPEC-013 v0.3 Option A Swift-native; AC-1 through AC-19
passing; deferred items per §11 unchanged."

## Post-merge documentation hooks (per SPEC-013 §11 checklist)

Once the build PR merges:

1. Append a decision-log entry to `beta/DECISION_CRITERIA.md`
   summarizing the biggest-fit lock, Option A choice, deferred
   v2 items.
2. Add a one-liner to SPEC-003 v0.x's onboarding flow:
   "after install, consider `macprovider-cli autotune`."
3. Patch SPEC-010 §11 and SPEC-011 §8/§11 cross-references
   (SPEC-013 = autotune; recommended catalog is SPEC-014).
4. Close PR #103 (the Python prototype) — either by closing as
   superseded or by repurposing the branch for the air5 n=3
   replication study that backs OQ-A through OQ-E.
