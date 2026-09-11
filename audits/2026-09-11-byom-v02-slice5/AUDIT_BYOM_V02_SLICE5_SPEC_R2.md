# BYOM v0.2 slice 5 SPEC audit — round 2 (2026-09-11)

Reviewed: `git diff origin/main -- specs/` at `034c9d2e`. Three codex lanes.

| Lane | C | H | M | L | I |
|---|---|---|---|---|---|
| code-reviewer | 0 | 3 | 6 | 2 | 0 |
| security-reviewer | 0 | 0 | 3 | 4 | 0 |
| architect | 0 | 3 | 4 | 3 | 1 |

## Findings and dispositions (fixed in the R2 fix commit unless noted)

- **Committing full intake responses into the public repo defeats the private endpoint** (arch H1): §16.8 rule 9 (renumbered) — sources retained in the operator's PRIVATE intake audit store (`$MACPROVIDER_INTAKE_AUDIT_DIR/<release_id>/`, default under `~/.config/macprovider/`, 0700), never in the repository; generator reads it via `--intake-audit-dir`; record classified as operator attestation; Q17 for coordinator-signed envelopes.
- **Fixed k=3 vs release-tunable `INTAKE_K_ANONYMITY_MIN`** (arch H2, code H): §16.4 fixes the floor at 3 in v0.10.4 (explicit exception; lockstep amendment to change); SPEC-017 carries `k_anonymity_min` in each window's immutable `parameters` and in `fleet_ram`; SPEC-047 emits 3; generator fails closed on any other value.
- **Sanction predicate contradicts SPEC-023/R007; revoked token ≠ sanction; wrong SPEC cited** (arch H3, code H, sec M2): SPEC-047 `provider_intake_sanctioned` redefined as a four-category CURRENT-STATE predicate — route (admission rejection or canary sanction), trust (≥1 hardware-trust root and none active), payout (vacuous until SPEC-016 defines one), registration (revoked SPEC-002 token with no active token) — evaluated at build time so a later-sanctioned provider loses every offer; blacklist explained as transient; unavailability rule (wired source unreadable → no snapshot); SPEC-023 §16.2(b) cites the predicate by name.
- **Unbounded per-request scan; "reads no other table"** (sec M3, code M): materialized snapshot every 15 minutes at startup + cadence, 10 s timeout, 100 000-event ceiling, `intake_unavailable` (503) when absent/stale; GET is constant work; sanction sources named.
- **Differencing/inference on the open window; colluding accounts** (sec M1): only COMPLETE windows are served or persisted; a bucket is emitted only when ≥ k distinct principals AND lower bound ≥ `buyer_request_floor` (stricter than SPEC-023 requires; stated as such).
- **Manifest window nullability vs example; no window for demand-rank-only entries** (code H, arch M1, code M): rule 3 rewritten — unmatched triple non-null exactly when a complete window was selected; top-level `observation_window_*` null when no windowed signal participates.
- **DRAFT/LOCKED contradiction** (arch M2, code M): Status is DRAFT everywhere until the final gate; lock is applied atomically at closure.
- **Undeclared SPEC-023 dependency** (arch M3): header `Depends on: SPEC-023 v0.10.4` (adopted at that version; later edits need a SPEC-017 amendment); CONFORMANCE `depends_on` updated.
- **Fleet activity via leaderboard join allows stale RAM** (arch M4): active = verified profile with `last_reported_at` in the window only.
- **Health example omits `intake`** (code M): example and closed nine-key list updated.
- **"One cadence period" undefined** (code M): 31 days.
- **`eligibility_policy_sha256` dictionary-testable** (sec L4): replaced by random opaque `eligibility_policy_id`.
- **Fleet complementary suppression** (sec L5): when any class is suppressed, the smallest unsuppressed class is suppressed too.
- **Duplicate rule 8** (code L, arch L2): renumbered to 9.
- **Ellipsis placeholders in a closed-schema example** (code L): one complete canonical example.
- **30 uninterrupted days required** (arch L1): stated as an operational availability requirement.
- **Sybil residual** (sec L7): restated honestly in §5.2b.3 (ten colluding funded accounts can clear the floor; SPEC-023 may later require a second clause). Carried.
- **Provenance** (sec L6, arch L3): record is an operator attestation; Q17. Carried.

## Carried
- LOW: coordinator-origin provenance (Q17); Sybil residual (documented).
