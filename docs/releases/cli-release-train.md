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

## Current promoted stable

| Field | Value |
|---|---|
| Version | **1.8.123** |
| Compat-set id | `Augustas11/macprovider:v1.8.123@37e2d232389ba37d94f138b5a7d52a12c2b12106` |
| Coordinator `target_id` / `latest_binary_version` | `1.8.123` |

## Next CLI — net changes vs 1.8.123

All in-scope CLI rows are **merged**. Last built candidates `v1.8.163`,
`v1.8.164`, `v1.8.167`, `v1.8.168`, `v1.8.171`, and `v1.8.172` are old or
off-train for promotion — do not promote them. Studio serving canary is
**`v1.8.174`** @ `0c276ebb95ee672084a61ac1f9030f7de301ff36` (includes #1653
and #1656), live as `live.malibu.provider` on Mac Studio. `v1.8.173` is the
Pearl coordinator/gateway tag, not a CLI package. Do not promote the fleet.
Buyer CB stays **off** after the 2026-09-20 Studio canary attempt rolled
back. Next CB proof is a keyless loopback on 174 (stderr
`event=batching_prefill_failed reason=…`). Do not raise slots.


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

#1453 closes when a candidate that includes the **merged** rows is promoted to
the fleet. #1569 is a later CLI. Spec promotion #1583 is not a CLI change.

Coordinator/gateway on live Pearl is **v1.8.173** @ `18da0723ef9ebc829b3cddde829b1028e19853e4`
([run 35548843512](https://github.com/Augustas11/macprovider/actions/runs/35548843512)).
That runtime includes #1653 (leftover `</tool_call>` sanitizer + SPEC-006-R014
system+tools auto-prefix) on top of #1632 / #1638 / #1639. Sticky and CB stay
off. Fleet Macs still run **1.8.123** until the operator-cut CLI is promoted.
Mac Studio serving canary is `v1.8.174` (signed package extracted into
`/Users/a1/macprovider/`; also staged at `/Users/a1/candidate-v1.8.174/`; CLI
SHA-256 `4a5bb7ff76c96f0cf4f076e57e118f1ffafb0ecdfca0df9e733d5d0e16c9f98b`).
Pearl `compatibility_set.target_id` stays `v1.8.123@37e2d232…`; `accepted_ids`
includes `v1.8.174@0c276ebb…` (8-entry cap; dropped unused `v1.8.115` to make
room; 172 and 171 remain accepted). Buyer `continuous_batching` stays **off**.
Do not raise slots. Next CB proof is a keyless loopback on this 174 package.

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

## Active candidate

| Field | Value |
|---|---|
| Last built from `main` | `v1.8.174` **signed** @ `0c276ebb95ee672084a61ac1f9030f7de301ff36`, branch `release/candidate-1.8.174-spec038`, [run 35553895586](https://github.com/Augustas11/macprovider/actions/runs/35553895586) attempt 1. Compat `Augustas11/macprovider:v1.8.174@0c276ebb95ee672084a61ac1f9030f7de301ff36`. Live as `live.malibu.provider` on Mac Studio (`/Users/a1/macprovider/macprovider-cli`); also staged at `/Users/a1/candidate-v1.8.174/`. Recut after #1657 docs landed during the first signer (`c41c761e`). |
| Mac Studio serving canary | `v1.8.174` @ `0c276ebb95ee672084a61ac1f9030f7de301ff36` — signed, live, Pearl session accepted (`serving_buyers`, slots 4, CB off). Previous canary `v1.8.172` remains staged at `/Users/a1/candidate-v1.8.172/`. Do not raise slots. |
| Off-train E2E candidate | `v1.8.167` @ `7f833a2f63ddee6b2e146c821341099d89aec169` ([run 35417249468](https://github.com/Augustas11/macprovider/actions/runs/35417249468)) — signed hold-branch CLI used for the 2026-09-19 Pearl Track B run |
| Older | `v1.8.163` @ `8c0c51d2`; `v1.8.164` BYOM @ `cdbb0257`; CLI artifact `v1.8.166` @ `00ce3625` (not the Pearl runtime tag); CLI `v1.8.172` @ `c512d342` |
| Status | **Do not promote.** `v1.8.174` is the live Studio serving canary (#1653, #1656). Fleet stays on 1.8.123. Buyer CB stays off. Do not raise slots. |
| Next candidate | **not cut.** Next cut only after a CB prefill fix, or another merged CLI row. |
| Why the next cut | 174 can name a swallowed prefill throw. Do not canary until a keyless 174 loopback names that throw or returns 200. |

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
- **Last run:** 2026-09-18, candidate `v1.8.163`. Provider-side OK. TTFT p95 /
  saturation still fleet-scale. Re-run on the next candidate.

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
- **Last run:** 2026-09-19 live on Pearl coordinator + fleet **1.8.123** —
  coordinator path green; CLI path still the old binary. Re-run on the next
  candidate after it is installed on a Mac.

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

- Merge a CLI change, cut a candidate, or run an e2e track → update this file
  in the same PR/commit.
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
