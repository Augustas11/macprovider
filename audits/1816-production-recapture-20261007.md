# #1816 production recapture — 2026-10-07

Run `trusted-pool-model-20261007T054340Z` exercised the live reviewed
v1.8.221 coordinator/gateway source
`2fa09b09a7bb96c521197222f7de3eaebb998184` with released, signed native
CLI 1.8.217 and GGUF CLI 1.8.219 on the designated Mac Studio. Raw captures,
credentials, and signing custody remain private. No locally built provider
attached to Malibu. The freshly built reviewed-main coordinator CLI was used
only as an offline manifest/route-snapshot verifier.

**The complete signed journey did not pass.** No pool-model envelope was
signed and no pool-model conformance row was promoted. Individual checks below
were run separately against genuine captures to identify the remaining
failures; that diagnostic record is explicitly non-promotable and remains
private. The production data was not rewritten to obtain a passing result.

## Results

| Check | Result |
|---|---|
| Native non-streaming and streaming paid requests | Both pass their complete paid-route, receipt, ledger, debit, and reservation joins |
| GGUF non-streaming and streaming paid requests | Both pass those joins |
| Window-only rotation; price-change in-flight/after; entry-removal in-flight | All four paid paths pass their frozen generation/rate and settlement checks |
| Resume and post-restart paid requests | Both pass those joins |
| GGUF attestation removal while in flight | Passes the closed ledger-only zero-bill fence and crosses the actual removal boundary |
| Admission binding history, window boundary probes, six genuine pool-state observations | Pass independently |
| Actual rollback preflight | Old `m9` target exits 3 (cannot replay extensions); current `p1816` target exits 0 after the receipt deadline |
| Complete models/refusal evidence contract | Fails for the four findings below |

The removed-attestation request has exactly one routed attempt and one
`byte_estimated` ledger row with
`pool_manifest_route_not_settlement_eligible`, zero gross/provider credits,
`payable=0`, and `quarantined=1`. The reservation is refunded, settles zero
tokens, and has no hold; output/verdict/usage rows are empty. Its real ledger
creation time proves settlement after removal. The checker now accepts this
closed production shape without relaxing terminal coverage elsewhere.

## Findings carried to #1880

1. **Selected-pool model view:** the response contains the two signed pool
   entries plus two global catalog entries. The journey requires
   `pool_view_other_count=0`. Reconcile the exclusive-view requirement of
   SPEC-006-R018 / the journey with production, then fix and test the chosen
   normative behavior. The global view itself contains no pool entry.
2. **Early-refusal provenance:** no-pool, other-pool, and removed-entry 404s
   join the correct external request ID but their coordinator logs contain an
   empty model; the latter two also omit the selected pool. The journey's
   exact `(X-Request-ID, model, pool)` join fails. Preserve unknown-model
   non-enumeration while establishing a genuine request binding; do not
   rewrite logs or discard inconvenient rows.
3. **Refusal disclosure:** wrong-engine and post-attestation-removal 503s
   carry both pool-model disclosure headers, while the refusal contract
   requires their absence. Test successful and rejected responses separately.
4. **Pre-quota pause refusal:** the paused-pool 503 happens before reservation
   creation and has no coordinator request-log row. The current checker
   requires one refunded reservation for every refusal. Specify and verify
   the closed pre-quota path, including no route, ledger, debit, or hold,
   without weakening the refund requirement when a reservation exists.

All six requested refusal calls returned their expected refusal status. That
fact alone does not satisfy the stronger evidence contract. The findings above
remain open; the ten paid paths do not make the full journey a pass.

## Restart validation

The coordinator became active at `2026-10-07T05:42:58Z`, then the gateway at
`2026-10-07T05:43:07Z`, using the existing installed release. Both health checks
reported v1.8.221 and the subsequent native pool request was paid. Expected
network interruption was announced as 10–20 seconds; continuous HTTP outage
measurement was not captured, so the systemd timestamps are not an exact
outage-duration measurement.

The protected private independent-check summary has SHA-256
`9a4e41ee202c684ae7ca4205092bf7bbb763cdb8ccdafe708501304a32c78fdf`.

Residual implementation, conformance, UX, catalog-graduation, and carried audit
work is tracked in [#1880](https://github.com/Augustas11/macprovider/issues/1880).
