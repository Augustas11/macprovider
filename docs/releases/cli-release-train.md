# CLI Release Train — control surface

**This file is the single source of truth for provider CLI releases.** Work happens
across many sessions and agents; before cutting, testing, or promoting a CLI
build, read this file, and after any release-affecting action update it in the
same commit/PR. If reality and this file disagree, fix this file.

## How to track the next CLI

This table is the net change vs fleet **1.8.123**.

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

- **Candidate tags do NOT bump `binaryVersion`.** Every acceptance candidate
  (v1.8.124 … v1.8.16x) was cut with the source
  `binaryVersion` constant unchanged (it is `1.8.123` = the last promoted
  stable). The candidate's identity lives in its signed `compatibility_set_id`
  (`owner/repo:vX.Y.Z@<commit>`), not in `binaryVersion`.
- **The PROMOTED stable release is the only thing that bumps `binaryVersion`**,
  advances the coordinator `latest_binary_version` + `compatibility_set.target_id`,
  and triggers fleet autoupdate.
- Cut the promotable candidate off the **current `main` tip after all in-scope
  changes are merged** — never promote a candidate that predates a merged
  in-scope change.

Pearl runtime `v1.8.189` was consumed by the signed but unapplied #1715
settlement-finality cut. Its deploy failed closed before Pearl mutation; the
replacement Pearl runtime tag `v1.8.190` is reserved for #1715 + #1718. Neither
tag is a provider CLI candidate, and neither changes `binaryVersion` or the
fleet recommendation from 1.8.123.

## Current promoted stable

| Field | Value |
|---|---|
| Version | **1.8.123** |
| Compat-set id | `Augustas11/macprovider:v1.8.123@37e2d232389ba37d94f138b5a7d52a12c2b12106` |
| Coordinator `target_id` / `latest_binary_version` | `1.8.123` |

## Next CLI — net changes vs 1.8.123

Candidates through `v1.8.176` are old or off-train for promotion. The current
Studio serving canary is private candidate **181** at `32ea1bd0` (includes
#1687); its reported `binaryVersion` remains **1.8.123**. Candidate 181 is not
a public stable tag and must not be promoted to the fleet. Signed private
candidate **182** at `710255f4` includes #1692 and is staged, not installed;
the same source is the live coordinator/catalog `v1.8.182` release. Tags
`v1.8.183` through `v1.8.185` were consumed by the #1699/#1704 Pearl
money-path releases, so the next provider acceptance candidate is
**`v1.8.186`**. #1700 landed at `d0aa3556` on top of those fixes; cut the
candidate from that current-main lineage. Fleet recommendation stays at
**1.8.123**.


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
| Storage / Build 1 prep stays private until activation | merged | #1504 #1507 #1525 |
| SPEC-038 attach needs measured runtime evidence | merged | #1502 |
| SPEC-039 attach without sticky reattach | merged | #1475 |
| FR-PKV10 extract exists; serving still off | merged | #1476 |
| Paged KV sticky billing parity | merged | #1489 |
| Reward eligibility not claimed from the wrong state | merged | (Malibu rewards, `422fc2f1`) |
| Buyer prompt/content not leaked on relays | merged | #1467 |
| Pricing metadata only from validated endpoints | merged | #1455 |
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
| Provider WebSocket relay admission follows advertised seats and warm swaps | merged | #1687 |
| Refresh embedded Tier-2 identity/catalog bindings for the current model set | merged | #1692 |
| Disable optional template thinking for final-answer mode by loaded-artifact capability | merged | #1700 |
| Running provider refreshes its signed catalog envelope on `catalog_incompatible` or a newer hello ack and adopts it only for the same served row identity (no Malibu restart after a content cut). Compatibility-set rejections keep their own reason. Malibu/CLI status says "Catalog refresh needed", not "software update required" | merged `3abf42a8` | #1714 (#1705) |

#1453 closes when a candidate that includes the **merged** rows is promoted to
the fleet. #1569 is a later CLI. Spec promotion #1583 is not a CLI change.

Coordinator/gateway on live Pearl is **v1.8.182** @ `710255f4`, including the
signed Tier-2 identity/catalog update from #1692. Fleet Macs and the coordinator
recommendation remain on provider binary **1.8.123**. The Studio serves private
candidate 181 at `32ea1bd0`; a newer candidate is staged but not installed.
Do not promote the fleet from this campaign.

#1632 / #1638 / #1639 / #1653 (coordinator leftover rewrite + gateway R014)
are coordinator/gateway, not CLI rows. #1653 also has the CLI
`InferenceRelay` drop; that CLI change is in `v1.8.174`.

#1600 is the install.sh consumer-health alarm
(scripts/CI), not the Mac binary. Curl-channel `get.malibu.tech/install.sh`
was republished **from `main`** on 2026-09-19 after #1610 (SHA-256
`c90fb44d9a780041233928f4376d7d92b71af087d034ae44c3a275fd9381d7c4`, pearl
backup `install.sh.bak-20260919T121720Z`) so `curl | bash` already has #1582
pagination and the #1575/#1610 CLT-stub bootstrap. Consumer health is green
against fleet **v1.8.123**. The parity alarm still compares served bytes to
the latest **stable tag** (v1.8.123) and stays red until this CLI is promoted
and the tag's `install.sh` matches served (re-publish from that tag, or
confirm bytes are unchanged).

### Precondition for any candidate cut after #1672

`v1.8.176` predates #1672 and is unaffected. Any candidate cut from `main` at
`b61f081c` or later enforces SPEC-038 FR-CB10 per-tuple acceptance coverage
**fail-closed**: descriptor membership alone no longer permits batching, and a
provider will not batch until its operator declares the exact tuple in
`continuous_batching_accepted_tuples`.

On such a candidate a provider left as-is serial-routes with reason
`tuple_acceptance_coverage_unavailable`; strict `continuous_batching: on`
fails at startup rather than serving unbatched. Declare the tuple on the
Studio canary **before** deploying such a candidate, or CB there goes serial
with no other symptom:

```yaml
continuous_batching_accepted_tuples:
  - model_id: <served model id>
    model_sha256: <64-char lowercase hex, must equal the runtime value exactly>
    cache_class: <runtime cache class>
    kv_dtype: bf16
    requires_moe: true
    hardware_class: <hardware class>
```

Config load rejects a whitespace-padded field or a non-canonical SHA, so a
declaration that could never have matched fails at startup instead of loading
and silently never matching.

## Active candidate

| Field | Value |
|---|---|
| Last built candidate | Signed private candidate **182** @ `710255f4`, [run 35819108150](https://github.com/Augustas11/macprovider/actions/runs/35819108150). It includes #1692, reports `binaryVersion` 1.8.123, and is staged but not installed. |
| Mac Studio serving canary | Private candidate **181** @ `32ea1bd0` — live and coordinator-connected. A newer candidate is staged but not installed. |
| Off-train E2E candidate | `v1.8.167` @ `7f833a2f63ddee6b2e146c821341099d89aec169` ([run 35417249468](https://github.com/Augustas11/macprovider/actions/runs/35417249468)) — signed hold-branch CLI used for the 2026-09-19 Pearl Track B run |
| Older | `v1.8.163` @ `8c0c51d2`; `v1.8.164` BYOM @ `cdbb0257`; CLI artifact `v1.8.166` @ `00ce3625` (not the Pearl runtime tag); CLI `v1.8.172` @ `c512d342`; CLI `v1.8.174` @ `0c276ebb`; CLI `v1.8.175` @ `d02798db` |
| Status | **Do not promote.** Fleet and coordinator recommendation stay on 1.8.123. Candidate 181 remains the serving canary until a reviewed, signed successor passes the hardware campaign. |
| Next candidate | **v1.8.186, not cut.** #1699, #1704, and #1700 are on `main`; cut from the current tip. Candidate identity must not bump `binaryVersion`; it stays 1.8.123. |
| Merged on `main`, not in serving 181 | #1692 (Tier-2 identity/catalog bindings; included in staged 182), #1700 (template-capability-driven no-thinking final answers), #1714 (in-process catalog envelope refresh + "Catalog refresh needed" status, #1705). |
| Why the next cut | Combine #1687, #1692, #1699, #1704, and #1700 so the same signed Studio candidate can prove answer quality, eight-seat buyer routing, and complete settlement. |

## E2E tracks (independent gates)

A release is promotable only when **every in-scope track is GREEN on the same
combined candidate**.

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
- **Status:** #1699, #1704, and #1700 are merged; #1700 passed required CI,
  three-lane freeze audit, and local hardware proof. Cut signed candidate
  **v1.8.186** and run the full live gate. Keep fleet recommendation
  and `binaryVersion` at 1.8.123.

## Promotion gate (checklist)

1. All in-scope CLI rows above are `merged`.
2. Cut one candidate off `main` (`acceptance-candidate.yml`). Do **not** reuse
   `v1.8.163` / `v1.8.164` / `v1.8.167` / `v1.8.168`.
3. In-scope e2e green on **that** candidate (Track A this cut; Track B on the
   next candidate, which includes #1609, before promoting a BYOM-serve CLI;
   Track B is not #1453 close).
4. Live smoke on the candidate (not a substitute for Track A): Pi/Qwen3-Coder
   stream+tools concat is one JSON object (never `{}` / `{}{`); unclosed
   function-XML becomes a real `bash` tool call; 257+ messages are not rejected
   with `messages_too_long` on the CLI.
5. Physical acceptance (`promote-acceptance-candidate.yml`) — this is what
   bumps `binaryVersion` and moves the fleet.
6. `verify-live-coordinator-release-rollout` before publishing discovery.
7. Byte-identity check: `docs/runbooks/provider-cli-release-verification.md`.
8. Curl-channel `https://get.malibu.tech/install.sh`:
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
- Live-coordinator candidate test: add its `compatibility_set_id` to
  `accepted_ids` (keep `target_id`). The list is capped at 8 and must
  include `target_id`; drop the oldest unused set if at cap. Restart the
  coordinator (`s.cfg` is a value copy — SIGHUP does not reload
  compatibility_set). Keep the id while it is the Studio serving canary;
  revert after a throwaway test. An unaccepted set is closed 4001
  `compatibility_set_unaccepted`; the CLI reports that as
  `Expected auth_challenge v2`.
- Pearl coordinator/gateway runtime: **one cut of current `main`**. Do not
  dual-dispatch `pearl-runtime-release.yml` from two sessions. Record owner +
  payload + live tag in the Pearl paragraph above before/after apply.
