## Summary

**Architecture gate: FAIL — 3 MEDIUM, 1 LOW.** The principal runtime validators implement structural expiry, but agreement renewal and native-MTP evidence validation retain calendar dependencies. Discovery renewal removal also leaves a mixed-version recovery gap.

## Analysis

1. **MEDIUM — Agreement renewal still pauses a live pool after grace ends.**
   At [creator_selfserve.go:543](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/trustpool/creator_selfserve.go:543), renewal uses `ValidFor`, which includes Agreement expiry, then writes `LifecyclePaused` at line 557. Meanwhile, the changed routing path uses `RoutingInvalidReason` and keeps the same pool routing after grace ([durable_store.go:3534](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/trustpool/durable_store.go:3534)).
   **Failure scenario:** a pool continues serving after grace, but accepting an unchanged Agreement renewal automatically interrupts it and requires promotion again. This contradicts the amended routing guarantee; SPEC-043 itself retains the conflicting renewal-pause requirement at line 91.
   **Fix:** use routing validity when deciding whether renewal requires a pause; remove the grace-only pause requirement and update its existing regression test. The pause machinery is **pre-existing**, but now interrupts traffic that this diff intentionally preserves.

2. **MEDIUM — Native-MTP journey evidence still expires during governance validation.**
   [native_mtp_journey_evidence.py:487](/Users/augstar/macprovider-no-expiry/scripts/native_mtp_journey_evidence.py:487) rejects evidence once `now >= expires_at`. Both payload construction and signed-payload validation call this validator; governance invokes it at [check_spec_governance.py:4410](/Users/augstar/macprovider-no-expiry/scripts/check_spec_governance.py:4410).
   **Failure scenario:** unchanged, correctly signed serving evidence becomes unusable solely through age, despite amended SPEC-048 permitting reuse until decode-path inputs change.
   **Fix:** remove wall-clock rejection from evidence consumption, retain structural ordering and all binding checks, and change the existing expiry regression to assert continued acceptance. This validator is **pre-existing** and remains inconsistent with the new contract.

3. **MEDIUM — Discovery retirement removes the supported same-target recovery path for older CLIs.**
   The diff deletes the renewal workflow, its ops entrypoint, and sequence/target-selection helpers. The remaining rollout downloads the release’s existing head ([verify-live-coordinator-release-rollout.yml:126](/Users/augstar/macprovider-no-expiry/.github/workflows/verify-live-coordinator-release-rollout.yml:126)) and republishes its existing sequence at line 175; it cannot restamp it. Publication verification still rejects an expired head ([verify-release-discovery-transport.py:192](/Users/augstar/macprovider-no-expiry/scripts/verify-release-discovery-transport.py:192)), as intended for mixed-version compatibility.
   **Failure scenario:** an older, disconnected CLI returns after the newest head’s seven-day window and cannot discover the upgraded CLI. Redispatching rollout cannot renew that head. No live fleet state was checked.
   **Fix:** retain a supported, on-demand same-target renewal step under `scripts/ops/cli-release.sh`, preserving immutable publication, sequence ceilings, and signed policy. Document bridge deployment before the last compatible head expires; keep scheduled renewal deleted.

4. **LOW — SPEC-049 overstates withdrawal by removing an approval entry.**
   [SPEC-049:423](/Users/augstar/macprovider-no-expiry/specs/SPEC-049-operator-constrained-privacy-class.md:423) says removal withdraws approval. However, without a matching configuration entry, [privacy_authority.go:794](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/relayblind/privacy_authority.go:794) falls back to release-derived identities.
   **Failure scenario:** removing an entry leaves the identity approved by release metadata.
   **Fix:** qualify removal as withdrawal only when no release-derived approval exists; document the version-mismatch override or deny list for release-backed identities. The fallback is **pre-existing**; the misleading withdrawal statement is introduced here.

## Root Cause

The policy change reaches primary validators but not every lifecycle transition, evidence consumer, or compatibility operation. Those secondary paths still embody the former expiry model.

## Recommendations

Address findings 1–3 before approval. Correct finding 4’s normative wording without changing approval precedence.

## Trade-offs

| Change | Benefit | Cost |
|---|---|---|
| Preserve routing through renewal | Removes grace-driven interruption | Genuine authorization changes still need explicit checks |
| Accept aged journey evidence | Matches evidence-reuse policy | Binding and decode-path checks remain essential |
| Keep manual discovery renewal | Preserves older-client recovery | Retains a small operational signing surface |

## References and validation

- Existing `ServingEvidenceTest.test_expired_evidence_fails`: **PASS**, confirming the retained expiry rejection.
- `bash scripts/test-renew-autotune-static-feed.sh`: **PASS**.
- Targeted `TestSelfServeRenewalAfterGracePausesActivePools`: **blocked before execution** — local Go 1.26.4; module requires 1.26.6.
- No files edited, custom inputs authored, or network hosts contacted.

C/H/M/L = 0/0/3/1
