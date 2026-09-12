# SPEC-047 v0.1.9 — offer_rejected reconciliation audit (2026-09-12)

Change: reconcile the `offer_rejected` state (stated unreachable since v0.1.5, no coordinator origin appends it) with SPEC-047-R001 and the JOURNEY-NETWORK-MODEL-ADMISSION evidence contract. Prompted by #1486 (slice-7 capture) where the contributor found the journey required proving a rejected→re-offer path the coordinator cannot produce.

Three codex lanes over `AUDIT_SPEC047_OFFER_REJECTED_PROMPT.md`.

| Lane | R1 C/H/M/L | R2 C/H/M/L |
|---|---|---|
| code-reviewer | 0/0/2/2 | 0/0/0/L |
| security-reviewer | 0/0/1/2 | 0/0/0/0 |
| architect | 0/1/1/0 | 0/0/0/0 |

All three lanes independently CONFIRMED the reachability premise: operator decisions whitelist only the five non-rejected targets, failed synthetic probes append `revoked` (not `offer_rejected`), and no provider/coordinator append helper targets `offer_rejected`. The reconciliation direction (mark reserved/unreachable, drop the unprovable journey observation) is correct.

R1 findings (all "adjacent file missed", fixed in `8d06f229`):
- HIGH (arch) / MEDIUM (sec): `journeys/JOURNEY-NETWORK-MODEL-ADMISSION.md` step 11 + observation list still required the rejected path and `rejected_reoffer_required_fresh_evidence` — updated to keep only the reachable withdrawn/revoked re-entry proofs.
- MEDIUM (code/sec): the admission fixture's step-03 capture asserted a coordinator `offer_rejected` status — replaced with a `local_default` opaque-endpoint refusal (capture renamed, step assertion corrected), which also fixes a pre-existing mislabel (an opaque endpoint is refused by the CLI builder before coordinator contact).
- MEDIUM (code): SPEC-047 embedded JSON metadata version still 0.1.8 → 0.1.9.
- LOW: changelog spelled out `withdrawn_reoffer_required_fresh_evidence`; CONFORMANCE gap rationale notes v0.1.9.

R2: 0 C / 0 H / 0 M on all three lanes. Bar met.

The R001/R006 fresh-evidence-on-re-entry invariant remains proven by the reachable `withdrawn` and `revoked` re-entry observations; `offer_rejected` stays in the closed enum (SPEC-044/SPEC-046/transition map) for wire compatibility, reserved and unreachable in v0.2.
