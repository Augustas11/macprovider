# Session direct-push R2 — SECURITY lane findings

## Verdict
PASS

No CRITICAL, HIGH, or MEDIUM security findings. I checked the SEC-M-1 token-exfiltration path from a tampered `/v1/providers/register` response through App persistence and later CLI WebSocket auth; the R2 validation now enforces the security-relevant origin tuple (scheme, host, port) before any `RegisterResponse` reaches `saveProviderIdentity`. I also checked the ARCH-M-1 process-group/signal cascade for confidentiality expansion, signal loops, process-group pollution, child signal disposition, PID-reuse blast radius, and new debug output. The remaining issues are defense-in-depth/test-coverage gaps only.

## Findings
### SEC-R2-C-1 (CRITICAL) None
- File: n/a
- Threat model: n/a
- Evidence: No critical issue found in the reviewed R2 security scope.
- Recommendation: n/a

### SEC-R2-H-1 (HIGH) None
- File: n/a
- Threat model: n/a
- Evidence: No high-severity issue found in the reviewed R2 security scope.
- Recommendation: n/a

### SEC-R2-M-1 (MEDIUM) None
- File: n/a
- Threat model: n/a
- Evidence: No medium-severity issue found in the reviewed R2 security scope.
- Recommendation: n/a

### SEC-R2-L-1 (LOW) WebSocket path is only non-empty, not exact-pinned
- File: phase3-binary/app/Sources/Malibu/System/RegisterClient.swift:218
- Threat model: A network attacker who can tamper with the register response but must still pass same-origin validation can choose an arbitrary non-empty same-origin path such as `wss://coordinator.streamvc.live/somewhere-else`.
- Evidence: `validateCoordinatorWSURL` rejects scheme/host/port/userinfo/empty path, but it does not require `/v2/provider`. Coordinator production config returns `wss://<domain>/v2/provider` in `phase4-coordinator/cmd/coordinator/main.go:647`; nginx has an exact `/v2/provider` route to `/ws/provider` in `phase4-coordinator/dist/nginx-coordinator.streamvc.live.conf:126`. Because the origin remains the coordinator origin, this does not recreate SEC-M-1 token exfiltration to an attacker origin. The residual impact is fail-closed connection failure or accidental same-origin handler exposure.
- Recommendation: Pin the path to `/v2/provider` unless there is an intentional migration story for alternate provider WebSocket paths. If migration flexibility is needed, use an explicit allowlist.

### SEC-R2-L-2 (LOW) Config writer still interpolates YAML scalars directly
- File: phase3-binary/app/Sources/Malibu/System/ProviderConfig.swift:229
- Threat model: A tampered or compromised register response controls `provider_id` and `coordinator_ws_url` fields passed to `saveProviderIdentity`.
- Evidence: The writer preserves strong file mechanics around the config write: app-owned collision guard at lines 203-209, token remains in Keychain rather than config at lines 232-236, `.atomic` write plus `0600` chmod at lines 239-241, and the lower-level `atomicWrite0600` helper uses `O_NOFOLLOW`, `O_EXCL`, `fchmod(0600)`, `fsync`, and `rename` at lines 792-809. However, `provider_id` and `coordinator_url` are written as unquoted interpolated YAML scalars at lines 229-230. The honest coordinator returns canonical `req.ProviderID` and a fixed WS URL, but this persistence layer is not a complete independent escaping boundary.
- Recommendation: Add a small YAML scalar renderer or reject control characters/newlines in persisted scalar fields. Also validate `response.providerID == requestBody.providerID` before saving, so response tampering cannot steer Keychain/config identity state even for fail-closed cases.

### SEC-R2-I-1 (INFO) SEC-M-1 same-origin validation closes the bearer-token exfiltration path
- File: phase3-binary/app/Sources/Malibu/System/RegisterClient.swift:179
- Threat model: A response tamperer substitutes an attacker-controlled `coordinator_ws_url`; later the CLI sends `Authorization: Bearer <provider_token>` on WebSocket connect.
- Evidence: `postRegister` decodes the response, validates `coordinatorWebSocketURL`, and returns only after validation at lines 179-181. The launch controller persists only after `registerProvider` returns at `phase3-binary/app/Sources/Malibu/Onboarding/LaunchProviderController.swift:256` and the resume-registration path follows the same order at line 385. The validator lowercases scheme/host, maps `https -> wss` and `http -> ws`, compares host, applies default 443/80 ports, rejects userinfo, and requires a path at lines 188-223. Local Foundation checks showed uppercase `WSS://COORDINATOR...` parses and passes after lowercasing, while Unicode homoglyph hosts are exposed as different punycode hosts and do not match the ASCII expected host.
- Recommendation: Keep this validation at the `postRegister` boundary. Add an integration-style test that `postRegister` throws and returns no `RegisterResponse` when validation fails.

### SEC-R2-I-2 (INFO) TLS trust remains standard system-CA trust, not certificate pinning
- File: phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:33
- Threat model: A compromised CA or locally trusted malicious root intercepts the later `wss://coordinator.streamvc.live/...` connection even after URL validation accepts the correct origin.
- Evidence: The provider WebSocket uses a normal `URLSessionConfiguration.default` session with a redirect-denying delegate, not a pinning delegate. This is outside the URL-string validator's scope: the validator controls what URL is persisted, not the TLS trust decision or the actual network route after DNS/TCP/TLS.
- Recommendation: Treat certificate pinning as a separate product/security decision. Do not count it as part of SEC-M-1 closure unless a future requirement explicitly calls for pinning.

### SEC-R2-I-3 (INFO) ARCH-M-1 signal cascade does not expand confidentiality surface
- File: phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift:46
- Threat model: Same-EUID local process sends SIGTERM/SIGINT to the CLI and triggers cascade to its autotune subtree.
- Evidence: The new handler sets an interrupt flag and calls `killpg(0, SIGTERM)` only after `runAutotuneRecommend` first calls `setpgid(0, 0)` at `phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:707`. Same-EUID processes could already directly signal the CLI child or its descendants; the new effect is availability-oriented graceful teardown, not token/key disclosure. Signal-loop risk is controlled because `signal(SIGINT, SIG_IGN)` and `signal(SIGTERM, SIG_IGN)` occur before dispatch sources are resumed at `AutotuneRuntimeSupport.swift:59-63`. App-side teardown uses the `Process` object's still-running child PID and then `killpg(cliPid, SIGKILL)` plus direct `kill(cliPid, SIGKILL)` at `phase3-binary/app/Sources/Malibu/Onboarding/AutotuneRecommendationRunner.swift:192-201`; the child is not reaped until `waitUntilExit`, so normal PID reuse does not make that fallback target an unrelated process while `process.isRunning` is true.
- Recommendation: Keep the cascade restricted to the `--recommend` path and continue using App-side SIGKILL escalation as the hard stop for wedged descendants.

### SEC-R2-I-4 (INFO) `Process` children see default SIGTERM despite parent `SIG_IGN`
- File: phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift:59
- Threat model: If `serve --no-join` inherited the CLI's ignored SIGTERM disposition, the cascade would not gracefully stop the grandchild and App-side SIGKILL would be the only reliable cleanup.
- Evidence: macOS `execve`/`posix_spawn` man pages say ignored signals are inherited unless spawn attributes change that behavior. A local Swift check with parent `signal(SIGTERM, SIG_IGN)` spawning `/bin/sh -c 'kill -TERM $$; ...'` via `Process.run()` exited from SIGTERM (`status=15`, termination reason signal), which confirms Foundation `Process` is resetting SIGTERM to default for this child path on this environment.
- Recommendation: Consider adding an executable regression test for this if future changes replace `Foundation.Process` or spawn children through a lower-level API.

### SEC-R2-I-5 (INFO) Debug-print review found no new secret logging
- File: phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift:752
- Threat model: New URL-validation or signal-cascade code writes bearer tokens, provider IDs, transcript hashes, ECDH keys, or signature bytes to stderr.
- Evidence: Grepping the R2 diffs for `stderr`, `standardError`, `Bearer`, `provider_token`, coordinator URL fields, identity signature material, ECDH, and signature bytes found one new runtime stderr write in the changed signal path: `autotune --recommend interrupted; exiting after subtree cleanup`. It contains no secrets. URL-validation error reasons include scheme/host/port metadata, not bearer tokens.
- Recommendation: Keep interruption logging generic. Avoid dumping full register responses or request headers in future validation failures.

### SEC-R2-I-6 (INFO) Security-relevant tests pass, with coverage gaps worth adding
- File: phase3-binary/app/Tests/MalibuTests/RegisterClientTests.swift:62
- Threat model: Future regressions accidentally weaken origin validation or partial-persistence ordering.
- Evidence: `xcodebuild test -project Malibu.xcodeproj -scheme Malibu -configuration Debug -destination 'platform=macOS' -only-testing:MalibuTests/RegisterClientTests` passed 14 tests. `xcodebuild test ... -only-testing:MalibuTests/AutotuneRecommendationRunnerTimeoutTests` passed 5 tests. `swift test --filter AutotuneRecommendTests/testBenchmarksBreaksBetweenCandidatesWhenInterruptFlagIsSet` passed 1 test. Missing coverage: `postRegister` failure should be tested end-to-end to prove no validated response object returns on bad `coordinator_ws_url`; IDN/punycode mismatch should be pinned; uppercase `WSS://` scheme acceptance should be pinned.
- Recommendation: Add the three focused tests above. They are not required to close SEC-M-1 for R2, but they would make the security contract harder to regress.
