# R1 findings (PR #1960)

Code 0/0/1/0, security 0/0/1/0, architecture 0/0/2/2.

- M (code, security; arch L3): the refusal marker survived intervening
  deferrals, so non-consecutive refusals could end the ladder; and the
  in-flight check ran only after the refusal. Fixed: the marker is cleared at
  the top of every failed attempt and keyed on the full target (key and swap
  generation); a refusal counts only with no request in flight and no real
  request started since the step began.
- M (security, arch M1): a backpressure-ended ladder could lower a prior grant
  through `reconcile` and persisted with no re-measurement. Fixed: with a
  prior or provisional grant wider than the verified prefix the ladder pauses
  (grant kept, resumes at the refused width after 1 h); otherwise the prefix
  decision applies and the full ladder is re-measured after 1 h.
- M (arch M2): a queue-bounded decision stayed after the queue limit grew.
  Fixed: the record stores `ladder_bound`; a decision whose every width up to
  it passed re-runs when the bound grows (`ladderBoundGrew`).
- L (arch L4, pre-existing): FR-CB11 item 1 said owner pins are served as
  written. Fixed in the SPEC text: never above `verified_k`.
