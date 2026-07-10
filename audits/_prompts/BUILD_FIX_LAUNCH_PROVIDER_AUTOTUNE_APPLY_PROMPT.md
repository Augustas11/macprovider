# BUILD_FIX — LaunchProviderController: persist autotune recommendation to config so serve succeeds

Fix a **P0 first-run onboarding failure** in the shipped `Malibu-v1.8.2.pkg`:
fresh installs cannot reach `.live` state because Malibu.app runs
`autotune --recommend --json` (prints recommendation but does NOT persist)
and then spawns `serve`, which refuses with exit 2:

```
$ macprovider-cli serve --ctl-socket-path <sock> --enable-warm-swap --config <cfg>
coordinator join requires model_artifact_sha256 from autotune --recommend --apply
Exit 2
```

## Reproduced end-to-end on 2026-07-05

Full smoke report at
`/private/tmp/claude-501/-Users-augstar-macprovider-poc/1b33094f-c4bc-4bad-b9ce-75ecc98946c4/scratchpad/smoke-v182/SMOKE_REPORT.md`.

Key evidence:

- `~/.config/macprovider/config.yaml` after autotune completes contains
  ONLY `provider_id` and `link_state: linked`. Missing every field the CLI's
  `serve` needs: `model`, `model_artifact_path`,
  `model_artifact_sha256`, and the `model_catalog_*` provenance keys.
- User-facing failure copy: **"The bundled macprovider-cli is incompatible
  with this Malibu.app version (exit 2 in 0.1s). Please reinstall Malibu.app
  or file a bug."**
- Retry button loops through the same failure — no self-healing.

## Bug location (already traced)

`phase3-binary/app/Sources/Malibu/Onboarding/AutotuneRecommendationRunner.swift:31`

```swift
arguments: ["autotune", "--recommend", "--json", "--config", configPath.path]
```

`fromAutotuneJSON` (line 111) extracts `recommended_model` and
`earnings_estimate` for UI display but never touches the apply-ready
config payload that `serve` requires. The `ModelDownloadPlan` value it
returns is passed to `downloadModel` and then `startAgent` — but by the
time `startAgent` invokes the CLI's `serve`, config.yaml still lacks the
required fields.

BUILD audit R1 found one important correction to the original hypothesis:
the current `autotune --recommend --json` output does **not** include
`model_artifact_path`, `model_artifact_sha256`, or `model_catalog_*`
provenance. The CLI constructs those values only in the `--apply` path
from the selected benchmark plus signed candidate catalog before calling
`ConfigApplier`. Therefore Malibu.app must not synthesize trusted
serve-readiness fields from `recommended_model`, candidates, defaults,
local cache paths, or `onboarding.json`.

## Scope IN — this PR

### Item 1 (mandatory). Persist autotune recommendation to `config.yaml` before `startAgent`

The MalibuAgent-spawned `serve` command must find the full apply-ready
recommendation payload in `config.yaml` when it starts. Today that means:

- `model`
- `model_artifact_path`
- `model_artifact_sha256`
- `model_catalog_key`
- `model_catalog_model_id`
- `model_catalog_revision`
- `model_catalog_sha256`
- `model_catalog_version`
- `model_catalog_hash`
- `kv_bits` when selected by autotune
- `max_context_override`
- `max_concurrency_override`
- `donor_mode` only when the recommendation path is explicitly donor mode

Options:

- **Approach A — Chain a second CLI call.** After the existing `--json`
  call, invoke `autotune --recommend --apply --config <path>` to have the
  CLI write the recommendation to config. Advantage: App doesn't touch
  config.yaml schema. Disadvantage: doubles autotune runtime; blocked on P1
  hang (`--apply` currently hangs indefinitely — see below).
- **Approach B — Extend CLI JSON with an apply-ready payload, then persist
  that payload in Swift.** Add an explicit JSON object (name suggestion:
  `serve_config`) emitted by `autotune --recommend --json`. The payload
  must be produced from the same selected benchmark + signed catalog row
  values that the current `--apply` path passes to `ConfigApplier`, not
  recomputed by Malibu.app. Malibu.app parses that typed payload and writes
  it to `config.yaml` via `ProviderConfig`. Advantage: single autotune
  invocation; no dependency on the `--apply` hang; CLI remains the owner of
  recommendation/provenance derivation. Disadvantage: small CLI JSON
  contract extension plus App-side persistence of serve-required config
  keys.
- **Approach C — Use existing `autotune --recommend --apply --json`
  combination once the P1 apply hang is fixed.** The current CLI already
  accepts the flag combination and applies before printing JSON; this PR
  must not spend work adding that combination again. The missing piece is
  either fixing the `--apply` hang or using Approach B.

**Recommended: Approach B as corrected by BUILD audit R1.** Rationale:
(a) avoids the separate P1 `--apply` hang; (b) keeps CLI-owned provenance
derivation in the CLI; (c) keeps the app's new responsibility limited to
strictly validating and persisting an explicit apply-ready payload; (d)
SPEC-026 already couples the App to config.yaml at other points
(`provider_id`, `link_state`), so this is boundary repair rather than a
new coordinator surface. Document this choice in the implementation commit
body and in `beta/DECISION_CRITERIA.md`.

### Item 2 (mandatory). Verify JSON output field structure vs. what `serve` requires

Before implementing Approach B, codex must inspect the CLI source
(`phase3-binary/Sources/macprovider-cli/`) to confirm:

- What fields `autotune --recommend --json` emits (in `Recommendation`
  or equivalent JSON model)
- What fields `serve` reads from config.yaml (in the coordinator-join
  precondition check that produces the "requires model_artifact_sha256"
  error)
- Which values the `--apply` path computes from selected benchmark and
  signed candidate catalog before `ConfigApplier.apply`

Audit R1 already verified that current JSON is incomplete. The
implementation must extend JSON to include an explicit apply-ready
`serve_config` payload carrying the fields above. Malibu.app must reject
the response if that payload is missing, incomplete, or invalid. Malibu.app
must not synthesize catalog/artifact provenance from `recommended_model`,
candidate display rows, local defaults, cache paths, or `onboarding.json`.

The JSON contract must remain backward compatible for existing display
fields: keep `recommended_model`, `candidates`, comparison, warnings, and
earnings estimate inputs unchanged.

### Item 3 (mandatory). App-side seam and tests

Add an explicit App-side result type so the typed payload cannot be hidden
inside the runner or reparsed ad hoc in the controller. Suggested shape:

```swift
struct AutotuneRecommendationResult {
    let plan: LaunchProviderController.ModelDownloadPlan
    let serveConfig: ProviderConfig.AutotuneServeConfig
}
```

Change `AutotuneRecommendationRunner.run` and
`LaunchProviderController.Dependencies.runAutotune` to return that result.
Add injected dependencies for `persistAutotuneRecommendation` and
`validateServeConfigShape` backed by `ProviderConfig`. Keep
`AutotuneRecommendationRunner` as process invocation + JSON parsing only;
keep `LaunchProviderController` as state-machine orchestration only.

Add `LaunchProviderControllerTests` covering:

- **Test A (regression):** Given a fresh install with no config.yaml, when
  `launch()` completes autotune stage, then the controller must have invoked
  the new serve-config persistence dependency and verified serve-config
  shape before transitioning to `.downloadingModel`. Failing today.
- **Test B (retry loop):** Given a `.failed` state at `.startingAgent`
  caused by missing or invalid serve config, when `retry()` fires, the
  second attempt MUST rerun the common autotune/persist/validate checkpoint
  and reach `.live` (not loop into the same failure).
- **Test C (resume):** Given a partial state (autotune completed but
  process killed before serve started), when `launch()` resumes from the
  persisted `onboarding.json`, config shape is validated before reaching
  `.startingAgent`. If serve-readiness is missing and `onboarding.json`
  does not contain enough recommendation data to reapply, the implementation
  MUST demote the resume point back to `.autotune` and regenerate/persist a
  fresh recommendation. Do not add fields to `onboarding.json`.

Add `ProviderConfigTests` covering:

- Strict parsing/validation of the `serve_config` payload accepted from
  `AutotuneRecommendationRunner`.
- Top-level upsert of only the recommendation-owned keys listed in Item 1,
  preserving existing `provider_id`, `link_state`, token handling semantics,
  comments/unrelated top-level keys where current helpers preserve them, and
  unrelated CLI config.
- `config.yaml` mode `0600` and atomic replace with directory fsync.
- Serve-readiness validation fails when any required key is missing, when
  `model_artifact_sha256`/catalog SHA fields are not 64 lowercase hex, when
  `model_artifact_path` is not absolute, or when string fields contain
  control characters/newlines that could alter YAML structure. Include
  malicious scalar fixtures containing `#`, `: `, single quote, double
  quote, leading/trailing whitespace, and backslash; use either structured
  YAML serialization with round-trip verification or one quoted/escaped
  scalar helper for every persisted string field.

Add CLI tests covering:

- `autotune --recommend --json` emits `serve_config` for a paid selected
  recommendation, populated from the same `RecommendationCore` fields the
  apply path passes to `ConfigApplier`.
- `serve_config` is absent or null when there is no selected recommendation
  and the CLI would not apply config.
- Existing recommendation display JSON remains backward compatible.

### Item 4 (defensive). Fail-loud when autotune succeeds but config shape is not usable

Add a defensive check between the autotune step and the `.startingAgent`
transition: verify that config.yaml contains the full syntactic field set
that `serve` gates on for coordinator join:

- nonempty `model`
- absolute `model_artifact_path`
- lowercase-hex `model_artifact_sha256`
- nonempty `model_catalog_key`
- nonempty `model_catalog_model_id`
- nonempty `model_catalog_revision`
- lowercase-hex `model_catalog_sha256`
- nonempty `model_catalog_version`
- lowercase-hex `model_catalog_hash`

This App-side check is intentionally **syntactic shape validation**, not a
duplicate of CLI semantic admission. It must catch missing/obviously invalid
local config before spawning `serve`; semantic artifact verification,
catalog freshness, rate-card/model agreement, and signed catalog admission
remain owned by the CLI `serve` preflight. Keep the schema aligned by
centralizing the field list/ranges in one Foundation-only app helper and
mirroring the CLI `ConfigApplier` owned-key list in tests.

If validation fails after an autotune attempt, transition to `.failed`
with a specific message ("autotune completed but config is missing
required serve config shape — file a bug") rather than blindly launching
`serve` and getting exit 2. This catches future regressions in the
wiring.

If validation fails while resuming from persisted `modelReady` or
`startingAgent`, do not launch `serve`. Since `onboarding.json` schema is
unchanged and cannot replay the recommendation payload, rerun the
autotune/persist/validate checkpoint before continuing.

The validation and persistence logic should live behind `ProviderConfig`
APIs (for example `persistAutotuneRecommendation(...)` and
`validateServeConfigShape(...)`) and be injected into
`LaunchProviderController` through dependencies. The controller should
orchestrate stages and branch on success/failure; it should not inline ad
hoc config parsing/writing.

## Scope OUT — deferred to separate PRs

- **P1 — `macprovider-cli autotune --recommend --apply` hangs indefinitely.**
  Independent CLI bug. Users on the CLI-track hit this when trying to
  self-repair. Different subsystem (`phase3-binary/Sources/macprovider-cli/`),
  different owner. This PR avoids depending on that path by extending JSON
  and letting Malibu.app persist the explicit payload.
- **UI copy improvements** on the error state. Existing "Please reinstall
  Malibu.app or file a bug." is technically correct but demoralizing;
  a better message would name the specific config issue. Deferred to a
  copy-polish PR.
- **`autotune --recommend --json` timeout tuning.** Currently 30s in
  `AutotuneRecommendationRunner.processTimeout`; the manual repro showed
  autotune sometimes taking >20s. If the codex investigation reveals the
  30s window is too short on fresh installs, that's a related-but-separate
  fix.
- **SMAppService login-item registration timing.** Not changed.
- **New coord surface, new SPECs, new secrets, new deps.** None.

## Constraints

1. **No coordinator surface added.** Everything happens locally between
   Malibu.app and the bundled CLI.
2. **SPEC-026 §6.1 state-machine sequence unchanged.** Same 10 stages:
   `identityReady → registering → autotuning → downloadingCLI →
   downloadingModel → startingAgent → authenticating → live`. Fix is
   internal to the `.autotuning` → `.downloadingModel` transition
   plumbing.
3. **Existing tests must stay green.** No test-only edits to bypass the
   regression.
4. **`onboarding.json` schema unchanged.** No new fields.
5. **Persistence discipline unchanged.** `config.yaml` mode 0600,
   atomic-replace-with-fsync (per `[[state-file-atomic-replace-needs-fsync]]`).
6. **No child-process environment changes.** `sanitizedProcessEnvironment`
   already filters — do not weaken it to fix the config wire-up.
7. **No new dependencies.** Foundation + existing helpers only.
8. **No trusted-field synthesis in the App.** Malibu.app may persist only
   the typed `serve_config` payload emitted by the bundled CLI after strict
   validation. It must not derive artifact/catalog provenance from display
   JSON.
9. **Strict scalar validation.** Reject or safely quote/escape control
   characters/newlines and YAML-sensitive scalars in persisted string fields.
   Hash fields must be 64 lowercase hex. Paths must be absolute where
   `serve` requires absolute paths. Numeric knobs must stay within the same
   accepted ranges as the CLI writer emits.

## Audit-loop discipline

Per `[[feedback-audit-build-prompts-before-impl]]`:

1. **This BUILD prompt gets a 3-lane codex audit FIRST** before codex
   executes it. Prompt files:
   - `specs/AUDIT_BUILD_FIX_LAUNCH_PROVIDER_CODE_AUDIT_PROMPT.md`
   - `specs/AUDIT_BUILD_FIX_LAUNCH_PROVIDER_SECURITY_AUDIT_PROMPT.md`
   - `specs/AUDIT_BUILD_FIX_LAUNCH_PROVIDER_ARCHITECT_AUDIT_PROMPT.md`
2. Converge prompt to 0 CRITICAL / 0 HIGH / 0 MEDIUM.
3. **Security lane focus:** Malibu.app now writes to a config file the CLI
   reads — verify no injection surface (path traversal, YAML injection via
   field values, quote escaping for every persisted scalar, and strict
   lowercase-hex validation for SHA fields).
4. Codex executes audited prompt → IMPL on this branch
   `fix/launch-provider-autotune-apply`.
5. 3-lane IMPL audit prompts:
   - `specs/AUDIT_FIX_LAUNCH_PROVIDER_IMPL_{CODE,SECURITY,ARCHITECT}_AUDIT_PROMPT.md`
6. Converge 0/0/0.
7. DRAFT → Ready → merge.

## Manual verification before Ready-for-review

- On a fresh-slate Mac (or after nuking Malibu.app + `~/.config/macprovider/`
  + `~/Library/Application Support/Malibu/` + `tech.malibu.provider`
  Keychain), install the .pkg built from this branch.
- Enable onboarding v2 for a packaged GUI launch with
  `defaults write tech.malibu.app onboardingFlow -string v2` (or use
  `launchctl setenv MALIBU_ONBOARD_V2 1` before launching and clean it up
  after the smoke).
- Launch Malibu.app → click Launch Provider.
- Verify state machine reaches `.live` end-to-end without hitting the
  `.failed(startingAgent, ...)` state.
- Verify `~/.config/macprovider/config.yaml` after the flow contains
  `model_artifact_sha256`, `model_artifact_path`, `model`, and
  `model_catalog_*` provenance.
- Verify menu bar transitions from "Idle" → running state.

## Automated implementation definition of done

- `swift test` passes for `phase3-binary` (existing tests + new controller,
  config, and CLI JSON tests from Item 3).
- 3-lane codex audit at 0 CRITICAL / 0 HIGH / 0 MEDIUM.
- Decision log entry appended to `beta/DECISION_CRITERIA.md` explaining why
  Malibu.app now persists CLI-emitted autotune serve config, which fields are
  owned, and what should re-trigger the decision.

## Ready-for-review release gate

- CI green.
- Manual smoke on a live Mac (per above) reaches `.live` state.
- If the live fresh-slate `.pkg` smoke cannot be run from the current
  automation environment, keep the PR Draft and include
  `Not-tested: live fresh-slate pkg smoke` in the commit/PR notes.
- Ready to convert DRAFT → Ready only after the manual smoke is complete.

## Reference

- SPEC-026 v0.11 § 6.1 step 7c (autotune stage)
- Smoke report:
  `/private/tmp/claude-501/-Users-augstar-macprovider-poc/1b33094f-c4bc-4bad-b9ce-75ecc98946c4/scratchpad/smoke-v182/SMOKE_REPORT.md`
- Bug location:
  `phase3-binary/app/Sources/Malibu/Onboarding/AutotuneRecommendationRunner.swift:31`
- State machine:
  `phase3-binary/app/Sources/Malibu/Onboarding/LaunchProviderController.swift`
  `.autotuning` → `.downloadingModel` → `.startingAgent` transitions
- Base branch: `main` (fef58d3 or later)
