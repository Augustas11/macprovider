# SPEC-023 — Installer-Integrated Autotune Recommend
version: v0.2
status: LOCKED
owner: operator (a11)
last-locked: 2026-07-03

## Change log

- **v0.2 (2026-07-03)** — Two-part amendment ratifying the 5 client-side
  fixes shipped between v1.7.5 and v1.7.9 and the accompanying
  autotune-static keypair rotation.
  1. **`min_sustained_tps` and `max_4k_ttft_ms` are advisory QoS
     targets, not hard eligibility gates.** v1.7.9 (PR #335) reclassified
     these fields as soft signals — a benchmark below/above the target
     emits `.tps_below_gate` / `.ttft_above_gate` warnings but does not
     veto the recommendation. `thermalThrottleDetected` remains a hard
     block; the real financial gate stays `expected_net_usd_per_hour ≥
     paidThreshold ($0.005/hr)`. `swapDetected` similarly went soft in
     v1.7.6 (`.swap_observed_under_load`). Motivation: on M-Base 32GB
     Tier C hardware (M5), every candidate had positive net income but
     was hard-blocked by TPS gates calibrated for M-Pro/M-Max. The
     first-install drop-out cliff (donor-mode-only recommendation
     despite paid eligibility) was closed by making the gates soft.
     The catalog field name `min_sustained_tps` is now semantically
     "advisory floor" rather than "hard minimum"; if a future policy
     ever wants a genuine hard floor, use a distinct field name (e.g.
     `hard_min_sustained_tps`) rather than overloading this one.
  2. **Static-feed keypair rotated v2 → v3.** New keyID
     `streamvc-autotune-static-v3`; new base64 pubkey
     `1qzXegR2OEu0TaQNWjUkN4PamQAHdpvBcYW/pJ4h6oE=` baked into
     `AutotuneRecommend.swift`. The v3 **private** key is held off-repo
     by the operator (default path
     `~/.config/macprovider/keys/autotune-static-v3.private.base64`,
     `chmod 0600`); the resign script at
     `scripts/resign-autotune-static.sh` refuses to run if the key
     file is world-readable. Runtime signature verification remains
     unchanged: the client fetches from `coordinator.streamvc.live/static/*`,
     verifies against the baked v3 pubkey, and falls back to the
     compiled-in baked catalog on verification failure. Older v1.7.9-
     clients that still bake the v2 pubkey `sidecarIsValid`-fail on
     v3 sigs, fall back to their baked catalog, and stay online
     thanks to the v0.2 soft-signal gates above. See
     `phase3-binary/dist/static/keys/README.md` for the full trust
     model and the v3 → v4 rotation procedure.
  3. **Live catalog `min_sustained_tps` cuts.** With gates now
     advisory, the v3-signed live catalog at
     `coordinator.streamvc.live/static/autotune-candidates.json` was
     re-published with M-Base-realistic advisory values so
     `tps_below_gate` becomes a rare warning rather than the common
     case on M-Base hardware:

     | model                              | v2 (2026-07-02) | v3 (2026-07-03) | rationale |
     |------------------------------------|:---------------:|:---------------:|---|
     | qwen3-coder-30b-a3b-instruct       | 25              | **20**          | M5 measured ~23.4 tok/s cold-start; new gate has headroom |
     | openai/gpt-oss-20b                 | 30              | **15**          | M5 measured ~16.7 tok/s cold-start; large cut needed |
     | meta-llama/llama-3.1-8b-instruct   | 20              | **15**          | keep M-Base-lite (8/16GB) eligible |
     | qwen2.5-coder-32b-instruct         | 25              | **20**          | broaden eligibility while keeping M-Max/Ultra tier signal |
     | qwen3-32b                          | 15              | 15              | unchanged |

     Baked catalog values in `AutotuneRecommend.swift` mirror the live
     feed for the 4 M-Base-relevant rows we lowered (qwen3-coder-30b-a3b,
     openai/gpt-oss-20b, meta-llama/llama-3.1-8b, qwen2.5-coder-32b) so
     fallback semantics match the intended M-Base UX. Baked and live
     intentionally drift on two other axes: (i) baked keeps
     `runtime_status="listed"` (qwen3-32b, qwen2.5-coder-32b) and
     `runtime_status="blocked"` (google-gemma, nvidia-nemotron) rows that
     the live feed omits — baked serves as an offline superset for
     correct "listed but not currently sold" and "blocked pending
     migration validation/rate-card rollout" semantics; (ii) baked keeps
     qwen3-32b at `min_sustained_tps=30`
     (M-Max floor) while live sets it to `15` (recommendable to
     M-Pro 48GB) — offline recommendation on a compiled-in fallback
     stays conservative.

- **v0.1 (2026-07-01)** — Initial lock. See §1-§10.

## 1. Mission

`autotune --recommend` scores rate-card-eligible models against the operator's detected Mac hardware, local benchmark results, the current rate card, and an operator-curated static demand signal, then recommends the model with the best demand-weighted expected provider net `$/hr` among eligible rows. It serves every new provider installer and every operator who runs `macprovider-cli autotune --recommend` after install. Wave 0c lands now because beta launch readiness depends on the 120-provider acquisition cohort reaching a low-friction install path and a correct first-model choice instead of the current donor-default behavior that often selects the largest RAM-fitting dense model rather than the best paid-yield row.

## 2. Non-goals

- This SPEC does not solve "will buyers show up." It recommends a model from available market and hardware signals; it does not create market demand.
- This SPEC does not auto-switch models without operator action. NiceHash QuickMiner-style profit switching is out of scope for v0.1.
- This SPEC does not change rate-card content. Wave 1 owns the rate-card rows and prices.
- This SPEC does not change gateway billing or coordinator settlement. Waves 0a/0b already shipped the money-path settlement and model-key normalization fixes.
- This SPEC does not add provider-side TPS reputation feedback to the coordinator. That is deferred to v0.2.
- This SPEC does not implement a live coordinator `/v1/demand-signal` endpoint. That is deferred to v0.2.
- This SPEC does not implement utilization-adjusted realized-earnings projection. That is deferred to v0.2 after real buyer history exists.
- This SPEC does not claim a live-buyer production incident as motivation. Per Decision Log Entry 95, the Wave 0a/0b urgency came from harness-driven pre-launch bug discovery; Wave 0c urgency comes from beta onboarding readiness.
- This SPEC does not inspect or depend on Darkbloom / `d-inference` source. Competitive framing uses only public-surface findings preserved in RESEARCH_230.

## 3. Inputs

### 3.1 Hardware properties

Hardware fields come from `MachineFingerprinter.sample()` plus local autotune benchmark measurements. The current code samples RAM, chip string, OS version, and binary version; SPEC-023 requires the implementation to extend or derive the remaining fields without weakening the existing sample.

Required hardware fields:

| Field | Type | Source | Rule |
|---|---|---|---|
| `ram_gb` | integer | `MachineFingerprinter.sample().ramGB` | Rounded unified memory in GiB. Must be at least `1`; unknown hardware is not represented as `0`. |
| `chip` | string | `MachineFingerprinter.sample().chip` | Apple chip family or `"unknown"`. |
| `os_version` | string | `MachineFingerprinter.sample().osVersion` | Used only for support/debug output. |
| `binary_version` | string | `MachineFingerprinter.sample().binaryVersion` | Used for reproducibility and support/debug output. |
| `bandwidth_tier` | string enum: `S`, `A`, `B`, `C`, `unknown` | derived from chip family / benchmark table | Unknown hardware maps to `C` for eligibility conservatism unless a benchmark-derived tier is available. |
| `diversification_id` | string | HMAC-SHA256-derived provider ID if configured, otherwise HMAC-SHA256-derived stable machine identity | Input to deterministic diversification. Raw machine fingerprints MUST NOT be persisted, logged, emitted in JSON, included in support bundles, or sent to coordinator/gateway as part of v0.1 recommendation. |
| `candidate_benchmarks[model_key].sustained_tps` | float | local autotune benchmark | Warm steady-state decode tokens/sec for each candidate. |
| `candidate_benchmarks[model_key].ttft_ms` | integer | local autotune benchmark | Time to first token under the v0.1 benchmark prompt shape. |
| `candidate_benchmarks[model_key].swap_detected` | boolean | local probe | **[amended v0.2]** Observed swap emits `swap_observed_under_load` warning; does not fail eligibility. |
| `candidate_benchmarks[model_key].thermal_throttle_detected` | boolean | local probe | Thermal throttle during probe fails eligibility. **[unchanged v0.2: hard block]** |

HMAC identity rules:

- The HMAC key MUST be a per-install local secret generated with a CSPRNG during first setup.
- The secret MUST be stored only in a local protected store: macOS Keychain when available, otherwise a root/operator-readable file with `0600` permissions under the macprovider config directory.
- The secret MUST NOT be sent to coordinator/gateway, emitted in JSON, logged, included in support bundles, or copied into `last-recommendation.json`.
- Diversification and cache identity MUST use separate domain labels, at minimum `macprovider-autotune-diversification-v1` and `macprovider-autotune-cache-identity-v1`, before HMAC-SHA256.
- If the local secret is missing or unreadable, the CLI MUST create a new secret and mark any prior recommendation cache stale because the derived identity changed.

Bandwidth tier rules:

- Tier order is `S >= A >= B >= C`; `unknown` is treated as `C` for eligibility.
- v0.1 derives `bandwidth_tier` from the normalized `chip` string before benchmark overrides:

| Chip family match | bandwidth_tier |
|---|---|
| `M3 Ultra`, `M4 Ultra`, or later `Ultra` | `S` |
| `M1 Ultra`, `M2 Ultra`, `M3 Max`, `M4 Max`, or later `Max` | `A` |
| `M1 Max`, `M2 Max`, any `Pro` | `B` |
| `M1`, `M2`, `M3`, `M4`, `unknown`, or unrecognized chip string | `C` |

- A benchmark-derived tier override MAY raise the chip-derived tier only when the benchmark table is compiled into the same binary release and the table row names the benchmark ID, threshold, and resulting tier. It MUST NOT lower a known chip-derived tier in v0.1.
- `min_bandwidth_tier` passes when `mac.bandwidth_tier >= model.min_bandwidth_tier` under the order above.

Optional hardware fields:

| Field | Type | Rule |
|---|---|---|
| `machine` | string | Human-readable Mac product name if available. |
| `power_watts` | float | Used only when an electricity estimate is available. Absence must not fail recommendation. |
| `measured_memory_pressure` | string enum | May be used for confidence. **[amended v0.2: the only runtime hard failure is `thermal_throttle_detected == true`; swap is advisory per change log v0.2 point 1]**. |
| `benchmark_id` | string | Stable ID of the local benchmark run, included when available. |

### 3.2 Candidate/admission catalog

Candidate metadata is a separate signed control-plane input. Demand rank may score rows, but it never defines model download IDs, RAM gates, tier gates, benchmark gates, or runtime status.

Primary source:

```text
https://get.streamvc.live/autotune-candidates.json
```

Fallback source:

```text
baked autotune-candidates snapshot compiled into the installer/CLI release
```

Catalog selection happens before row eligibility. If the fetched catalog is missing, invalid, unsigned, or stale beyond §3.5 limits, the CLI MUST reject the fetched catalog, use the baked catalog snapshot, and emit `candidate_catalog_fallback_used` per AC-6. After selecting either a valid fetched catalog or the baked catalog, a demand/rate-card row missing metadata in the selected catalog is ineligible and MUST NOT be downloaded or benchmarked. The baked catalog is part of the release artifact and is trusted only for that binary version.

The v0.1 candidate catalog schema is:

```json
{
  "version": "string",
  "generated_at": "RFC3339 timestamp",
  "source": "operator_curated_autotune_candidate_catalog",
  "rows": {
    "<model_key>": {
      "model_id": "org/repo",
      "model_revision": "40-hex content commit",
      "model_sha256": "64-hex canonical artifact-set hash",
      "min_ram_gb": 0,
      "min_bandwidth_tier": "C",
      "bench_gate": {
        "min_sustained_tps": 0.0,
        "max_4k_ttft_ms": 0
      },
      "runtime_status": "candidate",
      "notes": "string"
    }
  }
}
```

Field rules:

- `model_key` is the normalized key used for rate-card and demand-rank joins.
- `model_id` is the HuggingFace MLX model ID allowed for download/benchmark.
- `model_revision` is a content-addressed immutable model-host revision, such as a 40-hex HuggingFace repository commit. The CLI MUST download by this revision, not by a mutable branch or tag.
- `model_sha256` is a lowercase hex SHA-256 digest of the canonical artifact-set manifest for the release-pinned model snapshot. After downloading by `model_revision`, the CLI MUST reject the snapshot if any filesystem entry is not a regular file or directory; symlinks, hardlinks with link count greater than one, device nodes, sockets, FIFOs, absolute paths, path escapes, and relative paths containing `..` are forbidden. The CLI then enumerates every regular file, computes each file SHA-256, sorts entries by normalized POSIX relative path, serializes each entry as `path LF size_decimal LF sha256_hex LF`, concatenates those UTF-8 entries, and SHA-256s the concatenated bytes. A mismatch fails closed before benchmark, recommendation, local donor-mode commit, or provider run.
- Every downloadable row (`candidate`, `listed`, or `recommendable`) MUST include both `model_revision` and `model_sha256`. If either is absent, the row is ineligible before download or benchmark, including donor mode.
- `min_ram_gb`, `min_bandwidth_tier`, and `bench_gate` are authoritative for §5.
- `runtime_status` is one of `candidate`, `listed`, `recommendable`, or `blocked`. Only `recommendable` rows may become paid defaults, and the demand-rank row must also have `recommendable: true`.

The table below lists the minimum v0.1 rows and gate values. The baked JSON release artifact MUST also include a release-pinned `model_revision` and `model_sha256` for every non-`blocked` row; the long immutable bindings are omitted from this table for readability.

The v0.1 baked catalog MUST contain at least these rows:

| model_key | model_id | min_ram_gb | min_bandwidth_tier | min_sustained_tps | max_4k_ttft_ms | runtime_status |
|---|---|---:|---|---:|---:|---|
| `meta-llama/llama-3.1-8b-instruct` | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | 16 | `C` | 20 | 2500 | `recommendable` |
| `openai/gpt-oss-20b` | `mlx-community/gpt-oss-20b-MXFP4-Q8` | 24 | `C` | 30 | 2500 | `recommendable` |
| `qwen3-32b` | `mlx-community/Qwen3-32B-4bit` | 32 | `A` | 30 | 3000 | `listed` |
| `qwen3-coder-30b-a3b-instruct` | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | 32 | `C` | 25 | 3000 | `recommendable` |
| `qwen2.5-coder-32b-instruct` | `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | 64 | `A` | 30 | 3500 | `listed` |
| `google-gemma-4-26b-a4b-it` | `mlx-community/gemma-4-26b-a4b-it-4bit` | 32 | `C` | 30 | 3000 | `blocked` |
| `nvidia/nemotron-3-nano-30b-a3b` | `mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit` | 32 | `C` | 30 | 3000 | `blocked` |

`blocked` rows may be shown only as diagnostics when useful; they are never downloaded, benchmarked, or recommended by default in v0.1. The Gemma/Nemotron blocked status means pending `mlx-swift-lm` migration validation and rate-card rollout, not an upstream architecture absence.

### 3.3 Rate card

The recommendation engine fetches the current rate card from `https://coordinator.streamvc.live/v1/rate-card`. If the fetch fails, it uses the baked rate-card snapshot compiled into the installer/CLI release and emits a warning to stderr and JSON `warnings[]`.

`GET /v1/rate-card` is a read-only coordinator endpoint. It MUST NOT alter billing, settlement, routing, provider state, request logs, `RateCardEntry`, YAML schema, ledger schema, or settlement arithmetic. It is public-read in v0.1 because it exposes only prices already used for buyer/provider economics; no provider or buyer credential is required. The endpoint returns a recommendation-only projection derived from the running coordinator's existing `Rewards.RateCard`, `Rewards.ProviderShare`, `Rewards.GlobalMultiplier`, and `stats.rollup.usd_per_million_credits` after config load.

Repository routing contract:

- The handler lives on the coordinator buyer HTTP mux (`buyer_port: 8443`), not the provider/operator mux (`provider_port: 8444`).
- Production nginx MUST include an exact `location = /v1/rate-card` allow-through before the generic `location /v1/ { return 404; }` block in `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`.
- The nginx location proxies to `http://127.0.0.1:8443/v1/rate-card$is_args$args`, forwards `Host`, `X-Real-IP`, `X-Forwarded-For`, and `X-Forwarded-Proto`, and does not require `Authorization`.

The v0.1 rate-card JSON schema is:

```json
{
  "version": "string",
  "generated_at": "RFC3339 timestamp",
  "usd_per_million_credits": 1.0,
  "rows": {
    "<model_key>": {
      "prompt_rate_per_mtok": 0,
      "completion_rate_per_mtok": 0,
      "provider_share_bps": 9000,
      "global_multiplier_ppm": 1000000
    }
  }
}
```

`prompt_rate_per_mtok` and `completion_rate_per_mtok` are coordinator credits per million tokens, matching `phase4-coordinator/internal/billing/formula.go::RateCardEntry` semantics and ledger `*_rate_per_mtok` columns. `usd_per_million_credits` is the active `stats.rollup.usd_per_million_credits` conversion used for recommendation math; v0.1 expects `1.0` but the endpoint value is authoritative. A model is rate-card-enabled for recommendation only if lookup succeeds by exact key or by Wave 0b `normalizeModelKey`. Recommendation lookup MUST NOT use the coordinator `default` fallback unless the candidate key itself is literally `default`. Unknown/missing `provider_share_bps` is non-compliant for fetched rate-card rows; baked fallback rows may use `9000` only when the release snapshot explicitly records that fallback.

`version` is a recommendation-projection version, not the existing billing snapshot hash. It is the lowercase hex SHA-256 of the canonical projection bytes after config load:

1. Build a JSON object containing only `usd_per_million_credits`, `provider_share_bps`, `global_multiplier_ppm`, and `rows`.
2. Sort `rows` by normalized model key.
3. Serialize JSON with sorted object keys, no insignificant whitespace, decimal integers for all rates/BPS/PPM values, and decimal number syntax for `usd_per_million_credits`.
4. Exclude unrelated config and ledger fields, including quarantine/force-void state, request-log state, operator settings, and settlement runtime state.

### 3.4 Demand signal

The recommendation engine fetches `https://get.streamvc.live/demand-rank.json` and falls back to a baked snapshot when the static fetch fails, times out, fails Ed25519 detached-signature verification, or fails schema validation. The demand signal is operator-curated OpenRouter-prior metadata, not a coordinator demand endpoint.

The v0.1 demand-rank JSON schema is locked as:

```json
{
  "version": "string",
  "generated_at": "RFC3339 timestamp",
  "source": "openrouter_completion_token_rank_operator_curated",
  "cold_start_floor": 0.15,
  "diversification_band": 0.85,
  "rows": {
    "<model_key>": {
      "demand_weight": 0.0,
      "rank": null,
      "recommendable": false,
      "min_provider_target": 0
    }
  }
}
```

Field rules:

- `version` is an opaque operator-controlled version string and must be persisted with the recommendation.
- `generated_at` must parse as RFC3339. A stale file is allowed in v0.1 but must add a warning when older than 14 days.
- `source` must equal `openrouter_completion_token_rank_operator_curated` in v0.1.
- `cold_start_floor` must equal `0.15` for v0.1.
- `diversification_band` must equal `0.85` for v0.1.
- `rows.<model_key>.demand_weight` is a finite number in `[0.0, 1.0]`.
- `rows.<model_key>.rank` is either a positive integer OpenRouter completion-token rank or `null` for operator-curated rows without a current rank.
- `rows.<model_key>.recommendable` is the operator's deployability switch. `true` means runtime support, billing/settlement, and minimum bench gates are green enough for defaults.
- `rows.<model_key>.min_provider_target` is retained for operator coverage planning and v0.2 migration. v0.1 records it but does not query live provider counts.

### 3.5 Static JSON integrity

Fetched `demand-rank.json` and `autotune-candidates.json` MUST be verified before parsing into the recommendation engine:

1. Fetch `{name}.json` and detached `{name}.json.sig` from `https://get.streamvc.live/`.
2. Parse `{name}.json.sig` as UTF-8 JSON exactly in this shape:

```json
{
  "key_id": "streamvc-autotune-static-v1",
  "alg": "ed25519",
  "signature": "<base64>"
}
```

3. Verify `signature` as base64-encoded Ed25519 over the exact UTF-8 bytes of `{name}.json`.
4. Use the release-embedded public key `autotune_static_json_ed25519_v1` and release-embedded key ID `streamvc-autotune-static-v1`.
5. Parse `{name}.json` only after signature verification succeeds.
6. Reject the fetched file and fall back to the baked snapshot when the signature sidecar is missing, malformed, uses the wrong `key_id`, uses any `alg` other than `ed25519`, or fails verification.
7. Reject the fetched file and fall back to the baked snapshot when `generated_at` is older than the baked snapshot's `generated_at`.
8. Emit `demand_rank_stale` for stale `demand-rank.json` or `candidate_catalog_stale` for stale `autotune-candidates.json`, but allow the fetched file when `generated_at` is 14-30 days old.
9. Reject the fetched file and fall back to the baked snapshot when `generated_at` is more than 10 minutes in the future relative to the local clock.
10. Reject the fetched file and fall back to the baked snapshot when `generated_at` is more than 30 days old.

Key rotation is deferred to v0.2, but v0.1 clients MUST keep the public key and key ID release-pinned. A new key requires a new binary release.

## 4. Formula (locked v0.1)

The recommendation engine MUST use this v0.1 formula shape:

```text
eligible_rows = rows where:
  rate_card_enabled AND
  recommendable == true AND
  hardware_fits(model, mac) AND
  local_autotune_passes(model, mac)

raw_score(row | mac) =
  measured_tps(row, mac)
  × 3600
  × usd_per_million_completion_tok(row)
  × provider_share(row)
  × max(demand_weight(row), cold_start_floor)
  × tier_weight(row, mac.tier)

recommendation_pool =
  all eligible rows where raw_score >= 0.85 × max(raw_score)

default_model =
  pool[ stable_hash(diversification_id) % len(pool) ]
```

Constants locked in v0.1:

| Constant | Value | Rule |
|---|---:|---|
| `cold_start_floor` | `0.15` | From demand-rank JSON; schema validation fails if the fetched value differs. |
| `diversification_band` | `0.85` | All eligible rows within 85% of the best raw score join the diversification pool. |
| `provider_share` | `0.90` | Represented by rate-card row `provider_share_bps = 9000`; the row value is authoritative, but v0.1 rows are expected to use 0.90. |
| `tier_weight` | `1.0` | Applies to all rows and tiers in v0.1. Tier-specific calibration is deferred to v0.2. |
| ranked output length | `5` | The JSON `candidates[]` array defaults to the top 5 rows after ranking, including eligible rows first and then selected ineligible diagnostic rows only when no eligible row exists. |
| `stable_hash` | SHA-256 over UTF-8 `diversification_id` | Interpret the first 8 bytes as unsigned big-endian integer for modulo. |

`usd_per_million_completion_tok(row)` is:

```text
completion_rate_per_mtok
× (global_multiplier_ppm / 1_000_000)
× (usd_per_million_credits / 1_000_000)
```

Example: `completion_rate_per_mtok = 100000`, `global_multiplier_ppm = 1000000`, and `usd_per_million_credits = 1.0` yields `$0.100000/M` completion tokens. `provider_share(row)` is `provider_share_bps / 10_000.0`.

Displayed earning fields are not allowed to overstate demand certainty:

- `expected_gross_usd_per_hour` is full-utilization buyer gross capacity: `measured_tps × 3600 × usd_per_million_completion_tok / 1_000_000`.
- `platform_fee_usd_per_hour` is `expected_gross_usd_per_hour × (1 - provider_share)`.
- `expected_net_usd_per_hour` is provider-side capacity at `inputs.assumed_utilization`, minus electricity only when electricity is supplied: `(expected_gross_usd_per_hour - platform_fee_usd_per_hour) × assumed_utilization - electricity_usd_per_hour`.
- `raw_score` is for ranking only and includes `demand_weight`; the transcript must still say the result is an estimate, not guaranteed realized earnings.

## 5. Eligibility gates (mandatory pre-filter)

A row is eligible only if every gate passes:

1. `recommendable == true` in `demand-rank.json`.
2. `hardware_fits(model, mac)` passes.
3. `local_autotune_passes(model, mac)` passes.
4. The candidate catalog row has `runtime_status == "recommendable"`.
5. The coordinator rate card has a row for the model either verbatim or through `normalizeModelKey`, using the recommendation-specific no-default lookup from §3.3.

`hardware_fits(model, mac)` rules:

- v0.1 uses a fixed `safety_margin_gb = 4`.
- The signed candidate catalog must expose `model.min_ram_gb` as the resident-fit floor excluding this safety margin.
- The RAM headroom check is `model.min_ram_gb <= mac.ram_gb - safety_margin_gb`.
- The signed candidate catalog must expose `min_bandwidth_tier`. Dense 32B/70B and developer dense rows must honor their tier gates; small-active MoE rows may pass on Tier-C when RAM and local probes pass.
- Unknown hardware tier is treated as `C`; `min_bandwidth_tier` comparison uses the §3.1 order `S >= A >= B >= C`.

`local_autotune_passes(model, mac)` rules (v0.1 rules with v0.2 amendments applied — see change log v0.2 point 1):

- `sustained_tps >= model.bench_gate.min_sustained_tps` **[v0.2 amendment: advisory; missing emits `tps_below_gate` warning but does not veto eligibility]**.
- `ttft_ms <= model.bench_gate.max_4k_ttft_ms` **[v0.2 amendment: advisory; missing emits `ttft_above_gate` warning but does not veto eligibility]**.
- `swap_detected == false` **[v0.2 amendment (originally shipped v1.7.6): advisory; observed swap emits `swap_observed_under_load` warning but does not veto eligibility]**.
- `thermal_throttle_detected == false` **[unchanged from v0.1: hard block; the ONLY runtime hard eligibility gate in v0.2]**.
- The candidate benchmark must be from the current `benchmark_id` or from a cached run whose candidate catalog hash, binary version, model ID, and HMAC-derived hardware identity hash match and whose `generated_at` is no older than 7 days.

The real financial gate in v0.2 is `expected_net_usd_per_hour >= $0.0050/hr` (§7). If no rows clear that threshold, or if `thermal_throttle_detected == true` on all rows, `autotune --recommend` must emit no paid recommendation, JSON `recommended_model = null`, and the donor-tier transcript in §7.2.

## 6. Output JSON contract (`autotune --recommend`)

`autotune --recommend --json` MUST emit deterministic field order exactly as shown below. Unknown optional data uses `null`; fields are not reordered, renamed, or omitted in v0.1.

```json
{
  "schema_version": "autotune_recommend.v1",
  "generated_at": "<RFC3339>",
  "hardware": {
    "machine": null,
    "chip": "<string>",
    "memory_gb": 0,
    "bandwidth_tier": "C",
    "detected": true,
    "os_version": "<string>",
    "binary_version": "<string>"
  },
  "inputs": {
    "rate_card_version": "<string>",
    "demand_rank_version": "<string>",
    "candidate_catalog_version": "<string>",
    "electricity_usd_per_kwh": null,
    "assumed_utilization": 1.0,
    "availability_hours_per_day": 24
  },
  "recommended_model": "<model_key-or-null>",
  "candidates": [
    {
      "rank": 1,
      "model": "<model_key>",
      "eligible": true,
      "expected_gross_usd_per_hour": 0.0,
      "expected_net_usd_per_hour": 0.0,
      "electricity_usd_per_hour": null,
      "platform_fee_usd_per_hour": 0.0,
      "tokens_per_second": 0.0,
      "memory_headroom_gb": 0.0,
      "confidence": "low",
      "why": "<one-line reason>"
    }
  ],
  "comparison": {
    "default_model": "<model_key-or-null>",
    "recommended_delta_usd_per_hour": 0.0,
    "recommended_delta_percent": 0.0
  },
  "warnings": []
}
```

Schema rules:

- `schema_version` is exactly `autotune_recommend.v1`.
- `generated_at` is RFC3339 UTC.
- `hardware.memory_gb` is an integer greater than or equal to `1`.
- `hardware.bandwidth_tier` is one of `S`, `A`, `B`, `C`, or `unknown`.
- `inputs.electricity_usd_per_kwh` is `null` unless the operator supplied it or the CLI has an explicit configured default. When `null`, candidate `electricity_usd_per_hour` is also `null`, electricity is omitted from net calculation, and `warnings[]` includes `electricity_not_included`.
- `inputs.assumed_utilization` defaults to `1.0` and is in `[0.0, 1.0]`.
- `inputs.availability_hours_per_day` defaults to `24` and is in `[0, 24]`.
- `recommended_model` is a model key string only when a paid recommendation clears all §5 gates and `expected_net_usd_per_hour >= 0.0050`; otherwise it is `null`.
- `candidates[]` default length is at most 5. It is sorted by eligibility first, then `raw_score` descending, then `model` lexicographically for deterministic ties.
- `expected_*_usd_per_hour`, `platform_fee_usd_per_hour`, `tokens_per_second`, and `memory_headroom_gb` are rounded to 6 decimal places in JSON.
- `confidence` is:
  - `high` when rate-card fetch, signed demand-rank fetch, signed candidate-catalog fetch, current local benchmark, no-swap, and no-thermal checks all used live/current data.
  - `medium` when rate card, demand rank, or candidate catalog used a valid baked fallback, or the benchmark used a valid cache.
  - `low` when both market inputs used baked fallback, hardware tier is unknown, or any non-fatal diagnostic warning affects the recommended row.
- `why` is a single line under 140 characters, contains no newline, and must not promise realized buyer demand.
- `warnings[]` is an array of stable machine-readable strings, sorted lexicographically. v0.1 warning vocabulary is: `candidate_catalog_fallback_used`, `candidate_catalog_stale`, `demand_rank_fallback_used`, `demand_rank_stale`, `electricity_not_included`, `hardware_tier_unknown`, `rate_card_fallback_used`, `recommendation_below_threshold`, `no_eligible_paid_model`.

## 7. Install transcript copy (locked text)

All `$/hr` human transcript values MUST render as `$%.4f/hr`. The minimum paid-yield threshold is `$0.0050/hr` after provider share, assumed utilization, and available electricity adjustment.

### 7.1 Happy path

Use this text verbatim, replacing braces with computed values:

```text
Detected {machine_or_chip}, {memory_gb} GB unified memory, Tier {bandwidth_tier}.
Benchmarked {benchmarked_count} compatible models against rate card {rate_card_version} and demand rank {demand_rank_version}.

Recommended: {recommended_model}
Expected net capacity: {expected_net_usd_per_hour}/hr at {assumed_utilization_percent}% utilization
Why: {recommended_delta_usd_per_hour}/hr vs default {default_model}; {memory_headroom_gb} GB memory headroom

This is an estimate, not a guarantee. Actual earnings depend on buyer demand, uptime, thermal state, electricity, and rate-card changes.

Start provider with {recommended_model}? [Y/n]
```

Happy path applies only when at least one recommendable model is eligible and the selected recommendation has `expected_net_usd_per_hour >= 0.0050`.

### 7.2 Donor-tier path

Use this text verbatim, replacing braces with computed values:

```text
Detected {machine_or_chip}, {memory_gb} GB unified memory, Tier {bandwidth_tier}.
No paid model currently clears the minimum net-yield threshold of $0.0050/hr.

Best compatible option: {best_compatible_model}
Expected net capacity: {expected_net_range_or_value}/hr before demand risk
Recommendation: donor mode only

You can keep this Mac configured for donor-mode testing, but it is not expected to earn meaningful revenue on the current rate card.
Enable donor mode? [y/N]
```

Donor-tier path applies when no recommendable model has `expected_net_usd_per_hour >= 0.0050` or no row passes all §5 gates.

## 8. Donor-mode UX

v0.1 locks an explicit local donor-mode override:

- CLI flag: `--donor-mode` as a boolean flag on the configuration/apply path.
- YAML config: `donor_mode: true` as a boolean.
- Install prompt default: No (`[y/N]`).

When `donor_mode == true`:

- The CLI may skip only the paid-yield threshold and demand-rank `recommendable == true` default-selection gate.
- The CLI MUST NOT bypass signed candidate-catalog presence, immutable model revision, canonical artifact-set digest check, `runtime_status != "blocked"`, model ID allowlist, RAM headroom, no-swap, no-thermal, or runtime-support gates.
- A donor-mode row must have signed candidate metadata with `runtime_status` equal to `candidate`, `listed`, or `recommendable`; `blocked` rows remain forbidden.
- SPEC-023 does not add coordinator/gateway donor-routing or settlement behavior. Applying donor mode may write local config and status only; it MUST NOT auto-start or auto-register a network-connected paid provider for a non-recommendable donor row. Network-connected donor serving requires a separate donor-routing/settlement spec or build prerequisite.
- The CLI must print an explicit warning before commit:

```text
DONOR MODE: {selected_model} is estimated to earn {delta_usd_per_hour}/hr less than the recommended model on this Mac.
```

- When no paid recommendation exists, use:

```text
DONOR MODE: no paid model clears $0.0050/hr on this Mac; {selected_model} is for network support only.
```

- `macprovider-cli status` must show a `DONOR MODE` badge alongside the configured model while `donor_mode: true`.

## 9. Re-tune cadence + UX

`autotune --recommend` re-runs or prompts the operator in exactly these v0.1 cases:

1. Manual invocation: `macprovider-cli autotune --recommend`.
2. `macprovider-cli update` or installer rerun after install, when the live rate-card version, live demand-rank version, signed candidate-catalog version/hash, binary version, stable hardware identity hash, or benchmark age differs from stored recommendation state.
3. Installer rerun when no stored recommendation exists.

v0.1 explicitly does not re-run automatically on coordinator SIGHUP or rate-card hot reload. Coordinator broadcast of recommendation changes is deferred to v0.2.

The CLI stores the last recommendation result at:

```text
~/.config/macprovider/last-recommendation.json
```

Stored state MUST include at least:

```json
{
  "generated_at": "<RFC3339>",
  "rate_card_version": "<string>",
  "demand_rank_version": "<string>",
  "candidate_catalog_version": "<string>",
  "candidate_catalog_sha256": "<hex>",
  "benchmark_id": "<string-or-null>",
  "benchmark_generated_at": "<RFC3339-or-null>",
  "binary_version": "<string>",
  "hardware_identity_hash": "<hex>",
  "recommended_model": "<model_key-or-null>"
}
```

`hardware_identity_hash` is an HMAC-SHA256-derived local identity hash. It MUST NOT be a raw serial number, MAC address, device UUID, or unhashed hardware fingerprint.

Stored hash/version derivation:

- `candidate_catalog_sha256` is the lowercase hex SHA-256 over the exact selected catalog JSON bytes after fetched/baked selection and before parsing normalization.
- `rate_card_version` is the `/v1/rate-card.version` recommendation-projection hash from §3.3. It MUST NOT reuse broader coordinator config or billing snapshot hashes that include unrelated ledger, quarantine, request-log, operator, or settlement state.
- `demand_rank_version` is the selected demand-rank JSON `version`; v0.1 does not require an additional stored demand-rank hash.

`macprovider-cli status` MUST emit a stale-recommendation warning when the live rate-card version, demand-rank version, candidate-catalog version/hash, binary version, stable hardware identity hash, or benchmark freshness differs from this stored state:

```text
Recommendation stale: recommendation inputs changed since {generated_at}.
Run: macprovider-cli autotune --recommend
```

## 10. Goodhart mitigations

| ID | Mitigation | SPEC-023 implementation |
|---|---|---|
| M1 | Deterministic diversification | §4 defines `recommendation_pool` as all eligible rows within 85% of best score and `stable_hash(...) % len(pool)`. |
| M3 | Cold-start floor | §3.4 and §4 lock `cold_start_floor = 0.15` and `max(demand_weight, cold_start_floor)`. |
| M4 | Row lifecycle states | §3.2 and §3.4 lock `runtime_status` and `recommendable`; §5 requires both before default recommendations. |
| M7 | Rate-card version binding | §3.3, §6, and §9 persist `rate_card_version`. |
| M8 | Retune hint | §9 defines upgrade/manual triggers and stale status text. |
| M12 | Hard eligibility gates | §5 requires RAM, benchmark, no-swap, no-thermal, and rate-card gates before scoring. |
| M16 | Deployability gate | §3.2 and §3.4 define deployability via `runtime_status` + `recommendable`; §5 enforces both. |
| M18 | Full-utilization wording | §4 separates ranking from displayed capacity; §7 says "estimate, not a guarantee." |
| M20 | Static JSON demand control plane | §3.4 requires `get.streamvc.live/demand-rank.json` with baked fallback and version metadata. |

## 11. Acceptance criteria

AC-1: `macprovider-cli autotune --recommend --json` output validates against `autotune_recommend.v1` for any Mac where `MachineFingerprinter.sample()` returns at least `ram_gb = 1`.

AC-2: JSON field order is deterministic and matches §6 exactly for stable diffs and snapshot tests.

AC-3: When all rows fail eligibility, JSON emits `recommended_model = null`, warnings include `no_eligible_paid_model`, and human output uses the §7.2 donor-tier transcript.

AC-4: When `https://get.streamvc.live/demand-rank.json` returns 404, times out, fails schema validation, fails Ed25519 detached-signature validation, is older than the baked snapshot, is more than 10 minutes in the future, or is more than 30 days old, the CLI falls back to the baked demand-rank snapshot and emits `demand_rank_fallback_used`.

AC-5: When `/v1/rate-card` cannot be fetched, the CLI falls back to the baked rate-card snapshot and emits `rate_card_fallback_used`.

AC-6: When `https://get.streamvc.live/autotune-candidates.json` returns 404, times out, fails schema validation, fails Ed25519 detached-signature validation, is older than the baked snapshot, is more than 10 minutes in the future, or is more than 30 days old, the CLI falls back to the baked candidate catalog and emits `candidate_catalog_fallback_used`.

AC-7: `stable_hash(diversification_id) % len(pool)` produces the same recommendation for the same stable input and same pool across repeated runs.

AC-8: For a pool length of at least 3, a deterministic-hash distribution test over 100 synthetic provider IDs selects at least 2 distinct models.

AC-9: Rows outside the 85% diversification band are not chosen as `recommended_model` unless all higher rows become ineligible.

AC-10: A row with demand `recommendable: false` or candidate `runtime_status != "recommendable"` is never selected as the paid default recommendation.

AC-11: A row whose `model.min_ram_gb > mac.ram_gb - 4` fails `hardware_fits` and is not benchmarked. v0.1 has no arbitrary local-model or custom donor-mode path override; any donor-mode selection must still select a row from the signed selected candidate catalog and pass §3.2, §5, §8, and AC-22 controls.

AC-12 **[amended v0.2]**: A row whose local benchmark records `thermal_throttle_detected == true` fails eligibility (hard block). A row whose local benchmark records `swap_detected == true` emits `swap_observed_under_load` warning but does NOT fail eligibility on that basis alone; the `expected_net_usd_per_hour >= $0.0050/hr` financial gate remains the paid-vs-donor arbiter.

AC-13 **[amended v0.2]**: A row whose benchmark misses `min_sustained_tps` or `max_4k_ttft_ms` emits `tps_below_gate` / `ttft_above_gate` warnings but does NOT fail eligibility on that basis alone. See change log v0.2 point 1 for the rationale (M-Base hardware had every candidate net-positive but hard-blocked by M-Pro/M-Max-calibrated gates).

AC-14: A buyer/model string that matches the rate-card only after `normalizeModelKey` is treated as rate-card-enabled and records the normalized key in the candidate model field.

AC-15: A candidate that would match only the coordinator `default` rate-card row is not rate-card-enabled for recommendation and cannot become `recommended_model`.

AC-16: Missing candidate metadata, missing immutable `model_revision`, or missing canonical `model_sha256` for a demand/rate-card row makes the row ineligible before model download or benchmark.

AC-17: Missing electricity input leaves `electricity_usd_per_kwh = null`, `electricity_usd_per_hour = null`, omits electricity from `expected_net_usd_per_hour`, and emits `electricity_not_included`.

AC-18: Supplied electricity input subtracts estimated electricity cost from `expected_net_usd_per_hour` and removes `electricity_not_included`.

AC-19: A selected row with `expected_net_usd_per_hour < 0.0050` emits `recommended_model = null`, `recommendation_below_threshold`, and the §7.2 donor-tier transcript.

AC-20: The happy-path transcript exactly matches §7.1 with `$%.4f/hr` formatting.

AC-21: The donor-tier transcript exactly matches §7.2 with threshold `$0.0050/hr` and prompt default No.

AC-22 **[amended v0.2]**: `--donor-mode` allows a non-recommendable or below-threshold model to be locally committed only after printing the §8 warning, writing `donor_mode: true`, and verifying signed catalog metadata, immutable model revision, canonical artifact-set digest, `runtime_status != "blocked"`, model allowlist, RAM headroom, no-thermal-throttle, and runtime support. Swap and TPS/TTFT gates are advisory per AC-12/AC-13 amendments; observing them emits warnings but does not block donor-mode commit.

AC-23: Applying donor mode for a non-recommendable row does not auto-start or auto-register a network-connected paid provider. Any network-connected donor serving is blocked until a separate donor-routing/settlement prerequisite exists.

AC-24: `macprovider-cli status` shows `DONOR MODE` when `donor_mode: true`.

AC-25: `macprovider-cli update` and installer rerun compare stored `rate_card_version`, `demand_rank_version`, `candidate_catalog_version/hash`, `binary_version`, `hardware_identity_hash`, and benchmark age with live/current values and prompt re-tune when any changed or expired.

AC-26: `macprovider-cli status` emits the stale-recommendation warning in §9 when stored recommendation metadata differs from live metadata.

AC-27: The recommendation cache at `~/.config/macprovider/last-recommendation.json` is written after a successful recommendation and contains every field listed in §9 stored state.

AC-28: Raw hardware fingerprints, serial numbers, MAC addresses, device UUIDs, and the local HMAC secret do not appear in JSON output, logs, warnings, support bundles, or `last-recommendation.json`; only domain-separated HMAC-derived identifiers are persisted.

AC-29: Human output never states or implies guaranteed earnings; it uses "Expected net capacity" and the exact estimate disclaimer from §7.

AC-30: v0.1 implementation does not add or require a coordinator `/v1/demand-signal` endpoint, provider quota policy, or automatic model switch.

AC-31: Static JSON whose `generated_at` is more than 10 minutes in the future relative to the local clock falls back to the baked snapshot and emits the matching fallback warning.

AC-32: A non-`blocked` candidate catalog row without immutable `model_revision` or without canonical `model_sha256` is not downloaded, benchmarked, recommended, or locally committed in donor mode.

AC-33: The local HMAC secret is generated with a CSPRNG, stored in Keychain or a `0600` local file, never emitted outside the host, and uses separate domain labels for diversification and recommendation-cache identity.

AC-34: After downloading a model by immutable `model_revision`, the CLI computes the canonical artifact-set hash exactly as specified in §3.2 and fails closed before benchmark, recommendation, local donor-mode commit, or provider run when it differs from catalog `model_sha256`.

AC-35: Bandwidth-tier eligibility is deterministic: a Tier-C Mac fails a row with `min_bandwidth_tier = "A"` when all other gates pass, while a Tier-A or Tier-S Mac passes that row when all other gates pass.

AC-36: A downloaded model snapshot containing symlinks, hardlinks with link count greater than one, special files, absolute paths, path escapes, or `..` path segments fails artifact verification before benchmark, recommendation, local donor-mode commit, or provider run.

AC-37: Unauthenticated `GET https://coordinator.streamvc.live/v1/rate-card` reaches the coordinator buyer mux through nginx and returns the §3.3 schema; the nginx route is declared before the generic `/v1/` 404 block.

AC-38: `rate_card_version` changes when the recommendation projection rows, provider share, global multiplier, or `usd_per_million_credits` change, and does not change when unrelated quarantine, request-log, operator, ledger runtime, or settlement runtime state changes.

AC-39: `candidate_catalog_sha256` is computed over the exact selected catalog JSON bytes, so changing catalog whitespace changes the stored hash while preserving schema validation behavior.

## 12. Open questions / v0.2 candidates

Q1: Live coordinator `/v1/demand-signal` endpoint and switch trigger. v0.2 may use local attempted-demand stats only after at least 60 days history, 50M paid or auth-valid requested completion-token equivalent, 5 buyer accounts or partner keys with non-test traffic, and no single buyer contributing more than 50% of model demand.

Q2: Tier-specific `tier_weight` calibration. v0.1 locks all tier weights to `1.0`.

Q3: Provider TPS reputation downweighting from production traffic.

Q4: Utilization-adjusted realized-earnings projection once buyer history exists.

Q5: Coordinator broadcast of "recommendation changed" on hot reload, with provider auto-prompt.

Q6: Per-provider quota / coverage allocation policy.

Q7: Collusion detection / cartel monitoring.

Q8: Cross-Mac transfer of recommendation, such as an operator cloning config to a second Mac.

Q9: Donor-mode time-limited grant of token rewards and any `TOKEN_NAME` ledger interaction.

Q10: Static JSON key rotation policy after the release-pinned Ed25519 v0.1 key ages out.

Q11: How to represent model quality and buyer-acceptance scores without creating a new Goodhart target.

Q12: Whether minimum provider coverage targets should become an active recommendation input once provider-count telemetry exists.

## 13. Differentiation framing

macprovider's provider-install UX sits in a gap left by most decentralized GPU networks. Vast, RunPod, io.net, Akash, Aethir, Render, and Bittensor generally expose raw capacity, bids, node eligibility, subnet incentives, or buyer-selected workloads; their public provider flows do not show an installer-time recommendation that says "given this hardware, run this model to earn the most." That difference follows from their market structure: the buyer brings a container, manifest, render job, or subnet task, while the provider supplies capacity or competes under a protocol.

The closest competitive exception is Darkbloom. Its public pages show an Apple-Silicon inference network, a CLI provider install path, and an earnings calculator that auto-selects the "most profitable" model for a chosen Mac hardware profile. macprovider should not claim the whole idea is unobserved. The sharper wedge is that SPEC-023 makes the recommendation local, installer-integrated, benchmark-backed, and machine-readable via `autotune --recommend`, rather than only a web estimate.

The right UX lineage is not generic cloud hosting. It is staking calculators and mining profitability calculators: ranked yield options, transparent assumptions, power/rate inputs, confidence, and stale-data warnings. macprovider has the same shape: detected hardware plus measured tokens/sec plus a per-model rate card plus demand assumptions yields a ranked recommendation.

This will not create demand where none exists. SPEC-023 answers "which model should this provider run, given known rates and measured local performance?" It does not answer "will buyers show up?" The UX must say that clearly: expected `$/hr` is an estimate conditioned on demand, utilization, uptime, electricity, and the current rate card.

## 14. Threat model

| Threat | Capability | v0.1 defense | Deferred |
|---|---|---|---|
| Static JSON tampering | DNS, CDN, or static-host compromise attempts to alter demand weights, `recommendable`, or candidate gates | §3.5 Ed25519 detached signatures, release-pinned public key, fallback to baked snapshot on invalid/missing/stale signed data | Key rotation automation in v0.2 |
| Static JSON replay | Attacker serves an old but once-valid static file | §3.5 rejects files older than baked snapshot and files older than 30 days; 14-30 days emits `demand_rank_stale` or `candidate_catalog_stale` | Transparency log or monotonic operator epoch in v0.2 |
| Untrusted candidate metadata or mutable model artifact | Malicious metadata points to oversized/unsafe model, weak gates, or a mutable model-host branch that changes after signing | §3.2 signed candidate catalog, allowlisted model IDs, immutable `model_revision`, required canonical `model_sha256`, and missing metadata/digest fail-closed before download/benchmark | Richer artifact transparency log in v0.2 |
| Provider benchmark gaming | Provider optimizes or tampers with local benchmark | §5 requires CLI-owned benchmark, sustained TPS, TTFT, no-swap, no-thermal checks; production TPS reputation deferred | Coordinator production feedback in v0.2 |
| Donor-mode abuse | Operator commits non-recommendable row and receives paid buyer traffic | §8 keeps donor mode local-only for non-recommendable rows and blocks network-connected paid registration until a separate donor-routing/settlement prerequisite exists | Explicit donor traffic class or rewards policy in v0.2 |
| Fingerprint leakage | Stable hardware identity links provider across runs or support bundles | §3.1 and §9 require per-install-secret, domain-separated HMAC-derived identities only; AC-28 and AC-33 ban raw fingerprints and HMAC secrets in persisted/output paths | Formal privacy review if identities become network-visible |
| Misleading earnings claims | Provider interprets capacity as guaranteed realized income | §4 separates ranking score from displayed capacity; §7 locks estimate disclaimer; AC-29 enforces wording | Utilization-adjusted realized projection in v0.2 |
| Clean-room violation | Competitive framing accidentally depends on Darkbloom source | §2 and §13 restrict Darkbloom references to public surfaces only | None; source inspection remains prohibited |
