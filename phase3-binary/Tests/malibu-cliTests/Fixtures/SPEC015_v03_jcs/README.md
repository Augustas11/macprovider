# SPEC-015 v0.3 JCS golden fixtures

These files lock the byte-exact JCS canonical encoding of the v0.3
9-field receipt tuple so the Swift signer (phase3-binary) and the
Go verifier (phase7-verify, landing in Step 5) produce identical
canonical bytes for identical inputs.

Each fixture is a JSON object with:

- `description` — what shape this fixture exercises.
- `input` — the receipt input values (model_hash possibly null, etc.).
- `provider_pubkey_seed_b64` — 32-byte seed used to derive the
  ed25519 keypair via `Curve25519.Signing.PrivateKey(rawRepresentation:)`.
- `canonical_jcs_sha256_hex` — SHA-256 over the canonical JCS bytes
  the builder produces. Lower-case 64-char hex.
- `canonical_jcs_length` — byte count of the canonical JCS string.

The Swift test in `JCSGoldenFixtureTests.swift` runs the builder
against `input`, recomputes the SHA-256, and asserts equality.
Step 5's Go verifier MUST consume the same fixture files and pass
the same assertion.

To regenerate the SHA after intentional changes:
1. Update `input` and run the failing test once.
2. Copy the printed SHA-256 + length into the fixture JSON.
3. Re-run; the test should now pass.
