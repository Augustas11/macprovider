# Session direct-push audit R1 — CODE lane

You are the **code** lane of a three-lane audit (code / security / architect)
of the six direct-push commits landed in this working session while smoke-
testing Malibu.app onboarding through v1.8.5 → v1.8.9. The bar for
convergence is **0 CRITICAL, 0 HIGH, 0 MEDIUM findings** across all three
lanes. LOW/INFO are acceptable and land in the PR body.

## Scope

Direct pushes to `main`, in order:

| Commit | Version | Intent |
|--------|---------|--------|
| `0495fd9` | v1.8.5 | Fresh-install onboarding actually reach `.live` (persist coord URL to config.yaml, `FreePortProbe`, `MalibuOnboardingTimeouts`, LaunchProviderController wiring) |
| `a97c236` | v1.8.6 | Wire CLI-side SPEC-026 §7 identity_signature handshake (new `CanonicalJSON` + `IdentitySignatureBridge`, control-socket frames, RFC 8785 transcript hash, App-side `handleIdentitySignatureRequest`) |
| `23b3504` | v1.8.7 | Shorten identity_signature bridge timeout 30 s → 3 s so handshake beats coordinator's 10 s window |
| `4a5165a` | v1.8.8 | Bypass `ControlSocketConnection` actor for identity_signature push — pusher `Task.detached` writes frame directly to fd via new `writeFrameDirect(fd:frame:)` to avoid actor-deadlock where blocking `Darwin.read()` on receive path holds the serial queue against pusher `send()` |
| `6cd2bfe` | v1.8.9 | Accept `"ready"` OR `"serving"` in Malibu state consumer — CLI's `SwapState` only has `.ready`; App was checking `state == "serving"` and hung at `authenticating` |
| `c1d8be9` | (patch) | Strip `[idsig]` stderr debug prints from `IdentitySignatureBridge` + `ControlSocket` pusher — behavior-preserving cleanup |

Per-commit patches are at
`audits/2026-07-05/session-direct-r1/patch-0{1..6}-*.diff`. The full-diff
touched surface (unique files):

- CLI (`phase3-binary/Sources/macprovider-cli/`):
  `CanonicalJSON.swift` (NEW), `IdentitySignatureBridge.swift` (NEW),
  `ControlSocket.swift`, `CoordinatorClient.swift`, `MacProviderCLI.swift`.
- App (`phase3-binary/app/Sources/Malibu/`):
  `Agent/MalibuAgent.swift`, `Agent/ControlSocketFrame.swift`,
  `System/RegisterClient.swift`, `System/FreePortProbe.swift` (NEW),
  `System/MalibuOnboardingTimeouts.swift` (NEW),
  `System/ProviderConfig.swift`,
  `Onboarding/LaunchProviderController.swift`.
- Tests: `CoordinatorClientTests`, `ControlFrameCodecTests`,
  `RegisterClientTests`, `LaunchProviderControllerTests`,
  `MalibuOnboardingTimeoutsTests`, `ProviderConfigTests`.

## What this achieved (operator summary — NOT the audit answer)

The v1.8.9 smoke reached `.live` end-to-end with `provider_id
p_xriseqo2qdf333hzeafrfykwuuzjvlx2huwxjxtg34amqi6tem2a` at
`first_serving_at 2026-07-05T16:02:47Z`. Pearl coordinator heartbeats
show `state:"ready" slots_free:1 slots_total:1` every 5 s.

The direct-push discipline was explicitly authorized: the smoke was
already 5 failed attempts deep and the auth handshake was the last
blocking bug. All six commits are non-money-path (App-track provider
onboarding). The audit exists to confirm no bugs crept in, NOT to
second-guess the direct-push decision.

## Code-lane scope (apply each; stay in lane)

### CODE-1. CanonicalJSON (RFC 8785 JCS) correctness

The new `phase3-binary/Sources/macprovider-cli/CanonicalJSON.swift` ports
Malibu.app's `RegisterClient.CanonicalJSON` to the CLI so the CLI can
compute the same `transcript_sha256` the coordinator expects.

- Key sort: `dict.keys.sorted(by: utf16LessThan)` where `utf16LessThan`
  uses `lhs.utf16.lexicographicallyPrecedes(rhs.utf16)`. Verify this
  matches the reference App implementation byte-for-byte
  (`phase3-binary/app/Sources/Malibu/System/RegisterClient.swift`
  lines 69-71).
- String quoting: escapes `\"`, `\\`, `\b`, `\f`, `\n`, `\r`, `\t`, then
  `\uXXXX` for the rest of C0. NFC normalization via
  `precomposedStringWithCanonicalMapping` on `.string` values. Confirm.
- Numbers are pre-serialized as strings via `.number(String)` — the
  encoder is the caller's responsibility for RFC 8785 number
  canonicalization. Given the CLI only ever encodes the fixed
  transcript-hash schema (auth_attempt_id, provider_id, binary_version,
  provider_ecdh_public_key, transcript_sha256 — all `.string`),
  confirm no numeric fields are actually emitted through this path.
- `fromJSONLike(_ any: Any)` extension (if present) — confirm handling
  for `NSNumber` bool vs number ambiguity and for `NSNull`.

### CODE-2. Identity signature transcript hash

`CoordinatorClient.initialAuthTranscriptHashBase64(_:)` computes
`base64(SHA-256(CanonicalJSON(msg)))`. The identity_signature bridge
request passes this to Malibu, which recomputes it in
`RegisterClient.identitySignaturePayload(...)` and signs. If the two
canonicalizations diverge, the coordinator rejects with 4003.

- Both sides pull from the same rules (UTF-16 key sort, NFC on strings,
  no whitespace) — verify.
- The `initialMessage` fed to `initialAuthTranscriptHashBase64` is the
  original coordinator auth-request frame as it arrived on the wire.
  Confirm the CLI does not mutate it before hashing (e.g. by decoding
  and re-encoding through Swift `Any`).
- App side: `MalibuAgent.handleIdentitySignatureRequest(binaryVersion:
  String, ...)` builds its own payload dict for signing. Confirm keys
  and value types exactly match the CLI's `authProofMessage` splice:
  `auth_attempt_id`, `provider_id`, `binary_version` (String),
  `provider_ecdh_public_key`, `transcript_sha256`.

### CODE-3. ControlSocket actor bypass (v1.8.8 fix)

The v1.8.7 → v1.8.8 change is the highest-risk behavior change in the
set. Original `ControlSocketConnection` is a Swift actor. `handleClient`
now spawns:

```swift
pusherTask = Task.detached(priority: .userInitiated) {
    for await request in stream {
        try? Self.writeFrameDirect(
            fd: capturedFD,
            frame: .identitySignatureRequest(...)
        )
    }
}
```

- `capturedFD` capture: verify the fd's lifetime dominates the pusher
  task's lifetime. If `handleClient` returns and the connection is
  closed / fd closed before the pusher's stream terminates, the
  `writeFrameDirect` writes to a closed (or worse, recycled) fd.
- `writeFrameDirect(fd:frame:)`: raw `Darwin.write` — verify partial-
  write handling (write may return < len; loop until full frame is
  written or EAGAIN/EINTR handled).
- POSIX full-duplex safety: two concurrent writers on the same fd
  (pusher via `writeFrameDirect` AND actor-serialized `send()` via the
  regular RPC path) — verify write() atomicity for the frame size in
  question, or that frame-level interleaving is impossible in practice
  (e.g. only pusher writes identity_signature frames, only actor writes
  everything else, and frames are small enough to be atomic).
- Task cancellation: what cancels the pusher when the socket closes?
  Is there a happy-path shutdown vs error-path shutdown, and does each
  path cancel the pusher `Task.detached`?

### CODE-4. Bridge timeout (v1.8.7 fix)

`identitySignatureTimeoutSeconds: TimeInterval = 3`. If Malibu takes
> 3 s to respond, the CLI proceeds WITHOUT identity_signature — which
the coordinator will then reject with close 4003.

- Verify the code path when `response == nil` (timeout). Does it
  gracefully proceed with a proof that omits `identity_signature`, or
  does it fall through to a partial state?
- The 3 s value is chosen to beat the coordinator's 10 s auth window
  minus round-trip / signing time. If Keychain access on Malibu's
  side triggers a TouchID prompt (SPEC-020 note), the 3 s is likely
  too short. Flag whether the timeout should escalate depending on
  whether a signing prompt is expected.

### CODE-5. Bridge state machine (`IdentitySignatureBridge`)

New public actor with three surfaces: `requestSignature(_:timeout:)`,
`deliverResponse(_:)`, `subscribe()`.

- `subscribe()` returns `(id, AsyncStream)` — verify multiple
  subscribers (e.g. reconnection creating a new ControlSocketConnection)
  are handled: is the new subscriber added to the listener set, is the
  old one drained cleanly?
- `requestSignature` suspends on `CheckedContinuation`. If two
  concurrent auth attempts race, the second call overwrites the first
  continuation — verify. Given each auth attempt has a unique
  `authAttemptID`, is the bridge keyed by attempt id or single-slot?
- `deliverResponse(_:)` — verify it's a no-op (not a crash) when the
  continuation has already been resumed by timeout.

### CODE-6. Onboarding wiring (v1.8.5)

`LaunchProviderController` state machine changes + new
`MalibuOnboardingTimeouts`:

- `controlSocketConnectSec = 300` and `firstServingFrameSec = 600` —
  are these applied consistently across the state machine? Any state
  transition that uses a hard-coded timeout instead?
- `FreePortProbe` uses `bind(0)` + `getsockname` + `close` — verify
  standard TOCTOU caveat is either mitigated or acknowledged (port
  chosen may be taken by another process before the caller binds it).
- `ProviderConfig.saveProviderIdentity(providerID:token:coordinatorWSURL:...)`
  persists `coordinatorWSURL` to `config.yaml`. Verify:
  - YAML escaping for the URL string.
  - Atomic-replace pattern (write to tmp + fsync + rename)?
  - Round-trip fidelity when the config already exists with other
    fields.

### CODE-7. State-name backwards compatibility (v1.8.9)

The core observation: `SwapState` in the CLI has three cases
(`.loading` / `.ready` / `.draining`) — NO `.serving`. Malibu was
checking `state == "serving"`, so it hung.

- Confirm the accepted set `state == "ready" || state == "serving"` is
  correct on the App side. Are there any *other* consumers of the
  `statusResponse` frame that might now start accepting `.ready` where
  they previously did not? (Search for `.statusResponse` handlers.)
- Is there a matching test in `MalibuTests` that pins the "ready →
  serving" mapping so a future rename does not regress?

### CODE-8. Test adequacy

Enumerate what the new/modified tests do NOT cover, ranked by risk:

- `MalibuOnboardingTimeoutsTests` (NEW) — what surface is covered?
- `CoordinatorClientTests` — does it exercise the identity_signature
  bridge integration path with a fake bridge, or only the string-
  level frame encoding?
- `ControlFrameCodecTests` — does it round-trip the new
  `identitySignatureRequest` / `identitySignatureResponse` frames with
  the correct `binary_version` string type?
- Actor-bypass path in `ControlSocket.swift` — is there any test that
  covers the pusher `Task.detached` under fd close mid-stream?

### CODE-9. Debug print strip (c1d8be9)

The final direct commit stripped `[idsig]` stderr prints. Verify:

- No functional behavior change: `subscribe`, `requestSignature`,
  `deliverResponse`, timeout, pusher iteration, `writeFrameDirect`
  all preserved.
- The `try? Self.writeFrameDirect(...)` simplification (previously
  `do-catch`) does NOT accidentally swallow a different error path
  that the previous version handled specially.

## Response format

Write your findings to
`audits/2026-07-05/session-direct-r1/session-direct-r1-code-findings.md`
using this template:

```
# Session direct-push R1 — CODE lane findings

## Verdict
PASS / FAIL (0 C/H/M means PASS)

## Findings

### CODE-C-1 (CRITICAL) <one-line title>
- File: <path:line>
- Category: <code correctness / concurrency / test coverage / ...>
- Evidence: <code excerpt + reasoning>
- Impact: <what breaks>
- Recommendation: <specific fix, ideally with a diff sketch>

### CODE-H-1 (HIGH) <...>
### CODE-M-1 (MEDIUM) <...>
### CODE-L-1 (LOW) <...>
### CODE-I-1 (INFO) <...>
```

Number each finding sequentially within its severity. Include LOW/INFO —
they will be documented in the PR body even if they do not block the
bar. Stay in your lane: no security threat modeling, no cross-cutting
architecture judgments — those are the other two lanes.

If verdict is PASS, still write the file with an empty findings list
and a one-paragraph "what I looked at" narrative for the audit trail.
