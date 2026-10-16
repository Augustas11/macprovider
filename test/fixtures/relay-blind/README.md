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

`privacy-key-rotation-v1.json` is the SPEC-049 §4.12 identity key rotation
vector. It locks the posture digest and the rotation framing, and carries the
deterministic Ed25519 signatures of the previous and new identity keys, both
made from fixed byte-pattern seeds. The Secure Enclave key is the P-256
generator point, used only as a valid public key; ECDSA signatures are
randomized and are not part of the vector. The coordinator Go tests and the
Swift provider tests consume it. Regenerate with
`MACPROVIDER_REGEN_FIXTURES=1 go test ./internal/relayblind -run '^TestPrivacyRotationVectorGenerate$'`
from the coordinator module.

`privacy-code-bound-v1.json` is the SPEC-049 §4.13 code-bound evidence
vector. It locks the `privacy-code-bound-v1` statement framing and its
SHA-256, which is the App Attest `clientDataHash` the attestor asserts over.
The posture is the rotation vector's posture, the Secure Enclave key is the
P-256 generator point, the identity key comes from a fixed byte-pattern seed,
and the App Attest key id is a fixed byte pattern; none is a real key.
Assertions are ECDSA and randomized, so the vector carries none. The
coordinator Go tests and the Swift provider tests consume it. Regenerate with
`MACPROVIDER_REGEN_FIXTURES=1 go test ./internal/relayblind -run '^TestPrivacyCodeBoundVectorGenerate$'`
from the coordinator module.
