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
  `serve` needs: `model_artifact_sha256`, `model_id`, catalog config.
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
`earnings_estimate` for UI display but never touches `model_artifact_sha256`
or writes to config. The `ModelDownloadPlan` value it returns is passed to
`downloadModel` and then `startAgent` — but by the time `startAgent` invokes
the CLI's `serve`, config.yaml still lacks the required fields.

## Scope IN — this PR

### Item 1 (mandatory). Persist autotune recommendation to `config.yaml` before `startAgent`

The MalibuAgent-spawned `serve` command must find `model_artifact_sha256`
(and any other fields the CLI's `serve` gates on) in `config.yaml` when it
starts. Options:

- **Approach A — Chain a second CLI call.** After the existing `--json`
  call, invoke `autotune --recommend --apply --config <path>` to have the
  CLI write the recommendation to config. Advantage: App doesn't touch
  config.yaml schema. Disadvantage: doubles autotune runtime; blocked on P1
  hang (`--apply` currently hangs indefinitely — see below).
- **Approach B — Parse `--json` and write config.yaml in Swift.** Extract
  the model_artifact_sha256 from the recommendation JSON (per the CLI's
  actual --json output, not the abbreviated one `fromAutotuneJSON`
  currently parses) and write it into `config.yaml` via
  `ProviderConfig` (or the existing config-write helpers). Advantage: no
  P1 dependency, single autotune invocation. Disadvantage: App now knows
  the config.yaml schema for serve-required fields.
- **Approach C — Introduce `autotune --recommend --apply --json` combined
  flag.** Requires CLI change: the flag both writes to config AND emits
  JSON. Advantage: clean API, single invocation, both writes and returns
  data. Disadvantage: scope creep into macprovider-cli.

**Recommended: Approach B** for this PR. Rationale: (a) surgical, contained
to LaunchProviderController + AutotuneRecommendationRunner; (b) no
dependency on P1 CLI hang fix (which is a separate PR); (c) SPEC-026
already couples the App to config.yaml at other points (`provider_id`,
`link_state`) so the schema knowledge isn't a new coupling. If codex
identifies a reason B is unsafe (e.g. --json output doesn't actually
contain model_artifact_sha256 and the CLI computes it during --apply),
fall back to Approach A with the P1 hang made a hard blocker for this
PR. Document the choice in the impl commit body.

### Item 2 (mandatory). Verify JSON output field structure vs. what `serve` requires

Before implementing Approach B, codex must inspect the CLI source
(`phase3-binary/Sources/macprovider-cli/`) to confirm:

- What fields `autotune --recommend --json` emits (in `Recommendation`
  or equivalent JSON model)
- What fields `serve` reads from config.yaml (in the coordinator-join
  precondition check that produces the "requires model_artifact_sha256"
  error)
- Whether the JSON output already contains everything `serve` needs, or
  if `--apply` computes additional fields not present in `--json`

If the JSON output already contains model_artifact_sha256, Approach B is
correct. If it doesn't, the fix must either:
- Extend `--json` to include the missing fields (touches CLI)
- OR require `--apply` (blocks on P1)

### Item 3 (mandatory). Extend `LaunchProviderControllerTests`

Add tests covering:

- **Test A (regression):** Given a fresh install with no config.yaml, when
  `launch()` completes autotune stage, then config.yaml MUST contain
  `model_artifact_sha256` before the state machine transitions to
  `.downloadingModel`. Failing today.
- **Test B (retry loop):** Given a `.failed` state at `.startingAgent`
  caused by missing config field, when `retry()` fires, the second attempt
  MUST reach `.live` (not loop into the same failure).
- **Test C (resume):** Given a partial state (autotune completed but
  process killed before serve started), when `launch()` resumes from the
  persisted `onboarding.json`, the config is re-verified/re-applied before
  reaching `.startingAgent`.

### Item 4 (defensive). Fail-loud when autotune succeeds but config is not usable

Add a defensive check between the autotune step and the `.startingAgent`
transition: verify that config.yaml contains the fields `serve` needs
(at minimum `model_artifact_sha256`). If not, transition to `.failed`
with a specific message ("autotune completed but config is missing
required fields — file a bug") rather than blindly launching `serve`
and getting exit 2. This is a belt-and-suspenders check that catches
future regressions in the wiring.

## Scope OUT — deferred to separate PRs

- **P1 — `macprovider-cli autotune --recommend --apply` hangs indefinitely.**
  Independent CLI bug. Users on the CLI-track hit this when trying to
  self-repair. Different subsystem (`phase3-binary/Sources/macprovider-cli/`),
  different owner. If codex identifies P1 fix is required for Approach A to
  work, defer Approach A and use Approach B instead.
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
   field values, quote escaping in `model_artifact_sha256` string).
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
- Set `MALIBU_ONBOARD_V2=1`.
- Launch Malibu.app → click Launch Provider.
- Verify state machine reaches `.live` end-to-end without hitting the
  `.failed(startingAgent, ...)` state.
- Verify `~/.config/macprovider/config.yaml` after the flow contains
  `model_artifact_sha256`.
- Verify menu bar transitions from "Idle" → running state.

## Definition of done

- `swift test` passes (existing tests + new Test A/B/C from Item 3).
- 3-lane codex audit at 0 CRITICAL / 0 HIGH / 0 MEDIUM.
- Manual smoke on a live Mac (per above) reaches `.live` state.
- CI green.
- Ready to convert DRAFT → Ready.

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
