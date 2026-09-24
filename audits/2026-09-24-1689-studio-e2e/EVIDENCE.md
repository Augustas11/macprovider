# #1689 / PR #1713 Studio lab E2E (Loop A) — 2026-09-24

Campaign: honest status, `provider verify`, `provider context`, model diagnostics (epic #1689).
Lab binary: Studio local `swift build -c release --product macprovider-cli` at `e888ecce`
(detached worktree `~/macprovider-1689-e2e`).
Lab target: isolated `127.0.0.1:18180` (plus a short-lived `18182` for item i), `--no-join`.
Live `:8080`: read-only commands only. Nothing written under `~/.config/macprovider/`.

Paths are home-redacted (`~`), provider IDs are cut to 6 characters, session IDs and keys are left out.

## Binary

| Field | Value |
|---|---|
| Path | `~/macprovider-1689-e2e/phase3-binary/.build/release/macprovider-cli` |
| SHA-256 | `c3bf62aa2bc883a4b5637f3db9e61851fc0225fa6c3c7857ade3fb5242f4e7ea` |
| `--version` | `1.8.123` (shared constant; the build identity is the SHA) |
| Build | `Build of product 'macprovider-cli' complete! (264.55s)` |
| mlx.metallib | copied read-only from `~/macprovider/mlx.metallib` (sha `84e48718…fbaf`, identical) |

## Lab harness requirements (not PR defects; needed to isolate a second serve)

- A serve without `credential_store: protected_file` runs `execCanonicalInstall` (`MacProviderCLI.swift:1624-1629`, #616) and re-execs into the installed `~/macprovider/macprovider-cli` (the released 1.8.123). My first 18180 instance (pid 6896) was running the RELEASED binary, not the lab build. I killed it (my own config path, checked first) and restarted with `protected_file`. `~/.local/bin` symlinks were unchanged (mtimes Sep 23 05:12 / Sep 18).
- `FileManager.temporaryDirectory` ignores `TMPDIR`. The default control socket `$DARWIN_USER_TEMP_DIR/macprovider-cli/ctl.sock` belongs to the live provider. A second serve refuses to start (`control socket … already exists; remove the stale file`). I did not remove it.
- Isolation env: `MACPROVIDER_LIFECYCLE_ROOT`, `MACPROVIDER_WATCHDOG_STATE_DIR`, `MACPROVIDER_PROTECTED_CREDENTIAL_ROOT`, `MACPROVIDER_MODEL_ARTIFACT_ROOT`, and `HF_HOME` all pointed under `~/lab-1689-e2e/`. Without `MACPROVIDER_LIFECYCLE_ROOT`, a second serve shares `~/Library/Application Support/macprovider/lifecycle/state-v1.json` with live. The lab serve used a private `/private/tmp/macprovider-autotune-<uuid>/control.sock`.
- Model bytes: APFS clones (`cp -c`) of the durable Llama-3.2-3B and Qwen3-8B copies into `~/lab-1689-e2e/artifacts`. Real caches were never modified.
- **Operator error during the run (disclosed):** one `models switch qwen3-8b --ctl-socket-path <S>` went to the OTHER session's lab instance (pid 55838, `~/lab-ac25-m2/ab/base`). My `lsof -p PID -U` without `-a` OR-ed the filters and returned the wrong socket. That serve rejected the request (`switch rejected`, exit 4). Afterwards it was still the same pid and listening, `/v1/status` on 18080 reported `ready qwen3-coder-30b-a3b-instruct 200000×8`, and nothing changed. Every later call used `lsof -a`.
- **Harness error, corrected:** early prepare and verify-artifact runs through my `run.sh` wrapper re-sourced `env.sh`, which reset `MACPROVIDER_MODEL_ARTIFACT_ROOT` and `HF_HOME` to the healthy `artifacts/` root. Those runs were discarded and re-run with the intended roots. Only the re-runs are reported below.

## Step 2 — live :8080, read-only, new CLI against a 1.8.123 serve

| Check | Result | Verdict |
|---|---|---|
| `status --advanced` | exit 0. Readiness split into 4 lines (Local inference ready / Coordinator connected / Network buyer_serving / Catalog trust safe_offline_fallback). `Startup probe: 6.9 tok/s (not a sustained benchmark)`. `Sustained benchmark: 37.1 tok/s (benchmark spec-023-qwen/qwen3.6-27b-…, 2026-09-22T14:23:06Z)`. Warning: probe is under 50% of the sustained benchmark. `Context cap: 200000 tokens` with no source (old serve does not send one). `URL: wss://coordinator.malibu.tech/ws/provider (from config)`, not `<unknown>`. | PASS |
| `status` (plain) | exit 0, operator-language summary | PASS |
| `status --json` | exit 0, raw passthrough. `capacity` has only the legacy keys; no `coordinator_origin`, no `capacity_provenance_v1`. No crash. | PASS (degrades gracefully) |
| `provider verify --timeout 60` | exit 7 after 1 s. `✓ Local`, `✓ Network: connected; available to customers`, `… Public feed: the running provider does not report its coordinator (it predates coordinator_origin_v1) … this shell's config names wss://coordinator.malibu.tech, which may not be the coordinator the provider uses.` | PASS (see L1) |
| `provider verify --json` | `exit_code 7`, `outcome public_feed_unavailable`, layers local=pass, network=pass, public_feed=unverifiable, `unverifiable_fields [provider_id, per_provider_context]` | PASS |
| `provider context explain` | Effective 200000 (config max_context_override, operator). RAM default 200000 for 256 GB. Model limit 262144 (config.json; tokenizer 262144). Slots 8. KV about 97.7 GiB for 8 × 200000; about 177.8 GiB available after 15.0 GiB weights + 4 GB reserve (fits). Advertised 200000 (connected). Numbers checked by hand: Qwen3.6-27B has 16 full_attention layers × 4 kv × 256 head_dim × 4 B = 65,536 B/token; × 1.6 M = 97.7 GiB; (256 − 15 − 4) × 0.75 = 177.8. Sane. | PASS (see L2) |
| `models identity` / `--json` | `hashes agree: yes`, served = catalog `518ef47c…7931`, revision `c000ac2c…`, `model_served_identity.v1` | PASS |
| `models verify-artifact qwen/qwen3.6-27b` (+`--json`) | `verdict: match`, location `durable_store`, path shown as `<durable_store>/…`, `source=live_signed`, 16,081,490,064 bytes. 8 s each. Partials: 2 interrupted `hf_download_staging` (29,712 B). No home path, provider id, or token in either output. | PASS |

Live config SHA-256 before and after my commands: `4f04981f…` → a different session changed it at 03:53Z (slots 8 → 1, backup `config.yaml.pre-honest-capacity-20260924`) → `df35f383…` at the end. No `config.yaml.bak-1790…` or `config.yaml.latest-backup` from this CLI was created in `~/.config/macprovider/`.

## Step 3 — isolated :18180 (Llama-3.2-3B, lab roots)

| Check | Result | Verdict |
|---|---|---|
| `/v1/status` capabilities | `capacity_provenance_v1`, `coordinator_origin_v1` present. `capacity`: `max_context_source ram_tier_default`, `throughput_source startup_probe`, `throughput_probe_max_tokens 8`, `throughput_probe_model meta-llama/llama-3.2-3b-instruct`. `coordinator_origin ws://127.0.0.1:1` (the configured URL; `--no-join`). | PASS |
| `status --advanced` | `Context cap: 200000 tokens (source: RAM-tier default)`; `Startup probe: 3.3 tok/s (8-token probe on meta-llama/llama-3.2-3b-instruct; not a sustained benchmark)`; Coordinator `not connected`, Network `catalog_update_required` | PASS |
| `provider verify --timeout 0 --json` | exit 3 `network_not_serving`: local pass, network fail "not connected to the coordinator", feed pending | PASS |
| `provider verify --timeout 5/10/20/30` | **exit 2 `local_not_ready`: "local status on 127.0.0.1:18180 did not answer before the verification deadline"**, although local is ready (elapsed 5.1/10.1/20/30.1 s) | **FAIL → F1** |
| `context set 65536 --preflight` | exit 0, "Preflight passed. Nothing was written." Config hash unchanged. | PASS (see F2) |
| `context set 150000 --preflight` | exit 1, `Refused: 150000 is above this model's limit of 131072 tokens.` | PASS |
| `context set 3999` / `1000001` | exit 1, `Refused: context must be between 4000 and 1000000 tokens.` | PASS |
| KV × slots over memory (`max_concurrency_override: 16`, `set 131072`, with and without `--preflight`) | exit 1. `about 224.0 GiB … 16 slots × 131072 …; about 187.7 GiB available (does not fit)` `Refused: … Nothing was written.` Config byte-identical, no backup. | PASS |
| `context set 65536` (write, no `--apply`) | exit 0. Wrote the value; backup `config.yaml.bak-1790218148-0` (0600) plus `config.yaml.latest-backup`. Backup = pre-write config without the `provider_token` line (a dummy `lab-dummy-not-a-secret` token was planted for this test). Diff: +`max_context_override: 65536` only. | PASS |
| Manual restart of 18180, then verify | `/v1/status` `65536 operator_config slots 1`; `verify --timeout 0` proof `max_context_tokens 65536`; `explain` Effective 65536 (source: config.yaml max_context_override), set by the operator | PASS |
| `context set --apply` / `rollback` | NOT RUN. The restart is `CredentialRestartProver.restartLaunchdProvider` → `launchctl kickstart -k gui/<uid>/live.malibu.provider` (`CredentialsCommand.swift:793-810`), whatever `--config` or `--port` says. Rollback has no no-restart mode. | **FINDING F3** (code-confirmed) |
| Provenance (hand-crafted FR-20b line, value 65536, model = configured) | explain: `written by an autotune recommendation for meta-llama/llama-3.2-3b-instruct at 2026-09-24T04:00:00Z (benchmark lab-handcrafted)`. After restart, status: `source: config.yaml max_context_override written by an autotune recommendation`; `/v1/status` `recommendation_apply`. | PASS |
| Hand edit to 60000 (record still says 65536) | `set by the operator` | PASS |
| Record with `model: ""` / scalar `"garbage"` / list `[1, 2]` / missing model / `source: operator` | all `set by the operator`, config loads | PASS |
| Record naming another model (`qwen3-8b`) | `Warning: this value was generated for qwen3-8b, but meta-llama/llama-3.2-3b-instruct is configured now. …` | PASS |
| YAML-syntax-broken record (`[broken`) | `Error: Invalid YAML in config …` for explain and status. This is a YAML parse error, outside FR-20b's "malformed record", which covers a well-formed non-mapping value. | INFO |
| Warm switch llama (generated 65536, 8 slots) → qwen3-8b | `Context window: 40960 tokens, recomputed for qwen3-8b (the configured 65536 was generated for another model).` `/v1/status` `40960 recommendation_adoption slots 8`. status: `Startup probe is stale: it ran on meta-llama/…, but qwen3-8b is served now.` | PASS (see L3) |
| Switch back → llama | `65536 recommendation_apply slots 8`; status shows "written by an autotune recommendation" | PASS |
| Operator-owned 65536 → switch to qwen3-8b (declared max 40960) | kept at `65536 operator_config` with no warning | **FINDING F6** |
| R018 pair, qwen3.6-27b (`autotune --recommend --check-only --installed-only --json --no-submit-hardware-evidence --candidate-models mlx-community/Qwen3.6-27B-4bit`, no benchmark) | exit 0, 9 s. `serve_config` `max_context_override 200000`, `max_concurrency_override 8`. Durable-root listing unchanged. | PASS (200000 × 8) |
| R018 pair, GLM-4.5-Air | Binary: `installed_only_missing_verified_artifact`. The Studio's HF snapshot uses symlinks, and `verify-artifact` reports `path escape`. A materialized APFS clone hashes `7fbf8e50…`, but the signed hash is `350c018e…` (`likely_source catalog_row`), so the tool cannot produce the pair on this box. By hand from the verified config.json formula (46 layers × 8 kv × 128 × 4 = 188,416 B/token; usable (256 − 80 − 4) × 0.75 GiB): context `min(200000, 131072, 739142) = 131072`, fit slots `5`. | PARTIAL (formula 131072 × 5; binary blocked, F8) |
| R018 pair, Llama-3.2-3B (installed-only, lab roots) | `131072 × 8` | PASS |
| `models prepare --profile catalog` (a) healthy durable copy | `ready (verified)`, exit 0, `download_attempted false` | PASS |
| (b1) corrupt durable copy (1 byte appended to `tokenizer_config.json` in the clone), no `--repair-cache` | exit 2, `incomplete`, error "the pinned copy (durable_store) exists but does not verify; rerun with --repair-cache", retry command shell-safe. Corrupt file untouched (sha unchanged). | PASS |
| (b2) same, plus a valid pinned HF snapshot, `--repair-cache` | exit 0, `ready (verified)`, durable copy replaced (file hash restored), `blobs/*.incomplete` partial removed (1/1) | PASS |

## Step 4 — audit-carried checklist

| Item | Verdict | Evidence |
|---|---|---|
| (a) `/poolz.routing_eligible` ignores the R-2.7 material gate | **CONFIRMED by code**, not lab-reproduced (no local coordinator in this lab) | `publicRoutingEligible` → `canaryBuyerServing` (`phase4-coordinator/internal/ws/server.go:1297-1345, 1422-1424`) checks `RoutingEligible`, transport, context > 0, `tier2WarmupExcluded`, and the version floor. It never calls `catalogMaterialMissingUnderEnforce` (`internal/buyer/route_snapshot.go:53`). Under enforce, `/poolz` can show `routing_eligible: true` for a session routing excludes. The same predicate feeds the FR-CAN22 last-provider floor. |
| (b) `--repair-cache` success hides a partial-cleanup failure | **REPRODUCED** | Undeletable `snapshots/.download-labstuck` (`sub/` chmod 500) in the COPY: JSON `partials_found 1, partials_removed 0, error null, final_state ready_verified`, exit 0. Human output: `partials: 1 found, 0 removed (pass --repair-cache to remove interrupted downloads)` although `--repair-cache` was passed. Cause: `finalize()` sets `outcome.error = nil` on match (`ModelArtifactDiagnostics.swift:~1058-1063`), dropping the "repair-cache could not remove: …" error set at `:~966-984`. |
| (c) legacy measured sweep emits its own slot count | **CONFIRMED by code** | Classic autotune `applyConfig` (`AutotuneCommand.swift:2164-2170`) → `ConfigApplier.apply(recommendation:)` writes `knobs.maxBatch` and `knobs.maxContext` from Stage-2 hill-climb cells (`ConfigApplier.swift:583-584`). It never passes through `memoryBoundedSlots`, yet still writes a `recommendation_apply` provenance record (`ConfigApplier.swift:~103-114`). R018 item 9's joint bound does not apply. |
| (d) hand-raised slots not re-checked | **CONFIRMED** (mechanism; no breach possible with small models at 256 GB) | Serve takes `resolved.maxConcurrencyOverride ?? 1` unchecked (`MacProviderCLI.swift:698, 2035`, comment at `:2113` "Operators opting in via --max-batch >1 own the safety check"). Only `provider context set` and `explain` compute the KV fit; `explain` would print "does not fit". Serve and status do not. |
| (e) switch 4K floor with high slots | **CONFIRMED by code**, not reachable on this 256 GB box | `ModelSwitchContext.recomputedContext` → `memoryBoundedContext` (`AutotuneRecommend.swift:393-427`) bisects down to `minimumServeContext` (4000) and returns it even when 4000 × slots does not fit. On a small Mac with a tier/hand slot count > 1, a warm switch to a large-KV model lands at ≈4K context, the symptom this PR fixes on the recommend path. Slot limit is 8 (`ProviderStatus.swift:182`). |
| (f) sliding-window KV not counted | **CONFIRMED, immaterial (LOW)** | `kvCacheBytesPerToken` counts only `full_attention` layers. Catalog models on disk: gpt-oss-20b (12 sliding, window 128) omits about 3 MiB/slot; gpt-oss-120b (18 sliding, window 128) about 4.5 MiB/slot; gemma-4-26b (25 sliding, window 1024, kv 8, hd 256) omits about 200 MiB/slot, but its full layers are overcounted 2× (code uses kv 8 / hd 256 where the config declares `num_global_key_value_heads 2` / `global_head_dim 512`). Net conservative. Nemotron-3-Nano (hybrid Mamba, no `layer_types`) counts all 52 layers where about 6 are attention. That overcounts about 8× and undersizes context/slots, which is conservative. |
| (g) slot-only override recreates the context × slots breach | **REPRODUCED (mechanism)** | Config: generated `65536` (provenance `recommendation_apply`), no slot key. `serve --max-batch 8` → `/v1/status` `ctx 65536 recommendation_apply slots 8`, no re-bound. Switch away recomputes the target with slots (qwen3-8b 40960 × 8). Switch back restores `65536 × 8` unchanged: `serveContextsByTarget` always returns the configured value for the configured model (`ProviderContextCommand.swift:~727-733`). Fits here (56 GiB). The GLM-4.5-Air pair (131072 generated for 5 slots) at `--max-batch 8` would need about 184 GiB KV against about 129 GiB usable. Big-model load deferred per the memory rule. |
| (h) `models adopt-recommendation` with over-cap signed slots adopts HF bytes before rejecting | **CONFIRMED by code, write demonstrated on the shared function** | `ModelsSubcommand.swift:1900` calls `verifiedExistingArtifact(for:)` before `validateSignedContextAuthority` (`:1914`). With no durable copy, it adopts the HF snapshot into the durable store (`AutotuneRecommend.swift:4096 adoptVerifiedStaging`). Demonstrated in lab roots: `autotune --recommend --check-only --installed-only` (same function) created `i-art/mlx-community--Llama-3.2-3B-Instruct-4bit/7f0dc…/e7e5…`, although its own guard says "background checks never benchmark or populate shared caches". I did not build a signed recommendation (needs the HMAC-bound, hardware-bound signing path). |
| (i) HF-only prepare says ready, serve fails | **REPRODUCED** | Lab roots: valid pinned HF snapshot, empty durable store, config `model_artifact_path` = the (absent) durable path. `models prepare --profile catalog` → `ready (verified)` exit 0, `download_attempted false`, durable still empty. `verify-artifact` → `match` (`hf_cache_snapshot`). `serve` → `model artifact verification failed for …/i-art/…/e7e5…: missing pinned snapshot` / `provider startup preflight failed: ExitCode(rawValue: 2)`. When `model_artifact_path` points at the HF snapshot itself, serve starts. |

## Findings

- **F1 (MEDIUM). `provider verify` misreports every timed-out run as `local_not_ready` (exit 2).** Repro: isolated `--no-join` serve, `provider verify --port 18180 --timeout 5` → exit 2 "local status … did not answer before the verification deadline". With `--timeout 0` the same instance gives exit 3 `network_not_serving`. Cause: `ProviderVerifier.run` (`ProviderCommand.swift:188-206`) sleeps `min(backoff, remaining)` up to the deadline, then calls `evaluateOnce()` again. `boundedFetch` throws `DeadlineReached` for the local fetch, and that report is returned. Exit 3 (network) and exit 5 (stale feed) are therefore unreachable once polling runs to the deadline. The same mislabel reaches `context set --apply` and `rollback` verification. Fix direction: return the last completed report when the remaining time after the sleep is ≤ 0, or do not sleep to the deadline exactly.
- **F2 (MEDIUM). `set` and `explain` count slots serve does not run.** With no `max_concurrency_override`, `fileSlotCount` uses `ProviderCapacity.defaults(...).concurrency` (8 on 256 GB; `ProviderContextCommand.swift:444-449`). Serve runs `maxConcurrencyOverride ?? 1` (`MacProviderCLI.swift:698, 2035`), and live `/v1/status` reported `max_concurrency 1`. Output said: "after a restart it uses 8 from config.yaml, which is what the memory check counts", which is false. The error is conservative, so it can wrongly refuse values (8× KV). The same RAM-tier assumption is in SPEC-001 FR-20b ("else the RAM-tier default"), so this is a spec+code reconciliation.
- **F3 (MEDIUM). `context set --apply` and `rollback` always restart the launchd `live.malibu.provider` job**, whatever `--config` or `--port` names. Rollback has no no-restart mode. On a box with a lab instance, `--config ~/lab/config.yaml --apply` would write the lab file and then `kickstart -k` the LIVE provider, and verification would then check the lab port. Code: `ProviderContextCommand.swift:150` → `CredentialsCommand.swift:793-810`. Not executed.
- **F4 (MEDIUM, (b)).** `--repair-cache` success hides a partial-cleanup failure, and the human hint says to pass the flag that was already passed.
- **F5 (MEDIUM, (i)).** `prepare --profile catalog` reports `ready (verified)` from the HF snapshot while serve, configured with the durable path, fails `missing pinned snapshot`. Prepare does not adopt into the durable store.
- **F6 (LOW/MEDIUM). Contexts above the model's declared max are served and advertised without a warning.** (1) An operator-owned 65536 is kept through a warm switch to qwen3-8b (declared 40960). (2) With no override, serve advertises the RAM-tier 200000 for Llama-3.2-3B (declared 131072); `explain` prints `Model limit: 131072` beside `Effective: 200000` and does not warn. FR-20b only requires the under-use warning. (2) predates this PR.
- **F7 (MEDIUM, (h)).** HF-to-durable adoption happens before validation: in `adopt-recommendation` (code) and in `--check-only --installed-only` (demonstrated in lab roots). The latter contradicts its "never populate shared caches" message.
- **F8 (INFO, env).** GLM-4.5-Air on this Studio: the HF snapshot is symlink-based (`path escape`; the diagnosis says "config.json missing / no weight files", which is misleading). Materialized bytes hash `7fbf8e50…` against signed `350c018e…`. Either the local download or the catalog row is off. Not investigated further.
- **(a) (c) (e) (g)**: see the checklist. (a), (c), and (e) are code-confirmed. (g) is reproduced as a mechanism.
- **L1 (LOW).** The human `provider verify` uses `…` (the pending glyph) for a terminal `unverifiable` feed layer.
- **L2 (LOW).** The `explain`/`set` resource check lists every `macprovider-cli serve` on the host (other sessions' lab serves on other ports and configs) as "more than one provider process is running … Stop the extra one yourself". It is not scoped to the config or port.
- **L3 (LOW).** A warm-switch recompute is labelled `recommendation_adoption` / "adopted recommendation" in status, although nothing was adopted. This matches the SPEC-001 FR-17 wording but reads oddly.

## Host events during the run (not caused by this session)

- 03:53Z: a different session (Codex "honest-batching-status") restarted live with slots 8 → 1 (pid 47082 → 92252).
- 04:32:37Z: live was **jetsam-killed**. `launchctl print`: `last exit reason = JETSAM_REASON_MEMORY_VMCOMPRESSOR_SPACE_SHORTAGE`, exit -9, runs = 4. launchd restarted it as pid 46063. The other session's lab serves (4087, 44969, 44973) disappeared at the same time. It later ran two about 84 GB-RSS lab serves on 18080/18081. My 18180 instance was an idle Llama-3.2-3B (about 2 GB weights, 65536 × 1 context). I had stopped it seconds earlier, and my next serve exited on argument validation. Live came back `busy buyer_serving qwen/qwen3.6-27b 200000 × 1`.

## Cleanup and final state (04:52Z)

- My 18180 serve (pid 76955) stopped. My 18182 serve exited on its own (preflight failure). No `lab-1689-e2e` process is left.
- `~/lab-1689-e2e` and the `~/macprovider-1689-e2e` worktree are kept for re-runs. The undeletable test partial was re-chmodded `u+w`.
- Live :8080: pid 46063 (launchd restart after jetsam, not the 92252 given in the handoff), `busy buyer_serving qwen/qwen3.6-27b 200000 1`, config sha `df35f383…` (unchanged since the other session's 03:53Z edit).
- :18080/:18081: no longer listening at the end. The other session's instances exited, and my commands never targeted them, apart from the one rejected switch disclosed above.

## Not run / skipped

- `provider context set --apply` and `rollback`: they restart the live launchd job (F3).
- `autotune --recommend --apply`: it needs a benchmark or a cache-only prefetch receipt. I used a hand-crafted provenance record instead.
- GLM-4.5-Air load / `--max-batch 8` breach demo: large-model load deferred under the memory rule.
- `models adopt-recommendation` with a signed over-cap recommendation: signing needs the local HMAC/hardware path; confirmed by code plus the shared-function demo.
- Local coordinator for (a): not started (resource rule).
- No test suites were run.

## Confirmation re-run (3c0006e3)

Studio worktree `~/macprovider-1689-e2e` was checked out detached at `3c0006e33a527853541d97b793d06be189338ae7` (`git rev-parse HEAD`). Release build: `Build of product 'macprovider-cli' complete! (131.87s)`.
Binary SHA-256: `4bc1e8b3eaa8a5c303bed4111fbbd847b6c05ea159c669febef2d26f79bcbc0e`. Same isolation as before: `protected_file`, lab lifecycle/watchdog/credential/artifact/HF roots, private control socket (owner checked with `lsof -a` before every switch), ports 18180/18182 only.
At the start, live :8080 was pid 46063 `unavailable`, lifecycle `paused_by_operator`, model loaded.

| Check | Result | Verdict |
|---|---|---|
| F1 `provider verify --port 18180 --timeout 5/10/30 --json` (`--no-join`) | All three: `exit 3 network_not_serving`; local `pass`, network `fail` "not connected to the coordinator", feed `pending`. Elapsed 5/10/30 s. Human `--timeout 5`: `✓ Local provider … ✗ Network … Not verified: Network — not connected to the coordinator`, exit 3. | PASS |
| L1 live `provider verify --timeout 20` (paused live) | `✓ Local`, `✗ Network: connected; network state buyer_serving_unknown`, `? Public feed: the running provider does not report its coordinator …`, `? Not checkable …`, exit 3. The unverifiable layers use `?`. | PASS (see N2) |
| F2 no `max_concurrency_override`: `context set 131072 --preflight` | `Memory: about 14.0 GiB … 1 slots × 131072 …(fits)`, "Preflight passed. Nothing was written". No "from config.yaml" slot claim. | PASS |
| F2 `explain` | `Slots: 1`, KV for `1 slots × 65536` | PASS |
| L2 resource line | `Resource check: other serve processes on this Mac: pids 45411, 46063. The KV-memory estimate does not count their memory.` (45411 = the lab serve being explained; 46063 = live). Neutral, no "stop the extra one". | PASS (see N3) |
| F3 `context set 60000 --config ~/lab-1689-e2e/config.yaml --port 18180 --apply` | exit 1: `Refused --apply: ~/lab-1689-e2e/config.yaml on port 18180 is not the installed provider service (no installed provider service (live.malibu.provider) was found), so restarting it would restart another provider. Nothing was written. …` Config hash `d8f0b6a7…` unchanged; live pid 46063 unchanged. | PASS (see N1) |
| F3 `context rollback --config … --port 18180` | exit 1: `Refused rollback: … Run \`malibu-cli provider context rollback --no-restart --config … --port 18180\`, restart the provider that uses this config yourself …` Config unchanged; live pid 46063 unchanged. | PASS |
| F3 `context rollback --no-restart --config …` | exit 0: `Restored settings from ~/lab-1689-e2e/config.yaml.bak-1790218148-0; the replaced config was saved at ~/lab-1689-e2e/config.yaml.bak-1790228283-0.` `Not restarted. …` The restored config has no override (the backup predates the 65536 write). Live pid 46063 and lab pid 45411 unchanged. | PASS |
| F4 undeletable `snapshots/.download-labstuck` + corrupt durable copy, `prepare --repair-cache` | Human, exit 0: `partials: 1 found, 0 removed` / `warning: --repair-cache could not remove 1 interrupted download artifact(s): .download-labstuck: … don't have permission …; remove them by hand` / `final: ready (verified)`. No "pass --repair-cache" hint. JSON: `"cleanup_failed":[".download-labstuck: …"]`, `final_state ready_verified`, exit 0. | PASS |
| F5 valid HF snapshot + empty durable store + config path = durable path | `prepare --profile catalog --json` → `ready (verified)`, and the durable copy now exists (`i-art/mlx-community--Llama-3.2-3B-Instruct-4bit/7f0dc…/e7e5…`). Isolated serve on :18182 with the same config/roots → listening, `ready meta-llama/llama-3.2-3b-instruct e7e5bff42487`. Stopped afterwards. | PASS |
| F7 `autotune --recommend --check-only --installed-only --json --no-submit-hardware-evidence --candidate-models mlx-community/Llama-3.2-3B-Instruct-4bit` (HF-only lab roots, empty durable) | exit 0, `recommended_model meta-llama/llama-3.2-3b-instruct`, `131072 × 8`. `find i-art` identical before and after (still empty). | PASS |
| (g) generated 65536 (provenance line) + `serve --max-batch 8`, Llama-3.2-3B | `/v1/status` `65536 recommendation_apply slots 8`; status `source: config.yaml max_context_override written by an autotune recommendation`. No lowering at 256 GB, as expected (8 × 65536 × 114,688 B ≈ 56 GiB fits). Switch to qwen3-8b and back: back → `65536 recommendation_apply slots 8`. | RECORDED (no lowering expected) |
| (g) GLM-4.5-Air lowering demo | Not runnable: the GLM snapshot on this Studio fails its signed hash (F8), and loading it is excluded by the memory rule. | DEFERRED |
| F6 operator 65536 → `models switch qwen3-8b` | Notice: `Warning: the context window (65536 tokens) is above qwen3-8b's declared maximum of 40960 tokens; requests longer than that may fail or degrade. It was not changed. To lower it: malibu-cli provider context set 40960 --preflight`. `status --advanced` on qwen3-8b shows the same warning. `/v1/status` `65536 operator_config`. | PASS |
| F6 unset override, Llama-3.2-3B | `/v1/status` `200000 ram_tier_default`. `explain` and `status --advanced` both: `Warning: the context window (200000 tokens) is above meta-llama/llama-3.2-3b-instruct's declared maximum of 131072 tokens; … To lower it: malibu-cli provider context set 131072 --preflight`. | PASS |
| L3 switch recompute label | Switch notice: `Context window: 40960 tokens, recomputed for qwen3-8b (the configured 65536 was generated for another model).` `/v1/status` `40960 recommendation_adoption slots 8`; status `Context cap: 40960 tokens (source: recommendation for the served model (adoption or model switch))`. | PASS |
| (c) classic sweep | Skipped: classic `autotune` (Stage 1/2) benchmarks by design and has no offline mode. | SKIPPED |

### New findings (confirmation run)

- **N1 (LOW/MEDIUM, fails closed). The F3 guard reports "no installed provider service (live.malibu.provider) was found" on this Studio, but the job IS installed.** `liveInstalledService` picks the plist by `CredentialRestartProver.launchdDomain(for:)`, which returns `system` for any `credential_store: protected_file` config (`CredentialsCommand.swift:779-785`). It therefore reads `/Library/LaunchDaemons/live.malibu.provider.plist`, which does not exist. This Studio runs the real provider as a **gui LaunchAgent** (`~/Library/LaunchAgents/live.malibu.provider.plist`, ProgramArguments `~/macprovider/macprovider-cli serve --config ~/.config/macprovider/config.yaml`) while its config says `credential_store: protected_file`. Consequences:
  - The refusal reason is factually wrong.
  - On such installs `set --apply` and `rollback` against the REAL live config would also be refused. Code-deduced, not run (would target live).
  - The pre-existing restart helper would `sudo -n launchctl kickstart system/…`, which does not reach a gui job either.

  Safe (no wrong restart), but `--apply` is unusable on GUI-installed protected_file providers, and the message misleads. Likely pre-existing domain inference (see the memory note "Private-candidate GUI install recipe").
- **N2 (LOW).** On the operator-paused live provider, `verify` prints `✗ Network: connected; network state buyer_serving_unknown`. It does not name the pause (`lifecycle paused_by_operator`), so an operator cannot tell a pause from a network problem.
- **N3 (LOW).** The L2 line "other serve processes on this Mac" lists the serve that is being explained (pid 45411, the process on the queried port) as "other".

### Live and host during the confirmation run
- Live pid 46063 (paused) was unchanged through F3. Mid-run, at 05:38:36Z, live restarted as **pid 48671**: lifecycle `last_restart.reason_code launchd_service_started`, `operator_paused false`, and launchd shows no jetsam exit reason this time.
  - None of my commands in this run can restart launchd. The only restart paths (F3 `--apply`/`rollback`) were refused, and live was still 46063 right after them.
  - This is consistent with the operator resuming the pause.
  - At the end live is `ready buyer_serving`, lifecycle `serving_buyers`, config sha `df35f383…` (unchanged), and no backups from this CLI in `~/.config/macprovider/`.
- My :18180 (last pid 58363) and :18182 (pid 51027) serves are stopped. No `lab-1689-e2e` process is left. No other lab serves were running.

## E2E round 3 (061e55e6)

Studio worktree `~/macprovider-1689-e2e` was checked out detached at `061e55e6fc492ab62130d9293a29e29eb0a52a05`. Release build: `complete! (127.12s)`.
Binary SHA-256: `6239170ae175322cf313db3a4449e7ecd7e9fc72515c834b9c83bf82d401ad60`.
Live :8080 at the start: launchd `pid = 48671`, `ready buyer_serving`. Another session's lab serve (pid 74654, `~/lab-ac25-m2/q36`, :18080) was running and was not touched. My lab serve: pid 82326 on :18180 (`protected_file`, lab roots, no override). A short-lived F5 serve ran on :18182.

| Check | Result | Verdict |
|---|---|---|
| N1 `explain --config ~/.config/macprovider/config.yaml` | `Installed:    gui/501/live.malibu.provider (config ~/.config/macprovider/config.yaml, port 8080)` | PASS |
| N1 `explain --config lab --port 18180` | same `Installed:` line | PASS |
| N1 `set 60000 --config lab --port 18180 --apply` | exit 1: `Refused --apply: the installed service gui/501/live.malibu.provider runs ~/.config/macprovider/config.yaml on port 8080; this config is ~/lab-1689-e2e/config.yaml on port 18180, so restarting it would restart another provider. Nothing was written. …`. Lab config sha `94252629…` unchanged. Live `pid = 48671` before and after. | PASS |
| N1 `rollback --config lab --port 18180` (restart mode) | exit 1, same accurate wording, suggests `--no-restart`; nothing written; live pid unchanged | PASS |
| N2 pause my lab serve via ITS socket (owner checked `lsof -t` = 82326 only), `{"type":"pause_request"}` → `pause_ack accepted:true` | `/v1/status` `unavailable`, lifecycle `paused_by_operator`. `verify --port 18180 --timeout 0`: `✗ Local provider: … loaded but status is unavailable` / `✗ Network: paused by operator (resume it from Malibu or its control socket)`; **exit 2** `local_not_ready`, headline "Not verified: Local provider — … status is unavailable" | PASS for the network wording; exit 2 instead of the expected 3 (see N4) |
| N2 resume (`resume_request` → `resume_ack accepted:true`), watched 120 s | pid 82326 stayed alive and listening throughout. Status `ready`, lifecycle `degraded_serving` (the `--no-join` steady state), uptime kept increasing (67 → 178 s). **No restart or exit** for a non-launchd `--no-join` serve. The earlier "live restarted ~1 min after resume" lead is therefore not reproduced outside launchd/join. | RECORDED |
| N3 `explain --config live` resource line | `other serve processes on this Mac: pids 74654, 82326` (live 48671 excluded). Explaining the lab config: `pids 48671, 74654` (lab 82326 excluded). | PASS |
| F1 smoke `verify --port 18180 --timeout 5` | exit 3 `Not verified: Network — not connected to the coordinator` | PASS |
| F2 smoke `explain` (no override) | `Slots: 1` | PASS |
| F6 smoke (unset override, Llama-3.2-3B) | `Warning: the context window (200000 tokens) is above meta-llama/llama-3.2-3b-instruct's declared maximum of 131072 tokens …` | PASS |
| F3 smoke `rollback --no-restart --config lab` | `Restored settings from …bak-1790228283-0; the replaced config was saved at …bak-1790229950-0.` `Not restarted.` Live pid 48671 and lab listener 82326 unchanged. | PASS |
| F4 smoke (undeletable partial, `--repair-cache --json`) | exit 0, `ready_verified`, `cleanup_failed:[".download-labstuck: …"]`, `partials_found 1, removed 0` | PASS |
| F5 smoke (HF-only, empty durable, path = durable) | `prepare` → `ready (verified)`, durable copy created; serve on :18182 → `ready`, then stopped | PASS |

### New finding (round 3)
- **N4 (LOW).** A paused serve reports `/v1/status` `status: unavailable`, so `verify` fails the **local** layer first. It exits 2 with the headline "Local provider — … status is unavailable", although the correct pause reason is on the network line. Per FR-20a (local passes only on `ready`/`busy`) this is spec-conformant. However, the exit code and headline do not say "paused". Suggest a paused-specific local reason, or letting `paused_by_operator` decide the headline.

### Carried items not changed by the fix rounds (code identical at 061e55e6)
- (a) `/poolz.routing_eligible` ignores R-2.7: `phase4-coordinator/internal/ws/server.go` still has no catalog-material check in `canaryBuyerServing`/`publicRoutingEligible`. Code-confirmed only.
- (e) `memoryBoundedContext` still returns the 4000 floor without re-checking fit (`AutotuneRecommend.swift`). Unreachable on 256 GB.
- (c) The classic sweep apply still writes its own slot count (no `memoryBounded*` added in `AutotuneCommand.swift`).
- (d)/(g) Serve accepts an operator-raised or CLI slot count without a KV re-check. Documented "operator owns the safety check". No lowering observed at 256 GB.
- (f) Sliding-window KV not counted. Immaterial, net conservative.
- F8 (INFO, environment) The GLM-4.5-Air snapshot on this Studio fails its signed hash.

### Tally (open items at 061e55e6)
- CRITICAL 0
- HIGH 0
- MEDIUM 2, both carried, code-level, not lab-reproducible here: (a) `/poolz` material gate; (e) switch 4K floor with high slots
- LOW 4: N4 (new); (c) classic sweep slots; (d)/(g) unchecked operator slot raise; (f) sliding-window KV
- INFO 1: F8

All round-1 and round-2 findings (F1–F7, L1–L3, N1–N3) PASS at 061e55e6.

### Final state (06:06Z)
- My lab serves (82326 on :18180, the :18182 F5 serve) are stopped; no `lab-1689-e2e` process is left.
- Live: launchd `pid = 48671` unchanged, `ready buyer_serving`, lifecycle `serving_buyers`, config sha `df35f383…` unchanged.
- The other session's :18080 (pid 74654) was not touched.

## E2E round 4 (5db3d4c3)

Studio worktree was checked out detached at `5db3d4c3beab345acfd0e4bfbc001da7675d5f07` (Package.resolved reset before building). Build: `nice -n 10 swift build -c release --product macprovider-cli`, `complete! (123.96s)`.
Binary SHA-256: `e4d262e841d48cd8aca9037dc567d711e4f8d2a00f79ee499d736faeef5598fc`.
An earlier build attempt at 10d4d9e0 stopped at "Write sources" before the HOLD. It was never completed or used.

Memory rules followed:
- `memory_pressure` was 98% free before every lab start and after every block.
- Only Llama-3.2-3B-4bit was loaded, with a lab context of 8192 (16384 for (e)). No lab serve ran on any port other than :18180.
- Each serve was stopped right after its block.

Live baseline: launchd `pid = 67930` on :8080, `ready buyer_serving`, lifecycle `serving_buyers`. No other lab serves were running.

| Check | Result | Verdict |
|---|---|---|
| N4: lab serve (pid 84004, 8192 × 1) paused via its own socket (sole owner checked with `lsof -t`); `pause_ack accepted:true`; `verify --timeout 0` | `✗ Local provider: paused by operator (resume it from Malibu or its control socket)` / `✗ Network: paused by operator (…)` / `Not verified: Local provider — paused by operator …`, **exit 3**; no "status is unavailable" | PASS |
| N4 `--json` | `exit_code 3`, `outcome network_not_serving`, local and network reason "paused by operator …" | PASS |
| N4 resume | `resume_ack accepted:true`; status `ready`, lifecycle `degraded_serving` | PASS |
| (e) generated 16384 (provenance line) + `serve --max-batch 8` (pid 85355) | serve.log "does not fit" lines: **0**; `/v1/status` capacity `16384 recommendation_apply`, **`max_concurrency 8`**; `status --advanced` `Context cap: 16384 tokens (source: … written by an autotune recommendation)` and no "Slots lowered" line | PASS |
| N1 `explain --config live` | `Installed:    gui/501/live.malibu.provider (config ~/.config/macprovider/config.yaml, port 8080)` | PASS |
| N1 `set 12000 --apply --config lab --port 18180` | exit 1: "the installed service gui/501/live.malibu.provider runs ~/.config/macprovider/config.yaml on port 8080; this config is ~/lab-1689-e2e/config.yaml on port 18180 … Nothing was written." Lab config sha `0e310659…` unchanged; live `pid = 67930` before and after. | PASS |
| N3 resource line | explain live config: `pids 84004` (live excluded); explain lab config: `pids 67930` (lab excluded) | PASS |
| F1 `verify --timeout 5` | exit 3 `Not verified: Network — not connected to the coordinator` | PASS |
| F2 `explain` lab, no slot override | `Slots: 1` | PASS |
| F3 `rollback --no-restart --config lab` | `Restored settings from …bak-1790229950-0; the replaced config was saved at …bak-1790235688-0.` `Not restarted.` Live pid and lab listener unchanged. | PASS |
| F6 `explain` with no override (config only, no serve) | `Warning: the context window (200000 tokens) is above meta-llama/llama-3.2-3b-instruct's declared maximum of 131072 tokens …` | PASS |
| F4 undeletable partial + `--repair-cache --json` | `final_state ready_verified`, `cleanup_failed` 1 entry, found/removed 1/0. The exit code was not captured in this run (zsh `PIPESTATUS`); it was exit 0 in rounds 2–3. | PASS |
| F5 HF-only + empty durable + path = durable (`config-i4`, :18180, 8192) | `prepare` → `ready (verified)`, durable copy created (3 entries); serve (pid 86556) `ready … 8192`, then stopped | PASS |

### Tally (open items at 5db3d4c3)
- CRITICAL 0
- HIGH 0
- MEDIUM 1:
  - (a) `/poolz.routing_eligible` material gate: **code-only**. Coordinator-side; the round-4 notes say it is fixed and unit-tested, but there is no local coordinator in this lab.
- LOW 4:
  - (c) classic sweep writes its own slot count: **code-only**
  - (d)/(g) serve accepts a raised slot count without a KV re-check: **hardware-reproduced as a mechanism** (fits at 256 GB, no breach)
  - (e) floor-case slot lowering: fixed per the notes and **unit-proven only**. It cannot be reached on 256 GB; the round-4 no-regression check (8 slots kept, no "does not fit") is hardware-verified.
  - (f) sliding-window KV not counted: **code-only**, immaterial
- INFO 1:
  - F8 (GLM snapshot hash on this Studio; environment)
- All hardware-testable findings from rounds 1–3 (F1–F7, L1–L3, N1–N4) PASS on hardware at 5db3d4c3.

### Final state (07:43Z)
- No `lab-1689-e2e` process is left; nothing listens on :18180. The lab config is restored to the round-4 base.
- Live: launchd `pid = 67930` unchanged, `ready buyer_serving`, lifecycle `serving_buyers`, config sha `df35f383…` unchanged.
