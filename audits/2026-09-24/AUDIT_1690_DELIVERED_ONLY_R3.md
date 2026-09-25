# #1690 audit R3: signed settlement finality, final pass (all three lanes)

**READ-ONLY.** Do NOT run builds, package resolves, or tests. Do not modify any file.

**Focus:** `git diff ac0731b5 537d397c`, the fixes for the R2 findings. Full context is `git diff 92340eee 537d397c`, and origin/main is the pre-#1690 baseline. The R2 brief is `audits/2026-09-24/AUDIT_1690_DELIVERED_ONLY_R2.md`.

## Claimed R2 fixes
- **Every negotiated 200 carries a signed finality tuple, HTTP and WS, non-streaming and streaming.** A request with no route snapshot gets a signed `legacy` tuple, which the gateway settles locally as today. For streaming, the tuple goes in the headers before the first byte when there is no snapshot, and as signed declared trailers when there is one. The pin `coordinator.require_settlement_trailers` holds only a missing declaration or a missing or bad MAC.
- **Post-delivery record or ingest failure, or evidence lost after credit.** The coordinator sends a signed closed refund tuple (`quarantined`/`inconclusive`, reasons `settlement_record_failed_after_delivery`, `settlement_output_missing_after_credit`, `settlement_finality_unset_after_delivery`) and logs an error. A deferred finalizer (`finalizeNegotiatedSettlementFinality`) guarantees that a negotiated non-streaming response never ends without a tuple.
- **The MAC** is HMAC-SHA256 keyed by the trimmed service token. Its input is a domain tag, the account, the request id, the coordinator's internal request id and the seven finality values, all length-prefixed. The golden vector is pinned on both sides.
- **One gateway helper, `setCoordinatorChatContext`, stamps every coordinator chat request** (chat proxy and relay-blind), and a source-scan test enforces it.
- **Runbook §9 and SPEC-022 R-12.8.**
  - Rollout: drain, coordinator, gateway, pin on, CLI, v2 allowlists.
  - Rollback: stop traffic, drain `settlement_hold=1`, pin off, then reverse rollback, then resume.
  - `deploy-pearl-vps.sh` only prints a restore recipe.
- **CONFORMANCE:** the SPEC-022-R012 mapping is extended.

## Known carried items: assess the severity and whether each is new
1. The gateway periodic reconciler re-queries `coordinator_404_held` rows forever, with no terminal state. This is pre-existing reconciler behaviour. Can any #1690 path still create such a hold?
2. The gateway stamps the bearer and capability only when `subject.AccountID != ""`. Can a settleable 200 have an empty account? If so, the pin holds it.
3. On the refund paths, a provider credit row marked `settlement_attempt_output_missing` (not quarantined) may still be payable while the buyer is refunded. The house absorbs a bounded loss, flagged by an error log. Before #1690 the same store failure produced a 500, with the credit behaving the same way.

## Check
- **CODE:** correctness of always-sign, the finalizer (it runs before net/http writes trailers?), refund tuples, streaming header vs trailer choice, retry clearing, and test adequacy.
- **SECURITY / money path:**
  - forgery or replay;
  - double settlement;
  - a free-delivery or billed-undelivered path;
  - the mixed pairings and the rollback window;
  - carried items 2 and 3.
- **ARCH:** SPEC-022, the runbook and CONFORMANCE are consistent; every hold reaches a terminal state; carried item 1.

Label PRE-EXISTING issues as such. Report only real defects at their true severity, with file:line. End with `VERDICT: <c> CRITICAL / <h> HIGH / <m> MEDIUM / <l> LOW`.
