# Keyed first-turn CB canary lab e2e — 2026-09-21

Campaign PR **#1666**. Sanitized: timings, token counts, PIDs, binary SHA.
No buyer keys, no conversation-key values beyond lab prefixes, no live
8080 traffic.

## Header

- **Date:** 2026-09-21
- **Operator:** augstar
- **Hardware:** Mac Studio M3 Ultra, 256 GB, macOS 26.4.1
- **Topology:** isolated `127.0.0.1:18084`, `--no-join`,
  `credential_store: protected_file`, `continuous_batching: canary`,
  `max_concurrency_override: 4`, `paged_kv.enabled: true`,
  `max_context_override: 8192`.
- **Live processes left running:** 8080 PID **24569**
  (`live.malibu.provider`, signed v1.8.175, SHA
  `27a8ceac8fc35ca1b5447743048e7e6b0008734e0967a9569cd695c78d597ec8`).
  18082 (Lane A Python feed) and 18083 (`macprovider-cli-pr1658`) were
  not killed.
- **Model:** `qwen3-8b` /
  `mlx-community/Qwen3-8B-4bit` sha256
  `1f591f9c4fb38d05ea2d879d89a6eeab485c23a04eb75e3e0a289db9d95ec877`.
  8B because live 8080 already holds Coder-30B; a second 30B load is
  forbidden for this campaign.

## Binaries

| Role | Path | SHA-256 | Identity |
| --- | --- | --- | --- |
| Isolated lab CLI | `/Users/a1/macprovider-cb-keyed-canary/phase3-binary/.build/release/macprovider-cli` | `12de60d0c0462b9452fd59fa8dfc29dd274039a810f3d90b250da02853051b01` | `swift build -c release --product macprovider-cli`; `--version` still `1.8.123` |
| Isolated serve | PID **39458** | same SHA | `--port 18084 --no-join --no-idle-prewarm --continuous-batching canary --max-batch 4 --paged-kv-enabled` |
| Live 8080 | `/Users/a1/macprovider/macprovider-cli` | `27a8ceac…` | PID **24569** throughout; not swapped |

## Load-time attach (8B)

- parity `established=true` nLayers=36 nNew=32 gatherKernelCalls=2304
  maxLogicalBlocks=18 nonIdentityPermutation=true
- batched-isolation `requiresMoE=false proven=true rowsDecoded=2
  rowFailures=0 crossRowDivergences=0 challengeDistinguishing=true`
- `[paged-kv] measure OK: runtime measurement complete, paged-KV attach
  eligible for model=qwen3-8b`
- Startup still emits the configuration-only canary line
  `event=batching_unsupported action=serial_routed reason=local_batching_capability_unavailable`
  before attach. That is expected preflight, not the request path.

## Keyed 4-wide first-turn

Four concurrent POST `/v1/chat/completions` against isolated 18084.
Each request had a unique `X-Request-ID` and unique
`X-MacProvider-Provider-Conversation` (`conv:lab-1666-first-*`).
`max_tokens=32`, `temperature=0`, `stream=false`. First-turn cache miss.

| i | HTTP | wall_s | generation_ms | prompt | completion | cached | finish |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 0 | 200 | 1.093 | 1060 | 14 | 32 | 0 | length |
| 1 | 200 | 1.109 | 1099 | 15 | 32 | 0 | length |
| 2 | 200 | 1.054 | 1011 | 15 | 32 | 0 | length |
| 3 | 200 | 1.003 | 948 | 14 | 32 | 0 | length |

Overlap wall **1.111 s**. Four serial 1 s generations would have been
~4 s. Request-path logs: four `kv_cache_request_completed`, **no**
`serial_routed reason=conversation_key_rollout_unavailable`, **no**
`batching_prefill_failed`.

## Verdict

**PASS** for the campaign defect: conversation-keyed first-turn /
cache-miss requests enter Studio CB canary and share the decode batch.
Not a live-8080 swap. Not `continuous_batching: on`. Not a slot raise.
Not fleet promote. Worktree binary is lab evidence only.

## Loop B (after merge)

Signed **v1.8.176** is live as `live.malibu.provider` (PID **51670**,
SHA `b0bb40342350f5d843db874bc7e0ec40648d3065754ac6ff109955136eca0075`,
compat `Augustas11/macprovider:v1.8.176@bd75f86df829ec456a2cac7e1b23ffa4b08b4455`).
Pearl accepted the set. 30B paged-KV attach eligible. Isolated 18084 stopped.
Do not set CB `on`. Do not raise slots.

## Live 176 confirmation (2026-09-21, Coder-30B)

Same keyed 4-wide as lab, against live `127.0.0.1:8080` with unique
`X-MacProvider-Provider-Conversation` keys. `max_tokens=32`.

| i | HTTP | wall_s | prompt | completion | cached | finish |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 0 | 200 | 2.898 | 14 | 32 | 0 | length |
| 1 | 200 | 2.717 | 15 | 32 | 0 | length |
| 2 | 200 | 3.022 | 15 | 32 | 0 | length |
| 3 | 200 | 3.066 | 14 | 32 | 0 | length |

Overlap wall **3.073 s** vs sum **11.703 s**. Request-path: four
`kv_cache_request_completed`, **no** `conversation_key_rollout_unavailable`,
**no** `batching_prefill_failed`. **PASS.**

Wholesale `api.malibu.tech` 4-wide (acct_openrouter `mp_` key, unique first
turns, same 30B): 2/4 HTTP 200 (`cached_prompt_tokens=0`, no serial-route on
Studio) and 2/4 HTTP 429 `no_provider_available`. That shed is slots/routing,
not the keyed-first-turn CLI fence.

## Loop C (2026-09-22, slots 8)

Live 8080 `max_concurrency_override: 8`, CB still **canary**, signed 176.
Keyed 8-wide first-turn against `127.0.0.1:8080`, unique conversation keys,
`max_tokens=32`. 8/8 HTTP 200. Overlap **5.902 s** vs sum **41.216 s**.
RSS 49612→50321 MB, memory pressure **normal**, thermal **nominal**, same
PID, no `serial_routed`, no `batching_prefill_failed`. **PASS.**

Do not set CB `on`. Do not promote the fleet.

## Not done here

- Sticky/cross-turn positive `cached_prompt_tokens` batching (AC-26)
- Wholesale Track A rerun on Qwen 30B
