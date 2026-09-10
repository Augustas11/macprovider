# Local relay-blind test evidence

This self-attested ephemeral TEST signature records the complete relay-blind race journey suite at clean commit `956498f3fee52988d37d777e7f2fe0c2a8381676`. It is not an operator/deployment signature and cannot promote conformance. Subsequent changes are evidence/documentation and Linux test-fixture portability only; production runtime bytes are unchanged.

The signed object records the exact command, clean-tree hash, test-log hash, covered journeys, and limitations. The public verification key is `ephemeral-test-public.pub`; its SHA-256 must match the envelope. Reconstruct the signed payload using Python `json.dumps(envelope["signed"], sort_keys=True, separators=(",", ":")) + "\n"`, verify its SHA-256, base64-decode the signature, and verify ECDSA P-256/SHA-256 with OpenSSL. The private test key was deleted after capture.

Raw test logs remain local to avoid publishing incidental runtime output. Reproduce from the bound commit with `scripts/run-relay-blind-local-journey.sh /absolute/outside-repository/evidence-directory`. The validator requires every named acceptance test to pass and rejects skips or missing results. This full encrypted journey uses a deterministic real Swift provider backend. Separate Apple M5 model-runtime evidence and broad Swift limitations are documented in the parent implementation audit.
