# macprovider-verify v1.1.1

Fixes verification of current SPEC-015 v0.3 buyer receipts. `verify-v1.1.0` and `verify-v1.0.0` are deprecated.

## Fixes

- Accept `model_hash` as a 64-character lowercase hex string or JSON null on the v0.3 nine-field tuple. v1.1.0 rejected both with exit 65 (`json: unknown field "model_hash"`) before signature verification, including when `--pubkey` was set. Signed tuple bytes are still verified as received.
- The default key-lookup host in this binary is `coordinator.malibu.tech`. v1.1.0 and v1.0.0 compiled `coordinator.streamvc.live`. An explicit `--coordinator` for another HTTPS host still works and still warns `non_default_coordinator`. Private and loopback hosts still require `MACPROVIDER_VERIFY_ALLOW_PRIVATE_COORDINATOR=1`.

## Unchanged

- v0.1 and v0.2 seven-field receipts verify as before.
- `receipt_version` other than `"3"`, including settlement `"4"`, returns `inconclusive` / `unknown_receipt_version`. This release does not verify SPEC-015 v0.4 settlement receipts.
- Max SPEC version reported by `--version` remains `0.3.3`.
