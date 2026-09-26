## Lane: SECURITY / MONEY-PATH — billing, settlement, receipts, isolation, gating.

Hunt specifically for:
- Any change that can cause over- or under-billing, a second settlement, a
  receipt for work that did not complete, or loss of a receipt for work that
  did (EOS usage trim, `error_queue_full` re-route after partial work, lazy
  record).
- Cross-request data exposure: can the lazy record or the ragged-row fixes let
  one request read another request's KV (released/reused paged blocks, stale
  caches), or leak content into logs (`CBTrace` must log ids and stage names
  only).
- `waivesLabLoopbackCatalogReadiness`: can any production or non-lab
  configuration reach the waiver (URL parsing edge cases for "loopback",
  flag combinations, config vs CLI precedence)? What can a provider that
  reaches it do that it otherwise could not?
- `error_queue_full` mapping: can a provider that already emitted tokens be
  re-routed (duplicate output / double billing)?
