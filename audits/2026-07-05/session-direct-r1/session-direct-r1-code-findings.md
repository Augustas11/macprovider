# Session direct-push R1 — CODE lane findings

## Verdict
PASS

0 CRITICAL, 0 HIGH, 0 MEDIUM findings in the CODE lane.

I reviewed the six saved patch files plus the current touched source surface for CODE-1 through CODE-9: CLI canonical JSON, auth transcript hashing, identity-signature bridge and control-socket pusher, onboarding timeouts/config persistence, `ready`/`serving` state consumption, and the modified test coverage. Static inspection found no blocking correctness defect. I also ran `swift test --filter 'CoordinatorClientTests/testBinaryVersion_AdvertisesSPEC020V17AcrossHandshakeFrames'` and `swift test --filter 'ControlSocketTests/testEncodeDecodeStatusResponseReady'` from `phase3-binary`; both selected package tests passed.

## Findings

### CODE-L-1 (LOW) Identity-signature bridge and actor-bypass path lack direct regression coverage
- File: `phase3-binary/Sources/macprovider-cli/ControlSocket.swift:643`
- Category: test coverage / concurrency
- Evidence: The production fix now depends on a detached pusher writing directly to the captured fd:
  ```swift
  pusherTask = Task.detached(priority: .userInitiated) {
      for await request in stream {
          try? Self.writeFrameDirect(fd: capturedFD, frame: .identitySignatureRequest(...))
      }
  }
  ```
  `writeFrameDirect` loops partial writes and handles `EINTR` at `ControlSocket.swift:590`, and handler exit cancels the pusher plus unsubscribes at `ControlSocket.swift:658`. However, the current tests only cover normal control-socket codec/status behavior (`ControlSocketTests.testEncodeDecodeStatusResponseReady`) and app-side identity frame codec shape (`ControlFrameCodecTests.testIdentitySignatureRequestRoundTrip`). There is no test that proves a bridge request is pushed while `receive(timeout:)` is blocked, no fd-close-mid-stream test, and no `CoordinatorClient` test that injects a fake `IdentitySignatureBridge` and verifies proof fields are populated.
- Impact: A future change could reintroduce the original actor deadlock, break detached pusher cancellation, or silently omit identity-signature proof fields while the existing tests still pass.
- Recommendation: Add a CLI-side integration test using a connected Unix socket or `socketpair`: start `ControlSocketServer` with an `IdentitySignatureBridge`, leave the main receive loop idle, call `requestSignature`, assert the client receives `identity_signature_request` within the 3s budget, then send `identity_signature_response` and assert the bridge resumes. Add a second test that closes/stops the server while a request is pending to pin no hang/crash behavior. Extend `CoordinatorClientTests.makeClient` to accept `identityBridge` and cover proof-field insertion.

### CODE-L-2 (LOW) IdentitySignatureBridge is single-slot and responses are not keyed by auth attempt
- File: `phase3-binary/Sources/macprovider-cli/IdentitySignatureBridge.swift:82`
- Category: concurrency / state machine
- Evidence: The bridge stores one `pending` request. A second `requestSignature` resumes the previous continuation with `nil` and replaces it (`IdentitySignatureBridge.swift:94-108`). `deliverResponse` resumes whichever request is currently pending without checking `authAttemptID` (`IdentitySignatureBridge.swift:115-118`), and the response frame does not carry an auth attempt id (`ControlSocket.swift:62-67`, `ControlSocket.swift:165-172`).
- Impact: The current smoke/onboarding path has one active identity-signature auth request, so this is not a blocking bug. If future reconnect, receipt-rotation, or multi-client flows overlap auth attempts, the earlier attempt can fall through unsigned, and a late response can be applied to the newer pending attempt, causing coordinator rejection.
- Recommendation: Either make overlapping requests an explicit invariant with tests and logs, or add `auth_attempt_id` to `identitySignatureResponse` and key `pending` by attempt id. Also compare the echoed `transcriptSHA256` with the request transcript before adding it to the proof.

### CODE-L-3 (LOW) `saveProviderIdentity` bypasses the stronger config atomic-write helper
- File: `phase3-binary/app/Sources/Malibu/System/ProviderConfig.swift:229`
- Category: persistence hardening
- Evidence: `saveProviderIdentity` merges existing config lines and writes:
  ```swift
  lines.append("provider_id: \(providerID)")
  lines.append("coordinator_url: \(coordinatorWSURL.absoluteString)")
  lines.append("link_state: \(LinkState.pendingLink.rawValue)")
  try Data(joined.utf8).write(to: paths.configFile, options: [.atomic])
  try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configFile.path)
  ```
  The same file already has `atomicWrite0600`, which writes a temp file, `fsync`s the file, renames it, and `fsync`s the parent directory (`ProviderConfig.swift:792-810`). The current URL is a normal `wss://...` string and unknown existing lines are preserved, so this is not blocking. Still, this path does not use the stronger helper and writes YAML scalars without a general quoting/escaping layer.
- Impact: A crash or power loss around this specific identity save has weaker durability than other config updates. Non-standard future URL strings would rely on YAML plain-scalar compatibility instead of an explicit emitter/escaper.
- Recommendation: Reuse `atomicWrite0600(Data(joined.utf8), to: paths.configFile)` here. If config fields can expand beyond controlled IDs and `wss://` URLs, route scalar rendering through a small YAML string escaper or a real YAML writer.

### CODE-I-1 (INFO) Canonical JSON and transcript tuple match across CLI/App for the current identity-signature schema
- File: `phase3-binary/Sources/macprovider-cli/CanonicalJSON.swift:40`
- Category: code correctness
- Evidence: CLI and app canonicalizers both sort object keys by UTF-16 code units, normalize strings with `precomposedStringWithCanonicalMapping`, emit no whitespace, and use the same C0/string escapes (`CanonicalJSON.swift:40-78`, `RegisterClient.swift:30-70`). The identity-signature payload is all strings on both sides: `auth_attempt_id`, `provider_id`, `binary_version`, `provider_ecdh_public_key`, and `transcript_sha256` (`CoordinatorClient.swift:1212-1218`, `RegisterClient.swift:194-207`, `MalibuAgent.swift:401-407`). No numeric fields are emitted through this identity-signature path.
- Impact: No action required for the audited schema.
- Recommendation: If this canonicalizer is reused for numeric fields, add RFC 8785 number fixtures before relying on `.number(String)` callers to pre-canonicalize.

### CODE-I-2 (INFO) The 3s identity-signature timeout intentionally falls through unsigned
- File: `phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift:1219`
- Category: operational behavior
- Evidence: On timeout, `IdentitySignatureBridge.requestSignature` returns `nil` (`IdentitySignatureBridge.swift:94-110`), and `authProofMessage` simply omits `identity_signature` / `identity_signature_transcript_sha256` unless a non-nil accepted response arrives (`CoordinatorClient.swift:1223-1228`). App-side identity-key storage currently uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` without `SecAccessControl` user-presence/biometry flags (`ProviderIdentity.swift:211-215`), so the audited code is not currently expected to wait on a TouchID prompt.
- Impact: No blocking issue for the current implementation. If a future Keychain policy adds user-presence prompts, 3s can become too short for App-track providers and cause coordinator close 4003 unless the provider is exempt.
- Recommendation: Keep the short timeout while the signing path remains prompt-free. If user-presence protection is added, make the timeout/prompt contract explicit and test the slow-signing path.
