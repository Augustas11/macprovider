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

One CLI row is still **in progress** (uncatalogued BYOM loopback hold). Do not
cut a promotable candidate until that row is `merged`. Last built candidates
`v1.8.163`, `v1.8.164`, `v1.8.167`, and `v1.8.168` are old or off-train — do
not promote them.

| Net change in CLI / Malibu / installer | Status | PR |
|---|---|---|
| Uncatalogued BYOM loopback serve holds WS instead of self-flapping | in progress | #1609 |
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
| SPEC-038 on-device parity + MoE-isolation self-measurement | merged | #1591 |
| Paged-KV attach gates so SPEC-038/039 can engage on real MoE hardware | merged | #1597 |
| Opt-in empirical max_batch concurrency calibration | merged | #1590 |

#1453 closes when a candidate that includes the **merged** rows is promoted to
the fleet. #1569 is a later CLI. Spec promotion #1583 is not a CLI change.

Coordinator-only (already on Pearl `v1.8.162-29-gee089f0f`, **not** this CLI
cut): #1601 Pi stream TTFT / concat-safe coalesce, #1599 coordinator XML
rewrite, #1595 coordinator message-count drop. Fleet Macs still run **1.8.123**
until this CLI is promoted. #1600 is the install.sh consumer-health alarm
(scripts/CI), not the Mac binary — it stays red until this CLI (with #1582) is
promoted **and** `get.malibu.tech/install.sh` is republished.

## Active candidate

| Field | Value |
|---|---|
| Last built from `main` | `v1.8.168` @ `646f22f84984fd994151f3512c8432992cf9b36f` ([run 35425108016](https://github.com/Augustas11/macprovider/actions/runs/35425108016)), branch `release/candidate-1.8.168-spec038` |
| Off-train E2E candidate | `v1.8.167` @ `7f833a2f63ddee6b2e146c821341099d89aec169` ([run 35417249468](https://github.com/Augustas11/macprovider/actions/runs/35417249468)) — signed hold-branch CLI used for the 2026-09-19 Pearl Track B run |
| Older | `v1.8.163` @ `8c0c51d2`; `v1.8.164` BYOM @ `cdbb0257` |
| Status | **Do not promote any of the above.** `v1.8.168` predates this hold and later `main` (#1600/#1601/#1602). `v1.8.167` proved Track B but is not current `main`. |
| Next candidate | cut off current `main` **after** the loopback-hold row is `merged` |
| Why the next cut | Pi/Qwen tool-call correctness on the Mac, 256-cap gone, #1582 install.sh pagination, paged-KV attach, BYOM serve (#1576) **plus** the uncatalogued loopback hold so Pearl Gemma serve stays on the wire |

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
  load). Re-run Track B on the first candidate that includes this hold before
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
3. In-scope e2e green on **that** candidate (Track A this cut; Track B on a
   candidate that includes the loopback hold before promoting a BYOM-serve CLI;
   Track B is not #1453 close).
4. Live smoke on the candidate (not a substitute for Track A): Pi/Qwen3-Coder
   stream+tools concat is one JSON object (never `{}` / `{}{`); unclosed
   function-XML becomes a real `bash` tool call; 257+ messages are not rejected
   with `messages_too_long` on the CLI.
5. Physical acceptance (`promote-acceptance-candidate.yml`) — this is what
   bumps `binaryVersion` and moves the fleet.
6. `verify-live-coordinator-release-rollout` before publishing discovery.
7. Byte-identity check: `docs/runbooks/provider-cli-release-verification.md`.
8. Republish `https://get.malibu.tech/install.sh` from the promoted tag so
   #1582 pagination is what `curl | bash` runs. Confirm
   `scripts/check-install-sh-consumer-health.sh` is green (#1600 / #1588).

## Session protocol

- Merge a CLI change, cut a candidate, or run an e2e track → update this file
  in the same PR/commit.
- Live-coordinator candidate test: add its `compatibility_set_id` to
  `accepted_ids` (keep `target_id`), restart coordinator, revert after.
