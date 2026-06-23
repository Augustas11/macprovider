# AUDIT_SPEC_015_IMPL_STEP_7_PROMPT

Audit SPEC-015 implementation Step 7, "Key rotation command +
coordinator grace state", against `specs/BUILD_SPEC_015_IMPL_PROMPT.md`
and `specs/SPEC-015-receipts.md`.

Scope:
- `phase3-binary/Sources/macprovider-cli/RotateKeyCommand.swift`
- `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`
- `phase3-binary/Tests/macprovider-cliTests/RotateKeyCommandTests.swift`
- `phase3-binary/Tests/macprovider-cliTests/CoordinatorClientTests.swift`
- `phase4-coordinator/internal/ws/`
- `phase4-coordinator/internal/pool/`
- `/poolz` receipt key publication tests

Required checks:
1. Rotation uses reconnect-with-new-key over the existing v2 auth flow;
   there is no new websocket control frame.
2. The provider commits the candidate Keychain private key only after
   reconnect acceptance and leaves the old key active on rejection.
3. The coordinator publishes `receipt_pubkey_prev` with
   `rotated_at = reconnect acceptance time` and a 7-day expiry.
4. The previous-key acceptance window is documented and test-covered
   with the SPEC-015 AC-11 `rotated_at - 60` slack.
5. Rotation grace state is in-memory only and documented as such.
6. `receipt_rotation_detected` audit events do not leak receipt tuple,
   signature, prompt hash, or output hash material.

Report Critical, High, Medium, and Low findings. The implementation may
not be considered locked until Critical/High/Medium are all zero.
