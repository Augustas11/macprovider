# CLI Release Train — control surface

**This file is the single source of truth for provider CLI releases.** Work happens
across many sessions and agents; before cutting, testing, or promoting a CLI
build, read this file, and after any release-affecting action update it in the
same commit/PR. If reality and this file disagree, fix this file.

## How to track the next CLI

The shipped-207 table below records the completed net change from fleet
**1.8.123** to **1.8.207**. Start the next-candidate table only when another
CLI/Malibu/installer change merges.

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
CLI train. Pearl currently reports runtime `v1.8.208`; failed or superseded
runtime attempts remain consumed tags. Runtime tag `v1.8.209` is reserved for
the #1804 Pearl rollout. Public provider release `v1.8.207` is the current fleet
recommendation and none of those tags may be reused by either train.

## Current promoted stable

| Field | Value |
|---|---|
| Version | **1.8.207** |
| Compat-set id | `Augustas11/macprovider:v1.8.207@d98b74a6a158000dabaecb89d75886b6817e9d0f` |
| Coordinator `target_id` / `latest_binary_version` | `1.8.207` |
| Promotion | Immutable release [v1.8.207](https://github.com/Augustas11/macprovider/releases/tag/v1.8.207), promotion run [36526004611](https://github.com/Augustas11/macprovider/actions/runs/36526004611), final rollout verification run [36529821734](https://github.com/Augustas11/macprovider/actions/runs/36529821734) |
| Public installer / China mirror | `get.malibu.tech/install.sh` matches the released installer at SHA-256 `8a68f82b254023671715dd45f06895b4a552e35430f3afc97ff3d83c69dccde5`; consumer health resolves `v1.8.207`; `download.malibu.tech/releases/latest.json` points to `v1.8.207` and all 24 mirrored assets were byte-compared with GitHub |

## Next CLI candidate — net changes vs 1.8.207

No candidate has been cut from this table yet. Use the next unused tag after
the coordinator and CLI train reservations at cut time; `v1.8.209` is reserved
for the #1804 Pearl runtime and must not be used for a CLI candidate.

| Net change in CLI / Malibu / installer | Status | PR |
|---|---|---|
| Continuous-batch rows stay inside the buyer's authenticated reserved-output budget. Gateway reserved-output metadata now flows through coordinator HTTP, clear WebSocket, and Tier-2 dispatch without rewriting the request body or receipt prompt hash; prompt-at-cap and output-overflow failures return terminal buyer 413 responses with no retry, failover, breaker fault, credit, or debit. Hardware campaign used an isolated `--no-join` Studio provider and did not connect a local build to live Malibu. | merged `9eb1553b` 2026-09-30 | #1806 |

## Shipped CLI 1.8.207 — net changes vs 1.8.123

Candidate **207** was promoted from exact accepted commit `d98b74a6` on
2026-09-29. The Studio serving canary now runs the signed public 207 payload
with `qwen/qwen3.6-35b-a3b`, and Pearl recommends compatibility set 207 while
retaining promoted 117 and 123 in `accepted_ids` for the older fleet. Private
candidate 202 was removed from the accepted set after the 207 cut.


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
| Signed-policy hybrid-cache admission follow-up: policy generation and runtime verification accept the measured `mixed` cache identity. #1808's isolated source-built Studio campaign passed automatic policy activation, local proof, paged-KV attach, batch depth 4, and scheduler-admitted HTTP 200s for Qwen3.5 27B and 35B-A3B. The #1778 follow-up corrected the isolation verifier to compare the full-prompt lifecycle with production `TokenIterator` references; the verifier-only candidate then passed exact 48-token parity, unequal-row isolation, peer leave/rejoin, and attach eligibility for Qwen3.5 27B, Qwen3.5 35B-A3B, and Qwen3.8 27B on the M3 Ultra. Production policy remains empty. A reviewed signed/notarized packaged candidate, release-asset byte identity, updater proof, and real coordinator/buyer/billing/receipt/settlement/warm-swap campaign remain promotion and issue-closure gates. | #1808 merged; #1778 follow-up in review | #1778 |
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

Coordinator/gateway on live Pearl is **v1.8.191** @ `98e3e4af` (includes
#1728). Fleet Macs and the coordinator recommendation remain on provider
binary **1.8.123**. The Studio serves signed private candidate **195**; do
not promote the fleet from this campaign.

#1632 / #1638 / #1639 (coordinator leftover rewrite + gateway R014) are
coordinator/gateway, not CLI rows. #1653 **is** a CLI row (above); its
`InferenceRelay` drop is in `v1.8.174`.

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
| Last built candidate | **v1.8.207**, cut from `main` @ `d98b74a6a158000dabaecb89d75886b6817e9d0f`, acceptance run [36519497647](https://github.com/Augustas11/macprovider/actions/runs/36519497647), promoted unchanged by run [36526004611](https://github.com/Augustas11/macprovider/actions/runs/36526004611). |
| Mac Studio serving canary | Signed public **207** @ `d98b74a6`, installed through the established payload-only operator swap while preserving config and LaunchAgents. It serves `qwen/qwen3.6-35b-a3b` / `mlx-community/Qwen3.6-35B-A3B-4bit`, reports coordinator-authorized `buyer_serving`, and returned bounded public-buyer request `f0554d11-049b-47f8-81e5-a516d5130954` after promotion. |
| Off-train E2E candidate | `v1.8.167` @ `7f833a2f63ddee6b2e146c821341099d89aec169` ([run 35417249468](https://github.com/Augustas11/macprovider/actions/runs/35417249468)) — signed hold-branch CLI used for the 2026-09-19 Pearl Track B run |
| Older | `v1.8.163` @ `8c0c51d2`; `v1.8.164` @ `eb30981c` (BYOM #1576 `cdbb0257` + #1591 + #1590 + #1593); CLI artifact `v1.8.166` @ `00ce3625` (not the Pearl runtime tag); CLI `v1.8.172` @ `c512d342`; CLI `v1.8.174` @ `0c276ebb`; CLI `v1.8.175` @ `d02798db` |
| Status | **207 promoted and live.** Pearl `target_id` and `latest_binary_version` are 207; accepted compatibility sets are promoted 207, 117, and 123. Public installer parity, consumer health, mirror byte identity, signed discovery rollout, Studio join, and a bounded real-buyer response are green. |
| Coordinator tags taken | **v1.8.204**, **v1.8.205** (both applies rolled back), **v1.8.206**, and live **v1.8.208** are Pearl runtime releases; **v1.8.209** is reserved for the #1804 Pearl rollout. |
| Next candidate | None cut. The next-candidate table above has started with #1806; choose the next unused tag at cut time and do not reuse 207. |
| Candidate 202 CB-canary confirmation (2026-09-28) | Isolated Studio loopback serve of the **signed** 202 binary (`--no-join`, ephemeral id, :8092, live :8080/201 untouched) confirmed `qwen/qwen3.6-35b-a3b` **paged-KV attach eligible** (runtime parity `established=true`, cross-row MoE isolation `proven=true`) and a keyless **scheduler-admitted batched 200** with a stable `X-Request-ID` (`event=batching_admitted action=scheduler_admitted`), hash `3fed776d…`. Measured throughput (harness, v1.8.201 same source): 2.86× aggregate vs serial at 8 rows, bit-exact parity. On candidate 202 the qwen3.5/qwen3.8 hybrids fail parity and are excluded; #1776 fixes them only in the deferred successor candidate. Buyer `continuous_batching` was already canary in live config; the 201→202 serving swap (operator-tools/swap-202.sh, 2026-09-28) made 202 the live Studio provider — a3b now served BATCHED (scheduler_admitted) at ~2.86x. |
| Notable merges after candidate 186 | #1707 (`5ada77e1`, CLI); #1714 (`3abf42a8`, CLI + Malibu); #1706 (`2b352720`, catalog-lane file only — binary unchanged); #1713 (`57686a84`, node-operator UX — shipped in `v1.8.192`); #1742 (`03627cda`, shipped in Studio candidate `v1.8.195`); #1757 (`0197f379`, CB qualification closeout); #1745 (`ddaa551b`, China supply path); #1762 (`95a6563d`, batched prefill); #1658 (`3ec784c69`, Build 1 private staging path); #1753 (`9636a125`, signed provider-release discovery, merged after candidate 201); #1771 (`e29ea2976`, Qwen3.6 MoE paged-KV admission, shipped in candidate 202); #1776 (`38229a8c3`, Qwen3.5/Qwen3.8 exact CB parity, merged after candidate 202); #1785 (`5c09c5c9a`, keep-0 sliding-window paged KV, merged after candidate 202). Coordinator/gateway settlement recovery continued separately through #1728, live in Pearl runtime `v1.8.191`. |
| Why candidate 186 exists | Prove #1700 final-answer rendering, strict-pinned buyer quality, eight-seat routing, and durable settlement on one signed Studio-only build (soak proof; live seats since reduced to one — see Mac Studio serving canary above). |

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
  against this runtime before closing Track D. Keep fleet recommendation and
  `binaryVersion` at 1.8.123.
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

## Promotion gate (checklist)

1. All in-scope CLI rows above are `merged`.
2. Cut one candidate off `main` (`acceptance-candidate.yml`). Do **not** reuse
   `v1.8.163` / `v1.8.164` / `v1.8.167` / `v1.8.168`.
3. In-scope e2e green on that candidate, or an explicit carry-forward record
   under the rule above. For 207, Tracks A/C/D/F carry forward from signed
   201/202; Track B remains a separate BYOM-serve gate; Track E is mandatory
   before the mainland-provider installer handoff.
4. Exact signed-candidate install/join smoke. For 207, do not repeat the Pi or
   batched-prefill campaigns; verify the installed CLI advertises 1.8.207,
   joins through Pearl's exact compatibility set, and serves a bounded request.
5. Physical acceptance (`promote-acceptance-candidate.yml`) publishes the exact
   versioned bytes and moves the fleet; it does not rewrite `binaryVersion`.
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
