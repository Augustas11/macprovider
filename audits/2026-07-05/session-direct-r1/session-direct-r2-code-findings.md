# Session direct-push R2 — CODE lane findings

## Verdict
FAIL

## Findings
### CODE-R2-M-1 (MEDIUM) Cascading SIGTERM re-enters the CLI signal source
- File: phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift:46
- Evidence: The cascade handlers call `Darwin.killpg(0, SIGTERM)` from inside the SIGINT/SIGTERM dispatch source handlers. Because `killpg(0, SIGTERM)` also targets the current process group leader, the CLI receives its own cascaded SIGTERM. The code assumes `signal(SIGTERM, SIG_IGN)` swallows that re-fire, but a local minimal Swift reproduction using the same pattern (`DispatchSource.makeSignalSource`, `signal(SIGTERM, SIG_IGN)`, `setpgid(0,0)`, then `killpg(0, SIGTERM)` inside the handler) printed `handler 1`, `handler 2`, `handler 3`, `handler 4`, confirming the dispatch source is re-entered by the self-sent SIGTERM. In the real CLI this can create a shutdown signal storm until process exit instead of a single cascade.
- Recommendation: Make the cascade one-shot per `AutotuneSignalSources` instance, for example with an `NSLock`-guarded `didCascade`/compare-and-set helper shared by both handlers. Add a focused regression test that installs the signal source in an isolated subprocess/process group, sends one SIGTERM, and asserts the cascade side effect runs once rather than recursively.

### CODE-R2-L-1 (LOW) No test exercises the real cascade handler path
- File: phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift:1466
- Evidence: The new benchmarker test proves an already-set interrupt flag stops fresh probes, and the App-side tests prove direct child termination/escalation. They do not exercise `AutotuneSignalSources(cascadeToProcessGroup: true)` delivering a signal to a process group. The existing helper test explicitly notes it is "Not a substitute for an end-to-end signal-cascade test", and the missing test is why the self-reentry bug above was not caught.
- Recommendation: Add a subprocess-based cascade test that makes the test child a process-group leader, installs the cascade handler, spawns a grandchild, sends SIGTERM to the child, and verifies both one-shot cascade behavior and grandchild teardown.

## Review Notes
I traced the SEC-M-1 validator branches, `postRegister` persistence boundary, new Equatable enum shape, benchmarker interrupt threading, App-side subtree termination helper, and new tests. The coordinator URL validator branches matched the requested cases: uppercase base schemes are normalized with `lowercased()`, default HTTPS/WSS ports align, bare-host WebSocket URLs have an empty path and are rejected while `"/"` is accepted, and `wss://attacker@host/path` parses `attacker` into `URL.user`. `postRegister` validates immediately after decode and before callers persist the returned provider token/WS URL.

Validation run:
- `swift -e` URL parsing probe: confirmed scheme/user/path assumptions.
- `swift test --package-path phase3-binary --filter AutotuneRecommendTests/testBenchmarksBreaksBetweenCandidatesWhenInterruptFlagIsSet`: passed, 1 test.
- `xcodebuild test -project phase3-binary/app/Malibu.xcodeproj -scheme Malibu -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:MalibuTests/RegisterClientTests -only-testing:MalibuTests/AutotuneRecommendationRunnerTimeoutTests`: passed, 19 tests.
- `swift test --package-path phase3-binary --filter RegisterClientTests/testValidateCoordinatorWSURL` and `--filter AutotuneRecommendationRunnerTimeoutTests` ran 0 tests because those app tests are not SwiftPM targets in this repo.
