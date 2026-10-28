# CLI Release Train — control surface

**This file is the single source of truth for provider CLI releases.** Work happens
across many sessions and agents; before cutting, testing, or promoting a CLI
build, read this file, and after any release-affecting action update it in the
same commit/PR. If reality and this file disagree, fix this file.

## How to track the next CLI

The next-candidate table tracks changes since the current published provider
release. Historical shipped tables preserve earlier trains for reference. Add
a next-candidate row when a CLI/Malibu/installer change merges.

1. A PR that changes `phase3-binary/` (CLI, Malibu.app, installer) **merges** →
   add one row the same day. Status `merged`.
2. A PR is open but not merged → status `in progress`. It is **not** in the
   next candidate.
3. Cut a candidate off `main` → every `merged` row is in that build. If a row
   is still `in progress`, wait or leave it out of scope.
4. Promote that candidate to the fleet → bump “Current promoted stable”, delete
   the shipped rows, start a new table.

Do not put spec-only or CONFORMANCE-only PRs here. They do not change the
binary the Mac runs.

## Core rule (do not violate)

- Private, non-promotable candidate tags do not bump `binaryVersion`; their
  identity lives in the signed `compatibility_set_id`
  (`owner/repo:vX.Y.Z@<commit>`).
- A `promotion_ready=true` candidate **must already carry its final CLI and
  Malibu version in the accepted bytes**. Promotion publishes those exact
  bytes; it cannot rewrite a signed binary. The version-identity bump therefore
  lands immediately before the final candidate cut, while the checked-in and
  live coordinator recommendation remain on the previous stable until
  publication succeeds.
- Promotion then advances the live coordinator `latest_binary_version` and
  `compatibility_set.target_id`, and triggers fleet autoupdate.
- Cut the promotable candidate off the **current `main` tip after all in-scope
  changes are merged** — never promote a candidate that predates a merged
  in-scope change.

Pearl coordinator/gateway release numbering is independent from the provider
CLI train. Failed and superseded tags remain consumed and must not be reused.
Historical tables below do not select today's release version.

Pending gateway-only release content is tracked in the
[coordinator release train](coordinator-release-train.md#pending-runtime-inclusion--public-privacy-disclosures-2026-10-26):
#2159 (`2236eb74a`, issue #2156) updates public privacy disclosures and needs the
next Pearl runtime deployment. It is outside the provider CLI/app candidate;
cutting that candidate does not publish the embedded gateway pages.

## Current published release and fleet target

Verified 2026-10-25 against GitHub release/tag metadata, the release train
(`scripts/ops/cli-release.sh status`: `v1.8.272 train complete`) and live coordinator health:

| Field | Value |
|---|---|
| GitHub provider release | [v1.8.272](https://github.com/Augustas11/macprovider/releases/tag/v1.8.272), promoted 2026-10-25 (promotion run 40152407985) |
| Signed compatibility-set id | `Augustas11/macprovider:v1.8.272@28c06242701de711454f65b4bfb34375d31803c7` |
| Pearl runtime / recommended provider | `v1.8.271` / `1.8.272` (recommendation bump 2026-10-25) |
| Release mirror / installer | `latest.json` → v1.8.272; `get.malibu.tech/install.sh` parity with v1.8.272, consumer health OK |
| Catalog | `published-2026-10-25-glm53-qwen36-native-mtp-v272` (#2141), activated 2026-10-25 02:49–03:12Z; `native_mtp_admission_decode_path` `match` (`4d04a3f3…`) |
| Consumed identities | Provider and runtime tags through **v1.8.272** are consumed (v1.8.271 is a Pearl runtime tag). The next provider CLI takes the next unused tag; refresh both trains and remote tags first. |

## Next CLI release — net changes vs 1.8.272 (tracked 2026-10-26)

Live fleet target: **1.8.272**. Include the merged changes below in the next CLI/app cut.

| PR | Issue | Provider-side change | Status |
|---|---|---|---|
| #2158 | #2155 | Malibu.app retires duplicate app/menu-bar instances after updates: launch-time version election, successor readiness acknowledgement, 35-second quit deadline and forced stale-app exit after 40 seconds; newer running app survives an older rollback launch (SPEC-025-R013/R014). | merged (`79c1c81f6`); next CLI/app cut; signed live acceptance pending |
| #2172 | #2155 | Peer discovery and per-signal identity validation follow the running signed app across activation renames and arbitrary bundle moves, so a legacy app without a handshake reaches the existing 40-second forced-exit deadline. | next CLI/app cut; isolated Studio GUI acceptance PASS; signed release acceptance pending |
| #2161 | #2160 (closed) | Provider-local `/v1/messages` for Claude Code: tools, thinking, JSON/SSE errors and stop metadata over the shared runtime; local priority, cancellation and unbilled accounting; status capability (SPEC-001-R009/R011, SPEC-025-R015). | merged (`9678fc21d`); next CLI/app cut; signed live acceptance pending |
| #2145 | #2143 | GLM-5.3-Flash prompt-snapshot prefix-cache reuse on CB rows with native MTP under the signed cached-turns grant (SPEC-024-R005); touches `ServeDecodePath.swift`, so the decode-path digest changes; identity-only native-MTP admission rebind after the cut. | merged (`b1faa879b`); next CLI/app cut |
| #2149 | #854 | Heartbeat liveness loss requests a socket reconnect while the process and model stay resident; a separate 60-second deadline keeps fatal recovery for stalled local teardown. | merged (`1a058e801`); next CLI/app cut |
| (direct) | #2143 | Test-only: heartbeat regression coverage independent of bulk-transfer scheduling (`ShardLinkAuditFixTests`); no binary change. | merged (`000d72461`) |
| #2162 | #2054 | Malibu.app: chat-first navigation, merged Models destination, embedded Terminal. | merged (`0779d2aab`); next CLI/app cut; signed live acceptance pending |
| [#2165](https://github.com/Augustas11/macprovider/pull/2165) | #2157 | Managed coding-agent privacy: consumer encrypts original Chat, Responses and Messages bodies; provider-local conversion; signed endpoint-family binding; protected local credentials, budget admission and verified assurance UI. | merged (`dae190161`); next CLI/app cut plus coordinated Pearl runtime; production acceptance pending |

**#2160 release acceptance:** all 28 checks in
[CI run 40261607346](https://github.com/Augustas11/macprovider/actions/runs/40261607346)
passed, and `antfleet-ops` approved and merged #2161. Studio acceptance passed
30 targeted tests and a real four-turn streamed Claude Code coding task with
Read/Bash tools, cancellation, simulated network-priority preemption and native
stop-sequence reporting. The client also sent `X-MacProvider-Origin: local-app`
through `ANTHROPIC_CUSTOM_HEADERS`; base URL/model/auth alone do not classify
local work. The lab used `--bare` and explicit tools; full default-client
configuration and the Malibu Terminal launcher are not established by this test.

Issue #2160 is closed following source merge. Before promoting the next signed
provider cut, verify that released bytes support the local tool session and Stop,
and that a real paying Malibu buyer preempts local work without customer errors.
Local requests must remain unbilled and outside heartbeat accounting. No signed
release, live routing, billing or settlement acceptance is claimed by the lab.
The metadata change in `ModelRuntime.swift` changes the conservative decode-path
digest to `105875b44bb72502928fe5c96b82c6598a326c7c99670f9ebc241350e3556776`;
generation and output filtering are unchanged. Preserve existing qualification
and follow the release identity-binding procedure for signed policies.

**#2155 release acceptance:** CI run `40257144313` passed all 28 checks and
`antfleet-ops` approved #2158. Before promoting the next signed CLI/app cut,
verify on the designated Studio that a real bundle update and a second launch
leave exactly one Malibu process and one menu-bar icon, including a hung old
quit drain and pre-handoff legacy duplicates. Verify that an older rollback
launch preserves the newer running app and that app handoff keeps the launchd
provider running. This source merge is not live-update acceptance.

PR #2172 repairs the legacy activation-rename discovery gap in #2158. Isolated
Studio GUI bundles compiled from the production handoff source passed a legacy
hung-quit update (41.02 seconds from successor launch), same-version second
launch and older rollback, each with one surviving process and one logged
status item. The provider PID stayed unchanged. Untrusted same-bundle and
similar-name processes survived a 46-second negative check. These ad-hoc test
bundles use an exact fixture-code allowlist; the unmodified production Team-ID
gate rejects them. Repeat signed-byte acceptance before release promotion.


## Native-MTP campaign release readiness

Related: #2144; campaign PR #2152 remains in progress and is not a merged
release-train row. Refresh both trains and tags before assigning the next
provider identity; the campaign currently stages 1.8.274, while 1.8.273 is a
coordinator runtime identity.

Retain one native row, depth one and four ordinary CB slots. Sampled, tools,
history and reasoning eligibility requires genuine R005 correctness, applicable
R015 qualification, representative replay and signed serving evidence. The
combined production prefix-cache change invalidates the campaign's earlier
identity-only greedy carry-forward assumption; that record is withdrawn.
The existing representative-collector deployment depends on a newly qualified
signed greedy parent, while that qualification requires representative replay.
This bootstrap dependency remains unresolved; no qualification exemption,
stale-evidence rebind or MTP-off deployment is authorized by this train record.
The exploratory goal matrix does not constitute admission qualification.

## Following CLI release — net changes vs 1.8.274 (tracked 2026-10-27)

The 1.8.274 candidate was cut at `f8b6856e5`. It contains #2162 (chat-first
navigation, merged Models destination, embedded Terminal), but **not** the
changes below. Cut merged rows in the next candidate after 1.8.274 is promoted (staged as 1.8.276; v1.8.275 is a Pearl runtime tag);
rows marked `in progress` remain excluded until they merge.

| PR | Issue | Provider-side change | Status |
|---|---|---|---|
| [#2169](https://github.com/Augustas11/macprovider/pull/2169) | #2164 | Malibu.app **Create, Agents and Tasks**. Sidebar: Chat, Terminal, Create, Agents, Tasks, Models, Earn. **Agents** run on this Mac's model (local work, SPEC-001-R011) or a Malibu network model on the buyer key; read-only workspace tools plus user-configured stdio MCP servers with per-call approval. **Tasks** schedule agent runs while the app is open (caps, pre-approved tools only, local 0600 transcripts kept out of diagnostics). **Create**: vendored MIT SDXL-Turbo runtime (`MacProviderImageGen`, no new package dependency) behind a loopback-only, local-app-origin `POST /v1/images/generations`. A local creative hold fences customer admission, unloads the LLM, generates, keeps the image model warm for 120 s, then restores the LLM, CB and native MTP exactly as before. Delayed restores re-register with the coordinator, and an operator pause is preserved. SPEC-025 v0.45.0/v0.46.0 (R017–R021); SPEC-001 v1.9.49 (R011/R014). | merged (`0239dd1de`); next CLI/app cut after 1.8.274; signed live acceptance pending |
| [#2175](https://github.com/Augustas11/macprovider/pull/2175) | [#2171](https://github.com/Augustas11/macprovider/issues/2171) | Recover expired prepared update handoffs after an operator pause/resume supersedes the lifecycle operation; preserve operator pause and existing identity/dead-owner guards. `recover-update` explains helper fencing and enabling disabled LaunchAgents before bootstrap. | merged (`521a40199`); all 28 CI checks green; next CLI/app cut after 1.8.274; signed release acceptance pending |
| [#2152](https://github.com/Augustas11/macprovider/pull/2152) | #2144 | Native MTP: shared iterator, multi-family gate, multi-entry sidecar; exact GLM sampled/tool-history MTP profiles | merged (`202ff416c`); in the 1.8.276 candidate |
| [#2163](https://github.com/Augustas11/macprovider/pull/2163) | #2154 | Ternary-Bonsai 2B native loading for 8 GB Macs with bounded cache and CB rows | merged (`b422e0681`); in the 1.8.276 candidate |
| [#2168](https://github.com/Augustas11/macprovider/pull/2168) | #2153 | Keyed agent-prefix snapshot retention within serving memory headroom | merged (`2aca0f374`); in the 1.8.276 candidate |
| [#2177](https://github.com/Augustas11/macprovider/pull/2177) | #2153 | Prior model geometry no longer denies cache retention after a swap | merged (`82efc1628`); in the 1.8.276 candidate |
| [#2179](https://github.com/Augustas11/macprovider/pull/2179) | #2154 | Cross-family fixes from the regression window: GLM cached-turn prefill stride alignment, Qwen3.5 VLM warm-cache anchor, FP32 caches keep ordinary CB with keyed conversations served serially | merged (`e7ccd0826`); in the 1.8.276 candidate |
| [#2176](https://github.com/Augustas11/macprovider/pull/2176) | #2154 | Official Qwen3.8-27B template identity, reasoning-effort mapping and tool history (catalog activation separate) | merged (`1f61e8943`); in the 1.8.276 candidate |
| [#2173](https://github.com/Augustas11/macprovider/pull/2173) | #2154 | Native LFM2.5 loader and tool conversations (catalog activation held on the quality gate) | merged (`4d68e41fb`); in the 1.8.276 candidate |

**#2171 recovery tracking:** issue closed at operator request; PR #2175
merged as `521a40199` on 2026-10-27 after `antfleet-ops` approved the exact
head `787bc9508` and all 28 checks in
[CI run 40452783122](https://github.com/Augustas11/macprovider/actions/runs/40452783122)
passed, including all four Swift test shards, Malibu app recovery tests,
`spec-index` and `ci-required`. Regression coverage includes coordinator and
self-update handoffs, operator lifecycle supersession, pause preservation,
restored startup and refusal guards. Three review lanes passed. SPEC-020 and
its manifest both record v0.1.30. The fix is merged; signed release and live
acceptance remain pending in this train.
Before promotion, verify with the signed candidate on the designated Studio
that an expired activating marker plus a dead-owner prepared handoff and a
superseding operator pause recovers without editing lifecycle files, retains
the pause, and permits restored startup and buyer serving after explicit
operator resume. Confirm the documented LaunchAgent enable/bootstrap steps.
No decode-path code changes; reuse existing inference qualification.

**Release impact (#2169):** `ModelRuntime.swift` gained the creative hold and
restore, so the embedded decode-path digest changes. Token generation and
output filtering are unchanged. After the cut, rebind the native-MTP admission
set to the new decode path identity-only (AGENTS.md rule 2; no R015 rerun),
through `scripts/ops/catalog-activate.sh`, as #2170 did for 1.8.274. #2169
changes no coordinator or gateway code and needs no Pearl runtime payload.

**#2164 evidence before the cut:**
- **Goal metric**, measured first on the 16 GB M3 lab Mac (SDXL-Turbo, 4 steps):

  | Size and precision | Time per image | Peak memory |
  |---|---|---|
  | 512 px, fp16 | 12.3 s | 10.2 GB |
  | 512 px, quantized | 17.0 s | 7.4 GB |
  | 1024 px, fp16 | 29.0 s | 13.3 GB |

- **Real-weights lab end-to-end** on the same Mac (isolated loopback, `--no-join`, Qwen3-8B loaded):
  - a request without local-app origin got **403**
  - the first image returned **200 in 177 s**, including the first-use download of 6.94 GB of fp16 weights
  - the warm second image returned **200 in 5 s**
  - after the 120 s window and the restore, status matched the pre-hold state and a local chat request answered
  - CB and native MTP were inactive in that lab config, so restoring them is proven by the ModelRuntime, ContinuousBatch and NativeMTP suites
- **Studio suites:** 953 app tests; CLI LocalImage 26, ModelRuntime 116, NativeMTP 432, ContinuousBatch 371 and CoordinatorClientTests 260, all with 0 failures.
- **Audit:** three lanes, three rounds. The final code-lane HIGH was fixed with regression tests.

Before promoting the signed cut, verify with released bytes on a provider that is
serving paying buyers:
- One Create image on a 16 GB Mac pauses and then resumes customer serving. The
  provider re-registers, and CB and native MTP state are unchanged afterwards.
- One Agents run uses an MCP tool and gets the approval prompt.
- One scheduled Task fires once.

## Coding-agent privacy release acceptance — issue 2157

[#2165](https://github.com/Augustas11/macprovider/pull/2165) merged as
`dae190161f6b50680640cec77b81f82ad8b1e41b`; `antfleet-ops` approved and
merged the reviewed head `f6b292d30` after all 28 checks in
[CI run 40282107873](https://github.com/Augustas11/macprovider/actions/runs/40282107873)
passed. One unchanged rerun passed a pre-existing coordinator keepalive race;
21 focused Swift XCTest cases also passed on the authorized alternate Mac.

On operator instruction, issue [#2157](https://github.com/Augustas11/macprovider/issues/2157)
is closed with remaining release work tracked here and in the
[coordinator train](coordinator-release-train.md#coding-agent-privacy--pending-runtime-inclusion-2026-10-26).
Source merge and issue closure do not establish live privacy for coding agents.
Both the signed CLI/Malibu.app cut and matching coordinator/gateway runtime must
include `dae190161`; neither release alone delivers the feature.

Release through `scripts/ops/cli-release.sh status`, then `next` and
`next --run`, with the matching Pearl rollout tracked in the coordinator train.
Before promotion, complete and record these acceptance gates against released,
signed bytes:

- Launch Codex and Claude Code from Malibu.app Terminal and Connected apps;
  complete real multi-turn tool-using tasks through the production gateway.
  Verify original Responses/Messages bodies enter the encrypted path, with
  translation only inside the reserved provider runtime.
- Verify authenticated served privacy/assurance labels and relay logs containing
  envelopes without request/response content. The provider still reads plaintext
  to infer. Require `code_bound_attested` on a supported macOS 27 provider and
  verify that an unmet requirement fails closed.
- Exercise budget admission, invalid/revoked identity or family mismatch,
  interrupted/truncated streams and postdispatch uncertainty: no plaintext
  fallback, silent downgrade, failover or automatic resubmission. Verify agents
  receive only protected local tokens and managed legacy profiles migrate safely.
- Preserve ordinary Chat-only key/pin compatibility and existing accounting and
  settlement gates. Record signed runtime identities and acceptance evidence in
  both trains before marking the feature shipped.

Signed rollout and these real-agent production gates remain pending. Reuse
existing qualification evidence; a new cut requires identity binding, not an
unrelated inference benchmark.

## Shipped v1.8.272 — net changes vs 1.8.270

Published as v1.8.272 on 2026-10-25 at source `28c06242701de711454f65b4bfb34375d31803c7`
(candidate run 40146768804, promotion run 40152407985, rollout verification run 40153236925;
e2e gate CF-272-E2E). Studio canary on DeepSeek V4-Flash (serial, CB off by design). The first
signer run 40142899739 (cut at `1dde22532`) refused on main drift when #2140 (coordinator-only)
merged during the wait; the candidate was re-cut on `28c062427`. The native-MTP admission set is
rebound identity-only to the 1.8.272 decode path `4d04a3f3…` by #2141 (catalog-only). The release
metallib `3d9b4a74…` is unchanged, so every signed CB policy entry still matches.

| PR | Issue | Provider-side change | Status |
|---|---|---|---|
| #2137 | #614 | Provider WebSocket receive limit 64 MiB, so a large sealed prompt no longer closes the session with 1009 and a buyer 503 (SPEC-001-R012); coordinator half live in runtime v1.8.271. | shipped v1.8.272 (`c1992df77`) |
| #2138 | #2111 | A buyer cancel stops prompt prefill within one chunk (SPEC-001-R013); decode-path digest `4d04a3f3…`; identity-only native-MTP admission rebind after the cut (#2141). | shipped v1.8.272 (`a17fc834b`) |
| #2139 | #2111 | Version staging 1.8.272 (live-stable rows 1.8.270). | shipped v1.8.272 (`1dde22532`) |

## Shipped v1.8.270 — net changes vs 1.8.262

Published as v1.8.270 on 2026-10-24 at source `48cf25db2f6cc64a3779eb0ed36ff669874bf519`
(candidate run 40104446783, promotion run 40111708233, rollout verification run 40113229828;
e2e gate CF-270-E2E). Studio canary on DeepSeek V4-Flash (serial, CB off by design). The
native-MTP admission set is rebound identity-only to the 1.8.270 decode path `6471812e…` by
#2136 (catalog-only; it also fixes `scripts/ops` `workflow_runs`, which hid an in-flight
acceptance run from `cli-release.sh status`). The release metallib `3d9b4a74…` is unchanged,
so every signed CB policy entry still matches. `afd62110e` (test-only clock pin) also rides.

| PR | Issue | Provider-side change | Status |
|---|---|---|---|
| #2129 | #2127 | Autotune readiness: large candidates finish loading before autotune probes; model-aware readiness and signed candidate aliases. | shipped v1.8.270 (`25ce4bd6e`) |
| #2130 | #2107 | GLM-5.3, gpt-oss and Qwen3.8 render `none`/`minimal` reasoning effort as `low` instead of silently requesting maximum reasoning (SPEC-018 0.3.5). | shipped v1.8.270 (`34d66d6b0`) |
| #2131 | #2107 | Grammar-constrained decoding: guaranteed tool_choice required/named and strict json_schema for every catalog grammar (SPEC-018 0.3.6); decode-path digest `adc3f5dc…` (includes #2130); identity-only native-MTP admission rebind after the cut. | shipped v1.8.270 (`ec04c6de8`) |
| #2133 | #2107 | Reasoning round trip on all buyer surfaces (Messages `thinking`, Responses, Chat Completions), keepalives and prompt-sized first token. | shipped v1.8.270 (`0be1ed916`) |
| #2134 | #2111 | DeepSeek V4 CB backend (off without a live-verified signed policy entry for the exact tuple; fork `c8be0f61`, mlx-swift-lm `3.32.3-macprovider.10.5`) and extend-only prompt snapshots for DeepSeek V4 and GLM-5.3 serial turns (SPEC-024 0.2.12 FR-CI2a); GLM CB rows unchanged; decode-path digest `6471812e…`; identity-only native-MTP and CB admission rebinds after the cut. | shipped v1.8.270 (`a65f20090`) |
| #2135 | #2111 | Version staging 1.8.270 (live-stable rows 1.8.262) and `cli-release.sh` canary probe accepting a serial canary whose model has no signed CB policy entry (DeepSeek V4). | shipped v1.8.270 (`48cf25db2`); release source |

## Shipped v1.8.262 — net changes vs 1.8.261

Published as v1.8.262 on 2026-10-23 at source `92e39cf5f5979a7757011d837e62014abd35418e`
(candidate run 39927039135; e2e gate CF-262-E2E). The native-MTP admission set was rebound to
its decode path by #2120.

| PR | Issue | Provider-side change | Status |
|---|---|---|---|
| #2109 | #2107 | Buyer API compatibility for agentic clients across every catalog model. | shipped v1.8.262 (`ab9730172`) |
| #2115 | #2100 | `glm5_next` prefills in 2048-token CB prompt chunks. | shipped v1.8.262 (`20ead6ea6`) |
| #2116 | #2107 | Buyer API conformance fixes for the real-model failures from the #2109 validation run. | shipped v1.8.262 (`8a44d3f44`) |
| #2117 | #2107 | Qwen per-call `<tools>` wrappers, `json_object` failure diagnostics, lifecycle failed wedge. | shipped v1.8.262 (`c47bb4813`) |
| #2108 | #2084 | Multi-Mac shard groups on Trusted Pools (SPEC-051): stage transport, provider and coordinator. | shipped v1.8.262 (`9f8491b34`) |
| #2118 | #2107 | Buyer API re-audit: serial bare calls, conformance binding, grammar-unavailable settlement, schema profile. | shipped v1.8.262 (`68d6ed54d`) |
| #2112 | #2111 | DeepSeek V4 native `deepseek_v4` serving (fork `baec1724`, mlx-swift-lm `3.32.3-macprovider.10.3`), DSV4 prompt encoder, DSML tool calls and reasoning; decode-path digest `565617…`; native-MTP admission inputs rebound identity-only. | shipped v1.8.262 |

## Shipped v1.8.261 — net changes vs 1.8.260

Published as v1.8.261 on 2026-10-22 at source `90b1a3b72e5d71bb644111173e69eaaa03286212`
(candidate run 39724400285, promotion run 39733171059, rollout verification run 39734759592;
e2e gate CF-261-E2E). Every row below is an ancestor of that source and shipped in it.

The operator ordered this combined cut for #2095, #2096 and #2106. The
GLM-5.3-Flash and Qwen3.6 native-MTP admission set is rebound to its decode-path
digest (`4be59bfa…`) in #2110, which also adds the Qwen3.6 tuple; activation
and paid proofs go through `scripts/ops/catalog-activate.sh`.

| PR | Issue | Provider-side change | Status |
|---|---|---|---|
| #2098 | — | Download cancellation remains final when a sampled heartbeat arrives late. | shipped v1.8.261 (`41bba3a81`) |
| #2095 | #2054 | Qwen automatic tool use, schema-typed arguments, sampling controls and OpenCode/Connected apps integration. | shipped v1.8.261 (`15ef4e19b`) |
| #2096 | #2081 | Exact Qwen native/ordinary ragged prompt grouping and snapshot-pinned text preparation, including streaming preflight and queued-drain cancellation. | shipped v1.8.261 (`359e3d4ad`) |
| #2099 | #2082 | Dense-model CB qualification measures production's uncompiled decode default; truncated token prefixes are rejected instead of reported as parity PASS; per-row parity counts and prefix hashes; signed Qwen3-8B four-slot CB policy entry (catalog, already live). | shipped v1.8.261 (`41ea0fef0`) |
| #2106 | #2081 | Native-MTP admission binds to a compiled-in `decode_path_digest` (plus runtime revision, metallib, hardware) instead of the CLI binary; the serve decode path moves behaviour-preserving into `ServeDecodePath.swift`; the digest is reported on `/v1/status` (SPEC-048 0.1.51). | shipped v1.8.261 (`c1b49eddd`) |
| #2088 | #2029 | Catalog-only: GLM-5.3-Flash native-MTP admission identity rebind to 1.8.260 (already live; no binary change). | merged (`d9a6cf20f`); catalog-only |

### Qwen3.6 native-MTP handoff (#2081)

Runtime `c2519f2ad` on mlx-swift-lm `87dc5159` passed twelve focused Studio
tests without skips. The immutable six-cell matrix passes every gate except
the accepted s2 TTFT result. Sustained: 1,812.3987 seconds, 88 records, zero
errors/fallbacks/parity mismatches and nominal thermals. All seven local
self-test checks pass; the challenge-bank entry is unchanged.

All 194 executed local journey checks pass across seven step groups; overall
journey coverage remains partial for the external gates below. Required hosted
CI is green, three final audit lanes have zero CRITICAL/HIGH/MEDIUM, and
`antfleet-ops` approved and merged #2096 on 2026-10-21.

The frozen +5% two-request TTFT policy remains unchanged and its analyzer
result remains FAIL. Per the operator's 2026-10-21 direction,
[SPEC-048 v0.1.50](../../specs/SPEC-048-native-mtp-serving.md) accepts only this
campaign's recorded +5.9973% median / +6.3686% corrected-upper TTFT tradeoff.
This is an explicit acceptance disposition, not a preregistered PASS.
The earlier captures failed the same TTFT gate at +6.5088% / +6.8790% and
+6.3484% / +6.6132%; grouping alone did not remove that cost. All findings and
current-source evidence are retained in [the campaign measurement note](../research/spec048-r015/qwen36-35b-r015-2026-10-21.md).

When the combined CLI is ready:

1. Cut and verify the reviewed signed CLI with `scripts/ops/cli-release.sh`
   (`status`, `next`, then one documented `next --run` step at a time).
2. Reuse this campaign evidence and its explicit disposition if the measured
   decode/preparation/scheduler path is unchanged. A release identity change
   alone does not require qualification again.
3. Prepare one reviewed two-model v2 admission manifest preserving GLM and
   adding Qwen's measured tuple, artifact projection and unchanged bank entry.
   Bind the actual release source, executable SHA-256 and CDHash, and cite the
   SPEC-048 disposition alongside the original analyzer FAIL. This is also
   the one final dual-field rebind (SPEC-048 0.1.51): add each tuple's
   `decode_path_digest` and `metallib_sha256`, and set the release input's
   `provider_decode_path_digest` to the released CLI's embedded digest
   ([runbook](../runbooks/native-mtp-enablement.md#the-one-final-dual-field-rebind)).
   Publish it only once this CLI is the released one (R014 item 10). Later
   cuts need no admission step while `cli-release.sh status` reports
   `native_mtp_admission_decode_path=match`.
4. Activate through `scripts/ops/catalog-activate.sh` (`status`, `next`,
   `next --run`) with `PROBE_MODEL=qwen/qwen3.6-35b-a3b` and
   `CATALOG_REQUIRE_NATIVE_MTP_FORWARD=true`.
5. Prove an attributed paid Qwen gateway request increases `mtp_forwards`,
   verify receipts and incumbent restoration. These live gates remain pending.

## Historical published-release verification — 2026-10-10

Verified 2026-10-10 against public release metadata, the release train
(`scripts/ops/cli-release.sh status`) and live health:

| Field | Value |
|---|---|
| GitHub provider release | [v1.8.232](https://github.com/Augustas11/macprovider/releases/tag/v1.8.232) (published 2026-10-09 23:22Z) |
| Signed compatibility-set id | `Augustas11/macprovider:v1.8.232@36758c05c18dcedea1a321aa6b3120c6678640c0` |
| Pearl runtime / recommended provider | `v1.8.236` / `1.8.232` |
| Admission | Repository policy (#1919): every well-formed release from this repository connects and gets the recommendation; 42 exact revocations (the v1.8.34–v1.8.123 seed) make those builds update-only. No accepted-id list. |
| Canary | Studio canary on 1.8.232 passed with CB live-verified; e2e gate recorded as CF-232-E2E (below). |
| Installer | `get.malibu.tech/install.sh` matches the v1.8.232 `dist/install.sh` (train step `install_sh_vs_release: parity`). |
| Release mirror | `download.malibu.tech/releases/v1.8.232/` byte-identical to GitHub (33 assets verified); `latest.json` promoted from `v1.8.224` to `v1.8.232` on 2026-10-10 with `publish-release-mirror.sh --promote-latest`. |

## Shipped v1.8.260 — net changes vs 1.8.258

Published as v1.8.260 on 2026-10-20 at source
`13c6b1854cb65968cfff4473d1f0f23b99bb1c88`. All four changes below are ancestors
of that release source and shipped in it.

| PR | Issue | Provider-side change | Status |
|---|---|---|---|
| #2074 | #2059 | Malibu: catalog-only rows, Discover catalog, model Download (with cancel), readable model names, Connected apps (SPEC-044 R014). 812 app tests, 390 CLI tests, a real catalog-economics decode, a real download and a cancel | shipped v1.8.260 (`f3aafd069`) |
| #2077 | #2075 | Provider startup recovers an expired prepared self-update handoff before the startup fence, retires only matching abandoned lease authority and shows actionable recovery diagnostics, so a self-update can no longer leave a provider crash-looping. Targeted watchdog regressions, three audit lanes, CI | shipped v1.8.260 (`370f24f68`) |
| #2079 | #2078 | A `continuous_batch_queue_limit` above the bound for the planned rows (8 x rows) is clamped and logged (`event=cb_queue_limit_clamped`) instead of failing startup, so a signed `max_served_slots` ceiling or a removed owner pin no longer crash-loops the provider; the configured value is kept. Studio CPU tests (216, 0 failures), three-lane audit 0/0/0, CI | shipped v1.8.260 (`3f2a24946`) |
| #2085 | #2054 | Malibu Provider shows the observed KV disk tier and the last recorded restart (time, reason, version); Settings saves menu-bar and Dock preferences and keeps a visible entry point; Connected apps guidance corrected; KV support refreshes after a warm swap. Malibu 822 tests, targeted CLI 110 tests, three-lane audit 0/0/0, CI | shipped v1.8.260 (`82d491211`) |

## Next CLI release — net changes vs 1.8.257 (tracked 2026-10-19; released as v1.8.258)

Live fleet target was **1.8.257**. Released as **v1.8.258** on 2026-10-19 (candidate
`398002c10`, run 39295344398, carry-forward CF-258-E2E): Studio canary on GLM-5.3-Flash
passed, recommendation bumped, live rollout verified, mirror `latest.json` and
`install.sh` at v1.8.258. The GLM-5.3-Flash native-MTP admission is rebound to this
release by identity (#2071, catalog `published-2026-10-19-glm53-flash-native-mtp-v258`, activated
2026-10-19 20:05Z); a paid plain-text gateway request on GLM-5.3-Flash then ran native MTP on
the Studio (`mtp_forwards` 0 to 141, 114 of 141 proposals accepted). Every PR below shipped.

| PR | Issue | Provider-side change | Status |
|---|---|---|---|
| #2070 | #2029 | Gateway auto-prefix requests stay native-MTP eligible under a fleet-cache grant: `withFleetCacheGrant` keeps the cache-only conversation-key marker when the grant names the installed key (SPEC-048-R004/R009), so paid gateway plain-text requests no longer fall to ordinary decode with `conversation_key`; the native-MTP store reads v1 and v2 projection manifests and selects the served `model_key`; a cache-only native row that falls back to serial keeps its ordinary cache lease. Release-build Studio e2e on GLM-5.3-Flash (`docs/evidence/glm53-flash-mtp-gateway-eligibility-2026-10-19/`) | shipped v1.8.258 |

## Next CLI release — net changes vs 1.8.256 (tracked 2026-10-19; released as v1.8.257)

Live fleet target was **1.8.256**. Released as **v1.8.257** on 2026-10-19 (candidate
`10379e158`, run 39228227700, carry-forward CF-257-E2E): Studio canary on GLM-5.3-Flash
passed, recommendation bumped, live rollout verified, mirror `latest.json` and
`install.sh` at v1.8.257. Every PR below shipped.

| PR | Issue | Provider-side change | Status |
|---|---|---|---|
| #2059 | — | Malibu app redesign Phase 2: sidebar shell, Models, Discover, fast catalog, brand mark | merged |
| #2064 | #2029 | Signed CB policy `max_served_slots` ceiling (SPEC-023 v0.22.28 §12.6, SPEC-038 v0.3.22, SPEC-039 v0.1.21): the CLI parses the optional field and caps planned rows, the self-check ladder, stored/prior/provisional grants and the warm-swap interim count by the lowest ceiling of the matching verified entries; absent field = unchanged behaviour | merged |
| #2062 | #2061 | Bounded admission holds let due CB self-checks progress under sustained traffic while preserving existing requests and the prior grant; completed probes and paired throughput measurements survive interruptions, cancelled results cannot qualify, and canary confirmation binds the final grant to the exact smoke identity. Malibu waits for updater output capture before classifying rollback failures | shipped v1.8.257 |
| #2063 | #2029 | Native-MTP prompt rows join serial prefill cohorts where grouped rows always prefill alone (glm5_next; SPEC-038 v0.3.24 FR-CB2, SPEC-048 0.1.49 R009); paged-attention scheduling unchanged. R015 v2 PASS on a lab-harness build of `cf0571a5f` (`docs/research/spec048-r015/glm53-flash-r015-v2/`); the GLM native-MTP admission binds the next CLI release (staged inputs README, "After the 1.8.256 R015 FAIL") | shipped v1.8.257 |
| #2065 | #2054 | Local Chat and Connected apps in Malibu: loopback requests carrying `X-MacProvider-Origin: local-app` are local work (the coordinator stamps `coordinator` on every HTTP-direct dispatch); local work yields to the CB self-check hold and to buyer rows, never takes the native-MTP row; buyer-safe ownership routing keeps an account's requests off providers its linked identity owns (coordinator/gateway half ships in the next Pearl runtime) | shipped v1.8.257 |
| #2066 | #2029 | CB no-progress guard counts streamed decode-window tokens: on 1.8.253–1.8.256 every CB request past ~1025 output tokens failed with `continuous_batching_scheduler_no_progress` after 64 16-step windows. Release-build Studio e2e on GLM-5.3-Flash: 4 concurrent 1.1k–3.3k-token prompts to 4096 tokens, plus 2048 non-stream and stream, all complete (`docs/evidence/cb-streamed-window-progress-2026-10-19/`) | shipped v1.8.257 |

#2062 validation: all 28 jobs passed in [hosted CI run 39189689441](https://github.com/Augustas11/macprovider/actions/runs/39189689441)
on reviewed head `764b34de0`; code, security and architecture audits have no unresolved
Critical, High or Medium findings. This records merged source, not a signed CLI release
or live rollout. #2062 requires no coordinator/gateway runtime change; deliver it through
`scripts/ops/cli-release.sh` (`status`, `next`, then one documented `next --run` step at a time).

Deploy order for #2064 (done): a policy that carries `max_served_slots` is refused by every
release path until `scripts/cb_release_baselines.py` `CB_POLICY_CONSUMER_FLOOR` is raised
from `(0, 22, 27)` to `(0, 22, 28)`, because older CLIs reject a whole policy that carries the
field. This CLI cut and Pearl runtime v1.8.259 (#2064's coordinator half, 2026-10-19) are
both live, so the floor is raised and the GLM-5.3-Flash ceiling (4 served slots, from rows
1/2/4 evidence) is signed in catalog `published-2026-10-20-glm53-flash-cb-ceiling-v1`,
activated 2026-10-20 through `scripts/ops/catalog-activate.sh`. The Studio keeps its owner pin
for now: without it, the startup preflight refuses its `continuous_batch_queue_limit` 16 against
the 4 planned rows (see the coordinator train, "GLM-5.3-Flash signed CB ceiling live").

## Next CLI release — net changes vs 1.8.251 (tracked 2026-10-18; released as v1.8.256)

Live fleet target: **1.8.251**. Staged: `binaryVersion` **1.8.256** (v1.8.252, v1.8.253 and
v1.8.255 are runtime releases). The 1.8.254 candidate failed its Studio canary
(`Unable to load kernel gather_mm_offsets`: the release metallib was SwiftPM's partial
library) and was never tagged; #2052 fixes the release metallib. Every PR below is merged
and none is open, so the cut is authorized.

| PR | Issue | Provider-side change | Status |
|---|---|---|---|
| #2046 | #2014 | Guaranteed tool selection starts inside the call: named choice renders only the selected function and prefills its call opening; `required` prefills the envelope (SPEC-018 v0.2.15); lab real-model acceptance 6/6 on the Studio, stream and non-stream, CB on and off | merged |
| #2048 | #2015 | Watchdog never kicks an operator-paused or resuming provider: final pause/lease re-check and kick under the lifecycle store locks; listener probe tri-state (SPEC-020 v0.1.28) | merged |
| #2047 | #2029 | GLM-5.3-Flash on the native engine: paged MLA continuous batching, native MTP-1; mlx-swift-lm `3.32.3-macprovider.10.1` (core v0.32.4 line, carries the Qwen2-VL per-image fix); listed catalog cut `published-2026-10-17-glm53-flash-listed-v1` | merged |
| #2049 | #2036 | Malibu.app is stamped from the release tag (was a stale 1.8.224) and relaunches itself onto the installed bundle after a CLI self-update (SPEC-025 v0.31) | merged |
| #2050 | #2029 | Native MTP: the canary bank moves with the release in one publication; providers re-offer the tuple after `bank_mismatch` (coordinator half ships in runtime v1.8.255) | merged |
| #2051 | — | Malibu app lean, truthful dashboard (UX audit Phase 1): one status pill and earnings card, honest MALIBU/payout/trust copy, real metrics, menu-bar icon, Dock presence (coordinator half ships in runtime v1.8.255) | merged |
| #2052 | #2029 | Release metallib compiles every kernel the pinned MLX core loads (388 required, gated in package/acceptance/release/tier-2 verify); guarded `scripts/ops/canary-swap.sh` with kernel preflight and crash-loop auto-rollback | merged |

Order: Pearl runtime v1.8.253 (coordinator billing aliases from #2047) and the listed
catalog activation before the canary. The mlx-swift-lm pin moves to the v0.32.4 core line,
so the CB self-check re-measures on each Mac and native-MTP admission re-binds to this
identity. Live proof owed after the cut: #2014 (named and `required` through the gateway on
Qwen3.6), before the Studio switches to GLM-5.3-Flash.

Release notes for this cut MUST tell operators to reopen Malibu once
(SPEC-025 v0.31 first hop): a running pre-v0.31 Malibu has no relaunch
watcher, so it keeps its old in-memory code until it is reopened or the
user logs in again.

## Next CLI release — net changes vs 1.8.250 (tracked 2026-10-17)

Live fleet target: **1.8.250**. Staged: `binaryVersion` **1.8.251**. Every PR below is
merged and none is open, so the cut is authorized.

| PR | Issue | Provider-side change | Status |
|---|---|---|---|
| #2034 | #2029 | Artifact hashing, verification, import and GGUF digest loops release each 1 MiB chunk (per-iteration autorelease pool); serve-load peak drops from ~2.1x to ~1.01x of tensor bytes | merged |
| #2037 | #2036 | Release discovery resolves the coordinator-advertised release first (signature-verified via `checksums.txt.sig`); anonymous GitHub API is a single fallback with "deferred until reset" on a spent budget; Malibu.app stops re-polling GitHub every status tick | merged |
| #2038 | #2014 | Guaranteed tool selection (`required`/named) accepts the Qwen3.6 template's function-XML envelope, schema-typed; instruction merges into the leading system message (SPEC-018 v0.2.14) | merged |
| #2039 | #2036 | Release-train health gate never executes the served installer; streaming size cap on every release download; HTTPS-only same-host redirects | merged |
| #2035 | #2016 | Native image input for Qwen2-VL-2B: vision profile selected by catalog identity, vision models skip paged KV, catalog promotion (class-priced), SPEC-023 30-day listing rule removed | merged |
| #2041 | #2016 | mlx-swift-lm pin `3.32.3-macprovider.9.4` (`ce3bb523`): Qwen2-VL per-image vision attention; other models byte-identical (Qwen3.6 greedy output identical to 1.8.250) | merged |
| #2040 | #2015 | KV disk tier coexists with the privacy class (private requests bypass the tier, SPEC-049 v0.6.0); tier default on (SPEC-037 v0.2.2) | merged |
| #2043 | #2015 | Privacy-class CB replay claims stay in memory; no private-request-derived state on disk (SPEC-049 v0.7.0) | merged |

Re-binds at this cut: the mlx-swift-lm pin changes the runtime-build key, so the CB
self-check re-measures once on each Mac; CB policy and native-MTP admission get an
identity-only signed republish through `scripts/ops/catalog-activate.sh`; the Qwen2-VL
vision qualification is recorded on the released build and installed with
`PEARL_RUNTIME_TASK=vision-qualification`. Coordinator-side changes (#2035 SIGHUP
qualification apply, #2042 persisted compute-integrity schedule) ship in the next Pearl
runtime release.

Live proofs owed after the cut: #2014 (`required` and named tool calls through the
gateway, with and without a buyer system message), #2015 (disk tier activated, cold
restore, privacy hardening passing), #2016 (two-image buyer request with receipt), #2036
(update check and install with the anonymous budget at 0).

## Next CLI release — net changes vs 1.8.248 (tracked 2026-10-16)

Live fleet target: **1.8.248**. Staged: `binaryVersion` **1.8.250** (v1.8.249 is the
runtime release). Every PR below is merged and none is open, so the cut is authorized.

| PR | Issue | Provider-side change | Status |
|---|---|---|---|
| #2030 | #2014 | Tool selection evaluated on the catalog identity of an alias-configured model (named/required modes for Qwen3.6) | merged |
| #2032 | #2015 | Hybrid KV entries persist: complete recurrent state, size estimate, staging defaults that fit; Studio acceptance 14/14, cold-restore TTFT 750 vs 3523 ms | merged |
| #2033 | #2028 | MLX core fork v0.32.2-macprovider.5 keeps internal ops on the caller's stream (mlx-swift 0.32.3-macprovider.8, mlx-swift-lm 3.32.3-macprovider.9); gpt-oss-20b decode 125.37 vs 125.77 tok/s on 1.8.232 (Studio T1-02) | merged |

No catalog, CB-policy, native-MTP or Pearl change. The CB self-check re-runs on the new
runtime-build key, as at every runtime version change.

## Next CLI release — net changes vs 1.8.242 (tracked 2026-10-16)

Live fleet target: **1.8.242** (published 2026-10-15; Pearl recommends it).
Staged on main: `binaryVersion` **1.8.248** (`b4e1f2f52`); v1.8.243–v1.8.247 are
consumed by runtime releases. **Operator hold (2026-10-16): no candidate cut
until every open PR below is merged** (all merged 2026-10-16; cut authorized); then one cut carries all of them, with
the canary on a macOS 27 Mac (also the live `code_bound_attested` proof for
#1911/#2017) and the Studio CB grant check.

| PR | Issue | Provider-side change | Status |
|---|---|---|---|
| #2020 | #2014 | Required/named tool selection enforced on the provider | merged |
| #2022 | #2016 | Native image input preserved through qualified Chat Completions | merged |
| #2024 | #1911, #2017 | Code-bound posture key: CLI evidence + Malibu.app attestor (macOS 27+) | merged |
| #2025 | #2015 | Authenticated fleet KV persistence with recurrent checkpoints | merged |
| #1986 | #1644 | Cross-provider scoring (SPEC-036 v0.2); real-chip thresholds validated on M5, M1, M3 Ultra | merged |
| #1980 | #1971 | Stricter CB self-check exactness probe; Studio validated (verified_k 16 bounded, divergence caught at 12 unbounded) | merged |
| #2026 | #2018 | Provider-local stateless Responses API and tokenizer parity | merged |

## Next CLI release — net changes vs 1.8.240

**Authorized (operator, 2026-10-11), with a start condition:** cut the next
CLI release once (1) the CB-throughput session's current work (decode
isolation and its R015/probes) is merged, and (2) every other CLI-touching PR
in flight below is merged. Until both hold, no cut. Then freeze main and run
one isolated end-to-end check of exactly that main SHA on the Studio (own
loopback coordinator, gateway and CLI; 1.8.240 vs final main; output-heavy at
8 and 16 concurrent through the gateway; self-check grant recorded; two
announced pause windows of at most 25 minutes). Cut only after it passes; any
merge in between changes the SHA and re-runs it.

**Version and timing (2026-10-13, operator):** one cut, **1.8.242** (staging PR #1978; runtime v1.8.241 took the 241 tag), carrying **every CLI-side implementation** merged by freeze time. The only hold is Studio reachability (not on the tailnet; operator off the home LAN until 2026-10-18): the CB session's pre-cut isolated e2e and the Studio canary both need it. If the Studio is put on the tailnet earlier, the cut moves up.

Order on the cut day: (1) Studio validation + one verification audit for #1986 (provider scoring job), then merge; (2) freeze main and merge #1978; (3) CB-session isolated e2e of that exact SHA; (4) `scripts/ops/cli-release.sh` step by step with the Studio canary.

| PR | Change | Status |
|---|---|---|
| #1953 | Hybrid 16-step decode window; stop-boundary rule; self-check keyed by decode window (SPEC-038 v0.3.16). Expected +17% hybrid CB throughput at 8 concurrent output-heavy | merged (`2bddd66d0`) |
| #1960 (issue #1958) | CB self-check ladder bounded by the scheduler queue limit, ending at backpressure instead of a 320 s backoff, so grants above 16 slots become possible (+38% at 16 concurrent with #1953) | merged (`072f86a99`) |
| #1974 | Decode/verify isolation by kernel route class; per-forward decode row bound (SPEC-038 v0.3.18) | merged (`7663f463d`) |
| #1962 | Native-MTP tuple offer / canary visibility; provider logs the offer always | merged |
| #1948 | Non-streamed stop-string requests stop counting tokens generated past the stop | merged (#1966) |
| #1949 | gpt-oss stop strings no longer match hidden reasoning text | merged (#1964) |
| #1961 | Watchdog grace window after an operator-pause resume | merged (#1965) |
| #1968 | Malibu.app App Attest signing + CLI challenge/submit subcommands (coordinator side live in v1.8.241) | merged (`f387e3841`) |
| #1983 | Privacy in-band identity key rotation, provider side (`privacy-class rotate-identity`, SPEC-049-R031) | merged (`723ea9c5f`) |
| #1987 | Per-Mac engine profile in the heartbeat (SPEC-001-R006) for capability-aware routing (#1355) | merged (`79abef361`) |
| #1986 | Compute-integrity teacher-forced scoring job (SPEC-036 FR-21, #1644) | draft: Studio validation + one verification audit, then merge before freeze |
| #2020 (issue #2014) | Enforced native tool selection, schema/cardinality validation, streaming holdback and loaded-model capability advertisement; details below | merged (`33b6a3238`); not in candidate 1.8.242; hardware and signed-candidate live acceptance deferred |

### Tool selection — merged, awaiting a later candidate (2026-10-15)

[PR #2020](https://github.com/Augustas11/macprovider/pull/2020), merge
`33b6a3238c31b934ba2cef10e62814091092efbd`, changes the provider CLI as well as
the coordinator and gateway. Candidate **1.8.242**, acceptance run
[38702366766](https://github.com/Augustas11/macprovider/actions/runs/38702366766)
at `27ae5dc84`, predates this change. Its signed bytes and CF-242-E2E record
cannot establish tool-selection acceptance. Include this payload in a later
reviewed candidate; this entry reserves no version and does not change the
existing candidate's promotion scope.

Provider changes carried by that later candidate:

- Exact `mlx-community/Qwen3.6-35B-A3B-4bit` on native `mlx_cache` implements
  `required` and named selection through full generation, strict tool-envelope
  parsing, declared-function and argument-schema validation, and call-count
  checks. Omitted/false parallel policy permits exactly one call; true permits
  1–128. Malformed, wrong-name, zero-call, truncated or token-exhausted output
  fails; calls are not fabricated, repaired or retried as `auto`.
- Native `none` withholds output until no tool calls are present. Other native
  model identities reject required/named; loopback adapters reject explicit
  none/required/named. Existing supported `auto` behavior is preserved.
- Guaranteed streams withhold all output until validation. Invalid generation
  returns `tool_selection_validation_failed`, never ordinary successful prose.
  Cancellation and disconnect paths retain their existing accounting behavior.
- Auth/hello/heartbeat publish `schema-holdback-v1` capabilities bound to the
  currently loaded model/runtime; unloaded runtimes advertise no explicit
  capability. Relay-blind requests remain outside this contract, with explicit
  non-auto modes defensively rejected after decryption.

The [tool-selection contract](../tool-selection.md) records the exact schema,
argument and completion-budget bounds and endpoint matrix. SPEC-001-R007,
SPEC-006-R021 and SPEC-018-R006 define the reconciled wire/error/selection
contract. The [coordinator release entry](coordinator-release-train.md#tool-selection--merged-awaiting-runtime-rollout-2026-10-15)
records the matching routing and gateway payload; a provider-only upgrade does
not establish end-to-end support.

Required [implementation CI](https://github.com/Augustas11/macprovider/actions/runs/38712318356)
and all three audit lanes passed. Hardware and signed-candidate live acceptance
are **deferred at operator request**, not waived or complete. Before reporting
issue #2014 complete, verify real required/named/none/auto turns, streaming and
non-streaming, schema/cardinality/exhaustion failures and cancellation on the
supported native model, then prove the same contract through the released
gateway and compatible signed provider. Preserve release asset byte identity
and previous-stable updater verification. Use `scripts/ops/cli-release.sh`
(`status`, `next`, then one documented `next --run` step at a time). No CLI cut,
provider restart, fleet recommendation change or live acceptance was performed
for this entry; issue #2014 remains open.

## Earlier: net changes vs 1.8.232 (shipped in 1.8.238 / 1.8.240)

One candidate, one Studio canary, one promotion. Nothing is recommended to the
fleet before the canary passes.

| PR / branch | Change | Status |
|---|---|---|
| #1910 | Capacity shedding and prefill fairness; measured concurrency calibration | merged |
| #1937 | Attested-hardware auto-trust, pending hardware checks non-fatal, engine-run CLI fixes, operator pause survives coordinator drains | merged |
| #1919 | Provider side of repository admission (`binary_version` must equal the compatibility-id version) | merged |
| #1927 | MLX runtime to mlx-swift-lm 3.32.3 / MLX 0.32 through the forks; Swift 6.3 / Xcode 26.6 toolchain; kernel-route-invariant CB prefill grouping | merged (`0117e6a72`) |
| #1947 | CB/MTP simplification: CB on by default, per-Mac self-check (batched-vs-alone exactness at every granted slot count, net-gain check) picks the served slots; signed CB/MTP policy becomes revocation-only; native MTP model-keyed | in progress (draft PR, Studio re-run and audit) |
| #1944 | Calendar-expiry removal (catalog, native-MTP sidecar, discovery head, autotune feed age); native MTP keeps the last verified revocation set when the feed ages out | merged (`3833ae851`) |
| #1946 | Rollback lever: a Mac on an exactly revoked build may update down to the coordinator-recommended, validly signed release (coordinator path only, never the discovery rail) | in progress: fixing the two R4 MEDIUMs (test coverage; full signed compatibility-id check), then one verification round; rides this release |

Before the cut: run the CLI train's pending one-time `privacy_release_setup` step
(`privacy_class.release_code_identities` on Pearl, #1934), so the new build's
privacy code identity is admitted from signed release metadata instead of a
hand-added cdhash.

Deploy steps this release adds (from the CB/MTP bundle):
- Re-baseline the signed native-MTP challenge bank on the #1927 runtime before the
  coordinator canary runs; otherwise the canary correctly fails native MTP.
- Raise Pearl `pool.max_concurrency_ceiling` (default 8) so a Mac's self-checked
  grant above 8 (the Studio measured 16 for Qwen3.6) is routed in full.

Release plan:
1. Cut the candidate from `main` after every row above is merged.
2. Studio canary through `cli-release.sh` (`canary_smoke`), with the self-check
   decision read from `/v1/status`. One-off, outside the train: the same
   candidate on one house M1 8GB for about 30 minutes of serving, through the
   proven private-candidate install recipe.
3. Promotion and recommendation bump.
4. The Pearl runtime train for the coordinator side follows (#1944, CB/MTP
   coordinator canary, #1942); see the coordinator release train.

Rollback after promotion (#1946): set the recommendation back to the previous
good version and revoke the bad build exactly through `cli-release.sh`; Macs on
the revoked build update down and serve again. The coordinator signal ships in
the runtime train that follows the CLI release.

## Historical fully documented 207 promotion

| Field | Value |
|---|---|
| Version | **1.8.207** |
| Compat-set id | `Augustas11/macprovider:v1.8.207@d98b74a6a158000dabaecb89d75886b6817e9d0f` |
| Coordinator `target_id` / `latest_binary_version` | `1.8.207` |
| Promotion | Immutable release [v1.8.207](https://github.com/Augustas11/macprovider/releases/tag/v1.8.207), promotion run [36526004611](https://github.com/Augustas11/macprovider/actions/runs/36526004611), final rollout verification run [36529821734](https://github.com/Augustas11/macprovider/actions/runs/36529821734) |
| Public installer / China mirror | `get.malibu.tech/install.sh` matches the released installer at SHA-256 `8a68f82b254023671715dd45f06895b4a552e35430f3afc97ff3d83c69dccde5`; consumer health resolves `v1.8.207`; `download.malibu.tech/releases/latest.json` points to `v1.8.207` and all 24 mirrored assets were byte-compared with GitHub |

## Next CLI candidate — net changes vs 1.8.207

Promotion-ready candidate cut, authorized 2026-10-08, for `v1.8.224`. **Not yet
signed.** [Acceptance run 37743452851](https://github.com/Augustas11/macprovider/actions/runs/37743452851)
at `ac7cfde0516cf69c0e2ce3f919329f9052786202` was cancelled during the unsigned
build (07:37Z), as were the three earlier attempts; no signed 224 bytes and no
tag exist. It was stopped because the checked-in coordinator recommendation
still advertised `1.8.207`, so `scripts/release-staged-version-policy.sh` would
have treated 207 rather than the live stable 223 as the previous stable for the
updater-path checks. The three `latest_binary_version` rows move to `1.8.223`
in the release-train PR; the candidate is then cut from that merged main tip
with `promotion_ready=true` and `strict_post_migration`. Version-only
[#1896](https://github.com/Augustas11/macprovider/pull/1896) carries identity
224. Existing BYOM/privacy source acceptance and unchanged decode qualification
carry forward. Keep the fleet recommendation and compatibility target on 223
until signed-byte installation, buyer-path and promotion gates pass. Native MTP
and CB activation stay in [#1894](https://github.com/Augustas11/macprovider/pull/1894),
which re-binds to the signed 224 identity after this cut.

Backend check for this train: privacy #1871/#1892 change coordinator/gateway
directory, enrollment and grouped model-scope validation. Live runtime223
predates those changes, so the corresponding paired backend runtime needs a
new deployment; identity admission/target config alone cannot ship that code.
BYOM #1895 itself is CLI-only. No backend deployment or privacy activation was
performed by this candidate cut. Follow the existing Pearl rollout ordering
and keep deployment separate from catalog/config activation.

Privacy automatic enrollment [#1871](https://github.com/Augustas11/macprovider/pull/1871)
merged on 2026-10-08 as `d6e8bb2ff370d7368d3a1bb79d28b935bc2a72b6`,
with antfleet-ops approval. Product source `60d97dacf51047e10100622eeba1a093d76b63da`
passed [CI](https://github.com/Augustas11/macprovider/actions/runs/37711353541)
and [spec-index](https://github.com/Augustas11/macprovider/actions/runs/37711353502).
The final `3175f1c7` head differed only by release-train documentation;
the operator explicitly authorized admin merge without repeating CI on that delta.
Source builds for the CLI, coordinator, operator CLI, gateway and buyer client
passed on the designated Studio; final source audit reconciliation was clear.
The signed 16-step baseline and subsequent regression/audit evidence are retained.
These results do not assert signed V2 enrollment acceptance or fleet activation.

Next activation sequence: include the merged enrollment changes in the next
signed CLI train after the remaining in-scope slices land; verify changed
enrollment/directory behavior on Studio; deploy the matching Pearl runtime;
authorize the signed release identity and a current v0.2 activation exception;
configure the signed directory and buyer key distribution; canary private
stream/nonstream traffic under load, then promote and verify eligible-fleet
automatic enrollment, preserving explicit opt-outs. Close #1749 only after
its buyer-path, disclosure, support-matrix and incident criteria are evidenced.
No candidate identity is reserved by this entry. Published CLI 1.8.223 does
not contain these newly merged enrollment changes; updating to 223 alone
does not activate network-wide privacy.

Privacy post-#1895 source acceptance on 2026-10-08: exact combined head
`2329c3ae036477b1c747dcf0cf6c4ab6fc480027` built on the designated Studio
(release 183.68s; debug 18.19s). The release executable SHA-256 is
`7811ceae336ace4ae9160903ce9852bbe3e7508f3b6addbe47d5e533a1bbc8af`.
Both Qwen artifact/catalog model names completed native stream and nonstream
requests from the verified worktree executable. Six isolated encrypted-stack
E2Es passed with no skips in 11.606s: private stream/nonstream, redaction,
automatic enrollment with signed-directory discovery, wrong-directory-key
rejection, and enrollment key-change quarantine. The encrypted cases use the
debug fixture; they are not signed native-runtime acceptance. Live provider
bytes were unchanged, and retained dependency revisions did not change.
An additional local Swift unit-test attempt could not compile because the
Studio Command Line Tools lack XCTest; the executed #1895 Swift CI passed.
These source checks support proceeding to a consolidated promotion-ready
candidate; they do not cut a candidate, authorize production enablement or
replace final signed-identity and changed buyer-path confirmation.

Privacy network activation handback, 2026-10-09 (SPEC-049 §8.3, Related:
#1749). Live changes: the signed CLI 1.8.224 code identity is approved on
production, and eligible 1.8.224 providers enrolled automatically (six
enrolled plus the operator-pinned canary). Buyer confirmation through the
public gateway with the reviewed reference client passed for identity pin and
signed directory, each stream and non-stream; directory-selected private
requests were also served by enrolled Llama providers. Every private request
settled as `relay_blind_settled`; ordinary traffic stayed healthy. Synthetic
load on the canary was paused for 37 seconds for the pin/directory run and
restarted. Findings carried to #1911: reservation selection bound the first
provider for a model regardless of free slots, and private requests lose free
slots to sustained plaintext load. The approval still carries the old dated
expiry until a runtime containing `43180f577` is deployed and the approve
step is rerun.

Privacy activation follow-up [#1892](https://github.com/Augustas11/macprovider/pull/1892)
merged on 2026-10-08 as `394bf61aea689075ac5506c506484cc75168649a`,
with antfleet-ops approval and all checks green. The accepted campaign includes
exact signed-catalog/artifact model scopes, grouped
key-record budget, compatible reservation parsing, bounded rejection reasons,
and reliable isolated-stack migration/bootstrap and executable provenance.
Studio worktree release/debug builds and native stream/nonstream model-name
checks passed; encrypted automatic-enrollment transport fixtures passed.
Linux privacy/backend/updater and repeated real-service boundary checks passed.
Consolidated source `e8c525982` built successfully on the designated Studio;
the complete code, security and architecture audit lanes report 0C/0H/0M.
Final [CI](https://github.com/Augustas11/macprovider/actions/runs/37730968917)
and [spec-index](https://github.com/Augustas11/macprovider/actions/runs/37730968835)
passed without manual reruns.
These separate results are not signed native-runtime or fleet activation.
Reuse the retained signed baseline and unchanged decode qualification; resolve
campaign findings before one reviewed train cut, then confirm the final signed
identity and changed buyer path. No candidate version is reserved here, and
#1749 remains open until private traffic is actually serving on eligible fleet
providers, including new joins.

BYOM completion campaign [#1895](https://github.com/Augustas11/macprovider/pull/1895)
merged normally on 2026-10-08 as `9bb865b823ac7278315846ce4d0ed762994c0084`,
after all 16 checks passed on reviewed head `0e4aead880e6265039474d698bc5f89d55357268`
and antfleet-ops approved that exact head. The complete code, security and
architecture audit lanes were clear. [CI](https://github.com/Augustas11/macprovider/actions/runs/37736012113)
and [spec-index](https://github.com/Augustas11/macprovider/actions/runs/37736012108)
passed. Pool-only GGUF startup can use bounded advisory upstream counts when
there is no signed sibling tokenizer; pinned recount, identity checks and the
production floor remain enforced where applicable. Protected-file credential
custody no longer blocks a positively proven consumer-user GUI updater;
headless/system and ambiguous topology remain denied.

On the designated Studio, the isolated source release build passed. That exact
source served Ollama without joining the coordinator: startup measured
13.0164 TPS, bounded nonstream output and streaming content with `[DONE]`
passed. This is local source evidence, not signed-candidate paid acceptance.
No new CLI was cut by this merge. #1690 remains 2/6 actually complete despite
its closed GitHub state: updated signed-candidate Ollama paid acceptance,
supported previous-stable installation/restart, formal mixed rollout/rollback,
and final acceptance/conformance reconciliation are still pending. Reuse the
existing release and acceptance paths; no new harness or signing tooling is
required by this campaign.

Private signed compatibility set
`Augustas11/macprovider:v1.8.212@d806dcf203a94f813aadbe458c8de578be476bd0`
was produced by acceptance run [37075501296](https://github.com/Augustas11/macprovider/actions/runs/37075501296)
under workflow control commit `dac2ab8df6d1acd7bf54df61b2a604ac609780a4`,
but is superseded: it predates the operator-pause lifecycle fix and is not
promotion-ready. The final **v1.8.213** promotion-ready private compatibility
set `Augustas11/macprovider:v1.8.213@8b2d857f2e47c5b783b1e9caa876ea41a8f653e1`
was signed, notarized, and stapled by acceptance run
[37092159775](https://github.com/Augustas11/macprovider/actions/runs/37092159775).
Independent exact-set, code-signature, notarization, stapling, Gatekeeper, and
embedded/standalone CLI byte-identity checks passed. Promotion verification for
the release-bound continuous-batching policy pair was corrected by #1838 and
replayed successfully against those exact accepted bytes. Physical acceptance
passed on the designated M3 Ultra Studio on 2026-10-03: the exact signed CLI
(`9ee225a55ae1f1a54c66cde5a53c45bad8a7c4b470c2f9e4e859391d12aa0ecc`)
replaced 1.8.207 through the established payload-only swap while preserving the
operator config and launchd definitions; Pearl accepted the exact private set
without changing its 1.8.207 target or recommendation; the provider joined as
`serving_buyers`; operator pause was acknowledged and survived a full
provider/watchdog restart; resume restored buyer serving; and a bounded local
Qwen3.6 request completed successfully. The Pearl relay and buyer runner were
then restored. The candidate remains unpromoted, untagged publicly, and
unpublished. Runtime tag `v1.8.211` and private candidate identity `v1.8.212`
are consumed and must not be reused.

| Net change in CLI / Malibu / installer | Status | PR |
|---|---|---|
| Pool model status names the qualifying pool and says eligible to earn only on qualifying settled requests. Malibu clears stale positive bindings when status readback is unavailable, inactive, or mismatched; eligibility wording does not claim current paid work or income. | merged `00700349b` 2026-10-07; awaiting a reviewed signed CLI/app release | [#1883](https://github.com/Augustas11/macprovider/pull/1883) ([#1880](https://github.com/Augustas11/macprovider/issues/1880)) |
| Automatic privacy-class eligibility and enrollment, preserving explicit opt-out and refusing ineligible posture; fleet availability still requires signed-release acceptance, approved identity, directory configuration and staged rollout. | merged `d6e8bb2ff` 2026-10-08; not yet released or activated fleet-wide | [#1871](https://github.com/Augustas11/macprovider/pull/1871) (#1749) |
| Exact catalog/artifact privacy model scopes share one signed key record; reservation parsers accept grouped scopes while keeping exact request binding. Bounded rejection diagnostics and isolated-stack bootstrap/provenance fixes complete the source campaign. | merged `394bf61ae` 2026-10-08; source accepted, signed identity and live activation pending | [#1892](https://github.com/Augustas11/macprovider/pull/1892) (#1749) |
| Pool-only GGUF advisory startup TPS without a catalog sibling, and protected-file consumer GUI updater/recovery under positively proven topology. Money-path counting and headless/system restrictions are unchanged. | merged `9bb865b82` 2026-10-08; isolated Studio source smoke passed, signed-candidate acceptance pending | [#1895](https://github.com/Augustas11/macprovider/pull/1895) (#1690) |
| Operator pause remains authoritative when coordinator drain first moves the provider to `network_offline` or `coordinator_unavailable`; only the operator command may write those pause transitions. | merged `9384e5280` 2026-10-03 | #1834 (#1770) |
| Qwen3.6 35B-A3B ordinary decode uses the fused A3B MoE kernels (fork pin `Augustas11/mlx-swift-lm@b1811029`): decode and verify rows of at most 7 tokens stay fused at any batch size in chunks of at most 7, prefill stays on the stock kernel, and exact per-tensor layout validation gates the path. Studio qualification: ordinary decode 1.25x / 1.15x / 0.97x vs stock at 1 / 2 / 8 rows, 0 parity mismatches in 36 paired blocks, bit-identical run to run. `MLX_LM_QWEN35_FUSED_MOE=0` disables it. `KVBuildIdentity` changes, so prior KV cold-tier entries miss once. Native MTP stays default-off; the native-MTP lab tooling is compiled only under `DEBUG \|\| MACPROVIDER_LAB_HARNESS`, and signed R024 `proposal_depth` is capped at 6. | merged `280f0e95d` 2026-10-05 | #1832 (#1770) |
| Privacy-class work settles under production `enforce`: a relay-blind route snapshot, a provider-signed content-free `relay-blind-settlement-v1` receipt, and the `relay_blind_settled` outcome, which is never `verified`. The provider withholds the receipt on any unvalidated usage or frame failure. | merged `d4d73c253` 2026-10-05 | #1853 (#1749) |
| Privacy posture challenges and all frames are sent only after the provider handshake ack. | merged `e03a7cb9e` 2026-10-05 | #1852 (#1749) |
| Operator-constrained privacy class (SPEC-049) ships default-off as a Beta: providers advertise it only under verified operator posture, and the coordinator kill switch and revocation survive restart. Physical acceptance is the #1839 journey. | merged `07d5b0d3a` 2026-10-04 | #1846 (#1749) |
| Privacy-class audit follow-ups: the test-only privacy fixture is compiled out of release builds and relay opacity is enforced. | merged `cbb632b33` 2026-10-04 | #1847 (#1749) |
| Release metadata carries the signed provider CLI code identity (`provider_code_identity` in `pearl-release.json`), required from 1.8.214; it feeds SPEC-049 approved code identities. | merged `04ee6e6a6` 2026-10-04 | #1848 (#1842) |
| The promoter accepts the release-bound continuous-batching policy pair as exact accepted bytes. | merged `f4d80c273` 2026-10-03 | #1838 |
| Non-hybrid continuous batching reports sampled tokens to the scheduler per decode step instead of delivering 16-token lockstep-window bursts, while block release and terminal completion remain hop-boundary operations. | merged `f096d7320` 2026-10-02 | #1828 |
| SwiftNIO is updated from 2.101.3 to 2.103.0. | merged `90c1ab060` 2026-10-02 | #1827 |
| swift-jinja is updated from 2.4.2 to 2.5.1. | merged `e797059c3` 2026-10-02 | #1826 |
| Native MTP is production-reachable only through exact signed artifact, admission, load, batching, and fail-closed serving gates; the feature remains default-off pending the formal campaign. | merged `b29b7b8f5` 2026-10-02 | #1820 (#1770) |
| Hybrid recurrent-cache reuse captures exact canonical reply-end checkpoints and fails closed when serial natural EOS has advanced beyond the publishable token state. | merged `65ee6791a` 2026-10-01 | #1819 |
| Native MLX serving rejects unsupported non-zero presence/frequency penalties instead of accepting no-op buyer controls, and balances long prefill spans. | merged `2b1de5040` 2026-10-01 | #1818 |
| The proven gpt-oss 120B mixed sliding-window paged-KV topology is admitted only for its exact measured identity, configuration, topology, and fresh-probe evidence. | merged `b01da4940` 2026-10-01 | #1815 |
| Pool-authorized loopback streaming receipts now bind `normal_done` output hashes to the buyer-delivered byte snapshot only. Complete receipts fail closed when the relay cannot prove every accepted frame was sent, final content is not byte-exact with delivered UTF-8 bytes, or post-tool-call content was suppressed after tool calls opened. | merged `d700ab749` 2026-10-01 | #1814 (#1787) |
| Rotating-window parity measurement follows upstream cache presentation without broadening production admission. | merged `a736d2b94` 2026-10-01 | #1813 |
| Autotune matched-floor recommendations now use verified artifact bytes as the residency authority when local artifact facts are available, instead of treating catalog `min_ram_gb` as the model-size truth. Recommend/apply/adoption/warm-switch/live-facts paths now preserve R018 context while capping slots from measured bytes, with recursive artifact byte accounting and checked KV arithmetic. | merged `427f24d15` 2026-10-01 | #1811 (#1794) |
| Production continuous batching requires a signed release policy; the shipped policy remains empty until packaged Studio evidence authorizes exact tuples. | merged `b55463f6f` 2026-09-30 | #1803 (#1778) |
| An unset paged-KV pool now covers the provider's advertised maximum context instead of silently rejecting requests above the former 16K default; explicit operator values remain unchanged. | merged `1b504306a` 2026-09-30 | #1802 |
| Continuous-batch rows stay inside the buyer's authenticated reserved-output budget. Gateway reserved-output metadata now flows through coordinator HTTP, clear WebSocket, and Tier-2 dispatch without rewriting the request body or receipt prompt hash; prompt-at-cap and output-overflow failures return terminal buyer 413 responses with no retry, failover, breaker fault, credit, or debit. Hardware campaign used an isolated `--no-join` Studio provider and did not connect a local build to live Malibu. | merged `9eb1553b` 2026-09-30 | #1806 |
| Signed-policy hybrid-cache admission accepts the measured `mixed` cache identity. The isolated source-built Studio campaign passed automatic policy activation, local proof, paged-KV attach, batch depth 4, and scheduler-admitted HTTP 200s for Qwen3.5 27B and Qwen3.5 35B-A3B. This evidence is prequalification only: production policy remains empty and the source-built candidate was never connected to live Malibu. | merged `1c7041800` 2026-09-30 | #1808 (#1778) |
| Recurrent-hybrid isolation verification now mirrors the production full-prompt `TokenIterator` lifecycle. On the designated M3 Ultra Studio, the isolated verifier-only candidate passed exact 48-token, two-row shared-forward parity, unequal-row isolation, peer leave/rejoin, and paged-KV attach eligibility for Qwen3.5 27B, Qwen3.5 35B-A3B, and Qwen3.8 27B. All required CI checks and the adversarial/code/security/architecture audits passed. | merged `6d1810506` 2026-09-30 | #1809 (#1778) |
| Autotune artifact downloads now fail before transfer when the temporary or destination filesystem cannot safely hold the model, with bounded size discovery, reserved-space admission, and cleanup coverage. | merged `621928aeb` 2026-09-30 | #1796 |
| Connected providers now run under `caffeinate -ims`: macOS may sleep the display while system idle sleep remains inhibited for serving. Lid-close and reconnect caveats remain explicit. | merged `acc9d087d` 2026-09-30 | #1798 |
| Malibu onboarding now shows the current autotune model and bounded progress from a sanitized process probe and paid-yield output, without exposing raw subprocess text. | merged `1f03be5cf` 2026-09-30 | #1799 |
| The public uninstaller now fails closed around transaction locking and service-state proof, removes the full installed surface, and preserves only the exact lifecycle tombstone required for recovery. | merged `25dbe1f8c` 2026-09-30 | #1797 |

## Shipped CLI 1.8.207 — net changes vs 1.8.123

Candidate **207** was promoted from exact accepted commit `d98b74a6` on
2026-09-29. The Studio serving canary now runs the signed public 207 payload
with `qwen/qwen3.6-35b-a3b`, and Pearl recommends compatibility set 207.
Private candidate 202 was removed from the accepted set after the 207 cut.
(Since SPEC-002-R004, 117 and 123 are not in the live allowlist and are in
the one-time revocation seed: they connect update-only and auto-update.)


| Net change in CLI / Malibu / installer | Status | PR |
|---|---|---|
| Baked OpenRouter priced catalog + GLM served-id rate rewrite | merged | #1612 (#1603 listed bake) |
| Uncatalogued BYOM loopback serve holds WS instead of self-flapping | merged | #1609 |
| Serve stays connected while BYOM admission is pending | merged | #1557 |
| MLX `models offer` sends snapshot hash (catalog-match works) | merged | #1548 |
| Malibu shows BYOM admission states | merged | #1497 |
| Discover OpenAI-compatible loopback models | merged | #1457 |
| Discover LM Studio and llama.cpp loopback models | merged | #1480 |
| CLI uses catalog artifact feed (baked fallback) | merged | #1468 |
| GGUF file identity hash (does not make Ollama earn) | merged | #1469 |
| BYOM offer-submit can be disabled | merged | #1448 |
| 16 GB Macs get Llama 3.1 8B, not 3B, from recommend | merged | #1488 |
| Headless Mini install + system-domain uninstall | merged | #1494 |
| First-install no longer false `rollback_failed` | merged | #1443 |
| Sparkle public key only on the v1.8.39 bridge build | merged | #1450 |
| Prepare/stage catalog artifacts without turning them on | merged | #1525 #1530 #1533 |
| Storage / Build 1 prep stays private until activation | merged | #1504 #1506 #1507 #1510 #1519 #1525 |
| SPEC-038 attach needs measured runtime evidence | merged | #1502 |
| SPEC-039 attach without sticky reattach | merged | #1475 |
| FR-PKV10 extract exists; serving still off | merged | #1476 |
| Paged KV sticky billing parity | merged | #1489 |
| Reward eligibility not claimed from the wrong state | merged | #1466 (`422fc2f1`) |
| Relay-blind encryption pilot for buyer prompt/content, default off | merged | #1467 |
| Pricing metadata only from validated endpoints | merged | #1455 |
| Security fixes F05–F11 across wallet and provider update boundaries | merged | #1454 |
| Signed conformance evidence path made reproducible and protectable (#1433) | merged | #1459 |
| OpenRouter slot-delta / stale-capacity routing on CLI path | merged | #1571 #1535 |
| Installer 404 fix: paginate latest-release lookup, de-quadratic parser | merged | #1582 (#1574) |
| Live Ollama serve + Gemma tokens (non-earning) | merged | #1576 (#1569) |
| Drop independent 256-message chat cap | merged | #1595 (#1594) |
| Concat-safe native tool-call streaming (hold XML args until `</function>`) | merged | #1596 |
| Recover inner Qwen function-XML when `</tool_call>` is missing | merged | #1599 |
| Fresh-Mac install bootstraps pinned python3 instead of CLT GUI die 8 | merged | #1610 (#1575) |
| SPEC-038 on-device parity + MoE-isolation self-measurement | merged | #1591 |
| Paged-KV attach gates so SPEC-038/039 can engage on real MoE hardware | merged | #1597 |
| Opt-in empirical max_batch concurrency calibration | merged | #1590 |
| Qwen hybrid JSON tool_call recovery, concat-safe prefixes, follow-up content deltas | merged | #1626 |
| Conversation-keyed serial serve allocates trimmable `KVCacheSimple` (FR-CI2 can skip prefill) | merged | #1634 |
| SPEC-038 scheduler uses compiled lockstep decode windows (buyer CB still off) | merged | #1635 |
| FR-CB15 leftover harness (MSB-03/05, usage, isolation, drain, replay) + MoE promotion review (flag stays false) | merged | #1640 |
| Qwen leftover `</tool_call>` after a valid tool JSON must not kill the stream | merged | #1653 |
| Login keychain for KV disk DEKs (naked CLI can persist KVS-01a) | merged | #1648 |
| SPEC-038 AC-23 MoE promotion evidence available on production scheduler (buyer CB still off) | merged | #1650 |
| Sanitized reason-coded stderr on CB prefill fail-close (buyer API stays generic 503) | merged | #1656 |
| Studio CB serve-path: accept bfloat16 KV + per-row compiled writeback (isolated 18080 HTTP 200; buyer CB still off) | merged | #1661 |
| Stop serial Qwen tool turns after the first complete valid call (omitted/`false` `parallel_tool_calls`; leftover markup must not hang) | merged | #1662 |
| Keep CB canary streams alive past the first lockstep hop | merged | #1665 |
| Pearl keyed first-turn chats enter Studio CB canary (positive cache hits stay serial until AC-26) | merged | #1666 |
| SPEC-038 FR-CB10 per-tuple acceptance coverage enforced fail-closed (see precondition below before cutting) | merged | #1672 |
| SPEC-038 FR-CB6 accepts batched-vs-serial numeric ties so MoE CB can attach | merged | #1608 |
| install.sh: fresh-install paid-yield recommend is resumable, visible, and bounded | merged | #1613 (#1605) |
| Admit `gpt_oss` only behind SPEC-039 proof gates | merged | #1617 |
| install.sh: unblock provider recovery after catalog and evidence retries | merged | #1620 |
| Prove CB scales on M3 Ultra via compiled contiguous decode (MSB command) | merged | #1623 |
| install.sh: keep pool-ready providers alive during admission lag | merged | #1625 |
| install.sh: fail SSH installs before inaccessible Keychain work | merged | #1627 |
| install.sh: preserve hardware-evidence retry guidance before rollback | merged | #1631 |
| Stage Lane A artifact preparation path | merged | #1649 |
| Build 1 Lane A private OrcaRouter/Qwen staging path: signed complete-revision authority, durable private preparation, scoped 4-bit runtime binding, isolated staging admission, and correlated route/receipt/settlement evidence. Staging-only: no public-catalog publication, production activation, payout, or automatic paid-provider qualification. | merged `3ec784c69` | #1658 (#1642) |
| Raise FR-KVP9 promotion hard ceiling to 1 GiB for KVS-01b | merged | #1655 |
| Close proved #1616 recovery-hardening gaps (installed identity, buyer-serving reason, evidence record, dangling launchd repair) | merged | #1668 |
| Drop slot reservation once the Mac has the chat | merged | #1670 |
| Keep four seats admitting four chats after a late Mac busy report | merged | #1674 |
| Correct Qwen3.6 artifact identity so providers can use the signed row (catalog) | merged | #1686 |
| Stop loopback runtimes from signing settlement receipts | merged | #1707 (#1695) |
| Provider WebSocket relay admission follows advertised seats and warm swaps | merged | #1687 |
| Refresh embedded Tier-2 identity/catalog bindings for the current model set | merged | #1692 |
| Disable optional template thinking for final-answer mode by loaded-artifact capability | merged | #1700 |
| Running provider refreshes its signed catalog envelope on `catalog_incompatible` or a newer hello ack and adopts it only for the same served row identity (no Malibu restart after a content cut). Compatibility-set rejections keep their own reason. Malibu/CLI status says "Catalog refresh needed", not "software update required" | merged `3abf42a8` | #1714 (#1705) |
| Qwen3.6 continuous batching (greedy rows): batched-output fixes (frozen compiled-decode offset, end-of-turn stops, drain-race hang, ragged rows, per-window host KV copy), Qwen3.6 hybrid cache (#1731), AC-25 lifecycle codes plus bounded admission wait, CB queue pressure relayed as `error_queue_full`, `mlx_cache_limit_mb`, revision-bound FR-CB10 acceptance (`metallib_sha256`, `kernel_identifier`). Default off; live on the Studio as `v1.8.192` | merged `36946873` | #1716 (#1646) |
| Continuous batching follow-ups: batched sampled rows (AC-6b), Qwen3.6 hybrid cache reuse and batched cached turns (AC-26, flag off by default), in-place paged KV (steady 1.5k × 4 decode 43 → 65 tok/s), bounded decode window while prefilling, provider LaunchAgent `ProcessType` `Standard` (single-stream decode 22 → 38 tok/s). Studio candidate `v1.8.195` | merged `03627cda` | #1742 (#1646) |
| Continuous-batching qualification closeout: AC-25 receipt and warm-swap lifecycle coverage, durable replay proof, falsifiable Gate A5 counter-evidence, and modeled promotion economics. Production default remains off because Gate A5 did not converge. | merged `0197f379` | #1757 (#1646) |
| China supply path: release self-update mirror, pinned Python bootstrap mirror, content-addressed model mirror/import verification, sanitized rejected-mirror diagnostics, and signed-manifest transfer bounds. The production Qwen3 8B origin is seeded; the reviewed signed Darwin release, public installer/release mirror, and #1756 mainland hardware run remain gates. | merged `ddaa551b` | #1745 (#1737, #1756) |
| Malibu app credential handoff no longer races stdout capture. | in progress | #1747 |
| Signed provider release discovery pages past newer Pearl-only releases instead of treating the newest repository tag as the CLI release; client, verifier, and freshness alarm share bounded pagination and UInt64 transport-sequence semantics. | merged `9636a125` | #1753 (#1737, #1756) |
| Engine-agnostic serving on Trusted Pools (#1690), provider side: SPEC-015 0.4.10 pool-authorized loopback receipts (`PoolRuntimeAuthorization`, receipt eligibility), llama.cpp / Ollama / mlx_lm.server loopback runtimes with engine selection, delivered-only accounting, and lab e2e fixes: a llama.cpp buyer disconnect ends with a `buyer_cancel` receipt over the delivered prefix (E2E-F3); rotate-key swaps the signing key the process actually uses (E2E-F9, pre-existing); native streams stay byte-identical to the receipt across split UTF-8 characters (E2E-F13, pre-existing). | merged `747557cc` 2026-09-25 | #1719 (#1690) |
| #1690 follow-up, provider side: the CLI consumes the SPEC-023 v0.19.1 GGUF `huggingface_revision` + `file_path` artifact tuple (older CLIs reject a feed that carries it); LM Studio (`lmstudio_loopback`) and oMLX (`omlx_loopback`) runtimes and engine-select values; cancelled-stream billing on every external engine (per-chunk logprobs/timings or a tokenizer pinned to the hash-verified snapshot, inside the coordinator's 2 s cancel window; a streamed tool call stays unattested); catalog source gains the Llama-3.2-3B `gguf-q4-k-m` artifact and 17 measured MLX sizes (catalog-lane JSON; activation is a separate signed cut). | merged `8d1880bc` 2026-09-27 | #1754 (#1690) |
| Compatible-row batched prefill with bounded prompt/decode headroom. Release eligibility remains gated on the isolated Studio campaign. | merged `95a6563d` | #1762 (#1758) |
| Exact hybrid continuous batching for `qwen/qwen3.5-27b`, `qwen/qwen3.5-35b-a3b`, and `qwen/qwen3.8-27b`: full-prompt commitment with first-token sampling from final-prefill logits, production 512-token prefill partition, one-token hybrid decode lockstep, and a 48-token load-time shared-forward parity gate. Studio campaign passed exact L511/L512/L513 parity, leftovers isolation/replay/drain/usage gates, and rows=8 throughput at 1.807× / 2.471× / 1.817× serial. | merged `38229a8c3` 2026-09-28 | #1776 (#1773) |
| Page keep-0 sliding-window layers with a windowed mask so mixed RotatingKV (gpt-oss) can use paged KV. Compiled decode stays off for sliding. Production attach and the Qwen hybrid allowlist stay fail-closed until Studio parity. | merged `5c09c5c9a` 2026-09-29 | #1785 (#1780) |
| Node-operator UX (#1689): honest `status --advanced` (readiness layers, probe-vs-sustained TPS, context source); `provider verify` bound to the live coordinator; `provider context explain | set --apply | rollback --no-restart` with installed-service-aware restart; 4K context fix (declared head_dim / hybrid layers) with context × slots memory bound and draft cap; in-config `max_context_override_provenance`; model-switch recompute; `models verify-artifact | identity | prepare --profile catalog`; CLI holds through coordinator `catalog_material_missing`. Studio lab E2E rounds 1–4 PASS. Operators with a stored 4K recommendation need a fresh `autotune --recommend`. Coordinator side (SPEC-022 R-2.7, `/poolz` gate) ships with the next Pearl runtime ≥ v1.8.193 | merged `57686a84` | #1713 (#1689) |
| BYOM v0.2 slice 2a: catalog artifact feed generator, class rate rows, ledger v3 (catalog sources only, no Swift changes) | merged | #1461 (#1453) |
| Ship catalog content release without a Pearl runtime cut (`not-buyer-serving.json` only, catalog-lane; binary unchanged) | merged | #1706 (#1688) |

Catalog-json-only rule: rule 1 above ("a PR that changes `phase3-binary/`
merges → add one row") is a path rule, not a compiled-binary rule, so a PR
that only touches JSON sources under `phase3-binary/catalog/` still gets a
row even though it does not change the Swift binary the fleet runs; #1461 and
#1706 are rows on that basis, each noted as catalog-only above.

#1658 is a compiled provider-CLI change and therefore belongs on this train,
but its physical proof is deliberately staging-only. The committed evidence
records staging commit `58ea66f17ac3a057c2f8cd3112f92226ae989101`; merged source
`3ec784c6977bdbb8367dd29b0866b60393c5011a` passed the full GitHub matrix and
three-lane audit but was not represented as a physically rerun binary. Its
private OrcaRouter/Qwen tuple remains absent from the public catalog and does
not by itself make the next CLI promotable.

#1453 is **CLOSED** (2026-09-19); it does not gate a future promotion. #1569
is a later CLI. Spec promotion #1583 is not a CLI change.

Historical pre-207 record: coordinator/gateway on live Pearl was **v1.8.191**
@ `98e3e4af` (including #1728), fleet Macs and the coordinator recommendation
were on provider binary **1.8.123**, and the Studio served signed private
candidate **195**. That campaign was not a fleet-promotion authority.

#1632 / #1638 / #1639 (coordinator leftover rewrite + gateway R014) are
coordinator/gateway, not CLI rows. #1653 **is** a CLI row (above); its
`InferenceRelay` drop is in `v1.8.174`.

#1600 is the install.sh consumer-health alarm
(scripts/CI), not the Mac binary. Curl-channel `get.malibu.tech/install.sh`
was republished **from `main`** on 2026-09-19 after #1610 (SHA-256
`c90fb44d9a780041233928f4376d7d92b71af087d034ae44c3a275fd9381d7c4`, pearl
backup `install.sh.bak-20260919T121720Z`) so `curl | bash` already had #1582
pagination and the #1575/#1610 CLT-stub bootstrap. At that point consumer
health was green against fleet **v1.8.123**, while the parity alarm remained
red until the successor stable tag carried matching installer bytes. Current
public 1.8.207 parity and mirror status are recorded in “Current promoted
stable” above.

`install.sh` on `main` has moved past served bytes: #1613, #1620, #1625,
#1627, #1631, and #1745 all touch `phase3-binary/dist/install.sh` after the
2026-09-19 republish and are **not** in the served `c90fb44d…` bytes. As of
2026-09-27, the public installer still has SHA-256
`c90fb44d9a780041233928f4376d7d92b71af087d034ae44c3a275fd9381d7c4`
and contains none of the #1745 release-mirror, Python-mirror, or
`download.malibu.tech` markers. Do not assume the curl-channel one-liner
carries them until the next republish.

### China supply state after #1745

The production Qwen3 8B model origin is live as of 2026-09-27. PR #1745
merged as `ddaa551b24731ee8be3f92782b6ebb236ff4513e`; Malibu route PR #133
merged as `ec82f738ffe512994dc242512930991856a2d0d1`; and
`models.malibu.tech` resolves to `76.76.21.21` with valid Vercel TLS. The
content-addressed snapshot for
`mlx-community/Qwen3-8B-4bit@545dc4251c05440727734bcd94334791f6ab0192`
is published at signed model hash
`1f591f9c4fb38d05ea2d879d89a6eeab485c23a04eb75e3e0a289db9d95ec877`.
All 11 payload sizes match the signed manifest, every non-weight payload was
downloaded and hash-checked, and the full 4,607,835,174-byte public weights
object streamed with SHA-256
`f2d29621aab300336ad645567ff38c42aac755513006ef4e8a579cf7ef5256d8`.

This closes only the production model-origin blocker. Public release
`v1.8.200` has Linux Pearl assets only; it has no signed Darwin provider CLI.
`download.malibu.tech/releases/` and
`download.malibu.tech/releases/v1.8.200/checksums.txt` return 404. Do not call
the China supply track green until a reviewed signed post-#1745 CLI and its
installer/release mirror are published and #1756 passes from a clean mainland
Mac with the prohibited resolver boundary active.

### Continuous-batching continuity before candidate promotion or upgrade

SPEC-038 FR-CB10 requires exact signed-policy coverage for coordinator-joined
serving. Since #1803 (`b55463f6f`), `continuous_batching_accepted_tuples` is
an isolated `--no-join` test input; it cannot authorize production batching.
Keeping `continuous_batching: canary` in configuration is insufficient.

Before recommending or installing successor bytes, preserve each previously
active qualified hardware/model/cache tuple. A CB policy entry matches the
model, tokenizer, chat template, cache class, hardware, metallib and kernel,
not the provider version or CDHash (SPEC-023 v0.22.13). So a successor that
ships the same metallib and kernel keeps its coverage without a new policy
entry, and the per-Mac self-check re-measures it. Add or correct an entry only
when one of those matched fields changes. An empty policy or rollout `off` is
a capability loss, even when feed signature verification and provider join
succeed.

Native-MTP admission works the same way from SPEC-048 0.1.51. Before each cut,
read `cli-release.sh status` fact `native_mtp_admission_decode_path`. `match`
(the source decode path, plus the canary's self-check metallib equal to the
entries' `metallib_sha256`) means no admission step. `mismatch` means
requalification. `legacy` means the one final dual-field rebind after that cut
is released
([runbook](../runbooks/native-mtp-enablement.md#later-cli-cuts-no-admission-step-unless-the-decode-path-changed)).

After the signed upgrade and restart, verify `policy.load_status=live_verified`,
`policy.authorized=true`, `policy.local_proof_result=passed`,
`paged_kv_decision=attached`, and `active=true`, then confirm a scheduler-admitted
serving request through the Malibu gateway. Ready/connected alone is insufficient.
An intentional disable requires an explicit reviewed operator decision; do not
silently reinterpret missing coverage as intentional. See
[the signed-policy enable gate](../runbooks/continuous-batching-enable-gate.md)
and [the regression investigation](../runbooks/continuous-batching-upgrade-continuity.md).

## Active candidate

Shared-namespace update (2026-10-07): runtime **v1.8.221** carries the deployed
#1874 settlement fixes. Provider **v1.8.222** is a signed private acceptance
candidate serving the #1690 pool members, not a public stable release. Provider
**v1.8.217** remains published and the fleet recommendation remains **v1.8.207**.
Refresh both release trains and remote tags before reserving another shared
identity; this status update does not allocate a successor version.

| Field | Value |
|---|---|
| Private acceptance candidate | **v1.8.222** (Malibu build 222), signed from reviewed-main source `7e68120b8ac0b92e8291a990c88b40f55bafcf5a`, acceptance run [37493026731](https://github.com/Augustas11/macprovider/actions/runs/37493026731). The serving pool-member CLI matches the packaged standalone SHA-256 `fc3e54691585a0b0fa9509225fcac51ae89b6dba10f172a2f098f271b94bedcc`. It carries #1874's Trusted Pool cancel-receipt fixes and passed the fresh 11-step production external-runtime capture. It predates #1879's reviewed startup-tokenizer fix; no public release, fleet promotion, or successor-candidate packaging/updater acceptance is claimed. See [the closeout evidence](../../audits/2026-10-07-1690-closeout/README.md). |
| Historical 217 acceptance set | Then-private **v1.8.217** compatibility set `Augustas11/macprovider:v1.8.217@71f22d36c3ef11c99d3572f63bb0283f73f19aa5`, acceptance run [37389822832](https://github.com/Augustas11/macprovider/actions/runs/37389822832) (signed 2026-10-06 00:27Z), candidate/control commit `71f22d36c`, `checksums.txt` SHA-256 `f2e83cd76834b946ec209dad5a19ba88ad677d951fd5b33e96890525f7e9d2be`. Independently verified: every `checksums.txt` entry matches, the standalone CLI passes strict `codesign` verification and reports `1.8.217`, the DMG is stapled and Gatekeeper-accepted as Notarized Developer ID, and the embedded and standalone `macprovider-cli` are byte-identical (SHA-256 `a6ea51d7ad19359a21fac63995194523264035fbca2ab32dceeede9d9da739bb`). Subsequently installed and published; see the serving-canary and promotion rows below. The private acceptance set expired 2026-10-07 00:27Z and is not a successor promotion candidate. Previous build v1.8.215 (run [37305423870](https://github.com/Augustas11/macprovider/actions/runs/37305423870)) was superseded before promotion because it predates #1832. Fleet-recommended candidate remains **v1.8.207** @ `d98b74a6a`. |
| Mac Studio serving canary | Signed public **217** @ `71f22d36c`, swapped in 2026-10-06 04:03–04:05Z through the established payload-only operator swap (config and LaunchAgents byte-identical; 213 payload kept at `/Users/a1/macprovider.pre-217-20261006T040351Z`). It serves `qwen/qwen3.6-35b-a3b` on the fused A3B MoE path (kill switch unset), joins under the 217 compatibility set on the 10-01 catalog, and resolves the signed CB policy (`live_verified`, zero entries, so CB stays off by policy). Buyer path down about 2m11s. |
| Off-train E2E candidate | `v1.8.167` @ `7f833a2f63ddee6b2e146c821341099d89aec169` ([run 35417249468](https://github.com/Augustas11/macprovider/actions/runs/35417249468)) — signed hold-branch CLI used for the 2026-09-19 Pearl Track B run |
| Older | `v1.8.163` @ `8c0c51d2`; `v1.8.164` @ `eb30981c` (BYOM #1576 `cdbb0257` + #1591 + #1590 + #1593); CLI artifact `v1.8.166` @ `00ce3625` (not the Pearl runtime tag); CLI `v1.8.172` @ `c512d342`; CLI `v1.8.174` @ `0c276ebb`; CLI `v1.8.175` @ `d02798db` |
| Status | **207 promoted and live; 212 superseded without launch; 213 physically accepted but superseded without promotion by operator decision on 2026-10-04; 214 cut and journey-accepted but superseded without promotion on 2026-10-05, because relay-blind work was refused under production settlement `enforce` until #1853; 215 cut on 2026-10-05 but superseded without promotion because it predates #1832.** Pearl `target_id` and `latest_binary_version` remain 207. Public installer parity, consumer health, mirror byte identity, signed discovery rollout, Studio join, and a bounded real-buyer response are green for 207. |
| Consumed identities | Runtime identities through **v1.8.221** and provider candidates through **v1.8.222** are consumed/reserved. The private 222 candidate must not be reused for the later #1879 source. Runtime **v1.8.220** was signed at `6d49a4f16` by [run 37468267969](https://github.com/Augustas11/macprovider/actions/runs/37468267969); deployed runtime 221 and private provider 222 are recorded in the [#1690 evidence](../../audits/2026-10-07-1690-closeout/README.md). Refresh both trains and remote tags before reserving the next number. |
| Promotion candidate | **v1.8.217 is published** (immutable release [v1.8.217](https://github.com/Augustas11/macprovider/releases/tag/v1.8.217), promotion run [37412526946](https://github.com/Augustas11/macprovider/actions/runs/37412526946), published 2026-10-06 04:14:52Z). Verified after publication: `checksums.txt` SHA-256 `f2e83cd7…` equals the signed set, the tarball and DMG `macprovider-cli` are byte-identical (`a6ea51d7…`), download.malibu.tech serves identical tarball and checksums, and `get.malibu.tech/install.sh` matches `phase3-binary/dist/install.sh`. Physical acceptance: fused e2e on the signed binary (fused vs stock, batch invariance, cancellation, memory, kill switch) and the Studio install/join smoke above. **Operator decision 2026-10-06: the fleet recommendation stays on 1.8.207** (Pearl `target_id` / `latest_binary_version` unchanged, mirror `latest.json` stays v1.8.207). The next CLI candidate bundles the native-MTP step-overhead fixes (branch `mtp/step-overhead`, gated on a new R015) with the #1690 CLI fixes (branch `fix/1690-loopback-startup-throughput`), and that candidate is the one recommended to the fleet. |
| Candidate 202 CB-canary confirmation (2026-09-28) | Isolated Studio loopback serve of the **signed** 202 binary (`--no-join`, ephemeral id, :8092, live :8080/201 untouched) confirmed `qwen/qwen3.6-35b-a3b` **paged-KV attach eligible** (runtime parity `established=true`, cross-row MoE isolation `proven=true`) and a keyless **scheduler-admitted batched 200** with a stable `X-Request-ID` (`event=batching_admitted action=scheduler_admitted`), hash `3fed776d…`. Measured throughput (harness, v1.8.201 same source): 2.86× aggregate vs serial at 8 rows, bit-exact parity. On candidate 202 the qwen3.5/qwen3.8 hybrids fail parity and are excluded; #1776 fixes them only in the deferred successor candidate. Buyer `continuous_batching` was already canary in live config; the 201→202 serving swap (operator-tools/swap-202.sh, 2026-09-28) made 202 the live Studio provider — a3b now served BATCHED (scheduler_admitted) at ~2.86x. |
| Notable merges after candidate 186 | #1707 (`5ada77e1`, CLI); #1714 (`3abf42a8`, CLI + Malibu); #1706 (`2b352720`, catalog-lane file only — binary unchanged); #1713 (`57686a84`, node-operator UX — shipped in `v1.8.192`); #1742 (`03627cda`, shipped in Studio candidate `v1.8.195`); #1757 (`0197f379`, CB qualification closeout); #1745 (`ddaa551b`, China supply path); #1762 (`95a6563d`, batched prefill); #1658 (`3ec784c69`, Build 1 private staging path); #1753 (`9636a125`, signed provider-release discovery, merged after candidate 201); #1771 (`e29ea2976`, Qwen3.6 MoE paged-KV admission, shipped in candidate 202); #1776 (`38229a8c3`, Qwen3.5/Qwen3.8 exact CB parity, merged after candidate 202); #1785 (`5c09c5c9a`, keep-0 sliding-window paged KV, merged after candidate 202); #1808 (`1c7041800`, mixed-cache signed-policy admission); #1809 (`6d1810506`, recurrent-hybrid verifier lifecycle). Coordinator/gateway settlement recovery continued separately through #1728, live in Pearl runtime `v1.8.191`. |
| Why candidate 186 exists | Prove #1700 final-answer rendering, strict-pinned buyer quality, eight-seat routing, and durable settlement on one signed Studio-only build (soak proof; live seats since reduced to one — see Mac Studio serving canary above). |

### #1690 merged source and remaining release gates (2026-10-08)

[PR #1879](https://github.com/Augustas11/macprovider/pull/1879) merged at
`bc117360106d91055221e01f0f8b0de4cd2ac550`. It resolves startup throughput's
stream-fragment counting with artifact-bound pinned tokenization and records
the reviewed capability-aware Ollama qualification profile. Fresh
[CI](https://github.com/Augustas11/macprovider/actions/runs/37592545986) and
[spec-index](https://github.com/Augustas11/macprovider/actions/runs/37592546005)
passed on the reviewed head; combined code, security, and architecture reviews
finished with zero CRITICAL/HIGH/MEDIUM findings. This is merged source, not
proof that the fix has shipped in the private 222 candidate or a public release.

Layer2 [signing run 37597017902](https://github.com/Augustas11/macprovider/actions/runs/37597017902)
and creator [signing run 37597062267](https://github.com/Augustas11/macprovider/actions/runs/37597062267)
succeeded, as did external-runtime
[signing/promotion run 37597012552](https://github.com/Augustas11/macprovider/actions/runs/37597012552)
(completed 2026-10-07 09:09Z). All three exported envelopes passed targeted
signature, artifact-binding, expiry and current-selector verification at the
original integration base. After #1883/#1876, only the three external-runtime
promotion rows still pass current-selector validation. Layer2 R010 and creator
R007 selectors drifted; their older signed captures remain historical only.
Fresh unsigned Layer2 `20261007T122927Z` and creator `20261007T122939Z` captures
passed on merged source `62a9a459de59f759e09fbe88a9015e738da367ae`. Protected
signing and reviewed signature integration follow after those capture bytes
land on main. Workflow success alone is not landed conformance.
These evidence-only workflows neither publish a CLI nor activate an external
Creator launch.

The reviewed captures landed in #1886 (`080eb8404`). Fresh Layer2
[run 37625849934](https://github.com/Augustas11/macprovider/actions/runs/37625849934)
and Creator
[run 37625855687](https://github.com/Augustas11/macprovider/actions/runs/37625855687)
then succeeded from that main commit. All 16 fresh signature, artifact-binding,
expiry and current-selector mappings passed targeted integration verification.
Fresh signatures landed in #1887 and remain evidence-only (Layer2 expiry
2026-10-14; Creator 2026-10-07, now historical). No Layer2/Creator conformance
promotion, external Creator launch or binary release is claimed.

The release/closure gates still outstanding are:

- Layer2/Creator protected signatures landed in #1887 (`743f9ec0d`), with
  unchanged pending conformance states. Fresh BYOM discovery capture
  [`20261007T161811Z`](../../journeys/evidence/provider-byom-discovery-20261007T161811Z.redacted.json)
  passed all ten hermetic steps on `9c8c87dbff8ee00ba2c72f7923e1dce268c42e78`,
  superseding the failed compilation attempt as current unsigned evidence.
  Reviewed unsigned capture landed in #1889 (`bf88db0c1`). Exact PR-head CI
  [37708073165](https://github.com/Augustas11/macprovider/actions/runs/37708073165)
  subsequently passed. Current-main CI
  [37712605781](https://github.com/Augustas11/macprovider/actions/runs/37712605781)
  passed at `855149bd0` before protected signing
  [37715135336](https://github.com/Augustas11/macprovider/actions/runs/37715135336)
  completed after antfleet-ops approval. Its exported capture and envelope
  hashes, pinned public-key signature, expiry, artifact bindings and both
  current-source mappings passed integration verification. The protected output
  promotes only R001/R008; reviewed integration merged in #1891 after green CI
  and exact-head review. This does not prove
  released-CLI acceptance or complete #1690.
- All five released223 isolated `serve` selector/identity legs were executed
  successfully, including real hello hashes, runtime model translation and503
  drift refusals without another upstream chat. The additional `openai:` control
  rejected startup but did not match the runner's expected error wording.
  Conformance reconciliation remains pending; no new harness/tooling PR is
  required or being opened. This does not activate five engines in production.
- [CLI v1.8.223](https://github.com/Augustas11/macprovider/releases/tag/v1.8.223)
  was published from reviewed `9c8c87dbff8ee00ba2c72f7923e1dce268c42e78` by
  [release run 37642806955](https://github.com/Augustas11/macprovider/actions/runs/37642806955).
  Final public tarball/package/DMG CLI byte identity and signing/notarization
  proof are reconciled in the
  [closeout record](../../audits/2026-10-07-1690-closeout/README.md#public-v18223-package-proof-reconciliation--2026-10-08).
  Anonymous discovery passed on both223 and previous stable217. Fresh public223
  Llama/Ollama streaming and non-streaming requests each passed through the223
  gateway/coordinator while both external members remained222, with valid v0.4
  receipts, payable credits, closed verified finality and no settlement holds.
  Selection refusal checks passed, including a refunded wrong-allowlist reservation.
  This establishes mixed222/223 settlement, not public223 provider reacceptance.
  Public223 external-member transition/paid reacceptance, previous-stable
  installation/restart, receipt-authorization omission and
  disclosure reconciliation remain pending. Existing envelopes remain unchanged.
- Complete formal mixed-version rollout/rollback acceptance. Recorded
  217/219/222 coexistence is not a rolling-restart proof; a refused v1-only
  rollback preflight is not rollback readiness. Current `p1816` preflight passed
  with131 route snapshots,63 v2 manifests and no unresolved pool verdicts;
  the actual drill remains pending.
- Complete the final closure audit and reconcile #1690's required gates.

Current native/llama.cpp comparison and capability-aware Ollama measurements
passed their scoped profiles. Ollama's cached API-counter measurements are not
strict M0 token-ID/cache-free parity, runtime perplexity, billing authority, or
release acceptance. Full measurements and limitations remain in the
[closeout evidence](../../audits/2026-10-07-1690-closeout/README.md).
No release identity, live binary, or fleet recommendation changes in this
documentation update. #1690 remains open.

## E2E tracks (independent gates)

A release is promotable only when every in-scope track is GREEN. Normally the
evidence belongs to the same combined candidate. A recorded operator acceptance
may carry forward evidence when the final candidate changes only release
identity or changes outside that track's exercised path; the record must name
the carried evidence, the excluded delta, and the exact-candidate checks that
remain mandatory.

For v1.8.207, the signed 201/202 Studio evidence is accepted for Tracks A, C,
D, and F without repeating those expensive campaigns. The post-202 delta is
bounded: #1776 admits the separately measured Qwen3.5/Qwen3.8 identities, while
#1785 adds an isolated sliding-window measurement path but keeps production
attach fail-closed for that class. The exact signed 207 must still pass
install/join smoke, checksum and embedded CLI byte-identity verification, and
Pearl compatibility-set admission. Track E remains mandatory before the final
mainland-provider installer handoff.

### Track A — OpenRouter readiness

- **Owner / tracker:** #1570
- **Harness:** `scripts/openrouter_readiness_probe.py` · runbook
  `docs/runbooks/openrouter-provider-apply.md`
- **Gate:** benchmark success ≥ 0.95, TTFT p95 ≤ 5000ms, output tps ≥ 10, 0
  502/non-capacity failures; saturation sheds cleanly (early 429, no upstream
  errors); chat (paid+free), models, privacy, health/provenance, wholesale
  statement all pass. `--filing-mode` for the final application (prod URLs +
  benchmark ≥ 100).
- **Last run:** 2026-09-21 wholesale `acct_openrouter` `mp_` key against
  signed Studio **v1.8.176** serving
  `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` (not the Llama 3B fleet).
  Pearl **v1.8.174**. Artifacts:
  `~/.local/state/macprovider/openrouter-readiness/openrouter-readiness-20260921T130140Z-qwen30-studio-176-wholesale.json`
  (idle + ladder + sat) and
  `…T130616Z-qwen30-studio-176-wholesale-soak100.json`.
  Soak 100@4 **FAIL** 45/100 HTTP 200, **55× 429** `no_provider_available`,
  **0× 503**. Idle 16/16 200 but TTFT p95 6362ms (gate ≤5000). Sat 16@8:
  2×200 + 6×429. Ladder clean only through conc=2; conc=4 sheds 5/8.
  Same shape as 175 (49/100). Keyed first-turn CB did not lift Pearl 4-wide
  success. Do not raise slots. Do not set CB `on`. Do not promote.
- **Candidate 201 prequalification (2026-09-28):** live signed 201 serving
  Qwen3.6 35B-A3B passed the applicable public buyer surfaces: chat, models,
  privacy, and health; a clean 16-request idle repeat was 16/16 with TTFT p50
  1765 ms, p95 4546 ms (gate 5000 ms), and 108.475 output tok/s. A true
  16-simultaneous overload produced 8 successful streams plus 8 early 429
  `account_concurrency_exceeded`, with no 5xx or non-capacity failures. The
  earlier sample taken immediately around the load campaign measured 6024 ms
  p95, so retain both results as contention evidence. This is not filing
  evidence: paid+free chat and the wholesale statement were not rerun. For the
  207 China installer release, the operator accepts this evidence without an
  exact-candidate Track A repeat; OpenRouter filing remains a separate gate.

### Track B — BYOM Ollama / Gemma

- **Owner / tracker:** #1569 (not #1453)
- **Harness:** `test/e2e/byom/gemma_runtime_journey.py` · runbook
  `test/e2e/byom/GEMMA-RUNTIME-JOURNEY-RUNBOOK.md` (onboarding sibling:
  `test/e2e/byom/run-cli-onboarding-e2e.py`)
- **Gate:** one signed CLI process serving `ollama:gemma3:270m` with
  `runtime_source=ollama_loopback` and `macprovider.gguf-file.v1`; coordinator
  synthetic probe returns `synthetic_probe_passed` and
  `synthetic_probe_completion_tokens > 0`; `catalog_model_key` stays null;
  never `catalog_priced` / `settlement_capable`. Delete this provider's
  `model_admission_events` after the run or catalog Llama de-routes.
- **Last run:** 2026-09-19 live Pearl (`wss://coordinator.malibu.tech/ws/provider`)
  with signed `v1.8.167` @ `7f833a2f`. Serve `ollama:gemma3:270m` /
  `ollama_loopback`. Offer coordinator-backed,
  `coordinator_event_id` `bcdbd3cedfa2e4149b4094ddb6ae6629fc131fd7e78aa7954fdc4a67555506c6`.
  Probe: `synthetic_probe_passed` → `network_admitted_unsettled`,
  `synthetic_probe_completion_tokens=4`. Admission rows deleted afterward;
  stock earner restored to `1.8.123` `buyer_serving` / `live_verified`.
  A signed candidate from a non-install path must not re-exec into
  `~/macprovider/macprovider-cli` (that is how 167 first looked like an MLX
  load). Re-run Track B on the next candidate (it will include #1609) before
  promoting a BYOM-serve CLI. `v1.8.168` does **not** include the hold.

### Track C — Pi / Qwen tool-call smoke (this cut)

- **Owner / tracker:** #1594, #1596, #1599 (Pearl coordinator already hotfixed;
  this track proves the **Mac CLI**).
- **Gate:** against a candidate-installed provider: stream+tools bash args are
  one complete JSON object; leaked `<function=bash>…</function>` without
  `</tool_call>` becomes `tool_calls` (Pi runs bash, no XML in chat); CLI no
  longer returns `messages_too_long` at 256. Prefill TTFT on Pi’s ~4.5k system
  prompt is **not** a gate — that is hardware, not this cut.
- **Last run:** 2026-09-21 Pi 0.85.1 json vs OpenRouter
  `qwen/qwen3-coder-30b-a3b-instruct` on live `api.malibu.tech` + signed Studio
  **v1.8.175**. Same prompt as 171/174: Makefile `test-dist` first command,
  then `gh pr view 1638`. Malibu **PASS** (53.47s / 34.53s; `ls`/`read`/`bash`
  executed; leftover `missingEndDelimiter` did not hang; answers
  `bash scripts/test-openai-wire-compat.sh` and PR 1638 MERGED). OpenRouter
  **PASS** 29.97s. `~/.pi/agent/settings.json` untouched. Do not promote. Do
  not set CB `on`.
- **Candidate 201 prequalification (2026-09-28):** Pi 0.85.1 json against the
  live Qwen3.6 35B-A3B route executed `read` and `bash`, returned the correct
  `test-dist` first command and repository commit, and exited cleanly in
  24.78s. The run used an isolated Pi config; the real
  `~/.pi/agent/settings.json` mtime was unchanged. For 207, this evidence is
  accepted without repeating the Pi campaign; exact signed-207 install/join
  smoke remains mandatory.

### Track D — Studio Qwen final-answer and settlement recovery

- **Owner / tracker:** #1700, with settlement dependency #1699.
- **Gate:** install one reviewed and signed post-#1700 candidate on the Studio;
  strict-pin real Malibu buyer requests to it; verify exact final answers,
  useful coding/debug/test work, and a multi-turn tool scenario; classify the
  same request IDs through durable settlement evidence. Then pass at least
  95/100 unique coding chats at concurrency 4 and exactly 16/16 at concurrency
  8, with eight requests observed in flight and no recurring routing, queue,
  transport, malformed-answer, or incomplete-answer failures.
- **Pre-merge isolated proof:** the local #1700 release build passed exact-answer
  and no-thinking checks across all 11 loadable cached catalog artifacts: nine
  Qwen-family artifacts spanning Qwen2.5, Qwen3 Coder/Instruct, Qwen3, Qwen3.5,
  Qwen3.6, and Qwen3.8, plus GLM-4.5-Air and Nemotron-3-Nano. The fix is driven
  by the loaded template's
  `enable_thinking` capability, not a family-name guess. This proves local HTTP
  rendering only; it does not satisfy buyer routing, billing, receipt, or
  settlement gates.
- **Historical candidate 186 result:** answer quality passed;
  the strict-pinned buyer soak reached **99/100 at concurrency 4** and **16/16
  at concurrency 8**, with all successful replies free of thinking text and
  eight seats observed in flight (historical — live seats were reduced to one
  on 2026-09-24; see Active candidate above). Durable evidence was **113/116
  complete**; the three incomplete settlements keep this track open. #1728
  is merged and now **live** in Pearl runtime `v1.8.191` @ `98e3e4af` (since
  2026-09-24 05:23Z), so the settlement-complete rerun is unblocked — run it
  against this runtime before closing Track D. During this historical campaign,
  fleet recommendation and `binaryVersion` remained at 1.8.123; the later
  1.8.207 promotion superseded that hold.
- **Candidate 201 prequalification (2026-09-28):** Qwen3.6 35B-A3B completed
  100/100 buyer requests at concurrency 4 with 12,800 completion tokens, zero
  non-capacity failures, and valid usage. The adjacent c8 harness window was
  16/16 HTTP 200; the topology-correct 16-simultaneous overload admitted eight
  and shed eight cleanly. Pearl read-only evidence for the 110-request campaign
  window was 110/110 HTTP 200/no-error, `normal_done`, output available, and
  valid canonical usage JSON, with zero quarantine and zero billing faults.
  Pi supplied the final-answer/tool execution proof. For 207, the operator
  accepts this evidence without repeating the quality, multi-turn, or
  concurrency campaign. Prefix-cache billing is separately deferred until the
  #1768 coordinator fix is deployed and is not a 207 China-installer gate.

### Track E — China install and Qwen3 8B without GitHub or Hugging Face

- **Owner / tracker:** #1756, implementation #1745.
- **Gate:** on a clean Apple Silicon Mac under a mainland-China network
  vantage, install from the public Malibu entrypoint using a reviewed signed
  post-#1745 CLI; acquire the pinned Python bootstrap and Qwen3 8B through the
  approved Malibu mirrors; reproduce the signed model hash; start the provider
  and complete inference. A resolver-level deny/capture must prove zero GitHub,
  Hugging Face, LFS, Xet, or CAS lookups/connections throughout install and
  acquisition. A configured fallback variable or proxy is not proof.
- **Status:** production model origin **GREEN**: `models.malibu.tech`, TLS,
  immutable routing, manifest, sizes, and full weights hash are verified.
  Signed provider-release discovery #1753 is merged in `9636a125`, closing the
  source-side newest-tag/CLI-selection gap. The track remains **OPEN** because
  candidate 201 predates #1753 and is private, the latest public release is
  Pearl-only, `download.malibu.tech/releases/` is unseeded, the served
  installer predates #1745, and no released-binary mainland run has passed.
  Cut signed candidate 207 from post-#1753 `main`; do not substitute the
  earlier ad-hoc local build or Vietnam boundary exercise for this gate.

### Track F — Studio batched-prefill qualification

- **Owner / tracker:** #1758, implementation #1762 (`95a6563d`).
- **Candidate floor:** a reviewed, signed provider CLI cut from `main` at or
  after `95a6563d`. Candidate 195 predates the batched-prefill implementation
  and cannot satisfy this track.
- **Gate:** on the Studio and the exact packaged Metal runtime tuple, run four
  concurrent 1.5k-token prompts with 128 output tokens and keep worst first
  token under 20 seconds; run four concurrent 4k-token prompts with 128 output
  tokens and keep worst first token under 45 seconds; run four concurrent
  8k-token prompts without `continuous_batching_block_extension_failed`, using
  bounded queueing/backpressure if the block pool cannot admit all rows.
  Decode parity, cross-row isolation, cancellation, duplicate-terminal,
  receipt, and warm-swap boundaries must remain green.
- **Status:** **Accepted for the 207 China installer release from candidate
  201/202 evidence.** On
  2026-09-28 the signed packaged candidate, serving Qwen3.6 35B-A3B, completed
  1.5k×4 at 4/4 with 9.189s worst TTFT, 4k×4 at 4/4 with 16.042s worst
  TTFT, and 8k×4 at 4/4 with 25.730s worst TTFT. All rows produced 128 output
  tokens; no block-extension, OOM, queue, or backpressure failure appeared,
  and the provider returned ready/idle with stable RSS. Candidate 201 contains
  #1762, so this is valid performance prequalification. Cancellation,
  duplicate-terminal, receipt, and warm-swap boundaries were not repeated in
  this live pass. The operator accepts the existing signed-candidate evidence
  for 207 under the bounded post-202 delta recorded above; no expensive
  exact-207 Track F repeat is required.

### Track G — signed-policy hybrid activation (#1778)

- **Candidate floor:** a reviewed provider CLI cut from `main` at or after
  `6d1810506`, then signed, notarized, stapled, and packaged by the protected
  acceptance workflow. Source-built and verifier-only binaries cannot satisfy
  this track.
- **Prequalification:** **GREEN.** The designated M3 Ultra Studio passed the
  exact Qwen3.5 27B, Qwen3.5 35B-A3B, and Qwen3.8 27B tuples with 48-token,
  two-row shared-forward parity and zero row failures or cross-row
  divergences. The run used an isolated `--no-join` provider; it did not alter
  the installed live provider or prove Malibu routing, billing, receipts, or
  settlement. See the
  [durable Studio evidence](../../audits/2026-09-30-issue-1778-verifier/RESULT_studio.md).
- **Release gate:** **OPEN.** Repeat the three exact tuples on the packaged
  signed bytes without lab shims and capture automatic signed-policy
  activation plus scheduler-admitted HTTP evidence. Prove byte identity
  between the final Malibu.app and standalone-tarball `macprovider-cli`, and
  verify update from the previous stable release.
- **Live gate:** **OPEN and requires explicit authorization.** With the exact
  reviewed release candidate, prove real Malibu coordinator/gateway/buyer
  routing, billing, v0.4 receipts and settlement, warm swap, rollback, and a
  controlled nonempty signed production-policy rollout. Do not connect a
  locally built or unreleased binary to the live coordinator.
- **Closure rule:** keep #1778 open until both open gates have durable evidence.

- **Carry-forward CF-230-E2E (1.8.230, candidate `15ec4ebd5`, run 37912670009):** carry forward the 1.8.224 in-scope e2e. 1.8.230 changes no decode-path code: it adds the native-MTP Keychain-stall change from PR 1901, the CB upgrade release gate from PR 1904, the `creator` command group from PR 1908, and drops per-binary CB/native-MTP binding and calendar-expiry gates (PR 1918). Live proof on the designated Studio, 2026-10-09 10:50-10:55Z: payload-only swap to the exact signed candidate; `canary_smoke --probe` recorded binary 1.8.230, exact compatibility set, coordinator connected, CB active with the existing signed policy authorized and `live_verified`, paged KV attached; a gateway buyer request for `qwen/qwen3.6-35b-a3b` returned 200 with native-MTP target forwards 0 -> 66.

- **Carry-forward CF-232-E2E (1.8.232, candidate `36758c05c`, run 37957112917):** carry forward the 1.8.230 in-scope decode e2e (no decode-path change for native MLX). 1.8.232 adds the #1923 BYOM polish (claim credential store, creator revoke/lifecycle, `--from-proposal`, `restart`, pool selection in offers, mlx_lm.server and LM Studio resolution). In-scope e2e for those changes ran live on the exact signed candidate on the designated Studio, 2026-10-09 22:25-22:51Z: payload-only swap of the live provider; `canary_smoke --probe` recorded binary 1.8.232, exact compatibility set, coordinator connected, CB active and `live_verified`, paged KV attached. Three fresh provider identities on 1.8.232 (Ollama, LM Studio GGUF, mlx_lm.server MLX snapshot) were bootstrapped with referral codes, claimed through the portal, proposed with `models propose --yes` (signed `requested_pool_model_id`), added to a self-serve pool by a v2 manifest signed with `creator manifest sign --from-proposal` and admitted; one paid buyer request per engine through the public gateway returned 200 with `X-MacProvider-Engine` `ollama_loopback`, `lmstudio_loopback`, `mlxlm_loopback`, each credited (`provider_reported`, not quarantined).
- **In-scope e2e record CF-238-E2E (1.8.238, candidate `6f7290f45`, run 38045791437):** 1.8.238 changes the decode path (#1927 MLX 3.32.3 / MLX 0.32 forks; #1947 CB on by default with the per-Mac self-check; model-keyed native MTP), so this is fresh evidence, not a carry-forward of 1.8.232. (1) #1927 Studio evidence on the final stack: startup isolation probes `proven=true`, `crossRowDivergences=0` for A3B (fused MoE on/off) and 27B; grouped-prefill probe 0/108 divergences; native-MTP R015 PASS (`docs/research/mlx-swift-lm-3.32.3/`). (2) #1947 Studio e2e on the 3.32.3 runtime: Qwen3.6-35B-A3B self-check exact at k=2..23 (near-ties only), granted; Llama 3.1 8B identical at every width, granted; 16 concurrent tagged requests all batched (`audits/2026-10-10-auto-cb-slots/`). (3) Exact signed candidate, live, 2026-10-10: payload-only swap of the designated Studio provider at 11:58Z; `canary_smoke --probe` recorded binary 1.8.238, exact compatibility set, coordinator connected, CB active, paged KV attached, self-check `granted` 8 slots (verified k=12), plus a gateway proof. (4) Exact signed candidate on an M1 8GB house provider (Llama 3.2 3B), swapped 12:21Z: ready and buyer-serving, self-check pending at 1 slot by design; over 9 minutes of runner traffic it served 214.6k tokens/hour at 2.77 s median request time vs 209k/hour and 2.85 s on 1.8.232 in the prior hour (no regression; the 2.3 tok/s startup probe was first-run kernel compilation). (5) Privacy code identity admitted from the signed release metadata (`registrations: approved by release_metadata`), no hand-added cdhash. Native MTP: the re-baselined challenge bank (PR #1954, digest `7d624766…`) is released right after promotion; its first live coordinator canary on the signed 1.8.238 is the remaining MTP gate.
- **Carry-forward CF-240-E2E (1.8.240, candidate `7c3485159`, run 38064120168):** carry forward CF-238-E2E. 1.8.240 changes no decode-path line: #1956 only gives the native-MTP self-check's ordinary-reference request IDs a per-run nonce, so durable replay claims no longer reject native-MTP admission on every restart after the first (the 1.8.238 `selftest_execution_failed` regression from #1947). Live on the exact signed candidate, 2026-10-10: payload-only swap of the designated Studio provider at 16:07Z, which is a restart; afterwards native MTP is `enabled`, mode `eligible`, reason `active` (it admitted after the restart, which 1.8.238 could not do), CB self-check `granted` 8 slots, startup probe 80.5 tok/s; `canary_smoke --probe` recorded binary 1.8.240, exact compatibility set, coordinator connected, CB active, paged KV attached, self-check grant, plus a gateway proof.
- **Carry-forward CF-242-E2E (1.8.242, candidate `27ae5dc84`, run 38702366766):** carry forward the pre-merge Studio e2e of the decode-path changes this cut ships, plus CF-240-E2E for everything else. Decode-path lines changed since 1.8.240 and their evidence: #1974 (CB decode and verify rows bounded below the device vector limit; Studio M3 Ultra throughput and isolation evidence in the PR), #1953 (hybrid decode lockstep window 16; Studio M3 Ultra window-1 vs window-16 proof in `docs/research/hybrid-decode-window/`), #1960 (self-check ladder bounded by the queue limit; unit tests), #1966 and #1964 (serial decode stops before hidden post-stop tokens; buyer stop strings stay outside hidden Harmony channels; unit tests). Live on the exact signed candidate, 2026-10-15: signed-tarball swap of an M5 32GB house provider (Llama 3.2 3B), which rejoined buyer-serving; `canary_smoke --probe` recorded binary 1.8.242, exact compatibility set, coordinator connected, paged KV attached, CB policy `live_verified` with local proof passed and no emergency-off, self-check measured `single_row` (the same result this Mac measured on 1.8.240), plus a gateway proof attributed to the canary through the coordinator request log on the serial path. The Studio was unreachable for this cut, so its CB grant on 1.8.242 is read from the fleet after promotion. Privacy code identity admitted from the signed release metadata.
- **Carry-forward CF-248-E2E (1.8.248, candidate `ea2a0cbbf`, run 38873164595):** carry forward CF-242-E2E for unchanged paths plus the pre-merge evidence of every provider-side change in this cut: #1980 (stricter CB self-check exactness probe; Studio M3 Ultra validation on 2026-10-16: with the production decode row bound the probe grants `verified_k=16`, without it divergent rows are flagged at k=12 and the grant stops at 11), #1986 (cross-provider scoring; real-chip threshold validation on M5, M1 and M3 Ultra, same-chip and cross-chip honest outputs 100% inside the cold prior and above the hard floors, 3-bit/2-bit substitutes detected, zero drift under concurrent load), #2020 (tool selection), #2022 (image input), #2024 (code-bound posture key and Malibu.app attestor), #2025 (fleet KV persistence) and #2026 (provider-local Responses API): each merged with its tests, three-lane audit and green CI. Live on the exact signed candidate, 2026-10-16: signed-tarball swap of the Studio provider (M3 Ultra, macOS 27, Qwen3.6-35B-A3B) at 09:21Z; on startup the #1980 probe re-measured every width 2..16 conformant and kept the 8-slot grant (`verified_k=16`); `canary_smoke --probe` recorded binary 1.8.248, exact compatibility set, coordinator connected, CB active, paged KV attached, self-check granted 8 slots, plus a gateway proof. Privacy code identity admitted from the signed release metadata.
- **Carry-forward CF-274-E2E (1.8.274, candidate `f8b6856e5`, run 40304491363):** carry forward CF-272-E2E for unchanged kernels, runtime pins (mlx-swift-lm `c8be0f61`) and the release metallib `3d9b4a74…` (byte-identical in the 1.8.274 tarball, so every signed CB policy entry still matches), plus the pre-merge evidence of each provider-side change: #2167 (prompt segment encoding and token-ID output structure, SPEC-018-R009; 643-test Studio Swift run including Metal and real-tokenizer suites, three-lane audit at the 3-round cap, hosted CI green), #2145 (GLM CB prompt snapshots with exact cold/warm parity, Studio GPU parity, three-lane audit 0/0/0), #2165 (managed coding-agent privacy envelope; its coordinator half shipped in Pearl runtime v1.8.275, which this canary requires) and the Malibu app changes in the rows above. The exact signed candidate passed signed-byte verification on 2026-10-26 (checksums `24083588…`; CLI SHA-256 `e677067e…`, CDHash `7df4dfb2…`). The first guarded `scripts/ops/canary-swap.sh` swap rolled back: after model load the candidate's privacy key records named three endpoint families that coordinator v1.8.273 rejected (`unrecognized auth message`), and the provider's auth watchdog exited after three rejections. After Pearl runtime v1.8.275 went live, the second swap passed on the Studio (M3 Ultra, GLM-5.3-Flash, CB live): model loaded in 454 s, buyer-serving at 13:08:44Z, 120 s crash hold passed. `canary_smoke --probe` recorded the exact candidate compatibility identity, coordinator connected, policy `live_verified`, local proof passed, paged KV attached, CB self-check granted, and a provider-attributed paid GLM-5.3-Flash gateway proof with CB active. The embedded decode-path digest moves to `0b9ffe09…`; the native-MTP admission set is rebound identity-only by #2170 (operator ruling; no R015 rerun). No new qualification or benchmark is asserted by this carry-forward.
- **Carry-forward CF-272-E2E (1.8.272, candidate `28c062427`, run 40146768804):** carry forward CF-270-E2E for unchanged kernels, runtime pins (mlx-swift-lm `c8be0f61`) and the release metallib `3d9b4a74…` (byte-identical in the 1.8.272 tarball, so every signed CB policy entry still matches and no CB rebind is needed), plus the pre-merge evidence of each provider-side change: #2137 (provider WebSocket receive limit 64 MiB, SPEC-001-R012; new Go frame-limit tests on coordinator, buyer, tier2 and gateway, Swift `CoordinatorWebSocketMessageLimitTests` in CI, three-lane audit in 3 rounds; coordinator half live in runtime v1.8.271) and #2138 (buyer cancel stops prompt prefill within one chunk, SPEC-001-R013; `PrefillCancellationTests` and Metal-gated `ConversationPromptSnapshotTests` in CI). #2140 (`28c062427`, coordinator-only) is the release source tip because it landed while the first 1.8.272 signer (run 40142899739, cut at `1dde22532`) was waiting, and that run refused on main drift; it changes no provider byte. The embedded decode-path digest moves to `4d04a3f3…` (#2138 touched `ModelRuntime.swift`), so the native-MTP admission set is rebound identity-only after the release (operator ruling; no R015 rerun). The exact signed candidate passed signed-byte verification on 2026-10-25 (checksums `601bd666…`; CLI SHA-256 `e1145988…`, CDHash `5c068c04…`). The guarded `scripts/ops/canary-swap.sh` swap put it on the Studio (M3 Ultra, DeepSeek V4-Flash, owner concurrency 1, CB off by design: no signed DeepSeek CB entry) with the Pearl buyer runner stopped for the whole window: restarted 01:37:55Z, model loaded in 303 s, buyer-serving at 01:43:10Z, 120 s crash hold passed; installed binary SHA-256 and CDHash equal the signed candidate. After zero in-flight, `canary_smoke --probe` recorded at 01:46:05Z: exact candidate compatibility identity, coordinator connected, policy `live_verified`, local proof passed, paged KV attached, `cb_serial_no_policy_entry`, and a provider-attributed paid DeepSeek V4-Flash gateway proof. No new qualification or benchmark is asserted by this carry-forward.
- **Carry-forward CF-270-E2E (1.8.270, candidate `48cf25db2`, run 40104446783):** carry forward CF-262-E2E for unchanged kernels and the release metallib `3d9b4a74…` (byte-identical in the 1.8.270 tarball, so every signed CB policy entry still matches), plus the pre-merge evidence of each provider-side change: #2129 (autotune readiness for large candidates and signed candidate aliases; 360 targeted Studio Swift tests, spec governance), #2130 (`none`/`minimal` reasoning effort renders as `low`; 217-test Studio CPU suite, three-lane audit 0/0/0), #2131 (grammar-constrained `tool_choice` required/named and strict `json_schema` for every catalog grammar; Grammar/parser/CB/ToolSelection/BuyerUX/StructuredOutput/DeepseekV4 suites, release build digest match, three-lane audit at the 3-round cap with its one round-3 MEDIUM fixed and regression-tested), #2133 (reasoning round trip on all buyer surfaces, keepalives, prompt-sized first token; gateway/coordinator suites, race tests, three-lane audit), #2134 (DeepSeek V4 CB backend, off without a signed entry, and extend-only prompt snapshots; Studio M3 Ultra two-turn warm/cold parity on DeepSeek V4-Flash serial and GLM-5.3-Flash, three-lane audit 0/0/0 with 2 LOWs carried) and `afd62110e` (test-only clock pin). The runtime pin moves to mlx-swift-lm fork `c8be0f61` (`3.32.3-macprovider.10.5`); the embedded decode-path digest is `6471812e…`, so the native-MTP admission set is rebound identity-only after the release (operator ruling; no R015 rerun). The exact signed candidate passed signed-byte verification on 2026-10-24 (checksums `e4817ce9…`; CLI SHA-256 `9ba7eb5d…`, CDHash `e36d108f…`). The guarded `scripts/ops/canary-swap.sh` swap put it on the Studio (M3 Ultra, DeepSeek V4-Flash `TensorFold/DeepSeek-V4-Flash-0731-MXFP4-MLX`, owner concurrency 1, CB off by design: no signed DeepSeek CB entry); buyer-serving at 16:18:33Z, 120 s crash hold passed. `canary_smoke --probe` recorded at 16:23:02Z: exact candidate compatibility identity, coordinator connected, policy `live_verified`, local proof passed, paged KV attached, `cb_serial_no_policy_entry` (#2135), and a provider-attributed paid DeepSeek V4-Flash gateway proof (HTTP 200, `requests_total` +1, serial). No new qualification or benchmark is asserted by this carry-forward.
- **Carry-forward CF-262-E2E (1.8.262, candidate `92e39cf5f`, run 39927039135):** carry forward CF-261-E2E for unchanged kernels and the release metallib `3d9b4a74…`, plus the pre-merge evidence of each provider-side change. The runtime pin moves to mlx-swift-lm `baec1724` (tag `3.32.3-macprovider.10.3`), which adds the `deepseek_v4` model and pool cache and makes a value-identical `GLM5Next` constructor refactor. #2109, #2116, #2117 and #2118 (buyer API compatibility: template-driven tool rendering, per-grammar tool-call parsers, reasoning split, capability routing). They carry their three-lane audits; a post-merge Codex re-audit of #2109/#2116 confirmed 8 MEDIUM findings and #2118 fixed them, with its own audit at 0/0/0. #2115 (`glm5_next` 2048-token CB prompt chunks). #2108 (shard groups; fake-Pearl VM acceptance 61 PASS / 0 FAIL / 1 GAP, freeze audit closed at the round cap). #2112 (DeepSeek V4 serving, DSV4 prompt encoder, DSML tool calls and reasoning: freeze audit round 2 at 0/0/0 in all three lanes; the Studio loopback buyer-UX conformance passed twice, the second time on the final build `4912b2b63` on 2026-10-23, with `messages_beta_thinking` deferred to the gateway; GLM-5.3-Flash R015 v3.1 PASS on that build, informational for the identity-only rebind). The exact signed candidate passed signed-byte verification on 2026-10-23. The first guarded `scripts/ops/canary-swap.sh` canary, at 09:59Z, rolled back automatically: the candidate bakes the catalog release `published-2026-10-23-deepseek-v4-flash-listed-v1`, which was not yet live (`rate_card_update_required`). That release was activated through `scripts/ops/catalog-activate.sh` after #2119 added its pricing acknowledgement. The second canary restarted on 1.8.262 at 13:10:14Z, loaded GLM-5.3-Flash in 460 s, became buyer-serving at 13:18:07Z and passed its 120 s crash hold. The installed binary SHA-256 `58745fcd…` matches the signed candidate; CDHash `68c393b4…`. `canary_smoke --probe` recorded: exact candidate compatibility identity, coordinator connected, CB active, paged KV attached, policy `live_verified`, local proof passed, self-check granted 4 slots on metallib `3d9b4a74…`, and a provider-attributed GLM-5.3-Flash gateway proof. The proof accepts `reasoning_content` since `87921a3f8`, because with #2109's reasoning split a 32-token GLM proof is all reasoning. The embedded decode-path digest is `565617…`; the native-MTP admission rebind to this release follows it. No new qualification or benchmark is asserted by this carry-forward.
- **Carry-forward CF-261-E2E (1.8.261, candidate `90b1a3b72`, run 39724400285):** carry forward CF-260-E2E for unchanged kernels, runtime pins (mlx-swift-lm `87dc5159`, release metallib `3d9b4a74…`) and GLM serving paths, plus the pre-merge evidence of each provider-side change: #2095 (Qwen automatic tool use: both exact Qwen models PASS real OpenCode automatic read/continuation and tool-free direct answer on a Studio-isolated lab binary; 92 targeted Swift tests, 835 Malibu tests, router Go tests, 388 Metal kernels, CI), #2096 (Qwen3.6 native/ordinary ragged prefill grouping and pinned text preparation: twelve focused Studio tests without skips, the six-cell R015 matrix on the current pin and a 1,812 s sustained window with zero errors/fallbacks/parity mismatches, 194 executed local journey checks, unchanged challenge-bank entry; the s2 TTFT result is the SPEC-048 0.1.50 disposition, not a PASS), #2106 (native-MTP admission bound to the compiled-in decode-path digest; 1062 targeted Studio Swift tests, Go ws/buyer, 2450 Python tests, 803 ops entrypoint tests, three-lane freeze audit 0/0/0, CI), #2098 (download cancellation stays final; targeted tests, CI) and #2099 (dense CB qualification on the uncompiled serving decode; regression tests, CI). The ragged-join capability added by #2096 is limited to the `qwen3_5_mtp_v1` family, so GLM (`glm5_next_mtp_v1`) keeps its equal-offset rule; #2106's move into `ServeDecodePath.swift` is behaviour-preserving. The exact signed candidate passed signed-byte verification on 2026-10-22; its embedded decode-path digest is `4be59bfa…`. The guarded `scripts/ops/canary-swap.sh` canary (buyer runner already stopped by the operator) restarted on 1.8.261 at 05:51:40Z, loaded GLM-5.3-Flash in 824 s, became buyer-serving at 06:05:36Z and passed its 120 s crash hold. Installed binary SHA-256 `48c39900…` and CDHash `6d22d656…` match the signed candidate. `canary_smoke --probe` recorded at 06:09:36Z: exact candidate compatibility identity, coordinator connected, CB active, paged KV attached, policy `live_verified`, local proof passed, self-check granted 4 slots on metallib `3d9b4a74…`, and a provider-attributed GLM-5.3-Flash gateway proof. Native MTP reports `eligible` on the canary under the legacy GLM entry; the two-model decode-path admission follows the release. No new qualification or benchmark is asserted by this carry-forward.
- **Carry-forward CF-260-E2E (1.8.260, candidate `13c6b1854`, run 39391287240):** carry forward CF-258-E2E for unchanged decode kernels, runtime pins and serving paths, plus the pre-merge evidence of each provider-side change: #2074 (Malibu catalog/discovery/download and Connected apps; 812 app tests, 390 CLI tests, catalog-economics decode and download/cancel checks), #2077 (expired prepared-update handoff recovery; targeted watchdog regressions and CI), #2079 (startup queue-limit clamp; 216 Studio CPU tests and CI), and #2085 (Provider KV/restart status, live Settings preferences and warm-swap KV support refresh; 822 Malibu tests with one pre-existing skip, 110 targeted CLI tests and CI). The changes carry their merged audit records; Qwen automatic-tool acceptance is not claimed. The exact signed candidate passed signed-byte verification at 09:19:48Z on 2026-10-20. The guarded `scripts/ops/canary-swap.sh` canary restarted at 09:23:16Z, became buyer-serving at 09:36:06Z after the GLM load, and passed its crash hold. Installed binary SHA-256 `98091568…` and CDHash `65a7d6cd…` match the signed candidate. `canary_smoke --probe` recorded at 09:39:55Z: exact candidate compatibility identity, coordinator connected, CB active, paged KV attached, policy `live_verified`, local proof passed, self-check granted 4 slots on metallib `3d9b4a74…`, and a provider-attributed GLM-5.3-Flash gateway proof. The GLM native-MTP admission is rebound to this release separately; no new model qualification or benchmark is asserted by this carry-forward.
- **Carry-forward CF-258-E2E (1.8.258, candidate `398002c10`, run 39295344398):** carry forward CF-257-E2E for unchanged paths plus the pre-merge evidence of the one provider-side change: #2070 (gateway auto-prefix requests stay native-MTP eligible under a fleet-cache grant; v1/v2 projection manifests; serial-fallback cache lease; release-build Studio e2e on GLM-5.3-Flash with the signed metallib: plain text runs native MTP (`mtp_forwards` +140 and +133) token-identical to ordinary decode at temperature 0, tools stay ordinary, the pre-fix keyed state traces `ordinary reason=conversation_key`, four concurrent 1400-token rows complete, `docs/evidence/glm53-flash-mtp-gateway-eligibility-2026-10-19/`). Live on the exact signed candidate, 2026-10-19: guarded `scripts/ops/canary-swap.sh` swap of the Studio provider (M3 Ultra, macOS 27, GLM-5.3-Flash) with `CANARY_STATUS_TIMEOUT_S=900`: pre-swap kernel check passed both metallibs (388 kernels); restarted on 1.8.258 at 18:51:11Z, buyer_serving at 19:04:07Z (GLM load ~13 min), 120 s crash hold passed, watchdog restarted; installed binary sha256 `5397f870…` and CDHash `238a3f76…` equal the signed candidate; the CB self-check granted 4 slots on metallib `3d9b4a74…`, paged KV attached, policy `live_verified`; `canary_smoke --probe` recorded at 19:07:33Z with a GLM-5.3-Flash gateway proof (`PROBE_MODEL=zai-org/glm-5.3-flash`, buyer runner stopped around the probe). Native MTP reports `eligible` on the canary; the GLM admission is rebound to this release after promotion.
- **Carry-forward CF-257-E2E (1.8.257, candidate `10379e158`, run 39228227700):** carry forward CF-256-E2E for unchanged paths plus the pre-merge evidence of each provider-side change: #2059 (Malibu app redesign Phase 2; 735 app tests, 261 targeted Swift tests on a Studio lab clone, CI), #2062 (CB self-check progress under sustained traffic; all 28 CI jobs on the reviewed head, three-lane audit), #2063 (GLM-5.3-Flash native-MTP serial prefill cohorts; R015 v2 PASS on the Studio, `docs/research/spec048-r015/glm53-flash-r015-v2/`), #2064 (signed CB `max_served_slots` ceiling; unit tests, CI; absent field = unchanged behaviour), #2065 (local Chat, Connected apps, buyer-safe ownership routing; adversarial verification 0/0/0, CI), #2066 (CB no-progress guard counts streamed window tokens; release-build Studio e2e on GLM-5.3-Flash with the signed metallib: 4 concurrent 1.1k-3.3k-token prompts to 4096 tokens, 2048 non-stream and stream, all complete, while 1.8.256 fails the 2048-token request after 64 windows, `docs/evidence/cb-streamed-window-progress-2026-10-19/`). Live on the exact signed candidate, 2026-10-19: guarded `scripts/ops/canary-swap.sh` swap of the Studio provider (M3 Ultra, macOS 27, GLM-5.3-Flash): pre-swap kernel check passed both metallibs (388 kernels); buyer_serving on 1.8.257 at 11:05:17Z, 120 s crash hold passed, watchdog restarted; the CB self-check re-measured and granted 4 slots (`verified_k=16`, owner pin 4), paged KV attached; `canary_smoke --probe` recorded with a GLM-5.3-Flash gateway proof (`PROBE_MODEL=zai-org/glm-5.3-flash`). GLM-5.3-Flash native MTP stays off until its admission binds this release. Two earlier swap attempts were refused or rolled back before serving: the provider's lifecycle record was wedged at `failed` and refused the pause (#2067; cleared by one restart), and the default 120 s `/v1/status` silence limit fired during the ~6.5 min GLM load (the swap passed with `CANARY_STATUS_TIMEOUT_S=900`).
- **Carry-forward CF-256-E2E (1.8.256, candidate `2a575c453`, run 39103916777):** carry forward CF-251-E2E for unchanged paths plus the pre-merge evidence of each provider-side change: #2046 (guaranteed tool selection prefill; Studio lab real-model acceptance 6/6, stream and non-stream, CB on and off), #2048 (watchdog never kicks a paused or resuming provider; watchdog test suites, CI), #2047 (GLM-5.3-Flash native engine; campaign Studio e2e: T4 CB self-check, native-MTP serve-path e2e and journey passed), #2049 (Malibu.app version stamp and self-relaunch; 680 app tests), #2050 (native-MTP bank with the release and re-offer; CI incl. -race), #2051 (truthful dashboard Phase 1; 693 app tests, coordinator suites), #2052 (release metallib carries all 388 kernels the pinned MLX core loads; gated). Live on the exact signed candidate, 2026-10-18: Pearl runtime v1.8.255 first; guarded `scripts/ops/canary-swap.sh` swap of the Studio provider (M3 Ultra, macOS 27, Qwen3.6-35B-A3B): pre-swap kernel check passed both metallibs; buyer_serving on 1.8.256 at 08:24:46Z, 120 s crash hold passed, watchdog restarted; native MTP admitted (re-offer); the CB self-check re-measured on the new runtime-build key and granted 8 slots (`verified_k=16`) at 08:30Z; `canary_smoke --probe` recorded. The 1.8.254 candidate (partial SwiftPM metallib, `gather_mm_offsets` missing) and the first 1.8.256 swap attempt (old watchdog kicked the loading candidate; fixed in #2053) were never tagged.
- **Carry-forward CF-251-E2E (1.8.251, candidate `7c98b6f6d`, run 39015861218):** carry forward CF-250-E2E for unchanged paths plus the pre-merge evidence of each provider-side change: #2034 (artifact-hash chunk lifetime; peak footprint 2.1x to 1.01x of tensor bytes on the Studio; CI), #2037 and #2039 (release discovery via the coordinator-advertised release, signature-verified; served installer never executed; streaming size caps; 199/199 installer tests, 667 Malibu app tests, CI), #2038 (guaranteed tool selection accepts the Qwen3.6 template's function-XML; 112 tool-selection tests on the Studio lab clone; audit 0/0/0; CI), #2035 and #2041 (Qwen2-VL native image input; Studio lab acceptance on the pinned `3.32.3-macprovider.9.4` build: 29/29 provider-local and 29/29 isolated-stack cases including two-image ordering, text-only rejection, warm-swap replacement, disconnect recovery; Qwen3.6 greedy output byte-identical to 1.8.250), #2040 and #2043 (KV disk tier coexists with the privacy class; private requests write nothing request-derived to disk; 682 + 469 targeted Swift tests; CI). Live on the exact signed candidate, 2026-10-17: Pearl runtime v1.8.252 and catalog `published-2026-10-17-qwen2vl-recommendable-v1` activated first (content lane, evidence (a)-(d) passed, (e) owed for Qwen2-VL); signed-tarball swap of the Studio provider (M3 Ultra, macOS 27, Qwen3.6-35B-A3B) at 13:10Z, buyer_serving again at 13:11:38Z; the CB self-check re-measured on the new runtime-build key (`ce3bb523`) and granted 8 slots (`verified_k=16`) at 13:18Z; native MTP admitted (`enabled=true`); KV disk tier `activated` with no privacy hardening failure; `canary_smoke --probe` recorded binary 1.8.251, exact compatibility set, coordinator connected, CB active, plus a gateway proof.
- **Carry-forward CF-250-E2E (1.8.250, candidate `3c4dde673`, run 38973364754):** carry forward CF-248-E2E for unchanged paths plus the pre-merge evidence of each provider-side change: #2030 (tool selection on the catalog identity of an alias-configured model; unit tests, audit, CI), #2032 (hybrid KV persistence; Studio M3 Ultra acceptance 2026-10-16 on the PR build: 14/14, codec-v2 writes committed, cold restore after restart, identical continuations, cold-restore TTFT 750 vs 3523 ms, entries ~249 MiB, storage bounded) and #2033 (MLX core fork v0.32.2-macprovider.5 keeps internal ops on the caller's stream; Studio T1-02 gpt-oss-20b decode 125.37 vs 125.77 tok/s on 1.8.232; isolation probes pass). Live on the exact signed candidate, 2026-10-16: signed-tarball swap of the Studio provider (M3 Ultra, macOS 27, Qwen3.6-35B-A3B) at 23:19Z, buyer_serving again at 23:21Z; the CB self-check re-measured on the new runtime-build key and granted 8 slots (`verified_k=16`); `canary_smoke --probe` recorded binary 1.8.250, exact compatibility set, coordinator connected, CB active, paged KV attached, plus a gateway proof. Privacy code identity admitted from the signed release metadata.

## Promotion gate (checklist)

1. All in-scope CLI rows above are `merged`.
2. Activate `main`'s catalog release on Pearl first
   (`scripts/ops/catalog-activate.sh`), then cut one candidate off `main`
   (`acceptance-candidate.yml`). The candidate bakes `main`'s catalog release,
   and a canary on a catalog Pearl does not serve fails to join with
   `rate_card_update_required` (1.8.262). `cli-release.sh` keeps
   `candidate_cut` blocked, with NEXT `scripts/ops/catalog-activate.sh status`,
   until Pearl's `/v1/autotune-release` reports the committed `release_id`.
   Do **not** reuse `v1.8.163` / `v1.8.164` / `v1.8.167` / `v1.8.168`.
3. In-scope e2e green on that candidate, or an explicit carry-forward record
   under the rule above. For 1.8.217, the fused A3B MoE ordinary path (#1832)
   is in scope with its Studio qualification at `7d55924eb`; native MTP
   remains default-off and out of scope. Earlier signed
   candidate evidence may carry forward only where the table and track record
   explicitly permit it.
4. Privacy code identity registered on Pearl before any canary or fleet
   provider runs the candidate: `scripts/ops/cli-release.sh` step
   `privacy_release_identity` copies the verified candidate
   `pearl-release.json` + `.sig` into Pearl's
   `privacy_class.release_code_identities.metadata_dir` as `v<ver>.json`
   (hot, no restart). While Pearl has no `metadata_dir`, step
   `privacy_release_setup` comes first and `next --run` performs the one-time
   setup (`docs/runbooks/privacy-class-beta-operations.md` "One-time setup")
   with one coordinator restart, staging the identity right after. CLI 1.8.230 shipped without this and
   every upgraded provider's privacy advertisement was refused for ~12 h.
5. Exact signed-candidate install/join smoke. Swap the candidate onto the
   canary only with `MACPROVIDER_OPS_OWNER=<label> scripts/ops/canary-swap.sh
   swap --version <ver>`: it refuses a candidate whose `mlx.metallib` or
   bundled `default.metallib` lacks a kernel the pinned MLX core loads by name
   (the 1.8.254 candidate shipped without `gather_mm_offsets` and could not
   load MoE models), or whose baked `catalog-release/` (`release_id`,
   `release.json` and `rate-card.json` `generated_at`) differs from what Pearl
   serves at `COORDINATOR_URL`, and after the restart it restores the backup and
   resumes the previous version on a provider restart or exit (crash loop,
   detected at once) or on a `/v1/status` silence of 120 s
   (`CANARY_STATUS_TIMEOUT_S`) after the candidate reported its model loaded.
   Silence while the model loads is not a failure: GLM-5.3-Flash keeps
   `/v1/status` silent for 7-13 minutes while it loads, so with the same
   provider pid alive the load is bounded only by `CANARY_READY_TIMEOUT_S`
   (1800 s). No timeout override is needed. Verify the installed CLI advertises
   1.8.217, joins through Pearl's exact compatibility set, preserves operator
   pause through coordinator drain, and serves a bounded request. Do not touch
   the designated Studio until the operator releases its current session lock.
   The canary probe also fails when Pearl's coordinator journal shows its
   privacy advertisement rejected as `posture_unapproved_code_identity` in
   the last 10 minutes, or when the running coordinator does not positively
   hold the candidate's registrations (item 6).
6. Registrations gate (`registrations`, read-only over `PEARL_SSH`), checked
   on every status, also after publication, so it gates promotion, the
   recommendation bump and rollout verification. It passes only when the
   RUNNING coordinator holds every registration: the candidate
   `compatibility_set_id` is admitted by the live policy (SPEC-002-R004:
   well-formed, from the `target_id` repository, not in `revoked_ids`;
   `/healthz` must equal the applied config) and the on-disk config's
   sha256 equals the running process's boot `coordinator_config_applied`
   digests (restart-only fields), `privacy_class.enabled` is true, and the
   candidate `code_cdhash` is approved either by a `v<ver>.json` that
   verifies and that the coordinator reports as loaded
   (`relayblind_privacy_release_identity_loaded`), or by an unexpired
   `approved_code_identities` entry in that applied config. Unknown fails
   closed, including an unknown candidate `compatibility_set_id` (from fresh
   ops state it is derived only from the trusted-signer `v<ver>` tag); the
   refusal names the missing item. The promotion dispatch runs
   `_check-registrations` against Pearl immediately before
   `gh workflow run`. `promote-acceptance-candidate.yml` cannot reach Pearl,
   so it does not re-check registrations itself: approve its
   production-release deployment only from `cli-release.sh` (the approval
   step is shown only while `status` still passes this gate).
7. Signed release tag (`release_tag`): `promote-acceptance-candidate.yml`
   runs `scripts/verify-release-tag-target.sh "$TAG" "$CANDIDATE_SHA" origin
   --require-existing`, so `v<ver>` must already be an annotated tag on the
   candidate SHA. `cli-release.sh next --run` creates it with the operator's
   git signing key (`git tag -s -a v<ver> -m "macprovider-cli <ver>"
   <candidate_sha>`), checks it with `git verify-tag`, pushes it and confirms
   origin's target. An existing `v<ver>` counts only when it is annotated,
   peels to the candidate, and its exact remote tag object is signed by an
   explicitly approved signer: an SSH signature verified only against
   `MACPROVIDER_RELEASE_TAG_ALLOWED_SIGNERS` (default
   `~/.config/macprovider/release-tag-allowed-signers`, never the checkout's
   git config), or an OpenPGP signature whose `VALIDSIG` fingerprint is in
   `MACPROVIDER_RELEASE_TAG_GPG_FINGERPRINTS`. An unsigned or unapproved tag,
   a tag on another commit, or a lightweight tag is refused. Promotion of 1.8.224, 1.8.230 and 1.8.232 failed
   until this tag was made by hand.
8. Physical acceptance (`promote-acceptance-candidate.yml`) publishes the exact
   versioned bytes and moves the fleet; it does not rewrite `binaryVersion`.
9. `verify-live-coordinator-release-rollout` before publishing discovery.
   `cli-release.sh` runs `_check-privacy-rejections` before the dispatch: it
   samples `relayblind_privacy_posture_rejections_total{reason="posture_unapproved_code_identity"}`
   twice, `PRIVACY_REJECTION_WINDOW_SECONDS` (default 180) apart, within one
   coordinator invocation, and refuses on any new rejection. When the
   coordinator restarted in between (the counter resets) or the metric is not
   served, it counts the unit journal's rejection lines across the window. The lifetime count is only reported, so historical rejections
   never block; a provider that keeps being rejected does, until its identity
   is registered or denied.
10. Byte-identity check: `docs/runbooks/provider-cli-release-verification.md`.
11. Curl-channel `https://get.malibu.tech/install.sh`:
   - **On promotion:** republish from the promoted tag (or confirm served
     bytes still match that tag) so `scripts/check-install-sh-parity.sh`
     against the tag is green. Confirm
     `scripts/check-install-sh-consumer-health.sh` is green (#1600 / #1588).
   - **Off-cycle from `main`:** allowed when the public one-liner must
     change before the next CLI promotion (fresh-Mac CLT wall, pagination).
     Record date + SHA-256 in this file. Expect the parity alarm vs the
     current stable tag to go red until a successor stable includes the
     same `install.sh`. Do not skip consumer-health after a main publish.

## Session protocol

- **Lab campaigns** (Studio / real-Mac e2e): do **not** cut a candidate because
  a CLI-row PR merged. Iterate on a draft campaign PR with a local
  `swift build -c release` on the box. Cut **one** candidate after that
  campaign lands, or when the operator asks. Runbook:
  `docs/runbooks/lab-campaign-loop.md`.
- Update this file when a CLI change merges, a candidate is cut, or an e2e
  track runs. If the update is **only** this file (or other docs), push
  direct to `origin/main` — no PR, do not wait for CI. If it rides with a
  code change, put it in that PR. A merged CLI row is not by itself a cut
  trigger.
- Republish `get.malibu.tech/install.sh` from `main` or from a tag → update
  this file the same day (date, SHA-256, whether parity vs current stable is
  expected red).
- Live-coordinator candidate test: no Pearl admission edit. Since
  SPEC-002-R004 the coordinator admits every well-formed release identity
  from the `target_id` repository; step `pearl_accepted_ids` only checks that
  the running policy admits the candidate. `accepted_ids` is deprecated and
  ignored. To keep a bad build off buyer traffic, add its exact identity to
  `compatibility_set.revoked_ids` (SIGHUP-reloadable): it reconnects
  update-only and still receives the recommendation. A foreign-repository or
  malformed set is closed 4001 with its code, and a v2 CLI reports that code
  instead of `Expected auth_challenge v2`.
- Every new CLI version needs two Pearl registrations, not one: the
  compatibility set above and the privacy code identity. Stage the identity
  with `scripts/ops/cli-release.sh next --run` at step
  `privacy_release_identity`; never hand-edit `approved_code_identities` for a
  signed release. `cli-release.sh status` reports the live state as facts
  `privacy_release_metadata_dir` and `privacy_release_identity`.
- Never hand-make the `v<ver>` release tag: `cli-release.sh` step
  `release_tag` signs, verifies and pushes it on the verified candidate SHA.
  It needs the operator's git signing key configured (`user.signingkey`, and
  `gpg.format ssh` for an SSH key) in the checkout that runs the step.
- Pearl coordinator/gateway runtime: **one cut of current `main`**. Do not
  dual-dispatch `pearl-runtime-release.yml` from two sessions. Record owner +
  payload + live tag in the Pearl paragraph above before/after apply.
