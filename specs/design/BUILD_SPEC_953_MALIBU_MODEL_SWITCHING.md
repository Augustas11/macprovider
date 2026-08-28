# BUILD_SPEC_953_MALIBU_MODEL_SWITCHING - Malibu in-app model switching and background recommendations

Status: Draft build specification
Owner: Product design
Target issue: GitHub #953, "Malibu app: in-app model switching + background autotune recommendations (no Terminal)"
Last updated: 2026-08-08

## 1. Problem

Providers can currently change the served model and ask for a better paid model
only through Terminal workflows:

- `malibu-cli models list`
- `malibu-cli models browse`
- `malibu-cli models switch <hf-id>`
- `malibu-cli models status`
- `malibu-cli autotune --recommend --json`

Malibu is the provider-facing app, but it currently behaves as a monitor and
bounded local controller. This creates a sharp UX break: the provider can see
serving state in Malibu, then must leave Malibu and use CLI commands to discover,
evaluate, and adopt another model.

The feature goal is to make model status, compatible model discovery, live
switching, and low-priority autotune recommendations available inside Malibu
without moving lifecycle, admission, credentials, or model trust decisions into
the app.

## 2. Grounded Repo Interfaces

This section records the repo interfaces verified before writing this spec.
Implementation must re-check these files before coding, because control frames
and CLI options are product-contract surfaces.

### 2.1 Malibu app structure

- `phase3-binary/app/project.yml` defines the Malibu Xcode project.
- `phase3-binary/app/Sources/Malibu/Agent/MalibuAgent.swift` is the app's main
  agent. It attaches to the launchd-owned provider control socket, sends bounded
  local requests, and maintains the dashboard snapshot.
- `phase3-binary/app/Sources/Malibu/Agent/ControlSocketClient.swift` is the
  Malibu client for the provider control socket.
- `phase3-binary/app/Sources/Malibu/Agent/ControlSocketFrame.swift` duplicates
  the CLI control-frame enum locally. The file itself says this should
  eventually move to a shared control library.
- `phase3-binary/app/Sources/Malibu/Dashboard/DashboardWindow.swift` is the
  current SwiftUI dashboard surface.
- `phase3-binary/app/Sources/Malibu/Agent/AgentSnapshot.swift` holds
  `AgentSnapshot` and `AgentSnapshotPresenter`, including presentation of the
  current model ID.
- `phase3-binary/app/Sources/Malibu/Onboarding/AutotuneRecommendationRunner.swift`
  already shells the installed CLI for `autotune --recommend --json --config`
  and parses the `autotune_recommend.v1` JSON. This onboarding runner is a
  legacy path; the Malibu model feature must not reuse it for manual or
  background checks because it lacks the new consent, progress, isolation, and
  installed-only guarantees.
- `phase3-binary/app/Sources/Malibu/System/ProviderConfig.swift` can read the
  current `model` key and persist recommendation-owned serve-config fields under
  the config mutation lock.
- `phase3-binary/app/Sources/Malibu/System/ThermalMonitor.swift` exposes macOS
  thermal state to the app.

### 2.2 CLI model surfaces

- `phase3-binary/Sources/malibu-cli/ModelsSubcommand.swift` owns
  `models list`, `models switch`, and `models status`.
- `models list` prints TSV rows: `model_id<TAB>state`. It reports the current
  runtime model as `warm` and configured supported models as `idle`. If the
  socket is absent, it exits zero with "warm-swap disabled" and prints idle
  catalog rows.
- `models status` prints JSON for a `status_response` control frame containing
  `current_model_id` and `runtime_state`.
- `models switch <targetModelID>` validates the target against effective
  `supported_models`, checks RAM fit, enforces a cooldown using
  `SwitchStateStore`, sends a `switch_request` frame over the control socket,
  receives `switch_ack`, then streams `switch_progress` states on stderr until
  `loaded` or `failed`.
- Current switch rejection reasons are `loading_in_progress`, `cooldown`,
  `not_in_supported_models`, and `other`.
- Current switch progress states are `loading`, `draining`, `loaded`, and
  `failed`.
- Current switch exit codes include target/preflight errors, concurrent switch,
  socket failures, load failures, and cooldown. `--force` bypasses only selected
  soft guards, not unsupported target, concurrent switch, socket, or load
  failures.
- `phase3-binary/Sources/malibu-cli/ModelsBrowseCommand.swift` owns
  `models browse`. It prints TSV rows: `model_id<TAB>est_gb<TAB>fit`, where fit
  can be `fits`, `tight`, `wont_fit`, or `unknown`. It currently has no JSON
  output flag. The command sanitizes HuggingFace-returned IDs for terminal
  display; those sanitized strings are not authoritative action IDs.
- `phase3-binary/Sources/malibu-cli/ControlSocket.swift` is the CLI-side
  source of truth for control-frame shapes. Current frames include
  `switch_request`, `switch_ack`, `switch_progress`, and `status_response`; they
  do not include recommendation adoption, download byte progress, or switch
  cancellation frames.

### 2.3 Autotune recommendation surfaces

- `phase3-binary/Sources/malibu-cli/AutotuneCommand.swift` owns
  `autotune --recommend --json`.
- The same command supports `--candidate-models <ids>` to replace the default
  candidate list for a targeted evaluation. The current implementation is a
  heavyweight benchmark path: for a not-installed candidate it can download
  and load weights before emitting its final recommendation JSON. Malibu must
  not use this legacy path for a quiet background check or describe it as
  read-only.
- The feature requires a new capability-gated
`model_recommendation_check_v1` adapter. Its targeted command shape is:

  ```text
  malibu-cli autotune --recommend --json \
    --candidate-models <exact-raw-model-id> \
    --check-only --progress-json \
    --isolated-cache-root <private-staging-root> \
    --config <config.yaml>
  ```

  The adapter must evaluate only the exact raw ID, use an isolated staging
  cache, emit `model_recommendation_check_event.v1` progress frames and a final
  `autotune_recommend.v1`, and support cancellation before adoption. For
  background checks it additionally supports `--installed-only`, which skips
  candidates without locally present weights and performs no download. These
  are required new CLI surfaces, not claims about flags in the current source;
  Malibu gates the feature tier off until the adapter is present and proven.
- `--prefetch` is a separate existing CLI path that downloads and verifies the
  exact signed model artifact into its prefetch cache, writes a private receipt,
  and requires `--prefetch-receipt <private-receipt-path>`. Its output channel
  is receipt/progress only; it does not emit
  `autotune_recommend.v1`. Malibu does not use this receipt-only path for the
  Compatible online `Evaluate` step in the MVP; BS953-R014 owns signed
  preparation during the adoption transaction so recommendation JSON and
  preparation cannot be confused.
- `phase3-binary/Sources/malibu-cli/AutotuneRecommend.swift` emits
  `schema_version: "autotune_recommend.v1"` with `recommended_model`,
  `serve_config`, `candidates`, `warnings`, hardware metadata, and rate-card
  fields.
- `phase3-binary/Sources/malibu-cli/ConfigApplier.swift` is the CLI config
  apply path used by `autotune --recommend --apply`. It writes a token-redacted
  backup beside the config as `config.yaml.bak-<unix>-<counter>` with mode
  `0600`, then atomically replaces the provider config.
- `serve_config` includes the model ID plus artifact/catalog hash and serving
  knobs needed for config parity:
  `model_artifact_path`, `model_artifact_sha256`, catalog identifiers,
  `kv_bits`, `max_context_override`, `max_concurrency_override`, and
  `donor_mode`. The current visible emitter does not put speculative-draft
  fields in `serve_config`; the new check/adoption schema reserves optional
  `draft_model`/`draft_model_artifact_sha256` only if that capability is later
  added. The MVP parser retains such fields and rejects adoption when they are
  non-null because the current recommendation-owned config set does not apply
  speculative-draft fields.
- `SPEC-023` hard-blocks paid recommendations for thermal throttling and
  sustained critical memory pressure. It also forbids raw hardware fingerprints,
  serials, MACs, UUIDs, and HMAC secrets in output/logs/support bundles.
- `SPEC-013` keeps classic autotune non-automatic unless explicitly applied.
  `--recommend` is the SPEC-023 paid recommendation path and is the one Malibu
  must use.
- `phase3-binary/Sources/malibu-cli/AutotuneRecommend.swift` emits visible
  `autotune_recommend.v1` JSON with `hardware.machine`, `hardware.chip`,
  `hardware.memory_gb`, `hardware.bandwidth_tier`, `hardware.detected`,
  `hardware.os_version`, `hardware.binary_version`, and `inputs.*`. The visible
  recommendation JSON does not include `hardware_identity_hash`; that field is
  present in stored/upload state and is not available to Malibu UI dedupe.
- `phase3-binary/Sources/malibu-cli/HTTPServer.swift` exposes local status
  `binary_version`, `local_status_contract.version`,
  `local_status_contract.minimum_reader_version`,
  `local_status_contract.capabilities`, and short-lived observation validity.
- `phase3-binary/Sources/malibu-cli/IdlePrewarmer.swift` already contains
  the CLI-side `SystemPowerSourceReporter` using IOKit power-source APIs. Malibu
  currently has `ThermalMonitor` but no equivalent app-side power monitor.

### 2.4 Relevant tests

- `phase3-binary/Tests/malibu-cliTests/ModelsSubcommandTests.swift`
  already covers status JSON, list fallback, switch progress, preflight
  rejection, server rejection, and concurrent switch rejection.
- `phase3-binary/Tests/malibu-cliTests/EndToEndAcceptanceTests.swift`
  covers warm-swap disabled behavior, control-socket permissions, atomic
  in-flight/new-request behavior, loading heartbeat, cooldown behavior, and
  `--force` guard boundaries.
- `phase3-binary/app/Tests/MalibuTests` contains app-side presenter, control,
  update, and verification tests that should be extended for this feature.

### 2.5 Lookup assumptions

- Repository searches over `SPEC-023` are noisy because the spec includes a long
  amendment history. This build spec treats the current CLI emitter in
  `AutotuneRecommend.swift` plus the active `autotune_recommend.v1` schema text
  as the implementation-grounded source for Malibu parsing.
- `models browse` output is sanitized for terminal display. If the app uses TSV
  before a JSON CLI surface exists, it must treat browse rows as display-only
  unless a trusted raw model ID is available from a CLI-owned structured source.
- `ProviderConfig.persistAutotuneRecommendation` validates and atomically writes
  recommendation-owned fields in the app, but the verified CLI `ConfigApplier`
  path additionally returns a backup path. Recommendation adoption must use the
  CLI transaction defined in this spec; app-side config writes are not
  acceptable for recommendation adoption in this feature.
- No clean-room `d-inference` source was inspected for this pass.

## 3. Goals

### BS953-G001 - No-Terminal model operations

Providers can see the current served model, compare compatible choices, and
switch or adopt a recommendation from Malibu without Terminal.

### BS953-G002 - Preserve CLI/provider authority

Malibu remains a bounded local UI and control client. The provider CLI/runtime
continues to own model validation, supported-model policy, artifact trust,
RAM/cooldown guards, warm-swap commit, serving lifecycle, credentials, and
coordinator communication.

### BS953-G003 - Operator-grade clarity

Every action must show what will change, whether it can run on this Mac, what is
blocking it, and what is happening during the switch.

### BS953-G004 - Safe, quiet recommendations

Background autotune runs at low priority, only on already-installed candidate
weights, and only when local conditions are appropriate. It never downloads or
benchmarks an uninstalled model without an explicit provider action.
Recommendations are non-intrusive, identify the CLI's top paid pick among the
installed candidates in the check scope using trusted output, show that scope in
the rationale, and require a one-tap explicit adoption.

### BS953-G005 - Config parity

Adopting an autotune recommendation from Malibu must produce the same
recommendation-owned config state as the CLI recommendation apply path for the
same `autotune_recommend.v1` result.

For MVP parity, the recommendation-owned set is the current
`ConfigApplier.recommendationOwnedKeys` set. Optional speculative-draft fields
emitted by the recommendation schema are explicitly unsupported in this tier:
they are retained and cause a visible advisory/unsupported-draft result rather
than being silently dropped or partially applied.

## 4. Non-goals and Scope Boundaries

- Do not build a second provider supervisor in Malibu.
- Do not move bearer tokens, coordinator auth, admission, billing, or settlement
  logic into Malibu.
- Do not inspect, depend on, or copy clean-room `d-inference` source.
- Do not support arbitrary Hugging Face model installation unless the CLI
  provides a signed, validated prepare/apply path for that model.
- Do not add paid-yield promises such as hourly or daily revenue estimates.
  Malibu may show rate-card rates and recommendation confidence when those are
  present in trusted recommendation output.
- Do not let `--force` become the default app path. Force-style bypasses are
  support/operator diagnostics, not normal provider UX.
- Do not require Terminal for any successful happy-path provider action in this
  feature.
- Do not show modal marketing, hero onboarding, or decorative model pages.
  This belongs in the existing utility dashboard.

## 5. Product Positioning and UX Direction

Malibu should feel like a calm operator console: compact, direct, and
trustworthy. The model switcher is not a marketplace. It is an operational tool
for selecting what this Mac can safely serve right now.

Design principles:

- Show the current model as infrastructure state, not a preference setting.
- Define "ready to switch" as locally installed weights, supported policy,
  successful fit evaluation, and a reachable compatible runtime. An `idle` row
  alone is not enough evidence that weights are present on disk.
- Split "ready to switch" from "compatible but needs preparation".
- Prefer concrete guards over vague disabled buttons.
- Show progress as phases, because the current switch interface exposes phase
  state and elapsed time, not byte-level or percent completion.
- Recommendations are hints, not commands. The user explicitly adopts them.

## 6. Information Architecture

### 6.1 Dashboard entry points

Add these dashboard and app entry points:

- A compact "Model" row in the current status area showing current model,
  runtime state, and a `Change Model...` button.
- A recommendation callout below the status area when a fresh recommendation
  exists and is the CLI's top paid pick among the installed candidates in the
  check scope rather than merely a different model.

Add an unconditional provider-facing `Settings...` entry in the Malibu menu bar
menu and dashboard overflow menu. It opens a native Settings window with a
  `Models` section and a `Background recommendations` toggle. The toggle is the
  durable source of truth for `Stop background recommendations`, includes a short explanation
that manual checks remain available, and is reachable even when the callout is
suppressed. This is a required feature surface, not a conditional fallback.

The dashboard should not become a full model catalog. Detailed selection opens a
sheet anchored from `Change Model...`.

### 6.2 Model switcher sheet

The sheet has six regions:

1. Header
   - Current model ID.
   - Runtime state: ready, loading, draining, offline, unavailable, or unknown.
   - Last recommendation check timestamp when available.
2. Model list
   - `Current`
   - `Ready to switch` (installed, supported, and fit)
   - `Needs preparation` (supported, compatible, but
     `weights_present_locally=false`; never represented as ready; an evaluated
     staging result is shown as `Evaluation complete — adopt & switch`)
   - `Recommended`
   - `Compatible online` only when supported by the current CLI/backend data.
   - `Blocked` for supported or compatible rows that cannot run because of RAM,
     thermal, cooldown, runtime, or other explicit guards.
3. Details/action pane
   - Fit, estimated size, status, source, warning/guard text, and primary CTA.

Rows must remain usable with long model IDs. Long IDs wrap or middle-truncate in
secondary text, never overflow controls.

### 6.3 Background recommendation area

The dashboard callout is low priority:

- It appears only for a fresh, actionable recommendation whose exact target is
  the CLI's top paid pick among the installed candidates in the check scope and
  differs from the current model.
- It has a primary `Adopt` button, a secondary `Not now` button, and a clearly
  labeled `Stop background recommendations` action. The durable opt-out is also exposed at
  Settings > Models > Background recommendations, where the provider can turn
  recommendations back on without Terminal.
- It includes one sentence of rationale based on trusted fields: "Top paid
  model among your installed models" for background checks, plus model name,
  fit/headroom if present, rate-card rates if present, and warnings. The
  candidate scope is shown whenever it is narrower than the full catalog. It
  must not claim that a merely different model is better.
- It never steals focus, opens automatically, or blocks serving.

`Not now` suppresses the same recommendation for 24 hours or until one of the
identity fields below changes. `Stop background recommendations` sets the same durable
provider preference as the Settings toggle and remains reversible there.
Dismissal should suppress the same recommendation key until one of these
changes:

- recommended model ID;
- current served model ID at the time of dismissal or deliberate manual
  selection;
- catalog/rate-card/demand-rank version or hash;
- visible hardware bucket from `autotune_recommend.v1`
  (`hardware.machine`, `hardware.chip`, `hardware.memory_gb`,
  `hardware.bandwidth_tier`, `hardware.detected`, `hardware.os_version`);
- binary version;
- seven days have passed.

## 7. Provider Journeys

### 7.1 View current model

1. Provider opens Malibu.
2. Dashboard shows provider health and current model.
3. If the control socket is connected, the current model comes from
   `status_response.current_model_id` / `AgentSnapshot.currentModelID`.
4. If the socket is unavailable but config is readable, show the configured
   model as "configured" and explain that live switching is unavailable.
5. If the control-socket `status_response.current_model_id` and the health /
   `AgentSnapshot.currentModelID` observation disagree, the control-socket
   observation wins during an active transaction; Malibu shows `Reconciling
   runtime state` and does not claim switch success. If disagreement persists
   after the transaction settles, show an explicit `Runtime state conflict` and
   disable new model actions until a fresh authoritative status agrees.

Acceptance:

- The provider never has to open Terminal to learn the current model.
- Unknown model state is explicit and not presented as ready.

### 7.2 Switch to a ready installed model

1. Provider clicks `Change Model...`.
2. Malibu loads current status and the ready-to-switch list.
3. Provider selects an installed, fit, supported model. An idle row without
   local weights is not shown in this region.
4. Malibu shows a confirmation summary:
   current model, target model, fit status, any warnings, and expected phase
   labels.
5. Provider clicks `Switch`.
6. Malibu invokes the launchd-managed `malibu-cli models switch --json`
   transaction. The CLI performs the existing supported-model, RAM-fit, and
   cooldown preflight, sends the typed control-socket request, and returns
   authoritative progress/rejection events. Malibu must not send a raw
   `switch_request` directly from the app; there is no alternate socket-direct
   path for ready switches.
7. Malibu shows `loading`, then `draining` if active requests are finishing, then
   `loaded`.
8. Dashboard updates the current model.

Acceptance:

- Old in-flight buyer requests complete on the old model.
- New buyer requests use the new model only after the provider runtime commits
  the loaded target.
- The app does not claim success until it observes `loaded` or an equivalent
  authoritative runtime state.

### 7.3 Adopt a recommendation

1. Malibu runs a low-priority background recommendation check when local gates
   allow it, using the `model_recommendation_check_v1` adapter with
   `--installed-only`. Background checks never download or benchmark an
   uninstalled candidate.
2. The recommendation result is parsed from `autotune_recommend.v1`. For a
   Compatible online row, Malibu runs the explicit, capability-gated
   heavyweight evaluation adapter with the exact raw ID through the same signed
   CLI/provenance gate. The provider confirms its estimated download/load/
   benchmark cost before the adapter starts. It does not add `--prefetch`: that
   flag is a receipt-only preparation path and cannot emit recommendation JSON.
3. If the recommended model is the CLI's top paid pick in the installed-only
   check scope, is actionable, and is different from the current model, Malibu
   shows a callout with that scope in its rationale.
4. Provider clicks `Adopt`.
5. Malibu invokes the CLI/runtime-owned recommendation adoption transaction
   defined by BS953-R014. Malibu does not mutate provider config directly for
   adoption.
6. The transaction validates the recommendation, prepares any required artifact,
   updates live switch authority for the transaction target, applies config under
   a journaled rollback policy, requests the live switch, and returns one
   authoritative outcome.
7. Progress and errors use the transaction progress UI.

Acceptance:

- The resulting config contains the same recommendation-owned fields the CLI
  would write for the same recommendation.
- If validation, preparation, or config apply fails, no live switch is requested.
- If switch fails after config apply, the transaction rolls back config before
  returning failure and the incumbent runtime continues serving.
- A feasible-not-installed recommendation cannot produce a config-only change or
  a rejected live switch.

### 7.4 Check recommendations manually

1. Provider opens the model switcher.
2. Provider clicks `Check Recommendations`, or selects `Evaluate this model`
   on a Compatible online row. A targeted evaluation is explicitly labeled as
   a heavyweight download/load/benchmark operation; it never silently invokes
   the receipt-only `--prefetch` path.
3. Before a targeted evaluation starts, Malibu shows the trusted estimated
   download size, expected memory/benchmark impact, current network/power and
   thermal state, free-disk check, and an honest several-minutes expectation.
   The provider explicitly confirms or cancels. No subprocess, download, model
   load, or benchmark starts before confirmation.
4. Malibu runs the capability-gated adapter from §2.3 with the exact raw ID and
   consumes its typed progress frames plus final `autotune_recommend.v1`.
   General manual `Check Recommendations` uses the same adapter with
   `--installed-only` and is limited to locally present candidates. Before that
   manual run starts, Malibu shows the installed-candidate scope, states that no
   download will occur but local weights may be loaded and benchmarked while the
   provider continues serving, shows the expected memory/benchmark impact,
   current power/thermal state, and an honest duration estimate. The provider
   explicitly confirms or cancels. No subprocess, model load, or benchmark
   starts before confirmation. An uninstalled candidate is evaluated only
   through the explicit targeted flow.
5. During the run, Malibu shows a cancellable low-priority progress state.
6. If no top paid pick differs from the current model, the UI shows "No
   different top recommendation found" in the sheet, not a dashboard callout.

Acceptance:

- Manual checks are cancellable before they mutate config.
- Manual checks may run on battery only after explicit user action and a warning.
- Targeted online evaluation never starts its subprocess, download, model load,
  or benchmark without the explicit consent described above, and it never
  treats receipt-only `--prefetch` output as recommendation JSON.

### 7.5 Revert a successful switch

After a successful manual switch or recommendation adoption, Malibu records the
previous confirmed runtime model as a reversible choice. The dashboard offers
`Revert to <previous model>` while that model remains known and policy-valid.
Revert always uses the same launchd-managed `models switch --json` transaction
and therefore the same cooldown, RAM-fit, supported-model, and serving-lifecycle
guards. If the previous model is no longer installed, Malibu must use a signed
targeted prepare/adoption transaction, show estimated download size and warnings
before confirmation, and never mutate config directly. A cooldown is shown as a
countdown-disabled revert CTA rather than hidden.

Acceptance:

- The previous confirmed model is offered for revert after a successful switch;
  the provider can see the current and previous model IDs before acting.
- Revert is disabled with an explicit cooldown countdown or guard reason and
  does not bypass CLI/runtime policy.
- If revert requires preparation, the UI discloses download/disk impact before
  confirmation and uses the same cancellable preparation and rollback contract
  as recommendation adoption.
- The previous confirmed model and its reversible-choice timestamp persist
  across Malibu relaunches until a later successful switch replaces them or the
  target becomes unsupported; the activity history records the replacement.
- If policy invalidates the previous target, retain the history entry but
  replace the CTA with `Revert unavailable: model no longer supported` and a
  link to the current supported-model explanation; do not remove the state
  silently.

## 8. Screen and State UX

### 8.1 Loading states

- Dashboard startup: show current model as "Checking..." until either control
  socket status or config fallback resolves.
- Model list load: show a table skeleton with stable row heights.
- Recommendation load: show "Checking recommendations..." only inside the sheet
  for manual runs; background runs should not show a spinner on the dashboard.
- Manual checks may take several minutes because the signed CLI loads and
  benchmarks candidates; targeted checks may also download a candidate in
  isolated staging. Show the applicable memory/benchmark impact, elapsed time,
  an honest "This may take several minutes" expectation, and a cancellable
  progress state before the check begins; do not hide this work behind a
  lightweight-sounding label. The installed-only path must say that it performs
  no downloads while still warning that local weights may be loaded and
  benchmarked.

### 8.2 Progress states

Switch progress is phase-based:

- `loading`: "Loading target model..."
- `draining`: "Finishing current request..."
- `loaded`: "Model switched"
- `failed`: use the provider-supplied reason when available.

Progress UI:

- Use an indeterminate progress indicator unless a future CLI provides bytes or
  percent.
- Show elapsed time when available from `elapsed_ms`.
- Keep the current and target model IDs visible throughout.
- Disable conflicting switch actions while a switch is active.
- Announce loading, draining, loaded, rollback, failure, and completion phase
  transitions through the accessible live region. If an accepted switch has no
  new phase for 30 seconds, show "Still working; the provider is finishing this
  switch" with elapsed time and the `Keep in Background` recovery path; do not
  offer a false cancellation control.
- Recommendation-check progress uses
  `model_recommendation_check_event.v1` phases `planning`, `preparing`,
  `downloading`, `benchmarking`, `completed`, `failed`, and `cancelled`. It
  reports candidate ID, elapsed time, and byte totals when known. Malibu shows
  this progress and a real `Cancel check` action before adoption. Malibu sends
  an adapter cancel request; the CLI owns staging allocation and deletion,
  emits the terminal event, and reports cleanup. If the app must terminate a
  wedged subprocess, the CLI cleanup hook owns post-exit cleanup; Malibu
  verifies cleanup and reports a diagnostic but never races the CLI by deleting
  the directory itself.
- Recommendation checks must never repair, replace, or delete the canonical
  live-provider snapshot. Staging artifacts are promoted only by the
  BS953-R014 adoption transaction after validation; failed/cancelled checks
  discard staging and leave the incumbent provider cache untouched. If the
  CLI cannot provide this isolation, `model_recommendation_check_v1` is absent
  and Malibu disables the check action with update guidance.
- A targeted manual check has a 15-minute default wall-clock budget per
  candidate. On timeout the adapter emits a terminal `failed` event with
  `reason: "recommendation_check_timeout"`, removes staging, and Malibu offers
  retry; it never leaves an indeterminate check or partial artifact behind.
- For recommendation adoption, use the BS953-R014 transaction progress stream.
  Artifact preparation/download is an existing signed CLI/runtime phase owned
  by that transaction; Malibu must not implement a second downloader. If the
  implementation reuses the CLI's receipt-only prefetch helper, it must pass
  `--prefetch --prefetch-receipt <private-receipt-path>` and consume the receipt
  as preparation input, never as `autotune_recommend.v1`. Byte totals are shown
  only when the transaction phase reports them.
  `download_bytes_written` and `download_bytes_total` are mandatory when an
  artifact download/preparation step knows the byte total; otherwise the UI must
  explicitly show phase progress without percent and must not invent byte
  progress.
- Show Wi-Fi/network and disk-space warnings before the transaction enters a
  non-cancellable config or runtime commit phase.
- For targeted Compatible online evaluation, show the trusted estimated size,
  network/power state, and free-disk result before any CLI-reported local
  preparation begins. The label and confirmation must make clear whether the
  targeted check will prepare an artifact. The receipt-only `--prefetch` path
  is not used as the evaluation result; adoption warnings are repeated before
  the BS953-R014 preparation phase.

### 8.3 Cancel states

Current repo support does not include a `switch_cancel_request` control frame.
This spec accepts phase-only progress and no accepted-switch cancellation for
ready installed model switches in the MVP, because current frames expose only
`switch_ack` and phase `switch_progress`. Recommendation adoption adds a
runtime-owned cancel/progress contract before any config/runtime commit.
Therefore:

- Before the user clicks `Switch` or `Adopt`, `Cancel` closes the confirmation
  and no request is sent.
- While `models browse` or recommendation-check adapter work is running,
  `Cancel` sends `model_recommendation_check_command.v1` on the app-owned
  subprocess stdin and waits for the terminal event. If the subprocess is
  unresponsive, Malibu terminates it only after the adapter cleanup deadline;
  the CLI cleanup hook owns staging deletion and config remains unchanged.
- During recommendation adoption phases marked `cancellable: true`, `Cancel`
  sends the app-to-CLI `model_adoption_command.v1` cancel input defined in
  BS953-DC004. The CLI then sends
  `recommendation_apply_switch_cancel_request` to the runtime and waits for
  `recommendation_apply_switch_cancel_ack` before emitting the terminal
  cancellation event.
- After a switch request or recommendation adoption commit phase is accepted by
  the provider runtime, Malibu must not
  kill the provider process to cancel. The button becomes `Close` or
  `Keep in Background`, and Malibu continues observing switch progress.
- Malibu must never show a `Cancel switch` button after the transaction reports
  `cancellable: false`.

### 8.4 Success state

On successful switch:

- The sheet shows "Model switched" and the target model becomes the current row.
- The dashboard current model updates.
- The adopted recommendation callout is dismissed.
- Any cooldown timer starts from the provider/CLI-reported cooldown state.

### 8.5 Failure and guard states

Malibu must map known guard states to explicit UI:

| Condition | Source | UX |
|---|---|---|
| Cooldown | authoritative `models switch --json` CLI event or adoption transaction | Disable action, show seconds remaining, retry only when the user clicks after countdown. |
| RAM wont fit | authoritative CLI preflight or adoption transaction; browse fit is advisory | Block switch/adoption and explain required vs available memory when available. |
| RAM unknown | CLI preflight / browse fit | Block by default for paid/automatic paths. Manual support override is out of MVP scope. |
| Unsupported target | `not_in_supported_models` or preflight | Disable row or show "Not in this provider's supported model list." |
| Offline | browse/recommend network failure or status unavailable | Keep current model visible; defer background recommendation; allow retry. |
| Busy serving | runtime `draining`, in-flight request evidence | Show "Finishing current request"; do not imply failure. |
| Concurrent switch | `loading_in_progress` | Disable actions and show the current target if provided. |
| Battery | MalibuPowerMonitor using IOKit power-source APIs | Defer or cancel background recommendation; manual check allowed only after explicit warning acknowledgement. |
| Unknown/stale power | MalibuPowerMonitor sample missing or older than 10s | Fail closed for background recommendation; require fresh sample before start. |
| Thermal pressure | app `ThermalMonitor` or SPEC-023 hard block | Defer background recommendation; block paid adoption when recommendation says thermal throttle. |
| Evaluation benchmark impact | `model_recommendation_check_event.v1` plan/fit/phase data | Manual evaluation discloses download, memory load, benchmark, and expected duration before start; background is installed-only and skips candidates that would require preparation. |
| Download/disk concern | estimated GB / artifact plan / free-space check | Warn before any CLI-reported targeted-evaluation preparation and before BS953-R014 adoption preparation if estimated size is material or free space is tight. |
| Warm swap unavailable | missing/refused control socket | Show view-only configured model and explain switching is unavailable until provider is running with warm-swap support. |
| CLI incompatible | missing command/schema/control frames | Hide switch controls and show update guidance. |
| No recommendation | `recommended_model: null` | Quiet sheet result; no dashboard callout. |
| Stale recommendation | SPEC-023 stale warnings or changed versions | Require rerun before adoption. |
| Rollback failed | adoption transaction `rollback_state=rollback_failed` | Keep incumbent model visible, explain that config recovery needs attention, offer `Retry recovery` through the CLI transaction, and provide existing repair/support guidance; never silently claim success. |

The dashboard also includes a non-modal `Model activity` status line. It shows
the last recommendation check outcome and timestamp, including a provider-safe
skip reason such as `Skipped: on battery` or `Next check after cooldown` when a
background run was gated. The switcher offers a compact local history of the
last successful or failed switch, adoption, and revert (timestamp, from/to
IDs, phase/outcome, and guard reason when applicable). This is diagnostic UI,
not remote telemetry, and is retained only under the same redaction rules as
other local app state.

## 9. Data and State Contracts

### BS953-DC001 - Model row

Malibu should normalize all model choices into an internal app row:

```text
id: String
displayID: String
category: current | ready | needsPreparation | recommended | compatibleOnline | blocked
source: controlSocket | modelsList | modelsBrowse | autotuneRecommend | configFallback
runtimeState: warm | idle | feasible | unavailable | unknown
weightsPresentLocally: Bool
evaluationComplete: Bool
fit: fits | tight | wontFit | unknown | notProvided
estimatedGB: Decimal?
promptRateUSDPerMillionTokens: Decimal?
completionRateUSDPerMillionTokens: Decimal?
confidence: String?
warnings: [String]
blockReason: BlockReason?
action: none | switch | prepareAndSwitch | adoptRecommendation | rerunRecommendation
```

An evaluated candidate remains `needsPreparation` when its check artifacts are
only in isolated staging or when it is not in supported policy. Its row may show
`evaluationComplete=true` in app-only state, but it never becomes `ready` or
switchable until the signed adoption transaction succeeds.

The UI must not compare model IDs after presentation truncation. All actions use
the full exact model ID.

Action IDs must come only from trusted structured sources: control socket
`status_response.current_model_id`, strict `models list` parsing,
`models_list.v1.action_model_id`, or `autotune_recommend.v1.recommended_model`
plus matching `serve_config.model`. Both TSV and JSON browse rows are
display/advisory only and never provide action IDs.

State presentation mapping is normative: `warm` maps to Current/ready runtime;
`idle` maps to a candidate and requires `weightsPresentLocally` before Ready;
`feasible` maps to Compatible online or Needs preparation; `loading` and
`draining` map to the active switch phases; `unavailable`/`unknown` map to
view-only or Blocked. Header labels may be provider-friendly, but they must
retain this mapping.

### BS953-DC001A - Model catalog JSON capability

`model_catalog_json_v1` is the single canonical capability name for both
`models list --json` and `models browse --json`. The name `models_list_json_v1`
is not a valid capability in this spec and must not appear in the capability
manifest, local status, tests, or implementation.

Both JSON commands are new contracts. They preserve existing TSV behavior when
`--json` is absent. With `--json`, stdout contains exactly one UTF-8 JSON object
and no table/header text; diagnostics and human-readable errors go to stderr.
On command errors, the CLI exits non-zero and either writes no stdout or writes
one error object matching:

```json
{"schema_version":"model_catalog_error.v1","command":"models list|models browse","code":"offline|invalid_argument|socket_unavailable|incompatible_peer|internal","message":"safe human-readable summary"}
```

`model_catalog_error.v1` required fields and types:

- `schema_version`: required string, exactly `"model_catalog_error.v1"`.
- `command`: required enum, `models list` or `models browse`.
- `code`: required enum, `offline`, `invalid_argument`, `socket_unavailable`,
  `incompatible_peer`, or `internal`.
- `message`: required non-empty string safe for UI/log display after existing
  repo redaction policy.

Malibu treats non-zero exit, malformed JSON, unknown `schema_version`, missing
required fields, invalid enum values, invalid nullability, overlong IDs, or
control characters in action IDs as fail-closed for the affected feature tier.
Unknown extra JSON fields are allowed for forward compatibility and must be
ignored by Malibu; required fields and enum meanings remain stable.

### BS953-DC001B - `models list --json` schema

`models list --json` emits `schema_version: "models_list.v1"` and is covered by
`model_catalog_json_v1`.

Top-level object:

```json
{
  "schema_version": "models_list.v1",
  "generated_at": "2026-08-08T00:00:00Z",
  "source": "control_socket|config_fallback",
  "warm_swap_available": true,
  "current_model_id": "hf/current-or-null",
  "rows": [
    {
      "model_id": "hf/raw-action-id",
      "display_id": "hf/display-id",
      "action_model_id": "hf/raw-action-id",
      "state": "warm|idle",
      "weights_present_locally": true,
      "source": "status_response|supported_models|config_fallback",
      "fit": "fits|tight|wont_fit|unknown|null",
      "estimated_gb": 8.0
    }
  ]
}
```

Required top-level fields and types:

- `schema_version`: required string, exactly `"models_list.v1"`.
- `generated_at`: required RFC 3339/ISO-8601 UTC string.
- `source`: required enum, `control_socket` or `config_fallback`.
- `warm_swap_available`: required boolean. It is `false` when current behavior
  would print warm-swap-disabled fallback rows.
- `current_model_id`: required string or null. It is the current runtime model
  from `status_response.current_model_id` when the socket is connected; otherwise
  null unless the CLI can only report configured fallback state.
- `rows`: required array.

Required row fields and types:

- `model_id`: required string. This is the raw exact model ID from the effective
  supported-model/config/status surface and is never presentation-truncated.
- `display_id`: required string. This is the UI-safe display value and may equal
  `model_id`; Malibu must not use it as an action ID.
- `action_model_id`: required string. It must equal `model_id` after exact byte
  comparison and is the only row field Malibu may pass to ready-switch actions.
- `state`: required enum, `warm` or `idle`, matching current TSV behavior.
- `weights_present_locally`: required boolean from the runtime/CLI artifact
  inventory. It is true only when the exact target artifact snapshot and hash
  required by `ModelRuntime.loadLocalContainer` are present on local disk.
  `warm` implies true; `idle` does not.
- `source`: required enum, `status_response`, `supported_models`, or
  `config_fallback`.
- `fit`: required enum or null, `fits`, `tight`, `wont_fit`, `unknown`, or null.
  It is null when the list command did not perform fit evaluation.
- `estimated_gb`: required number or null. It is null when the current list
  command has no estimate.

Validation:

- `model_id` and `action_model_id` must be non-empty, no more than
  `SupportedModels.maxEntryByteLength` UTF-8 bytes, and contain no tabs,
  newlines, C0 controls, C1 controls, or DEL.
- `display_id` may be sanitized for presentation but must be non-empty and must
  not be used for actions.
- There must be at most one `warm` row. If `current_model_id` is non-null and a
  `warm` row is present, they must match exactly.
- Malibu maps a row to Ready to switch only when `weights_present_locally` is
  true, `fit` is `fits`, the target is in effective supported policy, and the
  runtime is reachable. An idle row with false weights presence is a
  preparation candidate, never a bare `Switch` target.

### BS953-DC001C - `models browse --json` schema

`models browse --json` emits `schema_version: "models_browse.v1"` and is covered
by `model_catalog_json_v1`.

Top-level object:

```json
{
  "schema_version": "models_browse.v1",
  "generated_at": "2026-08-08T00:00:00Z",
  "source": "huggingface_mlx_community",
  "query": "qwen",
  "limit": 30,
  "fits_only": false,
  "max_gb": null,
  "ram_gb": 24,
  "rows": [
    {
      "model_id": "mlx-community/raw-model-id",
      "display_id": "mlx-community/display-id",
      "action_model_id": null,
      "source": "huggingface_mlx_community",
      "fit": "fits|tight|wont_fit|unknown",
      "estimated_gb": 8.0,
      "actionable": false
    }
  ]
}
```

Required top-level fields and types:

- `schema_version`: required string, exactly `"models_browse.v1"`.
- `generated_at`: required RFC 3339/ISO-8601 UTC string.
- `source`: required enum, exactly `huggingface_mlx_community`.
- `query`: required string or null, reflecting `--family`.
- `limit`: required integer, matching the bounded command input.
- `fits_only`: required boolean.
- `max_gb`: required integer or null.
- `ram_gb`: required integer.
- `rows`: required array.

Required row fields and types:

- `model_id`: required string. This is the raw HuggingFace model ID returned by
  the CLI after JSON-contract validation, not the terminal-sanitized TSV cell.
- `display_id`: required string. This is the UI-safe display value.
- `action_model_id`: required null for `models_browse.v1`. Browse rows are
  compatible-online/advisory rows, not switch/adoption action rows.
- `source`: required enum, exactly `huggingface_mlx_community`.
- `fit`: required enum, `fits`, `tight`, `wont_fit`, or `unknown`, matching
  current TSV fit labels.
- `estimated_gb`: required number or null. It is null when current TSV would
  print `?`.
- `actionable`: required boolean, exactly false.

Validation:

- `model_id` must be non-empty, no more than `SupportedModels.maxEntryByteLength`
  UTF-8 bytes, and contain no tabs, newlines, C0 controls, C1 controls, or DEL.
- `display_id` may be sanitized for presentation but must not be used for
  actions.
- Malibu must not convert `model_id` into an action ID for browse rows. A browse
  result becomes actionable only through a fresh `autotune_recommend.v1` result
  and BS953-R014 transaction capability.

### BS953-DC002 - Switch transaction

Minimum switch transaction state:

```text
id: UUID
source: manualSwitch
fromModelID: String?
targetModelID: String
startedAt: Date
phase: confirming | requested | loading | draining | loaded | failed | dismissedObserving
elapsedMs: Int?
ackReason: String?
failureReason: String?
cooldownSecondsRemaining: Int?
configApplyState: notNeeded | pending | applied | failed | rolledBack | rollbackFailed
```

The app stores only enough local state to render current in-progress UI, the
reversible previous-model choice, recommendation settings, and a small redacted
activity history. The provider runtime remains authoritative for live model
state.

Recommendation adoption uses the separate `model_adoption_event.v1` reducer in
BS953-DC004; it is not represented by the ready-switch `BS953-DC002` phase
enum.

The local activity history is bounded and contains only timestamp, operation
(`switch`, `adopt`, or `revert`), exact from/to model IDs, phase/outcome, and a
provider-safe guard/failure reason. It contains no hardware identifiers,
secrets, tokens, or raw CLI output. A successful switch replaces the revert
target; app relaunch restores the last valid target and history entries.

### BS953-DC003 - Recommendation cache

The app may store a local recommendation UI cache under Malibu application
support, or use existing `~/.config/macprovider/last-recommendation.json` plus
app preferences. Stored UI cache must not contain raw hardware identifiers,
secrets, bearer tokens, provider private keys, or unsanitized logs.

Minimum recommendation identity key:

```text
recommendedModelID
serveConfig.modelCatalogHash or inputs.candidateCatalogVersion
inputs.rateCardVersion
inputs.demandRankVersion
hardware.machine
hardware.chip
hardware.memoryGB
hardware.bandwidthTier
hardware.detected
hardware.osVersion
hardware.binaryVersion
currentServedModelID
```

`appDismissedAt` is dismissal metadata, not recommendation identity. Store it
separately with the local action that caused suppression (`notNow`,
`dontSuggestAgain`, or `manualChoice`) and never include that mutable timestamp
in the identity hash. A deliberate manual choice records the current served
model and suppresses a repeat prompt for the same recommendation while that
choice remains current.

Store the durable provider preference separately as
`backgroundRecommendationsEnabled: Bool`, defaulting to true. The Settings
toggle and callout action read/write this value; it is not part of the
recommendation identity hash and never disables manual checks.

Malibu must not read hidden/upload-only payloads such as stored
`hardware_identity_hash` for UI dedupe. If a future visible schema adds a stable,
privacy-approved hardware hash, using it requires a new schema/capability AC.

### BS953-DC003A - Targeted Compatible online evaluation

When a provider selects `Evaluate this model` for a Compatible online row,
Malibu invokes the capability-gated signed check adapter with the exact raw
browse ID:

```text
malibu-cli autotune --recommend --json \
  --candidate-models <exact-raw-model-id> \
  --check-only --progress-json \
  --isolated-cache-root <private-staging-root> \
  --config <config.yaml>
```

The required adapter evaluates only the requested candidate, emits typed
`model_recommendation_check_event.v1` progress frames, and emits a final
`autotune_recommend.v1`. It must not substitute the default candidate list,
write the canonical live-provider snapshot, or mutate config. Malibu makes the
row Recommended only when `recommended_model` and `serve_config.model` both
exactly equal the selected raw ID and no unsupported draft fields are present.
The provider's pre-check confirmation covers the adapter's download, memory,
and benchmark work. BS953-R014 owns the separate signed serve-artifact
preparation (reusing isolated staging when valid), receipt/phase handling,
config parity, and rollback transaction. A null recommendation, a different
recommended model, a non-null unsupported draft field, or a failed/stale result
leaves the row advisory and explains the reason without mutating config.

### BS953-DC003B - Recommendation-check progress events

The `model_recommendation_check_v1` adapter emits newline-delimited JSON before
the final recommendation:

```json
{"schema_version":"model_recommendation_check_event.v1","type":"accepted","check_id":"uuid","candidate_model_id":"hf/model","isolated_cache_root":"redacted","staging_owner":"cli","cancellable":true}
{"schema_version":"model_recommendation_check_event.v1","type":"progress","check_id":"uuid","candidate_model_id":"hf/model","phase":"planning|preparing|downloading|benchmarking","elapsed_ms":123,"cancellable":true,"download_bytes_written":1048576,"download_bytes_total":8388608}
{"schema_version":"model_recommendation_check_event.v1","type":"cancelled","check_id":"uuid","candidate_model_id":"hf/model","reason":"provider_requested|power_changed","staging_discarded":true}
{"schema_version":"model_recommendation_check_event.v1","type":"failed","check_id":"uuid","candidate_model_id":"hf/model","reason":"recommendation_check_timeout|download_failed|benchmark_failed|unsupported_draft","staging_discarded":true}
```

Malibu sends cancellation on the adapter command's stdin as a separate input
frame, not by deleting files:

```json
{"schema_version":"model_recommendation_check_command.v1","type":"cancel","check_id":"uuid","requested_at_ms":123}
```

The final `autotune_recommend.v1` is emitted only after the check succeeds.
Staging paths are redacted from UI and logs. The CLI allocates a unique child
under the private root, owns all staging cleanup, and must remove it on
completed, failed, cancelled, timeout, or process-signal recovery. Background
invocations must carry `installed_only=true` in the accepted event and may not
emit a download phase.

### BS953-DC004 - Recommendation apply-and-switch command

Recommendation adoption is owned by one CLI/runtime transaction. The required
CLI surface is:

```text
malibu-cli models adopt-recommendation \
  --json \
  --config <config.yaml> \
  --recommendation-json <path-or-stdin> \
  --ctl-socket-path <socket-path>
```

The command output is newline-delimited JSON frames on stdout. It must exit zero
only after both live runtime model and recommendation-owned config fields match
the adopted target. It must exit non-zero for validation, preparation, config,
switch, rollback, cancellation, capability, or provenance failures.

Required command frame schemas:

```json
{"schema_version":"model_adoption_event.v1","type":"accepted","transaction_id":"uuid","target_model_id":"hf/model","from_model_id":"hf/current","cancellable":true}
{"schema_version":"model_adoption_event.v1","type":"progress","transaction_id":"uuid","phase":"validating|preparing_artifact|downloading|config_backup|config_apply|switch_loading|switch_draining|config_verify|rollback|completed|failed|cancelled","elapsed_ms":123,"cancellable":true,"download_bytes_written":1048576,"download_bytes_total":8388608,"reason":null}
{"schema_version":"model_adoption_event.v1","type":"completed","transaction_id":"uuid","target_model_id":"hf/model","config_sha256":"hex","backup_path":"redacted-or-null"}
{"schema_version":"model_adoption_event.v1","type":"failed","transaction_id":"uuid","phase":"switch_loading","reason":"not_in_supported_models","rollback_state":"not_needed|rolled_back|rollback_failed","incumbent_model_id":"hf/current"}
{"schema_version":"model_adoption_event.v1","type":"cancelled","transaction_id":"uuid","phase":"preparing_artifact|downloading|config_backup|config_apply|switch_loading|switch_draining","reason":"provider_requested|power_changed","rollback_state":"not_needed|rolled_back|rollback_failed","incumbent_model_id":"hf/current"}
```

The `models adopt-recommendation --json` subprocess accepts this app-to-CLI
stdin command while the transaction is cancellable:

```json
{"schema_version":"model_adoption_command.v1","type":"cancel","transaction_id":"uuid","requested_at_ms":123}
```

The CLI validates the transaction ID and phase, translates the input into the
typed CLI-to-runtime `recommendation_apply_switch_cancel_request`, waits for
`recommendation_apply_switch_cancel_ack`, and then emits exactly one terminal
`cancelled` event. Malibu never sends runtime frames directly.

`cancelled` is a terminal frame, distinct from a progress frame whose phase is
`cancelled`. It is emitted only when the cancellation acknowledgement has
completed; Malibu treats it as a non-success outcome and keeps the incumbent
model visible.

`download_bytes_written` and `download_bytes_total` are required for download
phases when the runtime knows the total. They must be omitted or null when the
runtime cannot know the total; Malibu then shows no percent.

### BS953-DC005 - Recommendation apply-and-switch control frames

The CLI command must use typed runtime frames rather than app-side policy:

```json
{"type":"recommendation_apply_switch_prepare_request","schema_version":"model_recommendation_apply_switch.v1","transaction_id":"uuid","requested_at_ms":123,"target_model_id":"hf/model","expected_current_model_id":"hf/current","recommendation_sha256":"hex","serve_config":{"model":"hf/model","model_artifact_path":"...","model_artifact_sha256":"hex","model_catalog_key":"...","model_catalog_model_id":"...","model_catalog_revision":"...","model_catalog_sha256":"hex","model_catalog_version":"...","model_catalog_hash":"hex","kv_bits":4,"max_context_override":4096,"max_concurrency_override":1,"donor_mode":false,"draft_model":null,"draft_model_artifact_sha256":null}}
{"type":"recommendation_apply_switch_prepare_ack","transaction_id":"uuid","accepted":true,"reason":null,"cancellable":true}
{"type":"recommendation_apply_switch_progress","transaction_id":"uuid","phase":"validating|preparing_artifact|downloading|authority_ready|switch_loading|switch_draining|loaded|failed|cancelled","elapsed_ms":123,"cancellable":true,"download_bytes_written":1048576,"download_bytes_total":8388608,"reason":null}
{"type":"recommendation_apply_switch_cancel_request","transaction_id":"uuid","requested_at_ms":123}
{"type":"recommendation_apply_switch_cancel_ack","transaction_id":"uuid","accepted":true,"reason":null}
```

Runtime validation order is normative:

1. Validate frame schema and transaction UUID idempotency.
2. Validate `target_model_id` byte length, control-character absence, and exact
   match to `serve_config.model`.
3. Validate recommendation hash and signed catalog/artifact identifiers through
   existing CLI/autotune trust policy.
4. Validate RAM, disk, cooldown, active switch, and incumbent model expectation.
5. Prepare/download artifacts and emit byte progress when known.
6. Add a transaction-scoped live switch authority entry for the exact target.
7. Accept the switch and load/drain through the runtime.

`draft_model` and `draft_model_artifact_sha256` are optional input fields for
schema completeness. In the MVP they must be null or absent for an adoption to
be accepted; a non-null draft produces `unsupported_draft` before config
mutation. The parser retains the values for diagnostics, so unsupported draft
fields cannot be silently dropped while claiming config parity.

The transaction-scoped authority entry must not make arbitrary browse results
globally supported. It is valid only for the transaction ID, target model,
recommendation hash, and serve config that passed validation.

### BS953-DC006 - Adoption transaction journal and rollback state

The CLI command must create a local journal before mutating config:

```text
~/.config/macprovider/model-adoption-transactions/<transaction-id>.json
```

The journal is mode `0600`, contains no bearer token/provider private key/raw
hardware identifiers/HMAC secrets, and records:

```text
transactionID
phase
fromModelID
targetModelID
recommendationSHA256
configPath
preApplyConfigSHA256
postApplyConfigSHA256?
redactedBackupPath
recommendationOwnedFieldsBefore
recommendationOwnedFieldsAfter
runtimeCommitObserved: Bool
rollbackState: notNeeded | pending | rolledBack | rollbackFailed
updatedAt
```

Recovery is deterministic:

- If the journal has no `runtimeCommitObserved`, restart recovery rolls back the
  recommendation-owned fields to `recommendationOwnedFieldsBefore` and verifies
  byte/field parity before marking the journal `rolledBack`.
- If `runtimeCommitObserved` is true, restart recovery verifies that local status
  current model and config recommendation-owned fields both match the target
  before marking `completed`; otherwise it enters rollback and reports
  `rollback_failed` if incumbent continuity cannot be proven.
- Re-running the same command with the same recommendation hash and target after
  a completed transaction returns completed without reapplying config. Re-running
  after a rolled-back failure starts a new transaction ID.

## 10. Requirements and Acceptance Criteria

### BS953-R001 - Current model visibility

Malibu MUST show the current runtime model in the dashboard when the provider
control socket is connected.

Acceptance:

- BS953-AC001: Given `status_response.current_model_id = X`, dashboard shows X.
- BS953-AC002: Given no socket but readable config `model = Y`, dashboard shows
  Y as configured, not as live-ready.
- BS953-AC003: Given malformed or unknown control frames, Malibu recovers by
  reattaching per SPEC-025 and does not display stale success state.
- BS953-AC003A: If live status and health observations disagree, the app shows
  `Reconciling runtime state`/`Runtime state conflict`, treats control-socket
  status as authoritative during a transaction, disables new actions until the
  conflict resolves, and never presents a false successful switch.

### BS953-R002 - Ready-to-switch model list

Malibu MUST list ready-to-switch models from the effective supported-model
surface, with current model separated from idle candidates.

Acceptance:

- BS953-AC004: `models list` row state `warm` maps to Current.
- BS953-AC005: A row maps to Ready to switch only when
  `weights_present_locally = true`, state is `warm|idle`, fit is `fits`, the
  target is supported, and the runtime is reachable. `idle` alone never proves
  local installation.
- BS953-AC005A: An idle supported row with
  `weights_present_locally = false` is shown as preparation-required, never as
  a one-tap `Switch` target; it appears in `Needs preparation`, and tapping it
  opens `Evaluate this model`, the same explicit heavyweight
  download/load/benchmark flow as a Compatible online row. After a matching
  recommendation result, the row changes to `Adopt & switch` and uses BS953-R014;
  there is no untracked download-only `Prepare & switch` path. The receipt-only
  `--prefetch` path is not treated as the recommendation result.
- BS953-AC006: Long model IDs do not overflow the sheet at narrow macOS window
  widths.
- BS953-AC007: If warm-swap is disabled, the sheet becomes view-only and says
  why.

### BS953-R003 - Compatible online models are not silently switchable

Malibu MUST NOT present `models browse` results as one-tap switchable. A browse
result becomes actionable only after a fresh `autotune_recommend.v1` result and
the BS953-R014 transaction validate that exact model.

Acceptance:

- BS953-AC008: A browse row with `fits` but absent from supported models is
  labeled Compatible online, not Ready to switch.
- BS953-AC009: Clicking a compatible-online row offers `Evaluate this model`,
  shows the estimated download/load/benchmark cost and explicit confirmation
  before any work starts, and then runs the
  `--check-only --progress-json --isolated-cache-root` adapter with
  `--candidate-models <exact-raw-id>` through the signed CLI, without sending
  `switch_request`, invoking receipt-only `--prefetch`, or substituting the
  default candidate list.
- BS953-AC010: No arbitrary HF result is written into config without signed
  catalog/artifact validation owned by existing CLI/autotune policy.
- BS953-AC010A: A targeted evaluation becomes Recommended only when the output
  `recommended_model` and `serve_config.model` exactly match the selected raw
  model ID; null, different, stale, or failed results remain advisory.
- BS953-AC010B: If `serve_config.draft_model` or
  `serve_config.draft_model_artifact_sha256` is non-null, the result remains
  advisory with an explicit unsupported-draft reason; the fields are retained
  for diagnostics and never silently discarded.

### BS953-R004 - Manual switch

Malibu MUST let providers switch from the current model to a ready supported
model using a CLI/runtime-owned transaction.

Acceptance:

- BS953-AC011: Successful switch shows loading/draining/loaded progress and then
  updates current model.
- BS953-AC012: A concurrent switch returns a clear busy state and prevents
  duplicate action.
- BS953-AC013: Cooldown rejection shows seconds remaining and disables the CTA
  until the cooldown expires.
- BS953-AC014: Unsupported target rejection shows the exact unsupported reason
  and does not retry automatically.
- BS953-AC015: Load failure shows provider-supplied failure reason when present.
- BS953-AC015A: Every Malibu-initiated ready switch goes through the CLI-owned
  `models switch --json` preflight. Tests prove cooldown and RAM-unfit targets
  are rejected before a raw control-socket switch request can be accepted.

### BS953-R005 - Busy-serving safety

Malibu MUST represent `draining` as active work finishing, not as a stuck or
failed switch.

Acceptance:

- BS953-AC016: If a buyer request is in flight, Malibu shows "Finishing current
  request" during draining.
- BS953-AC017: UI copy states that the new model becomes active after the
  runtime commit.
- BS953-AC018: New switch actions are disabled during draining.

### BS953-R006 - Recommendation scheduler

Malibu MUST run background recommendation checks at low priority and only under
safe local conditions.

Acceptance:

- BS953-AC019: Background checks do not run while on battery by default.
- BS953-AC020: Background checks do not run during serious/critical thermal
  state.
- BS953-AC021: Background checks do not start while another switch or
  recommendation check is active.
- BS953-AC022: Background checks use backoff after network or CLI failures.
- BS953-AC023: Background checks never surface a modal or steal focus.
- BS953-AC023A: Background checks use the capability-gated recommendation-check
  adapter with `installed_only=true`; they skip every candidate whose
  `weights_present_locally=false` and never download, load, or benchmark an
  uninstalled candidate. If that adapter capability is missing, background
  checks remain disabled with a provider-visible status reason.
- BS953-AC023B: Providers can select `Stop background recommendations` from the callout and
  the unconditional Settings > Models > Background recommendations toggle
  exposes the same durable preference and lets a provider turn it back on
  without Terminal; `Not now` remains a reversible 24-hour snooze.
- BS953-AC023C: The dashboard status line shows the last recommendation check
  outcome and timestamp, plus a provider-safe skip reason and next eligible
  time when background gates prevent a check; the switcher exposes a compact
  redacted local activity history for switch, adoption, and revert outcomes.

Required default schedule:

- First check: after the provider has reached a stable serving/ready state and
  the Mac is on AC power with nominal/fair thermal state.
- Recurrence: at most once every 24 hours.
- Backoff: 1 hour after transient network/CLI failure, doubling to 24 hours.
- Quiet hours: do not wake the display or open windows.

### BS953-R007 - Recommendation parsing and ranking

Malibu MUST parse only `schema_version: "autotune_recommend.v1"` for background
recommendations.

Acceptance:

- BS953-AC024: Unknown schema versions are ignored with a local diagnostic.
- BS953-AC025: `recommended_model: null` produces no dashboard callout.
- BS953-AC026: Thermal/swap hard-block warnings from SPEC-023 block paid
  adoption.
- BS953-AC027: Candidate rates and confidence are displayed only when present.
- BS953-AC028: Warnings are surfaced in the details pane before adoption.

### BS953-R008 - One-tap recommendation adoption

Malibu MUST provide one-tap adoption for actionable recommendations after the
recommendation has passed the BS953-R014 CLI/runtime transaction.

Acceptance:

- BS953-AC029: `Adopt` invokes
  `malibu-cli models adopt-recommendation --json` and consumes only
  `model_adoption_event.v1` frames for recommendation adoption.
- BS953-AC030: If recommendation validation, artifact preparation, or config
  apply fails, no live switch request is sent.
- BS953-AC031: If switch succeeds and config parity verification succeeds,
  current model and recommendation dismissal state update.
- BS953-AC032: If switch fails after config apply, the transaction rolls back
  recommendation-owned config fields before returning failure; Malibu shows
  `rolledBack` or `rollbackFailed`, never ambiguous staged-for-restart copy.
- BS953-AC033: Adoption never writes fields outside the recommendation-owned
  serve-config set.
- BS953-AC034: A feasible-not-installed recommendation is not actionable unless
  the CLI/runtime advertises `model_recommendation_apply_switch_v1`; without
  that capability Malibu shows it as advisory and does not mutate config.

### BS953-R009 - Cancel semantics

Malibu MUST be honest about what can be cancelled.

Acceptance:

- BS953-AC035: Confirmation cancellation sends no switch request.
- BS953-AC036: Browse/recommendation cancellation terminates the app-owned
  subprocess and leaves config unchanged.
- BS953-AC037: During recommendation adoption, cancel is shown only while
  transaction frames report `cancellable: true`; cancel sends the
  `model_adoption_command.v1` app-to-CLI input, and the CLI sends
  `recommendation_apply_switch_cancel_request` and waits for the runtime ack.
- BS953-AC038: After switch ack acceptance or any adoption frame with
  `cancellable: false`, Malibu does not present a false `Cancel switch` button.

### BS953-R010 - Offline and incompatible modes

Malibu MUST degrade safely when CLI, network, or control-socket capabilities are
missing.

Acceptance:

- BS953-AC039: Offline browse/recommendation failures keep current model visible.
- BS953-AC040: Missing installed CLI disables recommendation checks and provides
  update/repair guidance consistent with existing Malibu update UX.
- BS953-AC041: Missing control socket disables live switching but still allows
  view-only configured model state.
- BS953-AC042: Stale or mismatched CLI/runtime peers disable the affected feature
  tier and show update/repair guidance without hiding the current model.

### BS953-R011 - Privacy and telemetry

Malibu MUST not add remote analytics or leak provider-sensitive fields.

Acceptance:

- BS953-AC043: No bearer token, provider private key, serial number, MAC address,
  UUID, raw hardware fingerprint, or HMAC secret appears in UI cache, logs, or
  support output.
- BS953-AC044: Recommendation network behavior remains the existing CLI/autotune
  behavior, not app-added coordinator telemetry.
- BS953-AC045: Local diagnostics redact paths and identifiers where existing
  repo policy requires redaction.

### BS953-R012 - Accessibility and localization

Malibu MUST keep the entire reachable model-switching path accessible and
localizable: the dashboard Model row and entry CTA, sheet, rows, callouts,
confirmation, progress, guard/error states, revert CTA, and background opt-out.

Acceptance:

- BS953-AC046: The dashboard entry point plus all buttons, progress indicators,
  model rows, callouts, revert controls, and guard/error states have meaningful
  VoiceOver labels and hints, so a VoiceOver user can reach and operate the
  feature from the dashboard.
- BS953-AC047: State is conveyed with text and/or an icon plus an accessible
  label, never by color alone; new feature errors must not reuse the existing
  red-text-only idiom.
- BS953-AC048: Keyboard users can open the sheet, navigate rows, confirm, and
  dismiss without a pointer.
- BS953-AC049: The feature adds a checked-in String Catalog (for example
  `MalibuFeature.xcstrings`) and uses `String(localized:)` or generated catalog
  keys for every new user-facing string. The feature ships with a complete
  base-language set so its new path is not mixed-language; existing unrelated
  legacy English strings are out of scope. A lint/test rejects new bare English
  literals in feature views, presenters, and Settings code, with that scope
  explicitly limited to files/symbols owned by this feature.
- BS953-AC050: Currency/rate values use locale-aware formatting such as
  `.formatted(.currency(code:))`; model IDs remain exact and untranslated.
- BS953-AC050A: Rationale, guard, progress, duration, and empty-state copy is
  localized as whole templates with named placeholders; durations, counts,
  decimal sizes, and plural forms use locale-aware formatting rather than
  concatenated fragments or raw English numbers.
- BS953-AC046A: Progress phase and completion transitions are announced to
  assistive technology through an accessible live region or equivalent
  announcement, not only exposed as a static label.
- BS953-AC046B: When a fresh recommendation callout appears without taking
  focus, VoiceOver receives a non-disruptive announcement containing its scope,
  target model, and available action; the provider can discover it without
  navigating by color or timing.

### BS953-R013 - CLI/runtime capability negotiation and binary provenance

Malibu MUST negotiate feature tiers against the running provider peer and the
CLI binary it invokes before rendering model actions.

Capability tiers:

| Tier | Required capability evidence | Minimum peer version contract | Enabled UI |
|---|---|---|---|
| `model_status_v1` | local status contract version supported by Malibu, fresh `status_observation_v1`, `service_instance_v1`, and control `status_response` decode | First signed release whose local status advertises this tier | Current model and view-only fallback |
| `model_ready_switch_v1` | `model_status_v1`, launchd-managed `models switch --json` adapter with CLI-owned RAM/cooldown preflight, typed switch frames, strict `models list` TSV parser until `model_catalog_json_v1` is present, and local socket reachable | First signed release whose local status advertises this tier and whose CLI command tests cover `models list`/`models switch` guard parity | Ready installed model switching |
| `model_recommendation_check_v1` | signed intended CLI; targeted `--check-only --progress-json --isolated-cache-root` adapter; `model_recommendation_check_event.v1` progress/cancel frames; `autotune_recommend.v1` parser; `--installed-only` background mode; CLI-owned staging allocation/cleanup and no-canonical-mutation tests; safe scheduler gates | First signed release whose CLI emits the check-event stream plus `autotune_recommend.v1` and passes scheduler/provenance/isolation tests | Manual heavyweight evaluation and installed-only background recommendation checks |
| `model_recommendation_apply_switch_v1` | `model_recommendation_check_v1`, `models adopt-recommendation`, typed adoption frames, rollback journal support, and runtime transaction authority | First signed release containing BS953-R014/R015 command, frame, and crash-recovery tests | One-tap recommendation adoption |
| `model_catalog_json_v1` | `models_list.v1`, `models_browse.v1`, and `model_catalog_error.v1` schemas from BS953-DC001A through BS953-DC001C | First signed release containing BS953-R017 JSON schema tests | JSON-backed ready list rows and broad rollout of compatible-online browsing |

The implementation must add a checked-in Malibu feature-capability manifest that
maps each tier to its first supporting `binary_version`, required local-status
capabilities, required command schemas, and required control-frame schemas.
This build spec does not hardcode future release numbers; the release PR that
implements the tier must fill the manifest and tests with the concrete version.
For catalog JSON, both commands share only `model_catalog_json_v1`; the manifest
must not define separate list/browse capability names.

Acceptance:

- BS953-AC051: Malibu invokes the launchd-managed provider CLI path reported by
  `InstalledProviderMonitor.parseLaunchdServiceProgramPath` for model operations
  when it is present, owner-private, executable, signed, and compatible with the
  running local-status peer.
- BS953-AC052: Malibu does not invoke an arbitrary environment-provided CLI path
  for production model operations; `MALIBU_CLI_PATH` remains test/development
  only and is excluded from sanitized production subprocess environments.
- BS953-AC053: If Malibu contains an embedded CLI and the launchd-managed
  standalone CLI is a different signed binary, model operations use the running
  peer only when local-status capabilities prove compatibility; otherwise the UI
  shows update/repair guidance.
- BS953-AC054: Release candidates that ship Malibu and a standalone provider CLI
  are blocked until `docs/runbooks/provider-cli-release-verification.md` byte
  identity and updater acceptance checks pass for the final signed artifacts.
- BS953-AC055: Malibu gates by capabilities and schema versions, not by
  marketing version alone; `binary_version` is displayed only as diagnostic
  context.
- BS953-AC056: Tests cover the concrete first-supporting `binary_version` for
  every implemented tier, including one version below the floor and the floor
  version. For `model_catalog_json_v1`, tests must prove local-status capability
  evidence and the checked-in manifest agree before Malibu invokes either
  `models list --json` or `models browse --json`.
- BS953-AC057: A stale local-status observation beyond its `valid_for_ms` does
  not enable switch or adoption CTAs.
- BS953-AC058: Missing `model_recommendation_apply_switch_v1` disables `Adopt`
  for recommendations and cannot fall back to app-side config mutation.
- BS953-AC059: A mismatched or stale peer state is accessible to VoiceOver and
  offers the existing Malibu update/repair path, not Terminal instructions.

### BS953-R014 - CLI/runtime-owned recommendation apply-and-switch transaction

The implementation MUST add the command, event frames, control frames, and
validation ordering in BS953-DC004 and BS953-DC005 before shipping one-tap
recommendation adoption.

Acceptance:

- BS953-AC060: The command rejects unknown schemas, missing `serve_config`,
  mismatched `recommended_model`/`serve_config.model`, non-null unsupported
  draft fields, malformed IDs, unsupported catalog/artifact hashes,
  RAM/disk/cooldown guards, active switch, and incumbent mismatch before config
  mutation.
- BS953-AC061: The runtime validates signed artifact/catalog identity before
  adding transaction-scoped switch authority.
- BS953-AC062: The authority update is scoped to transaction ID, target,
  recommendation hash, and serve config; it does not add broad supported-model
  policy or make terminal `models browse` rows switchable.
- BS953-AC062A: The transaction authority is single-use, bound to the exact
  transaction UUID and recommendation hash, expires after completion/failure,
  rejects replay or target widening, and is not accepted by a raw socket
  `switch_request`; tests cover replay, concurrent requests, and browse-row
  leakage.
- BS953-AC063: The command returns one authoritative final frame:
  `completed`, `failed`, or `cancelled`; Malibu does not infer success from
  subprocess exit alone.
- BS953-AC064: A feasible-not-installed target that passes recommendation
  validation can live-switch without Terminal through this transaction.
- BS953-AC065: A feasible-not-installed target that lacks transaction capability
  cannot produce config-only drift or a rejected live `switch_request`.
- BS953-AC066: The transaction writes only `ConfigApplier.recommendationOwnedKeys`.

### BS953-R015 - Deterministic config recovery and incumbent continuity

Recommendation adoption MUST be rollback-first on every failure before the
runtime commit is proven complete.

Acceptance:

- BS953-AC067: Before config mutation, the command writes a `0600` journal under
  `~/.config/macprovider/model-adoption-transactions/` and a token-redacted
  backup beside the config using `ConfigApplier` naming semantics.
- BS953-AC068: The backup and journal contain no bearer token, provider private
  key, serial number, MAC address, UUID, raw hardware fingerprint, or HMAC
  secret.
- BS953-AC069: If config apply fails, the runtime is not asked to switch and the
  original config bytes remain unchanged.
- BS953-AC070: If runtime switch fails before `runtimeCommitObserved`, the
  command restores recommendation-owned fields to pre-apply values and verifies
  field parity before returning failure.
- BS953-AC071: If rollback cannot restore byte/field parity, the final event is
  `failed` with `rollback_state: "rollback_failed"` and Malibu keeps the
  incumbent runtime model visible.
- BS953-AC072: If the CLI or app crashes after config mutation but before
  runtime commit, restart recovery uses the journal to roll back before enabling
  another adoption.
- BS953-AC073: If the CLI or app crashes after runtime commit, restart recovery
  marks completion only when local status current model and config fields both
  match the target.
- BS953-AC074: Re-running an already completed transaction is idempotent and does
  not rewrite config; re-running after rollback uses a new transaction ID.
- BS953-AC075: Malibu has explicit UI states for `config_apply`, `rollback`,
  `rolledBack`, and `rollbackFailed`.
- BS953-AC075A: `rollbackFailed` keeps the incumbent runtime visible and offers
  a guarded `Retry recovery`/repair path plus support guidance; it never
  presents an ambiguous success state or asks the provider to edit config in
  Terminal.

### BS953-R016 - Authoritative power-source detection and fail-closed scheduling

Malibu MUST add an app-side `MalibuPowerMonitor` that uses IOKit
`IOPSCopyPowerSourcesInfo` / `IOPSGetProvidingPowerSourceType` semantics
equivalent to `SystemPowerSourceReporter` for scheduler gates.

Acceptance:

- BS953-AC076: Background recommendation checks start only with a fresh
  `external`/AC power sample and nominal/fair thermal state.
- BS953-AC077: `battery`, `unknown`, missing, or power samples older than 10s
  fail closed and do not start background recommendation work.
- BS953-AC078: If power changes from AC to battery during a background
  recommendation subprocess before mutation, Malibu cancels/defer the run and
  leaves config unchanged.
- BS953-AC079: Manual recommendation checks on battery require explicit warning
  acknowledgement before start.
- BS953-AC080: If power becomes unknown/stale during a manual check before
  mutation, Malibu pauses for a fresh sample or cancels without mutation.
- BS953-AC081: Power-source tests cover AC, battery, unknown, stale sample,
  mid-run transition, and manual override warning.

### BS953-R017 - Structured model catalog output and strict TSV fallback

Production rollout MUST use structured JSON list/browse output under the single
`model_catalog_json_v1` capability. TSV parsing is an MVP compatibility fallback
only for capability-gated local peers.

Acceptance:

- BS953-AC082: `models list --json` emits exactly the `models_list.v1` top-level
  object and row schema from BS953-DC001B, including required fields, nullability,
  enum values, action/display ID separation, unknown-field handling, malformed
  JSON fail-closed behavior, and `model_catalog_error.v1` command errors.
- BS953-AC083: `models browse --json` emits exactly the `models_browse.v1`
  top-level object and row schema from BS953-DC001C, including required fields,
  nullability, enum values, raw/display ID separation, `action_model_id: null`,
  unknown-field handling, malformed JSON fail-closed behavior, and
  `model_catalog_error.v1` command errors.
- BS953-AC084: TSV fallback skips exactly one known header for each command:
  `model_id<TAB>state` for list and `model_id<TAB>est_gb<TAB>fit` for browse.
- BS953-AC085: TSV fallback rejects any row with an unexpected column count,
  empty action ID, unknown state/fit token, embedded tab, newline, C0/C1 control,
  or ID exceeding `SupportedModels.maxEntryByteLength`.
- BS953-AC086: Action IDs from all sources are validated before use; display
  truncation/sanitization never feeds a switch/adoption command.
- BS953-AC087: Browse TSV rows remain display-only and cannot trigger
  `switch_request` or config mutation.
- BS953-AC088: Malibu blocks JSON list/browse invocation and broad
  compatible-online browsing until local status and the feature-capability
  manifest both advertise `model_catalog_json_v1`, with tests for the concrete
  first-supporting floor version and one version below that floor.

### BS953-R018 - Download progress and cancel honesty

Issue #953 asks for download progress and cancel. This spec implements that
request for explicit manual recommendation checks through BS953-R021 and for
recommendation preparation through BS953-R014, while accepting
phase-only/no accepted-cancel behavior for ready installed switches in MVP.

Acceptance:

- BS953-AC089: Ready installed switches show phase progress from current
  `switch_progress` and do not display byte/percent progress.
- BS953-AC090: BS953-R014 recommendation adoption preparation shows byte
  progress when `download_bytes_total` is known and phase-only progress when it
  is not; receipt-only `--prefetch` output is never parsed as recommendation
  JSON.
- BS953-AC090A: BS953-R021 targeted evaluation shows download progress when
  known, benchmark phase progress otherwise, and a real cancellable subprocess
  path before adoption; background installed-only checks never emit a download
  phase.
- BS953-AC091: Disk and network warnings are shown before non-cancellable
  adoption phases.
- BS953-AC092: Cancel is available for browse/recommendation-check subprocesses
  through their app-to-CLI input, and for cancellable adoption phases through
  `model_adoption_command.v1`; it is not shown after runtime commit begins.
- BS953-AC093: `Close` or `Keep in Background` keeps observing progress without
  implying cancellation.

### BS953-R019 - Visible-field recommendation dedupe

Recommendation dismissal dedupe MUST use only visible `autotune_recommend.v1`
fields and Malibu local UI state.

Acceptance:

- BS953-AC094: Dedupe uses the BS953-DC003 visible fields and does not parse
  stored/upload-only `hardware_identity_hash`.
- BS953-AC095: Changing recommendation model, catalog/input versions, visible
  hardware bucket, binary version, current served model, or seven-day expiry
  allows the callout again.
- BS953-AC096: UI cache tests prove no hidden hardware hash, token, provider
  key, serial, MAC, UUID, or HMAC secret is persisted.
- BS953-AC097: A deliberate manual model choice records the current served model
  in local dismissal metadata and suppresses repeat prompts for the same
  recommendation while that model remains current; the mutable dismissal
  timestamp is not part of the recommendation identity hash.

### BS953-R020 - Revert after a successful switch

Malibu MUST provide a guarded, understandable revert path after a successful
manual switch or recommendation adoption when the previous confirmed model is
known and policy-valid.

Acceptance:

- BS953-AC098: After success, Malibu shows the current and previous confirmed
  model IDs and offers `Revert to <previous model>` when the previous target is
  known and supported.
- BS953-AC099: Revert uses the same launchd-managed CLI transaction as a ready
  switch; cooldown, RAM-fit, supported-model, and serving-lifecycle guards are
  enforced and surfaced rather than bypassed.
- BS953-AC100: If the previous model requires signed preparation, Malibu shows
  download/disk impact before confirmation and uses the cancellable preparation
  plus rollback contract; it never writes config directly.
- BS953-AC101: The previous confirmed model and revert eligibility survive app
  relaunch, are replaced only by a later successful switch or invalidated by
  policy, and appear in the compact local activity history.

### BS953-R021 - Isolated recommendation-check execution

Malibu MUST use the capability-gated recommendation-check adapter for manual
and background checks. The adapter separates recommendation observation from
live-provider adoption and makes expensive work visible and cancellable.

Acceptance:

- BS953-AC102: A targeted manual check requires explicit provider confirmation
  before any subprocess, download, model load, or benchmark begins and shows
  expected download size, memory impact, thermal/power state, and estimated
  duration.
- BS953-AC102A: General manual `Check Recommendations` uses
  `installed_only=true`, shows its installed-candidate scope, explicitly says
  that no download will occur but local weights may be loaded and benchmarked,
  shows expected memory/benchmark impact, thermal/power state, and estimated
  duration, and requires provider confirmation before any subprocess, model
  load, or benchmark begins. It never starts a download/load/benchmark for an
  uninstalled candidate. The targeted online flow is the only manual path that
  can prepare an uninstalled candidate.
- BS953-AC103: The adapter emits
  `model_recommendation_check_event.v1` progress, byte totals when known, and a
  terminal `completed`, `failed`, or `cancelled` event before the final
  recommendation is consumed; the CLI owns staging removal after cancel and
  leaves config and the incumbent canonical snapshot unchanged.
- BS953-AC104: Background checks use `installed_only=true`, never download or
  benchmark an uninstalled candidate, and are disabled with a visible reason
  when the adapter or isolation capability is absent.
- BS953-AC105: A failed, cancelled, or timed-out check shows a localized reason,
  transferred bytes when known, and retry action; partial staging is removed
  and no candidate is marked Recommended.
- BS953-AC106: Non-null `draft_model` or
  `draft_model_artifact_sha256` in recommendation output is retained for
  diagnostics but blocks MVP Recommended/Adopt with an explicit unsupported
  draft reason; it is never silently dropped from a claimed config-parity
  result.

## 11. App/CLI/Backend Boundaries

### 11.1 Malibu responsibilities

Malibu owns:

- UI composition and state presentation.
- Local scheduling of low-priority recommendation checks.
- Invoking the installed signed CLI for recommendation checks where required.
- Parsing bounded CLI output or typed control frames.
- Showing guard/error states and progress.
- Persisting UI-only dismissal/backoff state and the provider-facing
  background-recommendation preference.
- Requiring consent for manual heavyweight checks and displaying their progress;
  Malibu never chooses or manages a canonical provider artifact cache.

Malibu must not call `ProviderConfig.persistAutotuneRecommendation` for
recommendation adoption in this feature. That helper remains useful for existing
onboarding/config validation paths, but BS953 adoption uses the CLI/runtime
transaction so backup, rollback, authority update, and live switch share one
authoritative outcome.

### 11.2 CLI/runtime responsibilities

CLI/runtime owns:

- Effective supported-model resolution.
- Control socket permissions and frame contracts.
- Runtime model loading and atomic model publication.
- RAM fit and cooldown enforcement.
- Artifact/catalog signature and hash validation.
- Autotune scoring, ranking, hard blocks, and serve-config construction.
- Isolated recommendation-check staging, progress/cancel events, installed-only
  background filtering, and prevention of canonical live-cache mutation.
- Config apply semantics for recommendation-owned fields.
- Binary provenance checks for model-operation subprocesses.
- Recommendation adoption journal, rollback, and idempotent crash recovery.

### 11.3 Backend responsibilities

Existing backend/feed surfaces remain unchanged unless engineering finds a
missing field required for signed recommendation adoption. Malibu must not add a
new backend dependency for this feature.

## 12. Edge Cases

- Current model is absent from `models list`: show current from status and mark
  the list as partially stale.
- Supported models include duplicates or case variants: follow SPEC-010
  normalization; the app displays one exact actionable row per target ID.
- Any source returns model IDs with tabs/newlines/C0/C1 controls or too many TSV
  columns: the parser rejects the row for actions. Browse TSV may show sanitized
  display text only; sanitized display text is never passed as an action ID.
- Recommendation matches current model: no dashboard callout; sheet can show
  "Current model is already recommended."
- Recommendation result has candidates but no serve config: display as advisory
  only; adoption disabled because BS953-R014 requires serve-config parity.
- Recommendation result is stale relative to current catalog/rate-card/binary:
  require rerun.
- Control socket disconnects during switch: show reconnecting and recover by
  status polling; do not assume success.
- App quits during ready switch: on next launch, status determines current truth.
- App or CLI quits during recommendation adoption: the BS953-DC006 journal
  determines rollback/completion recovery before another adoption is enabled.
- Provider CLI updates during a recommendation check: cancel or fail the check
  and retry after update completes.
- Thermal state changes during recommendation: cancel/defer background run.
- Battery state changes during recommendation: background run cancels/defer
  before mutation; manual run requires the BS953-R016 warning/fresh-sample
  policy.
- Disk space becomes insufficient during download/preparation: fail with the
  CLI/runtime-owned reason and keep incumbent model active.

## 13. Visual and Interaction Details

### 13.1 Dashboard model row

Fields:

- Label: `Model`
- Primary value: current model ID or configured model ID.
- Secondary value: runtime state and last switch/recommendation status.
- Button: `Change Model...`

States:

- Checking: show `Checking...` until control-socket status or config fallback
  resolves; do not expose a switch action.
- Ready: current model, active CTA.
- Loading: current model plus phase.
- View-only: configured model, disabled CTA with explanation.
- Error: current/configured model plus recoverable action if available.

The Malibu menu bar menu and dashboard overflow menu both expose `Settings...`.
The Settings window opens to `Models`, with `Background recommendations` as a
persisted On/Off toggle, explanatory copy, and a `Run a manual check` link that
does not depend on the toggle.

### 13.2 Model switcher list

Use a compact table/list with stable row height:

- Model ID
- Status chip: Current, Ready, Needs preparation, Evaluation complete,
  Recommended, Compatible, Blocked
- Fit chip: Fits, Tight, Too large, Unknown
- Optional metadata: estimated GB, rate-card prompt/completion rates,
  confidence
- Region label: `Needs preparation` for supported rows with
  `weights_present_locally=false`; primary action is `Evaluate this model`.
  After a matching recommendation result, show the `Evaluation complete` chip
  and `Adopt & switch` action. Both the evaluation and adoption disclose their
  respective heavyweight preparation costs before work starts.

Primary actions:

- Current row: no action.
- Ready row: `Switch`
- Recommended row: `Adopt`
- Evaluation complete row: `Adopt & switch` through BS953-R014.
- Compatible online row: no one-tap switch. It may become Recommended only after
  `autotune_recommend.v1` plus BS953-R014 transaction capability validates the
  exact target.
- Blocked row: disabled action with reason.

Empty states are explicit and localized for each region: no ready models
installed, no models needing preparation, no recommendation, no compatible
online results, and no local activity history. The sheet also includes
`Check Recommendations (installed models)` and a compact `Model activity` entry point. After a
successful switch, adoption, or revert, the sheet and dashboard show the
current/previous IDs plus `Revert to <previous model>` when policy-valid.

### 13.3 Copy rules

- Use specific reasons: "Cooling down for 8s", not "Unavailable".
- Use "Finishing current request" for draining.
- Use "This model is not in this provider's supported model list" for
  unsupported.
- Use "Recommendation needs a fresh check" for stale inputs.
- Use "This check downloads about {size}, loads the model, and benchmarks it
  while your provider continues serving" before a material manual evaluation;
  use a separate localized template for adoption preparation. Never hide a
  download, memory, or benchmark cost behind `Evaluate` or `Adopt` alone.
- Use whole localized templates for rationale and guard sentences, including
  locale-aware duration, size, count, and plural formatting.
- Do not use revenue-promising copy. Prefer "Higher paid rate-card tier" or
  "Better recommendation score" when grounded in output.

## 14. Testing Strategy

### 14.1 App unit tests

Add focused tests under `phase3-binary/app/Tests/MalibuTests` for:

- Model row normalization from `models list --json`, `models browse --json`,
  strict `models list` TSV fallback, and display-only `models browse` TSV
  fallback.
- Installed-weights classification: warm/idle rows with
  `weights_present_locally` true/false, fit/support/runtime gates, and the
  invariant that an uninstalled idle row never exposes a bare `Switch` CTA.
- Compatible-online targeted evaluation uses the
  `--check-only --progress-json --isolated-cache-root` adapter, passes exactly one
  raw ID through `--candidate-models`, rejects a different/null recommendation,
  and never substitutes the default candidate list; manual consent covers
  download/load/benchmark cost and staging never mutates the canonical cache.
- `models_list.v1` and `models_browse.v1` decoding, including required fields,
  nullability, enum values, unknown extra fields, malformed JSON fail-closed
  behavior, `model_catalog_error.v1`, and action/display ID separation.
- Header handling, malformed column counts, unknown state/fit tokens, overlong
  IDs, tabs/newlines, and C0/C1 control rejection for action IDs from all
  sources.
- `autotune_recommend.v1` parsing, including no-recommendation, stale warning,
  thermal/swap hard-block, missing serve config, present rate-card fields, and
  non-null unsupported draft fields.
- `model_recommendation_check_event.v1` progress, known/unknown byte totals,
  targeted and installed-only manual consent/cost disclosure, cancellation,
  timeout, partial-download cleanup, isolated cache preservation, and
  installed-only background behavior.
- Switch transaction reducer states: confirming, loading, draining, loaded,
  failed, cooldown, concurrent switch, socket lost, revert available, and
  revert preparation.
- Recommendation adoption event reducer states: validating, preparing,
  downloading with known bytes, downloading without known total, config apply,
  switch loading/draining, rollback, rolledBack, rollbackFailed, completed, and
  cancelled.
- Capability/provenance UX: stale observation, missing capability tier,
  mismatched embedded/standalone CLI, missing signed CLI, and update/repair
  guidance. Include `model_catalog_json_v1` manifest/local-status agreement,
  the concrete floor `binary_version`, and one version below the floor.
- Recommendation scheduler gates: AC power, battery, unknown power, stale power,
  mid-run power transition, thermal, active switch, backoff, visible-field
  dismissal dedupe, deliberate manual-choice suppression, reversible in-app
  opt-out/settings toggle, provider-visible skip status, installed-only no-
  download behavior, and manual override warning.
- Full reachable accessibility path from dashboard entry CTA through sheet,
  callout, guards, errors, and progress; color-independent state labels;
  live announcements for phase transitions, localized whole-sentence templates,
  string-catalog/lint coverage, locale-aware rates/durations/counts, explicit
  per-region empty states, evaluation cost/error copy, stall reassurance, and
  relaunch-persistent revert. Include the unconditional Settings entry and
  toggle in keyboard and VoiceOver coverage.

### 14.2 CLI/runtime tests

Keep existing `ModelsSubcommandTests` and `EndToEndAcceptanceTests` green.
Add CLI/runtime tests:

- `models list --json` emits `models_list.v1`, `models browse --json` emits
  `models_browse.v1`, command errors emit `model_catalog_error.v1`, both
  commands preserve current TSV behavior when `--json` is absent, and no
  `models_list_json_v1` capability is emitted or accepted.
- `models adopt-recommendation --json` rejects malformed recommendation JSON,
  unsupported schema, missing serve config, mismatched target/config model,
  unsafe IDs, stale incumbent, cooldown, RAM/disk failure, active switch, and
  unsigned/untrusted artifact/catalog identity before config mutation.
- The `model_recommendation_check_v1` adapter emits typed progress and final
  recommendation frames, honors exact candidate targeting, uses isolated
  staging, supports cancellation/timeout cleanup, and enforces
  `installed_only` without background downloads.
- Recommendation apply-and-switch frames update live authority only for the
  transaction-scoped target and do not alter broad `supportedModels`.
- Journal creation, token-redacted backup, config apply, rollback, crash/restart
  recovery, and idempotent retry preserve byte/field parity.
- `recommendation_apply_switch_cancel_request` succeeds only before
  non-cancellable commit phases and never publishes a partial target.
- Unsupported, cooldown, RAM, concurrent, socket, and load failure codes remain
  compatible with existing tests.
- `models switch --json` guard parity tests prove cooldown and RAM rejection
  happens before any raw socket request is accepted, including revert.
- `models switch --json` rejects cooldown and RAM-unfit targets before sending or
  accepting a raw socket switch request, proving ready-switch guard parity.

### 14.3 End-to-end acceptance

Run an app-plus-provider E2E on a supported Mac:

- Start serving on the incumbent model.
- Open Malibu and verify current model.
- Switch to a ready supported model and observe loading/draining/loaded.
- Confirm an in-flight request completes on the old model and subsequent request
  uses the new model.
- Run a recommendation check, adopt an actionable recommendation, and verify
  config parity plus live current model update.
- For a Compatible online row, verify explicit consent precedes the isolated
  download/load/benchmark check, progress and cancel work, failed staging is
  removed, and the canonical live-provider snapshot is unchanged until adopt.
- Verify a background check uses installed-only candidates and performs no
  unconsented download of an uninstalled model.
- Kill the app and the CLI transaction process at each journaled phase and
  verify deterministic completion or rollback on restart.
- Verify feasible-not-installed recommendations cannot mutate config unless
  `model_recommendation_apply_switch_v1` is present.
- Repeat offline, cooldown, RAM-too-large, thermal, battery, and socket-missing
  cases.

### 14.4 Release verification

For release candidates that ship Malibu and the standalone CLI, keep the
existing provider CLI release-verification discipline:

- Verify Malibu invokes the intended launchd-managed signed CLI for model
  operations, not an arbitrary environment override.
- Verify byte identity where the release runbook requires comparing embedded
  and standalone `malibu-cli` binaries.
- Verify updater path from the previous stable version.
- Do not treat workflow green or matching `--version` as sufficient production
  proof.

## 15. Rollout and Rollback

### 15.1 Rollout

Required rollout gates:

1. Ship app UI hidden behind local capability gates until compatible CLI/control
   frames, signed binary provenance, and fresh local-status observations are
   present.
2. Enable manual current-model viewing and ready-model switching first.
3. Enable manual recommendation checks only after the isolated,
   progress-aware `model_recommendation_check_v1` adapter, consent flow,
   staging cleanup, and canonical-cache isolation tests pass. Keep the
   receipt-only `--prefetch --prefetch-receipt <private-path>` path out of the
   evaluation result and let BS953-R014 own adoption preparation.
4. Enable `Adopt` only after `models adopt-recommendation --json`,
   `model_recommendation_apply_switch_v1`, rollback journal tests, and crash
   recovery tests pass.
5. Enable compatible-online browsing broadly only after `model_catalog_json_v1`
   is present in local status, matches the checked-in manifest, and passes floor
   plus below-floor version tests.
6. Enable background recommendation scheduling only after E2E validation proves
  `installed_only=true` performs no downloads/benchmarks of uninstalled models,
  on AC power, nominal thermal state, fail-closed power transitions, and at
  least one real provider hardware tier.

Background recommendations MUST be suppressible from the unconditional
provider-facing Malibu Settings > Models > Background recommendations toggle
and the callout `Stop background recommendations` action. The choice can be reversed without
Terminal, persists locally, and leaves manual checks/model switching available.
A local defaults key may exist only as an operator hotfix, never as the sole
provider-facing control or a documented user action.

### 15.2 Rollback

Rollback behavior:

- If the app feature is disabled, existing CLI commands remain usable.
- If recommendation scheduling is disabled, manual switching remains usable.
- If live switching is disabled due to control-socket incompatibility, Malibu
  falls back to view-only model status.
- If adoption is disabled due to missing transaction capability, recommendation
  checks remain advisory and no config is mutated.
- If config apply succeeds but live switch fails, BS953-R015 rollback runs before
  failure is returned; `rollback_failed` is the only allowed unresolved state and
  it keeps the incumbent runtime visible.

## 16. Traceability to Issue #953

Issue source: GitHub #953, "Malibu app: in-app model switching + background
autotune recommendations (no Terminal)".

| Issue #953 acceptance bullet | BS953 requirements | Acceptance criteria | Tests |
|---|---|---|---|
| Provider can view the current model and switch models entirely within Malibu, no Terminal. | BS953-R001, BS953-R002, BS953-R004, BS953-R010, BS953-R013 | BS953-AC001 through BS953-AC015A, BS953-AC039 through BS953-AC042, BS953-AC051 through BS953-AC059 | App current-model presenter tests, installed-weights/model-list parser tests, CLI guard-parity tests, control-frame switch reducer tests, E2E ready switch and guarded rejection tests |
| Malibu proactively recommends a better/new model when one becomes runnable on the Mac, with one-tap adopt. | BS953-R006, BS953-R007, BS953-R008, BS953-R014, BS953-R015, BS953-R016, BS953-R019, BS953-R021 | BS953-AC019 through BS953-AC034, BS953-AC023B through BS953-AC023C, BS953-AC060 through BS953-AC081, BS953-AC094 through BS953-AC106 | Isolated candidate-check progress/consent tests, installed-only scheduler power/thermal/opt-out/status tests, adoption preparation transaction tests, rollback/crash recovery tests, visible-field/manual-choice dedupe tests |
| Model switch shows live progress (`models status`) and completes without a reinstall or downtime. | BS953-R004, BS953-R005, BS953-R009, BS953-R014, BS953-R018, BS953-R020, BS953-R021 | BS953-AC011, BS953-AC016 through BS953-AC018, BS953-AC035 through BS953-AC038, BS953-AC063 through BS953-AC065, BS953-AC089 through BS953-AC093, BS953-AC090A, BS953-AC098 through BS953-AC106 | Switch progress reducer tests, in-flight request E2E, adoption and isolated-evaluation progress/cancel tests, phase live-announcement/stall tests, revert persistence/cooldown/preparation tests, no accepted-switch false-cancel UI test |
| Cross-cutting provider trust, privacy, accessibility, and localization. | BS953-R011, BS953-R012, BS953-R013 | BS953-AC043 through BS953-AC059, BS953-AC046A through BS953-AC050A, BS953-AC046B | Redaction/privacy tests, capability/provenance tests, full dashboard-to-Settings VoiceOver/keyboard path, live announcements, String Catalog/lint, locale-aware formatting tests |
| Blocked switches (cooldown / RAM / unsupported) show a clear in-app reason. | BS953-R003, BS953-R004, BS953-R010, BS953-R014, BS953-R017, BS953-R021 | BS953-AC008 through BS953-AC010B, BS953-AC011 through BS953-AC015A, BS953-AC039 through BS953-AC042, BS953-AC059, BS953-AC060, BS953-AC082 through BS953-AC088, BS953-AC102 through BS953-AC106 | Guard mapping tests, targeted recommendation consent/draft tests, CLI rejection/guard-parity tests, malformed parser tests, incompatible peer UI tests |

## 17. Resolved Product Decisions

### BS953-D001 - Accepted ready-switch progress/cancel MVP deviation

Ready installed model switches use current phase-only `switch_progress` and do
not offer accepted-switch cancellation in MVP. Malibu shows `Close` or
`Keep in Background` after ack and keeps observing runtime state. Recommendation
adoption implements byte progress and cancellable preparation through
BS953-R014/R018.

### BS953-D002 - Structured catalog rollout

Strict TSV parsing is allowed only as a capability-gated MVP fallback. Broad
compatible-online browsing requires `models_list.v1`, `models_browse.v1`,
`model_catalog_error.v1`, and the single `model_catalog_json_v1` capability.

### BS953-D003 - Feasible-not-installed adoption

Feasible browse results are advisory Compatible online rows. They become
one-tap adoptable only after the provider selects `Evaluate this model`, the
targeted `model_recommendation_check_v1` flow with
`--candidate-models <exact-raw-id>` returns a fresh `autotune_recommend.v1`
result whose target exactly matches, and the BS953-R014 CLI/runtime transaction
validates and prepares it. The receipt-only `--prefetch` path is not used to
produce recommendation JSON; config-only adoption is prohibited.

### BS953-D004 - Config recovery policy

Recommendation adoption uses rollback-first recovery. Staged-for-restart is not
an accepted success or normal failure policy for this feature.

### BS953-D005 - Yield presentation

Show prompt/completion USD per million tokens and confidence when present.
Do not show daily/hourly earnings estimates in MVP.

## 18. Implementation Plan for Engineering Agent

1. Re-verify control-frame, model CLI, and autotune JSON interfaces in the files
   listed in Section 2.
2. Add CLI/runtime capability surfaces:
   `model_ready_switch_v1`, `model_recommendation_check_v1`,
   `model_recommendation_apply_switch_v1`, and `model_catalog_json_v1` as
   applicable. Do not add or accept `models_list_json_v1`.
3. Add `models list --json` with `models_list.v1`, `models browse --json` with
   `models_browse.v1`, shared `model_catalog_error.v1`, the
   `model_catalog_json_v1` manifest/local-status gate, concrete floor and
   below-floor version tests, and strict TSV fallback tests while preserving
   existing TSV output.
4. Add `models adopt-recommendation --json`, adoption control frames,
   transaction-scoped runtime authority, journal/backup/rollback recovery, and
   idempotent retry.
5. Add app model-domain types and parsers behind tests:
   model rows, switch transaction state, adoption event state, recommendation UI
   cache, JSON/TSV parsing, and `autotune_recommend.v1` parsing.
6. Add binary provenance and capability negotiation using local status,
   `InstalledProviderMonitor`, signed CLI checks, and release byte-identity
   gates.
7. Add a Malibu model service that combines:
   current status from control socket/status fallback,
   ready rows from supported-model list plus authoritative local-weights state,
   optional compatible rows from browse,
   recommendation rows from the installed-only background check adapter, and
   isolated targeted candidate evaluation results. Do not use the legacy plain
   `autotune --recommend` path for background checks or for a feature tier that
   lacks progress/isolation capability.
8. Add ready-switch handling through the launchd-managed `models switch --json`
   CLI adapter (never app-direct socket requests), adoption through the
   CLI/runtime transaction event stream, and guarded revert to the previous
   confirmed model.
9. Add `MalibuPowerMonitor` and recommendation scheduler with fail-closed power,
   thermal, active-work, backoff, and visible-field dismissal gates.
10. Add the SwiftUI dashboard model row, recommendation callout, unconditional
   Settings > Models > Background recommendations surface, model switcher
   sheet, provider-facing opt-out, revert affordance, full reachable
   accessibility labels, and a checked-in `MalibuFeature.xcstrings` catalog
   with locale-aware whole-template formatting using existing `DashboardWindow`
   and presenter patterns. Add a scoped lint for new feature strings.
11. Extend app and CLI tests described in Section 14.
12. Run app unit tests, CLI tests touched by the feature, release-artifact
   byte-identity/updater verification for shipped builds, and an E2E provider
   smoke before marking the issue complete.

## 19. Completion Definition

The feature is complete when:

- A provider can view current model and switch to a ready supported model in
  Malibu with no Terminal.
- Malibu shows progress, cooldown, RAM, unsupported, offline, busy-serving,
  battery, thermal, evaluation consent/progress/cancellation, switch
  cancellation limits, success, and failure states accurately.
- Manual evaluations make download/load/benchmark cost explicit, use isolated
  staging with visible progress, and cannot mutate the live-provider cache.
- Background recommendations run only under safe local gates and installed-only
  checks, and surface a one-tap adoption for actionable, fresh recommendations.
- Adoption preserves recommendation-owned config parity with the CLI path,
  recovers deterministically after failures/crashes, and cannot leave
  config-only drift.
- Malibu gates feature tiers by signed binary provenance, fresh local-status
  capabilities, and release byte-identity/updater verification.
- Existing CLI/provider authority boundaries from SPEC-025, SPEC-023,
  SPEC-013, and SPEC-010 remain intact.
- Tests cover app state reducers/parsers, CLI contract changes, and E2E switch
  behavior.
