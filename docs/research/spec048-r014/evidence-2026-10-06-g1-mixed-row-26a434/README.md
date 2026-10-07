# G1 mixed-row parity on the Mac Studio (2026-10-06)

Hardware check of the G1 fix (`60009fc27`, native rows share the ordinary
`[B, L]` prefill forward) against the fixture that failed the R014 rehearsal
(`../evidence-2026-10-06-v1.8.217-26a434/checks/item3-mixed-row.json`): one
8-row batch with equal-length prompts holding one native row, load-gated rows,
and ordinary rows, each compared with the ordinary batched oracle.

| Field | Value |
| --- | --- |
| Source | `mtp/enablement` at `60009fc27`, built on the Studio with `swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS` |
| Binary | `binary-sha256.txt` (lab build; `mlx.metallib` is the v1.8.217 metallib used by the R015 runs) |
| Host | Apple M3 Ultra, 256 GB, macOS 26A434 |
| Command | `MACPROVIDER_NATIVE_MTP_E2E=1 macprovider-cli native-mtp-journey-e2e --root <clone of q36-a3b-cat> --model-id qwen/qwen3.6-35b-a3b --qualified-slots 8 --max-native-active-rows 1 --max-prompt-tokens 4096` |
| Isolation | exclusive lab window 13:28:34-13:31:32Z, no coordinator join, cloned fixture; live :8080 untouched |

## Result

`step-07-08-mixed-multirow-capacity`: **pass**, every check true, including
`journey-mixed-0..7.parity` (R014 on v1.8.217: rows 0-3 failed parity). The
native row is admitted (`eligible`), the others select ordinary
(`capacity_above_native_bound`, `conversation_key`), the load gate held the
native row for 18 depth-zero rounds and every hold resolved.

All executed steps (04, 05, 06, 07/08, 09, 12 local half) have zero failed
checks. "partial" on the other steps marks contract the harness does not yet
cover (G10), not a failure. `journey-result.json` is the unmodified output.
