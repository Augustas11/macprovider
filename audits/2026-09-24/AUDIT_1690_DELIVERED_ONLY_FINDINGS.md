# #1690 delivered-only billing: audit findings and resolutions (R1-R4)

This record covers the audit of delivered-only non-streaming billing and its
negotiated, signed settlement finality. The fixes sit on branch
`bench/1690-loopback-vs-native`, starting at `00cb36fd` (R1 brief:
`AUDIT_1690_DELIVERED_ONLY.md`).

- Each round ran three codex lanes (CODE, SECURITY, ARCH) and one
  independent reviewer.
- The round briefs are `AUDIT_1690_DELIVERED_ONLY_R2.md`, `_R3.md` and
  `_R4.md` in this directory.
- Auditing was capped after R4; the remaining work is e2e testing.

Status is one of:

- **FIXED**, with the fixing commit;
- **CARRIED**, with a rationale. These items go into the PR body.

## R1 (on 00cb36fd; delivered-only billing 6d48d9cc, runbook b6972f0d)

| # | Sev | Finding | Status |
|---|-----|---------|--------|
| F1 | HIGH | Non-streaming missing or stripped trailers failed open to a legacy debit. | FIXED f07b8cc4: declared-but-missing trailers hold as `missing_settlement_finality_trailer`. |
| F2 | HIGH | Mixed-version unsafe both ways; the runbook contradicted SPEC-022 R-12.8. | FIXED f07b8cc4 (per-request negotiation `X-MacProvider-Internal-Settlement-Trailers`) and 9258a60b (coordinator-first rollout). The v14 claim is correct: origin/main and Pearl v1.8.193 have max schema 13. |
| F3 | HIGH | Rotation-grace key accepted on the hot path but not in final verification. | FIXED df46a2fb: current key only everywhere (SPEC-022 R-4.4.1, SPEC-015 §7.5 step 7). |
| F4 | HIGH | Settlement trailers unauthenticated. | FIXED f07b8cc4: HMAC-SHA256 finality MAC keyed by the gateway service token. |
| F5 | MEDIUM | Post-delivery log failure left no explicit outcome. | FIXED f07b8cc4 as a hold tuple; replaced by a terminal outcome in 223dade4 and 29565281. |
| R1+ | MEDIUM | Strip-everything downgrade (declaration and values both removed). | FIXED ac0731b5: gateway pin `coordinator.require_settlement_trailers`. |

## R2 (on ac0731b5)

| # | Sev | Finding | Status |
|---|-----|---------|--------|
| HIGH | HIGH | With the pin on, a 200 with no route snapshot was held forever (404, and the hold never expired). | FIXED 223dade4: every negotiated 200 carries a signed tuple, `legacy` without a snapshot. |
| M1 | MEDIUM | The record-failure hold could never resolve. | FIXED 223dade4, then 29565281 (enforce/observe rule). |
| M2 | MEDIUM | Gateway rollback could erase holds and ledger writes. | FIXED cb456731, 537d397c, 3bf14ae3, 6e77dc97 (drain, export and re-apply; stop traffic first). |
| L1 | LOW | MAC key not trimmed on the gateway. | FIXED 223dade4 |
| L2 | LOW | MAC did not bind the coordinator internal request id. | FIXED 223dade4 |
| L3 | LOW | No real-wire trailer test. | FIXED 223dade4 |
| CODE H2 | HIGH | Transient output loss sent a signed `legacy` tuple while the provider evidence was missing. | FIXED f8b63813, then 29565281 and cab2fb0b. |
| CODE M3 | MEDIUM | Relay-blind requests did not negotiate. | FIXED f8b63813: `setCoordinatorChatContext` plus a source-scan test. |
| ARCH H1 | HIGH | Rollback could erase unresolved holds. | FIXED 537d397c (the script only prints the restore recipe; drain and export come first). |
| ARCH M2 | MEDIUM | WS with no snapshot was held forever. | FIXED 537d397c (test; code already correct at f8b63813). |
| ARCH M3 | MEDIUM | Pin turned off under live traffic during rollback. | FIXED 537d397c: stop traffic, drain, pin off, roll back, resume. |
| ARCH L4 | LOW | CONFORMANCE traceability missing. | FIXED 537d397c |

## R3 (on 537d397c)

| # | Sev | Finding | Status |
|---|-----|---------|--------|
| M1 | MEDIUM | Missing-evidence latch leaked into a later attempt. | FIXED 29565281: reset per attempt, plus a retry test. |
| M2 | MEDIUM | Refunding in observe mode lost revenue (the provider is paid while the buyer is refunded). | FIXED 29565281: refund only in enforce mode (credit quarantined); observe gets the signed `legacy` tuple. |
| M3 | MEDIUM | Runbook ran the recipe's start line while `reconcile_enabled` cannot be turned off. | FIXED 3bf14ae3 |
| L1 | LOW | Negotiation did not require an account. | FIXED 29565281 |
| L2 | LOW | Writer wrappers hid flush errors. | FIXED 29565281 (`FlushError`) |
| L3 | LOW | Stream post-record failure was left without a tuple. | FIXED 29565281 |
| L4 | LOW | Source-scan test was too narrow. | FIXED 29565281, hardened in cab2fb0b (allowlist). |
| L5 | LOW | WS MAC tests used an empty request id. | FIXED 29565281 |
| L6 | LOW | Rollback traffic stop could take the gateway down. | FIXED 3bf14ae3, 6e77dc97 (nginx 503, gateway stays up). |
| CODE M | MEDIUM | MAC declaration missed on a real client response (`resp.Trailer` keys). | FIXED 6db8ae78, plus a real-wire streaming test. |
| SEC | HIGH | Hard settlement-output failure on a stream. | FIXED 29565281; test in 6db8ae78. The finalizer covers streams. |

## R4 (on 6db8ae78)

| # | Sev | Finding | Status |
|---|-----|---------|--------|
| M-A | MEDIUM | A failed mark led to a `legacy` debit of an unpayable credit. | FIXED cab2fb0b |
| M-B | MEDIUM | A v13 gateway cannot re-apply `pool_operator_attested` rows. | FIXED 6e77dc97: pre-check; rollback forbidden when any such row exists. |
| L1 | LOW | Store-pressure enforce mode was undocumented. | FIXED 6e77dc97 (SPEC wording) |
| L2 | LOW | Refund lived only in the trailer, so the lookup could 404. | FIXED cab2fb0b (quarantined-credit lookup) and 551fd876 (enforce credit without evidence, including no-snapshot credits). |
| L3 | LOW | Finalizer could quarantine an earlier attempt's credit. | FIXED cab2fb0b |
| L4 | LOW | Unresolved request URLs not flagged. | FIXED cab2fb0b (allowlist) |
| L5 | LOW | nginx block list incomplete; no curl check. | FIXED 6e77dc97 |
| L6 | LOW | Rollback did not stop the gateway before export; restore inputs not named exactly. | FIXED 6e77dc97 |
| L7 | LOW | Stale comments. | FIXED cab2fb0b |
| L8 | LOW | Retry test assertions too weak. | FIXED cab2fb0b |
| Q | - | Finalizer on non-200 responses. | FIXED cab2fb0b: 200 only; the gateway settles a non-200 from headers. |
| CODE H | HIGH | Refund could disagree with the quarantine; a verified credit could be quarantined. | FIXED 97bbf2ac: verified guard, bounded retries, decision table. |
| CODE M | MEDIUM | A MAC-only declaration downgraded to legacy. | FIXED 97bbf2ac |
| SEC H | HIGH | An enforce refund whose trailer is lost could 404 forever. | FIXED 551fd876 |

R4 codex ARCH lane (on 6db8ae78), recorded after the round: 0 CRITICAL,
0 HIGH, 2 MEDIUM. Both MEDIUMs were already fixed on the branch by then, one
by `cab2fb0b` and one by `551fd876`; no further change.

## Carried (in the PR body)

1. **The gateway periodic reconciler re-queries `coordinator_404_held` forever.** PRE-EXISTING; there is no terminal state for a 404 hold.
   - Nudges are bounded to four attempts; the periodic sweep is not.
   - #1690 no longer creates such holds for negotiated attempts: every negotiated 200 has signed finality, and the lookup is terminal for enforce credits without evidence.
   - Giving a 404 hold a terminal state is a money-policy change outside this PR.
2. **Enforce store pressure leads to a signed `legacy` tuple and a local buyer debit while the enforce credit is unpayable.** PRE-EXISTING (`route_snapshot.go` store-pressure skip, outside #1690).
   - 551fd876 does not change it: the gateway debits locally from the `legacy` tuple without consulting the lookup.
3. **Observe-mode evidence failure pays both sides.** This is #1675 behaviour, kept on purpose: the buyer is debited locally and the provider credit stays payable, with an error log for operator review.
4. **Empty-account stamping gap.** The chat proxy stamps the bearer and capability only for a non-empty `subject.AccountID`, so under the pin such a 200 would be held.
   - Every authenticated and demo subject carries an account, so no path is known.
   - This is not proven exhaustively.
5. **Pearl live nginx not checked.** The runbook's list of locations to 503 comes from the repo's `nginx-api.malibu.tech.conf`. Operators must confirm it against the live config with the `grep -l 9443` step.
6. **Unsigned streaming finality with the pin off.** PRE-EXISTING. An older coordinator's unsigned streaming trailers are still accepted when no MAC is declared. The pin closes this once both sides are deployed.
