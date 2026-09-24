## Lane: CODE REVIEW — correctness, concurrency, test adequacy.

Hunt specifically for:
- `droppingTrailingModelStop` / `completionTokenCount`: any path where usage
  (billing) now differs from what the serial path would bill for the same
  output, or where a buyer `stop` string that happens to equal a model EOS
  token is double-handled.
- The drain fix: any remaining interleaving of `offer`, `stop`,
  `finish(afterDraining:)`, `timeout()`, `finishDrain` that strands an event or
  a completion, or calls a completion twice; capacity acquire/release balance.
- `packFromRows` / `syncRowsFromBatch`: any state where rows are equal-length
  but the batch tensors are not (or the reverse), so the lockstep path writes
  wrong KV back; interaction with `decodeLockstepWindow` session reuse and
  `clearDecodeSession`/`invalidateDecodeSession`.
- Lazy record: can `materializeContiguousByteCache` now observe caches that
  moved after `record`, or blocks released/reused by another request; does
  anything on the serve path still depend on the removed eager snapshot.
- Whether the new tests actually fail on the pre-fix code.
