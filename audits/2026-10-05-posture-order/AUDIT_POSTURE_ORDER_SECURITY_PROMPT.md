# Audit: SPEC-049 posture challenge must follow the handshake ack, SECURITY lane

METHOD: READ-ONLY first-party review. Go tests under phase4-coordinator/internal/ws may be run. Do not modify files.

Scope: `git -C /Users/augstar/macprovider-posture-order diff origin/main...HEAD -- phase4-coordinator` (branch fix/privacy-posture-after-ack, commit 3295329e9).

Defect being fixed (verified on hardware, #1839 journey): `acceptPrivacyKeyRecords` ran before the handshake ack (`hello_ack` in handleV1Conn, `auth_response` v2 in handleV2Conn) was enqueued. It schedules a posture probe goroutine that `session.send`s a `privacy_posture_challenge` on the same FIFO writer. The provider (phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift receiveAuthResponse) requires the ack as the next frame, so it aborted the handshake and reconnected. Three in a row trip its fatal auth watchdog. The fix moves `acceptPrivacyKeyRecords` after a successful ack send on both paths, adds a nil-in-production test seam `beforeHandshakeAckSend`, and adds privacy_posture_handshake_test.go.

Authority: specs/SPEC-049-*.md (R005, R017: a missed posture response makes the provider ineligible without quarantine), SPEC-001 handshake framing, AGENTS.md.

Check:
- No frame other than the ack can precede it on either path, including via the periodic sweep (runPrivacyPostureSweep) or heartbeat key acceptance.
- Nothing between the old and new call site depends on privacy keys being accepted (routing, eligibility, warmup gate, AuthResponse population).
- Ack-send failure leaves no accepted privacy keys for the dead session. Session teardown (dropPrivacyPosture) still runs correctly.
- The test seam cannot be set in production. Tests fail on the old ordering and are not flaky.
- CONFORMANCE.json mappings (handleV2Conn under SPEC-008-R001 / SPEC-042-R010) are not broken.
- Out of scope but report if relevant: acceptHeartbeatPrivacyKeys schedules a probe on every heartbeat with records (known, carried as LOW).

Lane: SECURITY. Report findings by severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), each with file:line, the condition, and a fix. Attribute each as NEW or PRE-EXISTING.
End with exactly one line: VERDICT: <n> CRITICAL / <n> HIGH / <n> MEDIUM / <n> LOW / <n> INFO
