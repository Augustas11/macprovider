# #1690 audit R4: signed settlement finality, closing pass (all three lanes)

**READ-ONLY.** Do NOT run builds, package resolves, or tests. Do not modify any file.

**Focus:** `git diff 537d397c 6db8ae78`, the fixes for the R3 findings. Full context is `git diff 92340eee 6db8ae78`, and origin/main is the pre-#1690 baseline. The earlier briefs are `AUDIT_1690_DELIVERED_ONLY_R2.md` and `_R3.md` in this directory.

## R3 findings and the claimed fixes
1. **The missing-evidence latch carried over to a later attempt, so a delivered retry was refunded.** Now two flags: the ingest-skip latch, reset per attempt in `recordRow`, and `settlementOutputMissingMarked`, set only when a credited row was actually marked (`MarkSettlementOutputMissing` returns bool). Test: `TestMissingEvidenceLatchDoesNotLeakIntoRetry`.
2. **A delivered attempt whose evidence failed** (record or ingest failure, output marked missing, or no tuple by the end of the handler; streaming and non-streaming; hard and transient) goes through `setSettlementEvidenceFailedFinality`.
   - **Enforce route snapshot:** a signed closed refund, and the credit is quarantined (`QuarantineUndeliveredSettlementCredit`), so neither side is paid.
   - **Observe mode or no snapshot:** a signed `legacy` tuple, keeping the #1675 behaviour where both sides are paid.
   - The deferred finalizer now covers streams too, so no negotiated response ends with declared-but-empty trailers.
3. **Gateway MAC declaration check.** `settlementFinalityMACDeclared` now also honours `resp.Trailer` keys, because the Go client transport moves `Trailer` out of `Header`. Real-wire streaming test: `TestStreamingSignedTrailersOverRealWire`.
4. **Negotiation** now requires a non-empty account, the same check the trailer declaration uses.
5. **Both writer wrappers implement `FlushError`.**
6. **The chat-builder source-scan test** resolves constants and path parameters through their call sites.
7. **WS tests** send `X-Request-ID`.
8. **Runbook §9 rollback:**
   - stop buyer traffic with an nginx 503 on `/v1/` and `/auth/`, keeping the gateway up;
   - drain `settlement_hold=1`;
   - pin off;
   - reverse rollback (v2 allowlists, CLI, the gateway if it must go, the coordinator last);
   - for a gateway restore, run the printed recipe without its final `systemctl start` and healthz lines, re-apply the exported rows, then start.

   SPEC-022 R-12.8 matches.

## Carried items: severity and new vs pre-existing
- The gateway periodic reconciler re-queries `coordinator_404_held` forever. This is pre-existing. Can any #1690 path still create one?
- Observe-mode evidence failure: the provider credit stays payable and the buyer is debited (#1675 behaviour, no longer a refund).
- A malformed empty account skips negotiation, and the pin holds it. Normal auth paths always carry an account.

## Check
- **CODE:** correctness of the R3 fixes above, and test adequacy.
- **SECURITY:**
  - the money path, in enforce and observe;
  - quarantine correctness: can a legitimately delivered and verified credit be quarantined?
  - MAC and declaration handling on the real wire;
  - any path that bills undelivered output or gives free delivered output.
- **ARCH:** SPEC-022 v0.2.2, R-12.8, runbook §9 and CONFORMANCE agree with the code; every hold is terminal.

Label PRE-EXISTING issues as such. Report only real defects at their true severity, with file:line. End with `VERDICT: <c> CRITICAL / <h> HIGH / <m> MEDIUM / <l> LOW`.
