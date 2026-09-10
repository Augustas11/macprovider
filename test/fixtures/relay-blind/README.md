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
