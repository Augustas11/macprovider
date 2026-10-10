
codex
**FIXED — both round-7 anchors.** Commit `2c9a247cb` passes the scoped CODE gate.

- **Capacity/stamp suspension window: FIXED.** [ProviderStatus.swift:749](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ProviderStatus.swift:749) rejects older stamps and installs the accepted stamp and capacity before the first await at line 774. A delayed older self-check publication cannot overwrite the swap’s count.
- **Older swap borrowing a newer generation: FIXED.** [ModelRuntime.swift:5399](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5399) captures `swapGeneration` once. Gate resizes and capacity publication use that captured value; resolver and scheduler-limit application check generation equality. [The completion call](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:5543) carries the stamp, and the trailing publication is removed.

**NEW findings introduced by this commit: none.**

Validation: read-only source/diff inspection. The added test covers stale receiver updates, but does not exercise the thermal-suspension interleavings. No edits, builds, tests, or network calls performed. Pre-existing non-capacity swap races excluded as requested.

**C/H/M/L = 0/0/0/0**
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed
