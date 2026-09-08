# SPEC-023 v0.10.0 — audit round R2

**Date:** 2026-09-08
**Branch:** `spec/023-catalog-artifact-sets-class-rates`
**Audited diff:** the complete combined fix — `git diff origin/main...HEAD`, commits `8d5b5505` ("v0.10.0 catalog artifact sets, class rate rows, listed-tier intake") and `2e76f066` (R1 fix) — not the R1 fix slice alone.
**Scope:** `specs/SPEC-023-installer-autotune-recommend.md`, `specs/SPEC-047-network-model-admission.md`, `specs/CONFORMANCE.json`, `specs/README.md`
**Prompt:** [`AUDIT_SPEC_023_V0_10_PROMPT.md`](AUDIT_SPEC_023_V0_10_PROMPT.md)
**Prior round:** [`AUDIT_SPEC_023_V0_10_R1.md`](AUDIT_SPEC_023_V0_10_R1.md)
**Lanes:** three codex lanes (code-reviewer, security-reviewer, architect), each over the complete combined diff.
**Bar:** 0 CRITICAL, 0 HIGH, 0 MEDIUM.

## R2 verdicts

| Lane | Verdict | Result |
|---|---|---|
| code-reviewer | `0 CRITICAL / 2 HIGH / 7 MEDIUM / 2 LOW / 0 INFO` | REQUEST CHANGES |
| architect | `0 CRITICAL / 2 HIGH / 3 MEDIUM / 1 LOW / 2 INFO` | Blocking on identity authority and activation safety |
| security-reviewer | `0 CRITICAL / 0 HIGH / 1 MEDIUM / 0 LOW / 1 INFO` | Risk level MEDIUM |

Lane artifacts (local, untracked, `.omc/artifacts/ask/`):

- code-reviewer — `codex-spec-audit-...-2026-09-08T13-54-12-360Z.md`
- architect — `codex-spec-audit-...-2026-09-08T13-47-41-373Z.md`
- security-reviewer — `codex-spec-audit-...-2026-09-08T13-49-54-283Z.md`

All three lanes confirmed the R1 resolutions are present and intact (closed feed schema at every level, `declared` artifacts backlog-only, `Q1a`, the SPEC-017 adoption gate, GGUF barred from `catalog_priced` and `settlement_capable` in both specs). Every R2 finding is new or is an unresolved residue of R1's F1, and none reverses an operator decision: all three v0.10.0 decisions stand, and the fixes below change how they are ENCODED.

Findings are deduplicated across lanes below. Six of the eleven distinct findings were reported by two or three lanes.

## Findings and resolutions

### F7 — HIGH (code HIGH-1, architect HIGH-2; architect MEDIUM-3 is the same seam): the separate feed can fail-close already-installed updaters

**Reported at:** SPEC-023 §3.7.2 / §3.7.6 (`:623`, `:740`), against `phase3-binary/Sources/macprovider-cli/CompatibilitySetManifest.swift:485-500`, `scripts/compatibility-set-manifest.py:55` and `:532`, `scripts/acceptance-candidate-metadata.py:487`, `scripts/catalog-release.py:36` and `:767-800`.

**Finding.** §3.7.6 made the artifact feed "a first-class release-manifest member" and required `release.json` to bind it, then said it "participates in the §9 release ledger". Two problems. (1) The deployed provider CLI validates a signed compatibility-set manifest whose `components.catalog.files` map is an **exact nine-name set** and rejects any additional key; the package generator and the acceptance validator enforce that same exact set. An implementation that read "first-class release member" as "add it to `catalog.files`" would make every already-installed updater reject the v0.10 payload BEFORE the new binary could run — a fleet-wide fail-close, the precise failure §12.2 exists to prevent and the direct opposite of §3.7.6 rule 6. AC-CAT-2 tested recommendation behavior and AC-CAT-3 tested candidate-row decoding; neither exercised the previous-stable self-update path. (2) "§9 release ledger" pointed at nothing: §9 is "Re-tune cadence + UX". The real ledger validator accepts exactly three historical feed-name sets, and the spec did not say which of them stay valid, when a new set becomes mandatory, or how tombstone/rebinding rules apply to it.

**Resolution.** New **§3.7.8 "Release binding, ledger feed sets, and staged activation"** (SPEC-023 `:785`), with §3.7.6's paragraph reduced to a pointer at it and the wrong "§9 release ledger" reference removed and explicitly named as an error.

- **Release binding.** `release.json` (the manifest generated and validated by `scripts/catalog-release.py`, on which §3.5 rules 11-13 and the §3.3 rate-card binding already depend) MUST bind `autotune-artifacts.json` by `sha256`, `bytes`, `version`, `signer_key_id`; the release ledger `release-ledger.json` records the release with the artifact-bound feed set.
- **Ledger feed-set evolution.** A normative four-row table: Legacy 2-feed and Tier-2-bound 3-feed stay permanently valid as historical sets and MUST NOT be re-validated against a later set; rate-card-bound 4-feed stays permanently valid for releases cut before activation; **artifact-bound 5-feed** is added, is valid from the activation release, and is MANDATORY for every release cut on or after it. A release uses exactly one set; a post-activation revert to the 4-feed set fails closed. `autotune-artifacts.json` is release-train-versioned (its `version` equals `release_id`), unlike `tier2-catalog.json` and `rate-card.json`. Tombstone and release-ID rebinding rules are unchanged and extend to the new member: a `release_id` observed bound to two differing feed digest sets is permanently rejected, and the artifact feed's `sha256`/`bytes` join that observed binding.
- **Two-stage activation (§12.2-style).** **Stage A (v0.10.0):** the feed is generated, signed, served at `/v1/catalog-artifacts`, baked into the release payload, bound in signed `release.json`, and ledger-recorded — fully release-bound — but it **MUST NOT** be added to `components.catalog.files`, and the exact nine-name catalog file set the deployed updater enforces stays unchanged. The producer-side `release.json` `feeds` check in `scripts/compatibility-set-manifest.py` widens to five feeds in the same slice; that script runs on the release host and in acceptance, never on an installed provider, so widening it fail-closes no fleet member. (The deployed Swift validator digests the nine named files and never parses `release.json` contents, which is why Stage A is safe.) **Stage B (later revision):** the feed and its `.sig` MAY join `components.catalog.files` only when BOTH (i) a bridge CLI accepting the widened map has shipped as stable, and (ii) previous-stable for the self-update path is at or after that bridge. Until both hold, Stage B is PROHIBITED — the same shape as the §12.2 Stage-1/Stage-2 gate.
- Stage A is weaker than Stage B **for the compatibility-set manifest only**: §3.7.2 signature verification, §3.7.4 release binding, §3.7.5 consistency, and the §3.7.6 failure classes apply in full at Stage A.
- **AC-CAT-15 (new)** proves it: the last pre-v0.10 updater validates and installs a v0.10 payload through the previous-stable self-update path with no manifest rejection and no rollback; a release adding the feed to `catalog.files` while Stage B is ungated is rejected at generation; a Stage-B release with either gate condition unmet fails closed; and the ledger accepts the three historical sets, accepts the 5-feed set, and rejects mixed/partial sets, post-activation reverts, and double-bound release IDs.
- R004 now requires §3.7.2 through §3.7.8 and states the Stage-A/Stage-B obligation directly.

### F8 — HIGH (architect HIGH-1): non-primary artifacts cannot be SPEC-010 settlement identities

**Reported at:** SPEC-023 `:605`, `:709`, `:744`, `:1567`; SPEC-047 `:117`; against SPEC-010 `:975`, `:980`, `:1004`.

**Finding.** SPEC-010 is the sole authority for model identity. SPEC-010-R001 defines `macprovider.snapshot-manifest.v1` as the `model_sha256` **of the exact signed candidate-catalog row**, and SPEC-010-R004 keeps that same row as session authority for later heartbeats and settlement snapshots. R004 and the SPEC-047-R003 amendment gated settlement on the **algorithm name** alone, so a secondary `mlx_safetensors` quantization — verified, correctly declaring `macprovider.snapshot-manifest.v1`, but with different bytes and therefore a different digest — passed the algorithm gate while being, structurally, not a SPEC-010 identity. Q14 addressed only the GGUF algorithm and did not cover alternative snapshot-manifest identities, so naming a GGUF algorithm would not have closed this.

**Resolution.** v0.10.0 restricts settlement identity to the **primary artifact only**, in five places, so the revision is strictly consistent with SPEC-010 as it stands today and needs no SPEC-010 amendment:

- **§3.7.4** gains a normative bullet: only the artifact named by `primary_artifact_id` (`mlx_safetensors`, `macprovider.snapshot-manifest.v1`, `verified`, `hash` byte-identical to the candidate row's `model_sha256`) may support `catalog_priced`/`settlement_capable`, be the SPEC-010 `model_hash`/`model_hash_algorithm` wire pair, or bind a SPEC-022 route-time snapshot. Every non-primary artifact of ANY format — a `gguf` artifact and a secondary MLX quantization alike — reaches at most `catalog_matched`, `sandbox_probe_only`, `network_visible_unpriced`.
- **§3.7.7 R004** replaces the algorithm-only condition with the primary-only rule and keeps the algorithm exclusion as an independent second ground.
- **§13 Q14** is broadened from "name a GGUF hash algorithm" to **"SPEC-010 multi-artifact identity"**, splitting the gap into (a) the algorithm gap and (b) the non-primary-artifact gap, and naming the SPEC-010 amendment (R002 algorithm naming **and** R001/R004 recognition of a release-bound verified artifact-feed entry) as the BYOM v0.2 epic's SPEC-010 slice.
- **SPEC-047-R003** and the `catalog_matched` paragraph mirror the rule, and the 0.1.3 changelog is rewritten to match.
- **AC-CAT-17 (new)** tests the case the algorithm exclusion misses: a verified secondary `mlx_safetensors` artifact declaring the correct algorithm is refused `catalog_priced`, `settlement_capable`, the SPEC-010 wire pair, and the SPEC-022 binding, for the primary-only reason, independently of AC-CAT-7's algorithm reason.

### F9 — HIGH (code HIGH-2) / MEDIUM (architect MEDIUM-1): the identity fields were closed individually but not as a tuple

**Reported at:** SPEC-023 §3.7.4 (`:706-713`), §3.7.3 (`:687`), AC-CAT-1 (`:1282`), AC-CAT-7 (`:1294`).

**Finding.** `runtime_format`, `source_ref.kind`, `hash_algorithm`, and `allowed_runtime_sources` were each a closed enum, validated independently. Nothing required `gguf` to pair with `macprovider.gguf-file.v1`. A schema-valid, operator-signed `gguf` artifact declaring `macprovider.snapshot-manifest.v1` therefore passed the algorithm-only settlement gate despite GGUF settlement being explicitly deferred. Only the primary artifact carried a complete tuple constraint (§3.7.5).

**Resolution.** §3.7.4 gains a **closed artifact-identity matrix (normative)** — a two-row table giving, per `runtime_format`, the only legal `hash_algorithm`, the only legal `source_ref.kind`, and the only legal `allowed_runtime_sources` superset:

| `runtime_format` | `hash_algorithm` | `source_ref.kind` | `allowed_runtime_sources` ⊆ |
|---|---|---|---|
| `mlx_safetensors` | `macprovider.snapshot-manifest.v1` | `huggingface_revision` | `{mlx_cache}` |
| `gguf` | `macprovider.gguf-file.v1` | `ollama_library_tag` | `{ollama_loopback, llamacpp_loopback, lmstudio_loopback, openai_compatible_loopback}` |

Every artifact MUST match exactly one row on all four fields; **any other tuple is `catalog_artifact_feed_integrity_failure`** at generation and at consumption. The matrix is closed in both directions — adding a format, algorithm, source kind, or pairing is a SPEC revision plus a generator and consumer release. The two pre-existing independent constraints (an `mlx_safetensors` artifact allows only `mlx_cache`; a `verified` artifact may not allow `openai_compatible_loopback`) are stated as restatements of and additions to the matrix, so the fourth column's `openai_compatible_loopback` entry is reachable only by a `declared` artifact. R004 carries the obligation. **AC-CAT-16 (new)** enumerates seven negative tuples — both format/algorithm swaps, both format/source-kind swaps, both `allowed_runtime_sources` violations, and the verified-`openai_compatible_loopback` case — each rejected at generation and at consumption with a valid signature over the bytes, plus one legal tuple per format that validates.

### F10 — MEDIUM (code M1): class rows carried fields the coordinator billing fallback cannot represent

**Reported at:** SPEC-023 §3.3.1 rules 3-4 (`:477`), against `phase4-coordinator/dist/coordinator.yaml:245` and `phase4-coordinator/internal/config/config.go:1086`.

**Finding.** A class carried five per-row values including `provider_share_bps` and `global_multiplier_ppm`, and had to be materialized into coordinator YAML rows. Coordinator `rewards.rate_card` rows carry only three credit fields (`RateCardEntry`); provider share and global multiplier are release-global settings (`RewardsConfig.ProviderShare`, `RewardsConfig.GlobalMultiplier`). A class-specific share or multiplier was therefore unrepresentable in the billing fallback the expansion writes into, which could make signed recommendation economics diverge from actual coordinator billing while the "billing untouched" decision held. No JSON-to-YAML field mapping and no parity check were specified.

**Resolution.** §3.3.1 rules 3, 4, and a new rule 9:

- **Rule 3** — a `classes` entry carries **exactly the three credit-rate fields** (`prompt_rate_per_mtok`, `prompt_cache_hit_rate_per_mtok`, `completion_rate_per_mtok`) and MUST NOT carry `provider_share_bps` or `global_multiplier_ppm`; a source that declares either on a class fails the release closed. Those two are release-global values, held once by the coordinator, applied by the generator to every expanded row at expansion time, and they MUST equal the coordinator globals of the release being published. Published rows still carry both fields per §3.3, materialised from the release-global values and identical across every row of a release.
- **Rule 4** — the exact mapping table: `prompt_rate_per_mtok`→`prompt_credits_per_mtok`, `prompt_cache_hit_rate_per_mtok`→`prompt_cache_hit_credits_per_mtok`, `completion_rate_per_mtok`→`completion_credits_per_mtok` (per row, integers on both sides, no rounding/conversion/defaulting; a generator that would have to round fails closed), and `provider_share_bps`→`rewards.provider_share` (`bps / 10000`), `global_multiplier_ppm`→`rewards.global_multiplier` (`ppm / 1000000`) (release-global, never written into a `rewards.rate_card` row), each with its Go binding.
- **Rule 9 (new)** — generated-feed / billing-config parity is a release gate: before signing, the published `rate-card.json` `rows` and the coordinator inline fallback rows published with it MUST agree row-for-row under the rule-4 mapping, and the release's share/multiplier MUST equal the published coordinator configuration's after unit conversion. Any disagreement fails the release closed.
- **AC-CAT-14 (new)** is the parity test, including that mutating any one value on either side, adding or removing a key, or writing a per-row share fails generation. **AC-CAT-9** additionally asserts the class-level share/multiplier rejection.

### F11 — MEDIUM (code M2): stale-feed behavior was internally contradictory

**Reported at:** SPEC-023 §3.7.6 rules 4-5 (`:736`), R004 (`:744`), SPEC-047-R003.

**Finding.** Rule 4 said a 14-30-day-old feed is "allowed" with a stale warning; rule 5 failed artifact capabilities only for integrity and update-required; R004 and SPEC-047-R003 both said staleness also fails every artifact-derived capability. Three statements, two behaviors.

**Resolution.** Rule 4 now states stale bytes MAY still be **selected** — they are the freshest bytes available and are useful for recording which feed a fallback decision was made against — but selection is **for diagnostics and fallback provenance only**, and stale bytes MUST NOT authorize any artifact-derived capability. Rule 5 adds `catalog_artifact_feed_stale` to the fail-closed set alongside integrity-failure and update-required, with the reason stated: an artifact binding is a settlement-adjacent identity claim and a 14-to-30-day-old identity claim is exactly the §15 replay window, so the artifact feed is deliberately stricter about staleness than the §3.5 feeds whose stale bytes stay usable. R004's staleness sentence is unchanged and now agrees with both rules.

### F12 — MEDIUM (code M3): the new `listed` tier conflicted with §12.2(b)(ii)

**Reported at:** SPEC-023 §12.2(b)(ii) (`:1431`), against the amended ladder (`:388`) and §16.3 (`:1660`).

**Finding.** §12.2(b)(ii) said every provisional row — `candidate` and `listed`, including every `omlx_seeded` row — is local-only and never buyer-routable. The v0.10.0 ladder grants a `listed` row SPEC-047 `sandbox_probe_only` and `network_visible_unpriced`. Direct contradiction inside one spec.

**Resolution.** §12.2(b)(ii) is amended to scope the prohibition by tier, keeping the Stage-1 oMLX gate at full strength:

- A `candidate` row and **every `omlx_seeded` row at any tier** remain local-only and never buyer-routable at all — no paid routing, no default routing, no sandbox probe, no unpriced visibility. The Stage-1 promotion prohibition is unchanged.
- A `listed` row that is not `omlx_seeded` is prohibited from **paid and default buyer routing only**. It MAY reach `sandbox_probe_only` and `network_visible_unpriced` and MAY be `catalog_matched` against a verified artifact, exactly as §3.2 and §16.3 state, and it MUST NOT reach `catalog_priced` or `settlement_capable`.

The heading is retitled "Network-connected PAID providers are `recommendable`-only" so the requirement name matches what it now requires.

### F13 — MEDIUM (code M4 + M5, architect MEDIUM-2, security M1): the bounded unknown-key contract demanded exact results from insufficient state

**Reported at:** SPEC-023 §16.2(a) clauses 4-9 (`:1629-1634`), AC-CAT-13 (`:1306`).

**Finding.** R1's F1 fix bounded the OUTPUT but not the ALGORITHM. It required simultaneously: exactly the highest-count 64 keys with deterministic ties; ingest-time work bounded by that same constant; an exact overflow distinct-key count; and per-principal contribution caps with no retained principal rows. Exact top-K selection and exact distinct-key counting are not both achievable in state bounded by K, and the per-principal cap placed no bound on the number of principal counters, so principal fanout grew state independently of the 64-key limit. Every conforming implementation had to violate at least one MUST, silently approximate a normative count, or diverge in admission behavior. Clause 9's blanket identity prohibition also contradicted clause 6's unspecified principal-scoped counter. The SPEC-017 adoption gate postponed rather than resolved this. All three lanes reported it; the security lane supplied the remediation shape.

**Resolution.** §16.2(a) clauses 4-9 are replaced by clauses 4-10, one complete bounded model:

4. **Named fixed-memory heavy-hitter algorithm** — **Space-Saving** (Metwally/Agrawal/El Abbadi) at capacity `INTAKE_UNKNOWN_KEY_BUCKETS` (default 64). Each entry carries `count` and `error`. Monitored key → increment; room available → new entry at `count = 1, error = 0`; otherwise evict the **victim** (smallest `count`; ties by largest `error`, then by key ascending — deterministic and normative) and install the new key at `count = victim_count + 1, error = victim_count`. Memory and per-request work are bounded by the capacity and independent of distinct-key volume; the bound is enforced at ingest, not at emission.
5. **Only the conservative LOWER BOUND may clear a floor** — an entry's lower bound is `count - error`, and only that value may satisfy `INTAKE_BUYER_REQUEST_FLOOR`; `count` is an upper bound and satisfies nothing. Emission carries the lower bound (optionally `count`/`error` as diagnostics), ordered by lower bound then key ascending. The SPEC explicitly **abandons the exact-top-N claim** and states the two guarantees it does rely on: any key exceeding `window_eligible_request_total / INTAKE_UNKNOWN_KEY_BUCKETS` is monitored, and a lower bound never exceeds a true count. Intake is a floor test and never an ordering, so this is exactly sufficient.
6. **Single overflow bucket with saturating counters** — `other_suppressed` absorbs ineligible-key requests, evicted counts, and discarded over-cap and overflow-principal contributions. It carries `request_count` (saturates at `2^53 - 1`) and `distinct_key_count` (saturates at **`INTAKE_UNKNOWN_KEY_DISTINCT_CAP`, default 10000**), setting `saturated: true` on reaching a cap. `distinct_key_count` is defined as a **key-churn indicator** (one per eviction plus one per ineligible-key request), explicitly **not** an exact cardinality — no sketch is required and no exact distinct-key count is promised anywhere. `other_suppressed` never satisfies any floor, saturated or not.
7. **Per-principal cap accounted by an opaque window-scoped token** — the 10%-of-floor cap is unchanged; excess goes to `other_suppressed.request_count`. Accounting uses `principal_token = HMAC-SHA-256(window_key, "macprovider.intake.unknown_model_principal.v1" || principal_identifier)` truncated to 16 bytes, where `window_key` is cryptographically random per window, held only in private aggregator memory, never persisted, never emitted, and **destroyed at window close together with every derived token**. Tokens are non-correlatable across windows by construction and non-reversible.
8. **Bounded principal cardinality** — at most **`INTAKE_UNKNOWN_PRINCIPALS_PER_BUCKET` (default 64)** distinct tokens tracked per retained bucket per window. An untracked principal arriving at a full bucket is an **overflow principal** contributing only to `other_suppressed`, never to that bucket, so it can never satisfy a floor. Total principal state is bounded by `INTAKE_UNKNOWN_KEY_BUCKETS × INTAKE_UNKNOWN_PRINCIPALS_PER_BUCKET` counters (4096 at defaults); per-request principal work is one HMAC plus one bounded lookup. An evicted bucket's principal table is destroyed with it.
9. **Suppression and floors** — k-anonymity suppression on the post-cap lower-bound count; the floor is satisfied ONLY by a retained bucket's post-cap, post-suppression **lower-bound** count; `other_suppressed`, suppressed buckets, upper-bound `count`s, discarded over-cap contributions, and overflow-principal contributions may never satisfy it and may never be added back.
10. **No identity, no rows, no tokens on the wire** — aggregated counts only at every stage, and **neither a raw principal identifier NOR an item-7 opaque token may appear in an emitted or retained record**, in any field, hashed or otherwise.

Supporting changes: **§16.4** gains `INTAKE_UNKNOWN_PRINCIPALS_PER_BUCKET` = 64 and `INTAKE_UNKNOWN_KEY_DISTINCT_CAP` = 10000 with rationale, and the `INTAKE_UNKNOWN_KEY_BUCKETS` rationale is restated in terms of the Space-Saving guarantee. **§16.7** restates the invariant list to name the algorithm, the lower-bound semantics, the token bound, and the window-close key destruction. **§15**'s unknown-model-key-fanout row is rewritten to the same terms. **AC-CAT-13** now requires **proven** bounds: under adversarial distinct-KEY fanout AND under adversarial distinct-PRINCIPAL fanout against one key, measured total memory stays at or below the summary entries plus the principal counters plus the two overflow counters, and per-request work is constant; determinism is asserted by re-running the same request order; a bucket whose upper-bound count clears the floor while its lower bound does not, does not clear it; and no opaque token appears in any emitted or retained record. The SPEC-017 adoption gate is kept unchanged.

### F14 — MEDIUM (code M6): `candidate` was both pre-verification staging and required to have a verified artifact

**Reported at:** SPEC-023 §3.2 ladder (`:387`), §3.7.5 (`:718-725`), §16.1 (`:1608-1610`).

**Finding.** The ladder granted `candidate` "operator staging of a row before its artifacts are verified", while §3.7.5 required every non-`blocked` candidate-catalog row to have a verified primary artifact and §16.1 P1 said no key enters any tier without one. The §3.2 sentence "every downloadable row (`candidate`, `listed`, or `recommendable`) MUST include both `model_revision` and `model_sha256`" added a third reading.

**Resolution.** `candidate` is stated as operator staging, and the two obligations are scoped rather than the semantics removed (donor-mode rules in §7.2 and §8, which reference `candidate` rows, are untouched):

1. §3.7.5's verified-primary consistency check applies to rows whose `runtime_status` is `listed` or `recommendable`; a `candidate` row is out of scope and its artifact-feed entries MAY all be `declared`. §3.7.5 and R004 both carry the narrowed scope, and AC-CAT-5 asserts that an all-`declared` `candidate` row produces no warning.
2. §16.1 P1 is a precondition for **entering `listed`** (and transitively `recommendable`), not for authoring a `candidate` row.
3. A `candidate` row is never BYOM-matchable and never reaches `catalog_matched`, `catalog_priced`, or `settlement_capable` — now stated in the ladder's "never grants" column as well as in the new paragraph.

The §3.2 downloadable-row sentence is reconciled rather than changed: it governs **local download authorization by the row's own signed identity**, which is what donor mode exercises, while the artifact feed's `declared`/`verified` distinction governs whether an entry may act as a **network-visible catalog identity** for matching, pricing, or settlement. The spec now says explicitly that a `candidate` row is locally downloadable by its signed row hash and simultaneously matchable by nobody over the network, and why those are consistent.

### F15 — MEDIUM (code M7): AC-CAT-7 omitted its preconditions

**Reported at:** SPEC-023 AC-CAT-7 (`:1294`), against AC-CAT-6 and §3.7.4.

**Finding.** AC-CAT-7 said unconditionally that an artifact using `macprovider.gguf-file.v1` reaches `catalog_matched`, `listed` intake, `sandbox_probe_only`, and `network_visible_unpriced` — contradicting AC-CAT-6 and §3.7.4, which bar `declared` and `blocked` artifacts from any catalog match or admission tier.

**Resolution.** AC-CAT-7 is conditioned on `verification_status == "verified"`, an exact digest match against the provider's locally computed digest, and a row whose `runtime_status` is `listed` or `recommendable`. It also now states the refusal on both independent grounds (not the primary artifact — AC-CAT-17; algorithm not named by SPEC-010-R002) and adds the negative direction: change any precondition and the match itself fails.

### F16 — LOW (code L1): `verified_at` had two plausible wire formats

**Reported at:** SPEC-023 §3.7.3 / §3.7.4 (`:659`, `:691`).

**Finding.** The field was described as an "RFC3339 date" while the example used `2026-09-08`; an RFC3339 timestamp parser rejects that value.

**Resolution.** Both places now say **RFC3339 `full-date`: exactly `YYYY-MM-DD`, ten characters, no time-of-day and no zone offset, never a full RFC3339 timestamp**, and a consumer MUST reject a value carrying either. The §3.7.3 example is already in that form and is unchanged.

### F17 — LOW (code L2): primary-consistency failure had two warning classifications

**Reported at:** SPEC-023 §3.7.5-§3.7.6 (`:727`, `:735`), AC-CAT-5.

**Finding.** §3.7.5 called a primary-artifact disagreement an integrity failure; §3.7.6 rule 3 folded §3.7.5 consistency failures into `catalog_artifact_feed_update_required`. Both fail closed, but implementations and tests could emit different codes.

**Resolution.** One class, `catalog_artifact_feed_integrity_failure` (§3.7.6 class 2), with the reason stated: two release-bound feeds of one release disagreeing about an identity is a corrupt release, not a stale one. §3.7.6 rule 3 drops the §3.7.5 reference and says so explicitly; §3.7.5 names the single class; AC-CAT-5 asserts that exact code in both the generator test and the consumer test and asserts the update-required code is NOT emitted.

### F18 — LOW (architect LOW-1): the cold-start slot was optional in one place and reserved in another

**Reported at:** SPEC-023 §16.4 (`:1683`), §16.6 (`:1705`).

**Finding.** The §16.4 threshold table said one fit-only admission "MAY" occur; the §16.6 Goodhart text claimed the slot "reserves at least one" admission. A discretionary exception does not reserve anything.

**Resolution.** Both places now say the same thing. §16.4: the operator **MAY** admit up to `INTAKE_COLDSTART_SLOTS` new `listed` rows on P1-P4 plus the fit term alone; the slot is a **discretionary permission, not a reservation** — it permits an admission the demand-or-supply disjunction would otherwise refuse, never obliges one, and an unused slot does not accumulate. §16.6 FM-2 item 4 says **permits** and adds that the cold-start loop is broken by the route existing, not by an obligation to use it every release.

## Carried items

| Item | Lane | Severity | Why carried |
|---|---|---|---|
| SPEC-047-R002 duplicated offer-package MUST-list (R1 F6) | architect (R1) | LOW | Pre-existing on `origin/main`; not introduced or worsened by this branch. The v0.1.3 citation-only note already names the later, stricter paragraph as authoritative where the two lists differ. Consolidation remains a SPEC-047 editorial revision. Excluded from R2 lane reporting by the prompt. |
| `GO-2026-5970` — `golang.org/x/text v0.37.0` in `phase7-verify` | security (R2 INFO-1) | INFO | Corrects R1's carried note, which classified all `govulncheck` findings as toolchain artifacts. Five are fixed by moving from local Go 1.26.4 to the repo target 1.26.6; this one is a module finding fixed in `golang.org/x/text v0.39.0`. **Not a normative-spec finding and not introduced by this branch** — this branch changes no dependency file. Tracked separately for a dependency-upgrade pass; the verifier-availability impact is input-dependent DoS with no demonstrated settlement forgery. |

## Verification after fixes

```
python3 scripts/gen_spec_index.py --lint     # ok: specs/ root is canonical-only (51 tracked)
python3 scripts/gen_spec_index.py --check    # canonical specs: 47 / ok: spec index is up to date
python3 scripts/check_spec_governance.py     # SPEC governance validation passed
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_spec_governance
                                             # Ran 46 tests — OK
python3 scripts/catalog-release.py verify    # verified catalog release published-2026-09-02-gpt-oss-120b-v1
git diff --check                             # clean
```

The revision remains docs-and-governance only: no catalog JSON, no generator code, and no Go or Swift code changes on this branch. Every fix above is an encoding change to the same three operator decisions R1 and R2 audited; none reverses a decision.

## Round status

R2 findings: 12 distinct findings across three lanes (2 HIGH deduplicated from 4 lane reports, 1 HIGH+MEDIUM pair, 6 MEDIUM deduplicated from 11 lane reports, 3 LOW), all 12 resolved in this fix commit. One pre-existing LOW (SPEC-047-R002 duplication) and one non-branch dependency INFO are carried. Four acceptance criteria are added — AC-CAT-14 (billing parity), AC-CAT-15 (staged activation and previous-stable self-update), AC-CAT-16 (closed artifact tuple, seven negative cases), AC-CAT-17 (primary-only settlement identity) — and AC-CAT-5, AC-CAT-7, AC-CAT-9, and AC-CAT-13 are strengthened. R3 re-audits all three lanes over the complete combined diff — `8d5b5505` plus both fix commits — never the R2 fix slice alone.
