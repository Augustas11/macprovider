# Relay-blind deterministic fixtures

`golden-v1.json` is a public, deterministic interoperability vector for
SPEC-041. The Ed25519 seed and X25519 private-key values are test inputs made
from fixed byte patterns. They are not operator credentials and must never be
used outside tests.

The vector locks key-record framing and signature fields, reservation bindings,
AAD, transcript digest, X25519 shared secret, HKDF outputs, AES-GCM ciphertext,
tag, and decrypted UTF-8 chat request. Go tests in both the coordinator and
gateway modules consume the same file; the Swift provider fixture harness should
consume it directly as well.

`privacy-response-v1.json` is the SPEC-049 vector derived from those inputs.
It locks the response HKDF key and nonce prefix, the per-frame AAD, three
sealed frames (seq 0, 1, and a final seq 2) under the golden envelope's
`stream` bit, the posture framing, and the privacy key-attestation framing
and Ed25519 signature. The privacy key record reuses the golden identity and
X25519 key with a 3600-second window, the SPEC-049 maximum. That window is
shorter than the golden SPEC-041 record, so the privacy digest differs while
the kid stays the same. The envelope digest is SHA-256 of the compact JSON
encoding produced by `Envelope.Digest`. Regenerate with
`MACPROVIDER_REGEN_FIXTURES=1 go test ./internal/relayblind -run '^TestPrivacyGoldenVectorGenerate$'`
from either relay-blind module.

`privacy-code-bound-v2.json` is the SPEC-049 v0.2 framing vector. It locks
the `privacy-posture-v2` statement framing (fields 1..34) and the
`privacy-app-attest-enrollment-v1` statement framing, plus the SHA-256 of each,
which is the `clientDataHash` Malibu.app passes to App Attest. The coordinator
Go tests, the provider Swift tests, and the Malibu.app supervisor tests all
frame the same statements and must produce these bytes. It holds no keys,
attestations, or assertions. Regenerate with
`MACPROVIDER_REGEN_FIXTURES=1 go test ./internal/relayblind -run '^TestPrivacyCodeBoundVectorGenerate$'`
from `phase4-coordinator`.
