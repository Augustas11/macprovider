# SPEC-023 — Installer-Integrated Autotune Recommend

version: v0.10.2
status: LOCKED
owner: operator (a11)
last-locked: 2026-09-09

## Change log

- **v0.10.2 (2026-09-10)** — §6 output contract and §3.7.2 consumption scope reconciled with the §3.7 artifact feed (BYOM v0.2 slice 2c).
  1. §6 `warnings[]` now lists the four v0.10.0 artifact-feed codes (`catalog_artifact_feed_fallback_used`, `catalog_artifact_feed_integrity_failure`, `catalog_artifact_feed_update_required`, `catalog_artifact_feed_stale`) and scopes its blocking sentence: those codes are excepted by §3.7.6 rule 6 and never block a paid recommendation.
  2. §3.7.2 signer-identity equality: the `release.json` leg is checked at generation and by every consumer that holds the authenticated manifest (`verify`, the acceptance signer, the live coordinator release gate); a fetching CLI holds no authenticated manifest for a newer live release and enforces the two authenticated signers it holds (candidate feed and artifact feed), plus the manifest-bound signer compiled in beside its snapshot. The substance of AC-CAT-1 — a valid signature by a second concurrently trusted key fails — holds on every path.
- **v0.10.1 (2026-09-09)** — Canonical artifact manifest path grammar hardening.
  1. `model_sha256` canonical manifest entries keep the existing `path LF size_decimal LF sha256_hex LF` serialization, but normalized POSIX relative paths containing C0 control characters or DEL are now forbidden.
  2. The CLI MUST enforce the same control-character rejection both when accepting remote snapshot paths for download and when inspecting the downloaded filesystem tree before hashing, closing ambiguous line-delimited manifest encodings without changing the digest format for valid snapshots.

- **v0.10.0 (2026-09-08)** — Catalog as a pipeline: artifact sets, class rate rows, listed-tier intake (BYOM v0.2 prerequisite).
  1. **A catalog model key now carries a SET of verified artifacts, not one.** New §3.7 defines a separate signed static feed (`autotune-artifacts.json`, served at `/v1/catalog-artifacts` with a detached `.sig`) whose per-model artifact entries each carry their own runtime format, quantization, immutable source reference, hash + hash algorithm, size, per-artifact `min_ram_gb`, allowed SPEC-046 runtime sources, and a `declared` / `verified` / `blocked` verification status. Pricing is **model-key scoped**: every artifact of a model key carries the same price. Settlement identity is not: in v0.10.0 only the model key's **primary** artifact — the `mlx_safetensors` entry named by `primary_artifact_id`, hashed under `macprovider.snapshot-manifest.v1`, whose `hash` is byte-identical to the candidate row's `model_sha256` — may reach `catalog_priced` or `settlement_capable`, be reported as the SPEC-010 `model_hash`/`model_hash_algorithm` wire pair, or bind a SPEC-022 route-time settlement snapshot. Every non-primary artifact of any format is a matchable identity that stays **unpriced and non-settling** pending the SPEC-010 amendment (§13 Q14). `mlx_safetensors` (hash = the existing SnapshotManifestV1 manifest digest) and `gguf` (hash = SHA-256 of the GGUF file bytes, which is what Ollama exposes as its layer digest) are the v0.10.0 formats. `verification_status: "verified"` is necessary but never sufficient for settlement; a `declared` or `blocked` artifact binds nothing at all. Within one artifact feed a `(hash_algorithm, hash)` pair MUST appear under exactly one model key and exactly one `artifact_id`, so a matched hash resolves to exactly one pricing identity.
  2. **The artifact set is a SEPARATE signed feed, never a new field in the candidate-catalog bytes.** §12.2 already documents the #813 forward-incompatibility trap: deployed coordinator Go validators and the CLI Swift strict decoders (`AutotuneStrictJSON.validateCandidate`) reject unknown candidate-row keys and would fail-close the fleet. §3.7 therefore binds the artifact feed to the candidate-catalog `release_id` and body digest instead, keeps the existing top-level `model_id` / `model_revision` / `model_sha256` unchanged as each row's primary MLX artifact for every v0.1 consumer, and requires that primary artifact to reappear in the artifact feed with an identical hash (consistency checked at generation and at consumption). A missing, stale, or untrusted artifact feed suppresses only the new artifact-derived capabilities; it MUST NOT block the v0.1 paid-recommendation or coordinator-join paths.
  3. **Pricing gains market-pegged model classes without touching billing.** New §3.3.1 adds a closed `rate_class` enum, carried on the artifact feed's model entry (for the same forward-compatibility reason as point 2) and expanded by the catalog release generator into the existing per-model `rows` of the PUBLISHED rate-card feed and the coordinator inline fallback rows. The published §3.3 rate-card schema is unchanged, so SPEC-005 §5.5 rate resolution (exact → normalized → `default`) is untouched and is NOT amended by this revision. An explicit model row always wins over class expansion, and the first release that introduces class expansion MUST publish byte-identical rate-card `rows`.
  4. **`listed` becomes the cheap intake tier.** §3.2 and new §16 make `listed` mean identity plus at least one verified artifact: discoverable, BYOM catalog-matchable, probe-eligible, and eligible for SPEC-047 `network_visible_unpriced` — but never a paid default and never requiring a rate class. `recommendable` additionally requires a `rate_class` that resolves to a rate row, plus the existing operator admission. Bench-provenance rules are unchanged and the §12 Stage-2 oMLX automation stays defined-but-deferred.
  5. **Catalog intake is a defined pipeline with named signals and thresholds.** §16 defines a monthly release cadence (out-of-band releases only for `blocked` transitions), three intake signals — buyer demand (the §3.4 OpenRouter demand-rank snapshot plus a new SPEC-017 aggregated unknown-model-key request count, specified here and to be implemented under SPEC-017 authority), aggregated provider supply from SPEC-047 admission events, and fleet hardware fit against per-artifact `min_ram_gb` — and an operator-tunable admission rule with stated defaults. It states how the `listed` tier and rank floors mitigate `RESEARCH_229` FM-1 (winner-take-all herding) and FM-2 (cold-start exclusion), and restates the non-goal: no open marketplace, no provider-set prices, non-catalog models stay non-earning (SPEC-047 §1).
  6. **New requirements and criteria.** `SPEC-023-R004` (artifact feed), `SPEC-023-R005` (class rate expansion), and `SPEC-023-R006` (listed-tier intake) are added with acceptance criteria AC-CAT-1..AC-CAT-21, four new §15 threat-model rows (artifact substitution, class mis-declaration, intake-signal gaming, unknown-model-key fanout), and §13 annotations. This is a docs-and-governance revision: it changes no catalog JSON, no generator code, and no Go/Swift code.
  7. **Safety invariants travel with the signals and schemas they protect.** §3.7.3 closes the artifact-feed schema explicitly at every level — top-level object, model entry, artifact entry, and each `source_ref` variant — so an unknown, missing, or wrong-typed field is `catalog_artifact_feed_integrity_failure` rather than a tolerated forward-compat field, tested by AC-CAT-1 and enforced at generation. §16.2(a) states the `unmatched_model_request_count` bounded-cardinality contract normatively here (eligible-request filtering, `NormalizeModelKey` before bucketing, a closed `[a-z0-9._/-]{1,128}` key grammar, `INTAKE_UNKNOWN_KEY_BUCKETS = 64` named buckets per window, a single `other_suppressed` overflow bucket, an `INTAKE_UNKNOWN_KEY_PRINCIPAL_CAP_PCT = 10%` per-principal cap, k-anonymity suppression, and the rule that suppressed, overflow, and capped contributions never satisfy `INTAKE_BUYER_REQUEST_FLOOR`), requires SPEC-017 to adopt it by amendment before the signal may satisfy any intake floor, and adds AC-CAT-13 and the §15 unknown-model-key-fanout row. §3.7.4 narrows `declared` artifacts to operator backlog and review material only.
  8. **Activation, identity, and aggregation are pinned to what today's fleet and today's sibling specs actually accept.** New §3.7.8 defines the feed's `release.json` binding, the release-ledger feed-set evolution rule (three historical sets stay permanently valid; a fourth artifact-bound five-feed set is added and becomes mandatory from the activation release), and a §12.2-style **two-stage activation**: at Stage A the feed is generated, signed, served, baked, release-bound, and ledger-recorded but is NOT added to the compatibility-set manifest's exact nine-name `components.catalog.files` map, so a v0.10 payload installs on every already-shipped updater; Stage B may widen that map only after a bridge CLI has shipped stable AND previous-stable is at or after it. §3.7.4 adds a **closed artifact-identity matrix** binding `runtime_format` to its only legal `hash_algorithm`, `source_ref.kind`, and `allowed_runtime_sources` set, so an individually schema-valid but semantically inconsistent tuple is an integrity failure at generation and consumption. §3.7.4, §3.7.7, §13 Q14, AC-CAT-7, AC-CAT-17, and the SPEC-047-R003 amendment restrict `catalog_priced`/`settlement_capable`, the SPEC-010 wire pair, and SPEC-022 settlement bindings to the **primary artifact only** — a secondary MLX quantization is excluded on the same SPEC-010-R001/R004 ground as a GGUF artifact — so v0.10.0 is strictly consistent with SPEC-010 as it stands and needs no SPEC-010 amendment. §3.3.1 removes `provider_share_bps`/`global_multiplier_ppm` from class rows (they are release-global values that the coordinator's `rewards.rate_card` rows cannot represent), states the exact JSON-to-YAML field mapping, and adds a generated-feed / billing-config parity release gate. §16.2(a) replaces exact-top-N semantics with one complete bounded model — a named Space-Saving summary with deterministic eviction, conservative-lower-bound floor semantics, saturating overflow counters, and opaque window-scoped HMAC principal tokens bounded per bucket — with `INTAKE_UNKNOWN_PRINCIPALS_PER_BUCKET` and `INTAKE_UNKNOWN_KEY_DISTINCT_CAP` added to §16.4. §3.7.6 makes a stale feed fail artifact-derived capability while staying selectable for diagnostics/fallback provenance, §12.2(b)(ii) narrows the `listed` prohibition to paid and default routing while keeping `omlx_seeded` rows fully local-only, and §3.2 states what `candidate` staging does and does not authorize.

  9. **Audit R3 closures: identity resolution, staging scope, and aggregation order.** The §3.7 introduction and changelog point 1 above are restated in primary-only terms, so no sentence in this revision implies that a non-primary artifact may settle. §3.7.4 adds two normative feed invariants — **global artifact-hash uniqueness** (a `(hash_algorithm, hash)` pair appears under exactly one model key and one `artifact_id`, so a verified hash resolves to exactly one pricing identity and a provider-offered `catalog_model_key` is advisory), and **GGUF source-digest equality** (`source_ref.digest == "sha256:" + hash`) — and gives `artifact_id` a closed `^[a-z0-9][a-z0-9-]{0,63}$` grammar plus a reproducible cross-release rebinding check whose authority is the release ledger's recorded `(model_key, artifact_id, hash_algorithm, hash)` bindings (§3.7.8). The verified-primary requirement, §16.1's preconditions, and AC-CAT-11 are scoped to entry into `listed` or `recommendable`, so a `candidate` staging row may keep an all-`declared` artifact set while its `primary_artifact_id` must still name a schema-valid, identity-corresponding `mlx_safetensors` artifact. §16.2(a) gains an explicit five-step per-request processing order (S1 eligibility, S2 normalization, S3 grammar, S4 principal derivation and caps, S5 Space-Saving update) so capped and overflow contributions provably never enter a named bucket's count, and an eviction transfers only `victim_count - victim_error` into `other_suppressed`. AC-CAT-16 is extended and AC-CAT-18 and AC-CAT-19 are added.

  10. **Audit R4 closures: snapshot-bound artifact evidence, serialized wire shapes, and transient principals.** §3.7.2 makes "the same static-feed key" a CHECKED equality — the authenticated artifact sidecar `key_id` MUST equal both `release.json.feeds["autotune-artifacts.json"].signer_key_id` and the authenticated candidate-feed signer of that release, so a valid signature by a different but concurrently trusted rotation-bridge key is `catalog_artifact_feed_integrity_failure` at generation and at consumption (AC-CAT-1) — and names `artifact_feed_signer_key_id` alongside `artifact_feed_sha256`. §3.7.7 and the SPEC-047-R003 amendment require an artifact-derived binding to carry all six of `artifact_feed_sha256`, `artifact_id`, artifact `hash`, `hash_algorithm`, `artifact_feed_signer_key_id`, and the candidate-catalog body digest into the IMMUTABLE SPEC-022 route-time record, with settlement failing closed on missing, changed, cross-release, or wrong-signer evidence (AC-CAT-20); that extension is a SPEC-047-owned optional record and **SPEC-022's minimum snapshot field list is unchanged — SPEC-022 is not amended by this revision.** §3.7.8 defines release-ledger **schema version 3** (`macprovider.autotune-release-ledger.v3`): the artifact-bound release row is the exact closed set `{generated_at, policy_version, feeds, artifact_bindings, intake_decision_sha256}`, `artifact_bindings` is a canonically ordered, uniqueness-checked, complete array of closed `{model_key, artifact_id, hash_algorithm, hash}` objects, v1/v2 rows stay untouched and permanently valid, and the first artifact-bound release activates v3 for every later release (AC-CAT-19). §16.2(a) item 6 closes `other_suppressed` to exactly `{request_count, request_count_saturated, distinct_key_count, distinct_key_count_saturated}` with per-counter saturation flags, and item 10 and step S4 make the raw principal identifier **transient**: readable only while deriving `principal_token`, discarded before any intake-state mutation, and absent from every bucket, counter table, log, trace, diagnostic dump, and aggregator state (AC-CAT-13). §16.4 adds the SPEC-023-owned `INTAKE_K_ANONYMITY_MIN` (default 3) applying to BOTH `distinct_provider_offer_count` and the SPEC-017 unknown-key signal, requires `INTAKE_OFFER_FLOOR >= INTAKE_K_ANONYMITY_MIN`, forbids a suppressed provider count from satisfying the offer floor, and states that provider-offer intake is coordinator-owned SPEC-047 admission data available now rather than gated on the SPEC-017 amendment. New §16.8 defines the release-bound closed `intake-decision.json` manifest — evaluated signal values with authenticated source digests, observation window and as-of timestamps, suppression state, every §16.4 threshold, selected admission and fit clause, cold-start slot use, and the operator decision and role — digest-bound in the ledger row, so §16's reconstructibility claim holds from the release record alone (AC-CAT-21). §3.3.1 rule 3 names the never-published generator source artifact `rate-card-source.json` (`macprovider.rate-card-source.v1`) and closes its top-level key set (AC-CAT-9).
  11. **Independent review closures (2026-09-09, `/code-review ultra` on PR #1452).** §16.8 `intake-decision.json` gains a per-signal `*_absent_reason` field for every signal and a `promotion` object so that `promote_recommendable` entries and null signals are representable inside the closed schema (rules 2, 6, 6a; AC-CAT-21 extended); three editorial corrections (changelog AC range, §3.3.1 rule 3 wording, CONFORMANCE gap rationale).
- **v0.9.5 (2026-08-30)** — Guarded interactive-context calibration (#1201).
  1. Adds an explicit `--calibrate-context` post-selection probe that measures uncached prefill TTFT for the selected signed model artifact before config emission/application.
  2. Keeps the RAM/model-derived context cap as a hard upper bound while selecting the largest 1,000-token cell whose three-sample final p95 TTFT is at most 8,000 ms, measured with a one-token completion and an explicit 256-token prompt/format overhead reserve.
  3. The feature is operator opt-in in this revision. Installer activation remains blocked on signed physical journey evidence and owner approval; the pre-existing default path is unchanged.

- **v0.9.4 (2026-08-29)** — Thermal veto redefined as sustained throttle (#1269).
  1. **`thermal_throttle_detected` now means sustained thermal throttle, not any single throttling sample.** Computed over the SAME ~250 ms interval series already sampled for `swap_detected` (§ v0.9.0.2): `thermal_throttle_detected == true` only when at least 2 readable thermal samples are throttling (`.serious`/`.critical`) AND throttling readings are ≥50% of the readable (non-Unknown) thermal samples. A genuinely thermally-throttled node (sustained majority) still fails paid eligibility, including short probes that collect only the two synchronous samples.
  2. **Why.** The install-time recommendation probe runs while the Mac is hot from unpacking/verifying/signing, so a lone transient throttle amid a benign thermal fair/nominal oscillation flipped the old any-sample flag and hard-rejected otherwise-capable Macs at upgrade — the node was then rolled back to its prior release (the #1269 convergence blocker). The prior rule set the flag if ANY single sample throttled OR any sample's thermal state was unreadable.
  3. **Fail-closed narrowed.** `thermal_throttle_detected` fails closed to true only when the thermal state could not be read for the ENTIRE series (every sample unreadable, or an empty series). A single transient unreadable or throttling sample MUST NOT veto the paid path. This mirrors the v0.9.0 `swap_detected` fail-closed narrowing.
  4. **No wire/schema change.** The `thermal_throttle_detected` boolean field name, the candidate-benchmark shape, and the coordinator-facing evidence schema are unchanged; only the field's meaning tightens. The gate remains a hard block for paid recommendation.

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
     unchanged: the client then fetched from `coordinator.malibu.tech/static/*`,
     verifies against the baked v3 pubkey, and falls back to the
     compiled-in baked catalog on verification failure. Older v1.7.9-
     clients that still bake the v2 pubkey `sidecarIsValid`-fail on
     v3 sigs, fall back to their baked catalog, and stay online
     thanks to the v0.2 soft-signal gates above. See
     `phase3-binary/dist/static/keys/README.md` for the full trust
     model and the v3 → v4 rotation procedure.
  3. **Live catalog `min_sustained_tps` cuts.** With gates now
     advisory, the v3-signed live catalog at
     `coordinator.malibu.tech/static/autotune-candidates.json` was
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

`autotune --recommend` scores rate-card-eligible models against the operator's detected Mac hardware, local benchmark results, the current rate card, and an operator-curated demand/supply signal, then recommends the eligible model with the strongest expected operator earning opportunity while preferentially filling buyer-facing supply deficits. It serves every new provider installer and every operator who runs `malibu-cli autotune --recommend` after install. Wave 0c lands now because beta launch readiness depends on a low-friction install path, a trustworthy catalog, and a first-model choice that improves both operator economics and buyer coverage.

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
|| `candidate_benchmarks[model_key].thermal_throttle_detected` | boolean | local probe | **[amended v0.9.4 / #1269]** True means SUSTAINED thermal throttle across the probe (≥2 readable thermal samples `.serious`/`.critical` AND ≥50% of the readable samples throttling); a hard block for paid recommendation. A lone transient throttle amid a benign fair/nominal oscillation does NOT set it. Fail closed to true only when the whole thermal series is unreadable. Field name/type unchanged. |

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
https://coordinator.malibu.tech/v1/autotune-candidates
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
- `model_sha256` is a lowercase hex SHA-256 digest of the canonical artifact-set manifest for the release-pinned model snapshot. After downloading by `model_revision`, the CLI MUST reject the snapshot if any filesystem entry is not a regular file or directory; symlinks, hardlinks with link count greater than one, device nodes, sockets, FIFOs, absolute paths, path escapes, relative paths containing `..`, and relative paths containing C0 control characters (`U+0000` through `U+001F`) or DEL (`U+007F`) are forbidden. The CLI then enumerates every regular file, computes each file SHA-256, sorts entries by normalized POSIX relative path, serializes each entry as `path LF size_decimal LF sha256_hex LF`, concatenates those UTF-8 entries, and SHA-256s the concatenated bytes. A mismatch fails closed before benchmark, recommendation, local donor-mode commit, or provider run.
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

**Ladder semantics (amended v0.10.0).** The four `runtime_status` values are a graduation ladder, not four unrelated labels. This revision makes `listed` the cheap intake tier so a model key can be admitted to the catalog for identity and discovery long before the operator is ready to make it a paid default:

|| `runtime_status` | Minimum requirements | What it grants | What it never grants |
||---|---|---|---|
|| `candidate` | Row identity only (`model_id` plus, for downloadable rows, `model_revision` and `model_sha256`). If the row has a §3.7 artifact-feed entry, its `primary_artifact_id` MUST name a schema-valid `mlx_safetensors` artifact whose `source_ref`, `hash_algorithm`, and `hash` correspond to the row's `model_id`/`model_revision`/`model_sha256`; that artifact and every other entry MAY all still be `declared`. | Operator staging of a row before its artifacts are verified; local diagnostics; local-only unpaid donor-mode selection under §7.2 and §8, authorized by the row's own signed `model_revision`/`model_sha256`. | Not BYOM catalog-matchable, not probe-eligible, never a paid default, never SPEC-047 `catalog_matched`, never `catalog_priced`, never `settlement_capable`. |
|| `listed` | Row identity, **plus at least one artifact with `verification_status == "verified"` in the §3.7 artifact feed**, plus the §16 intake rule. No `rate_class` and no rate row are required. | Buyer-visible discovery of the model key; SPEC-047 `catalog_matched` identity for a BYOM candidate whose artifact hash matches a verified artifact of this row; SPEC-047 `sandbox_probe_only` and `network_visible_unpriced` admission; donor-mode selection subject to §5 and AC-22. | Never a paid default, never `catalog_priced`, never `settlement_capable`, never priced buyer routing. A `listed` row carries no earning claim. |
|| `recommendable` | Everything `listed` requires, **plus a `rate_class` (§3.3.1) that resolves to a published rate-card row**, plus demand-rank `recommendable: true`, plus the existing operator admission and §5 gates. | Paid-default eligibility for `autotune --recommend`; SPEC-047 `catalog_priced` and, when SPEC-022 route-time and receipt preconditions hold, `settlement_capable`. | Nothing in this ladder relaxes §5, SPEC-022, SPEC-032, or SPEC-044 gates. |
|| `blocked` | Operator withdrawal for safety, licensing, runtime, or economics reasons. | Diagnostic display only. | Never downloaded, benchmarked, donor-committed, or recommended. |

**What `candidate` means, and what it does not (amended v0.10.0).** `candidate` is **operator staging**. It is the tier at which a row exists and can be worked on before the operator has confirmed its artifacts against real bytes, so a `candidate` row's §3.7 artifact-feed entries MAY all carry `verification_status: "declared"`. Three scoping rules follow and are normative:

1. The §3.7.4 verified-primary field rule and the §3.7.5 verified-primary consistency check both apply to candidate-catalog rows whose `runtime_status` is `listed` or `recommendable`. A `candidate` row is out of scope for the `verified` requirement in both. Its `primary_artifact_id` MUST still name a schema-valid `mlx_safetensors` artifact whose `source_ref`, `hash_algorithm`, and `hash` correspond to the row's `model_id`, `model_revision`, and `model_sha256`; that artifact MAY carry `verification_status: "declared"`.
2. The §16.1 P1 verified-artifact precondition is a precondition for **entering `listed`** (and therefore, transitively, `recommendable`). It is not a precondition for authoring a `candidate` row.
3. A `candidate` row is **never** BYOM-matchable, never probe-eligible, and never reaches SPEC-047 `catalog_matched`, `catalog_priced`, or `settlement_capable`. No provider-supplied artifact hash matches a `candidate` row, whatever the artifact feed says about it.

This does not change the §3.2 rule above that every downloadable row — `candidate`, `listed`, or `recommendable` — MUST include both `model_revision` and `model_sha256`. That rule governs **local download authorization by the row's own signed identity**, which is what §7.2 and §8 donor mode exercise on a `candidate` row and which is unchanged by this revision. The artifact feed's `declared` / `verified` distinction governs a different thing: whether an artifact-feed entry may act as a **network-visible catalog identity** for matching, pricing, or settlement. A `candidate` row is downloadable locally by its signed row hash and is simultaneously matchable by nobody over the network; those two statements are consistent because they are about different boundaries.

Graduation is monotonic in privilege but not in direction: a row may be demoted from `recommendable` to `listed`, or moved to `blocked` out of band, at any time (§16). Promotion from `listed` to `recommendable` for an `omlx_seeded` row remains governed by §5 and §12 and remains PROHIBITED in Stage 1; the v0.10.0 intake rule does not activate the §12 Stage-2 automation and does not create a second promotion authority.

**The candidate catalog gains no new fields in this revision.** `rate_class`, artifact sets, and intake metadata are deliberately NOT added to the candidate-catalog rows. The deployed CLI Swift strict decoder (`AutotuneStrictJSON.validateCandidate`) and the coordinator/generator validators enumerate the exact allowed row keys and fail closed on anything else, so a new candidate-row field would reproduce the #813 forward-incompatibility trap documented in §12.2 and fail-close the fleet. Those fields live in the separate signed artifact feed defined in §3.7, which every v0.1 consumer simply never fetches.

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

The recommendation engine fetches the current rate card from `https://coordinator.malibu.tech/v1/rate-card` and its detached sidecar from `https://coordinator.malibu.tech/v1/rate-card.sig`. Live rate-card bytes MUST be verified before paid recommendation uses them. Transport/HTTP unavailability may use the baked rate-card snapshot compiled into the installer/CLI release and emit `rate_card_fallback_used`; missing/malformed sidecar, unknown signer, invalid signature, invalid schema, policy mismatch, valid older-than-baked bytes, future bytes, or expired bytes MUST additionally emit `rate_card_integrity_failure` or `rate_card_update_required` as applicable and block paid recommendation.

`GET /v1/rate-card` is a read-only coordinator endpoint. It MUST NOT alter billing, settlement, routing, provider state, request logs, `RateCardEntry`, settlement arithmetic, or coordinator-held signing material. It is public-read because it exposes only prices already used for buyer/provider economics; no provider or buyer credential is required. Production serves literal signed `rate-card.json` bytes loaded from disk after Ed25519 verification at startup. Unconfigured local/development coordinators may compute the same recommendation-only projection from `Rewards.RateCard`, `Rewards.ProviderShare`, `Rewards.GlobalMultiplier`, and `stats.rollup.usd_per_million_credits`; clients still require the sidecar before trusting live bytes.

Repository routing contract:

- The handler lives on the coordinator buyer HTTP mux (`buyer_port: 8443`), not the provider/operator mux (`provider_port: 8444`).
- Production nginx MUST include exact `location = /v1/rate-card` and `location = /v1/rate-card.sig` allow-through blocks before the generic `location /v1/ { return 404; }` block in `phase4-coordinator/dist/nginx-coordinator.malibu.tech.conf`.
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

#### 3.3.1 Class rate rows (v0.10.0)

Pricing is expressed by **model class**, market-pegged per the `RESEARCH_224` executive recommendation (anchor USD to buyer market price rather than to provider USD, with market-pegged completion credits per class). The mechanism is an authoring-time expansion. It changes no published feed schema and no billing code.

**SPEC-023-R005:** A catalog release MUST support class-declared pricing under all of the following rules.

1. **Closed class enum.** `rate_class` is one of `class-3b`, `class-8b`, `class-20b-moe`, `class-30b-moe`, `class-32b`, `class-70b`, `class-120b-moe`. The enum keys on parameter scale and dense-vs-small-active-MoE shape, because those two properties are what both the buyer market price and the §5 hardware gates actually track. Extending the enum is a SPEC-023 revision, not an operator edit. A `recommendable` row MUST declare a `rate_class`; a `candidate` or `listed` row MAY omit it.
2. **Where `rate_class` lives.** The model key's `rate_class` is carried on its §3.7 artifact-feed model entry. It MUST NOT be added to the candidate-catalog rows for the forward-compatibility reason stated in §3.2 and §12.2. If a future activation gate, mirroring §12.2, establishes that every deployed candidate-catalog consumer accepts unknown row keys, `rate_class` MAY additionally be mirrored into the candidate row; until then the artifact feed is its sole carrier.
3. **The rate-card SOURCE gains a `classes` block carrying credit rates ONLY.** The rate-card authoring source document (the catalog release generator's input) is a **named, versioned, never-published artifact**: `rate-card-source.json`, carrying `"schema_version": "macprovider.rate-card-source.v1"`. It is committed with the release inputs, is read only by the release generator, and is **never served at `/v1/rate-card`, never baked into a CLI release payload, never bound in `release.json`, and never recorded in the release-ledger feed set** — it is authoring input, not a published feed, and the published `rate-card.json` is materialised FROM it and is never equal to it. Its top level is the exact closed set `{schema_version, generated_at, policy_version, usd_per_million_credits, provider_share_bps, global_multiplier_ppm, rows, classes}`, where `usd_per_million_credits`, `provider_share_bps`, and `global_multiplier_ppm` are the **release-global** values rule 4 materialises onto every published row, `rows` is an object mapping a normalized model key to an explicit row carrying exactly the three credit-rate fields, and `classes` is the object defined in the rest of this rule. Both `rows` and `classes` MAY be empty objects but MUST be present. An unknown top-level key, a missing top-level key, a wrong-typed value, or a `rows`/`classes` entry carrying any field beyond the three credit-rate fields MUST fail the release closed before signing, exactly as an invalid published feed does (AC-CAT-9). Naming and closing the source schema is what makes class expansion reproducible from named release inputs and its test fixtures portable; it changes no published bytes. The `classes` object maps each `rate_class` to **exactly the three credit-rate fields** a §3.3 row prices with: `prompt_rate_per_mtok`, `prompt_cache_hit_rate_per_mtok`, and `completion_rate_per_mtok`. A class entry MUST NOT carry `provider_share_bps` or `global_multiplier_ppm`, and a release whose rate-card source declares either on a class MUST fail closed at generation.

   `provider_share_bps` and `global_multiplier_ppm` are **release-global values, not per-class and not per-model**. The coordinator holds them exactly once, as `rewards.provider_share` and `rewards.global_multiplier` (`phase4-coordinator/internal/config/config.go`, `RewardsConfig`), while every `rewards.rate_card` row in `phase4-coordinator/dist/coordinator.yaml` carries only the three credit fields (`RateCardEntry`). A per-class share or multiplier is therefore not representable in the billing fallback the expansion writes into, and permitting one would let signed recommendation economics diverge from actual coordinator billing while rule 6 keeps billing code untouched. The generator applies the release-global values to every expanded row at expansion time, and those values MUST equal the coordinator globals of the release being published (rule 9).

   The published, signed `rate-card.json` served at `/v1/rate-card` MUST remain exactly the §3.3 schema — `version`, `policy_version`, `generated_at`, `usd_per_million_credits`, and a flat `rows` map — with no `classes` key and no per-row class field. Each published row still carries `provider_share_bps` and `global_multiplier_ppm` as §3.3 requires; they are materialised from the release-global values and are identical across every row of a release.
4. **Expansion is the generator's job, and its field mapping is exact.** For every model key whose artifact-feed entry declares a `rate_class`, the catalog release generator MUST emit a concrete per-model row into the published `rate-card.json` `rows` map and into the coordinator inline fallback rows (`phase4-coordinator/dist/coordinator.yaml`, `rewards.rate_card:`), materialised from that class's values. The JSON-to-YAML mapping is exactly:

   | rate-card source / published `rows` field (JSON) | coordinator field (YAML) | Go binding | Scope |
   |---|---|---|---|
   | `prompt_rate_per_mtok` | `rewards.rate_card.<key>.prompt_credits_per_mtok` | `RateCardEntry.PromptCreditsPerMtok` | per row |
   | `prompt_cache_hit_rate_per_mtok` | `rewards.rate_card.<key>.prompt_cache_hit_credits_per_mtok` | `RateCardEntry.PromptCacheHitCreditsPerMtok` | per row |
   | `completion_rate_per_mtok` | `rewards.rate_card.<key>.completion_credits_per_mtok` | `RateCardEntry.CompletionCreditsPerMtok` | per row |
   | `provider_share_bps` | `rewards.provider_share` | `RewardsConfig.ProviderShare` | release-global; `bps / 10000` |
   | `global_multiplier_ppm` | `rewards.global_multiplier` | `RewardsConfig.GlobalMultiplier` | release-global; `ppm / 1000000` |

   The three credit values are integers on both sides and are copied without rounding, unit conversion, or defaulting; a generator that would have to round to emit a row MUST fail the release closed instead. The last two rows of the table are release-global on both sides and MUST NOT be written into any coordinator `rewards.rate_card` row. The model key used on both sides is the same normalized key (§3.3, SPEC-005 §5.5 `NormalizeModelKey`). Expansion MUST be deterministic and MUST be reproducible from the release inputs alone.
5. **Precedence: explicit model row beats class expansion.** When the rate-card source declares an explicit row for a model key, that row's three credit values are published verbatim — with the release-global `provider_share_bps` and `global_multiplier_ppm` materialised onto the published row as rule 4 requires — and the class expansion for that key MUST be discarded. Class expansion fills only keys that have no explicit row. The generator MUST fail closed on a key whose explicit row and class expansion disagree only through an ambiguous or partial override; an override is all-or-nothing per model key.
6. **Billing is untouched.** Because the published rate card still contains one concrete row per model key, SPEC-005 §5.5 rate resolution — exact key, then `NormalizeModelKey`, then the `default` row — resolves exactly as it does today. **This revision does not amend SPEC-005 and no billing, settlement, ledger, or receipt behavior changes.** `rate_class` is never sent on the wire, never stored on a ledger row, and never read by `RateFor`.
7. **Invariant: a `recommendable` row MUST resolve to a rate row.** For every candidate-catalog row with `runtime_status == "recommendable"`, the published rate card MUST contain a row reachable by exact key or by `NormalizeModelKey` for that model key. Reaching only the `default` row does not satisfy this invariant at authoring time, even though §3.3 and AC-15 keep the `default` fallback available at runtime for fresh-install recovery. A release that violates this invariant MUST fail closed at generation.
8. **No silent repricing.** The first catalog release that introduces class expansion MUST publish a `rate-card.json` whose `rows` map is byte-identical to the immediately preceding release's `rows` map. Class expansion is a refactor of how rows are authored, never a repricing event; any intended price change is a separate, explicitly reviewed release.
9. **Generated-feed / billing-config parity is a release gate.** Before signing, a class-expanded release MUST verify that the published `rate-card.json` `rows` map and the coordinator inline fallback `rewards.rate_card` rows it publishes agree row-for-row under the rule-4 mapping — the same normalized key set, and the same three credit values per key — and that the release's `provider_share_bps` and `global_multiplier_ppm` equal the published coordinator configuration's `rewards.provider_share` and `rewards.global_multiplier` after the rule-4 unit conversion. Any disagreement, in either direction, MUST fail the release closed. This parity check is what keeps signed recommendation economics and actual coordinator billing from drifting apart while rule 6 keeps SPEC-005 and the billing code untouched.

The intended v0.10.0 class assignment for the current signed catalog is recorded here as an illustrative operator mapping, not as normative catalog content: `class-3b` — `meta-llama/llama-3.2-3b-instruct`; `class-8b` — `meta-llama/llama-3.1-8b-instruct`, `qwen3-8b`; `class-20b-moe` — `openai/gpt-oss-20b`; `class-30b-moe` — `google-gemma-4-26b-a4b-it`, `qwen3-coder-30b-a3b-instruct`, `nvidia/nemotron-3-nano-30b-a3b`; `class-32b` — `qwen3-32b`, `qwen2.5-coder-32b-instruct`; `class-120b-moe` — `openai/gpt-oss-120b`; `class-70b` is reserved and currently unpopulated, held for the `RESEARCH_224` 70B peg. Several current rows price differently from their class peers (notably `qwen2.5-coder-32b-instruct` against `qwen3-32b`, and the three `class-30b-moe` rows against each other). Rule 8 means those rows stay explicit model overrides until the operator deliberately reconciles them in a separate priced release; class expansion MUST NOT be the vehicle that quietly moves a live money-path rate.

### 3.4 Demand signal

The recommendation engine fetches `https://coordinator.malibu.tech/v1/demand-rank` and falls back to a baked snapshot when the signed feed fetch fails, times out, fails Ed25519 detached-signature verification, or fails schema validation. The demand signal is operator-curated OpenRouter-prior metadata, not a coordinator demand endpoint.

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

1. Fetch `rate-card` and detached `rate-card.sig` from `https://coordinator.malibu.tech/v1/rate-card` and `https://coordinator.malibu.tech/v1/rate-card.sig`; fetch `autotune-candidates` and detached `autotune-candidates.sig` from `https://coordinator.malibu.tech/v1/autotune-candidates` and `https://coordinator.malibu.tech/v1/autotune-candidates.sig`; fetch `demand-rank` and detached `demand-rank.sig` from `https://coordinator.malibu.tech/v1/demand-rank` and `https://coordinator.malibu.tech/v1/demand-rank.sig`.
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
13. **[v0.10.0]** `autotune-artifacts.json` (§3.7) is fetched from `https://coordinator.malibu.tech/v1/catalog-artifacts` with its detached sidecar at `.../v1/catalog-artifacts.sig` and is verified through steps 2-5 above verbatim, using the same static-feed keyring. It shares the candidate release's `version`, `generated_at`, and `policy_version`, so rule 11 applies to it as well. Its failure classes are defined in §3.7.6 and differ from the feeds above in exactly one respect: an artifact-feed failure fails closed for artifact-derived capabilities only and MUST NOT block paid recommendation or coordinator join.

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

### 3.7 Catalog artifact feed (v0.10.0)

A catalog model key is one priced identity that MAY be served from more than one verified binary artifact. The `mlx-community/*-4bit` safetensors snapshot is one artifact; a GGUF blob served by a local Ollama or llama.cpp runtime under SPEC-046 is a different artifact of the same model. They have different bytes and different hashes, so a single `model_sha256` per row can never match both, and SPEC-047-R003's catalog binding is unreachable for every non-MLX BYOM candidate. §3.7 fixes that by giving each model key a SET of verified artifacts.

**Pricing is model-key scoped; settlement identity is artifact-scoped and, in v0.10.0, primary-only.** Two artifacts of one model key are priced identically, because price attaches to the model key (§3.3, §3.3.1). Settlement does not follow pricing. A settlement binding names one specific artifact `hash` together with its `hash_algorithm`, and in v0.10.0 the ONLY artifact that may be named is the model key's **primary** artifact: the `mlx_safetensors` entry named by `primary_artifact_id`, `verified`, hashed under `macprovider.snapshot-manifest.v1`, whose `hash` is byte-identical to the candidate row's `model_sha256` (§3.7.5). Only that artifact may reach SPEC-047 `catalog_priced` or `settlement_capable`, be reported as the SPEC-010 provider `model_hash`/`model_hash_algorithm` wire pair, or bind a SPEC-022 route-time settlement snapshot.

**Every non-primary artifact — a `gguf` artifact and a secondary `mlx_safetensors` quantization alike — is a matchable identity and nothing more.** When it is `verified` it may satisfy SPEC-047 `catalog_matched` and support `sandbox_probe_only` and `network_visible_unpriced`, and it stays **unpriced and non-settling** there. That is not a §3.7 policy choice: SPEC-010-R001/R004 recognize exactly one identity per catalog model key — the `model_sha256` of the exact signed candidate-catalog row — so widening settlement to a non-primary artifact-feed entry is a SPEC-010 amendment (§13 Q14), not a SPEC-023 or SPEC-047 one. Read every later "settlement binds the artifact hash" sentence in this SPEC under that restriction: those sentences say which fields a binding MUST record, never that a non-primary artifact may be bound.

**One `(hash_algorithm, hash)` pair belongs to exactly one model key.** Pricing is resolved by model key while a SPEC-047 catalog match is resolved by verified hash, so identical bytes appearing under two model keys would leave one matched candidate with two possible prices. §3.7.4 therefore makes global artifact-hash uniqueness a normative feed invariant, enforced at generation and at consumption.

#### 3.7.1 Why a separate feed, and not a candidate-catalog field

§12.2 records the #813 forward-incompatibility trap. The deployed CLI Swift strict decoder enumerates the exact allowed candidate-row keys (`model_id`, `model_revision`, `model_sha256`, `min_ram_gb`, `min_bandwidth_tier`, `bench_gate`, `runtime_status`, `notes`, `draft_candidates`, `workload_profiles`) and throws on any other key; the release generator and the coordinator feed validators enforce the same closed set. Publishing an artifact set as a new candidate-row field would therefore fail-close every deployed provider — integrity failure on the whole catalog, blocking autoupdate and coordinator join — which is the exact failure the oMLX activation gate exists to prevent.

The artifact set is consequently a **separate signed static feed**. Existing consumers never fetch it and are byte-for-byte unaffected; the candidate catalog keeps `model_id`, `model_revision`, and `model_sha256` unchanged as the row's primary MLX artifact for all v0.1 consumers.

#### 3.7.2 Feed identity, transport, and trust

```text
primary:   https://coordinator.malibu.tech/v1/catalog-artifacts
sidecar:   https://coordinator.malibu.tech/v1/catalog-artifacts.sig
file name: autotune-artifacts.json
fallback:  baked autotune-artifacts snapshot compiled into the installer/CLI release
```

The feed is signed by the same static-feed key as `autotune-candidates.json`, `demand-rank.json`, and `rate-card.json`, and it is verified through the §3.5 procedure verbatim: detached `{key_id, alg, signature}` sidecar, base64 Ed25519 over the exact UTF-8 bytes, `key_id` resolved through the release-embedded trusted verifier keyring, parse only after verification succeeds, and the same future/expired/older-than-baked rules. Nginx MUST expose exact `location = /v1/catalog-artifacts` and `location = /v1/catalog-artifacts.sig` allow-through blocks before the generic `location /v1/ { return 404; }` block, proxying to the coordinator buyer mux (`buyer_port: 8443`) with no `Authorization` requirement, exactly as §3.3 requires for the rate-card routes.

**Signer identity equality (normative).** "The same static-feed key" is a CHECKED equality, not an assumption. During a key-rotation bridge more than one key may be concurrently trusted by the release-embedded keyring, so unknown-`key_id` rejection alone does not establish that the artifact feed and the candidate catalog of one release were signed by the same operator key. At generation AND at consumption the authenticated artifact sidecar's `key_id` MUST equal the authenticated candidate-feed signer `key_id` for that same release; at generation and in every consumer that holds the authenticated `release.json` (`verify`, the acceptance signer, the live coordinator release gate) it MUST also equal `release.json.feeds["autotune-artifacts.json"].signer_key_id`. A fetching CLI holds no authenticated manifest for a newer live release: it enforces the two authenticated signers it holds, and for its compiled-in snapshot additionally the manifest-bound signer baked beside it (v0.10.2). Any mismatch — including a cryptographically valid signature made by a different but concurrently trusted key — is `catalog_artifact_feed_integrity_failure` (§3.7.6 class 2), never `catalog_artifact_feed_update_required`, the release fails closed before signing, and no artifact of that feed may be matched, displayed as catalog-verified, downloaded, prepared, probed, priced, or settled (AC-CAT-1).

`artifact_feed_sha256` is the lowercase hex SHA-256 over the exact selected feed JSON bytes, taken after fetched/baked selection and before parsing normalization. It is the "exact catalog body digest" that SPEC-047-R003 requires when an admission binds to an artifact from this feed. `artifact_feed_signer_key_id` is the `key_id` of the sidecar that authenticated those exact bytes, recorded only after the equality check above succeeds. Those two values, together with the artifact's `artifact_id`, `hash`, and `hash_algorithm` and the candidate-catalog body digest of the same release, are the six values SPEC-047-R003 requires an artifact-derived binding to carry into the immutable SPEC-022 route-time record (§3.7.7, AC-CAT-20).

#### 3.7.3 Schema

```json
{
  "version": "published-2026-09-02-gpt-oss-120b-v1",
  "generated_at": "RFC3339 timestamp",
  "policy_version": "autotune-policy-v1",
  "source": "operator_curated_autotune_artifact_catalog",
  "release_id": "published-2026-09-02-gpt-oss-120b-v1",
  "candidate_catalog_sha256": "<64-hex digest of the candidate-catalog bytes of this release>",
  "models": {
    "<model_key>": {
      "rate_class": "class-8b",
      "primary_artifact_id": "mlx-4bit",
      "artifacts": {
        "<artifact_id>": {
          "runtime_format": "mlx_safetensors",
          "quantization": "4bit",
          "source_ref": {
            "kind": "huggingface_revision",
            "repo_id": "mlx-community/Qwen3-8B-4bit",
            "revision": "545dc4251c05440727734bcd94334791f6ab0192"
          },
          "hash_algorithm": "macprovider.snapshot-manifest.v1",
          "hash": "1f591f9c4fb38d05ea2d879d89a6eeab485c23a04eb75e3e0a289db9d95ec877",
          "size_bytes": 4900000000,
          "min_ram_gb": 12,
          "allowed_runtime_sources": ["mlx_cache"],
          "verification_status": "verified",
          "verified_at": "2026-09-08",
          "notes": "string"
        },
        "gguf-q4-k-m": {
          "runtime_format": "gguf",
          "quantization": "Q4_K_M",
          "source_ref": {
            "kind": "ollama_library_tag",
            "library_tag": "qwen3:8b",
            "digest": "sha256:<64-hex GGUF layer digest>"
          },
          "hash_algorithm": "macprovider.gguf-file.v1",
          "hash": "<64-hex sha256 of the GGUF file bytes>",
          "size_bytes": 4900000000,
          "min_ram_gb": 12,
          "allowed_runtime_sources": ["ollama_loopback", "llamacpp_loopback"],
          "verification_status": "declared",
          "verified_at": null,
          "notes": "string"
        }
      }
    }
  }
}
```

All values above are illustrative, not normative catalog content.

**The feed schema is CLOSED at every level.** Each object below has an exact field set. A consumer MUST reject the feed — emitting `catalog_artifact_feed_integrity_failure` (§3.7.6 class 2) — when any object carries a field not listed for it, omits a REQUIRED field, or carries a field whose JSON type is not the one named. There is no forward-compatible "ignore unknown keys" mode for this feed: it is release-bound (§3.7.4), so a field the consumer does not recognise means the consumer and the feed disagree about the release, which is exactly the condition that MUST fail closed. Adding a field is a SPEC revision plus a generator and consumer release, never a silent feed change.

- **Top-level object.** REQUIRED: `version` (string), `generated_at` (string, RFC3339), `policy_version` (string), `source` (string), `release_id` (string), `candidate_catalog_sha256` (string, 64-hex lowercase), `models` (object). No other top-level field is permitted.
- **`models.<model_key>` object.** REQUIRED: `primary_artifact_id` (string), `artifacts` (object, non-empty). OPTIONAL: `rate_class` (string, a §3.3.1 enum value). No other field is permitted. `models` itself MUST be an object whose keys are normalized model keys and whose values are these objects.
- **`artifacts.<artifact_id>` object.** REQUIRED: `runtime_format` (string enum), `quantization` (string), `source_ref` (object), `hash_algorithm` (string enum), `hash` (string, 64-hex lowercase), `size_bytes` (integer > 0), `min_ram_gb` (number > 0), `allowed_runtime_sources` (array of strings, non-empty), `verification_status` (string enum), `verified_at` (string, RFC3339 `full-date` — exactly `YYYY-MM-DD`, ten characters, no time-of-day and no zone offset — or `null` exactly when `verification_status != "verified"`). OPTIONAL: `notes` (string). No other field is permitted.
- **`source_ref` object, `kind: "huggingface_revision"`.** REQUIRED: `kind` (string), `repo_id` (string), `revision` (string, 40-hex lowercase). No other field is permitted.
- **`source_ref` object, `kind: "ollama_library_tag"`.** REQUIRED: `kind` (string), `library_tag` (string), `digest` (string, `sha256:` followed by 64-hex lowercase). No other field is permitted.
- `source_ref.kind` is itself a closed enum. A `source_ref` whose `kind` is neither of the two variants above, or which carries one variant's fields under the other variant's `kind`, is a schema failure — not an unknown-but-tolerable reference type.

The release generator MUST apply these same closed field sets before signing, so an out-of-schema feed can never be published, and MUST fail the release closed rather than silently dropping an offending field.

#### 3.7.4 Field rules

- `source` MUST equal `operator_curated_autotune_artifact_catalog`. `policy_version` MUST equal the candidate catalog's `policy_version`.
- `version` and `release_id` MUST both equal the candidate catalog's `version` for the same release, and `generated_at` MUST equal the candidate catalog's `generated_at`. `candidate_catalog_sha256` MUST equal the full `candidate_catalog_sha256` (§3.6, §9) of the candidate-catalog bytes of that release. A feed that disagrees with the selected candidate catalog on any of these is a mixed release and MUST fail closed for every artifact-derived use (§3.7.6).
- `models.<model_key>` keys MUST use the same normalized model-key form as the candidate catalog and the rate card. A model key present in the artifact feed but absent from the candidate catalog is a feed-integrity failure.
- `rate_class`, when present, MUST be one of the §3.3.1 enum values. It MUST be present for every model key whose candidate row is `recommendable`.
- `primary_artifact_id` MUST name an entry in that model's `artifacts` map whose `runtime_format` is `mlx_safetensors`, and that entry's `source_ref.repo_id`, `source_ref.revision`, `hash_algorithm`, and `hash` MUST correspond to the candidate row's `model_id`, `model_revision`, `macprovider.snapshot-manifest.v1`, and `model_sha256` respectively. **The `verified` requirement on that entry is scoped by the row's `runtime_status`.** For a candidate-catalog row entering or held at `listed` or `recommendable`, the primary artifact's `verification_status` MUST be `verified` (§3.7.5, §16.1 P1). For a `candidate` row it MAY remain `declared` — that is exactly what operator staging means (§3.2) — but the entry MUST still be schema-valid and identity-corresponding as stated above: staging permits an unconfirmed hash, never an unnamed, absent, or mismatched primary artifact.
- **`artifact_id` grammar, stability, and historical authority (normative).** `artifact_id` is a stable, operator-assigned identifier scoped to one model key. Its grammar is closed: it MUST match `^[a-z0-9][a-z0-9-]{0,63}$` in full — lowercase ASCII letters, digits, and hyphens, first character alphanumeric, 1 to 64 characters. Any other value is `catalog_artifact_feed_integrity_failure` at generation and at consumption.

  An `artifact_id` MUST NOT be rebound to different bytes, and that prohibition is enforced from **named release inputs** rather than from operator memory. The catalog release generator MUST take **the previous release's signed artifact feed** as an input alongside the release ledger, and MUST fail the release closed when any `(model_key, artifact_id)` present in both feeds carries a `(hash_algorithm, hash)` that differs from its prior binding. Changing an artifact's bytes therefore requires a NEW `artifact_id`; the old id is retired by publishing it with `verification_status: "blocked"`, and a retired id MUST NOT be reintroduced later with different bytes. Removal is not an escape hatch: a `(model_key, artifact_id)` that appears in one release, is absent from a later feed, and then reappears bound to a `(hash_algorithm, hash)` other than its last recorded binding is a rebinding and fails the release closed exactly as an in-place change does.

  The authority for that comparison is durable and reproducible. The release ledger's artifact-bound feed-set row (§3.7.8) MUST record, for the release it describes, every `(model_key, artifact_id, hash_algorithm, hash)` binding the artifact feed publishes. The generator's prior-binding lookup is therefore reconstructible from the named release inputs alone — the ledger plus the previous release's signed feed bytes — so an auditor holding those inputs can detect a rebinding without trusting the generator that produced the release.
- `runtime_format` is a closed enum. v0.10.0 values are `mlx_safetensors` and `gguf`.
- `quantization` is an operator-curated label such as `4bit`, `8bit`, `MXFP4-Q8`, or `Q4_K_M`. It is descriptive metadata for display and fit reasoning; it is never an identity or trust input on its own.
- `source_ref` is a closed, content-addressed reference. `kind: "huggingface_revision"` requires `repo_id` and an immutable 40-hex `revision`. `kind: "ollama_library_tag"` requires `library_tag` and an immutable `digest`. Mutable branches, tags without a digest, and any network location the coordinator could dereference are forbidden; `source_ref` is an identity descriptor, exactly as SPEC-047-R002 requires of `served_model_ref`.
- `hash_algorithm` is a closed enum. `macprovider.snapshot-manifest.v1` is the existing SPEC-010-R001 identifier, and its `hash` is the §3.2 canonical artifact-set manifest digest for the snapshot at `source_ref.revision` — for the primary artifact this is byte-identical to the candidate row's `model_sha256`. `macprovider.gguf-file.v1` is RESERVED by this SPEC and its `hash` is the lowercase hex SHA-256 of the GGUF file bytes, which is the value Ollama exposes as the model layer digest. `hash` MUST be lowercase 64-hex.
- **Global artifact-hash uniqueness (normative).** Within one artifact feed, a `(hash_algorithm, hash)` pair MUST appear under **exactly one** model key and, within that model key, under exactly one `artifact_id`. A feed in which the same pair appears twice — under two model keys, or twice under one model key — is `catalog_artifact_feed_integrity_failure` (§3.7.6 class 2): the release generator MUST reject it before signing, and a consumer MUST reject the feed before any artifact from it binds anything. **This is a NEW check.** It is not supplied by the release generator's existing candidate-catalog conflicting-hash check, which rejects two DIFFERENT `model_sha256` values under one normalized `model_id` and says nothing about one hash appearing under two model identities (`scripts/catalog-release.py`); the two checks close opposite directions of the same seam and both MUST run. The invariant is what makes artifact matching resolvable: pricing is resolved by model key (§3.3, §3.3.1) while SPEC-047 `catalog_matched` is resolved by verified `(hash_algorithm, hash)`, so without it identical bytes could resolve to two model keys carrying two different rate rows and the price of a matched candidate would depend on an implementation's tie-break. With it, a verified `(hash_algorithm, hash)` resolves to exactly one `(model_key, artifact_id)`; that resolved `model_key` is the candidate's catalog pricing identity, and a provider-offered `catalog_model_key` is **advisory only** and MUST equal the resolved key or the match fails closed (SPEC-047-R001/R003 as amended in 0.1.3).
- **GGUF source digest binds the artifact hash (normative).** For an artifact whose `runtime_format` is `gguf`, `source_ref.digest` MUST equal `"sha256:" + hash` — the same 64-hex lowercase digest, prefixed. Both fields describe the same bytes (the GGUF file, which is what Ollama exposes as its layer digest), so a feed in which they disagree binds two incompatible identities to one artifact even under a valid signature: the source reference would identify one blob while catalog matching trusted another digest. A mismatch is `catalog_artifact_feed_integrity_failure`, rejected by the release generator before signing and by the consumer **before** the artifact may satisfy SPEC-047 `catalog_matched` or any other artifact-derived capability. The closed identity matrix below validates field types and enum combinations; this rule is the value-level equality the matrix cannot express.
- `size_bytes` is a positive integer count of the artifact's on-disk bytes, used for preparation estimates and SPEC-044 confirmation copy only.
- `min_ram_gb` is per-artifact, not per-model, because resident memory follows the quantization, not the parameter count. It has the same §5 semantics as the candidate row's `min_ram_gb`: it is the resident-fit floor excluding the fixed `safety_margin_gb = 4`. The primary artifact's `min_ram_gb` MUST equal the candidate row's `min_ram_gb`. A non-primary artifact MAY declare a different value.
- `allowed_runtime_sources` is a non-empty array drawn from the SPEC-046-R002 adapter enum (`mlx_cache`, `ollama_loopback`, `lmstudio_loopback`, `llamacpp_loopback`, `openai_compatible_loopback`). It names which SPEC-046 discovery adapters MAY produce a candidate that matches this artifact. An `mlx_safetensors` artifact MUST allow only `mlx_cache`. An artifact MUST NOT allow `openai_compatible_loopback` while carrying `verification_status: "verified"`, because an opaque OpenAI-compatible endpoint supplies no artifact bytes to hash.
- **Closed artifact-identity matrix (normative).** The four identity fields above are NOT independently valid: `runtime_format` determines the only legal `hash_algorithm`, the only legal `source_ref.kind`, and the only legal `allowed_runtime_sources` values. The complete v0.10.0 cross-product is:

  | `runtime_format` | `hash_algorithm` | `source_ref.kind` | `allowed_runtime_sources` ⊆ |
  |---|---|---|---|
  | `mlx_safetensors` | `macprovider.snapshot-manifest.v1` | `huggingface_revision` | `{mlx_cache}` |
  | `gguf` | `macprovider.gguf-file.v1` | `ollama_library_tag` | `{ollama_loopback, llamacpp_loopback, lmstudio_loopback, openai_compatible_loopback}` |

  Every artifact entry MUST match exactly one row of this table on all four fields. **Any other tuple is `catalog_artifact_feed_integrity_failure`**, rejected by the release generator before signing and by the consumer before any artifact from that feed binds anything — including, specifically, a `gguf` artifact declaring `macprovider.snapshot-manifest.v1`, an `mlx_safetensors` artifact declaring `macprovider.gguf-file.v1`, either format carrying the other's `source_ref.kind`, an `mlx_safetensors` artifact allowing any loopback source, and a `gguf` artifact allowing `mlx_cache`. The matrix is closed in both directions: adding a runtime format, a hash algorithm, a source-reference kind, or a format/source pairing is a SPEC-023 revision plus a generator and consumer release, exactly as §3.7.3 requires of the schema itself. The two independent constraints stated elsewhere in this section — that an `mlx_safetensors` artifact MUST allow only `mlx_cache`, and that a `verified` artifact MUST NOT allow `openai_compatible_loopback` (an opaque OpenAI-compatible endpoint supplies no artifact bytes to hash) — are restatements of and additions to this matrix, not exceptions to it: the second means the fourth column's `openai_compatible_loopback` entry is reachable only by a `declared` artifact.

- `verification_status` is a closed enum: `declared`, `verified`, or `blocked`. `declared` means the operator has recorded the artifact's identity but has not confirmed the hash against real bytes. `verified` means the operator has confirmed that the recorded `hash` is the digest of the artifact obtained from `source_ref` under `hash_algorithm`. `blocked` means the artifact is withdrawn for safety, licensing, runtime, or economics reasons. `verified_at` is an RFC3339 `full-date`: exactly `YYYY-MM-DD` (the `2026-09-08` form used in the §3.7.3 example), never a full RFC3339 timestamp. A consumer MUST parse it as a date and MUST reject a value carrying time-of-day or a zone offset. It MUST be non-null exactly when `verification_status == "verified"`.
- **`verified` is necessary for every artifact-derived capability, and never sufficient for settlement.** Settlement additionally requires the artifact to be the model key's primary artifact (next bullet); this bullet states what `declared` and `blocked` exclude. A `declared` artifact MAY appear in operator backlog and review material only — the working list of artifacts an operator has recorded but not yet confirmed. It MUST NOT satisfy the §16.1 P1 intake precondition, MUST NOT contribute to admission at any tier, MUST NOT satisfy SPEC-047 `catalog_matched`, MUST NOT support `catalog_priced` or `settlement_capable`, MUST NOT be priced, and MUST NOT be downloaded or prepared as a catalog artifact. A key whose artifacts are all `declared` MUST NOT enter `listed` or `recommendable` (§16.1 P1, AC-CAT-11); it may exist only as an operator-staged `candidate` row, which reaches no SPEC-047 admission tier at all (§3.2). A `blocked` artifact MUST NOT be matched, displayed as available, downloaded, prepared, probed, or settled.
- **Only the PRIMARY artifact may be a settlement identity in v0.10.0.** SPEC-010 is the sole authority for model identity. SPEC-010-R001 defines `macprovider.snapshot-manifest.v1` as the `model_sha256` **of the exact signed candidate-catalog row**, and SPEC-010-R004 keeps that same row as session authority for later heartbeats and settlement snapshots. A secondary artifact — of ANY runtime format — has different bytes and therefore a different digest, so it is not the SPEC-010 identity for its model key even when it declares a SPEC-010-named algorithm. In v0.10.0, therefore, **only the artifact named by `primary_artifact_id`** (`mlx_safetensors`, `macprovider.snapshot-manifest.v1`, `verified`, `hash` byte-identical to the candidate row's `model_sha256`, §3.7.5) may support SPEC-047 `catalog_priced` or `settlement_capable`, be reported as the SPEC-010 provider `model_hash`/`model_hash_algorithm` wire pair, or bind a SPEC-022 route-time settlement snapshot. **Every non-primary artifact — a `gguf` artifact and a secondary `mlx_safetensors` quantization alike — reaches at most SPEC-047 `catalog_matched`, `sandbox_probe_only`, and `network_visible_unpriced`.** This is not a new restriction invented here; it is what SPEC-010 already requires, and it is why v0.10.0 needs no SPEC-010 amendment. Widening it — recognizing a non-primary artifact-feed entry as a settlement identity — is a SPEC-010 decision (§13 Q14), not a SPEC-023 or SPEC-047 one.

#### 3.7.5 Consistency with the candidate catalog

For every candidate-catalog row whose `runtime_status` is `listed` or `recommendable`, the artifact feed MUST contain a model entry under the same model key, whose `primary_artifact_id` artifact satisfies all of:

- `runtime_format == "mlx_safetensors"`;
- `hash_algorithm == "macprovider.snapshot-manifest.v1"`;
- `hash` exactly equal to the candidate row's `model_sha256`;
- `source_ref.kind == "huggingface_revision"`, `source_ref.repo_id` equal to the candidate row's `model_id`, and `source_ref.revision` equal to the candidate row's `model_revision`;
- `min_ram_gb` equal to the candidate row's `min_ram_gb`;
- `verification_status == "verified"`.

A `candidate` row is out of scope for this check (§3.2): its artifact-feed entries MAY all be `declared`, which is exactly what operator staging means. A `blocked` row is out of scope as before.

This consistency check MUST run at generation (the catalog release generator fails closed before signing) **and** at consumption (a consumer that fetches both feeds fails closed for artifact-derived use before binding anything). A model key whose primary artifact disagrees with its candidate row is an **artifact-feed integrity failure** — `catalog_artifact_feed_integrity_failure` (§3.7.6 class 2), exactly one class, never `catalog_artifact_feed_update_required` — because the two release-bound feeds of one release disagree about an identity, which is a corrupt release rather than a stale one. The operator MUST NOT paper over it by publishing a second hash under the same identity.

#### 3.7.6 Fallback, baked snapshot, and failure classes

The artifact feed follows the §3.5 failure-class separation, with one deliberate asymmetry: **artifact-feed failures never fail-close the v0.1 path.**

1. Transport failure, timeout, or an unavailable HTTP response MAY select the baked artifact-feed snapshot and MUST emit `catalog_artifact_feed_fallback_used`. Like every baked feed, the baked snapshot is part of the release artifact and is trusted only for that binary version.
2. A missing sidecar, malformed sidecar, unknown `key_id`, non-`ed25519` `alg`, invalid signature, invalid schema, or **signer-identity mismatch** — an authenticated sidecar `key_id` that is not equal to both the `release.json` artifact-feed `signer_key_id` and the authenticated candidate-feed signer of that release (§3.7.2), including a valid signature by a different concurrently trusted key — MUST emit `catalog_artifact_feed_integrity_failure`.
3. A cryptographically valid but older-than-baked, future, expired, policy-incompatible, or release-mismatched feed (§3.7.4 binding rules) MUST emit `catalog_artifact_feed_update_required`. A §3.7.5 primary-artifact consistency failure is NOT in this class: it is `catalog_artifact_feed_integrity_failure` under class 2, so exactly one warning class describes it and one code is testable (AC-CAT-5).
4. A `generated_at` between 14 and 30 days old MUST emit `catalog_artifact_feed_stale`. Stale bytes MAY still be selected — they are the freshest bytes available and are more useful than nothing for diagnostics and for recording which feed a fallback decision was made against — but selection is **for diagnostics and fallback provenance only**. Stale bytes MUST NOT authorize any artifact-derived capability (rule 5).
5. `catalog_artifact_feed_integrity_failure`, `catalog_artifact_feed_update_required`, and `catalog_artifact_feed_stale` are **fail-closed for every artifact-derived capability**: no artifact from the feed may be matched, displayed as catalog-verified, downloaded, prepared, probed, priced, or settled while any of the three warnings is present. The consumer falls back to the candidate row's primary artifact identity, which the candidate catalog already carries. Staleness is in this list deliberately: an artifact binding is a settlement-adjacent identity claim, and a 14-to-30-day-old identity claim is exactly the replay window §15 keeps closed, so the artifact feed is stricter about staleness than the §3.5 feeds whose stale bytes stay usable.
6. Those same warnings **MUST NOT block paid recommendation, coordinator join, model download by the candidate row's own `model_revision`/`model_sha256`, or any other behavior the v0.1 feeds already authorize.** An absent artifact feed is indistinguishable from a v0.1 release for every existing code path. This is the whole reason the artifact set is a separate feed: a new capability may fail closed without taking the fleet with it.

The artifact feed is a first-class release-manifest member. Its `release.json` binding, its release-ledger feed set, and the staged activation that keeps it from fail-closing already-installed updaters are defined in §3.7.8.

#### 3.7.7 Requirement

**SPEC-023-R004:** A catalog release MUST publish a signed artifact feed satisfying §3.7.2 through §3.7.8. Every artifact entry MUST match exactly one row of the §3.7.4 closed artifact-identity matrix on `runtime_format`, `hash_algorithm`, `source_ref.kind`, and `allowed_runtime_sources`; any other tuple is `catalog_artifact_feed_integrity_failure` at generation and at consumption. Every candidate-catalog row whose `runtime_status` is `listed` or `recommendable` MUST have a model entry whose primary artifact is `verified` and byte-identical in identity to that row (§3.7.5), checked at generation and at consumption; a `candidate` row is out of that scope (§3.2). Within one artifact feed a `(hash_algorithm, hash)` pair MUST appear under exactly one model key and exactly one `artifact_id`; a duplicate is `catalog_artifact_feed_integrity_failure` at generation and at consumption, so a verified hash resolves to exactly one `(model_key, artifact_id)` and therefore to exactly one pricing identity, and a provider-offered `catalog_model_key` is advisory and MUST equal the resolved key or the match fails closed. For a `gguf` artifact, `source_ref.digest` MUST equal `"sha256:" + hash`; a mismatch is the same integrity failure, checked before `catalog_matched`. `artifact_id` MUST match `^[a-z0-9][a-z0-9-]{0,63}$` and MUST NOT be rebound to different bytes within or across releases; the generator MUST take the previous release's signed artifact feed as an input and reject any changed `(model_key, artifact_id)` binding, and the release ledger MUST record every `(model_key, artifact_id, hash_algorithm, hash)` binding so that check is reproducible from named release inputs (§3.7.4, §3.7.8). Only artifacts with `verification_status == "verified"` may satisfy a SPEC-047 catalog match, and settlement MUST bind the artifact `hash` together with its `hash_algorithm` — and, per the paragraph below, only for the primary artifact.

**In v0.10.0 only the PRIMARY artifact of a model key may bind `catalog_priced` or `settlement_capable`.** SPEC-010-R001 defines the canonical identity digest as the `model_sha256` of the exact signed candidate-catalog row and SPEC-010-R004 keeps that row as session authority for later heartbeats and settlement snapshots, so a non-primary artifact — of ANY runtime format, a secondary `mlx_safetensors` quantization exactly as much as a `gguf` artifact — is not a SPEC-010 identity and MUST NOT reach `catalog_priced` or `settlement_capable`, MUST NOT be used as the SPEC-010 provider `model_hash`/`model_hash_algorithm` pair, and MUST NOT bind a SPEC-022 route-time settlement snapshot. Non-primary artifacts reach at most identity, discovery, `listed` intake, `sandbox_probe_only`, and `network_visible_unpriced`. An artifact whose `hash_algorithm` is not a canonical wire pair named by SPEC-010-R002 is excluded on that independent ground as well. Widening this is a SPEC-010 amendment (§13 Q14), not a SPEC-023 change; v0.10.0 is deliberately consistent with SPEC-010 as it stands today.

**Artifact evidence is signer-bound at generation and snapshot-bound at settlement.** At generation and at consumption the authenticated artifact sidecar `key_id` MUST equal `release.json.feeds["autotune-artifacts.json"].signer_key_id` AND the authenticated candidate-feed signer `key_id` of that release; any mismatch, including a valid signature by a different concurrently trusted key, is `catalog_artifact_feed_integrity_failure` (§3.7.2, AC-CAT-1). When a SPEC-047-R003 trusted binding references an artifact of this feed, the SPEC-022 route-time verification snapshot — or a separate immutable record the snapshot references by digest — MUST carry `artifact_feed_sha256`, `artifact_id`, the artifact `hash`, its `hash_algorithm`, `artifact_feed_signer_key_id`, and the candidate-catalog body digest, and settlement MUST fail closed on missing, changed, cross-release, or wrong-signer artifact evidence (AC-CAT-20). That snapshot extension is a **SPEC-047-owned optional record**; **SPEC-022's minimum route-time snapshot field list is unchanged and SPEC-022 is NOT amended by this revision.**

Artifact-feed transport failure, integrity failure, update-required, or staleness MUST fail closed for every artifact-derived capability and MUST NOT block any behavior the §3.2/§3.3/§3.4 feeds already authorize. The feed MUST be bound in signed `release.json` and recorded in the §3.7.8 artifact-bound release-ledger feed set, and its activation MUST be staged: at Stage A it MUST NOT be added to the compatibility-set manifest's `components.catalog.files` map, and Stage B is permitted only once a bridge CLI accepting the widened map has shipped AND the previous-stable self-update release is at or after that bridge version (§3.7.8).

#### 3.7.8 Release binding, ledger feed sets, and staged activation

**Release binding.** `release.json` — the catalog release manifest generated and validated by the catalog release generator (`scripts/catalog-release.py`), on which §3.5 rules 11-13 and the §3.3 rate-card binding already depend — MUST bind `autotune-artifacts.json` by `sha256`, `bytes`, `version`, and `signer_key_id` alongside the existing feeds, and the release ledger (`release-ledger.json`, validated by that same generator) MUST record the release with the artifact-bound feed set below. That ledger row MUST additionally record, for the artifact feed it binds, every `(model_key, artifact_id, hash_algorithm, hash)` binding the feed publishes, in the exact `artifact_bindings` wire shape defined below, so the §3.7.4 cross-release `artifact_id` rebinding check has a durable authority: the verdict is reconstructible from named release inputs alone — this ledger plus the previous release's signed feed bytes — and is auditable without trusting the generator that produced the release. The release-ledger authority is that generator's ledger validator; **§9 is "Re-tune cadence + UX" and defines no release ledger**, and any cross-reference to a "§9 release ledger" is an error. This subsection is the normative statement SPEC-023 contributes to the ledger's feed-set rule.

**Ledger feed-set evolution (normative).** The ledger validates each release's feed-name set against an exact allowed set. Historical sets stay valid forever, because published releases are immutable and their signatures cover the shape they were cut with; a new set is added, never substituted. v0.10.0 adds a fourth allowed set and changes nothing about the first three:

| Ledger feed set | Members | Status after v0.10.0 |
|---|---|---|
| Legacy (2-feed) | `autotune-candidates.json`, `demand-rank.json` | Historical; permanently valid; MUST NOT be re-validated against any later set |
| Tier-2-bound (3-feed) | legacy + `tier2-catalog.json` | Historical; permanently valid |
| Rate-card-bound (4-feed) | Tier-2-bound + `rate-card.json` | Permanently valid for releases cut before the activation release below |
| Artifact-bound (5-feed) **[v0.10.0]** | rate-card-bound + `autotune-artifacts.json` | Valid from the activation release; MANDATORY for every release cut on or after it |

A release MUST use exactly one of these four sets; a mixed or partial set fails the release closed. The **activation release** is the first release published with the artifact-bound set, and from that release forward the artifact-bound set is the only set a NEW release may use — a later release that reverts to the rate-card-bound set is a downgrade and MUST fail the release closed. The existing per-feed version rule is unchanged and extends to the new member: `autotune-artifacts.json` is release-train-versioned like the candidate and demand feeds (its `version` equals the `release_id`), unlike `tier2-catalog.json` and `rate-card.json`, which carry their own content identities. Tombstone and release-ID rebinding rules are likewise unchanged and apply to the artifact-bound set identically: a `release_id` observed bound to two differing feed digest sets is permanently rejected, and the artifact feed's `sha256` and `bytes` participate in that observed binding exactly as the candidate and demand digests do.

**Release-ledger schema version 3 (normative wire shape).** The ledger document (`release-ledger.json`) is versioned by its own `schema_version` string, following the naming the generator's validator already uses for `macprovider.autotune-release-ledger.v1` and `macprovider.autotune-release-ledger.v2`. v0.10.0 adds **`macprovider.autotune-release-ledger.v3`**. The document's top level stays the exact closed set `{schema_version, releases, tombstones}` that v2 defines, and the tombstone shape is unchanged.

v3 changes exactly one thing: the per-release row. A v1/v2 row is the exact closed set `{generated_at, policy_version, feeds}`. A **v3 artifact-bound row** is the exact closed set `{generated_at, policy_version, feeds, artifact_bindings, intake_decision_sha256}` — the v1/v2 set extended with `artifact_bindings` (this subsection) and `intake_decision_sha256` (§16.8). No other key may appear in a release row, and a row missing any key of its applicable set fails the ledger closed.

- **`artifact_bindings`** is a JSON array. Each element is the exact closed object `{model_key, artifact_id, hash_algorithm, hash}`, all four values strings: `model_key` is the SPEC-005 §5.5 normalized catalog model key; `artifact_id` matches the §3.7.4 grammar `^[a-z0-9][a-z0-9-]{0,63}$`; `hash_algorithm` is one of the §3.7.4 matrix algorithms; `hash` is lowercase 64-hex. An unknown key, a missing key, a wrong-typed value, or an out-of-grammar `artifact_id` fails the ledger closed.
- **Completeness.** The array MUST contain exactly one element per `(model_key, artifact_id)` pair the row's `autotune-artifacts.json` publishes, for EVERY artifact regardless of `verification_status` — a `declared` or `blocked` artifact is recorded exactly as a `verified` one is, because the rebinding check is about bytes-under-an-id and not about trust state. A row that omits any published pair, or records a pair the feed does not publish, fails the ledger closed.
- **Canonical ordering.** Elements are ordered ascending by `model_key` compared as UTF-8 bytes, then ascending by `artifact_id` compared the same way. The order is part of the wire shape, not a presentation choice: two conforming generators fed one feed emit byte-identical `artifact_bindings`.
- **Uniqueness.** Within one row, `(model_key, artifact_id)` MUST appear at most once and `(hash_algorithm, hash)` MUST appear at most once — the ledger mirror of the §3.7.4 global artifact-hash uniqueness invariant. A duplicate of either kind fails the ledger closed, so the row cannot record an ambiguity the feed itself forbids.
- **`intake_decision_sha256`** is the lowercase 64-hex digest of the release's committed §16.8 `intake-decision.json`, or `null` for a release that adds no `listed` row and promotes no row to `recommendable`. A release that adds or promotes a row while recording `null` fails the ledger closed.
- **Historical rows are untouched and permanently valid.** A row written under v1 or v2 keeps its exact `{generated_at, policy_version, feeds}` shape forever. It MUST NOT be rewritten, MUST NOT gain `artifact_bindings` or `intake_decision_sha256` retroactively, and MUST NOT be re-validated against the v3 row rules. Within one v3 document, `artifact_bindings` and `intake_decision_sha256` are REQUIRED exactly when the row's feed-name set is the artifact-bound five-feed set, and PROHIBITED otherwise; a historical-feed-set row carrying either key, or an artifact-bound row missing either, fails the ledger closed.
- **Activation.** The first release published with the artifact-bound feed set MUST be written into a ledger serialized as `macprovider.autotune-release-ledger.v3`, and from that release forward every NEW release row MUST be a v3 artifact-bound row; a later ledger serialized as v2, or a later release recorded without `artifact_bindings`, is a downgrade and MUST fail the release closed. A v3 reader MUST accept v1 and v2 documents by the rule above. A v2 reader is not required to accept a v3 document, and this is not a fleet fail-close: `release-ledger.json` is a release-host and audit artifact validated by `scripts/catalog-release.py`, never fetched, baked, or parsed by an installed provider.

AC-CAT-19 asserts this concrete representation — field set, types, ordering, uniqueness, completeness, historical-row invariance, and activation — and not merely that the bindings are "recorded".

**Staged activation across the signed update package (§12.2-style).** The deployed provider CLI validates a signed compatibility-set manifest whose `components.catalog.files` map is an **exact nine-name set** and rejects any additional key (`phase3-binary/Sources/macprovider-cli/CompatibilitySetManifest.swift`); the package generator and the acceptance-candidate validator enforce that same exact nine-name set and, separately, an exact four-name `release.json` `feeds` set (`scripts/compatibility-set-manifest.py`, `scripts/acceptance-candidate-metadata.py`). Adding a tenth name to `components.catalog.files` would make every ALREADY-INSTALLED updater reject the v0.10 payload **before** the new binary that understands it can run — a fleet-wide fail-close of exactly the class §12.2 exists to prevent, and the direct opposite of §3.7.6 rule 6. Activation is therefore staged:

- **Stage A — v0.10.0 (this revision).** The artifact feed is generated, signed, served at `/v1/catalog-artifacts` with its detached sidecar, baked into the CLI release payload as the §3.7.2 fallback snapshot, bound in signed `release.json`, and recorded in the release ledger's artifact-bound feed set — so it is fully release-bound and tamper-evident through that chain. It **MUST NOT** be added to the compatibility-set manifest's `components.catalog.files` map, and the exact nine-name catalog file set the deployed updater enforces MUST remain unchanged. The producer-side `release.json` `feeds` check in `scripts/compatibility-set-manifest.py` is widened to the five-feed artifact-bound set in the same implementation slice; that script runs on the release host and in acceptance, never on an installed provider, so widening it fails-closes no fleet member. A v0.10.0 release therefore validates and installs on every previously shipped updater, under the exact rules that updater already applies.
- **Stage B — a later revision, gated.** `autotune-artifacts.json` and its `.sig` MAY join `components.catalog.files` (raising it to an eleven-name set) only when BOTH of the following hold: (i) a **bridge CLI** that accepts the widened map has shipped as a stable release, and (ii) the release designated **previous-stable** for the self-update path is at or after that bridge version. Until both hold, Stage B is PROHIBITED. This mirrors the §12.2 Stage-1/Stage-2 gate exactly: the forward-declaration ships first, and the enforcement flips only once the fleet can already parse what is being enforced.

Stage A is a weaker binding than Stage B **for the compatibility-set manifest only**. It is not weaker for the feed itself: §3.7.2 signature verification, §3.7.4 release binding, §3.7.5 primary-artifact consistency, and the §3.7.6 failure classes all apply in full at Stage A, and every artifact-derived capability still fails closed on any of them.

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
| ranked output length | `5 (+1 donor fallback)` | The JSON `candidates[]` array defaults to the top 5 rows after ranking, including eligible rows first and then selected ineligible diagnostic rows only when no eligible row exists. When `donor_fallback_explanation` is present for a fallback outside those 5 rows, emit that donor fallback as one additional displayed candidate so the explanation remains bound to a visible model. |
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
- `thermal_throttle_detected == false` **[amended v0.9.4 / #1269: `thermal_throttle_detected` == SUSTAINED thermal throttle (≥2 readable thermal samples `.serious`/`.critical` AND ≥50% of readable samples throttling) is a hard block for paid recommendation. A lone transient throttle amid a benign fair/nominal oscillation does NOT set it. Fail closed to true only when the whole thermal series is unreadable. Donor mode remains unaffected]**.
- The candidate benchmark must be from the current `benchmark_id` or from a cached run whose candidate catalog hash, binary version, model ID, and HMAC-derived hardware identity hash match and whose `generated_at` is no older than 7 days.
- There is no default 60_000 ms TTFT feasibility ceiling on the paid `--recommend` path. Omitting `--gate-ttft-ms` with `--recommend` disables that probe feasibility ceiling. Classic non-recommend Stage 1/2 retains the SPEC-013 default. The paid buyer-facing ceiling is the separate `--buyer-ttft-ceiling-ms` policy knob above.

In v0.4, there is no paid financial gate. All eligible rows proceed to recommendation regardless of earnings projections. Real earnings are recorded only after tokens are served.

## 6. Output JSON contract (`autotune --recommend`)

`autotune --recommend --json` MUST emit deterministic field order exactly as shown below. Unknown optional data uses `null`; fields are not reordered, renamed, or omitted, except for the opt-in `context_calibration` extension defined by SPEC-023-R003. That field appears immediately after `serve_config` only when `--calibrate-context` completes successfully and is absent otherwise, preserving the pre-v0.9.5 byte shape for ordinary runs. The explanation fields are additive `autotune_recommend.v1` extensions. Older v1 documents without them remain schema-decodable by Malibu for compatibility, but they are not valid recommendation display/adoption evidence for a non-null `recommended_model`; Malibu MUST reject recommended documents that lack selected/candidate explanation parity rather than rendering legacy free-text rationale as trusted recommendation evidence. Malibu treats this document family as advisory display evidence unless a later schema adds verifiable adoption authority; explanation parity alone is not one-click adoption authority.

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
  "context_calibration": {
    "schema_version": "autotune_context_calibration.v1",
    "recommended_context": 8000,
    "safe_upper_bound": 50000,
    "minimum_context": 4000,
    "ttft_ceiling_ms": 8000,
    "quantum": 1000,
    "prompt_reserve_tokens": 256,
    "completion_tokens": 1,
    "measurements": []
  },
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
      "explanation": {
        "summary": "<safe one-line rationale>",
        "warning_state": "ready",
        "measured_tps": 0.0,
        "throughput_source": "measured",
        "memory_fit": {
          "required_gb": 0,
          "total_gb": 0,
          "safety_margin_gb": 4,
          "headroom_gb": 0.0
        },
        "demand_signal": {
          "rank": null,
          "weight": 0.0,
          "recommendable": false,
          "min_provider_target": 0,
          "ready_provider_count": null,
          "supply_deficit_multiplier": 0.0
        },
        "rate_signal": {
          "prompt_rate_usd_per_million_tokens": 0.0,
          "completion_rate_usd_per_million_tokens": 0.0,
          "provider_share_bps": 0,
          "provider_completion_payout_usd_per_million_tokens": 0.0
        },
        "earning_potential": {
          "score": 0.0,
          "kind": "relative_ranking_score",
          "note": "Estimated earning potential only; actual rewards depend on buyer demand, uptime, accepted work, and settlement."
        },
        "local_health": {
          "warnings": []
        },
        "confidence": "low",
        "lost_reason": "<machine_reason_slug>"
      },
      "bench_gate_provenance": {
        "source": "policy",
        "notes": "#744 audit: gate set by operator policy to broaden eligibility."
      },
      "bench_gate_drift": [],
      "buyer_ttft_ceiling_exceeded": false
    }
  ],
  "warnings": [],
  "selected_explanation": null,
  "alternative_explanations": [
    {
      "rank": 2,
      "model": "<model_key>",
      "eligible": true,
      "lost_reason": "lower_expected_earning_potential",
      "summary": "<safe one-line rationale>",
      "expected_earning_potential_score": 0.0
    }
  ],
  "donor_fallback_explanation": null
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
- `candidates[]` default length is at most 5. It is sorted by eligibility first, then `raw_score` descending, then `model` lexicographically for deterministic ties. It MAY contain one additional donor fallback candidate when `donor_fallback_explanation` is present and the fallback is outside the default 5 rows.
- Candidate `prompt_rate_usd_per_million_tokens` and `completion_rate_usd_per_million_tokens` are USD display rates from the rate-card row used for that candidate.
- Top-level `prompt_rate_usd_per_million_tokens` and `completion_rate_usd_per_million_tokens` MUST be finite, non-negative, and equal to the selected candidate's candidate-level rates. When `selected_explanation` is present, they MUST also equal `selected_explanation.rate_signal.prompt_rate_usd_per_million_tokens` and `selected_explanation.rate_signal.completion_rate_usd_per_million_tokens`.
- `raw_score` is rounded to 6 decimal places in JSON.
- Candidate `explanation` is optional for legacy v1 decoding but MUST be present in newly emitted output for every displayed candidate. A Malibu consumer that displays a non-null `recommended_model` as recommendation evidence MUST require the selected candidate explanation and top-level `selected_explanation` to be present and semantically equal. Its fields are display-safe, machine-readable evidence for the candidate's rank and eligibility. `summary` is a safe one-line rationale from the CLI-owned template set and MUST NOT contain local paths, provider identity material, hardware identity material, HMAC/key material, or guaranteed/daily/hourly/weekly income claims.
- Candidate `explanation.measured_tps`, `explanation.memory_fit.headroom_gb`, `explanation.memory_fit.total_gb`, and `explanation.earning_potential.score` MUST match the candidate's `tokens_per_second`, `memory_headroom_gb`, detected `hardware.memory_gb`, and `raw_score` respectively. Consumers MUST reject contradictory explanation/candidate evidence rather than trying to reconcile it.
- `explanation.warning_state` is one of `ready`, `advisory`, or `blocked`.
- `explanation.throughput_source` is one of `measured`, `catalog_estimate`, or `unavailable`; `catalog_estimate` MUST be used when installed-only disclosure uses signed catalog estimates instead of a local throughput benchmark.
- `explanation.memory_fit` reports signed candidate memory requirement, detected total memory, the local safety margin, and computed headroom in GB.
- `explanation.demand_signal` reports the signed demand rank inputs used for relative ranking. Missing demand uses `rank = null`, `recommendable = false`, and `weight = 0.0`; it must be described as unavailable, not as live demand.
- `explanation.rate_signal` reports the rate-card row used for relative ranking. Provider payout values are per-million-token rates and MUST NOT be described as accrued rewards.
- `explanation.earning_potential.kind` is exactly `relative_ranking_score`. `explanation.earning_potential.note` is exactly `Estimated earning potential only; actual rewards depend on buyer demand, uptime, accepted work, and settlement.`
- `explanation.local_health.warnings` contains only stable local probe warning slugs such as `thermal_throttle_detected`, `thermal_throttled`, `swap_observed_under_load`, and `buyer_ttft_ceiling_exceeded`.
- `explanation.confidence` uses the same values as candidate `confidence`; installed-only catalog estimate disclosure may use `catalog_estimate`.
- `explanation.lost_reason` is a lowercase machine slug explaining why the candidate is selected, lower-ranked, or blocked.
- `selected_explanation` is `null` when there is no selected candidate. When present, it MUST be byte-for-byte semantically equal to the selected candidate's `explanation`.
- `alternative_explanations[]` is optional for legacy readers but newly emitted output SHOULD include non-selected displayed candidates. Each alternative explanation MUST bind to exactly one non-selected candidate with the same `model`, `lost_reason`, `summary`, and `earning_potential.score`.
- `donor_fallback_explanation` is `null` unless a donor fallback candidate is selected for display; when present it has the same object shape and safety constraints as candidate `explanation` and MUST bind to exactly one displayed candidate with a semantically equal candidate `explanation`.
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
- `warnings[]` is an array of stable machine-readable strings, sorted lexicographically. v0.6 adds `candidate_catalog_integrity_failure`, `candidate_catalog_update_required`, `demand_rank_integrity_failure`, and `demand_rank_update_required`; v0.8 adds `buyer_ttft_ceiling_exceeded`; v0.8.1 restores `rate_card_default_tier_used` as the visible signal for default-row pricing fallback; v0.8.6 adds `rate_card_integrity_failure`, `rate_card_update_required`, and `rate_card_stale`; v0.10.0 adds `catalog_artifact_feed_fallback_used`, `catalog_artifact_feed_integrity_failure`, `catalog_artifact_feed_update_required`, and `catalog_artifact_feed_stale` (§3.7.6). Any integrity/update-required warning of the §3.2–§3.4 feeds blocks a paid recommendation; the `catalog_artifact_feed_*` codes never do (§3.7.6 rule 6) — they fail closed for artifact-derived capabilities only.

## 7. Per-token payout semantics

In v0.4, provider earnings are fully determined by real delivered tokens and the per-token rate from the rate card:

```text
real_earnings = sum(tokens_served × rate_per_token_from_rate_card)
```

The install transcript shows a per-token rate at recommendation time and instructs the operator that the provider will earn `sum(tokens × rate)` deterministically.

### 7.1 Happy path (recommended model)

For `malibu-cli autotune --recommend`, use this text verbatim,
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
              malibu-cli serve
```

Happy path applies only when at least one recommendable model is eligible and clears all §5 gates.
After the CLI applies the recommendation, it replaces the final two lines above with:

```text
Configuration applied. Start the provider with:
              malibu-cli serve
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

- `malibu-cli status` must show a `DONOR MODE` badge alongside the configured model while `donor_mode: true`.

## 9. Re-tune cadence + UX

`autotune --recommend` re-runs or prompts the operator in exactly these v0.4 cases:

1. Manual invocation: `malibu-cli autotune --recommend`.
2. `malibu-cli update` or installer rerun after install, when the live rate-card version, live demand-rank version, signed candidate-catalog version/hash, binary version, stable hardware identity hash, or benchmark age differs from stored recommendation state.
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

`recommended_bench_gate_provenance_source` is the selected row's `bench_gate.provenance.source`; `recommended_gate_seed_identity` records the selected row's seed identity (at minimum `gate_seed.omlx_snapshot_id` and `gate_seed.seeded_at`) when the selected row is `omlx_seeded`, and is `null` otherwise. These fields let `malibu-cli status` render provisional oMLX provenance (AC-OMLX-6) without re-fetching the catalog. When `recommended_bench_gate_provenance_source == "omlx_seeded"`, `malibu-cli status` MUST render the exact label `oMLX-seeded; not macprovider-verified` alongside the configured model.

Stored hash/version derivation:

- `candidate_catalog_sha256` is the lowercase hex SHA-256 over the exact selected catalog JSON bytes after fetched/baked selection and before parsing normalization.
- `rate_card_version` is the `/v1/rate-card.version` recommendation-projection hash from §3.3. It MUST NOT reuse broader coordinator config or billing snapshot hashes that include unrelated ledger, quarantine, request-log, operator, or settlement state.
- `demand_rank_version` is the selected demand-rank JSON `version`; v0.4 does not require an additional stored demand-rank hash.

`malibu-cli status` MUST emit a stale-recommendation warning when the live rate-card version, demand-rank version, candidate-catalog version/hash, binary version, stable hardware identity hash, or benchmark freshness differs from this stored state:

```text
Recommendation stale: recommendation inputs changed since {generated_at}.
Run: malibu-cli autotune --recommend
```

### 9.1 Guarded interactive-context calibration

**SPEC-023-R003:** When `autotune --recommend --calibrate-context` is explicitly requested, the CLI MUST calibrate only the selected, already-verified signed model artifact. It MUST keep the existing RAM/model context cap as a hard upper bound, use 4,000 tokens as the minimum, search in 1,000-token cells, and select the largest cell whose uncached-prefill p95 TTFT is no greater than 8,000 ms. Each measured request MUST use a one-token completion and fill the candidate context to its advertised boundary minus an explicit 256-token reserve for chat-template/token-estimation overhead. Search MAY use one sample per cell, but the final selected cell MUST pass three distinct uncached prompts. Prompt identity MUST differ between measured samples; the model/JIT MAY be warmed with a separate short prompt, but the measured long prompt MUST NOT be prewarmed. Sustained memory-pressure or thermal-throttle vetoes, malformed results, timeouts, interruption, a failing minimum, or a failing final validation MUST fail closed before recommendation state or config mutation. JSON and stored recommendation state MUST carry the calibration policy, prompt reserve, completion-token count, measurements, safe upper bound, and selected context. Without `--calibrate-context`, behavior and output shape MUST remain unchanged.

Automatic installer use of this requirement is not authorized by v0.9.5. It remains pending a signed `JOURNEY-PROVIDER-PREBETA-ADMISSION` result covering the selected hardware/model/context and an owner decision under issue #1201.

## 10. Goodhart mitigations

| ID | Mitigation | SPEC-023 implementation |
|---|---|---|
| M1 | Deterministic diversification | **[deferred v0.5]** v0.4's 85% pool + `stable_hash(...) % len(pool)` is suspended for beta supply growth. v0.5 uses strict payout-first argmax + tiebreakers; re-enable diversification when supply exceeds demand. |
| M3 | Cold-start floor | §3.4 and §4 lock `cold_start_floor = 0.15` as a demand-weight tiebreaker floor in v0.5. |
| M4 | Row lifecycle states | §3.2 and §3.4 lock `runtime_status` and `recommendable`; §5 requires both before default recommendations. **[extended v0.10.0]** §3.2's ladder table and §16 make `listed` the cheap intake tier — identity plus a verified artifact, never a paid default — so a new row accumulates evidence while visible and matchable but unpriced; §16.6 records how that tier plus rank floors address `RESEARCH_229` FM-1 and FM-2. |
| M7 | Rate-card version binding | §3.3, §6, and §9 persist `rate_card_version`. |
| M8 | Retune hint | §9 defines upgrade/manual triggers and stale status text. |
| M12 | Hard eligibility gates | §5 requires RAM, benchmark, no-swap, no-thermal, and rate-card gates before scoring. |
| M16 | Deployability gate | §3.2 and §3.4 define deployability via `runtime_status` + `recommendable`; §5 enforces both. |
| M18 | Full-utilization wording | §4 separates ranking from displayed capacity; §7 uses per-token rates only. |
| M20 | Static JSON demand control plane | §3.4 requires `coordinator.malibu.tech/v1/demand-rank` with baked fallback and version metadata. |

## 11. Acceptance criteria

AC-1: `malibu-cli autotune --recommend --json` output validates against `autotune_recommend.v1` for any Mac where `MachineFingerprinter.sample()` returns at least `ram_gb = 1`.

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

AC-24: `malibu-cli status` shows `DONOR MODE` when `donor_mode: true`.

AC-25: `malibu-cli update` and installer rerun compare stored `rate_card_version`, `demand_rank_version`, `candidate_catalog_version/hash`, `binary_version`, `hardware_identity_hash`, and benchmark age with live/current values and prompt re-tune when any changed or expired.

AC-26: `malibu-cli status` emits the stale-recommendation warning in §9 when stored recommendation metadata differs from live metadata.

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

AC-37 **[amended v0.8.6]**: Unauthenticated `GET https://coordinator.malibu.tech/v1/rate-card` and `GET https://coordinator.malibu.tech/v1/rate-card.sig` reach the coordinator buyer mux through nginx and return the §3.3 schema/sidecar; both nginx routes are declared before the generic `/v1/` 404 block.

AC-38: `rate_card_version` changes when the recommendation projection rows, provider share, global multiplier, or `usd_per_million_credits` change, and does not change when unrelated quarantine, request-log, operator, ledger runtime, or settlement runtime state changes.

AC-39: `candidate_catalog_sha256` is computed over the exact selected catalog JSON bytes, so changing catalog whitespace changes the stored hash while preserving schema validation behavior.

AC-40 (`SPEC-023-R003`): An explicit context-calibration run never exceeds the RAM/model upper bound, measures near the advertised boundary with one completion token and a 256-token overhead reserve, uses unique measured prompts, validates the final context with three samples, persists the evidence, and fails before state/config mutation when interrupted or when the minimum, safety checks, deadline, response validation, or final p95 TTFT ceiling fails. The same recommendation command without `--calibrate-context` preserves the pre-v0.9.5 output shape and emits/applies the pre-v0.9.5 RAM/model-derived cap unchanged.

AC-OMLX-1: A row with `bench_gate.provenance.source == "omlx_seeded"` and `runtime_status == "recommendable"` is rejected by catalog validation.

AC-OMLX-2: A row with `bench_gate.provenance.source == "omlx_seeded"` and a missing, malformed, or incomplete `bench_gate.gate_seed` is a catalog-integrity failure rejected fail-closed at catalog authoring, lint, and signing (the same authoring boundaries as the forbidden-seed-on-non-oMLX-row case, AC-OMLX-7). At CLI/coordinator decode the effect is phase-qualified (§12.3): PRE-activation the mere presence of the unsupported oMLX schema is a whole-catalog integrity failure; POST-activation the malformed row decodes successfully and is row-scoped quarantined (excluded from download/benchmark/donor/recommendation), never a whole-catalog failure and never blocking coordinator join or SPEC-032 admission.

AC-OMLX-3: `autotune --recommend` never selects an `omlx_seeded` row as the default recommendation.

AC-OMLX-4: In Stage 1, promotion of an `omlx_seeded` (or formerly-`omlx_seeded`) row to `recommendable` is PROHIBITED and fails closed (the row stays `listed`) because the Stage-2 verified-evidence-record mechanism (signed immutable per-measurement references + deterministic aggregation) does not yet exist, so no promotion can be proven backed by the `N = 3` verified measurements. The transition is DEFINED but inert. When that mechanism exists, promotion is refused unless at least `N = 3` verified provider autotune measurements on eligible hardware exist and promotion depends solely on those measurements: the oMLX seed is NEVER the pass/fail criterion and is NEVER an input to the promoted gate — the promoted `min_sustained_tps` is recomputed solely from the `N` verified measurements, the promoted row has `bench_gate.provenance.source == "verified_provider_matrix"`, and it carries no `gate_seed`. A promotion computed by testing verified runs against the provisional oMLX gate, that reuses the oMLX seed value in the promoted gate, or that is performed before the Stage-2 evidence-record mechanism exists, is rejected.

AC-OMLX-5: Seeded `min_sustained_tps` equals `max(8, floor(board_p25_tg * engine_delta_applied * 0.90))` computed from the row's own `gate_seed` values; a row whose stored `min_sustained_tps` does not equal that computed value is rejected as a catalog-integrity failure. (This AC is NOT satisfied by always emitting `8`: a well-formed seed whose computed value exceeds 8 MUST store that higher value, and a row that stores `8` when the formula yields a higher number is rejected.) A seed derived from a `.dev` oMLX board release or from undiscounted MTP/speculative-decode observations is rejected.

AC-OMLX-5a (positive fixture): A well-formed `omlx_seeded` row with `board_p25_tg = 90.6`, `engine_delta_applied = 0.85`, `observations_used_n >= K`, a stable (non-`.dev`) `board_release_tag`, `mtp_discounted = true`, and a `seeded_at` within the freshness window computes `min_sustained_tps == max(8, floor(90.6 * 0.85 * 0.90)) == 69` and is accepted (as `candidate` or `listed`).

AC-OMLX-5b (K rejection): An `omlx_seeded` row with `gate_seed.observations_used_n < K` (`K = 10`) is rejected — ineligible and fail-closed before download or benchmark.

AC-OMLX-5c (cross-cell rejection): An `omlx_seeded` row whose `gate_seed` observations span more than one normalized cell — a mix of chips, RAM classes, models, quants, or context lengths not all within its declared `gate_seed.target_cell` — is rejected as a catalog-integrity failure, even when the aggregate `observations_used_n >= K`. `observations_used_n` is bound to the single `target_cell`.

AC-OMLX-6: Recommendation JSON, human `autotune --recommend` output, and `malibu-cli status` surface oMLX provenance as provisional and not macprovider-verified. `malibu-cli status` reads the persisted recommendation state (§9), which retains the selected row's `bench_gate.provenance.source` and `gate_seed` identity, and MUST render the exact label `oMLX-seeded; not macprovider-verified` for a selected `omlx_seeded` row.

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

AC-CAT-1 (`SPEC-023-R004`, feed trust and closed schema): A fetched `autotune-artifacts.json` whose sidecar is missing or malformed, whose `key_id` is unknown to the release-pinned keyring, whose `alg` is not `ed25519`, whose signature fails, or whose schema is invalid emits `catalog_artifact_feed_integrity_failure`; no artifact from that feed is matched, displayed as catalog-verified, downloaded, prepared, probed, priced, or settled while the warning is present. Transport/HTTP unavailability instead selects the baked artifact snapshot with `catalog_artifact_feed_fallback_used`. "Schema is invalid" is tested explicitly against the §3.7.3 closed field sets: for each of the top-level object, a `models.<model_key>` object, an `artifacts.<artifact_id>` object, and each `source_ref.kind` variant, a feed carrying one unknown field, a feed omitting one REQUIRED field, and a feed carrying one field at the wrong JSON type each emit `catalog_artifact_feed_integrity_failure` — a cryptographically valid signature over those bytes does not rescue any of them. A `source_ref` whose `kind` is unknown, or which carries one variant's fields under the other's `kind`, fails the same way. The release generator rejects each of those same shapes before signing. **Signer identity is tested as an equality, not as keyring membership:** an artifact feed carrying a cryptographically VALID Ed25519 signature made by a **different but concurrently trusted key** — a second `key_id` present in the release-pinned keyring, as during a rotation bridge — whose `key_id` therefore differs from `release.json.feeds["autotune-artifacts.json"].signer_key_id` or from the authenticated candidate-feed signer `key_id` of the same release, fails closed at BOTH ends: the generator rejects the release before signing, and a consumer holding both feeds emits exactly `catalog_artifact_feed_integrity_failure` — never `catalog_artifact_feed_update_required` — and matches, displays, downloads, prepares, probes, prices, and settles nothing from that feed. A feed whose sidecar `key_id` equals both bindings validates (§3.7.2).

AC-CAT-2 (`SPEC-023-R004`, no fleet fail-close): With the artifact feed absent, stale, integrity-failed, or update-required, `autotune --recommend` produces exactly the recommendation, JSON shape, warnings, and coordinator-join outcome it produces on a v0.9.5 release for the same inputs, apart from the artifact-feed warning itself. No artifact-feed failure class blocks paid recommendation, coordinator join, or model download by the candidate row's own `model_revision`/`model_sha256`.

AC-CAT-3 (`SPEC-023-R004`, no candidate-row schema change): The published candidate catalog of a v0.10.0 release contains no `rate_class`, artifact-set, or intake field, and decodes without error under the pre-v0.10.0 CLI Swift strict decoder's exact allowed row-key set. A release whose candidate catalog carries any additional row key is rejected at generation.

AC-CAT-4 (`SPEC-023-R004`, release binding): An artifact feed whose `version`, `release_id`, `generated_at`, `policy_version`, or `candidate_catalog_sha256` disagrees with the selected candidate catalog is a mixed release, emits `catalog_artifact_feed_update_required`, and fails closed for every artifact-derived capability.

AC-CAT-5 (`SPEC-023-R004`, primary-artifact consistency): For every candidate row whose `runtime_status` is `listed` or `recommendable`, the artifact feed's `primary_artifact_id` artifact is `mlx_safetensors`, `macprovider.snapshot-manifest.v1`, `verified`, and equal to that row's `model_sha256`, `model_id`, `model_revision`, and `min_ram_gb`. A release violating this fails closed at generation before signing, and a consumer holding both feeds fails closed for artifact-derived use before binding anything. The emitted warning is exactly `catalog_artifact_feed_integrity_failure` and never `catalog_artifact_feed_update_required` (§3.7.6 rule 3), so one code is asserted by both the generator test and the consumer test. A `candidate` row whose artifacts are all `declared` is NOT a consistency failure and produces no warning: it is out of scope for the `verified` requirement of both §3.7.4 and §3.7.5. Its `primary_artifact_id` is still asserted to name a schema-valid `mlx_safetensors` artifact whose `source_ref.repo_id`, `source_ref.revision`, `hash_algorithm`, and `hash` correspond to the row's `model_id`, `model_revision`, and `model_sha256`; a `candidate` row whose primary artifact is absent, of the wrong format, or identity-mismatched fails closed at generation exactly as a `listed` row does.

AC-CAT-6 (`SPEC-023-R004`, verified-only settlement): A `declared` or `blocked` artifact never satisfies a SPEC-047 catalog match, never supports `catalog_priced` or `settlement_capable`, and is never downloaded or prepared as a catalog artifact. A settlement binding records the artifact `hash` together with its `hash_algorithm`, never the hash alone.

AC-CAT-7 (`SPEC-023-R004`, GGUF is identity-only in v0.10.0): An artifact with `hash_algorithm == "macprovider.gguf-file.v1"` AND `verification_status == "verified"`, whose `hash` exactly equals the provider's locally computed digest, belonging to a candidate row whose `runtime_status` is `listed` or `recommendable`, reaches `catalog_matched`, `listed` intake, `sandbox_probe_only`, and `network_visible_unpriced`. It is refused as `catalog_priced`, as `settlement_capable`, as a SPEC-010 provider `model_hash`/`model_hash_algorithm` wire pair, and as a SPEC-022 route-time settlement binding, on BOTH independent grounds — it is not the primary artifact (AC-CAT-17) and its algorithm is not named by SPEC-010-R002. Change any precondition and the match itself fails: a `declared` or `blocked` artifact, an inexact digest, or a `candidate` or `blocked` row reaches no admission tier at all (AC-CAT-6, §3.2).

AC-CAT-8 (`SPEC-023-R005`, published schema unchanged): The published `rate-card.json` of a class-expanded release validates against the §3.3 schema with no `classes` key and no per-row class field, and its recommendation-projection `version` is computed by the unchanged §3.3 algorithm.

AC-CAT-9 (`SPEC-023-R005`, precedence and expansion): A model key with an explicit rate-card source row publishes that row verbatim and discards its class expansion; a model key with only a `rate_class` publishes a concrete row materialised from that class into both the published rate card and the coordinator inline fallback rows, under the exact §3.3.1 rule-4 field mapping. A rate-card source whose `classes` block declares `provider_share_bps` or `global_multiplier_ppm` on a class fails the release closed. Expansion is deterministic and reproducible from the release inputs alone. **The authoring source schema is closed and is tested as such:** a `rate-card-source.json` (§3.3.1 rule 3, `schema_version: "macprovider.rate-card-source.v1"`) carrying one unknown top-level key, omitting one required top-level key of the exact set `{schema_version, generated_at, policy_version, usd_per_million_credits, provider_share_bps, global_multiplier_ppm, rows, classes}`, carrying one top-level value at the wrong JSON type, declaring an unknown `schema_version`, or carrying a `rows` or `classes` entry with any field beyond the three credit-rate fields each fails the release closed at generation before signing; a source with `rows` and `classes` both present and empty is valid. The published `rate-card.json` is materialised from that source and is never byte-equal to it, and the source is never served, baked, bound in `release.json`, or recorded in the release-ledger feed set.

AC-CAT-10 (`SPEC-023-R005`, no silent repricing and no orphan `recommendable`): The first release introducing class expansion publishes a `rate-card.json` whose `rows` map is byte-identical to the preceding release's `rows` map. A release in which any `recommendable` candidate row resolves to no rate-card row by exact key or `NormalizeModelKey` fails closed at generation. SPEC-005 §5.5 resolution behavior is unchanged and SPEC-005 is not amended.

AC-CAT-11 (`SPEC-023-R006`, tier boundary): A key admitted as `listed` is discoverable, is SPEC-047 `catalog_matched` when a BYOM candidate's artifact hash equals one of its verified artifacts, is eligible for `sandbox_probe_only` and `network_visible_unpriced`, requires no `rate_class` and no rate row, and is never selected as `recommended_model` and never reaches `catalog_priced` or `settlement_capable`. A key lacking any `verified` artifact MUST NOT enter `listed` or `recommendable`; it may exist only as a `candidate` staging row, which is not BYOM-matchable and reaches no SPEC-047 admission tier at all (§3.2, §16.1 P1). Authoring that `candidate` row with an all-`declared` artifact set is valid and emits no warning.

AC-CAT-12 (`SPEC-023-R006`, signals are floors and promotion is manual): Each intake signal is evaluated as a threshold test whose result is boolean; no signal value orders admitted keys, contributes to `raw_score`, or promotes a row. `distinct_provider_offer_count` counts distinct providers, excludes sanctioned providers, and is reported as suppressed below the SPEC-023-owned `INTAKE_K_ANONYMITY_MIN` (§16.4, default 3) rather than as a small number. A suppressed provider count never satisfies `INTAKE_OFFER_FLOOR` — it is not unsuppressed, not read as "at least k", and not added back for the comparison — and a release configured with `INTAKE_OFFER_FLOOR < INTAKE_K_ANONYMITY_MIN` fails closed at generation. This signal is coordinator-owned SPEC-047 admission data and is usable for intake with no SPEC-017 amendment, unlike `unmatched_model_request_count`. Promotion from `listed` to `recommendable` requires an explicit operator admission in addition to every threshold, and no `omlx_seeded` row is promoted.

AC-CAT-13 (`SPEC-023-R006`, bounded unknown-model signal): `unmatched_model_request_count` satisfies the §16.2(a) field contract. Requests that are unauthenticated, rejected before model resolution, or flagged test/synthetic/internal contribute to no bucket. Keys are bucketed only after SPEC-005 `NormalizeModelKey`, and only when the normalized key matches `[a-z0-9._/-]{1,128}` in full; an over-long or out-of-grammar key creates no named bucket. The §16.2(a) per-request processing order is asserted step by step: an ineligible request (S1) contributes to nothing at all, an out-of-grammar key (S3) and a capped or overflow-principal contribution (S4) contribute to `other_suppressed` ONLY and never reach the item-4 update, and only an S1-through-S4 survivor performs the Space-Saving update (S5) — an implementation that increments a named entry first and subtracts capped traffic afterwards fails this criterion. Retention uses the §16.2(a) item-4 Space-Saving summary at capacity `INTAKE_UNKNOWN_KEY_BUCKETS` (default 64) with the specified deterministic victim and tie rules: two runs over the same request order produce the identical summary, and a key whose true count exceeds one 64th of the window's eligible request volume is monitored. **Resource bounds are proven, not asserted.** Under adversarial distinct-key fanout (millions of distinct eligible keys in one window) the test measures that total aggregator memory stays at or below `INTAKE_UNKNOWN_KEY_BUCKETS` summary entries plus `INTAKE_UNKNOWN_KEY_BUCKETS * INTAKE_UNKNOWN_PRINCIPALS_PER_BUCKET` principal counters plus the two `other_suppressed` counters, and that per-request work is constant. Under adversarial distinct-PRINCIPAL fanout against a single key (millions of distinct principals) the same bounds hold, and overflow principals beyond `INTAKE_UNKNOWN_PRINCIPALS_PER_BUCKET` contribute only to `other_suppressed`. Only the conservative lower bound `count - error` is compared against `INTAKE_BUYER_REQUEST_FLOOR`; a bucket whose upper-bound `count` clears the floor while its lower bound does not, does not clear it. `other_suppressed` is the exact closed object `{request_count, request_count_saturated, distinct_key_count, distinct_key_count_saturated}` — four fields, no fifth, no bare `saturated` key — each counter saturating at its §16.4 cap and setting its OWN boolean flag, so a test can tell which counter saturated; a bucket carrying an unknown, missing, or wrong-typed field is rejected as malformed, and neither counter ever clears a floor. An eviction transfers only the victim entry's non-inherited contribution `victim_count - victim_error` into `other_suppressed.request_count`, so a count inherited through a chain of evictions is added there exactly once. One principal's contribution to one bucket in one window is capped at `INTAKE_UNKNOWN_KEY_PRINCIPAL_CAP_PCT` of `INTAKE_BUYER_REQUEST_FLOOR`, with the excess discarded into `other_suppressed` and no per-principal breakdown emitted or retained. A bucket below the effective k-anonymity floor (`INTAKE_K_ANONYMITY_MIN`, §16.4, or a higher SPEC-017 value) is reported as suppressed. A single principal generating any volume of requests for one key never clears the floor, `other_suppressed` never clears it, and a suppressed bucket never clears it. No buyer account, API key, IP address, prompt, completion, or per-request row exists at any stage, **and no item-7 opaque principal token appears in any emitted or retained record**; `window_key` and every derived token are destroyed at window close, so tokens from two windows for the same principal do not correlate. **Raw principal identifiers are asserted TRANSIENT, not merely unemitted:** immediately after the S4 token derivation for a request, the test asserts that no raw principal identifier is reachable from any aggregator state — no bucket, counter table, principal table, cached field, log line, trace span, or metric label — and that a serialized diagnostic dump of the aggregator taken at that instant contains no raw principal identifier. An implementation that keeps the raw identifier alongside its token for the life of the window fails this criterion even though it emits no identity. Until SPEC-017 adopts this contract by amendment, a field of this name satisfies no intake floor.

AC-CAT-14 (`SPEC-023-R005`, generated-feed / billing-config parity): For a class-expanded release, the published `rate-card.json` `rows` map and the coordinator inline fallback `rewards.rate_card` rows published with it have the same normalized key set and, per key, `prompt_rate_per_mtok == prompt_credits_per_mtok`, `prompt_cache_hit_rate_per_mtok == prompt_cache_hit_credits_per_mtok`, and `completion_rate_per_mtok == completion_credits_per_mtok`. The release's `provider_share_bps / 10000` equals the published `rewards.provider_share` and its `global_multiplier_ppm / 1000000` equals the published `rewards.global_multiplier`. No coordinator `rewards.rate_card` row carries a share or multiplier field. A mutation of any one of those values on either side — a changed credit value, an extra or missing key, a per-row share, or a global that disagrees with the coordinator configuration — fails the release closed at generation before signing.

AC-CAT-15 (`SPEC-023-R004`, staged activation and previous-stable self-update): A v0.10.0 release payload — artifact feed generated, signed, served, baked, bound in `release.json`, and recorded in the §3.7.8 artifact-bound ledger feed set — is validated and installed by the LAST pre-v0.10 updater through the previous-stable self-update path, with no compatibility-set-manifest rejection and no rollback. The signed compatibility-set manifest of that release carries the unchanged exact nine-name `components.catalog.files` set, and a release that adds `autotune-artifacts.json` to that map is rejected at generation while Stage B is ungated. Stage B is permitted only when a bridge CLI accepting the widened map has shipped as stable AND the previous-stable release is at or after that bridge version; a Stage-B release cut with either condition unmet fails closed. The ledger accepts the legacy two-feed, Tier-2-bound three-feed, and rate-card-bound four-feed historical sets unchanged, accepts the artifact-bound five-feed set, and rejects a mixed or partial set, a post-activation release that reverts to the four-feed set, and a `release_id` observed bound to two differing feed digest sets.

AC-CAT-16 (`SPEC-023-R004`, closed artifact-identity tuple): Every artifact entry matches exactly one row of the §3.7.4 matrix. Each of the following illegal tuples emits `catalog_artifact_feed_integrity_failure` at consumption and is rejected by the generator before signing, even with a valid signature over the bytes: `mlx_safetensors` with `macprovider.gguf-file.v1`; `gguf` with `macprovider.snapshot-manifest.v1`; `mlx_safetensors` with `source_ref.kind == "ollama_library_tag"`; `gguf` with `source_ref.kind == "huggingface_revision"`; `mlx_safetensors` whose `allowed_runtime_sources` contains any loopback adapter; `gguf` whose `allowed_runtime_sources` contains `mlx_cache`; and any `verified` artifact whose `allowed_runtime_sources` contains `openai_compatible_loopback`. A legal `mlx_safetensors` tuple and a legal `gguf` tuple both validate. **Value-level source binding is tested alongside the tuple:** a `gguf` artifact whose `source_ref.digest` is not exactly `"sha256:" + hash` — a differing digest, a missing `sha256:` prefix, an uppercase digest, or a digest naming a different blob — emits `catalog_artifact_feed_integrity_failure` at consumption BEFORE the artifact may satisfy `catalog_matched`, and is rejected by the generator before signing; a `gguf` artifact whose `source_ref.digest` equals `"sha256:" + hash` validates.

AC-CAT-17 (`SPEC-023-R004`, primary-only settlement identity): Only the artifact named by a model key's `primary_artifact_id` reaches `catalog_priced` or `settlement_capable`, is reported as the SPEC-010 provider `model_hash`/`model_hash_algorithm` wire pair, or binds a SPEC-022 route-time settlement snapshot. A **secondary `mlx_safetensors` artifact** — `verified`, correctly declaring `macprovider.snapshot-manifest.v1`, differing from the primary only in quantization and therefore in `hash` — reaches `catalog_matched`, `sandbox_probe_only`, and `network_visible_unpriced` and is refused `catalog_priced`, `settlement_capable`, the SPEC-010 wire pair, and the SPEC-022 binding, exactly as a `gguf` artifact is. The refusal reason is that the artifact is not the primary, and it holds independently of the algorithm exclusion tested by AC-CAT-7.

AC-CAT-18 (`SPEC-023-R004`, one hash resolves to one pricing identity): An artifact feed in which the same `(hash_algorithm, hash)` pair appears under two different model keys emits `catalog_artifact_feed_integrity_failure` at consumption and is rejected by the generator before signing, and it does so whether or not the two model keys resolve to the same rate row — a duplicate pair under two keys carrying DIFFERENT rate rows is the case that must fail, and it fails as a feed-integrity error rather than by selecting either price. The same pair appearing twice under ONE model key, under two `artifact_id`s, fails identically. No artifact of a rejected feed reaches `catalog_matched`. In a conforming feed a verified `(hash_algorithm, hash)` resolves to exactly one `(model_key, artifact_id)`, and that resolved model key is the pricing identity: a provider-offered `catalog_model_key` naming any other key fails the match closed rather than overriding or selecting, and a provider-offered key equal to the resolved key changes nothing about the outcome (SPEC-047-R001/R003 as amended in 0.1.3). This check is asserted to run in ADDITION to the release generator's existing candidate-catalog conflicting-hash check, which rejects two different `model_sha256` values under one normalized `model_id`; neither check subsumes the other and a release fails closed on either.

AC-CAT-19 (`SPEC-023-R004`, `artifact_id` grammar and cross-release binding history): An `artifact_id` that does not match `^[a-z0-9][a-z0-9-]{0,63}$` in full — uppercase, an underscore, a leading hyphen or digit-free symbol, an empty string, or 65 characters — emits `catalog_artifact_feed_integrity_failure` at consumption and is rejected by the generator before signing. Cross-release: given the previous release's signed artifact feed and the release ledger as generator inputs, a release that reuses a `(model_key, artifact_id)` with a `(hash_algorithm, hash)` differing from that pair's last recorded binding fails closed at generation; a release that publishes NEW bytes under a NEW `artifact_id` while retiring the old id with `verification_status: "blocked"` succeeds; and a release that removes a `(model_key, artifact_id)` from one feed and reintroduces the same pair in a later feed bound to different bytes fails closed exactly as an in-place change does, so removal is not an escape hatch. **The concrete ledger wire shape is asserted, not merely its intent.** A release-ledger document serialized as `macprovider.autotune-release-ledger.v3` (§3.7.8) is validated field by field: an artifact-bound release row is the exact closed set `{generated_at, policy_version, feeds, artifact_bindings, intake_decision_sha256}`, and a row with an unknown key, a missing key, or a wrong-typed value is rejected. `artifact_bindings` is an array whose elements are the exact closed object `{model_key, artifact_id, hash_algorithm, hash}` of four strings, with `artifact_id` matching `^[a-z0-9][a-z0-9-]{0,63}$`, `hash_algorithm` from the §3.7.4 matrix, and `hash` lowercase 64-hex. Completeness, ordering, and uniqueness are each tested: a row omitting any `(model_key, artifact_id)` the feed publishes — including a `declared` or `blocked` artifact — or recording a pair the feed does not publish is rejected; elements out of ascending `model_key` then `artifact_id` UTF-8 byte order are rejected, and two conforming generators over one feed emit byte-identical `artifact_bindings`; a repeated `(model_key, artifact_id)` and a repeated `(hash_algorithm, hash)` are each rejected. `intake_decision_sha256` is a 64-hex digest or `null`, and a release that adds a `listed` row or promotes a row while recording `null` is rejected (§16.8). **Historical rows are invariant:** a v1 or v2 row keeps its exact `{generated_at, policy_version, feeds}` shape, is accepted unchanged by a v3 reader, is rejected if it gains `artifact_bindings` or `intake_decision_sha256`, and is never re-validated against the v3 row rules; conversely an artifact-bound row missing either key is rejected. **Activation is tested in both directions:** the first artifact-bound release is written into a v3-serialized ledger, a later release recorded without `artifact_bindings` or in a v2-serialized ledger is rejected as a downgrade, and the tombstone shape is unchanged across v2 and v3. The rebinding verdict is then reproducible by an auditor from this ledger plus the previous release's signed feed bytes alone, without re-running the generator that produced the release.

AC-CAT-20 (`SPEC-023-R004`, artifact evidence is snapshot-bound at settlement): For a request attempt whose SPEC-047-R003 trusted binding references a §3.7 artifact, the SPEC-022 route-time verification snapshot — or a separate immutable record the snapshot references by digest — carries all six of `artifact_feed_sha256`, `artifact_id`, the artifact `hash`, its `hash_algorithm`, `artifact_feed_signer_key_id`, and the candidate-catalog body digest of that release, and settlement re-verifies them against the snapshot rather than against any current feed. Four negative cases each fail closed at settlement — no buyer-final debit, no default paid routing, no positive provider settlement, no settlement ledger row: **missing** (the snapshot carries none of the six values for an artifact-derived binding, or its referenced record does not resolve to the digest the snapshot recorded); **changed** (any one of the six values differs from the snapshot's, the artifact `hash` included); **cross-release** (an `artifact_feed_sha256` or candidate-catalog body digest from a different release than the snapshot recorded, tested with an artifact `hash` that still matches, so the release binding and not the hash is what fails it); and **wrong-signer** (an `artifact_feed_signer_key_id` differing from the snapshot's, including a cryptographically valid signature by a different concurrently trusted key). An implementation that stores artifact evidence only in mutable admission state while persisting a candidate-only route snapshot fails this criterion. Settlement does not consult a current artifact feed, `release.json`, or keyring to repair evidence the snapshot lacks. **SPEC-022's minimum route-time snapshot field list is unchanged**: the extension is the SPEC-047-owned optional record SPEC-047-R003 defines, carried under the snapshot binding SPEC-022's receipt profile already requires, and this criterion asserts that no SPEC-022 amendment is needed for it.

AC-CAT-21 (`SPEC-023-R006`, intake decisions are reconstructible from the release record): A release that admits a key to `listed` or promotes a key to `recommendable` commits an `intake-decision.json` (§16.8, `schema_version: "macprovider.intake-decision.v1"`) whose lowercase 64-hex digest is recorded as `intake_decision_sha256` in that release's §3.7.8 ledger row; a release that changes a row's tier without a committed manifest, or whose ledger row records a digest that does not match the committed bytes, fails closed at generation. The manifest is closed at every level: an unknown key, a missing key, or a wrong-typed value at the top level, inside `thresholds`, inside a `decisions` element, or inside its `signals` object fails the release closed. `thresholds` contains every §16.4 knob at the value in force for the release, with no omissions and no additions. `decisions` contains exactly one entry per added or promoted key and none for any other key, each recording the evaluated signal values with the authenticated source snapshot digests they were read from, an absent signal as `null` with a closed `*_absent_reason`, the observation window bounds and `as_of` timestamp, the per-signal suppression state, the selected `admission_clause` and `fit_clause`, `coldstart_slot_used`, `listed_since` (non-null exactly for `promote_recommendable`), and the `operator_decision` and `operator_role`. A manifest that names a suppressed signal as its `admission_clause`, that sets `coldstart_slot_used` on more entries than `INTAKE_COLDSTART_SLOTS`, or whose observation window ends more than one §16.5 cadence period before `as_of` fails closed. The manifest carries no provider id, pseudonym, hardware fingerprint, buyer account, API key, IP address, raw principal identifier, or §16.2(a) item-7 principal token in any field, hashed or otherwise. Given the manifest, its ledger-recorded digest, and the release's signed feeds, an auditor re-evaluates the §16.3 rule for every changed key and reaches the same verdict without re-running the generator. The test set MUST also cover: an `admit_listed` entry with a `null` `openrouter_demand_rank`, `distinct_provider_offer_count`, and `fleet_fit_fraction_ppm` each carrying its own non-null `*_absent_reason` (accepted); the same entry with a `null` signal and a `null` `*_absent_reason` (fails closed); a non-null signal with a non-null `*_absent_reason` (fails closed); and one `promote_recommendable` entry with `signals`, `admission_clause`, and `fit_clause` `null` and a complete `promotion` object (accepted) versus the same entry carrying an `admission_clause` value or a `null` `promotion` (fails closed).

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

  (ii) **Network-connected PAID providers are `recommendable`-only.** The
  coordinator enforces `runtime_status == "recommendable"` for paid or default
  buyer routing; provisional rows are never a paid default and never
  buyer-routable for paid traffic. **[amended v0.10.0]** The scope of that
  prohibition now differs by tier, because §3.2 makes `listed` the cheap intake
  tier:

  - A `candidate` row and every `omlx_seeded` row — at any `runtime_status` —
    remain **local-only and never buyer-routable at all**: no paid routing, no
    default routing, no SPEC-047 sandbox probe, and no
    `network_visible_unpriced` visibility. The Stage-1 prohibition on promoting
    an `omlx_seeded` row is unchanged.
  - A `listed` row that is not `omlx_seeded` is prohibited from **paid and
    default buyer routing only**. It MAY reach SPEC-047 `sandbox_probe_only`
    and `network_visible_unpriced`, and it MAY be `catalog_matched` against a
    `verified` artifact, exactly as the §3.2 ladder and §16.3 state. It MUST
    NOT reach `catalog_priced` or `settlement_capable`, carries no earning
    claim, and is never selected as `recommended_model`.

  Nothing here relaxes the Stage-1 oMLX gate: `omlx_seeded` provenance keeps the
  stricter, local-only rule regardless of tier.

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

Q1a **[new v0.10.0, partially answering Q1]**: §16.2(a) introduces `unmatched_model_request_count`, an aggregated coordinator count of buyer requests for unknown model keys, specified here and owned by SPEC-017. It is an INTAKE input only — it admits a key to `listed`, and it never enters `raw_score`, `demand_weight`, or any recommendation or switch decision. The original question, whether a live coordinator demand endpoint should become a recommendation input under the history/volume/concentration bar above, remains OPEN and unchanged.

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

Q12 **[scoped v0.10.0]**: Whether minimum provider coverage targets should become an active recommendation input once provider-count telemetry exists. v0.10.0 uses aggregated provider-supply counts (§16.2(b)) as a catalog INTAKE floor only; they do not enter §4 scoring or §5 eligibility. The recommendation-input question remains OPEN.

Q13: Adaptive `N` for oMLX-seeded promotion. Replace fixed `N = 3` with a minimum and maximum of verified provider autotune runs. The promoted gate would still be recomputed solely from the verified sustained-TPS distribution (never from, nor tested against, the provisional oMLX seed — consistent with §12 and AC-OMLX-4); promotion would trigger once a one-sided ~95% lower confidence bound on the verified sustained-TPS distribution is high enough to set the recomputed `verified_provider_matrix` gate with confidence. If unmet after 7 runs, the row remains `listed`. (Like fixed `N`, this remains subject to the Stage-1 prohibition until the Stage-2 evidence-record mechanism exists.)

Q14 **[new v0.10.0, broadened]**: **SPEC-010 multi-artifact identity.** SPEC-010 is the sole authority for model identity, and it currently recognizes exactly one identity per catalog model key: SPEC-010-R001 defines `macprovider.snapshot-manifest.v1` as the `model_sha256` **of the exact signed candidate-catalog row**, and SPEC-010-R004 keeps that same row as session authority for later heartbeats and settlement snapshots. §3.7 gives a model key a SET of artifacts, so two distinct gaps open at once, and v0.10.0 closes both by restriction rather than by amending SPEC-010:

- **(a) Algorithm gap.** `macprovider.gguf-file.v1` is not a canonical wire pair named by SPEC-010-R002, so no `gguf` artifact can be a SPEC-010 `model_hash`/`model_hash_algorithm` pair.
- **(b) Non-primary-artifact gap.** Even an artifact using a SPEC-010-named algorithm is not the SPEC-010 identity unless its digest IS the candidate row's `model_sha256`. A **secondary `mlx_safetensors` quantization** has different bytes and therefore a different snapshot-manifest digest, so it fails SPEC-010-R001/R004 for the same structural reason a GGUF artifact does — the algorithm exclusion does not cover it, and naming a GGUF algorithm would not fix it.

v0.10.0 therefore restricts `catalog_priced` and `settlement_capable` to the **primary artifact only** (§3.7.4, §3.7.7 R004, AC-CAT-7, AC-CAT-17, SPEC-047-R003 as amended in 0.1.3), which makes this revision strictly consistent with SPEC-010 as it stands and requires no SPEC-010 amendment. Every non-primary artifact of every format reaches at most identity, discovery, `listed` intake, `sandbox_probe_only`, and `network_visible_unpriced`. The open question is whether SPEC-010 should be amended — naming a GGUF algorithm under R002 **and** recognizing a release-bound, `verified` artifact-feed entry as an expected identity under R001/R004 — so that non-primary artifacts can settle. That is a SPEC-010 decision, owned by the BYOM v0.2 epic's SPEC-010 slice, not a SPEC-023 or SPEC-047 one.

Q15 **[new v0.10.0]**: Reconciling the catalog rows that currently price away from their §3.3.1 class peers — `qwen2.5-coder-32b-instruct` against `qwen3-32b` within `class-32b`, and the three `class-30b-moe` rows against each other. §3.3.1 rule 8 keeps them as explicit model overrides so class expansion cannot silently reprice live money-path traffic. Whether to converge them onto class rates, and at which release, is an operator pricing decision that needs its own reviewed release.

Q16 **[new v0.10.0]**: Whether to mirror `rate_class` (and eventually artifact identity) into the candidate-catalog rows behind an activation gate mirroring §12.2, once every deployed candidate-catalog consumer accepts unknown row keys. That would collapse two feeds back into one at the cost of a fleet-wide forward-compat rollout; v0.10.0 takes the separate-feed path specifically to avoid that rollout.

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
| Artifact substitution **[v0.10.0]** | An operator error, a compromised authoring host, or a mutable upstream reference binds a model key to bytes that are not the intended model — a second artifact published under an existing `artifact_id`, a GGUF whose declared hash is not the digest of the served file, or a `declared` artifact promoted to `verified` without confirmation | §3.7.4 requires content-addressed immutable `source_ref`s (40-hex HF revision or an immutable Ollama digest), gives `artifact_id` a closed `^[a-z0-9][a-z0-9-]{0,63}$` grammar and forbids rebinding it to differing bytes — enforced against the previous release's signed feed and the release ledger's recorded `(model_key, artifact_id, hash_algorithm, hash)` bindings, so removal-and-reintroduction is not an escape hatch and an auditor can reproduce the verdict from named inputs; binds a `gguf` artifact's `source_ref.digest` to `"sha256:" + hash` so a source reference cannot name one blob while matching trusts another; makes a `(hash_algorithm, hash)` pair globally unique within one feed so identical bytes cannot present two pricing identities; and admits only `verified` artifacts to matching/pricing/settlement; §3.7.5 requires the primary artifact to be byte-identical in identity to the signed candidate row and checks it at generation AND consumption; §3.7.6 fails closed for every artifact-derived capability on integrity/update-required; §3.7.4's closed artifact-identity matrix forbids semantically inconsistent tuples (a `gguf` artifact declaring the MLX snapshot algorithm, an `mlx_safetensors` artifact allowing a loopback adapter) that would otherwise be individually schema-valid; SPEC-047-R003 still requires exact catalog-body digest plus artifact hash and algorithm before `catalog_priced`/`settlement_capable`; and §3.7.7 restricts `catalog_priced`/`settlement_capable` and the SPEC-010 wire pair to the PRIMARY artifact alone, so a substituted secondary artifact of any format — GGUF or a second MLX quantization — cannot reach settlement even if it is verified and correctly typed | Artifact transparency log and multi-party artifact attestation in a later revision |
| Class mis-declaration **[v0.10.0]** | A `rate_class` is assigned to the wrong class — by operator error or by an authoring-path compromise — so a model is published at another class's price, silently repricing live money-path traffic | §3.3.1 rule 1 closes the class enum in this SPEC so classes cannot be invented at authoring time; rule 5 makes an explicit model row always win, so no class edit can move a key that carries an override; rule 7 fails the release closed when a `recommendable` row resolves to no rate row; rule 8 requires the first class-expansion release to publish byte-identical rate-card `rows`, so the mechanism cannot itself be a repricing event; the published rate card is signed and release-bound (§3.3, §3.5), and §3.3.1 rule 6 keeps `rate_class` off the wire and out of the ledger entirely | Per-class price-change review gate and a rate-card diff attestation in the release runbook |
| Intake-signal gaming **[v0.10.0]** | A provider or buyer inflates an intake signal to force a model into the catalog — mass BYOM offers for one key, synthetic buyer requests for an unknown model key, or coordinated rank manipulation upstream | §16.2 counts distinct providers rather than offers, excludes sanctioned providers, caps each signal's contribution, and treats every signal as an admission FLOOR rather than a weight, so no amount of signal ranks a row above another; §16.3 admits only to `listed`, which is never a paid default and carries no earning claim, so a gamed intake buys discovery and probe eligibility, not revenue; §16.3 keeps `recommendable` behind the unchanged operator admission, `rate_class` assignment, and §5 gates, so no automated signal can promote a row; §16.1 requires a verified artifact before any intake, so a model with no real bytes cannot enter at all | Buyer-side abuse scoring on unmatched-model-key requests beyond the §16.2(a) per-principal cap, once SPEC-017 implements the signal |
| Unknown-model-key fanout **[v0.10.0]** | A buyer, a compromised integration, or an unauthenticated caller sends requests naming very many distinct or very long unknown model strings — to exhaust stats storage and rollup parser work, to bury a real signal under noise, or to walk one chosen key over `INTAKE_BUYER_REQUEST_FLOOR` from a single account | §16.2(a) makes the field contract normative in this SPEC rather than leaving it behind the §16.7 ownership boundary: only auth-valid non-test requests count; keys are bucketed only after `NormalizeModelKey` and only when they match the closed `[a-z0-9._/-]{1,128}` grammar; retention is a named fixed-memory Space-Saving summary of capacity `INTAKE_UNKNOWN_KEY_BUCKETS` (default 64) with deterministic eviction, so per-request work and total memory are constants rather than functions of distinct-key volume, and only its conservative lower-bound count may clear a floor; everything else collapses into one key-free `other_suppressed` bucket whose two counters saturate at stated caps and never clear a floor; principal accounting uses an opaque window-scoped HMAC token, bounded at `INTAKE_UNKNOWN_PRINCIPALS_PER_BUCKET` (default 64) tokens per bucket with overflow principals contributing only to `other_suppressed`, and the per-window key and every derived token are destroyed at window close; one principal contributes at most `INTAKE_UNKNOWN_KEY_PRINCIPAL_CAP_PCT` (default 10%) of the floor to one bucket per window, so clearing the floor needs at least ten independent principals; suppressed, overflow, capped, and upper-bound counts never satisfy the floor; §16.7 holds the signal absent for intake until SPEC-017 adopts the contract by amendment; and §16.3 admits only to `listed`, which pays nothing | Buyer-side abuse scoring and reputation-weighted principals once SPEC-017 implements the signal |

## 16. Catalog intake pipeline (v0.10.0)

§16 defines how a model key gets INTO the catalog, on what evidence, and on what cadence. Before this revision the answer was "the operator adds a row when the operator decides to," and each addition was a full signed release cut. The mechanism below does not automate that decision — it makes the inputs to it explicit, bounded, and auditable, and it gives the operator a cheap tier (`listed`) that admits identity without committing to price.

**Non-goal, restated.** This is not an open marketplace. Providers do not set prices, do not admit models, and do not gain an earning path by supplying a signal. Non-catalog models remain non-earning exactly as SPEC-047 §1 and SPEC-047-R004 require: a genuinely novel non-catalog model has no earning path in v0.1, and only a later billing-owner pricing-conversion spec can change that. §16 widens *which models the operator can cheaply admit as catalog identities*; it does not widen *who decides*.

### 16.1 Intake preconditions

No model key may enter `listed` — and therefore, transitively, `recommendable` — unless all of the following hold. These are preconditions, not signals; no amount of demand or supply substitutes for them. They are **not** preconditions for authoring a `candidate` staging row (§3.2): a `candidate` row is network-invisible, reaches no SPEC-047 admission tier, and is governed by the §3.2 row-identity rules and the §3.7.4 identity-correspondence rule alone.

- **P1 — Verified artifact.** At least one artifact for the key has `verification_status == "verified"` in the §3.7 artifact feed, with an immutable content-addressed `source_ref` and a hash under a §3.7.4 algorithm. This is a precondition for **entering `listed`**. It is not a precondition for authoring a `candidate` row, whose artifact entries MAY all be `declared` (§3.2, §3.7.4).
- **P2 — Runtime support.** The current CLI release can load at least one verified artifact of the key through an `allowed_runtime_sources` adapter that SPEC-046-R002 permits.
- **P3 — Licensing and safety.** The operator has recorded that the model's licence permits paid third-party serving, and the key is not `blocked`.
- **P4 — Identity hygiene.** The normalized model key does not collide with, shadow, or normalize onto an existing catalog key under SPEC-005 §5.5 `NormalizeModelKey`, and the release generator's existing shadowing and conflicting-hash checks pass. The §3.7.4 **global artifact-hash uniqueness** invariant also holds: no `(hash_algorithm, hash)` this key publishes appears under any other model key of the same artifact feed. That is a NEW generator check and is distinct from the existing candidate-catalog conflicting-hash check, which only rejects two different `model_sha256` values under one normalized `model_id`.

### 16.2 Intake signals

Three signals feed the intake decision. Each is an aggregate; none carries provider or buyer identity, and none is a score that ranks rows against each other.

**(a) Buyer demand.**

- `openrouter_demand_rank` — the existing §3.4 operator-curated OpenRouter completion-token rank for the key, or `null` when the key is unranked. This is an EXTERNAL prior: it measures buyer demand in the wider market, not macprovider's own served traffic, which is what makes it usable for a key macprovider has never served.
- `unmatched_model_request_count` — **a new signal, specified here and to be implemented under SPEC-017 authority.** It is the count of buyer requests whose requested model string resolved to no admitted catalog key, aggregated per normalized requested model key over the SPEC-017 rollup window. Until SPEC-017 implements it, this signal is simply absent and the intake rule falls through to its other terms; its absence MUST NOT block intake.

**`unmatched_model_request_count` field contract (normative).** The requested model string is buyer-controlled, so an unbounded key space would let any caller mint arbitrarily many rollup buckets — both a storage-and-parser pressure surface and an intake-gaming surface. The safety invariants therefore travel WITH the field rather than staying behind the §16.7 ownership boundary. SPEC-017 owns the wire shape, the endpoint, the rollup window, and the k-anonymity floor value; SPEC-017 MUST adopt this exact contract by amendment before the signal may satisfy any intake floor, and until that amendment lands the signal MUST be treated as absent for intake purposes (§16.7). An implementation MUST satisfy all of:

1. **Eligible requests only.** The counter counts only auth-valid, non-test buyer requests: a request that fails authentication, is rejected before model resolution, or is flagged as test/synthetic/internal traffic MUST NOT contribute to any bucket.
2. **Normalization before bucketing.** The requested model string is normalized with SPEC-005 §5.5 `NormalizeModelKey` BEFORE any bucket is created or incremented. Buckets are keyed by the normalized key; the raw buyer-supplied string is never a bucket key and is never persisted.
3. **Closed key grammar and byte limit.** A normalized key is eligible for its own bucket only when it matches the closed grammar `[a-z0-9._/-]{1,128}` in full. A request whose normalized key exceeds 128 bytes, or contains any byte outside that set, MUST NOT create or increment a named bucket; it is counted only in `other_suppressed` (item 6).
4. **Bounded retention: a named fixed-memory heavy-hitter algorithm.** Named buckets MUST be produced by the **Space-Saving** stream-summary algorithm (Metwally, Agrawal, El Abbadi) with capacity `INTAKE_UNKNOWN_KEY_BUCKETS` — default `64`, operator-configured. The summary holds at most that many entries; each entry carries a monitored normalized key, a `count`, and an `error` (the count it may have inherited from an evicted key). On an **intake-eligible contribution** — a request that has passed steps S1 through S4 of the per-request processing order stated after item 10, which is the only point at which this update runs:
   - if the key is already monitored, that entry's `count` increments by one;
   - else if the summary holds fewer than `INTAKE_UNKNOWN_KEY_BUCKETS` entries, a new entry is created with `count = 1` and `error = 0`;
   - else the **victim** entry is evicted and its key replaced by the new key, with `count = victim_count + 1` and `error = victim_count`. The victim is the entry with the smallest `count`; ties are broken by the largest `error`, then by monitored key ascending. This replacement rule is deterministic and normative, so two conforming implementations fed the same request order produce the same summary.

   Total memory and per-request work are therefore bounded by `INTAKE_UNKNOWN_KEY_BUCKETS` and are independent of distinct-key volume. The bound is enforced at ingest, not at emission: an implementation MUST NOT materialise unbounded distinct keys and then trim.
5. **Only a conservative LOWER BOUND may clear a floor.** An entry's conservative lower-bound count is `count - error`. **That value, and only that value, MAY satisfy `INTAKE_BUYER_REQUEST_FLOOR`.** The `count` field is an upper bound and MUST NOT satisfy any floor. The emitted signal MUST carry the lower-bound count for each retained bucket and MAY additionally carry `count` and `error` as diagnostics; emission order is by lower-bound count, highest first, ties broken by key ascending. This SPEC makes **no** claim that the retained set is the exact highest-count `INTAKE_UNKNOWN_KEY_BUCKETS` keys of the stream. It is the Space-Saving monitored set, whose two relevant guarantees are that any key whose true count exceeds `window_eligible_request_total / INTAKE_UNKNOWN_KEY_BUCKETS` is monitored, and that a monitored key's lower bound never exceeds its true count. Intake is a floor test and never an ordering (§16.3, §16.6), so an approximate set with a never-over-counting lower bound is exactly sufficient — and it is the reason a bounded exact top-N, which is not implementable in bounded state, is not required.
6. **Single overflow bucket, saturating counters.** One `other_suppressed` bucket exists per window. It absorbs every eligible request whose key is ineligible under item 3, the **non-inherited** part of every count evicted from the summary under item 4 — `victim_count - victim_error`, because a victim's inherited `error` was already absorbed here when the entry it was inherited from was evicted and MUST NOT be added a second time — and every contribution discarded under items 7 and 8. The bucket is a **closed object carrying exactly these four fields and no other**, and it never carries key material:

   ```json
   {
     "request_count": 0,
     "request_count_saturated": false,
     "distinct_key_count": 0,
     "distinct_key_count_saturated": false
   }
   ```

   `request_count` and `distinct_key_count` are non-negative integers; `request_count_saturated` and `distinct_key_count_saturated` are booleans, `false` by default. Both counters are **saturated counters**: `request_count` saturates at `2^53 - 1`, and `distinct_key_count` saturates at `INTAKE_UNKNOWN_KEY_DISTINCT_CAP` (default `10000`); on reaching its cap a counter stops incrementing and its OWN flag is set `true`. The flags are **per counter, never a single shared `saturated` field**, so a reader can tell which counter saturated; an emitted bucket carrying a bare `saturated` key, an unknown key, a missing key, or a wrong-typed value is a malformed intake record. `distinct_key_count` is a **key-churn indicator** — one increment per summary eviction plus one per ineligible-key request — not an exact distinct-key cardinality; no cardinality sketch is required, and no exact distinct-key count is promised anywhere in this contract. `other_suppressed` MUST NOT satisfy `INTAKE_BUYER_REQUEST_FLOOR` or any other floor under any circumstances, saturated or not.
7. **Per-principal contribution cap, accounted by an opaque window-scoped token.** Within one retained bucket and one rollup window, a single principal — buyer account, partner key, or source class — contributes at most `INTAKE_UNKNOWN_KEY_PRINCIPAL_CAP_PCT` of `INTAKE_BUYER_REQUEST_FLOOR` (default `10%`, i.e. 25 requests at the default floor of 250). Contribution beyond the cap is discarded for intake purposes and is added to `other_suppressed.request_count`. Principal accounting MUST use an **opaque, window-scoped, keyed token** and never a principal identifier: `principal_token = HMAC-SHA-256(window_key, "macprovider.intake.unknown_model_principal.v1" || principal_identifier)`, truncated to 16 bytes, where `window_key` is a cryptographically random per-window key generated at window open, held only in private aggregator memory, never persisted, never emitted, and **destroyed at window close together with every token derived from it**. Tokens are therefore not comparable across windows by construction, and a token is not reversible to the principal.
8. **Bounded principal cardinality.** At most `INTAKE_UNKNOWN_PRINCIPALS_PER_BUCKET` distinct principal tokens — default `64`, operator-configured — are tracked per retained bucket per window, each with one small counter. A principal whose token is not already tracked when a bucket is at that limit is an **overflow principal**: its requests contribute only to `other_suppressed.request_count`, never to that bucket's count, and therefore can never satisfy a floor. Total principal-accounting state is bounded by `INTAKE_UNKNOWN_KEY_BUCKETS * INTAKE_UNKNOWN_PRINCIPALS_PER_BUCKET` counters and per-request principal work is one HMAC plus one bounded lookup, both independent of distinct-principal volume. When a bucket is evicted under item 4, its principal table is destroyed with it.
9. **Suppression, and what may never clear a floor.** A bucket whose post-cap lower-bound count is below the **effective k-anonymity floor** — `INTAKE_K_ANONYMITY_MIN` (§16.4, default `3`), or a higher value SPEC-017 selects — is reported as suppressed rather than as a small number, exactly as `distinct_provider_offer_count` is in §16.2(b). `INTAKE_BUYER_REQUEST_FLOOR` may be satisfied ONLY by a retained bucket's post-cap, post-suppression **lower-bound** count. `other_suppressed` MUST NOT satisfy it, a suppressed bucket MUST NOT satisfy it, an upper-bound `count` MUST NOT satisfy it, discarded over-cap contributions MUST NOT be added back for the comparison, and overflow-principal contributions MUST NOT be added back either. A key that would clear the floor only because one principal exceeded its cap, or only on its upper-bound count, has not cleared it.
10. **No identity, no rows, no tokens on the wire; raw principals are TRANSIENT.** Aggregated counts only: no buyer account, API key, IP address, prompt, or completion content, and no per-request rows, at any stage — ingest, storage, rollup, or emission. The item-7 cap is a counting rule, not a retention licence. **Neither a raw principal identifier NOR an item-7 opaque token may appear in an emitted or retained intake record**, in any field, hashed or otherwise.

    The raw principal identifier is further bounded in TIME, not only in reach. A raw principal identifier MAY be read transiently ONLY while deriving `principal_token` at step S4 of the processing order below. It MUST be discarded before any intake-state mutation — before the item-8 principal-table lookup or insert, before the item-7 cap comparison mutates a counter, and before any item-4 Space-Saving update — and it MUST NOT be stored in a bucket, a counter table, a principal table, a log line, a trace span, a metric label, a diagnostic dump, a crash artifact, or any other aggregator state. Only `principal_token` and its one bounded counter may persist for the rollup window, and both are destroyed at window close along with `window_key`. The aggregator therefore holds no linkable identity between two requests of one principal, and a process-memory or diagnostic-dump compromise taken at any moment after S4 yields tokens that are not reversible to a principal and not comparable across windows (AC-CAT-13).

    The `other_suppressed` bucket's exact closed four-field shape is item 6's; no intake record may carry a fifth field there, and no per-principal breakdown is emitted or retained anywhere.

**Per-request processing order (normative).** The items above are constraints, not a sequence, so the order in which they apply is stated here and is binding. For each buyer request, an implementation MUST perform exactly these steps, in this order, and MUST NOT reach a later step when an earlier one has already routed the request:

- **S1 — Eligibility and authentication filter (item 1).** A request that fails authentication, is rejected before model resolution, or is flagged test/synthetic/internal contributes to NOTHING — not to a named bucket, and not to `other_suppressed`. It leaves the pipeline here.
- **S2 — Normalization (item 2).** Apply SPEC-005 §5.5 `NormalizeModelKey` to the requested model string. The raw string is never a bucket key and is never persisted.
- **S3 — Grammar and byte-limit check (item 3).** If the normalized key does not match `[a-z0-9._/-]{1,128}` in full, the request contributes to `other_suppressed` (item 6) ONLY. It creates and increments no named bucket, and the pipeline stops here for that request.
- **S4 — Principal derivation and cap check (items 7 and 8).** Derive the opaque window-scoped `principal_token` (item 7). The raw principal identifier is read ONLY for that derivation and MUST be discarded the moment the token exists — before the item-8 lookup below, before any counter is compared or incremented, and before any state this step or S5 mutates (item 10). No later step of this order, and no state any step of it writes, may hold or re-read the raw identifier. Check the per-bucket principal bound (item 8) and the per-principal contribution cap (item 7) for the bucket this key would target. An overflow-principal contribution, and any contribution beyond the cap, is added to `other_suppressed.request_count` (item 6) ONLY. Such a contribution **MUST NOT** reach step S5: it never increments a named entry's `count`, never affects that entry's `count - error` lower bound, and therefore can never move a bucket toward `INTAKE_BUYER_REQUEST_FLOOR`. The pipeline stops here for that request.
- **S5 — Space-Saving update (item 4).** Only a contribution that survived S1 through S4 is intake-eligible. Apply the item-4 Space-Saving update — increment, insert, or evict-and-replace — for that contribution, and increment the corresponding principal counter under item 8. Any eviction the update causes transfers `victim_count - victim_error` into `other_suppressed` under item 6.

The cap and bound are therefore an admission filter ahead of the summary, never a post-hoc adjustment of it. An implementation that increments a named entry first and subtracts capped traffic afterwards does not conform: the item-5 lower bound would then have counted traffic the floor rules forbid, and AC-CAT-13's single-principal invariant would not hold.

**(b) Provider supply.**

- `distinct_provider_offer_count` — the number of DISTINCT providers whose SPEC-047 admission events record an offer naming this catalog key or a served model reference that matches one of its verified artifacts, over the trailing 30 days. Derived from coordinator admission events, aggregated only: no provider id, pseudonym, hardware fingerprint, or per-provider row may appear in the intake record. Offers from providers under an active route, trust, payout, or registration sanction MUST be excluded (SPEC-047-R007). The count MUST be reported as **suppressed** below the effective k-anonymity floor — `INTAKE_K_ANONYMITY_MIN` (§16.4, default `3`) — so a two-provider interest cannot be read back as an identification of those providers. `INTAKE_K_ANONYMITY_MIN` is **owned by SPEC-023**, not borrowed from SPEC-017: it is the minimum that applies to BOTH this signal and the §16.2(a) `unmatched_model_request_count` signal. SPEC-017 MAY select a HIGHER floor for the signal it owns and MUST NOT select a lower one (§16.7); it never lowers the floor applied here.
- **A suppressed provider count satisfies nothing.** `INTAKE_OFFER_FLOOR` may be satisfied only by an UNSUPPRESSED `distinct_provider_offer_count`. A suppressed count MUST NOT be treated as "at least k", MUST NOT be unsuppressed for the comparison, and MUST NOT satisfy the offer floor under any circumstances. `INTAKE_OFFER_FLOOR >= INTAKE_K_ANONYMITY_MIN` MUST hold in every configuration; a release whose configured offer floor is below the effective k-anonymity floor fails closed at generation, because such a configuration would make the floor satisfiable only by counts the privacy rule forbids reporting.
- **This signal is available NOW.** `distinct_provider_offer_count` is derived from coordinator-owned SPEC-047 admission events, which are coordinator admission data and not a SPEC-017 stats field. It is therefore NOT gated on the SPEC-017 amendment that §16.7 requires before `unmatched_model_request_count` may satisfy any floor: provider-supply intake is usable in the first release that implements §16, with the SPEC-023-owned `INTAKE_K_ANONYMITY_MIN` as its suppression floor.

**(c) Hardware fit.**

- `fleet_fit_fraction(artifact)` — the fraction of providers active in the trailing 30 days whose reported `ram_gb` satisfies the §5 headroom rule for that artifact: `artifact.min_ram_gb <= ram_gb - safety_margin_gb`, with `safety_margin_gb = 4`. Computed per artifact, because §3.7.4 makes `min_ram_gb` per-artifact. A key's fit is the maximum over its verified artifacts.
- `tier_target` — the operator's named hardware-tier target for the release, an explicit statement of which part of the fleet the release is trying to serve. Its default is stated in §16.4.

### 16.3 The intake rule

**SPEC-023-R006:** Catalog intake MUST follow this rule. Its thresholds are operator-tunable release policy; the rule's shape, its preconditions, and its tier boundary are normative.

**Admission to `listed`.** A model key MAY be admitted as `listed` in a release when P1-P4 hold AND at least one of the following demand-or-supply terms is satisfied:

- `openrouter_demand_rank != null AND openrouter_demand_rank <= INTAKE_DEMAND_RANK_MAX`; or
- `distinct_provider_offer_count >= INTAKE_OFFER_FLOOR`; or
- `unmatched_model_request_count >= INTAKE_BUYER_REQUEST_FLOOR`;

AND at least one of the following fit terms is satisfied:

- `fleet_fit_fraction >= INTAKE_FLEET_FIT_MIN_PCT`; or
- the key's best-fitting verified artifact fits the release's declared `tier_target`.

`listed` grants exactly what §3.2's ladder table says it grants: discovery, SPEC-047 `catalog_matched` identity against a verified artifact hash, `sandbox_probe_only` and `network_visible_unpriced` admission, and nothing that pays. **No `rate_class` and no rate-card row is required to be `listed`.** This is the point of the tier: identity is cheap, price is a commitment.

**Promotion to `recommendable`.** A `listed` key MAY be promoted only when all of:

- it has been `listed` for at least `INTAKE_MIN_LISTED_DAYS`;
- it declares a §3.3.1 `rate_class` that resolves, by explicit row or class expansion, to a published rate-card row (§3.3.1 rule 7);
- its demand-rank row carries `recommendable: true` (§3.4, §5);
- the §3.2 bench-provenance rules and the §5 eligibility gates are satisfied unchanged — in particular an `omlx_seeded` row MUST NOT be promoted, and the §12 Stage-2 promotion automation remains defined-but-deferred and is NOT activated by this revision;
- the operator explicitly admits it. **Promotion is an operator decision. No combination of §16.2 signals promotes a row automatically.**

**Demotion and blocking.** The operator MAY demote `recommendable` to `listed`, or move any row to `blocked`, at any time and for any reason, without satisfying any threshold. Withdrawal is always cheaper than admission.

### 16.4 Thresholds and defaults

| Knob | Default | Rationale |
|---|---:|---|
| `INTAKE_DEMAND_RANK_MAX` | `100` | An external-market rank floor generous enough to admit real buyer demand for models macprovider has never served (FM-2), narrow enough to exclude the long tail. Rank is a floor, never a weight. |
| `INTAKE_OFFER_FLOOR` | `3` | Three DISTINCT providers independently offering the same key is real supply-side signal and is at or above the effective k-anonymity floor. One or two providers is an anecdote and is reported as suppressed. `INTAKE_OFFER_FLOOR >= INTAKE_K_ANONYMITY_MIN` MUST hold; a configuration below it fails the release closed (§16.2(b)). |
| `INTAKE_K_ANONYMITY_MIN` | `3` | The SPEC-023-owned MINIMUM k-anonymity floor, applying to BOTH `distinct_provider_offer_count` (§16.2(b)) and the SPEC-017-owned `unmatched_model_request_count` (§16.2(a) item 9). An aggregate below it is reported as suppressed rather than as a small number, and a suppressed aggregate satisfies no floor. Three is the smallest value at which an aggregate cannot be read back as "this one provider" or "these two providers", and it is the floor the intake rule's own `INTAKE_OFFER_FLOOR` default already assumes. SPEC-017 MAY require a higher floor for the signal it owns and MUST NOT require a lower one (§16.7); no SPEC-017 amendment is needed for this default to apply to provider-offer intake. |
| `INTAKE_BUYER_REQUEST_FLOOR` | `250` | Roughly 0.2% of the trailing-30-day paid request volume at the time of this revision (~130k requests). Low enough to notice a real unserved model, high enough that incidental typos and single-integration probing do not clear it. |
| `INTAKE_UNKNOWN_KEY_BUCKETS` | `64` | Space-Saving summary capacity: the number of named unknown-model-key buckets retained per rollup window (§16.2(a) item 4). The requested model string is buyer-controlled, so the bucket count must be a constant rather than a function of traffic. 64 is far more than the number of models a monthly intake review can consider, and it sets the algorithm's guarantee: any key exceeding 1/64 of the window's eligible request volume is monitored. Everything else collapses into `other_suppressed`. |
| `INTAKE_UNKNOWN_PRINCIPALS_PER_BUCKET` | `64` | Distinct principal tokens tracked per retained bucket per window (§16.2(a) item 8). Bounds principal-fanout state at `INTAKE_UNKNOWN_KEY_BUCKETS * INTAKE_UNKNOWN_PRINCIPALS_PER_BUCKET` = 4096 counters in the default configuration, independent of how many principals a caller can mint. At the default cap of 25 requests per principal, 64 tracked principals is more than twice the ten independent principals the floor already requires, so the bound cannot silently suppress a genuine multi-buyer signal. |
| `INTAKE_UNKNOWN_KEY_DISTINCT_CAP` | `10000` | Saturation point for `other_suppressed.distinct_key_count` (§16.2(a) item 6). The counter is a key-churn indicator, never a floor input, so it needs an upper stop rather than accuracy; saturating flags "fanout is happening" without a cardinality sketch and without unbounded state. |
| `INTAKE_UNKNOWN_KEY_PRINCIPAL_CAP_PCT` | `10%` | Maximum share of `INTAKE_BUYER_REQUEST_FLOOR` that one principal — buyer account, partner key, or source class — may contribute to one bucket in one window (§16.2(a) item 7, applied at step S4 of the §16.2(a) processing order); 25 requests at the default floor. Clearing the floor therefore requires at least ten independent principals, which makes a single integration's traffic — accidental or deliberate — structurally unable to admit a key. |
| `INTAKE_FLEET_FIT_MIN_PCT` | `25%` | A key must be servable by a meaningful minority of the active fleet, or it is a catalog row nobody can fill. |
| `tier_target` | `<= 16 GB` | The live fleet is dominated by 8-16 GB Macs (13 of 24 observed hardware profiles), while only 3 catalog rows fit at or under 16 GB. The default target is therefore the under-covered small-RAM tier until that is no longer true. |
| `INTAKE_COLDSTART_SLOTS` | `1` | Per release, the operator MAY admit up to this many new `listed` rows on P1-P4 plus the fit term alone, with no demand-or-supply term, when the declared `tier_target` is under-covered. The slot is a **discretionary permission, not a reservation**: it permits an admission the demand-or-supply disjunction would otherwise refuse; it never obliges the operator to admit anything, and an unused slot does not accumulate. This is the explicit cold-start escape hatch (FM-2). |
| `INTAKE_MIN_LISTED_DAYS` | `30` | One release cycle of `listed` observation before a key can carry a price. |

Every threshold above is release policy the operator may change; each change MUST be recorded in the release notes for the release that applies it. Release notes alone do not make an intake decision reconstructible, because the decision also depends on the signal VALUES it was taken against; §16.8 defines the release-bound record that carries those values, and reconstructibility is claimed there and only there.

### 16.5 Cadence

Catalog releases that ADD or PROMOTE rows run on a **fixed monthly cadence**. Batching intake into one dated release keeps the expensive part of a catalog change — the signed release cut, the fixture churn documented in the release runbook, the fleet-wide feed rollout — to a predictable twelve times a year instead of once per model.

**Out-of-band releases are permitted only for `blocked` transitions** — withdrawing a row for safety, licensing, runtime breakage, or economics. An out-of-band release MUST NOT add a new row, promote a row, change a `rate_class`, or change a published rate. Withdrawal must never wait for a cadence; admission must never jump one.

### 16.6 Goodhart mitigations for intake

`RESEARCH_229` names the two failure modes an intake signal is most likely to reproduce. Both are addressed structurally, not by tuning.

**FM-1 — winner-take-all herding on rank.** The memo's scenario is that a strong rank signal collapses every provider's recommendation onto one row and destroys catalog coverage. Intake cannot reproduce it, because every §16.2 signal is a **floor, not a weight**: a key either clears `INTAKE_DEMAND_RANK_MAX` or it does not, and clearing it by a wide margin buys nothing extra. Intake produces a SET of admitted keys, never an ordering, and it never touches §4's `raw_score`. The existing M3 cold-start floor and M4 lifecycle-state mitigations are unchanged. Most importantly, intake admits to `listed`, and a `listed` row is never a paid default — so even a fully gamed intake signal cannot herd a single provider's recommendation, let alone the fleet's. The one place rank could still herd is promotion to `recommendable`, and that is gated on an explicit operator decision (§16.3) rather than on any threshold.

**FM-2 — cold-start exclusion for new rows.** The memo's scenario is a demand signal defined as macprovider's own served traffic, which is structurally zero for any model the fleet cannot yet serve, so the row is never installed, never served, and never demanded — a self-fulfilling exclusion. Four properties of §16 break that loop:

1. The primary demand term is `openrouter_demand_rank`, an EXTERNAL market prior. A model macprovider has never served can clear it on day one.
2. `unmatched_model_request_count` counts requests the fleet **could not** serve. It is the inverse of a served-traffic metric: it goes UP precisely for the models the cold-start loop would otherwise silence.
3. The demand-or-supply terms are a disjunction, so provider-side interest alone (`distinct_provider_offer_count`) can admit a key with no buyer history at all — which is exactly how a BYOM candidate becomes a catalog identity.
4. `INTAKE_COLDSTART_SLOTS` **permits** up to one `listed` admission per release on hardware-fit and verified-artifact evidence alone, so an under-covered hardware tier can be filled with no demand evidence whatsoever. It is a discretionary operator permission and not a reserved slot (§16.4): the cold-start loop is broken by the fact that a route exists at all, not by an obligation to use it every release.

The `listed` tier is itself the deepest mitigation for both modes: it lets a model accumulate real evidence — providers offering it, buyers requesting it, probes exercising it — while it is visible and matchable but not yet priced. That is the observation window the cold-start loop previously had no way to open.

### 16.7 Ownership boundary

§16 is catalog-admission policy owned by SPEC-023. It does not create a routing rule (SPEC-002), a billing rule (SPEC-005), an admission state (SPEC-047-R001), a receipt or settlement rule (SPEC-022), or a buyer-visibility rule (SPEC-006, SPEC-047-R005). The `unmatched_model_request_count` signal is specified here but is OWNED by SPEC-017: its wire shape, redaction, k-anonymity floor value, rollup window, and endpoint are that SPEC's to define, and this section is the contract that implementation must satisfy.

That ownership split does not send the field's safety invariants away with it. The §16.2(a) field contract — eligible-request filtering, `NormalizeModelKey` normalization before bucketing, the closed `[a-z0-9._/-]{1,128}` key grammar, the named Space-Saving summary at capacity `INTAKE_UNKNOWN_KEY_BUCKETS` with its deterministic eviction and its conservative-lower-bound floor semantics, the single `other_suppressed` overflow bucket in its exact closed four-field shape `{request_count, request_count_saturated, distinct_key_count, distinct_key_count_saturated}` with per-counter saturation flags (item 6), the `INTAKE_UNKNOWN_KEY_PRINCIPAL_CAP_PCT` per-principal cap accounted through an opaque window-scoped token bounded at `INTAKE_UNKNOWN_PRINCIPALS_PER_BUCKET`, the transient-only handling of the raw principal identifier and the destruction of that token key at window close (item 10), suppression at or above `INTAKE_K_ANONYMITY_MIN`, and the rule that suppressed, overflow, capped, and upper-bound counts never satisfy `INTAKE_BUYER_REQUEST_FLOOR` — is normative HERE, because it is what makes the signal safe to admit a catalog identity on. **SPEC-017 MUST adopt that exact contract by amendment before `unmatched_model_request_count` may satisfy any intake floor.** Until that amendment lands, the signal is absent for intake purposes even if some implementation emits a field of that name, and the intake rule falls through to its other demand-or-supply terms. SPEC-017 remains free to specify a stricter bound, a lower cap, or a higher k-anonymity floor; it may not specify a weaker one, and in particular it may not specify a k-anonymity floor below `INTAKE_K_ANONYMITY_MIN` (§16.4), which is SPEC-023's own minimum and is not delegated. That ownership split covers `unmatched_model_request_count` ONLY: `distinct_provider_offer_count` (§16.2(b)) is coordinator-owned SPEC-047 admission data, is not a SPEC-017 stats field, and is therefore usable for intake without waiting for any SPEC-017 amendment.

### 16.8 Intake decision record (release-bound)

Recording the §16.4 thresholds in release notes says what the rule WAS; it does not say what the rule was applied TO. An intake decision also depends on the evaluated signal values, the window they were measured over, whether a signal was suppressed, which admission clause was selected, and whether a cold-start slot was used. Those are the inputs an auditor needs to re-run the §16.3 rule and reach the same verdict, and none of them survives in release notes. §16.8 defines the record that carries them.

**The `intake-decision` manifest.** A release that admits any key to `listed` or promotes any key to `recommendable` MUST commit an `intake-decision.json` with the release inputs, and MUST record its lowercase 64-hex digest as `intake_decision_sha256` in that release's §3.7.8 ledger row. It is authoring and audit evidence, not a served feed: like `rate-card-source.json` (§3.3.1 rule 3) it is **never served, never baked into a CLI release payload, and never bound in `release.json`**, so it adds no feed name to any exact-set check. Its authority is the ledger digest.

The manifest is a **closed schema at every level**. An unknown key, a missing key, or a wrong-typed value MUST fail the release closed before signing, exactly as an invalid feed does.

```json
{
  "schema_version": "macprovider.intake-decision.v1",
  "release_id": "published-2026-09-02-gpt-oss-120b-v1",
  "generated_at": "RFC3339 timestamp",
  "thresholds": {
    "INTAKE_DEMAND_RANK_MAX": 100,
    "INTAKE_OFFER_FLOOR": 3,
    "INTAKE_BUYER_REQUEST_FLOOR": 250,
    "INTAKE_UNKNOWN_KEY_BUCKETS": 64,
    "INTAKE_UNKNOWN_PRINCIPALS_PER_BUCKET": 64,
    "INTAKE_UNKNOWN_KEY_DISTINCT_CAP": 10000,
    "INTAKE_UNKNOWN_KEY_PRINCIPAL_CAP_PCT": 10,
    "INTAKE_K_ANONYMITY_MIN": 3,
    "INTAKE_FLEET_FIT_MIN_PCT": 25,
    "INTAKE_COLDSTART_SLOTS": 1,
    "INTAKE_MIN_LISTED_DAYS": 30,
    "tier_target": "<= 16 GB"
  },
  "decisions": [
    {
      "model_key": "<normalized model key>",
      "action": "admit_listed",
      "observation_window_start": "RFC3339 timestamp",
      "observation_window_end": "RFC3339 timestamp",
      "as_of": "RFC3339 timestamp",
      "signals": {
        "openrouter_demand_rank": 42,
        "demand_rank_absent_reason": null,
        "demand_rank_source_sha256": "<64-hex digest of the signed demand-rank feed bytes>",
        "distinct_provider_offer_count": 4,
        "distinct_provider_offer_suppressed": false,
        "distinct_provider_offer_absent_reason": null,
        "distinct_provider_offer_source_sha256": "<64-hex digest of the authenticated admission-event snapshot>",
        "unmatched_model_request_count": null,
        "unmatched_model_request_suppressed": false,
        "unmatched_model_request_absent_reason": "spec017_amendment_not_landed",
        "unmatched_model_request_source_sha256": null,
        "fleet_fit_fraction_ppm": 312000,
        "fleet_fit_absent_reason": null,
        "fleet_fit_source_sha256": "<64-hex digest of the authenticated fleet snapshot>"
      },
      "admission_clause": "provider_offer",
      "fit_clause": "fleet_fit",
      "coldstart_slot_used": false,
      "listed_since": null,
      "promotion": null,
      "operator_decision": "admitted",
      "operator_role": "<operator role identifier>"
    },
    {
      "model_key": "<normalized model key>",
      "action": "promote_recommendable",
      "observation_window_start": "RFC3339 timestamp",
      "observation_window_end": "RFC3339 timestamp",
      "as_of": "RFC3339 timestamp",
      "signals": null,
      "admission_clause": null,
      "fit_clause": null,
      "coldstart_slot_used": false,
      "listed_since": "RFC3339 timestamp",
      "promotion": {
        "listed_days_elapsed": 41,
        "rate_class": "class-8b",
        "rate_row_resolved": true,
        "rate_card_source_sha256": "<64-hex digest of the rate-card-source.json bytes>",
        "demand_rank_recommendable": true,
        "demand_rank_source_sha256": "<64-hex digest of the signed demand-rank feed bytes>",
        "bench_provenance_source": "measured_single_host",
        "operator_admission_reference": "<release-notes anchor or ticket id, no identity>"
      },
      "operator_decision": "promoted",
      "operator_role": "<operator role identifier>"
    }
  ]
}
```

**Field rules (normative).**

1. **One entry per changed key.** `decisions` MUST contain exactly one element for every key the release adds as `listed` or promotes to `recommendable`, and no element for any other key. `action` is the closed enum `admit_listed` | `promote_recommendable`. A release that changes a row's tier without a matching entry fails closed at generation. Demotions and `blocked` transitions need no entry: withdrawal satisfies no threshold and is always cheaper than admission (§16.3).
2. **Evaluated values or authenticated digests, never both absent.** Each signal is recorded as the VALUE the decision was taken against, together with the digest of the authenticated snapshot that value was read from. Every signal has its own `*_absent_reason` field, present in every `admit_listed` entry: `demand_rank_absent_reason` (closed enum `unranked`), `distinct_provider_offer_absent_reason` (`suppressed` | `no_observations`), `unmatched_model_request_absent_reason` (`spec017_amendment_not_landed` | `suppressed` | `no_observations`), and `fleet_fit_absent_reason` (`no_observations`). A signal that was not available is recorded as `null` with its `*_absent_reason` set to one of its enum values; the `*_absent_reason` field is `null` exactly when the signal value is non-null and non-null exactly when the value is `null`, so an absent signal can be neither silently omitted nor recorded without its reason. Rules 2, 4, and 6 govern the `signals` object, `admission_clause`, `fit_clause`, and `coldstart_slot_used` of `admit_listed` entries only; for `promote_recommendable` entries see rule 6a.
3. **Window and as-of are explicit.** `observation_window_start`, `observation_window_end`, and `as_of` are RFC3339 timestamps. The window is the trailing interval the aggregates cover (§16.2(b), §16.2(c): 30 days); `as_of` is when the operator evaluated them. A decision whose window ends more than one cadence period (§16.5) before `as_of` fails closed: stale evidence is not evidence.
4. **Suppression state is recorded, and a suppressed signal decides nothing.** `distinct_provider_offer_suppressed` and `unmatched_model_request_suppressed` record whether the aggregate was below the effective k-anonymity floor (§16.2(b), §16.2(a) item 9). A suppressed signal MUST record `null` as its value — never the small number it suppressed — and MUST NOT be named as `admission_clause`. A manifest naming a suppressed signal as the selected clause fails closed.
5. **Every §16.4 knob is recorded, at the value in force for THIS release.** `thresholds` is a closed object containing every knob of the §16.4 table, with no omissions and no additions. Adding a knob to §16.4 in a later revision extends this object and bumps `schema_version`.
6. **Selected clause and cold-start use are explicit (`admit_listed`).** For an `admit_listed` entry, `signals` is the closed object above, `admission_clause` is the closed enum `demand_rank` | `provider_offer` | `buyer_request` | `coldstart_slot` and names the ONE demand-or-supply term the operator relied on, `fit_clause` is `fleet_fit` | `tier_target`, and `promotion` is `null`. `coldstart_slot_used` is `true` exactly when `admission_clause` is `coldstart_slot`, and at most `INTAKE_COLDSTART_SLOTS` entries of one release may set it. `listed_since` is the RFC3339 time the key entered `listed`, REQUIRED and non-null for `promote_recommendable` (so `INTAKE_MIN_LISTED_DAYS` is checkable) and `null` for `admit_listed`.
6a. **Promotion entries record what promotion actually depends on.** §16.3 makes promotion an operator decision that no §16.2 signal produces, so a `promote_recommendable` entry MUST set `signals`, `admission_clause`, and `fit_clause` to `null`, `coldstart_slot_used` to `false`, and `promotion` to a closed object with exactly: `listed_days_elapsed` (integer, MUST be >= `INTAKE_MIN_LISTED_DAYS`), `rate_class` (a §3.3.1 enum value), `rate_row_resolved` (MUST be `true`; a promotion whose rate class does not resolve to a published rate row fails closed, §3.3.1), `rate_card_source_sha256`, `demand_rank_recommendable` (MUST be `true`, §3.2), `demand_rank_source_sha256`, `bench_provenance_source` (a §3.2 `bench_gate.provenance.source` value other than `omlx_seeded`, §12), and `operator_admission_reference` (a release-notes anchor or ticket id carrying no identity). Every key of every `decisions` element is present in every entry — the closed schema is the same for both actions; which fields are `null` is fixed by `action`, and an entry whose null pattern does not match its `action` fails closed.
7. **The operator decision is named.** `operator_decision` is the closed enum `admitted` | `promoted`, and `operator_role` names the operator role that took it. Promotion remains a human decision no signal makes (§16.3); this field records that it was taken, not that it was derived.
8. **No identity, ever.** The manifest carries aggregates and digests only. No provider id, pseudonym, or hardware fingerprint; no buyer account, API key, or IP address; no raw principal identifier and no §16.2(a) item-7 principal token, in any field, hashed or otherwise. It is a release artifact, and the §16.2 privacy invariants apply to it exactly as they apply to the aggregator that produced its inputs.

**Reconstructibility.** With this manifest, its ledger-recorded digest, and the release's signed feeds, an auditor can re-evaluate the §16.3 rule for every key the release changed and reach the same verdict without trusting the generator that produced the release — the same standard §3.7.8 sets for the cross-release `artifact_id` rebinding check. That is where the reconstructibility claim of §16 lives; §16.4's release-notes rule alone does not carry it (AC-CAT-21).
