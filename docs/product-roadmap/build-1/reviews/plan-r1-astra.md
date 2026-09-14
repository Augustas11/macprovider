# Independent adversarial Build 1 plan gate — revision 1

Verdict: **REJECTED**. Findings: 0 Critical, 1 High, 1 Medium. Implementation is not approved by this review.

Reviewed inputs:

- Base: `422fc2f13fc62c1ff8987522f822d9ef856e4a96`.
- Explicit unmerged prerequisite: PR #1468, `f5edeaebfb6c712a2cb6dced9020c8c78ed1053e`; reviewed through `git show` and the cumulative prerequisite diff inventory, without importing it.
- `plan-r1.md` SHA-256: `25e28c65f1c6d1f23ac0799991f58b0215811f11b35593dbfb182d6e2d405ca4`.
- `test-spec-r1.md` SHA-256: `c883dd24e5f40478c2c0ed82718fcbcae2c7ede39cc8cd9ecba45990aad90884`.

Both hashes were independently checked. Read repository `AGENTS.md` and `CLAUDE.md`. This is a read-only design/code inspection except for this review file. No implementation tests, hardware journey, production operations, or external writes were performed. No secrets or clean-room source were inspected.

## H1 — The proposed bootstrap exception stops before the adoption/admission cycle is resolved

**Severity: High.**

**Evidence.** Plan lines 10–14 and B1-T10 require preparation, then adoption, then admission. Lines 48–55 amend the economics prohibition only for non-economic preparation. Lines 82–89 reuse recommendation adoption and require the exact primary target's current session/hash plus successful wire probe and receipt/reference prerequisites for admission decisions. SPEC-044-R002 permits trusted economics only with coordinator `catalog_priced` or `settlement_capable` authority; R003 still categorizes `switch` and `adopt_recommendation` as money-motivated. `ModelManagement.swift:686` rejects actionable adoption and switch rows without trusted economics. `ModelCatalogEconomics.swift:665`–`678` disables the action until local readiness, admission economics permission and trusted economics exist. The existing adoption executable also is not a generic prepared-artifact activation command: `ModelsSubcommand.swift:1000`–`1021` validates an actionable recommendation and signed authority, and `:1429` onward requires a complete eligible `autotune_recommend.v1` document with benchmark/configuration and feed bindings. The plan does not supply a producer of that recommendation or an authorized pre-admission activation path. Existing coordinator probing uses the already connected provider session (`ws/server.go:4215` onward).

**Consequence.** A fresh provider with a newly prepared primary artifact can finish preparation but cannot follow the proposed app journey to load that target: adoption needs economic admission, while the proposed admission needs that target loaded. B1-T06 can pass by constructing a prepared, already-authorized recommendation, and B1-T07 can pass with an already loaded provider, without proving their composition. Treating the separate recommendation screen as an escape hatch would leave the SPEC-044 authority boundary unresolved.

**Required correction.** Define and normatively authorize one complete bootstrap sequence before implementation. For example, distinguish identity/rate-backed `catalog_priced` qualification from the loaded-session/receipt predicates required for `settlement_capable`, and make the offer/readback → actionable recommendation → adoption → probe → settlement transition explicit; alternatively define a narrowly scoped, confirmed non-economic local activation path with the required owner-spec amendments. This review does not select the policy. Specify how the actionable recommendation or activation authority is produced from the prepared target, including fresh fit/configuration evidence, rather than assuming the existing adoption command accepts a preparation result. Add an executable integration/app scenario beginning with no prior offer, no target session and no saved recommendation, preserving the incumbent until explicit adoption, and reaching settled traffic without pre-seeding admission or authority records. Keep all Build 1 outcomes.

## M1 — Durable publication is not connected to discovery, readiness and the signed offer identity

**Severity: Medium.**

**Evidence.** Plan lines 70–83 publish a verified durable copy, clean transaction-owned staging and refresh readiness, but name no discovery/projection/offer integration for that new location. At base, `BYOMDiscovery.swift:2174`–`2193` constructs only `BYOMMLXCacheDiscovery` using `environment.mlxCacheRoot`; the environment defaults to the Hugging Face cache (`:2040` onward), not `DurableModelArtifactStore.defaultRoot`. The same discovery path remains in the pinned prerequisite. `DurableModelArtifactStore.swift:12`–`24` uses the distinct provider-owned models directory, while `AutotuneRecommend.swift:3552`–`3559` separately honors configured durable roots. The offer/status command path resolves candidates from discovery (`BYOMDiscovery.swift:1939` onward). An isolated staging directory copied to durable storage and then cleaned therefore does not automatically appear as a discoverable `mlx_cache` candidate. B1-T02 says “fresh readiness” and B1-T06 assumes a prepared target, but neither requires an empty HF cache or demonstrates stable offer identity across publication and cleanup.

**Consequence.** Preparation can succeed while the executable projection still reports the target missing and `models offer` cannot resolve it. Existing cache contents can conceal the gap during local testing. A naive second adapter can also duplicate the same artifact or change candidate identity, losing the relationship to an existing signed offer.

**Required correction.** Assign a concrete CLI-owned bridge from durable inventory to read-only discovery, catalog projection, prepared-only adoption and offer generation. Specify supported root/config resolution, hash/revision/algorithm validation, candidate-ID stability and deduplication when both HF and durable copies exist, and what happens after staging/cache removal or restart. Preserve SPEC-046 read-only discovery and do not publish caller-supplied filesystem paths as authority. Add an executable test with initially empty HF cache: prepare into the configured durable root, remove only owned staging, restart the CLI, observe exactly one verified ready candidate, adopt it, and submit/read back an offer with the same intended identity. Include corrupted durable bytes and simultaneous HF/durable copies as negatives.

## Retained requirements and non-blocking observations

- The proposed immutable six-field artifact provenance extension correctly keeps candidate-catalog digest distinct from Tier2 `CatalogBodyDigest`; additive snapshot/digest compatibility and historical settlement evidence are explicitly required. These remain implementation-review obligations, not proven properties.
- The plan explicitly covers cancellation before/after publication, journals, incumbent preservation, path escape, disk exhaustion, stale input revalidation, concurrency, delayed app response and reconciliation. Do not replace those cases with happy-path tests while correcting H1/M1.
- The production promotion gap is real: the current offer path probes only toward `network_admitted_unsettled`, and exact idempotent replay returns without probing. The plan identifies both correctly.
- Physical acceptance remains mandatory and unproven. The prerequisite has no baked artifact feed; usable signed feed/reference material must be independently qualified. A missing feed/reference is a recorded blocker, never permission to report fixture settlement as physical completion or remove B1-T10. The real model/hash/runtime/device and accounting evidence must be reported separately from fixture and production evidence.
- Approval of a revised plan must bind its new exact digests. Correct these findings and rerun the independent gate; the reviewed revision is not approved.
