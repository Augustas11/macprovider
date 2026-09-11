# Product Build 3 — Plan v1 Finding Dispositions in Revision 2

Status: corrections authored; independent review pending
Source review: `reviews/plan-v1-sol.md`
Source review SHA-256: `4c2900708c8ce7ce6a1f999ac7b3b5c6054798f1aa12b7cb92eb19d5ab2eae44`
Corrected artifacts: `prd-implementation-plan-v2.md`, `test-spec-v2.md`

No finding was downgraded or waived.

| Finding | Disposition in R2 | Verification added |
| --- | --- | --- |
| H1 exact covered key/gate | Current approval scope is feasibility-only. Candidate model/revision/hash and package revisions are frozen; a closed no-TBD pilot manifest must freeze exact quantization, release, tokenizer, profile, OS/runtime and hardware-class fields. An unconditional second full gate blocks all runtime/source/reward/UI implementation. | B3-F001–F008, especially closed-manifest rejection and Gate B. |
| H2 durable owner/linearization | Observation authority and request captures are co-located in money SQLite. One lineage `flock` → `BEGIN IMMEDIATE` order, monotonic event/revision CAS, atomic route/capture, deterministic commit ordering, replay validation and crash recovery are defined. | B3-O001–O011 plus lock-order fault injection. |
| H3 wrong journal authority | Defines a canonical complete immutable event payload containing route, receipt/verdict/finality, exclusions, credits and full request-start observation capture. Every auxiliary mutation appends in the same transaction; consumer applies payload rather than rereading current rows. | B3-M001–M009 and request mutation matrix. |
| H4 restore/bootstrap | Defines an external non-restored lineage anchor plus target checkpoint and digest chain; old same-incarnation restores, forks and sequence reuse fail closed. Specifies exclusive online bootstrap, backfill identity/count/chain verification, tail catch-up, cutover, rollback and crash phases. | B3-M010–M018, especially same-generation restore and every bootstrap boundary. |
| H5 reference/calibration evidence | Restores SPEC-036's three simultaneous independence axes and mandatory additional signed golden fixture. Defines physical source records, exact class/cohort evidence, sample/position/warm/cold/tail requirements, measured false-quarantine budget, threshold, expiry and independent approval. | B3-REF001–004 and B3-CAL001–005. |
| M1 Tier-2/shared scheduler | Preserves plaintext/Tier-2 carrier separation, encrypted inference carrier, domain-separated replay, capability negotiation/NAK compatibility, buyer-first aggregate scheduling, compute-first ordering and losslessness anti-starvation. | B3-P001–P013. |
| M2 total reward mapping | Defines versioned independent request, earning, withdrawal and payment states, closed reasons/actions, exact precedence, last-known/freshness domains, unknown handling, truthful copy and cross-client shared vectors. | B3-R001–R014 and B3-U001–U012. |

Approval is not claimed. The exact R2 digests and commit must be supplied to a fresh independent GPT-5.6 Sol high-reasoning reviewer. Any Critical, High, or Medium finding requires another revision and review before implementation.
