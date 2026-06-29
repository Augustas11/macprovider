# Audit: ISS-231 R1 architect lens

SPEC-007 v0.4 closes R2 architect lane deferrals from PR #221.
Tree: `spec/iss-231-spec-007-v04`.

## What I want (architect lens)

Find **DESIGN DEFECTS**: SPEC↔IMPL drift, missing authority sites,
cross-spec contracts forgotten, observability gaps.

1. **§7.1-equivalent gap**: SPEC-007 doesn't have a centralized
   §7.1 events table like SPEC-016. The new
   `payout_explorer_path_segment_untyped` audit/log event lives
   in §6.4 + §5.6 prose only. Is that the right place, or does
   the audit event need a separate `## Events` section? Will an
   alert filter (BetterStack equivalent) catch the new event
   names by convention?
2. **v0.5 break commitment**: the SPEC promises v0.5 will reject
   untyped with 400. Is there a tracking issue / Appendix
   pointer / timeline for that break? Is the deprecation window
   length defined ("v0.4 ships, v0.5 cuts" — is that 1 quarter,
   1 release, or unspecified)?
3. **Cap=10 magic number**: stable across both SPEC (§6.4) and
   IMPL (storage.ExplorerMatchedAccountIDsCap). Is cap=10
   justified, or should it be operator-configurable like the
   §5.6 max_rows? Could a future SPEC version need to tune it?
4. **`matched_account_ids_truncated` field presence contract**:
   SPEC says "the field MUST be present and `false` on the
   non-truncated path." Does the JSON `omitempty` tag in
   ExplorerSessionDetail break this contract? (Look at
   `matched_account_ids_truncated bool json:",omitempty"`.)
5. **Forensic audit emit semantics**: the unbounded SELECT for
   forensic capture only fires on truncation. What if a 409
   fires WITHOUT truncation but with a notable number of
   accounts (e.g. 9 — just below cap)? Should there be a
   counter / gauge for "near-cap" 409s?
6. **§5.6 + §6.4 IMPL parity asymmetry**: coordinator emits via
   stdlib `log` (stderr / journald); gateway emits via
   `InsertAuditEvent` (DB row). Both are operator-visible but
   via different channels. Documented? Operator runbook
   coherent across both?
7. **Cross-spec**: any SPEC-002/005/006/014/019 dependency on
   `matched_account_ids` field shape that the cap breaks?

Severity + Convergence line.
