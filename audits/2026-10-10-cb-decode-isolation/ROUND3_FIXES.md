# Round 3 (final, three lanes) and fixes

Round 3 ran on `3f68b0c06`. Verdicts: code 0 C / 0 H / 1 M / 0 L; security
0 C / 0 H / 0 M / 0 L; architecture 0 C / 0 H / 0 M / 1 L (+1 INFO). All
lanes confirmed round-1 #1-#8 and round-2 #1-#4 closed.

| # | Lane / severity | Finding | Fix |
| --- | --- | --- | --- |
| 1 | Code MEDIUM | Under a foreign array mask, rows on one vector route still shared the padded call, but nothing proved the mask excluded padding: an all-true mask let a short row attend padding. | The padded call is shared only under a plain cache-built mask or the packed verification mask; under any other mask every padded row splits and attends over its own keys with its slice of the mask, so padding is never visible. Regression in `testPerRowAttentionKeepsTheSingleCallForForeignMasksAndMissingHistory` (600/901 keys, both one-pass, all-true mask). |
| 2 | Arch LOW | The draft said every prompt chunk over 8 tokens takes the unfused path; head dim 128 takes fused steel attention. | Draft qualified (unfused at 192/256, fused steel otherwise; padded prompt rows split either way). |
| - | Arch INFO | SPEC-038 text and CONFORMANCE mappings remain in the draft. | Landing dependency, coordinated with the release session. |

Also: `testSelfCheckKeyCarriesTheRowIsolationPolicy` now builds the key from
an explicit forward bound instead of creating a Metal device. Creating the
device inside `ContinuousBatchSchedulerTests` perturbed the timing-sensitive
`testBatchedPrefillPreservesDecodeOrderFallbackFairnessAndCancellationIsolation`
(5 of 14 suite runs failed; 0 of 16 on main). After the change: 0 of 8, with
main also 0 of 8, interleaved.

Carried: none above LOW. The architecture LOW is fixed; the INFO is the
agreed SPEC landing dependency.
