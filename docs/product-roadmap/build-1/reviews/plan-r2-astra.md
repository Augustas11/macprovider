# Independent adversarial Build 1 plan gate — revision 2

Verdict: **REJECTED**. Findings: 0 Critical, 1 High, 0 Medium. The remaining High is the executable-producer portion of r1 H1; the normative activation cycle and r1 M1 are addressed at plan level. Implementation is not approved by this review.

Reviewed inputs:

- Base: `422fc2f13fc62c1ff8987522f822d9ef856e4a96`.
- Explicit unmerged prerequisite: PR #1468, `f5edeaebfb6c712a2cb6dced9020c8c78ed1053e`.
- `plan-r2.md` SHA-256: `333cf85c4047b1159412199b42a9dfd9085766c7ad729d2d6e2967af07b92c4d`.
- `test-spec-r2.md` SHA-256: `14c5fc3ab2e94c477745ee0e92b05df7d2c481206895590de8f8c919b3485a34`.

Both hashes were independently checked. The repo instructions and code/prerequisite inspection from r1 remain applicable. This pass re-read the full r2 pair and independently followed its newly named recommendation executable into its implementation. Only this new review file was written; r1 review, plans and code are unchanged. No tests, physical journey or production operations were performed by this reviewer.

## H1-R2 — The specified “real benchmark” producer explicitly produces catalog estimates

**Severity: High. Disposition: r1 H1 partially corrected, still open.**

**Evidence.** `plan-r2.md:74`–`80` names `autotune --recommend --check-only --installed-only --candidate-models TARGET --progress-json` as the existing producer of “genuine current local benchmark/fit” evidence. In `AutotuneCommand.swift:1195`–`1200`, that command requires `--json` (omitted in the plan) and explicitly requires installed-only behavior because background checks never benchmark. Its reachable branch calls `installedOnlyBenchmarkOutcomes` (`:1268`–`1274`), which reads a verified existing artifact and creates `CandidateBenchmark` using `row.benchGate.minSustainedTPS` and `row.benchGate.max4KTTFTMS` (`:1347`–`1366`), not measured inference. `disclosingInstalledOnlyEstimate` labels the result `catalog_estimate` and says no local throughput benchmark ran (`:1375`–`1390`). The actual `AutotuneRecommendationBenchmarker` is in the other branch, unreachable under this command's mandatory installed-only guard. The pinned prerequisite does not replace that algorithm.

**Consequence.** As written the exact command fails validation. Adding `--json` makes it emit an estimate-backed recommendation, not the current local measurement the plan promises. Executing the CLI and receiving an eligible recommendation is therefore insufficient evidence for B1-T11's intended bootstrap proof. Merely treating its `CandidateBenchmark` struct or timestamp as measured evidence would launder catalog estimates into physical qualification. Conversely, silently switching to an ordinary benchmark command can reintroduce downloads, cache mutation and unsafe provider lifecycle behavior that the chosen installed-only command was intended to exclude.

**Required correction.** Specify a feasible, explicitly owned real measured prepared-only recommendation path, whether by carefully constraining the existing benchmark path or implementing an appropriately versioned producer mode. Pin the exact invocation, including required output flags and whether TARGET denotes the signed row's model ID rather than its catalog key. Require verification of the prepared exact hash/revision before inference, fail-closed behavior when material is absent, no downloader/cache-population fallback, bounded runtime/cancellation/progress and safe isolated provider drain/restore. Keep the normative non-economic activation authorization already added in r2. Extend B1-T11 to prove actual local inference occurs, require measured evidence provenance rather than `catalog_estimate`, prove no downloads or incumbent configuration mutation before activation, and reject estimate-only output for the promised measured step. Preserve physical B1-T10 and every existing Build 1 outcome; do not resolve this by relabeling estimates or dropping the measurement promise.

## Prior finding dispositions

| Finding | Disposition | Evidence and remaining obligation |
|---|---|---|
| r1 H1, activation/admission policy cycle | Corrected at plan level | r2 lines 59–69 and 93–98 explicitly authorize confirmed non-economic activation before admission, name normative owner amendments, suppress economics, retain signed authority/fit/configuration checks, and retain conservative legacy behavior. Those amendments must land before the corresponding runtime behavior. |
| r1 H1, actionable recommendation producer | Open, High | H1-R2 above. A concrete command was added but cannot produce its promised measurement. |
| r1 M1, durable discovery/offer bridge | Corrected at plan level | r2 lines 102–121 assign the bridge across discovery, command resolution and projection, use the existing resolver/root precedence and path-independent candidate identity, and define dedup/conflict/corruption/restart behavior. B1-T12 starts with empty HF cache and traverses adoption/offer/status. Implementation must prove these claims. |
| Operator-custody isolation boundary | Addressed at plan level | The acceptance section explicitly isolates config, identity, HMAC, discovery namespace, credential and model roots and requires inspection/override of CLI defaults before a journey. B1-T13 rejects operator-default stores and nonlocal service targets. This is particularly necessary because the specified recommendation producer calls `AutotuneHMACSecretStore.defaultPath.loadOrCreate` at `AutotuneCommand.swift:1241`. No operator-store inspection or mutation was performed for this review. |

## Full-plan retained checks

The rest of the r2 plan retains the required primary-only authenticated feed and fallback gates; transaction cancellation, atomic publication and recovery; truthful app projection/capability/confirmation behavior; current coordinator session, sanction, receipt, reference and effective rate authority; immutable six-field artifact provenance without repurposing Tier2 catalog digest; historical snapshot compatibility; concurrency and drift negatives; PostgreSQL settlement/accounting proof; and three cumulative implementation audit lanes. No additional Critical/High/Medium plan finding was identified in those sections during this pass. This is not implementation acceptance or a claim those tests passed.

Physical preparation-to-settled-request acceptance remains mandatory, separately qualified and unproven. A fixture key/feed/reference or estimate-backed recommendation cannot count as that physical proof. Missing independently qualified material remains a blocker. The reported local Xcode environment does not substitute for the separate locked release-toolchain qualification, and release/publication remains outside this build's operational scope.

Correct H1-R2, bind the revised pair to new exact digests, and rerun this independent gate. The reviewed revision is not approved.
