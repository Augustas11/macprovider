# Round 2 — SECURITY lane (omc ask codex)


HIGH — phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:836 — **NEW:** Downgrade authorization can change before activation or restart. The swap gate checks revocation, then awaits a trust-only check at line 766. The restart gate at line 459 precedes asynchronous status eviction, after which line 837 unconditionally restarts P. During a held-session retry, teardown/reconnect can interleave; cancellation is not checked at these boundaries. P can run after its authorization disappears. — Serialize current-session authorization with activation/restart, perform eviction before the final restart check, and permit no intervening suspension. Test authorization withdrawal during both callbacks.

MEDIUM — phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:1067 — **NEW:** Live authorization compares revocation and recommended set IDs but omits the current recommended binary version and session generation. A replacement session retaining those IDs while changing or omitting `recommended_binary_version` still authorizes the old attempt. Acceptance does not reject this contradiction. — Bind the captured authorization to the session generation and normalized recommended version; reject inconsistent set/version acknowledgements.

MEDIUM — phase3-binary/Sources/macprovider-cli/AutoUpdater.swift:319 — **PRE-EXISTING, exposed by this downgrade workflow:** Effective signed policy is checked only before download. Concurrent manual `update --check` can persist a signed head revoking P or raising the minimum above P (`SelfUpdate.swift:288`), without acquiring the mutation lock. The in-flight downgrade never checks policy again and can install an already-observed, forbidden target. — Recheck effective policy immediately before activation and restart, serializing policy changes with those boundaries. Test policy advancement during download.

Both R1 findings are fixed in the inspected code: restored revoked V can retire the failed transaction using exact identity and stable local health; T-3/T-4 now describe vulnerable signed-history rollback and locally observed policy limits accurately.

Cryptographic artifact verification remains shared with upgrades. No additional parsing, boolean-confusion, repository-binding, discovery/manual downgrade, or ops-injection bypass was confirmed.

Residual coordinator-compromise risk remains selection of authentic but vulnerable signed history within the floor and observed policy bounds. T-4 accurately records that intended risk; the findings above exceed those bounds.

Read-only static audit of the complete diff and supporting paths. No edits, network commands, or tests.

VERDICT: C=0 H=1 M=2 L=0
