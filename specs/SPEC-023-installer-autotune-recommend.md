# SPEC-023 — Installer-Integrated Autotune Recommend

version: v0.9.3
status: LOCKED
owner: operator (a11)
last-locked: 2026-08-02

## Change log

- **v0.9.3 (2026-08-02)** — oMLX activation-gate hardening (#687, r5 convergence).
  1. **Provenance-erasure laundering closed.** The §12.2 activation gate now bans deriving a catalog row from oMLX data in ANY form before activation — not only the `omlx_seeded` schema but any value laundered into a `policy` / `measured_single_host` / other provenance label with `gate_seed` stripped. Authoring-process prohibition (AC-OMLX-16), plus an immutable provenance-lineage Stage-2 prerequisite §12.2(b)(v) so post-activation detection is possible.
  2. **Admission-subset digest defined.** New §3.6 defines `admission_policy_sha256`, a digest over the catalog EXCLUDING `bench_gate.min_sustained_tps`, `max_4k_ttft_ms`, `provenance`, and `gate_seed`. SPEC-032 verified-evidence admission matching uses THAT subset digest, not the full `candidate_catalog_sha256` (which stays cache/update-integrity only). This resolves the SPEC-032 admission self-contradiction and protects verified admission from advisory-only edits.
  3. **Quarantine phase-qualified.** §12.3/§3.5/AC-OMLX-2/AC-OMLX-10/AC-OMLX-15 now split by activation: PRE-activation any oMLX schema in a served catalog is globally fail-closed (the gate); POST-activation a per-row semantic oMLX error decodes successfully and quarantines ONLY that row. Whole-catalog `candidate_catalog_integrity_failure` stays reserved for signature, global-schema, and non-oMLX-row failures.
  4. **Docs only.** No Go/Swift code; governance manifest synced to matching versions.

- **v0.9.2 (2026-08-02)** — oMLX Stage-1 activation gate & forward-declaration (#687, r4 re-scope).
  1. **The oMLX schema is FORWARD-DECLARED, not activated.** `bench_gate.provenance.source == "omlx_seeded"`, `bench_gate.gate_seed`, and the `verified_provider_matrix` provenance value MUST NOT be emitted into any signed or served candidate catalog until the §12.2 activation gate is satisfied. This prevents the #813 forward-incompatibility trap: deployed coordinator Go validators and CLI Swift strict decoders would reject the new schema and fail-close the fleet.
  2. **Activation gate (§12.2).** All catalog consumers must accept the new schema without integrity failure (forward-compat), and the Stage-2 enforcement (admission-identity exclusion of advisory `bench_gate`, network-connected `recommendable`-only enforcement, row-scoped quarantine, evidence-bound `verified_provider_matrix` promotion, and immutable provenance lineage) must have shipped. Until then a signed/served catalog MUST NOT contain any `omlx_seeded` row (§12.2, AC-OMLX-11).
  3. **`verified_provider_matrix` is reserved and inert in Stage 1.** Any catalog row created or modified with `provenance.source == "verified_provider_matrix"` MUST be rejected at authoring/lint/signing; no such row may exist until Stage-2 evidence binding exists (AC-OMLX-12).
  4. **Field-laundering prohibition.** oMLX data MAY seed ONLY `bench_gate.min_sustained_tps` (plus its `gate_seed` metadata). It MUST NOT create or change `min_ram_gb`, `min_bandwidth_tier`, `runtime_status`, model identity, demand-rank, or rate-card/pricing/admission/routing fields (AC-OMLX-13).
  5. **`gate_seed.target_cell` is row-bound; invalid oMLX rows are row-scoped quarantined.** A seed targeting a different model than its row is a catalog-integrity failure (AC-OMLX-14); a single semantically-invalid oMLX row is row-scoped-quarantined and never fleet-blocking (§12.3, AC-OMLX-15).
  6. **Stage-2 prerequisites are declared, not implemented.** §12.2 lists the coordinator/CLI enforcement (i)-(v) as normative Stage-2 requirements; this amendment ships no Go/Swift code.

- **v0.9.1 (2026-08-02)** — oMLX-seeded provisional catalog gates (#687).
  1. **oMLX seeds are provisional only.** Unattested oMLX data MAY seed the STARTING advisory `bench_gate.min_sustained_tps` of a non-default provisional row only. It MUST NEVER set or hold a recommendable gate, raise a verified gate, hard-block a provider, or be sole or partial promotion evidence. Verified provider autotune is the only admission/promotion authority.
  2. **Promotion depends solely on verified measurements.** Promotion from `listed` to `recommendable` depends solely on `N = 3` verified provider autotune measurements on eligible hardware; the promoted gate is recomputed solely from those measurements, and the oMLX seed is discarded and is NEVER the pass/fail criterion for promotion.
  3. **`K` is an intra-cell observation count.** `K = 10` is the minimum post-dedup/outlier oMLX observation count WITHIN one normalized chip/RAM/model/quant/context cell (per `RESEARCH_231`'s ≥10-observations-per-cell percentile-reliability threshold), recorded as `gate_seed.observations_used_n`.
  4. **Catalog provenance is extended and laundering is fail-closed.** `bench_gate.provenance.source` gains `omlx_seeded` and `verified_provider_matrix`; `bench_gate.gate_seed` is REQUIRED on `omlx_seeded` rows and a catalog-integrity failure on any other row.
  5. **Cross-spec.** SPEC-032 no longer hard-gates admission on the advisory `bench_gate` drift targets; see SPEC-032 FR-HG3/FR-HG4 and §5/§12 below.
  6. **No Stage 2+ behavior ships here.** This is a Stage-1 normative governance change; it does not change catalog rows, implementation code, snapshot ingestion, pricing, or promotion automation. The concrete evidence-record (verified-measurement IDs), catalog generation, and promotion automation are deferred to a later stage.

- **v0.9.0 (2026-07-31)** — Swap veto redefined as sustained memory-pressure thrash.
  1. **`swap_detected` now means sustained CRITICAL memory pressure, not any pageout.** The signal is the macOS kernel memory-pressure verdict (`kern.memorystatus_vm_pressure_level`: 1 = Normal, 2 = Warning, 4 = Critical), read in-process across the probe. It replaces the machine-wide cumulative `Pageouts` counter, which on Apple Silicon counts healthy memory compression and is not process-scoped, so any incidental system paging during the probe flipped the old flag and false-rejected legitimate small-model providers (e.g. an 8 GB Mac on llama-3.2-3b).
  2. **Interval sampling.** The CLI samples the pressure level (and thermal state) as a SERIES at a fixed ~250 ms interval for the duration of the Stage 1 probe, plus one synchronous sample at probe start and one after the probe returns (always ≥2 samples). `swap_detected == true` only when at least 2 samples are Critical AND Critical readings are ≥50% of the readable (non-Unknown) samples. A genuinely thrashing node (the 32 GB M5 / #742 incident) still fails paid eligibility, including short probes that collect only the two synchronous samples.
  3. **Advisory WARNING-majority.** When at least 2 samples are Warning and Warning readings are ≥50% of the readable samples (without a Critical majority), `swap_detected` stays false and the CLI records an advisory `swap_observed_under_load` observation in local probe-safety telemetry; it does NOT block the paid path.
  4. **Fail-closed narrowed.** `swap_detected` fails closed to true only when the pressure level could not be read for the ENTIRE series (every sample unknown). A single transient unknown/warning sample MUST NOT veto the paid path.
  5. **No wire/schema change.** The `swap_detected` boolean field name, the candidate-benchmark shape, and the coordinator-facing evidence schema are unchanged; only the field's meaning tightens.

- **v0.8.6 (2026-07-29)** — Signed rate-card feed (B10).
  1. **Rate-card live bytes are signed.** `/v1/rate-card` is served from literal verified static bytes when configured, and `/v1/rate-card.sig` is a detached Ed25519 sidecar over those exact bytes.
  2. **Paid recommendation fails closed on rate-card trust failures.** Missing/malformed sidecars, unknown signers, bad signatures, schema failures, policy mismatch, stale/future/expired live bytes, or valid older-than-baked bytes fall back locally and emit rate-card integrity/update warnings that block paid recommendation.
  3. **The release manifest binds rate-card bytes.** `rate-card.json` is a first-class SPEC-023 feed member with its own projection-hash `version`, separate from the catalog release ID.

- **v0.8.5 (2026-07-29)** — A4 signed in-band provenance catalog release.
  1. **Current signed catalog carries explicit provenance.** The current release is `published-2026-07-29-inband-provenance-v1`; every `bench_gate` object in the signed candidate catalog includes machine-readable `provenance`.
  2. **Nil-provenance is retired for current releases.** Catalog-release verification, direct CLI catalog decoding, and current coordinator feed loading fail closed when `bench_gate.provenance` is absent. The exact signed July 10 recovery release remains a transition-only compatibility input for pre-activation live fetches and `previous-target` rollback loading; it is pinned by release id plus SHA-256 and MUST NOT generalize to new releases.
  3. **No new benchmark authority.** A4 signs the existing #744 provenance classifications in-band; it does not promote gate values to trusted post-#745 provider-run measurements.

- **v0.8.4 (2026-07-29)** — A2 signature-caveat reconciliation.
  1. **Catalog signature proof is bounded.** §3.2 now names exactly what the signed candidate catalog proves and what it does not prove, mirroring the SPEC-015 negative-list pattern.
  2. **No new trust authority.** The caveat does not change row eligibility, scoring, catalog bytes, signature verification, or coordinator admission behavior.

- **v0.8.3 (2026-07-29)** — Signed candidate-catalog row reconciliation (A8).
  1. **The normative row table follows the signed candidate catalog.** The §3.2 row table recorded the then-current `published-2026-07-10-catalog-recovery-v1` candidate catalog rows and gate values from `phase3-binary/dist/static/autotune-candidates.json`, which matched Pearl's live `/v1/autotune-candidates` bytes at the time.
  2. **Serving catalog reality is authoritative for row state.** All rows in that signed candidate catalog were `recommendable`; `qwen3-32b`, `qwen2.5-coder-32b-instruct`, and `google-gemma-4-26b-a4b-it` no longer retained the older `listed` / `blocked` table states.
  3. **The baked/live drift note is superseded.** The v0.2 historical baked/live divergence is no longer normative for the current release artifacts; the committed baked copy and served `/v1` candidate catalog are reconciled.

- **v0.8.2 (2026-07-29)** — Human transcript label honesty (A6).
  1. **Human transcript carries the same trust hints as JSON.** The happy-path transcript MUST print confidence, bench-gate provenance, and bench-gate drift for the selected recommendation.
  2. **Benchmarked count means local benchmark results.** The transcript count is the number of local benchmark result rows in the recommendation result, not the number of rendered eligible candidates.
  3. **Donor copy no longer names the deleted hourly gate.** Donor-mode fallback text MUST NOT reference the superseded hourly threshold.

- **v0.8.1 (2026-07-28)** — Default-tier fresh-install recovery (#786).
  1. **Coordinator default-rate semantics are restored for recommendation.** When exact and normalized rate-card lookup miss but the projection carries `rows.default`, the candidate remains rate-card-enabled and is priced against `default`.
  2. **The served model stays the catalog model.** The `default` row is only the pricing row; `recommended_model` / selected candidate model stay on the catalog key so the provider loads the intended snapshot.
  3. **Fallback is visible.** Recommendations that use this pricing fallback emit `rate_card_default_tier_used`. Specific exact or normalized rows still win and do not emit the warning.

- **v0.8 (2026-07-26)** — Selection-quality amendment (#744).
  1. **Paid ranking is measured earning opportunity per second.** §4 preserves v0.6 buyer-coverage economics and makes throughput part of `raw_score`, not a tiebreaker: provider completion payout × locally measured sustained TPS × demand floor/weight × bounded supply-deficit multiplier.
  2. **Buyer TTFT ceiling is separate from catalog drift.** `--buyer-ttft-ceiling-ms` is an operator-set paid recommendation ceiling. Values `>0` hard-veto paid rows whose measured p95 TTFT exceeds the ceiling and emit `buyer_ttft_ceiling_exceeded` when that leaves no eligible paid row. `0` disables it. This does not restore the old `--gate-ttft-ms` default; omitted `--gate-ttft-ms` on `--recommend` remains disabled.
  3. **`bench_gate` provenance is machine-readable.** Candidate catalog `bench_gate` now carries `provenance.source` plus optional `hardware`, `measured_at`, and `notes`. Current release values remain advisory drift signals unless/until promoted from trusted post-#745 provider runs.
  4. **Candidate JSON exposes drift.** Each candidate includes `bench_gate_provenance`, `bench_gate_drift`, and `buyer_ttft_ceiling_exceeded` so support tooling can distinguish bad catalog expectations from buyer-facing selection vetoes.
  5. **Static signer rotation is bridged, not activated.** At v0.8 publication time, the active v4 signing material was unavailable to that release session, so the v5 public key was release-pinned in the trusted keyring with bridge status while the live feed remained signed by `streamvc-autotune-static-v4`. A4 later published the in-band provenance release with the active v4 signer; the first v5-signed feed remains a separate activation after bridge adoption.

- **v0.7 (2026-07-25)** — Swap is a paid-path hard eligibility veto (#742).
  1. **`swap_detected == true` disqualifies paid recommendation.** Swap is a locally measured fact about the provider machine. **[amended v0.9: the signal is sustained CRITICAL memory pressure — ≥2 samples of `kern.memorystatus_vm_pressure_level` across the probe reading Critical AND Critical forming ≥50% of the readable samples — not the old machine-wide `Pageouts` delta.]** It needs no catalog threshold and applies on hardware never benchmarked in advance. A thrashing row MUST NOT become `recommended_model`.
  2. **§4 scoring untouched.** Ranking, demand weight, and payout-first order are unchanged; only §5 eligibility gains the swap gate.
  3. **Donor mode keeps swap advisory.** When no non-swapping paid row exists, the CLI falls to donor mode and MUST name swap in the transcript / candidate `why` / `swap_observed_under_load` warning. Donor commit still admits a swapping row when other donor gates pass.
  4. **No 60 s TTFT feasibility default on the paid path.** `autotune --recommend` MUST NOT default its probe TTFT ceiling to 60_000 ms. Omitting `--gate-ttft-ms` on `--recommend` disables that ceiling (`0`). Classic (non-recommend) Stage 1/2 retains the SPEC-013 60_000 ms default when the flag is omitted. Catalog `bench_gate` TPS/TTFT fields remain advisory.

- **v0.6 (2026-07-10)** — Catalog recovery, trust-state separation, and buyer-coverage scoring.
  1. **One release unit.** Candidate and demand JSON, exact-byte SHA-256 digests, detached signatures, trusted verifier keyring, baked Swift payload, and release manifest are generated and verified from one canonical release directory. Candidate and demand feeds in one release share `version`, `generated_at`, and `policy_version`.
  2. **Failure classes no longer collapse.** Transport/HTTP unavailability may use the baked release as `safe_offline_fallback`. Invalid signature, unknown key ID, malformed sidecar, or invalid schema emits an integrity warning; a valid but incompatible/older/future/expired feed emits update-required. Integrity and update-required states MUST NOT produce a paid recommendation or coordinator join.
  3. **Rotation bridge.** Clients and coordinators use a release-pinned verifier keyring and may trust v4 and v5 during the rotation window. Unknown key IDs fail closed. Retirement of v4 requires measured fleet adoption of a v5-capable binary, not merely publication of a v5-signed feed.
  4. **Buyer-coverage economics.** Ranking estimates operator earning opportunity as provider completion payout × measured TPS × demand floor/weight × bounded supply-deficit multiplier. Demand rows may carry `ready_provider_count` or an operator-computed `supply_deficit_multiplier`; missing supply data is neutral (`1.0`).
  5. **Buyer-serving state.** Local readiness or coordinator transport alone is insufficient. `buyer_serving` requires a locally ready paid model, a live-verified signed catalog, and an active coordinator admission. Offline fallback and donor modes remain explicitly local/non-buyer-serving.

- **v0.5 (2026-07-06)** — Payout-first scoring for beta supply growth.
  1. **Rank by provider payout, not buyer throughput.** `raw_score` becomes `completion_rate_per_mtok × provider_share` (credits per million completion tokens after the provider split). `demand_weight` and `measured_sustained_tps` are tiebreakers only, in that order, after payout score.
  2. **Remove diversification pool for beta.** v0.4's 85% band + `stable_hash(diversification_id) % len(pool)` pick is deferred until supply exceeds demand. `recommended_model` is the strict highest `raw_score` eligible row; `diversification_id` remains for cache identity only.
  3. **§5 eligibility unchanged.** RAM, bandwidth, thermal, rate-card, catalog, and benchmark gates still run before scoring.
  4. **Transcript copy.** Eligible-row `why` strings describe payout-per-token leadership, not demand-weighted throughput.

- **v0.4 (2026-07-06)** — Rate-card v4 pivot: SPEC-023 moves from hourly net capacity estimates to per-token transcript semantics.
  1. **Drop hourly-net projection.** `expected_net_usd_per_hour`, `assumed_utilization`, and `electricityUSDPerKWH` inputs are removed. Recommendations now use only real measured tokens from provider transcripts.
  2. **Remove paid threshold and starter tier.** The `$0.0050/hr` financial gate, paid vs. starter recommendation tiers, and two-path install transcript logic are superseded. v0.4 scoring uses a single pass: `score = demand_weight × completion_rate_per_mtok × measured_sustained_tps`.
  3. **Per-token payout semantics.** Provider earnings are deterministic real income: `sum(tokens × rate)` where rate is the per-token rate from the current rate card. Install transcript shows one outcome: recommended model or donor-mode fallback.
  4. **New scoring formula.** §4 replaces utility/hourly/utilization terms with token throughput: `score = demand_weight × completion_rate_per_mtok × measured_sustained_tps`. `raw_score` now uses `completion_rate_per_mtok` credits, not USD, for ranking independence from rate-card USD volatility.
  5. **Two outcomes only: recommended / donor.** When at least one row passes §5, the CLI recommends it with per-token rates. When none pass, the donor transcript applies. No starter tier and no `recommendation_tier` JSON field.

- **v0.3 (2026-07-06)** — Issue 411 promotes
  `nvidia/nemotron-3-nano-30b-a3b` from a baked diagnostic row to a
  signed-static, paid-yield candidate. The live demand rank records
  `rank=68`, `demand_weight=0.30`, `recommendable=true`, and
  `min_provider_target=20`; the live candidate catalog pins
  `mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit` at revision
  `832f602eba5d22436c258c1462bdedc5afddb42b` with artifact-set SHA-256
  `1bc78f214f9a042eaeb290b1fa4cb29915df1028f79d8479266349166c40a71f`.
  Because the local v3 signing private key was unavailable during this
  update, the static-feed keypair rotates v3 -> v4. New keyID:
  `streamvc-autotune-static-v4`; new base64 pubkey:
  `zTKDIdMmKKkO1Cgf5OdTzMOytVqW7U8SGsJ9XrzAltU=`.

- **v0.2 (2026-07-03)** — Two-part amendment ratifying the 5 client-side
  fixes shipped between v1.7.5 and v1.7.9 and the accompanying
  autotune-static keypair rotation.
  1. **`min_sustained_tps` and `max_4k_ttft_ms` are advisory QoS
     targets, not hard eligibility gates.** v1.7.9 (PR #335) reclassified
     these fields as soft signals — a benchmark below/above the target
     emits `.tps_below_gate` / `.ttft_above_gate` warnings but does not
     veto the recommendation. `thermalThrottleDetected` remains a hard
     block; the real financial gate stays `expected_net_usd_per_hour ≥
     paidThreshold ($0.005/hr)` **[superseded v0.4: removed per per-token payout pivot]**. `swapDetected` similarly went soft in
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
     unchanged: the client then fetched from `coordinator.streamvc.live/static/*`,
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
     fallback semantics match the intended M-Base UX. At the time of the
     v0.2 amendment, baked and live intentionally drifted on two other axes
     (superseded by v0.8.3's signed-catalog reconciliation): (i) baked kept
     `runtime_status="listed"` (qwen3-32b, qwen2.5-coder-32b) and
     `runtime_status="blocked"` (google-gemma) rows that
     the live feed omits — baked serves as an offline superset for
     correct "listed but not currently sold" and "blocked pending
     migration validation/rate-card rollout" semantics. Nemotron moved to
     the live signed feed in v0.3 after runtime validation and rate-card
     rollout; (ii) baked keeps
     qwen3-32b at `min_sustained_tps=30`
     (M-Max floor) while live sets it to `15` (recommendable to
     M-Pro 48GB) — offline recommendation on a compiled-in fallback
     stays conservative.

- **v0.1 (2026-07-01)** — Initial lock. See §1-§10.

## 1. Mission

`autotune --recommend` scores rate-card-eligible models against the operator's detected Mac hardware, local benchmark results, the current rate card, and an operator-curated demand/supply signal, then recommends the eligible model with the strongest expected operator earning opportunity while preferentially filling buyer-facing supply deficits. It serves every new provider installer and every operator who runs `macprovider-cli autotune --recommend` after install. Wave 0c lands now because beta launch readiness depends on a low-friction install path, a trustworthy catalog, and a first-model choice that improves both operator economics and buyer coverage.

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

|| Field | Type | Source | Rule |
||---|---|---|---|
|| `ram_gb` | integer | `MachineFingerprinter.sample().ramGB` | Rounded unified memory in GiB. Must be at least `1`; unknown hardware is not represented as `0`. |
|| `chip` | string | `MachineFingerprinter.sample().chip` | Apple chip family or `"unknown"`. |
|| `os_version` | string | `MachineFingerprinter.sample().osVersion` | Used only for support/debug output. |
|| `binary_version` | string | `MachineFingerprinter.sample().binaryVersion` | Used for reproducibility and support/debug output. |
|| `bandwidth_tier` | string enum: `S`, `A`, `B`, `C`, `unknown` | derived from chip family / benchmark table | Unknown hardware maps to `C` for eligibility conservatism unless a benchmark-derived tier is available. |
|| `diversification_id` | string | HMAC-SHA256-derived provider ID if configured, otherwise HMAC-SHA256-derived stable machine identity | Input to deterministic diversification. Raw machine fingerprints MUST NOT be persisted, logged, emitted in JSON, included in support bundles, or sent to coordinator/gateway as part of v0.1 recommendation. |
|| `candidate_benchmarks[model_key].sustained_tps` | float | local autotune benchmark | Warm steady-state decode tokens/sec for each candidate. |
|| `candidate_benchmarks[model_key].ttft_ms` | integer | local autotune benchmark | Time to first token under the v0.1 benchmark prompt shape. |
|| `candidate_benchmarks[model_key].swap_detected` | boolean | local probe | **[amended v0.9 / #742]** True means sustained CRITICAL memory pressure across the probe (≥2 samples of `kern.memorystatus_vm_pressure_level` reading Critical AND ≥50% of the readable samples Critical); fails paid eligibility (hard block) and, when it leaves no paid row, emits `swap_observed_under_load`. Advisory Warning-majority is telemetry-only. Field name/type unchanged. Donor mode keeps swap advisory. |
|| `candidate_benchmarks[model_key].thermal_throttle_detected` | boolean | local probe | Thermal throttle during probe fails eligibility. **[unchanged v0.2: hard block]** |

HMAC identity rules:

- The HMAC key MUST be a per-install local secret generated with a CSPRNG during first setup.
- The secret MUST be stored only in a local protected store: macOS Keychain when available, otherwise a root/operator-readable file with `0600` permissions under the macprovider config directory.
- The secret MUST NOT be sent to coordinator/gateway, emitted in JSON, logged, included in support bundles, or copied into `last-recommendation.json`.
- Diversification and cache identity MUST use separate domain labels, at minimum `macprovider-autotune-diversification-v1` and `macprovider-autotune-cache-identity-v1`, before HMAC-SHA256.
- If the local secret is missing or unreadable, the CLI MUST create a new secret and mark any prior recommendation cache stale because the derived identity changed.

Bandwidth tier rules:

- Tier order is `S >= A >= B >= C`; `unknown` is treated as `C` for eligibility.
- v0.1 derives `bandwidth_tier` from the normalized `chip` string before benchmark overrides:

|| Chip family match | bandwidth_tier |
||---|---|
|| `M3 Ultra`, `M4 Ultra`, or later `Ultra` | `S` |
|| `M1 Ultra`, `M2 Ultra`, `M3 Max`, `M4 Max`, or later `Max` | `A` |
|| `M1 Max`, `M2 Max`, any `Pro` | `B` |
|| `M1`, `M2`, `M3`, `M4`, `unknown`, or unrecognized chip string | `C` |

- A benchmark-derived tier override MAY raise the chip-derived tier only when the benchmark table is compiled into the same binary release and the table row names the benchmark ID, threshold, and resulting tier. It MUST NOT lower a known chip-derived tier in v0.1.
- `min_bandwidth_tier` passes when `mac.bandwidth_tier >= model.min_bandwidth_tier` under the order above.

Optional hardware fields:

|| Field | Type | Rule |
||---|---|---|
|| `machine` | string | Human-readable Mac product name if available. |
|| `power_watts` | float | Used only when an electricity estimate is available. Absence must not fail recommendation. |
|| `measured_memory_pressure` | string enum | May be used for confidence. **[amended v0.7: runtime hard failures are `thermal_throttle_detected == true` and paid-path `swap_detected == true`]**. |
|| `benchmark_id` | string | Stable ID of the local benchmark run, included when available. |

### 3.2 Candidate/admission catalog

Candidate metadata is a separate signed control-plane input. Demand rank may score rows, but it never defines model download IDs, RAM gates, tier gates, benchmark gates, or runtime status.

Primary source:

```text
https://coordinator.streamvc.live/v1/autotune-candidates
```

Fallback source:

```text
baked autotune-candidates snapshot compiled into the installer/CLI release
```

Catalog selection happens before row eligibility. Transport failure, timeout, or unavailable HTTP response MAY select the baked catalog and MUST emit `candidate_catalog_fallback_used`; this state is `safe_offline_fallback` and MUST NOT claim buyer-serving readiness. Invalid signature, unknown signer, malformed sidecar, or invalid schema MUST additionally emit `candidate_catalog_integrity_failure`. A cryptographically valid but older-than-baked, future, expired, or policy-incompatible catalog MUST emit `candidate_catalog_update_required`. Integrity and update-required warnings block paid recommendation and coordinator join. After selecting either a valid fetched catalog or the baked catalog for local diagnostics, a demand/rate-card row missing metadata in the selected catalog is ineligible and MUST NOT be downloaded or benchmarked. The baked catalog is part of the release artifact and is trusted only for that binary version.

**What the candidate-catalog signature proves.** A valid detached signature proves only that the
operator-controlled static-feed key signed the exact catalog bytes selected by the client or
coordinator, and that those bytes satisfy the schema and release-compatibility rules above. It
binds model keys to operator-curated metadata such as `model_id`, immutable `model_revision`,
canonical `model_sha256`, minimum RAM/bandwidth gates, advisory benchmark-gate metadata, and
`runtime_status` for that release.

**What the candidate-catalog signature does not prove.** The signature does **not** prove that a
provider actually downloaded, loaded, or served those weights; does not prove benchmark honesty;
does not prove hardware identity, Secure Enclave custody, Apple attestation, RAM capacity, thermal
behavior, or network admission; does not prove rate-card correctness; and does not prove that a
future provider heartbeat or request path still matches the row. Runtime enforcement remains owned
by the separate catalog/hash checks, hardware-evidence verifier, Tier-2 attestation surfaces,
autotune recommendation gates, and coordinator admission/routing logic named in their owning specs.

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
        "min_sustained_tps": 69.0,
        "max_4k_ttft_ms": 0,
        "provenance": {
          "source": "omlx_seeded",
          "hardware": "string",
          "measured_at": "YYYY-MM-DD",
          "notes": "string"
        },
        "gate_seed": {
          "omlx_snapshot_id": "omlx-benchmark-snapshot-2026-07.json",
          "omlx_snapshot_sha256": "<64-hex digest of the immutable oMLX snapshot / observation manifest>",
          "target_cell": {
            "chip_normalized": "M4 Max",
            "ram_gb": 48,
            "model_key": "qwen3-32b",
            "quant": "4bit",
            "context": 4096
          },
          "board_release_tag": "v0.5.3",
          "board_p25_tg": 90.6,
          "engine_delta_applied": 0.85,
          "mtp_discounted": true,
          "observations_used_n": 12,
          "seeded_at": "2026-07-22T00:00:00Z"
        }
      },
      "runtime_status": "candidate",
      "notes": "string"
    }
  }
}
```

The `gate_seed` block is shown here only because this example row is
`omlx_seeded`; it MUST be absent on every other provenance source (see the
field rules below). All values above — including `min_sustained_tps` (shown as
`69.0`, the value the binding seed formula yields for these illustrative
`gate_seed` inputs), the `gate_seed` snapshot values (`board_p25_tg`,
`engine_delta_applied`, `observations_used_n`, `target_cell`, digests, tags,
timestamps) — are illustrative, not normative catalog values.

Field rules:

- `model_key` is the normalized key used for rate-card and demand-rank joins.
- `model_id` is the HuggingFace MLX model ID allowed for download/benchmark.
- `model_revision` is a content-addressed immutable model-host revision, such as a 40-hex HuggingFace repository commit. The CLI MUST download by this revision, not by a mutable branch or tag.
- `model_sha256` is a lowercase hex SHA-256 digest of the canonical artifact-set manifest for the release-pinned model snapshot. After downloading by `model_revision`, the CLI MUST reject the snapshot if any filesystem entry is not a regular file or directory; symlinks, hardlinks with link count greater than one, device nodes, sockets, FIFOs, absolute paths, path escapes, and relative paths containing `..` are forbidden. The CLI then enumerates every regular file, computes each file SHA-256, sorts entries by normalized POSIX relative path, serializes each entry as `path LF size_decimal LF sha256_hex LF`, concatenates those UTF-8 entries, and SHA-256s the concatenated bytes. A mismatch fails closed before benchmark, recommendation, local donor-mode commit, or provider run.
- SPEC-010 §3.7 owns the name `macprovider.snapshot-manifest.v1`, provider/coordinator wire fields, and comparison authority for this digest. This section defines the canonical manifest bytes only and MUST NOT be used as a second admission authority.
- Every downloadable row (`candidate`, `listed`, or `recommendable`) MUST include both `model_revision` and `model_sha256`. If either is absent, the row is ineligible before download or benchmark, including donor mode.
- `min_ram_gb` and `min_bandwidth_tier` are authoritative for §5. `bench_gate.min_sustained_tps` and `bench_gate.max_4k_ttft_ms` are advisory drift targets only; they do not veto paid or donor selection.
- `bench_gate.provenance.source` is one of `measured_single_host`, `runtime_validated_only`, `policy`, `no_throughput_bench`, `never_benched`, `legacy_unverified`, `omlx_seeded`, or `verified_provider_matrix`. Optional `hardware`, `measured_at`, and `notes` explain where the advisory gate came from. Provenance is support/operator metadata and does not by itself admit or reject cached benchmarks. Newly generated catalog releases, direct CLI catalog decoding, and current coordinator feed loading MUST fail closed when `bench_gate.provenance` is absent. During A4 feed activation only, implementations MAY accept the exact `published-2026-07-10-catalog-recovery-v1` candidate catalog with SHA-256 `776182f6230eff098345b188322dba0c7fce47a6da46447432991ffdc37eabda` as a signed live fetch or `previous-target` rollback input; every other missing-provenance candidate catalog remains an integrity failure.
- `verified_provider_matrix` is the canonical provenance value denoting a gate recomputed solely from `N` verified provider autotune measurements on eligible hardware (§12 promotion). It is the required value a row promoted away from `omlx_seeded` MUST carry (§5, §12). Unlike `measured_single_host` (one host) or `runtime_validated_only` (no trusted throughput gate), it denotes the verified-provider matrix that is the sole promotion/admission authority for a formerly provisional row. It is RESERVED and inert in Stage 1: any newly created or modified row carrying `verified_provider_matrix` MUST be rejected at catalog authoring, lint, and signing until the Stage-2 evidence binding ships (§12.4, AC-OMLX-12).
- `bench_gate.gate_seed` is REQUIRED when `bench_gate.provenance.source == "omlx_seeded"` and MUST be absent for every other provenance source. The requirement is symmetric: a row with `bench_gate.provenance.source == "omlx_seeded"` and a missing, malformed, or incomplete `gate_seed` is a catalog-integrity failure at the SAME boundaries as the forbidden-seed-on-non-oMLX-row case — it MUST fail closed at catalog authoring, lint, and signing, and at CLI catalog decode (and is likewise ineligible before download or benchmark). A row whose `bench_gate.provenance.source != "omlx_seeded"` that nonetheless carries a `bench_gate.gate_seed` is equally a catalog-integrity failure that MUST fail closed at catalog authoring, lint, and signing, and at CLI catalog decode (it MUST NOT be treated as a benign extra field — carrying seed identity on a non-provisional row is exactly the provenance-laundering this rule closes). `gate_seed` records the oMLX snapshot and derivation inputs used to produce the provisional advisory `min_sustained_tps`; it is not runtime evidence and does not admit or promote a provider.
- `bench_gate.gate_seed.target_cell` is the canonical normalized cell identity the seed is derived from and MUST carry `chip_normalized`, `ram_gb`, `model_key`, `quant`, and `context`. It binds the seed to exactly ONE normalized chip/RAM/model/quant/context cell; `board_p25_tg` and `observations_used_n` are the p25 and observation count OF THAT ONE cell. `target_cell.model_key` MUST equal the enclosing catalog row's normalized `model_key`, and `target_cell` model/quant/context MUST be consistent with the row's model identity; a seed whose `target_cell` targets a different model than its row is a catalog-integrity failure (§12.4, AC-OMLX-14). `bench_gate.gate_seed.omlx_snapshot_sha256` is a lowercase 64-hex digest of the immutable oMLX snapshot / observation manifest the observations were drawn from, so a validator can pin the observation set. Observations spanning more than one normalized cell (a mix of chips, RAM classes, models, quants, or context lengths) MUST NOT be aggregated into one seed; a `gate_seed` whose observations are not all within its declared `target_cell` is a catalog-integrity failure.
- `bench_gate.gate_seed.observations_used_n` is a positive integer (`>= 1`; and it MUST be `>= K`, the §12 oMLX seed threshold). It is the minimum post-dedup/outlier oMLX **observation** count within the single `target_cell` above (not a count of distinct cells). `board_release_tag` MUST identify a stable oMLX release, not a `.dev` prerelease. `board_p25_tg` MUST be the filtered 4k-token, matching-quantization p25 generation (decode) throughput of that cell after duplicate and outlier handling. `engine_delta_applied` MUST record the runtime delta used by the §12 seed formula and MUST be the exact `engine_delta` value bound into that formula. `mtp_discounted` MUST be `true` when MTP or speculative-decode board rows were discounted; accelerated rows that cannot be excluded or discounted MUST NOT seed a gate.
- The seed formula is binding: `min_sustained_tps` on an `omlx_seeded` row MUST equal `max(8, floor(board_p25_tg * engine_delta_applied * 0.90))` exactly, using the row's own `gate_seed` values (§12). A `min_sustained_tps` that does not equal that computed value is a formula mismatch and a catalog-integrity failure (fail-closed per the semantic-failure rule below).
- Field-laundering is forbidden: oMLX data MAY seed ONLY `bench_gate.min_sustained_tps` and its `gate_seed` metadata. An `omlx_seeded` row (or its seed) MUST NOT create or change `min_ram_gb`, `min_bandwidth_tier`, `runtime_status`, model identity (`model_key`/`model_revision`/`model_sha256`), demand-rank, rate-card/pricing, or any admission/routing field; any such row is a catalog-integrity failure. An oMLX-derived `min_ram_gb` in particular is forbidden because SPEC-032 would consume it for `autotune_model_cap_exceeded` and hard-block a provider on unattested data (§12.4, AC-OMLX-13).
- `gate_seed` freshness reference: `seeded_at` is the seed derivation time and is the reference point for the §12 120-day date window (oMLX rows used for the seed MUST be dated within 120 days of, and on or after 2026-05-01 relative to, `seeded_at`). An `omlx_seeded` row whose `seeded_at` (or underlying board snapshot) is older than the 120-day freshness window is ineligible and MUST be re-seeded; a seed MUST NOT remain provisional indefinitely (§12).
- Semantic seed failures fail closed on the CATALOG/CLIENT paths only. A `.dev` `board_release_tag`, undiscounted MTP/speculative-decode source rows (`mtp_discounted` false while accelerated rows were used), duplicate or cross-bucket cells, an invalid/out-of-order/future `seeded_at` or `measured_at` timestamp, a stale-beyond-window seed, or a seed-formula mismatch is a catalog-integrity failure. Such a row MUST fail closed at catalog authoring, lint, and signing, and at CLI catalog decode, and MUST NOT be downloaded, benchmarked, donor-committed, or recommended (paid-default or donor selection). It is not merely "does not seed a gate" — it fails closed on every one of those paths. A row-level oMLX `gate_seed` integrity failure MUST NOT affect or block any provider's SPEC-032 verified-hardware coordinator admission: oMLX data (valid or invalid) NEVER hard-blocks a provider. Provider admission is governed solely by verified-hardware evidence (SPEC-032), which does not read `bench_gate` advisory/seed fields.
- `runtime_status` is one of `candidate`, `listed`, `recommendable`, or `blocked`. Only `recommendable` rows may become paid defaults, and the demand-rank row must also have `recommendable: true`.

The table below lists the current `published-2026-07-29-inband-provenance-v1` signed candidate-catalog rows and gate values. The baked JSON release artifact MUST also include a release-pinned `model_revision` and `model_sha256` for every non-`blocked` row; the long immutable bindings are omitted from this table for readability.

The baked and served static candidate catalog MUST contain at least these rows:

|| model_key | model_id | min_ram_gb | min_bandwidth_tier | min_sustained_tps | max_4k_ttft_ms | runtime_status |
||---|---|---:|---|---:|---:|---|
|| `meta-llama/llama-3.1-8b-instruct` | `mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` | 12 | `C` | 15 | 2500 | `recommendable` |
|| `openai/gpt-oss-20b` | `mlx-community/gpt-oss-20b-MXFP4-Q8` | 24 | `C` | 15 | 2500 | `recommendable` |
|| `qwen3-32b` | `mlx-community/Qwen3-32B-4bit` | 48 | `B` | 15 | 4000 | `recommendable` |
|| `qwen3-coder-30b-a3b-instruct` | `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit` | 28 | `C` | 20 | 3500 | `recommendable` |
|| `qwen2.5-coder-32b-instruct` | `mlx-community/Qwen2.5-Coder-32B-Instruct-4bit` | 48 | `A` | 20 | 3500 | `recommendable` |
|| `google-gemma-4-26b-a4b-it` | `mlx-community/gemma-4-26b-a4b-it-4bit` | 28 | `C` | 10 | 3000 | `recommendable` |
|| `nvidia/nemotron-3-nano-30b-a3b` | `mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit` | 32 | `C` | 30 | 3000 | `recommendable` |
|| `meta-llama/llama-3.2-3b-instruct` | `mlx-community/Llama-3.2-3B-Instruct-4bit` | 4 | `C` | 15 | 2500 | `recommendable` |
|| `qwen3-8b` | `mlx-community/Qwen3-8B-4bit` | 12 | `C` | 15 | 4500 | `recommendable` |

The current signed catalog carries these in-band `bench_gate.provenance` classifications:

|| model_key | source | hardware | notes |
||---|---|---|---|
|| `meta-llama/llama-3.1-8b-instruct` | `no_throughput_bench` |  | #744 audit: gate row had no throughput benchmark. |
|| `meta-llama/llama-3.2-3b-instruct` | `no_throughput_bench` |  | #744 audit: gate row had no throughput benchmark. |
|| `openai/gpt-oss-20b` | `measured_single_host` | `M5 32GB` | #744 audit: measured single-host row; #745 blocks trusted gate re-derivation. |
|| `qwen3-32b` | `never_benched` |  | #744 audit: high-memory row was never benched; values unchanged. |
|| `qwen3-coder-30b-a3b-instruct` | `measured_single_host` | `M5 32GB` | #744 audit: measured single-host row; #745 blocks trusted gate re-derivation. |
|| `qwen2.5-coder-32b-instruct` | `policy` |  | #744 audit: gate set by operator policy to broaden eligibility. |
|| `google-gemma-4-26b-a4b-it` | `measured_single_host` | `M5 32GB` | #744 audit: measured single-host row; #745 blocks trusted gate re-derivation. |
|| `nvidia/nemotron-3-nano-30b-a3b` | `runtime_validated_only` |  | #744 audit: runtime validated only; no trusted throughput gate. |
|| `qwen3-8b` | `measured_single_host` | `M5 32GB` | #744 audit: measured single-host row; #745 blocks trusted gate re-derivation. |

`blocked` rows may be shown only as diagnostics when useful; they are never downloaded, benchmarked, or recommended by default. The current signed candidate catalog has no blocked rows; Gemma and Nemotron are `recommendable` after `mlx-swift-lm` runtime validation and coordinator rate-card rollout.

### 3.3 Rate card

The recommendation engine fetches the current rate card from `https://coordinator.streamvc.live/v1/rate-card` and its detached sidecar from `https://coordinator.streamvc.live/v1/rate-card.sig`. Live rate-card bytes MUST be verified before paid recommendation uses them. Transport/HTTP unavailability may use the baked rate-card snapshot compiled into the installer/CLI release and emit `rate_card_fallback_used`; missing/malformed sidecar, unknown signer, invalid signature, invalid schema, policy mismatch, valid older-than-baked bytes, future bytes, or expired bytes MUST additionally emit `rate_card_integrity_failure` or `rate_card_update_required` as applicable and block paid recommendation.

`GET /v1/rate-card` is a read-only coordinator endpoint. It MUST NOT alter billing, settlement, routing, provider state, request logs, `RateCardEntry`, settlement arithmetic, or coordinator-held signing material. It is public-read because it exposes only prices already used for buyer/provider economics; no provider or buyer credential is required. Production serves literal signed `rate-card.json` bytes loaded from disk after Ed25519 verification at startup. Unconfigured local/development coordinators may compute the same recommendation-only projection from `Rewards.RateCard`, `Rewards.ProviderShare`, `Rewards.GlobalMultiplier`, and `stats.rollup.usd_per_million_credits`; clients still require the sidecar before trusting live bytes.

Repository routing contract:

- The handler lives on the coordinator buyer HTTP mux (`buyer_port: 8443`), not the provider/operator mux (`provider_port: 8444`).
- Production nginx MUST include exact `location = /v1/rate-card` and `location = /v1/rate-card.sig` allow-through blocks before the generic `location /v1/ { return 404; }` block in `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf`.
- The nginx locations proxy to `http://127.0.0.1:8443/v1/rate-card$is_args$args` and `http://127.0.0.1:8443/v1/rate-card.sig$is_args$args`, forward `Host`, `X-Real-IP`, `X-Forwarded-For`, and `X-Forwarded-Proto`, and do not require `Authorization`.

The v0.1 rate-card JSON schema is:

```json
{
  "version": "string",
  "policy_version": "autotune-policy-v1",
  "generated_at": "RFC3339 timestamp",
  "usd_per_million_credits": 1.0,
  "rows": {
    "<model_key>": {
      "prompt_rate_per_mtok": 0,
      "prompt_cache_hit_rate_per_mtok": 0,
      "completion_rate_per_mtok": 0,
      "provider_share_bps": 9000,
      "global_multiplier_ppm": 1000000
    }
  }
}
```

`prompt_rate_per_mtok`, `prompt_cache_hit_rate_per_mtok`, and `completion_rate_per_mtok` are coordinator credits per million tokens, matching `phase4-coordinator/internal/billing/formula.go::RateCardEntry` semantics and ledger `*_rate_per_mtok` columns. `usd_per_million_credits` is the active `stats.rollup.usd_per_million_credits` conversion used for recommendation math; v0.1 expects `1.0` but the signed endpoint value is authoritative. A model is rate-card-enabled for recommendation if lookup succeeds by exact key, by Wave 0b `normalizeModelKey`, or by the coordinator `default` row after those specific lookups miss. When the `default` row is used for a non-`default` candidate, `recommended_model` remains the catalog model key and the CLI emits `rate_card_default_tier_used`. Missing `provider_share_bps` or missing `prompt_cache_hit_rate_per_mtok` is non-compliant for fetched rate-card rows.

`version` is a recommendation-projection version, not the existing billing snapshot hash. It is the lowercase hex SHA-256 of the canonical projection bytes after config load:

1. Build a JSON object containing only `usd_per_million_credits`, `provider_share_bps`, `global_multiplier_ppm`, and `rows`.
2. Sort `rows` by normalized model key.
3. Serialize JSON with sorted object keys, no insignificant whitespace, decimal integers for all rates/BPS/PPM values, and decimal number syntax for `usd_per_million_credits`.
4. Exclude unrelated config and ledger fields, including `policy_version`, `generated_at`, quarantine/force-void state, request-log state, operator settings, and settlement runtime state.

### 3.4 Demand signal

The recommendation engine fetches `https://coordinator.streamvc.live/v1/demand-rank` and falls back to a baked snapshot when the signed feed fetch fails, times out, fails Ed25519 detached-signature verification, or fails schema validation. The demand signal is operator-curated OpenRouter-prior metadata, not a coordinator demand endpoint.

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
      "min_provider_target": 0,
      "ready_provider_count": 0,
      "supply_deficit_multiplier": 1.0,
      "min_dwell_hours": 0
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
- `rows.<model_key>.min_provider_target` is the desired buyer-ready provider floor for coverage planning.
- `rows.<model_key>.ready_provider_count` is optional, non-negative, and records the observed buyer-ready supply used for the release. When present and no explicit multiplier is supplied, the effective multiplier is `clamp(min_provider_target / max(ready_provider_count, 1), 0.5, 2.0)`.
- `rows.<model_key>.supply_deficit_multiplier` is optional and, when present, is authoritative for that release in the inclusive range `[0.5, 2.0]`.
- `rows.<model_key>.min_dwell_hours` is optional operator policy metadata in `[0, 720]`; v0.6 validates and preserves it but does not auto-switch models.
- When neither supply field is present, the effective supply-deficit multiplier is neutral (`1.0`).

### 3.5 Static JSON integrity

Fetched `rate-card.json`, `demand-rank.json`, and `autotune-candidates.json` MUST be verified before parsing into the recommendation engine:

1. Fetch `rate-card` and detached `rate-card.sig` from `https://coordinator.streamvc.live/v1/rate-card` and `https://coordinator.streamvc.live/v1/rate-card.sig`; fetch `autotune-candidates` and detached `autotune-candidates.sig` from `https://coordinator.streamvc.live/v1/autotune-candidates` and `https://coordinator.streamvc.live/v1/autotune-candidates.sig`; fetch `demand-rank` and detached `demand-rank.sig` from `https://coordinator.streamvc.live/v1/demand-rank` and `https://coordinator.streamvc.live/v1/demand-rank.sig`.
2. Parse the detached `{name}.sig` sidecar as UTF-8 JSON exactly in this shape:

```json
{
  "key_id": "streamvc-autotune-static-v4",
  "alg": "ed25519",
  "signature": "<base64>"
}
```

3. Verify `signature` as base64-encoded Ed25519 over the exact UTF-8 bytes of `{name}.json`.
4. Resolve `key_id` through the release-embedded trusted verifier keyring. The v0.6 rotation bridge contains `streamvc-autotune-static-v4` and the staged v5 verifier; unknown key IDs fail closed.
5. Parse `{name}.json` only after signature verification succeeds.
6. Reject the fetched file and use the baked snapshot only for local-safe behavior when the signature sidecar is missing/malformed, uses an unknown `key_id`, uses any `alg` other than `ed25519`, or fails verification; emit the corresponding integrity-failure warning and block paid recommendation/coordinator join.
7. Reject the fetched file and use the baked snapshot only for local-safe behavior when `generated_at` is older than the baked snapshot's `generated_at`; emit the corresponding update-required warning and block paid recommendation/coordinator join.
8. Emit `rate_card_stale` for stale `rate-card.json`, `demand_rank_stale` for stale `demand-rank.json`, or `candidate_catalog_stale` for stale `autotune-candidates.json`, but allow the fetched file when `generated_at` is 14-30 days old.
9. Reject the fetched file and emit update-required when `generated_at` is more than 10 minutes in the future relative to the local clock.
10. Reject the fetched file and emit update-required when `generated_at` is more than 30 days old.
11. Candidate and demand feeds selected as one live release MUST share `version`, `generated_at`, and `policy_version`; mixed releases fail closed.
12. `rate-card.json` is release-manifest-bound but versioned by the §3.3 recommendation projection hash, so its `version` MAY differ from the candidate/demand release ID. It MUST share the policy version expected by the baked rate-card snapshot.

oMLX schema and the whole-catalog integrity rule are phase-qualified by the §12.2
activation state. PRE-activation (before the oMLX schema is supported by every
consumer), any `omlx_seeded` row / `gate_seed` / `verified_provider_matrix` value
in a served catalog is treated as invalid/unknown schema and triggers a
whole-catalog `candidate_catalog_integrity_failure` (blocking paid recommendation
and coordinator join) — this is the activation gate working as intended.
POST-activation, a per-row semantic oMLX error decodes successfully at the
whole-catalog level and is row-scoped quarantined (§12.3), NOT a
`candidate_catalog_integrity_failure`. Whole-catalog integrity failure remains
reserved for signature failure, global-schema failure, a non-oMLX-row integrity
failure, or the pre-activation presence of the unsupported oMLX schema — never a
single post-activation malformed oMLX row.

Clients MUST keep a release-pinned verifier keyring. Key rotations require a bridge binary that embeds both old and new verifier keys before the feed signer changes. The old key remains trusted until operator telemetry establishes the retirement threshold defined by the release runbook.

### 3.6 Catalog digests: full-integrity vs admission-policy subset

Two distinct digests are computed over the selected candidate catalog, for two
distinct purposes. Conflating them is the SPEC-032 admission self-contradiction
this section resolves.

- `candidate_catalog_sha256` (the full hash, §9) is the lowercase hex SHA-256
  over the EXACT full catalog JSON bytes, including every `bench_gate` field
  (`min_sustained_tps`, `max_4k_ttft_ms`, `provenance`, `gate_seed`). It is used
  ONLY for cache identity, update/staleness detection, and byte-level feed
  integrity. It MUST NOT be used as the coordinator's verified-hardware admission
  match key, because it changes whenever an advisory-only field (including an
  `omlx_seeded` seed value) changes, which would spuriously invalidate a
  provider's verified admission.

- `admission_policy_sha256` (the admission-policy subset digest) is the lowercase
  hex SHA-256 over a canonical projection of the catalog that EXCLUDES the
  advisory `bench_gate.min_sustained_tps`, `bench_gate.max_4k_ttft_ms`,
  `bench_gate.provenance`, and `bench_gate.gate_seed` fields, and retains only the
  admission-authoritative fields (`model_id`, `model_revision`, `model_sha256`,
  `min_ram_gb`, `min_bandwidth_tier`, `runtime_status`, and `model_key`). It is
  computed by removing those excluded `bench_gate` sub-fields, sorting `rows` by
  normalized model key, and serializing with sorted object keys and no
  insignificant whitespace (same canonicalization discipline as §3.3).

SPEC-032's autotune hello-gate verified-evidence admission matching MUST match on
`admission_policy_sha256`, NOT on the full `candidate_catalog_sha256` (SPEC-032
FR-HG3/FR-HG4). This ensures (a) unattested oMLX advisory values are outside the
admission match entirely, and (b) a non-oMLX advisory-only edit (e.g. a drift
target adjustment) does not invalidate an otherwise-valid verified admission. The
implementation that computes `admission_policy_sha256` and matches admission on it
is Stage-2 prerequisite §12.2(b)(i); this section is the normative contract it
must satisfy.

## 4. Formula (updated v0.8)

The v0.6 recommendation engine ranks eligible rows by expected operator earning opportunity while filling buyer-facing supply deficits:

```text
eligible_rows = rows where:
  rate_card_enabled AND
  recommendable == true AND
  hardware_fits(model, mac) AND
  local_autotune_passes(model, mac)

provider_share(row) = provider_share_bps(row) / 10_000

raw_score(row | mac) =
  completion_rate_per_mtok(row)
  × provider_share(row)
  × measured_sustained_tps(row, mac)
  × max(demand_weight(row), cold_start_floor)
  × effective_supply_deficit_multiplier(row)

recommended_model =
  eligible row with highest raw_score, breaking ties by:
    1. measured_sustained_tps DESC
    2. max(demand_weight, cold_start_floor) DESC
    3. model key ASC
```

**Raw score uses provider completion payout credits, measured throughput, buyer-demand weight, and bounded supply deficit.** Throughput is a first-order term, not a tiebreaker. The score remains independent of rate-card USD conversion volatility, while a `0.5...2.0` deficit bound prevents a noisy provider count from overwhelming operator economics.

Constants locked in v0.6:

| Constant | Value | Rule |
|---|---:|---|
| `cold_start_floor` | `0.15` | From demand-rank JSON; schema validation fails if the fetched value differs. Floors the demand factor. |
| supply-deficit bound | `0.5...2.0` | Applied to explicit or provider-count-derived deficit multipliers. Missing supply data uses `1.0`. |
| `diversification_band` | `0.85` | Retained in demand-rank JSON schema for forward compatibility; **not used for recommendation pick in v0.5**. Re-enable when supply exceeds demand. |
| `provider_share` | `0.90` | Represented by rate-card row `provider_share_bps = 9000`; the row value is authoritative, but v0.5 rows are expected to use 0.90. |
| `tier_weight` | `1.0` | Applies to all rows and tiers in v0.5. Tier-specific calibration is deferred to v0.2 follow-up. |
| ranked output length | `5` | The JSON `candidates[]` array defaults to the top 5 rows after ranking, including eligible rows first and then selected ineligible diagnostic rows only when no eligible row exists. |
| `diversification_id` | HMAC-derived stable ID | Used for recommendation-cache identity only in v0.5; does not alter `recommended_model` selection. |

**Real provider earnings** are recorded after tokens are served:

```text
real_earnings = sum over transcript entries of (token_count × rate_per_token)
```

Displayed candidate capacity is a per-token throughput estimate:

- `tokens_per_second` is the measured `sustained_tps` from local autotune benchmark.
- `platform_fee` is derived from the `provider_share` split at recommendation time.
- `raw_score` is for ranking only; the transcript must say the result is an estimate.

## 5. Eligibility gates (mandatory pre-filter)

A row is eligible only if every gate passes:

1. `recommendable == true` in `demand-rank.json`.
2. `hardware_fits(model, mac)` passes.
3. `local_autotune_passes(model, mac)` passes.
4. The candidate catalog row has `runtime_status == "recommendable"`.
5. For PAID-DEFAULT selection, the candidate catalog row has `bench_gate.provenance.source != "omlx_seeded"`. This gate scopes ONLY the paid-default (recommended-model) path: an `omlx_seeded` row is never a paid default. It does NOT bar the row from local-only, unpaid donor selection, which MAY offer an `omlx_seeded` row with the mandatory provisional label (§7.2, §8).
6. The coordinator rate card has a row for the model either verbatim, through `normalizeModelKey`, or through the §3.3 `default` fallback after those specific lookups miss.

Rows with `bench_gate.provenance.source == "omlx_seeded"` are provisional rows. They MAY appear only with `runtime_status` equal to `candidate` or `listed`; they MUST NOT appear as `recommendable` and MUST NOT become paid defaults. They MAY still be selected in local-only, unpaid donor mode (§7.2, §8), which is not a paid-default and does not admit a network-connected paid provider. The oMLX seed MUST NOT be sole or partial evidence for promotion.

Promotion from `listed` to `recommendable` depends solely on at least `N` verified provider autotune measurements on eligible hardware as defined in §12; the oMLX seed is neither a pass/fail criterion for promotion nor an input to the promoted gate. On promotion, the advisory gate is recomputed solely from those verified provider measurements, `bench_gate.provenance.source` is set to `verified_provider_matrix` (§3.2), and `bench_gate.gate_seed` is removed.

**Promotion is DEFINED but PROHIBITED in Stage 1 (fail-closed deferral).** An `omlx_seeded` (or formerly-`omlx_seeded`) row MUST NOT be promoted to `recommendable` until the Stage-2 verified-evidence-record mechanism — signed immutable per-measurement references plus deterministic aggregation of the `N` verified provider autotune measurements — exists. The promotion transition and its target provenance (`verified_provider_matrix`) are specified here so the contract is complete, but the transition is inert and MUST NOT be exercised in Stage 1: with no verifiable evidence-record mechanism, a promotion cannot be proven backed by the `N` measurements, so it fails closed (stays `listed`). The evidence-record mechanism is deferred to a later stage.

Note: `bench_gate.min_sustained_tps` and `bench_gate.max_4k_ttft_ms` are advisory drift targets, never a coordinator admission veto. SPEC-032's autotune hello-gate no longer hard-gates admission on the advisory `bench_gate` (SPEC-032 FR-HG3/FR-HG4); any hard performance admission gate is a separate field backed by verified-provider evidence.

`hardware_fits(model, mac)` rules:

- v0.1 uses a fixed `safety_margin_gb = 4`.
- The signed candidate catalog must expose `model.min_ram_gb` as the resident-fit floor excluding this safety margin.
- The RAM headroom check is `model.min_ram_gb <= mac.ram_gb - safety_margin_gb`.
- The signed candidate catalog must expose `min_bandwidth_tier`. Dense 32B/70B and developer dense rows must honor their tier gates; small-active MoE rows may pass on Tier-C when RAM and local probes pass.
- Unknown hardware tier is treated as `C`; `min_bandwidth_tier` comparison uses the §3.1 order `S >= A >= B >= C`.

`local_autotune_passes(model, mac)` rules (v0.1 rules with v0.2 amendments applied — see change log v0.2 point 1):

- `sustained_tps >= model.bench_gate.min_sustained_tps` **[v0.2 amendment: advisory; missing emits `tps_below_gate` warning but does not veto eligibility]**.
- `ttft_ms <= model.bench_gate.max_4k_ttft_ms` **[v0.2 amendment: advisory; missing emits `ttft_above_gate` warning but does not veto eligibility]**.
- `swap_detected == false` **[amended v0.9 / #742: `swap_detected` == sustained CRITICAL memory pressure (≥2 samples Critical AND ≥50% of readable samples Critical) is a hard block for paid recommendation. When it causes no paid row to land, emit `swap_observed_under_load`. Advisory Warning-majority pressure does not set `swap_detected` and does not block (telemetry only). Fail closed to true only when the whole series is unreadable. Donor mode keeps swap advisory]**.
- `buyer_ttft_ceiling_ms == 0 OR ttft_ms <= buyer_ttft_ceiling_ms` **[v0.8 / #744: hard block for paid recommendation only. The operator-set ceiling protects buyer UX and is independent of catalog `bench_gate.max_4k_ttft_ms`. Enabling donor mode does not bypass the paid-path ceiling; donor fallback remains local-only and may still name a compatible row separately]**.
- `thermal_throttle_detected == false` **[unchanged from v0.1: hard block]**.
- The candidate benchmark must be from the current `benchmark_id` or from a cached run whose candidate catalog hash, binary version, model ID, and HMAC-derived hardware identity hash match and whose `generated_at` is no older than 7 days.
- There is no default 60_000 ms TTFT feasibility ceiling on the paid `--recommend` path. Omitting `--gate-ttft-ms` with `--recommend` disables that probe feasibility ceiling. Classic non-recommend Stage 1/2 retains the SPEC-013 default. The paid buyer-facing ceiling is the separate `--buyer-ttft-ceiling-ms` policy knob above.

In v0.4, there is no paid financial gate. All eligible rows proceed to recommendation regardless of earnings projections. Real earnings are recorded only after tokens are served.

## 6. Output JSON contract (`autotune --recommend`)

`autotune --recommend --json` MUST emit deterministic field order exactly as shown below. Unknown optional data uses `null`; fields are not reordered, renamed, or omitted in v0.4.

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
    "candidate_catalog_version": "<string>"
  },
  "recommended_model": "<model_key-or-null>",
  "prompt_rate_usd_per_million_tokens": null,
  "completion_rate_usd_per_million_tokens": null,
  "serve_config": null,
  "candidates": [
    {
      "rank": 1,
      "model": "<model_key>",
      "eligible": true,
      "prompt_rate_usd_per_million_tokens": 0.0,
      "completion_rate_usd_per_million_tokens": 0.0,
      "tokens_per_second": 0.0,
      "memory_headroom_gb": 0.0,
      "confidence": "low",
      "why": "<one-line reason>",
      "raw_score": 0.0,
      "bench_gate_provenance": {
        "source": "policy",
        "notes": "#744 audit: gate set by operator policy to broaden eligibility."
      },
      "bench_gate_drift": [],
      "buyer_ttft_ceiling_exceeded": false
    }
  ],
  "warnings": []
}
```

Schema rules:

- `schema_version` is exactly `autotune_recommend.v1`.
- `generated_at` is RFC3339 UTC.
- `hardware.memory_gb` is an integer greater than or equal to `1`.
- `hardware.bandwidth_tier` is one of `S`, `A`, `B`, `C`, or `unknown`.
- `recommended_model` is a model key string when at least one eligible row exists; otherwise `null`.
- `prompt_rate_usd_per_million_tokens` and `completion_rate_usd_per_million_tokens` are USD/M rates for the selected recommendation, derived from rate-card credits and `usd_per_million_credits`. Both are `null` when `recommended_model` is `null`.
- `serve_config` is `null` in recommendation-only output when no apply-ready serving configuration has been attached. When present, it is the exact model/knob payload the installer can apply for the selected recommendation; donor outcomes keep `donor_mode = true`.
- `candidates[]` default length is at most 5. It is sorted by eligibility first, then `raw_score` descending, then `model` lexicographically for deterministic ties.
- Candidate `prompt_rate_usd_per_million_tokens` and `completion_rate_usd_per_million_tokens` are USD display rates from the rate-card row used for that candidate.
- `raw_score` is rounded to 6 decimal places in JSON.
- `bench_gate_provenance` is copied from the signed candidate catalog row for the displayed candidate. Missing signed-catalog provenance is a catalog integrity failure, not a display fallback, except for the exact A4 transition-pinned July 10 live fetch where clients may derive the display-only #744 provenance classification while retaining the original signed bytes as the selected catalog hash.
- When `bench_gate_provenance.source == "omlx_seeded"`, JSON and human output MUST make the provisional status explicit. The rendered text MUST state that the gate is oMLX-seeded, not macprovider-verified, and not eligible for paid-default recommendation until verified provider autotune promotion replaces the seed per §12.
- `bench_gate_drift` is a sorted array containing `tps_below_gate` and/or `ttft_above_gate` when local measured benchmark results diverge from the advisory catalog target.
- `buyer_ttft_ceiling_exceeded` is `true` when the candidate failed the paid-path buyer TTFT ceiling.
- `confidence` is:
  - `high` when rate-card fetch, signed demand-rank fetch, signed candidate-catalog fetch, and current local benchmark all used live/current data.
  - `medium` when rate card, demand rank, or candidate catalog used a valid baked fallback, or the benchmark used a valid cache.
  - `low` when both market inputs used baked fallback, hardware tier is unknown, or any non-fatal diagnostic warning affects the recommended row.
- The human transcript MUST render the selected candidate's `confidence`, `bench_gate_provenance`, and `bench_gate_drift` fields. Empty drift is rendered as `none`.
- `why` is a single line under 140 characters, contains no newline, and must not promise realized buyer demand.
- `warnings[]` is an array of stable machine-readable strings, sorted lexicographically. v0.6 adds `candidate_catalog_integrity_failure`, `candidate_catalog_update_required`, `demand_rank_integrity_failure`, and `demand_rank_update_required`; v0.8 adds `buyer_ttft_ceiling_exceeded`; v0.8.1 restores `rate_card_default_tier_used` as the visible signal for default-row pricing fallback; v0.8.6 adds `rate_card_integrity_failure`, `rate_card_update_required`, and `rate_card_stale`. Any integrity/update-required warning blocks a paid recommendation.

## 7. Per-token payout semantics

In v0.4, provider earnings are fully determined by real delivered tokens and the per-token rate from the rate card:

```text
real_earnings = sum(tokens_served × rate_per_token_from_rate_card)
```

The install transcript shows a per-token rate at recommendation time and instructs the operator that the provider will earn `sum(tokens × rate)` deterministically.

### 7.1 Happy path (recommended model)

For `macprovider-cli autotune --recommend`, use this text verbatim,
replacing braces with computed values:

```text
Detected {machine_or_chip}, {memory_gb} GB unified memory, Tier {bandwidth_tier}.
Benchmarked {benchmarked_count} local benchmark results against rate card {rate_card_version} and demand rank {demand_rank_version}.

Recommended: {recommended_model}
Rate: ${prompt_rate_usd_per_million_tokens} per million prompt tokens
      ${completion_rate_usd_per_million_tokens} per million completion tokens
Confidence: {confidence}
Bench gate provenance: {bench_gate_provenance}
Bench gate drift: {bench_gate_drift}
Real earnings scale with buyer demand and your uptime.

To apply this recommendation, rerun with --apply. Then start the provider with:
              macprovider-cli serve
```

Happy path applies only when at least one recommendable model is eligible and clears all §5 gates.
After the CLI applies the recommendation, it replaces the final two lines above with:

```text
Configuration applied. Start the provider with:
              macprovider-cli serve
```

The public `install.sh` wrapper may ask a separate service-start
confirmation after `--apply` succeeds, but that wrapper prompt is not part
of the `autotune --recommend` transcript and MUST NOT reuse the deleted
minimum-hourly-gate donor copy.

### 7.2 Donor-tier path

Use this text as the donor transcript, replacing braces with computed values.
When at least one candidate was disqualified for `swap_detected == true`, the CLI
MUST insert the optional swap diagnostic line shown below (including its trailing
blank line). When no swap disqualification applied, omit that line entirely so the
blank line after the "No catalog model..." sentence remains a single blank line.

```text
Detected {machine_or_chip}, {memory_gb} GB unified memory, Tier {bandwidth_tier}.
No catalog model currently fits this Mac for network serving.
{optional_swap_diagnostic}
Best compatible option: {best_compatible_model}
Recommendation: donor mode only

You can keep this Mac configured for donor-mode testing, but it is not expected to earn meaningful revenue on the current rate card.
Enable donor mode? [y/N]
```

`{optional_swap_diagnostic}` is either empty or exactly:

```text
At least one candidate was disqualified because swap was detected under probe load.

```

Donor-tier path applies when no row passes all §5 gates and only a donor-compatible non-default row remains available for explicit local donor-mode testing.

When the `{best_compatible_model}` shown in the donor transcript is an
`omlx_seeded` row, the transcript MUST additionally carry the provisional label
`oMLX-seeded; not macprovider-verified` for that row, so the operator sees that
the best compatible option is seeded from unattested community data and has not
been verified by macprovider.

## 8. Donor-mode UX

v0.1 locks an explicit local donor-mode override:

- CLI flag: `--donor-mode` as a boolean flag on the configuration/apply path.
- YAML config: `donor_mode: true` as a boolean.
- Install prompt default: No (`[y/N]`).

When `donor_mode == true`:

- The CLI may skip only the recommendability and demand-rank `recommendable == true` default-selection gate.
- The CLI MUST NOT bypass signed candidate-catalog presence, immutable model revision, canonical artifact-set digest check, `runtime_status != "blocked"`, model ID allowlist, RAM headroom, no-thermal, or runtime-support gates. Swap remains advisory for donor-mode commit (paid path hard-blocks swap per §5 / AC-12).
- A donor-mode row must have signed candidate metadata with `runtime_status` equal to `candidate`, `listed`, or `recommendable`; `blocked` rows remain forbidden.
- SPEC-023 does not add coordinator/gateway donor-routing or settlement behavior. Applying donor mode may write local config and status only; it MUST NOT auto-start or auto-register a network-connected paid provider for a non-recommendable donor row. Network-connected donor serving requires a separate donor-routing/settlement spec or build prerequisite.
- The CLI must print an explicit warning before commit:

```text
DONOR MODE: {selected_model} does not meet rate-card or hardware requirements on this Mac.
```

- `macprovider-cli status` must show a `DONOR MODE` badge alongside the configured model while `donor_mode: true`.

## 9. Re-tune cadence + UX

`autotune --recommend` re-runs or prompts the operator in exactly these v0.4 cases:

1. Manual invocation: `macprovider-cli autotune --recommend`.
2. `macprovider-cli update` or installer rerun after install, when the live rate-card version, live demand-rank version, signed candidate-catalog version/hash, binary version, stable hardware identity hash, or benchmark age differs from stored recommendation state.
3. Installer rerun when no stored recommendation exists.

v0.4 explicitly does not re-run automatically on coordinator SIGHUP or rate-card hot reload. Coordinator broadcast of recommendation changes is deferred to v0.2 follow-up.

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
  "recommended_model": "<model_key-or-null>",
  "recommended_bench_gate_provenance_source": "<string-or-null>",
  "recommended_gate_seed_identity": "<string-or-null>"
}
```

`hardware_identity_hash` is an HMAC-SHA256-derived local identity hash. It MUST NOT be a raw serial number, MAC address, device UUID, or unhashed hardware fingerprint.

`recommended_bench_gate_provenance_source` is the selected row's `bench_gate.provenance.source`; `recommended_gate_seed_identity` records the selected row's seed identity (at minimum `gate_seed.omlx_snapshot_id` and `gate_seed.seeded_at`) when the selected row is `omlx_seeded`, and is `null` otherwise. These fields let `macprovider-cli status` render provisional oMLX provenance (AC-OMLX-6) without re-fetching the catalog. When `recommended_bench_gate_provenance_source == "omlx_seeded"`, `macprovider-cli status` MUST render the exact label `oMLX-seeded; not macprovider-verified` alongside the configured model.

Stored hash/version derivation:

- `candidate_catalog_sha256` is the lowercase hex SHA-256 over the exact selected catalog JSON bytes after fetched/baked selection and before parsing normalization.
- `rate_card_version` is the `/v1/rate-card.version` recommendation-projection hash from §3.3. It MUST NOT reuse broader coordinator config or billing snapshot hashes that include unrelated ledger, quarantine, request-log, operator, or settlement state.
- `demand_rank_version` is the selected demand-rank JSON `version`; v0.4 does not require an additional stored demand-rank hash.

`macprovider-cli status` MUST emit a stale-recommendation warning when the live rate-card version, demand-rank version, candidate-catalog version/hash, binary version, stable hardware identity hash, or benchmark freshness differs from this stored state:

```text
Recommendation stale: recommendation inputs changed since {generated_at}.
Run: macprovider-cli autotune --recommend
```

## 10. Goodhart mitigations

| ID | Mitigation | SPEC-023 implementation |
|---|---|---|
| M1 | Deterministic diversification | **[deferred v0.5]** v0.4's 85% pool + `stable_hash(...) % len(pool)` is suspended for beta supply growth. v0.5 uses strict payout-first argmax + tiebreakers; re-enable diversification when supply exceeds demand. |
| M3 | Cold-start floor | §3.4 and §4 lock `cold_start_floor = 0.15` as a demand-weight tiebreaker floor in v0.5. |
| M4 | Row lifecycle states | §3.2 and §3.4 lock `runtime_status` and `recommendable`; §5 requires both before default recommendations. |
| M7 | Rate-card version binding | §3.3, §6, and §9 persist `rate_card_version`. |
| M8 | Retune hint | §9 defines upgrade/manual triggers and stale status text. |
| M12 | Hard eligibility gates | §5 requires RAM, benchmark, no-swap, no-thermal, and rate-card gates before scoring. |
| M16 | Deployability gate | §3.2 and §3.4 define deployability via `runtime_status` + `recommendable`; §5 enforces both. |
| M18 | Full-utilization wording | §4 separates ranking from displayed capacity; §7 uses per-token rates only. |
| M20 | Static JSON demand control plane | §3.4 requires `coordinator.streamvc.live/v1/demand-rank` with baked fallback and version metadata. |

## 11. Acceptance criteria

AC-1: `macprovider-cli autotune --recommend --json` output validates against `autotune_recommend.v1` for any Mac where `MachineFingerprinter.sample()` returns at least `ram_gb = 1`.

AC-2: JSON field order is deterministic and matches §6 exactly for stable diffs and snapshot tests.

AC-3: When all rows fail eligibility, JSON emits `recommended_model = null`, warnings include `no_eligible_model`, and human output uses the §7.2 donor-tier transcript.

AC-4 **[amended v0.6]**: Transport/HTTP unavailability may use baked demand data with `demand_rank_fallback_used`. Invalid signature/key/sidecar/schema additionally emits `demand_rank_integrity_failure`; valid-but-old/future/expired/policy-incompatible data emits `demand_rank_update_required`. Either blocking warning prevents a paid recommendation.

AC-5 **[amended v0.8.6]**: Transport/HTTP unavailability for `/v1/rate-card` or `/v1/rate-card.sig` may use the baked rate-card snapshot with `rate_card_fallback_used`. Invalid signature/key/sidecar/schema additionally emits `rate_card_integrity_failure`; valid-but-old/future/expired/policy-incompatible data emits `rate_card_update_required`. Either blocking warning prevents a paid recommendation.

AC-6 **[amended v0.6]**: Transport/HTTP unavailability may use the baked candidate catalog with `candidate_catalog_fallback_used`. Invalid signature/key/sidecar/schema additionally emits `candidate_catalog_integrity_failure`; valid-but-old/future/expired/policy-incompatible data emits `candidate_catalog_update_required`. Either blocking warning prevents a paid recommendation and coordinator join.

AC-7 **[amended v0.5]**: Repeated runs with identical hardware, catalog, rate-card, demand-rank, and benchmark inputs produce the same `recommended_model` (strict payout-first argmax + tiebreakers).

AC-8 **[deferred v0.5]**: Diversification distribution across synthetic provider IDs is suspended until supply exceeds demand.

AC-9 **[superseded v0.5]**: The 85% diversification band no longer applies. `recommended_model` is always the highest `raw_score` eligible row unless tiebreakers select among equal payout rows.

AC-10: A row with demand `recommendable: false` or candidate `runtime_status != "recommendable"` is never selected as the default recommendation.

AC-11: A row whose `model.min_ram_gb > mac.ram_gb - 4` fails `hardware_fits` and is not benchmarked. v0.4 has no arbitrary local-model or custom donor-mode path override; any donor-mode selection must still select a row from the signed selected candidate catalog and pass §3.2, §5, §8, and AC-22 controls.

AC-12 **[amended v0.9 / #742]**: A row whose local benchmark records `thermal_throttle_detected == true` fails paid eligibility (hard block). A row whose local benchmark records `swap_detected == true` — now defined as sustained CRITICAL memory pressure across the probe (≥2 samples of `kern.memorystatus_vm_pressure_level` reading Critical AND Critical forming ≥50% of the readable samples) — fails paid eligibility (hard block), MUST NOT become `recommended_model`, and emits the top-level `swap_observed_under_load` warning when the disqualification leaves no paid recommendation. Incidental single-sample pressure and Warning-majority-without-Critical-majority MUST NOT set `swap_detected` (the latter is recorded as advisory local telemetry only); `swap_detected` fails closed to true only when the entire sample series is unreadable. When every paid row fails for swap (or other §5 gates) the CLI falls to donor mode and the transcript / candidate `why` names swap.

AC-13 **[amended v0.2]**: A row whose benchmark misses `min_sustained_tps` or `max_4k_ttft_ms` emits `tps_below_gate` / `ttft_above_gate` warnings but does NOT fail eligibility on that basis alone.

AC-14: A buyer/model string that matches the rate-card only after `normalizeModelKey` is treated as rate-card-enabled and records the normalized key in the candidate model field.

AC-15 **[amended v0.8.1 / #786]**: A candidate that would match only the coordinator `default` rate-card row remains rate-card-enabled for recommendation after exact and normalized lookups miss. The recommendation MUST keep the candidate's catalog key as `recommended_model`, price the candidate with the `default` row, and emit `rate_card_default_tier_used`. Exact or normalized specific rows MUST win over `default` and MUST NOT emit the fallback warning.

AC-16: Missing candidate metadata, missing immutable `model_revision`, or missing canonical `model_sha256` for a demand/rate-card row makes the row ineligible before model download or benchmark.

AC-20: The happy-path transcript exactly matches §7.1 with per-token rate display.

AC-21 **[amended v0.7 / #742]**: The donor-tier transcript matches §7.2, including the conditional swap diagnostic when swap caused no paid row to land (AC-12).

AC-22 **[amended v0.7 / #742]**: `--donor-mode` allows a non-recommendable model to be locally committed only after printing the §8 warning, writing `donor_mode: true`, and verifying signed catalog metadata, immutable model revision, canonical artifact-set digest, `runtime_status != "blocked"`, model allowlist, RAM headroom, no-thermal-throttle, and runtime support. Swap remains advisory for donor-mode commit (paid path hard-blocks swap per AC-12); TPS/TTFT catalog gates remain advisory. Observing swap/TPS/TTFT emits warnings but does not block donor-mode commit.

AC-23: Applying donor mode for a non-recommendable row does not auto-start or auto-register a network-connected paid provider. Any network-connected donor serving is blocked until a separate donor-routing/settlement prerequisite exists.

AC-24: `macprovider-cli status` shows `DONOR MODE` when `donor_mode: true`.

AC-25: `macprovider-cli update` and installer rerun compare stored `rate_card_version`, `demand_rank_version`, `candidate_catalog_version/hash`, `binary_version`, `hardware_identity_hash`, and benchmark age with live/current values and prompt re-tune when any changed or expired.

AC-26: `macprovider-cli status` emits the stale-recommendation warning in §9 when stored recommendation metadata differs from live metadata.

AC-27: The recommendation cache at `~/.config/macprovider/last-recommendation.json` is written after a successful recommendation and contains every field listed in §9 stored state.

AC-28: Raw hardware fingerprints, serial numbers, MAC addresses, device UUIDs, and the local HMAC secret do not appear in JSON output, logs, warnings, support bundles, or `last-recommendation.json`; only domain-separated HMAC-derived identifiers are persisted.

AC-29 **[amended v0.4]**: Human output uses per-token rate display only; no hourly projections are promised or implied.

AC-34: Static candidate and demand bytes, detached signatures, trusted keyring, baked Swift payload, and manifest are generated from one canonical release input and pass exact-byte parity plus signature verification in CI, packaging, and deploy preflight.

AC-35: A v5-bridge binary accepts both configured v4 and v5 key IDs, rejects every unknown key ID, and requires a canonical 64-byte Ed25519 signature.

AC-36: A candidate and demand pair with different `version`, `generated_at`, or `policy_version` is rejected as a mixed release.

AC-37: Ranking multiplies provider completion payout, measured TPS, demand floor/weight, and bounded supply-deficit multiplier; an unrelated catalog-row edit does not invalidate stable benchmark evidence for an unchanged row.

AC-38: `/v1/status` reports catalog trust and release identity. `buyer_serving` is emitted only when the model is locally ready, the live catalog is verified, and coordinator admission is active; Malibu update success uses that state rather than transport connectivity alone.

AC-30: v0.4 implementation does not add or require a coordinator `/v1/demand-signal` endpoint, provider quota policy, or automatic model switch.

AC-31: Static JSON whose `generated_at` is more than 10 minutes in the future relative to the local clock falls back to the baked snapshot and emits the matching fallback warning.

AC-32: A non-`blocked` candidate catalog row without immutable `model_revision` or without canonical `model_sha256` is not downloaded, benchmarked, recommended, or locally committed in donor mode.

AC-33: The local HMAC secret is generated with a CSPRNG, stored in Keychain or a `0600` local file, never emitted outside the host, and uses separate domain labels for diversification and recommendation-cache identity.

AC-34: After downloading a model by immutable `model_revision`, the CLI computes the canonical artifact-set hash exactly as specified in §3.2 and fails closed before benchmark, recommendation, local donor-mode commit, or provider run when it differs from catalog `model_sha256`.

AC-35: Bandwidth-tier eligibility is deterministic: a Tier-C Mac fails a row with `min_bandwidth_tier = "A"` when all other gates pass, while a Tier-A or Tier-S Mac passes that row when all other gates pass.

AC-36: A downloaded model snapshot containing symlinks, hardlinks with link count greater than one, special files, absolute paths, path escapes, or `..` path segments fails artifact verification before benchmark, recommendation, local donor-mode commit, or provider run.

AC-37 **[amended v0.8.6]**: Unauthenticated `GET https://coordinator.streamvc.live/v1/rate-card` and `GET https://coordinator.streamvc.live/v1/rate-card.sig` reach the coordinator buyer mux through nginx and return the §3.3 schema/sidecar; both nginx routes are declared before the generic `/v1/` 404 block.

AC-38: `rate_card_version` changes when the recommendation projection rows, provider share, global multiplier, or `usd_per_million_credits` change, and does not change when unrelated quarantine, request-log, operator, ledger runtime, or settlement runtime state changes.

AC-39: `candidate_catalog_sha256` is computed over the exact selected catalog JSON bytes, so changing catalog whitespace changes the stored hash while preserving schema validation behavior.

AC-OMLX-1: A row with `bench_gate.provenance.source == "omlx_seeded"` and `runtime_status == "recommendable"` is rejected by catalog validation.

AC-OMLX-2: A row with `bench_gate.provenance.source == "omlx_seeded"` and a missing, malformed, or incomplete `bench_gate.gate_seed` is a catalog-integrity failure rejected fail-closed at catalog authoring, lint, and signing (the same authoring boundaries as the forbidden-seed-on-non-oMLX-row case, AC-OMLX-7). At CLI/coordinator decode the effect is phase-qualified (§12.3): PRE-activation the mere presence of the unsupported oMLX schema is a whole-catalog integrity failure; POST-activation the malformed row decodes successfully and is row-scoped quarantined (excluded from download/benchmark/donor/recommendation), never a whole-catalog failure and never blocking coordinator join or SPEC-032 admission.

AC-OMLX-3: `autotune --recommend` never selects an `omlx_seeded` row as the default recommendation.

AC-OMLX-4: In Stage 1, promotion of an `omlx_seeded` (or formerly-`omlx_seeded`) row to `recommendable` is PROHIBITED and fails closed (the row stays `listed`) because the Stage-2 verified-evidence-record mechanism (signed immutable per-measurement references + deterministic aggregation) does not yet exist, so no promotion can be proven backed by the `N = 3` verified measurements. The transition is DEFINED but inert. When that mechanism exists, promotion is refused unless at least `N = 3` verified provider autotune measurements on eligible hardware exist and promotion depends solely on those measurements: the oMLX seed is NEVER the pass/fail criterion and is NEVER an input to the promoted gate — the promoted `min_sustained_tps` is recomputed solely from the `N` verified measurements, the promoted row has `bench_gate.provenance.source == "verified_provider_matrix"`, and it carries no `gate_seed`. A promotion computed by testing verified runs against the provisional oMLX gate, that reuses the oMLX seed value in the promoted gate, or that is performed before the Stage-2 evidence-record mechanism exists, is rejected.

AC-OMLX-5: Seeded `min_sustained_tps` equals `max(8, floor(board_p25_tg * engine_delta_applied * 0.90))` computed from the row's own `gate_seed` values; a row whose stored `min_sustained_tps` does not equal that computed value is rejected as a catalog-integrity failure. (This AC is NOT satisfied by always emitting `8`: a well-formed seed whose computed value exceeds 8 MUST store that higher value, and a row that stores `8` when the formula yields a higher number is rejected.) A seed derived from a `.dev` oMLX board release or from undiscounted MTP/speculative-decode observations is rejected.

AC-OMLX-5a (positive fixture): A well-formed `omlx_seeded` row with `board_p25_tg = 90.6`, `engine_delta_applied = 0.85`, `observations_used_n >= K`, a stable (non-`.dev`) `board_release_tag`, `mtp_discounted = true`, and a `seeded_at` within the freshness window computes `min_sustained_tps == max(8, floor(90.6 * 0.85 * 0.90)) == 69` and is accepted (as `candidate` or `listed`).

AC-OMLX-5b (K rejection): An `omlx_seeded` row with `gate_seed.observations_used_n < K` (`K = 10`) is rejected — ineligible and fail-closed before download or benchmark.

AC-OMLX-5c (cross-cell rejection): An `omlx_seeded` row whose `gate_seed` observations span more than one normalized cell — a mix of chips, RAM classes, models, quants, or context lengths not all within its declared `gate_seed.target_cell` — is rejected as a catalog-integrity failure, even when the aggregate `observations_used_n >= K`. `observations_used_n` is bound to the single `target_cell`.

AC-OMLX-6: Recommendation JSON, human `autotune --recommend` output, and `macprovider-cli status` surface oMLX provenance as provisional and not macprovider-verified. `macprovider-cli status` reads the persisted recommendation state (§9), which retains the selected row's `bench_gate.provenance.source` and `gate_seed` identity, and MUST render the exact label `oMLX-seeded; not macprovider-verified` for a selected `omlx_seeded` row.

AC-OMLX-7 (no laundering): A catalog row whose `bench_gate.provenance.source != "omlx_seeded"` that carries a `bench_gate.gate_seed` is a catalog-integrity failure, rejected fail-closed at catalog authoring, lint, and signing, and at CLI catalog decode.

AC-OMLX-8 (no raise, no hard-block): An `omlx_seeded` gate never raises a gate whose provenance is verified provider/local evidence and never causes a provider hard-block. The advisory `bench_gate.min_sustained_tps`/`max_4k_ttft_ms` are never a coordinator admission veto; any hard performance admission gate is backed by verified-provider evidence, not the advisory `bench_gate` (see SPEC-032 FR-HG3/FR-HG4 and §5).

AC-OMLX-9 (TTFT not tightened): `max_4k_ttft_ms` is never tightened from oMLX PP/prefill proxy data; a seeded row either inherits an existing conservative TTFT value or leaves TTFT unset for advisory warning only until verified provider autotune supplies measured TTFT.

AC-OMLX-10 (semantic-failure fail-closed): An `omlx_seeded` row with a `.dev` `board_release_tag`, undiscounted MTP/speculative-decode source, duplicate/cross-bucket cells, an invalid/out-of-order/future timestamp, a `seeded_at` older than the 120-day freshness window, or a seed-formula mismatch is a catalog-integrity failure that blocks catalog authoring/lint/signing and is excluded from download, benchmark, donor selection, and recommendation. Its decode-time effect is phase-qualified (§12.3): PRE-activation the unsupported oMLX schema is a whole-catalog integrity failure; POST-activation the row decodes successfully and is row-scoped quarantined (not a whole-catalog failure). In neither phase does it block, gate, or otherwise affect any provider's SPEC-032 verified-hardware coordinator admission — oMLX data (valid or invalid) never hard-blocks a provider.

AC-OMLX-11 (Stage-1 activation-gate safety boundary): Before the §12.2 activation gate is satisfied, a signed or served candidate catalog contains NO `omlx_seeded` row; a release process that publishes or serves an `omlx_seeded` row (or any `gate_seed` / `verified_provider_matrix` value) into a signed/served catalog before all activation-gate conditions (forward-compat across coordinator Go validators and CLI Swift decoders, plus the shipped Stage-2 enforcement (i)-(v)) are met is a release-process violation and is rejected.

AC-OMLX-12 (`verified_provider_matrix` reserved): Any newly created or modified catalog row with `bench_gate.provenance.source == "verified_provider_matrix"` is rejected at catalog authoring, lint, and signing. In Stage 1 no such row may exist; the value is inert until the Stage-2 verified-evidence-record mechanism ships.

AC-OMLX-13 (field-laundering forbidden): An `omlx_seeded` row (or its `gate_seed`) that creates or changes any field other than `bench_gate.min_sustained_tps` and its `gate_seed` metadata — in particular `min_ram_gb`, `min_bandwidth_tier`, `runtime_status`, `model_key` / `model_revision` / `model_sha256`, demand-rank, or rate-card/pricing/admission/routing fields — is a catalog-integrity failure. Specifically, an oMLX-derived or oMLX-modified `min_ram_gb` (which SPEC-032 would use for `autotune_model_cap_exceeded`) is rejected.

AC-OMLX-14 (seed↔row binding): An `omlx_seeded` row whose `gate_seed.target_cell.model_key` does not equal the enclosing row's normalized `model_key`, or whose `target_cell` model/quant/context is inconsistent with the row's model identity, is a catalog-integrity failure.

AC-OMLX-15 (row-scoped quarantine, not fleet-blocking): POST-activation (§12.3), a single semantically-invalid `omlx_seeded` row is row-scoped quarantined — excluded from download, benchmark, donor selection, and recommendation — and does NOT cause a whole-catalog decode/integrity failure, does NOT block coordinator join, and does NOT affect SPEC-032 admission. PRE-activation, by contrast, any oMLX schema in a served catalog is a whole-catalog fail-closed integrity failure (the gate). Whole-catalog `candidate_catalog_integrity_failure` (AC-6) remains reserved for signature failure, global-schema failure, a non-oMLX-row integrity failure, or the pre-activation presence of the unsupported oMLX schema.

AC-OMLX-16 (no-oMLX-derivation gate — anti-erasure-laundering): Before the §12.2 activation gate is satisfied, a signed or served catalog row whose value is DERIVED from oMLX data is a gate violation regardless of its `provenance.source` label — including a row labeled `policy`, `measured_single_host`, or any non-`omlx_seeded` value with `gate_seed` removed. The signer attests no row was oMLX-derived pre-activation; post-activation, immutable provenance lineage (§12.2(b)(v)) records any oMLX origin so an oMLX-derived value cannot be relabeled to escape the oMLX restrictions, and may transition only to evidence-bound `verified_provider_matrix`.

## 12. oMLX-seeded provisional catalog gates


oMLX community benchmark data is self-reported and unattested. It MAY inform
the starting advisory `bench_gate.min_sustained_tps` of a non-default candidate
catalog row only when the row remains provisional. It MUST NOT set or hold the
`bench_gate` of a `recommendable` row, raise a gate whose provenance is verified
provider/local evidence, hard-block a provider, or serve as the sole (or partial)
evidence for promotion to `recommendable`. Because the advisory `bench_gate` is
never an admission veto, SPEC-032's hello-gate no longer hard-gates admission on
`bench_gate.min_sustained_tps`/`max_4k_ttft_ms` (SPEC-032 FR-HG3/FR-HG4); a hard
performance admission gate is a separate field backed by verified-provider
evidence.

An oMLX-seeded row MUST use `bench_gate.provenance.source == "omlx_seeded"` and
MUST include `bench_gate.gate_seed` per §3.2. oMLX-seeded rows MAY appear only
with `runtime_status` equal to `candidate` or `listed`; they MUST NOT appear with
`runtime_status == "recommendable"`.

An oMLX-seeded `min_sustained_tps` MUST be derived from the filtered oMLX
distribution, not copied directly from board TG. The relationship is binding
(a mismatch is a catalog-integrity failure, §3.2):

```text
min_sustained_tps == max(8, floor(board_p25_tg * engine_delta_applied * 0.90))
```

where `board_p25_tg` is the filtered 4k-context, matching-quantization p25
generation (decode) throughput of the target normalized cell after duplicate
and outlier handling, and `engine_delta_applied` is the row's
`gate_seed.engine_delta_applied` (the current tracked stable oMLX release's
macprovider runtime delta). The date-window reference point for the filter
below is the row's `gate_seed.seeded_at`.

`RESEARCH_231`'s "never below 75% of local median when local bench exists"
clause is intentionally not carried into this formula: an oMLX-seeded row
by definition has no qualifying local or verified-provider benchmark for
that model/hardware bucket yet (§3.2, §5) — if one existed, the row would
not need an oMLX seed. The clause is preserved as a candidate v0.2 input if
a future workflow ever re-seeds a row that already has partial local
evidence.

The seed is usable only when at least `K = 10` oMLX **observations** remain
within the target normalized chip/RAM/model/quant/context cell after duplicate
collapse and outlier trimming (`gate_seed.observations_used_n >= K`); `K` is an
intra-cell observation count, not a count of distinct cells. Observations used
for the seed MUST be 4k-context, matching-quantization observations, dated
within 120 days of `gate_seed.seeded_at`, and dated on or after 2026-05-01.
Name-only aliases, community merges, and non-matching artifacts MUST NOT seed a
gate. A seed whose `seeded_at` or board snapshot is older than the 120-day
freshness window is stale: the row is ineligible and MUST be re-seeded from a
fresh oMLX snapshot rather than remaining provisional indefinitely (§3.2).

`engine_delta` MUST reflect the current tracked stable oMLX release and the
macprovider runtime delta. `.dev` oMLX board releases MUST NOT be used as seed
authority. If MTP or speculative-decode rows are present, the seed MUST use
non-accelerated rows or explicitly discount accelerated rows; undiscounted
accelerated rows MUST NOT seed a gate.

`max_4k_ttft_ms` MUST NOT be tightened from oMLX PP/prefill proxy data. A seeded
row may inherit an existing conservative TTFT value or leave TTFT unset for
advisory warning only until verified provider autotune supplies measured TTFT.

Promotion from `listed` to `recommendable` depends solely on at least `N = 3`
verified provider autotune measurements on eligible hardware. The oMLX seed is
NEVER the pass/fail criterion for promotion and is NEVER an input to the
promoted gate: the promoted `min_sustained_tps` (and any `max_4k_ttft_ms`) is
recomputed solely from those `N` verified provider measurements. On promotion,
the operator MUST recompute the advisory gate from the verified provider
measurements alone, set `bench_gate.provenance.source` to
`verified_provider_matrix` (§3.2), and remove `bench_gate.gate_seed`. The oMLX
seed is discarded at promotion.

**Promotion is PROHIBITED until the Stage-2 evidence-record mechanism exists
(fail-closed deferral).** The concrete evidence-record binding the `N` verified
measurements — signed immutable per-measurement references plus deterministic
aggregation of those measurements — is deferred to a later stage. Until that
mechanism exists, a promotion cannot be verifiably proven backed by the `N`
measurements, so promotion MUST NOT be performed: the transition and its target
provenance (`verified_provider_matrix`) are fully specified here, but in Stage 1
the transition is inert and any attempted promotion fails closed (the row stays
`listed`). A row is promoted only once the Stage-2 mechanism can prove the `N`
verified measurements back the recomputed gate.

### 12.1 K/N threshold justification

The `RESEARCH_231` prompt asked for cells that are "statistically reliable enough" to inform catalog rows, and explicitly required conservative calibration: p25-based gate slack, uncertainty bands, and advisory-only treatment until macprovider repros the result. `RESEARCH_231`'s `n >= 10` is a per-cell sample-size threshold: a normalized chip/RAM/model/quant/context cell is percentile-reliable enough to seed a p25-based gate only once it holds at least 10 oMLX observations after duplicate collapse and outlier trimming. We adopt `K = 10` as exactly that minimum intra-cell observation count (`gate_seed.observations_used_n`); it is the number of observations required WITHIN the one target cell, not a requirement that 10 distinct cells exist or agree. A cell with fewer than 10 post-dedup/outlier observations does not clear the memo's percentile-reliability bar and MUST NOT seed a gate.

`N` serves a different purpose than `K`. Whereas `K` is the intra-cell sample size that makes a single oMLX cell's p25 statistically usable as a provisional seed, `N` counts repeated verified provider autotune measurements on eligible hardware before replacing provisional oMLX evidence with verified-provider evidence. The purpose of `N` is to reduce the likelihood that a single anomalous benchmark run (for example due to transient system load, thermal state, or other run-to-run variability) determines promotion of a catalog row.

### 12.2 Stage-1 forward-declaration & activation gate

The oMLX-seeded schema defined by this SPEC — `bench_gate.provenance.source ==
"omlx_seeded"`, the `bench_gate.gate_seed` object, and the
`verified_provider_matrix` provenance value — is **FORWARD-DECLARED** in Stage 1.
It defines the normative contract but is **NOT activated**: it MUST NOT be
emitted into any signed or served candidate catalog until the activation gate
below is satisfied. This is deliberate. The deployed coordinator Go feed
validators and CLI Swift strict decoders were built before this schema and
fail-close on unknown provenance/`gate_seed` shapes; publishing an `omlx_seeded`
row into a live signed catalog now would reproduce the #813
forward-incompatibility trap and fail-close the fleet (integrity failure on the
whole catalog, blocking autoupdate and coordinator join).

**Activation gate — all of the following are required before any `omlx_seeded`
row may appear in a signed or served candidate catalog:**

(a) **Forward-compat across every consumer.** Every catalog consumer — the
coordinator Go feed validators AND the CLI Swift strict decoders — accepts the
new schema (`omlx_seeded`, `gate_seed`, `verified_provider_matrix`) without
integrity failure.

(b) **Stage-2 enforcement has shipped.** The following are normative Stage-2
requirements the implementation MUST satisfy (they cross-reference the r3 audit's
implementation findings; none is implemented by this docs-only amendment):

  (i) **Admission-identity excludes advisory fields.** Coordinator admission
  identity / verified-evidence match MUST NOT include the advisory
  `bench_gate.min_sustained_tps` / `max_4k_ttft_ms`, `bench_gate.provenance`, or
  `bench_gate.gate_seed`; a separate admission identity (SPEC-032 FR-HG3/FR-HG4,
  §5) is enforced instead, so unattested oMLX data can never hard-block a
  provider.

  (ii) **Network-connected providers are `recommendable`-only.** The coordinator
  enforces `runtime_status == "recommendable"` for network-connected providers;
  provisional (`candidate` / `listed`, including every `omlx_seeded`) rows are
  local-only and never buyer-routable.

  (iii) **Row-scoped quarantine (§12.3).** An invalid `omlx_seeded` row is
  row-scoped quarantined and MUST NOT cause whole-catalog decode/integrity
  failure, block coordinator join, or affect SPEC-032 admission.

  (iv) **Evidence-bound promotion.** `verified_provider_matrix` promotion is
  bound to the Stage-2 verified-evidence-record mechanism (signed immutable
  per-measurement references + deterministic aggregation, §5/§12); until it
  exists the value is reserved and inert.

  (v) **Immutable provenance lineage.** Every catalog row carries an immutable
  provenance lineage such that a row ever derived from oMLX data retains that
  lineage regardless of its current `provenance.source` label. A lineage-marked
  row may transition ONLY to evidence-bound `verified_provider_matrix` (never to
  `policy`, `measured_single_host`, or any other label that would erase the oMLX
  origin). This makes the authoring-process prohibition below detectable
  post-activation by tooling, not merely a process promise.

**No-oMLX-derivation gate (broadened — closes provenance-erasure laundering).**
Before the activation gate is satisfied, NO catalog row may be DERIVED from oMLX
data in ANY form. This is broader than banning the `omlx_seeded` schema: a
catalog author MUST NOT ingest or derive any field value (a `min_sustained_tps`,
a `min_ram_gb`, a tier, or anything else) from oMLX community data into a signed
or served catalog — not as an `omlx_seeded` row, and not laundered into a
`policy` / `measured_single_host` / any other provenance label with the
`omlx_seeded` marker and `gate_seed` stripped. All oMLX restrictions in this SPEC
key off the oMLX-derived nature of a value, not merely off the current
`provenance.source` string; stripping the label does not launder the value out
of scope. This is an authoring-process prohibition consistent with the
signer-trust model: the operator who signs the catalog attests that no row in it
was derived from oMLX data before activation (AC-OMLX-16).

Until the gate is satisfied, a signed or served candidate catalog MUST NOT
contain any `omlx_seeded` row NOR any row derived from oMLX data under any other
label. Publishing or serving such a row before the gate is a **release-process
violation**. This is the Stage-1 safety boundary (AC-OMLX-11 / AC-OMLX-16): the
contract is fully specified so Stage-2 can build to it, while the live fleet sees
no schema change and cannot be fail-closed by it.

### 12.3 Quarantine, phase-qualified by activation

The handling of an `omlx_seeded` row splits on the §12.2 activation state, and
the two phases MUST NOT be conflated:

**PRE-activation (the gate).** No consumer supports the oMLX schema yet, so ANY
`omlx_seeded` row (or `gate_seed` / `verified_provider_matrix` value) present in a
signed or served catalog is globally rejected and fail-closed — it is a
whole-catalog integrity failure (`candidate_catalog_integrity_failure`) that
blocks paid recommendation and coordinator join, exactly as §3.5 and AC-6 already
require for unknown/invalid schema. This IS the activation gate: an oMLX schema
must never reach the pre-activation fleet, and if one does, fail-closed rejection
is correct. (This is also why the gate forbids emitting such rows at all, §12.2.)

**POST-activation (row-scoped quarantine).** Once activated (§12.2) every consumer
decodes the oMLX schema successfully. A semantically-invalid `omlx_seeded` row
(any §3.2 catalog-integrity failure: malformed/incomplete `gate_seed`,
seed-formula mismatch, `.dev` board, undiscounted acceleration, cross-cell
observations, stale-beyond-window seed, or a mis-bound `target_cell`) then
decodes SUCCESSFULLY at the whole-catalog level and MUST be **row-scoped
quarantined**: that single row alone is excluded from download, benchmark, donor
selection, and recommendation, and MUST NOT be emitted as an active row. A single
invalid oMLX row MUST NOT cause a whole-catalog decode or integrity failure, MUST
NOT block coordinator join, and MUST NOT affect any provider's SPEC-032
verified-hardware admission.

This reconciles with the §3.5 static-feed integrity contract and AC-6:
whole-catalog admission failure (`candidate_catalog_integrity_failure`, blocking
paid recommendation and coordinator join) remains reserved for **signature
failure, global-schema failure, a non-oMLX-row integrity failure, or (pre-activation
only) the mere presence of the not-yet-supported oMLX schema**. Post-activation, a
single malformed `omlx_seeded` row is row-scoped-quarantined, never fleet-blocking.
(The post-activation row-scoped-quarantine enforcement is Stage-2 prerequisite
§12.2(b)(iii); this subsection is the normative obligation it must satisfy.)

### 12.4 Field-laundering prohibition, reserved provenance & seed↔row binding

**Field-laundering prohibition.** oMLX data MAY seed ONLY
`bench_gate.min_sustained_tps` (together with its `bench_gate.gate_seed`
metadata). It MUST NOT create or change `min_ram_gb`, `min_bandwidth_tier`,
`runtime_status`, model identity (`model_key`, `model_revision`, `model_sha256`),
demand-rank fields, rate-card / pricing fields, or ANY admission/routing field.
This is load-bearing: an oMLX-derived `min_ram_gb`, for example, would flow into
SPEC-032's capacity ceiling and let `autotune_model_cap_exceeded` hard-block a
provider on unattested community data — exactly the invariant violation this
prohibition forecloses (AC-OMLX-13).

**`verified_provider_matrix` reserved in Stage 1.** No catalog row may carry
`bench_gate.provenance.source == "verified_provider_matrix"` yet, because the
Stage-2 evidence binding that justifies it does not exist. Any newly created or
modified catalog row using that provenance value MUST be rejected at catalog
authoring, lint, and signing (AC-OMLX-12). The value is inert until Stage-2
evidence binding ships; it closes the provenance-laundering path at the
schema/signing layer, not merely in prose.

**Seed↔row binding.** `bench_gate.gate_seed.target_cell.model_key` MUST equal the
enclosing catalog row's normalized `model_key`, and the cell's model / quant /
context MUST be consistent with the row's own model identity. A `gate_seed`
whose `target_cell` targets a different model than the row that carries it is a
catalog-integrity failure (AC-OMLX-14).

Therefore `N = 3` is adopted as a conservative verification policy rather than a value derived from the oMLX dataset. One run cannot distinguish a repeatable result from a transient outlier, while two runs provide no tie-break when they disagree. Three independent verified provider autotune measurements provide a majority-consistency check before promotion while keeping verification operationally practical.

## 13. Open questions / v0.2 candidates

Q1: Live coordinator `/v1/demand-signal` endpoint and switch trigger. v0.2 may use local attempted-demand stats only after at least 60 days history, 50M paid or auth-valid requested completion-token equivalent, 5 buyer accounts or partner keys with non-test traffic, and no single buyer contributing more than 50% of model demand.

Q2: Tier-specific `tier_weight` calibration. v0.4 locks all tier weights to `1.0`.

Q3: Provider TPS reputation downweighting from production traffic.

Q4: Utilization-adjusted realized-earnings projection once buyer history exists.

Q5: Coordinator broadcast of "recommendation changed" on hot reload, with provider auto-prompt.

Q6: Per-provider quota / coverage allocation policy.

Q7: Collusion detection / cartel monitoring.

Q8: Cross-Mac transfer of recommendation, such as an operator cloning config to a second Mac.

Q9: Donor-mode time-limited grant of token rewards and any `TOKEN_NAME` ledger interaction.

Q10: Static JSON key rotation policy after the release-pinned Ed25519 v0.4 key ages out.

Q11: How to represent model quality and buyer-acceptance scores without creating a new Goodhart target.

Q12: Whether minimum provider coverage targets should become an active recommendation input once provider-count telemetry exists.

Q13: Adaptive `N` for oMLX-seeded promotion. Replace fixed `N = 3` with a minimum and maximum of verified provider autotune runs. The promoted gate would still be recomputed solely from the verified sustained-TPS distribution (never from, nor tested against, the provisional oMLX seed — consistent with §12 and AC-OMLX-4); promotion would trigger once a one-sided ~95% lower confidence bound on the verified sustained-TPS distribution is high enough to set the recomputed `verified_provider_matrix` gate with confidence. If unmet after 7 runs, the row remains `listed`. (Like fixed `N`, this remains subject to the Stage-1 prohibition until the Stage-2 evidence-record mechanism exists.)

## 14. Differentiation framing

macprovider's provider-install UX sits in a gap left by most decentralized GPU networks. Vast, RunPod, io.net, Akash, Aethir, Render, and Bittensor generally expose raw capacity, bids, node eligibility, subnet incentives, or buyer-selected workloads; their public provider flows do not show an installer-time recommendation that says "given this hardware, run this model to earn the most." That difference follows from their market structure: the buyer brings a container, manifest, render job, or subnet task, while the provider supplies capacity or competes under a protocol.

The closest competitive exception is Darkbloom. Its public pages show an Apple-Silicon inference network, a CLI provider install path, and an earnings calculator that auto-selects the "most profitable" model for a chosen Mac hardware profile. macprovider should not claim the whole idea is unobserved. The sharper wedge is that SPEC-023 makes the recommendation local, installer-integrated, benchmark-backed, and machine-readable via `autotune --recommend`, rather than only a web estimate.

The right UX lineage is not generic cloud hosting. It is staking calculators and mining profitability calculators: ranked yield options, transparent assumptions, power/rate inputs, confidence, and stale-data warnings. macprovider has the same shape: detected hardware plus measured tokens/sec plus a per-model rate card plus demand assumptions yields a ranked recommendation.

This will not create demand where none exists. SPEC-023 answers "which model should this provider run, given known rates and measured local performance?" It does not answer "will buyers show up?" The UX must say that clearly: per-token rates are set by the rate card, and real earnings = tokens served × rate.

## 15. Threat model

| Threat | Capability | v0.4 defense | Deferred |
|---|---|---|---|
| Static JSON tampering | DNS, CDN, or static-host compromise attempts to alter demand weights, `recommendable`, or candidate gates | §3.5 Ed25519 detached signatures, release-pinned public key, fallback to baked snapshot on invalid/missing/stale signed data | Key rotation automation in v0.2 |
| Static JSON replay | Attacker serves an old but once-valid static file | §3.5 rejects files older than baked snapshot and files older than 30 days; 14-30 days emits `demand_rank_stale` or `candidate_catalog_stale` | Transparency log or monotonic operator epoch in v0.2 |
| Untrusted candidate metadata or mutable model artifact | Malicious metadata points to oversized/unsafe model, weak gates, or a mutable model-host branch that changes after signing | §3.2 signed candidate catalog, allowlisted model IDs, immutable `model_revision`, required canonical `model_sha256`, and missing metadata/digest fail-closed before download/benchmark | Richer artifact transparency log in v0.2 |
| Provider benchmark gaming | Provider optimizes or tampers with local benchmark | §5 requires CLI-owned benchmark, sustained TPS, TTFT, no-swap, no-thermal checks; production TPS reputation deferred | Coordinator production feedback in v0.2 |
| Donor-mode abuse | Operator commits non-recommendable row and receives paid buyer traffic | §8 keeps donor mode local-only for non-recommendable rows and blocks network-connected paid registration until a separate donor-routing/settlement prerequisite exists | Explicit donor traffic class or rewards policy in v0.2 |
| Fingerprint leakage | Stable hardware identity links provider across runs or support bundles | §3.1 and §9 require per-install-secret, domain-separated HMAC-derived identities only; AC-28 and AC-33 ban raw fingerprints and HMAC secrets in persisted/output paths | Formal privacy review if identities become network-visible |
| Misleading earnings claims | Provider interprets displayed tokens/sec as guaranteed realized income | §6 and §7 show per-token rate and per-token formula only; AC-29 enforces transparency | Utilization-adjusted realized projection in v0.2 |
| Clean-room violation | Competitive framing accidentally depends on Darkbloom source | §2 and §14 restrict Darkbloom references to public surfaces only | None; source inspection remains prohibited |
