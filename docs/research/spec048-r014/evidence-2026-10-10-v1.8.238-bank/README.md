# Native-MTP self-test bank re-baseline for CLI 1.8.238 (2026-10-10)

CLI 1.8.238 moves the provider runtime to mlx-swift-lm 3.32.3 on MLX 0.32
(#1927; `Package.resolved` mlx-swift-lm `ca8c384c` -> `72c4ab08`). SPEC-048
R014 (0.1.32) requires a release that changes MLX numerics to re-baseline the
SPEC-031-R033 challenge bank on the new runtime. The previous bank's expected
tokens diverge from the 3.32.3 output at token 18, so the coordinator canary
would fail the A3B tuple on 1.8.238.

| Field | Value |
| --- | --- |
| Source | `6f7290f45b3e976b275a97a5fa6ac248ef648811` (the v1.8.238 tag commit), built on the Studio with `swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS` |
| Toolchain | Swift 6.3.3 (swiftlang-6.3.3.1.3, clang-2100.1.1.101), macOS SDK 26.5: the same compiler and SDK as the release workflow's `release-toolchain.json` |
| Metallib | the signed candidate tarball's `mlx.metallib` (sha256 `16f1000b...`), byte-identical to the release; the runtime-identity log line names it |
| Binary | `binary-sha256.txt` (lab build plus the candidate metallib) |
| Host | Apple M3 Ultra, 256 GB, macOS 27.0.1 (26A434) |
| Command | `MACPROVIDER_NATIVE_MTP_E2E=1 macprovider-cli native-mtp-journey-e2e --root <clone of the A3B fixture> --model-id qwen/qwen3.6-35b-a3b --qualified-slots 8 --max-native-active-rows 1 --max-prompt-tokens 4096` |
| Isolation | exclusive lab window, in-process (no coordinator, no network, no serve port), isolated HOME, cloned fixture; no other inference ran on the GPU |

## Why a lab build

The signed release binary can't record a bank. `native-mtp-journey-e2e` and
the other native-MTP probe commands are compiled only under
`DEBUG || MACPROVIDER_LAB_HARNESS`. The release self-test (SPEC-048 0.1.32)
compares native and ordinary decode on the device but emits no tokens. The
coordinator canary runs only after a signed admission bound to the binary's
CDHash exists. The current bank came from the same kind of lab recording, and
the CI-signed 1.8.232 has passed the live canary against it.

## Result

`step-12-native-selftest`: every check is true. The native output equals the
ordinary oracle, and tokens, counters and committed-state digest are equal
across two runs. The status is `partial` only because the coordinator half of
R033 isn't exercised in-process. `challenge_bank_entry` from
`journey-result.json` (unmodified output) is the only entry of
`phase3-binary/catalog/autotune/native-mtp-selftest-bank.json`.

`step-05-cache-state-boundary` reports failed lab-harness cache-digest
comparisons on the 3.32.3 runtime. That step is not an input to the bank and
gates no serving decision. It is recorded here as found.

## Gate

After the 1.8.238 promotion and the catalog activation, the first live
coordinator native-MTP canary on the signed 1.8.238 against this bank must
PASS. On FAIL, native MTP turns off on that Mac only and continuous batching is
unaffected. The bank is then re-recorded and the catalog release re-cut.
