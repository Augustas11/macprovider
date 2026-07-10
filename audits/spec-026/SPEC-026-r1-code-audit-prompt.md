# SPEC-026 R1 — CODE audit lane

You are auditing a specifications-only PR that adds a new normative spec:
`specs/SPEC-026-browserless-provider-onboarding.md`. The PR does **not**
change `phase3-binary/`, `phase4-coordinator/`, or `phase5-gateway/`
sources — implementation lands in follow-up PRs blocked on this merge.

Your lens is **CODE**: whether the spec's normative statements about
existing sources are technically correct, whether the proposed code
shape is buildable, and whether the invariants the spec claims are
preserved actually hold in the referenced files.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (the spec)
- `beta/DECISION_CRITERIA.md` Entry 102 (the decision log entry — check
  that its claims about the spec match the spec)

## Cross-reference sources (READ, do not modify)

The spec cites specific existing file paths and line ranges. Every one
of these citations must be verified against the working tree:

- `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift:226`
  (spec §0, §3.2) — `Curve25519.Signing.PublicKey` reference
- `phase3-binary/Sources/MacProviderCore/ProviderTokenPersist.swift:42-113`
  (spec §2, §4.1 step 7) — atomic write of `provider_token`
- `phase3-binary/app/Sources/Malibu/System/ProviderConfig.swift:63-99`
  (spec §2, §6.1 step 7c) — `saveProviderIdentity(providerID:token:)`
- `phase3-binary/app/Sources/Malibu/Agent/MalibuAgent.swift:46-50` and
  `:62-66` (spec §2, §7.6) — `MACPROVIDER_PROVIDER_TOKEN` handoff and
  `isConfigured` guard
- `phase3-binary/app/Sources/Malibu/System/PendingLinkState.swift`
  (spec §7.3) — file to delete; verify it exists at the claimed path
- `phase3-binary/app/Sources/Malibu/MalibuApp.swift:37-45` and `:107-125`
  (spec §7.3) — `application(_:open:)` and `.consume(.providerLinked)`
- `specs/SPEC-003-open-onboarding.md` §FR-C9 (spec §2, §4.1 step 7)
- `specs/SPEC-015-receipts.md` §12 (spec §0, §3.2)
- `specs/SPEC-022-verified-model-settlement.md` (spec §2, §5.4)
- `specs/SPEC-025-native-mac-app.md` §3.1 (spec §2, §6.1, §8, §9.1)

## What to check

Rank each finding by severity: CRITICAL / HIGH / MEDIUM / LOW / INFO.

1. **Citation accuracy.** For every path:line reference above, does the
   file exist at that path, and does the line range (or content near it)
   match what SPEC-026 claims is there? If SPEC-026 says
   `MalibuAgent.swift:46-50` guards on `ProviderConfig.isConfigured`,
   grep the file and verify. Any drift is at minimum MEDIUM — the spec
   will rot fast if implementers can't trust the citations.

2. **Buildable Swift shape.** The types/methods declared in §7.1 and
   §7.2 must be consistent with `swift-crypto`'s `Curve25519.Signing`
   surface and Swift 5.9+ actor rules. Watch for:
   - `Curve25519.Signing.PrivateKey.init(rawRepresentation:)` throws;
     `loadOrGenerate() async throws` reflects this correctly?
   - `@MainActor final class LaunchProviderController: ObservableObject`
     with async methods — do the `async` methods in §7.2 need actor hops
     that the spec skips over?
   - `exportRawForCLI(_:)` returns `Data` — is exporting the raw private
     key over an env var actually safe under macOS process-environment
     inheritance rules (child processes can read parent env; that IS
     the point; but any Swift or macOS constraint that makes this
     impractical is a HIGH).

3. **`provider_id` derivation.** §3.3 defines
   `p_ + base32(sha256(pubkey), lowercase, no-pad)`. Verify:
   - RFC 4648 lowercase base32 is unambiguous (there is no "lowercase"
     variant in RFC 4648; the standard alphabet is uppercase). Is the
     spec's alphabet claim well-defined enough to implement without
     ambiguity, or does an implementer have to guess?
   - `sha256(pubkey_bytes)` is 32 bytes; base32 no-pad of 32 bytes is
     52 chars. Add the `p_` prefix → 54 chars. Does the spec's example
     `p_abcd…` and success-card display "short 8-char display" match?

4. **JCS canonicalization.** §4.1 and §4.2 sign
   `JCS(body_without_signature)` per RFC 8785. Verify:
   - JCS ordering is well-defined for the JSON shape shown; are any
     nested objects (e.g. `hardware_summary`) also canonicalized?
   - Ed25519 signature over JCS bytes is a well-known pattern, but does
     the spec commit to a specific JCS library that both coordinator
     (Go) and app (Swift) already vendor, or is this the first use?

5. **Env-var handoff safety.** §3.2 introduces
   `MACPROVIDER_RECEIPT_KEY_RAW` (base64 of 32-byte private key). The
   env var will be visible in `/proc/<pid>/environ` (Linux) or
   `ps eww` (macOS). Is this acceptable given the CLI runs on the same
   user as the App and the Keychain ACL already grants that user
   access?

6. **`PendingLinkState` removal side effects.** §7.3 deletes the file
   and removes the `.consume(.providerLinked)` branch. Grep the whole
   `phase3-binary/app/` tree for other consumers of `PendingLinkState`
   or `.providerLinked`. If any survive, the spec's deletion plan
   drops a compile error into follow-up PRs.

7. **`MALIBU_ONBOARD_V2` flag semantics.** §8 says the flag is readable
   as an env var OR a `UserDefaults` key. When both are set with
   conflicting values, which wins? Undefined precedence = MEDIUM.

8. **Entry 102 vs SPEC-026 drift.** The decision-log entry in
   `beta/DECISION_CRITERIA.md` restates the spec's key calls. Compare
   the entry against the spec section-by-section; any contradiction is
   at minimum MEDIUM.

## What is out of scope for this lane

- Sybil-defense adequacy (that's the SECURITY lane)
- Whether reusing FR-C9 self-mint is the right shipping path (that's
  the ARCHITECT lane)
- Prose style, typos, section ordering — INFO at most

## Output format

For each finding, produce a block:

```
Severity: CRITICAL | HIGH | MEDIUM | LOW | INFO
Where: <file:line or spec §>
Claim: <one-line summary>
Evidence: <what you found in the working tree>
Fix: <concrete change to spec text OR to a cited file>
```

End with a totals line:

```
TOTALS: C=<n> H=<n> M=<n> L=<n> I=<n>
```

The audit-loop merge gate is **0 CRITICAL, 0 HIGH, 0 MEDIUM**. LOW and
INFO ship with a PR-body callout.
