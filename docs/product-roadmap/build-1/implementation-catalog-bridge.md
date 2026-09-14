# Build 1 catalog read caller bridge

Date: 2026-09-10. Implementation/test lane, not independent approval.
Contract: catalog-read-lifecycle addendum r2, SHA-256
`e607e8d45fac124d5ebc85e6a9f6064bd803052487c8b93998e4d091984ff954`.

## Scope and execution

`ModelCatalogReadBridgeTests.swift` adds two explicit qualification phases and a
compiled XCTest child entry. It reuses `Build1CommandFixtureInputs` for genuinely
signed current fixture feeds and the existing `Build1CommandBootstrapTests`
fixture context/downloader/real candidate process/prober. The only bootstrap
helper change makes that context static/internal with an optional catalog key;
its original key remains the default. No production flag or signing-key bypass
selects fixture behavior. Private signing key bytes are never persisted.

Run the export test with `BUILD1_CATALOG_BRIDGE_PHASE=export`. It creates a
retained private temporary fixture root and writes the following handoff artifact
inside this worktree:

`.omx/qualification/catalog-read/input.json`

The manifest contains real parsed CLI outputs: clean-install quick projection,
post-prepare quick unverified projection, post-evaluation verified projection,
exact recommendation result, prepare/evaluate terminal JSONL, and both target
verification streams. It also contains exact home/config/context/target/key and
transaction/generation identities. This fixture root is intentionally retained
until app capture/replay qualification is complete. It contains public signed
fixture bytes and simulated model files, no operator credentials or MLX weights.

The app lane consumes those unchanged CLI response strings, drives the actual
refresh/verification/result caller, and writes
`.omx/qualification/catalog-read/app-argv.json` with schema
`malibu_catalog_read_argv_fixture.v1`. It records the actual dispatched `quick`,
`verify`, and `result` argument arrays plus exact shared metadata.

Run the replay test with `BUILD1_CATALOG_BRIDGE_PHASE=replay`. It reads these
arrays directly, passes them unchanged through request serialization and real
`MacProviderCLI.parseAsRoot`, then runs the parsed command with the isolated
fixture context. It verifies bound quick/verified states and exact committed
result bytes, confirms the app argument artifact is unchanged, and writes
`.omx/qualification/catalog-read/cli-replay.json`. There is no independently
reconstructed equivalent argument list in this acceptance phase. The export
phase's bootstrap arguments are separate setup evidence.

Both read modes install genuine native lock and lifetime-pipe descriptors at
199/200 in the compiled test child. The shipping CLI validates the fixed lock
inode/mode/held open description and read-only pipe. This proves descriptor and
parser composition; it does not claim the XCTest child fixture installs them
through the production app spawn path or proves app-parent-death ownership.
Those belong to the app runner lifecycle tests.

## Slow-read and terminal evidence

Export executes an actual parsed prepare owner to a successful terminal, then
an exact-target verification command whose first actual measured hash chunk
pauses for 21 seconds through the explicit compiled context callback. The
production progress timer continues independently. The test requires elapsed
verification at least 20 seconds, accepted/completed events and at least four
progress heartbeats. It then runs the actual parsed recommendation owner and
exact result command, followed by another 21-second verification read, retaining
both streams. Config bytes must remain unchanged. No production runtime flag
or wall-clock reset enables the pause.

The candidate executable is the existing deterministic SSE fixture: these are
actual command/journal/probe/verification paths, **not real MLX performance**.
The callback delays actual byte processing but does not fabricate bytes. App
pending custody clear/restart tests consume these artifacts separately; this
CLI fixture alone does not prove the app performed its durable pending clear.

## Evidence status and remaining boundaries

At authoring, Swift frontend parse of bridge/bootstrap/map edits exited 0.
Compilation and execution remain root-owned and must be recorded with actual
commands/results. The phase-gated tests return without qualification work when
the phase environment is absent; an ordinary green suite does not count as
export/replay acceptance. A missing manifest in an explicitly requested phase
fails rather than silently skipping. Signed fixture timestamps remain real;
no timestamp rewriting is authorized to bypass app freshness.

Replay additionally exercises the unchanged captured quick array against two
explicit fixture states. First it holds aside the complete dormant fixture
`models` root, including its journal, allowing the actual command to create a
fresh root/context and prepare action. It asserts a new context, no previous
transaction history and no recoveries, then removes only this freshly created
fixture root and restores the original directory. This is the clean-install
case; its new context is expected and is never substituted into captured argv.

Second, with the original root/context restored, it holds aside only the exact
fixture artifact and verifies missing-target preparation under the existing
context. The actual parsed prepare owner downloads fixture bytes, encounters
an injected EIO at its actual hash-chunk boundary, then encounters EACCES in its
cleanup callback. Its real failed terminal and retained owned staging create the
cleanup obligation; no journal state is fabricated. Replaying the same captured
quick array must expose a separate cleanup recovery action. The original
artifact is restored with defer, config bytes remain unchanged, and the later
captured verify/result arrays use the original context. Only this test's
private fixture files are moved; no operator or production artifact is touched.
Missing-target and clean-install evidence are labeled separately in replay JSON.

The bridge does not qualify app signature/process identity, production spawn
ownership, cancellation/app death, admission/settled credit, throughput, or
actual signed hardware journeys. Root and the independent combined auditors own
acceptance of those remaining evidence lanes.

## First export failure and fixture correction

Root's Swift35 compiled export failed after 29.078 seconds (one test, one
unexpected failure), log `/tmp/build1-catalog-bridge-export-swift35.log`.
The candidate trace recorded PID45780, owner PID45774, port59036 and four completed
probe requests. The evaluation journal recorded a failed, uncommitted terminal.
The signed fixture candidate/rate selected `test-model`, but its signed demand
feed contained no corresponding row. The recommendation engine correctly treats
missing demand as not recommendable, preventing a selected recommendation.

The correction adds the requested custom fixture key's demand row before the
fixture signing loop, only when that key is absent; existing fixture keys retain
their previous bytes/behavior. It neither changes production selection nor
accepts an unsigned or ineligible result. The stderr stop-grace warning was not
sufficient evidence of teardown failure: targeted PID and port checks showed
both processes and the listener absent, so no signal was sent. Export now
explicitly checks the exact fixture PID and listener after evaluation child exit
and flushes failure stdout to retain terminal evidence. The fixture's real quick
projection is captured before its final verified projection, preserving the
actual app freshness ordering without rewriting timestamps.

## Corrected export result

After the signed fixture demand-row correction, root ran
`BUILD1_CATALOG_BRIDGE_PHASE=export swift test --filter ModelCatalogReadBridgeTests.testExportPersistentSignedFixtureForActualAppCaller`.
The current bridge sources compiled in 12.69 seconds and the single selected
test passed in 48.527 seconds with zero failures or skips. The test created
`.omx/qualification/catalog-read/input.json`. This is fresh fixture export
evidence; app caller capture and unchanged-argument CLI replay remain separate
required phases.

The app capture subsequently passed its one selected Xcode test with zero
failures or skips and wrote `app-argv.json`, SHA-256
`3bfb0747977954ae1ef6c3b71f083fc8f80155919faf059eb9c6a1ee6a19d3f1`.
The complete Malibu app suite then passed 652 tests with zero failures or skips.
The first replay command used a nonexistent test filter and selected zero tests;
it is explicitly excluded from evidence. Root corrected the filter and ran
`BUILD1_CATALOG_BRIDGE_PHASE=replay swift test --filter ModelCatalogReadBridgeTests.testReplayUnchangedActualAppCallerArguments`.
That selected test passed in 2.140 seconds with zero failures or skips and wrote
`cli-replay.json`, SHA-256
`d7d835e8a932ad8e6baa05f86ba4858a12bf733a102d4541f965eeb710629089`.
