# Audit R3 (FINAL): privacy session handshake ordering, posture cadence, SPEC-049 v0.1.2 (SECURITY lane)

METHOD: READ-ONLY first-party review. Go tests under phase4-coordinator (internal/ws, internal/pool, internal/relayblind, internal/buyer) may be run. Do not modify files.

Scope: the FULL combined diff `git -C /Users/augstar/macprovider-posture-order diff origin/main...HEAD` (branch fix/privacy-posture-after-ack, 7 commits 3295329e9..608072f9a). This is round 3 of 3 (final). Report only real defects; the gate is 0 CRITICAL/HIGH/MEDIUM. Round-1 prompts and findings are in audits/2026-10-05-posture-order/AUDIT_POSTURE_ORDER_*_PROMPT.md. Dispositions:
- Round-1 A (keys accepted for a session whose ack write failed asynchronously): no change. The writer closes the conn before onWriteFailure, readProviderLoop then fails, and handleConn's deferred handleDisconnect drops posture for that exact session after acceptance. Verify this reasoning.
- B (sleep-based test): replaced with a challenge-enqueued barrier seam.
- C (ack enqueue failure skipped teardown): the handlers now return IDs so teardown runs.
- D (CONFORMANCE mapping): done.
- E (session routable/writable before ack): fixed. pool.Provider.HandshakeAckPending (json:"-") is excluded from RoutingEligible, and providerSession holds non-control text frames in preAck until sendHandshakeAck.
- F (replaced session's heartbeat revoking the new session's privacy keys): fixed with a current-session check under withProviderSection.
- Heartbeat cadence LOW: fixed. A probe is scheduled only when the advertised key-digest set changes.
- SPEC-049 v0.1.2: R007 item 7 DYLD_* inertness (hardware evidence: the hardened runtime prunes DYLD_* before main on signed 1.8.214), and the R005 cadence clarification.

Hardware evidence: the #1839 journey on the Studio with signed CLI 1.8.214 and this coordinator. The original bug was observed there: a posture challenge before auth_response, the provider handshake abort, and a stale 5s timeout. After the fix: clean first connect on every session.

Check for this lane:
- No frame can precede the handshake ack on either path (v1 hello / v2 auth). Cover every sender: relay/inference, canary, warmup, drains, SE liveness, native MTP, posture, admin. Control frames (ping/close) bypass the hold; check that this is safe for the Swift provider's receiveAuthResponse.
- The preAck buffer: bounds, ordering, backpressure, behaviour when the session closes while frames are held (no leaks, no goroutine blocked, no frame sent after close), and races (writeMu, -race).
- HandshakeAckPending: never persisted or on the wire, and does not leak across reconnect or replacement. The Bearer downgrade guard is preserved. lastKnownFromProvider ignores it correctly. No routing, money-path or settlement behaviour changes other than the pre-ack exclusion.
- F guard: holding withProviderSection across the AcceptPrivacyKeys SQLite write. Check for deadlock or lock-order risk against every other withProviderSection holder, and latency at heartbeat rate.
- Cadence: a session that stops answering still goes stale via the sweep. An explicit empty array still revokes immediately. Rotation still challenges. Quarantine and unapproved-cdhash checks still run on every heartbeat (AcceptPrivacyKeys still called).
- Test seams are nil in production and settable only via export_test.go.
- SPEC-049 v0.1.2 text is accurate and does not weaken R007 for non-hardened builds (items 4/5 and R006/R007 still refuse those). Changelog, CONFORMANCE.json, specs/README.md and the journey doc are consistent. Governance validators pass.
- Conformance-frozen bodies (handleHeartbeat, writeError) are untouched.

Lane: SECURITY. Report findings by severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), each with file:line, the condition, and a fix. Attribute each as NEW (introduced by this branch) or PRE-EXISTING.
End with exactly one line: VERDICT: <n> CRITICAL / <n> HIGH / <n> MEDIUM / <n> LOW / <n> INFO

Round-2 dispositions (commits fc36be40c and 608072f9a):
- **Pre-ack sessions binding relay-blind/privacy reservations (MEDIUM): fixed** with `relayBlindBindable` (ServingCapable && !HandshakeAckPending), applied in `selectRelayBlindProvider`, `handleRelayBlindConsume`, `privacyGate` and `selectPrivacyProvider`.
  - `ServingCapable` itself is untouched. Its body is bound by conformant SPEC-032-R001 signed journey evidence (`c3e8ef2f`).
  - Other ServingCapable callers are unchanged. Their frames are still held behind the ack at the session level.
  - Verify there is no remaining binding path.
- **R005 cadence wording (MEDIUM): fixed.** Periodic sweep challenges are mandatory, a key change also triggers an immediate challenge, and an unchanged heartbeat triggers no extra challenge.
- **Rotation at capacity (MEDIUM, pre-existing): carried as store design.**
  - The capacity count includes revoked-but-unexpired rows (`relayblind/store.go` ~290). Those rows are kept for replay protection until key expiry (~384-387).
  - Reordering revoke and upsert frees no capacity.
  - Only a provider already advertising the maximum number of live keys hits this.
  - Do not re-raise it unless you show a privacy/routing correctness consequence beyond delayed rotation.
- **Direct sweep test (LOW): added.**
- **Spec rationale (LOW): fixed.**
- **Last-known snapshot written pre-ack (LOW): fixed.** The registration snapshot is now non-routable, and `releaseAckedSession` re-persists it after the ack.
- **Carried LOWs:**
  - The 250ms barrier escape in one handshake test.
  - `withProviderSection` held across `AcceptPrivacyKeys` (measured about 412µs per heartbeat).
  - Close-before-ack (pre-existing; Swift-safe).
