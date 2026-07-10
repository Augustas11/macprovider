# AUDIT_SPEC_015_IMPL_STEP_2 — Keychain receipt key lifecycle

You are auditing the implementation branch for BUILD_SPEC_015 Step 2 in
`/Users/augstar/macprovider-poc-spec015-step02`.

## Normative sources

- `specs/BUILD_SPEC_015_IMPL_PROMPT.md` Step 2.
- `specs/SPEC-015-receipts.md` v0.1.3, especially §7.1, §7.5, §13, and AC-1.
- `phase3-binary/Sources/macprovider-cli/ReceiptKeyStore.swift`.
- `phase3-binary/Sources/macprovider-cli/InMemoryReceiptKeyStore.swift`.
- `phase3-binary/Tests/macprovider-cliTests/ReceiptKeyStoreTests.swift`.
- `phase3-binary/implementation-notes.html`.

## Scope under audit

Step 2 is limited to the Swift receipt key lifecycle:

1. Add `ReceiptKeyStoring` with the public API named in the build spec.
2. Add `KeychainReceiptKeyStore` using the SPEC-015 §7.1 Keychain attributes.
3. Add `InMemoryReceiptKeyStore` for deterministic tests.
4. Implement atomic insert-or-load semantics: on duplicate add, discard the
   generated key and reload the winning current key.
5. Implement `swapToCurrent` so current moves to `.prev` and the new key
   becomes current.
6. Implement/test 7-day stale `.prev` cleanup on launch via fake clock.

No serve startup wiring, receipt signing, auth-frame publication, coordinator
parsing, gateway behavior, or locked-spec edits should land in this step.

## Required local commands

Run or inspect equivalent fresh evidence:

```bash
git diff --check
env CLANG_MODULE_CACHE_PATH=/private/tmp/macprovider-swift-module-cache swift test --package-path phase3-binary --filter ReceiptKeyStoreTests
env CLANG_MODULE_CACHE_PATH=/private/tmp/macprovider-swift-module-cache swift test --package-path phase3-binary
```

## Audit lenses

### Code auditor

- Verify the protocol has exactly the four required functions and is cleanly
  injectable for later steps.
- Verify `loadOrGenerate` follows read -> generate -> add -> duplicate reload
  behavior and does not return/cache a losing generated key.
- Verify private keys are encoded/decoded as 32-byte raw
  `Curve25519.Signing.PrivateKey` representations.
- Verify `swapToCurrent` moves current to `.prev` and installs the new current
  without silently succeeding when current is absent.
- Verify in-memory behavior is byte-equivalent for current load, generation,
  duplicate handling, swap, and previous cleanup.
- Verify tests cover first launch, second launch, provider separation, duplicate
  insertion, concurrent race convergence, swap-to-prev, missing-current swap,
  stale prev cleanup, and Keychain attribute shape.

### Security auditor

- Verify Keychain attributes match SPEC-015 §7.1 byte-for-byte:
  `kSecClassGenericPassword`, service
  `com.streamvc.macprovider.receipt-key`, account `<provider_id>`,
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and
  `kSecAttrSynchronizable=false`.
- Verify `.prev` uses only the documented `.prev` service and does not expose
  private keys via logs, pubkey persistence, files, environment variables, or
  network calls.
- Verify invalid/non-32-byte Keychain data cannot be accepted as a signing key.
- Verify no receipt tuple values, signatures, or pubkeys are logged or stored.

### Architect auditor

- Verify Step 2 remains a narrow lifecycle abstraction and does not leak into
  receipt signing or provider/coordinator/gateway runtime behavior.
- Verify implementation notes document the Keychain transaction limitation and
  future risk clearly.
- Verify the design is usable by Step 3 receipt builder and later serve wiring
  without forcing real Keychain access in unit tests.
- Verify no new dependencies are introduced.

## Severity contract

Report findings with severities:

- `CRITICAL`: accepts divergent key material for the same provider race, uses
  wrong Keychain storage attributes, stores/logs private key material outside
  Keychain/test memory, or implements out-of-scope wire/coordinator/gateway
  behavior.
- `HIGH`: likely receipt verification break, unsafe rotation/current-prev
  behavior that can silently lose the active key, missing mandatory race or
  persistence tests, or a non-injectable design that blocks later steps.
- `MEDIUM`: incomplete cleanup/test coverage, unclear error behavior that
  could mask Keychain corruption, or undocumented lifecycle tradeoff future
  implementers need.
- `LOW`: style, naming, optional extra coverage, or documentation polish.

The gate to proceed is **0 CRITICAL / 0 HIGH / 0 MEDIUM**. LOW findings may
remain if explicitly justified.

## Expected output

Return:

1. Verdict: `READY` or `FIX REQUIRED`.
2. Counts: `CRITICAL n / HIGH n / MEDIUM n / LOW n`.
3. Findings grouped by code/security/architecture lens, with concrete file and
   line references.
4. Verification commands actually run and their results.
5. Any residual risk.
