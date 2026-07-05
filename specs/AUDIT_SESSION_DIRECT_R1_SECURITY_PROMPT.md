# Session direct-push audit R1 — SECURITY lane

You are the **security** lane of a three-lane audit (code / security /
architect) of the six direct-push commits landed in this working session
while smoke-testing Malibu.app onboarding through v1.8.5 → v1.8.9. The
bar for convergence is **0 CRITICAL, 0 HIGH, 0 MEDIUM findings** across
all three lanes.

## Scope

Direct pushes to `main`, in order:

| Commit | Version | Intent |
|--------|---------|--------|
| `0495fd9` | v1.8.5 | Persist coord URL to `config.yaml`; new `FreePortProbe`, `MalibuOnboardingTimeouts`; LaunchProviderController wiring |
| `a97c236` | v1.8.6 | Wire CLI-side SPEC-026 §7 `identity_signature` handshake (new `CanonicalJSON` + `IdentitySignatureBridge`, control-socket frames, transcript SHA-256) |
| `23b3504` | v1.8.7 | Bridge timeout 30 s → 3 s |
| `4a5165a` | v1.8.8 | Pusher bypasses `ControlSocketConnection` actor via `writeFrameDirect(fd:frame:)` |
| `6cd2bfe` | v1.8.9 | Accept `"ready"` OR `"serving"` in Malibu state consumer |
| `c1d8be9` | (patch) | Strip debug prints |

Per-commit patches: `audits/2026-07-05/session-direct-r1/patch-0{1..6}-*.diff`.

Baseline specs to consult:
- `specs/SPEC-020-TIER2-AUTH-HANDSHAKE.md` (or the current v1.7 file — check header for exact filename) — coordinator side of identity_signature.
- `specs/SPEC-026-BROWSERLESS-ONECLICK-PROVIDER-ONBOARDING.md` — §7 handshake definition.

## Security-lane scope (apply each; stay in lane)

### SEC-1. identity_signature: replay + binding surface

The signed payload contains:

```
{
  "auth_attempt_id": <String>,
  "provider_id": <String>,
  "binary_version": <String>,      // v1.8.6+ (was Int, now String)
  "provider_ecdh_public_key": <String>,
  "transcript_sha256": <String>    // base64(SHA-256(canonicalized initial coordinator auth frame))
}
```

- Replay: does `auth_attempt_id` come from the coordinator (challenge)
  and is it single-use on the coordinator side? What stops an attacker
  who captured a valid `identity_signature` from replaying it against
  a different session?
- Transcript binding: `transcript_sha256` binds the signature to the
  exact initial coordinator auth frame. Verify:
  - The frame the CLI hashes is the *received* frame, not a locally
    reconstructed one.
  - Canonicalization matches App-side exactly — a single-byte
    canonicalization drift = coordinator rejects, but a canonicalization
    that DIFFERS in a security-material way (e.g. drops fields, sorts
    differently) would let an attacker sign a different transcript.
- Nonce reuse / prng: `ProviderIdentity.sign` — is nonce fresh per
  signature? (Ed25519 is deterministic, so N/A, but confirm the
  identity key is Ed25519 not ECDSA.)

### SEC-2. Bridge timeout race + degraded auth

`identitySignatureTimeoutSeconds: TimeInterval = 3` (v1.8.7). On
timeout, the CLI proceeds to send the auth proof WITHOUT
`identity_signature`.

- Coordinator behavior when `identity_signature` is absent but the
  provider previously enrolled with a Tier-2 identity: does it reject
  (close 4003) or downgrade? Per SPEC-026 §7, close 4003 is expected —
  confirm.
- If the coordinator DOES downgrade (e.g. Tier-1 fallback), this is a
  Tier-2 → Tier-1 downgrade attack surface: attacker DoSes the App's
  bridge for 3 s and the provider silently drops trust tier. Verify
  no such downgrade path exists.
- Is the timeout event surfaced to the operator (log at ERROR level,
  UI state) so degraded auth doesn't fail silently?

### SEC-3. Control-socket actor bypass — protocol integrity

v1.8.8's `writeFrameDirect(fd:frame:)` writes newline-delimited JSON
directly to the fd, bypassing the actor.

- Frame interleaving: if the actor is mid-write of a large frame and
  the pusher fires a `writeFrameDirect`, could the frames interleave
  at the byte level (POSIX `write()` is atomic up to `PIPE_BUF` = 4096
  on macOS for Unix domain sockets)? Confirm the identity_signature
  request frame is < 4096 bytes AND that no other actor-side frame in
  flight can exceed 4096 bytes. If either fails, an attacker (or just
  bad luck) can cause a frame corruption that Malibu parses as
  something other than intended.
- Newline framing: the pusher writes one frame + trailing newline. If
  the actor writes a frame that is not newline-terminated, byte-level
  interleaving corrupts framing. Verify actor-side writes always end
  with `\n`.
- Reader on Malibu side: does Malibu tolerate a corrupted frame
  (log + continue) or does it treat unparseable frames as fatal?
  Fatal is fine for defense-in-depth; log + continue is a DoS-input
  surface.

### SEC-4. Control-socket auth model (unchanged, but re-verify)

- The Unix domain socket lives at (grep for path): confirm it is
  chmod-restricted to the owning user only. Any world- or group-
  readable/writable variant is a local privilege escalation surface —
  any local process could impersonate the App/CLI and hijack the
  identity_signature handshake.
- Any peer credential check on `accept()`? (`SO_PEERCRED` /
  `getpeereid()` on macOS.) If not, LPE risk is real.

### SEC-5. `ProviderConfig.saveProviderIdentity` — config write surface

`config.yaml` now stores the coordinator WebSocket URL.

- YAML injection: is `coordinatorWSURL` written through a real YAML
  encoder or via string interpolation? If interpolation, an attacker-
  controlled URL (e.g. from a MITM register response) with a newline
  could inject arbitrary config keys.
- File perms: what mode does the tmp-file get? The final `config.yaml`
  should be 0600. Verify.
- The register response includes `coordinator_ws_url`. If the register
  endpoint is TLS-pinned OR verified via app-attest, this is safe.
  If it's plain HTTPS with the coordinator's DNS resolvable, verify
  the URL scheme is `wss://` (not `ws://`) and origin is what the
  App expects.

### SEC-6. FreePortProbe (v1.8.5)

`bind(0)` + `getsockname` + `close` — probe returns a suggested port.

- TOCTOU: the caller may bind() the port later, but between probe and
  bind another process (or the attacker) can bind the same port. On
  macOS, `SO_REUSEADDR` semantics differ from Linux — verify the
  caller sets `SO_REUSEADDR = 0` before binding the probed port and
  fails closed on `EADDRINUSE`, otherwise an attacker who binds a
  race-winning listener can intercept traffic to a well-known local
  port.
- The probe socket type — TCP or UDP? For the CLI's use case, they
  need to match the caller's bind() type. Confirm.

### SEC-7. Debug prints strip (c1d8be9)

- Before-strip: prints contained request/response payloads including
  `provider_ecdh_public_key`, `transcript_sha256`, signature bytes.
  Any of these leaked would materially help an attacker with wire
  captures. Confirm the prints are GONE from all release paths (grep
  for `[idsig]`, `stderr.write`, `FileHandle.standardError` in
  IdentitySignatureBridge.swift and ControlSocket.swift).
- Any other debug prints elsewhere that were NOT cleaned? Grep the
  CLI + App for stderr writes that expose secrets.

### SEC-8. binary_version type change (Int → String)

The frame's `binary_version` moved Int → String. Signed payload also
uses String. Any surface that still assumes Int (e.g. a coordinator-
side check) would silently reject or accept unexpected values.

- Verify the coordinator schema for `binary_version` in the SPEC-020
  or SPEC-026 spec — is it defined as String? If defined as Int,
  the CLI is now sending a String and this is a bug.
- Version comparison logic: does anything on the CLI or App side do
  `if binary_version >= 1.8.6`-style numeric comparison? Now that
  it's a String, lexical compare could ordering-fail (e.g. "1.8.10"
  < "1.8.9" lexically).

### SEC-9. Tier-2 identity Keychain access

The identity_signature is produced by signing with the identity Ed25519
private key stored in Keychain under `tech.malibu.app` (service).

- Access-control on the Keychain item: is it
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (or stronger) +
  application-tag pinned so only the signed App can sign?
- Is the CLI ever a signer, or only the App? (Should be App-only per
  SPEC-020 — CLI has no identity key.)

## Response format

Write findings to
`audits/2026-07-05/session-direct-r1/session-direct-r1-security-findings.md`:

```
# Session direct-push R1 — SECURITY lane findings

## Verdict
PASS / FAIL

## Findings

### SEC-C-1 (CRITICAL) <title>
- File: <path:line>
- Threat model: <attacker capability, precondition, blast radius>
- Evidence: <code + protocol references>
- Recommendation: <specific fix>

### SEC-H-1 (HIGH) <...>
### SEC-M-1 (MEDIUM) <...>
### SEC-L-1 (LOW) <...>
### SEC-I-1 (INFO) <...>
```

Stay in your lane: no code-style opinions, no architecture judgments —
those are the other two lanes. Only flag things that turn into a real
attacker capability or a privacy leak. If verdict is PASS, still write
the file with a one-paragraph "what threats I checked" narrative for
the audit trail.
