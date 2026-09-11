# BYOM v0.2 slice 5 SPEC — independent cold-context review (2026-09-11)

Reviewed: `git diff origin/main -- specs/` at `72eeaec7` by three Claude
lanes (code-reviewer, security-reviewer, architect; model opus; neutral
prompt; forbidden from reading `audits/`, `.omc/`, `.claude/`; prompt in
the session scratchpad `slice5-independent-spec-review-prompt.md`).

| Lane | C | H | M | L | I |
|---|---|---|---|---|---|
| code-reviewer | 0 | 6 | 17 | — | — |
| security-reviewer | 0 | 6 | 15 | — | — |
| architect | 0 | 5 | 18 | — | — |

The three lanes overlapped heavily; the consolidated list below is
what the fix pass changed (SPEC and code together, in one commit).

## Consolidated findings and dispositions

- **Eligibility keyed on `model_not_found` measures capacity, not demand** (all three lanes, H): §5.2b.2 item 5 — unmatched means the normalized key is not a `listed`/`recommendable` row of the current release; evaluated before routing; an unserved admitted key never reaches the aggregator, a served non-catalog key does. Code: `intakeAdmittedCatalogKey` against `AutotuneFeeds.CandidateRowStatuses`, hook moved ahead of the `ModelKnown` branch.
- **Provider-offer count restricted to `catalog_matched` can never name an unadmitted key** (arch/code H): SPEC-047 counting rule now uses an offer-time `intake_model_key` resolved against EVERY candidate-catalog row and verified artifact; recorded on the event; DISTINCT-pair scan bounded by providers × keys.
- **SPEC-047 rule-4 contradiction: key-attributable suppression on a private reader vs a public manifest** (sec H): SPEC-047 suppression is served to the operator reader only; the public manifest records suppressed and absent identically (`*_suppressed` always false, `no_observations`).
- **Fleet histogram re-materialized every 15 minutes allows ±1 differencing; no trust-root join; unbounded window** (sec H, arch H): §5.2b.6 — materialized once per 30-day period (Unix-epoch-aligned), re-persisted byte-identical; activity requires `last_reported_at` inside `[start, end]` AND an active `hardware_verification_trust` root at `window_end`; never-trusted providers are not fleet; sub-floor providers folded into `provider_suppressed` so `provider_total` reconciles; complementary tie breaks to the HIGHEST floor. §7.2.2 grants `provider_hardware_profiles` and `hardware_verification_trust (provider_id, expires_at)` to `stats_rollup` (migration 028).
- **Random `eligibility_policy_id` is unverifiable across restarts and coordinators** (arch M, code M): HMAC-SHA-256 under the operator secret `stats.intake.policy_salt` over the canonical excluded-account set; derived at the buyer boundary; the aggregator receives only the id and the count.
- **403 confirms key existence; CORS on a non-browser surface** (sec H/M): every intake refusal is 401 with one shape; no CORS header at all; a key-less request is refused before the public tier; a disabled endpoint is 404 for OPTIONS too.
- **`principal_cap_pct` up to 100 defeats the "ten independent principals" argument** (sec M): bounded at 10 in SPEC-023 §16.4, SPEC-017 §5.2b.7, config, aggregator, generator.
- **Knobs unbounded above** (sec M): maxima on buckets, principals, distinct cap, floor.
- **Raw buyer string persisted with account in the request log** (sec H, found again by IMPL R1): request-log row of an unserved request carries a blank model and a constant message.
- **Persisted windows trusted on read-back** (sec/code M): every persisted and aggregator window validated against the closed wire contract; in-set and cross-set id conflicts fail closed.
- **Exact ppm over a small fleet reproduces the ratio in a public manifest** (sec M): `fleet_fit_fraction_ppm` floored to a 50 000 ppm grid; units stated (threshold pct vs recorded ppm).
- **`spec017_amendment_not_landed` gate keyed on nothing** (arch M): keyed on `specs/CONFORMANCE.json` SPEC-017 ≥ 0.2.1; the generator rejects the reason once landed.
- **Retention unbounded; store file modes unstated** (sec M): rule 9 lifecycle — 0600/0700, ≥ 24 months and while listed, ≤ 36 months after the last listing release, encrypted backup; generator refuses group/other-readable files.
- **`eligible_request_total` and `close_reason` on the wire leak window internals / are redundant** (sec M, code M): dropped from the wire; close reasons are local diagnostics.
- **Windows ≤ 8 retains more than the 90-day horizon needs** (arch M): at most 3.
- **Timestamps not byte-comparable** (code M): one form `YYYY-MM-DDTHH:MM:SSZ` in sources and manifest; exact 30-day windows; generator enforces.
- **`methodology` open-ended in a closed schema** (code M): closed to four fixed strings; coordinator emits the canonical values.
- **SPEC-047 snapshot bytes not bound to one build** (sec M): per-build `nonce` in the frame.
- **Sanction predicate: never-trusted providers count; withdrawal gated by the widened predicate** (arch H, sec M): eligibility requires an active trust root where trust is operated; the predicate is counting-only; the offer gate keeps its v0.1.5 route-sanction scope; withdrawal is never gated (SPEC-047-R006 "providers MUST be able to withdraw").
- **`rate_class` in a promotion entry unchecked against its source** (code M): must equal the artifact-feed model entry's `rate_class`.
- **`verify` without `--previous-release-dir` skipped the manifest entirely** (code M): the manifest is validated against the release inputs and retained sources; only the transition rule needs the previous release.
- **Two `§5.2a` headings; C5 states no exemption** (code M): routability renamed §5.2c; C5 amended.
- **CONFORMANCE: SPEC-023 depends on SPEC-017/SPEC-047, SPEC-047 on SPEC-014; SPEC-047 lacks a requirement id for the intake aggregate** (arch M): depends_on widened; SPEC-047-R009 added and mapped.
- LOW/INFO items (wording, cross-references, example consistency) were applied inline; none carried.

Fix commit: the slice-5 fix-pass commit that follows `687c9a60`. Codex closure lanes (SPEC) and IMPL R2 lanes run on the full diff after it.
