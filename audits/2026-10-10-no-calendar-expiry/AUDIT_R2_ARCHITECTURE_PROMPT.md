You are the ARCHITECTURE lane auditor, round 2, for PR #1944.

Method constraint: this is a first-party software-correctness review. Read source and run EXISTING tests only. Do not author or construct malformed payloads or exploit inputs; describe any gap abstractly (field + condition) in prose. Do not edit files and do not contact Pearl, GitHub or any network host.

PR #1944 (Augustas11/macprovider), branch campaign/no-calendar-expiry, checkout /Users/augstar/macprovider-no-expiry. Review the COMPLETE diff `git diff origin/main...HEAD` (10 commits, rebased on current origin/main) and the code it touches.

Context: AGENTS.md rule 10 forbids calendar expiry, automatic withdrawal or automatic kill switches on live features. Issue #1938 makes every signed artifact's expires_at structural only (it must parse and follow issued_at; the wall clock never stops it) and moves withdrawal to supersession/revocation:
1. Tier-2 catalog (coordinator internal/tier2, phase7-verify receipt verifier): no inactivation after expires_at.
2. Native-MTP admission sidecar (Swift NativeMTPAdmissionSidecar.swift): no expiresAt > now, no 90-day cap.
3. Signed release discovery head (SignedReleaseDiscovery.swift): no expires > now / 7-day cap; release_sequence monotonicity, equivocation, future-issued, signed minimum/revocations kept.
4. Build-1 private authority and the live coordinator release gate stop gating on age.
5. Trusted pools (internal/trustpool): on-call confirmation lapse and Creator Agreement grace end become status warnings, not routing cutoffs; routeable_until bounded only by the signed manifest policy window.
6. Autotune hello gate (internal/autotune, ws): drop binary_version equality and the evidence TTL; evidence is superseded when a newer submission reports a different hardware_identity_hash or os_version.
7. SPEC-049: remove optional expires_at on privacy approved_code_identities (config, relayblind, tooling).
8. Delete the scheduled renewal workflows/alarms (discovery head, autotune feed) and discovery-renew.sh.
9. Native-MTP emergency revocation feed (NativeMTPRevocationFeed.swift, buyer/native_mtp_feeds.go) fails to last-known: an aged/unreachable/rejected feed keeps the newest verified revoked set enforced and native MTP on; generation monotonicity, same-generation equivocation, superset, signature, signer, future-issued checks kept; anchorless first fetch accepts any-age verified body (residual recorded in SPEC-023 §12.5); coordinator serves newest issued slot past expiry.
Mixed-version: old CLIs/coordinators still enforce dates; release tooling still signs future expires_at with the old window bounds.
Specs amended: SPEC-008 0.7.1, SPEC-015 0.4.15, SPEC-020 v0.1.22, SPEC-023 v0.22.22, SPEC-032 v0.3.7 (SPEC-032-R002 moved to pending, gap #1938), SPEC-043 0.3.2, SPEC-048 0.1.29, SPEC-049 0.2.4.

Out of scope by operator decision (do not report as findings): adding an OS-change re-benchmark trigger in the CLI; the signed pool manifest policy window; operator-set expiry on hardware trust roots; removing calendar expiry that is a short-lived cryptographic freshness window re-signed automatically by software (privacy key records, posture, directory, AEAD rekey, tokens).

Output: findings with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, failure scenario, fix; say "pre-existing" when the issue is not introduced by this diff. End with the exact line "C/H/M/L = n/n/n/n". Gate: 0 C/H/M.

Lane: ARCHITECTURE. Focus: single source of truth for "structural expiry" across Go/Swift/Python/specs, mixed-version rollout safety and the stated deploy order, consistency between SPECs, coupling between the removed renewal workflows and remaining on-demand tooling, abstraction altitude (new helpers such as RoutingInvalidReason, StatusWarnings, isNetworkFeedFailure), anything that leaves a hidden calendar dependency in live paths touched by this diff.

Round 1 results are in /Users/augstar/macprovider-no-expiry/audits/2026-10-10-no-calendar-expiry/R1_ARCHITECTURE_RESULT.md (and the other two lanes' R1_*_RESULT.md files). Commit dd1d0e9a4 addresses them: evidence supersession ordered by job id; native-MTP journey evidence no age rejection; renewal-after-grace no longer pauses a routing pool (self-serve and operator reactivation gate use RoutingInvalidReason); discovery-head renewal workflow, helpers and discovery-renew.sh restored as on-demand (no schedule, no alarm); SPEC-049 withdrawal wording; catalog-activate revocation step no longer age-based; diagnostics renamed; canary R002 step supersedes evidence; dead RouteableExpired assignments removed; Swift .expired reserved; docs/comments; integration-tagged rewards test import fixed. First state FIXED / NOT FIXED for each round-1 finding in your lane, then report new issues only.
