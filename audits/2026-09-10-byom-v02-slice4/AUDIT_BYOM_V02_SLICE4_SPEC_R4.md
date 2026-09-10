# SPEC audit R4 — BYOM v0.2 slice 4 (SPEC-047 v0.1.5) — anchored loop closed

**Diff reviewed:** `git diff origin/main -- specs/` at `0a6b60a7` (R3 fixes). Lanes: code-reviewer + architect (security at bar since R3). **Bar:** 0 C / 0 H / 0 M.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 C / 0 H / 2 M |
| architect | 0 C / 1 H / 1 M / 1 L |

Resolved in the commit that adds this record:
- **HIGH (architect): a feed-member settlement combined row-signed Tier-2 material with the member pair.** Stated as the composite proof it already is in the slice-3 implementation: Tier-2 material proves the ROW binding (catalog identity, body digest, signer, the row's own digest = primary member); the member's hash is proven only by its recorded six values; neither half may be read as the other. SPEC-047-R003(iii) says so; SPEC-010 gains a v1.8 R004 clarification (bundled; no behaviour change).
- **MEDIUM (architect): replacement hello was not a drift trigger.** R006(a)/(d) now include hello (initial or replacement), evaluated inside the critical section against the prior binding BEFORE the incoming session's binding is published; R008 covers it.
- **MEDIUM (code): `offer_rejected` had no origin.** Offer-validator origin `offer_submitted → offer_rejected` with reserved `offer_validation_` reasons; the probe origin lists `revoked` (what the code does) instead of `offer_rejected`.
- **MEDIUM (code): row-bound decisions did not bind the session's exact release.** The offer event records the release its row was read from (`catalog_release_id`, `catalog_candidate_sha256`, `catalog_signer_key_id`); R003(iv) and route time require the session's admitted release tuple to equal it (`catalog_release_mismatch`); a rotated release requires a fresh offer — stated as an operational consequence in §4 and the change log.
- **LOW (architect): summaries omitted receipt-key drift** — §4 step 9 and the change log updated.

**Loop status:** four anchored rounds (R1 3H/10M → R2 1H/5M → R3 1H/7M → R4 1H/3M). Per the standing rule the anchored loop stops here; the SPEC now goes to an independent cold-context review (three reviewer lanes, neutral prompt) before implementation. Any findings there are fixed and closed with ONE codex pass over the affected lanes.
