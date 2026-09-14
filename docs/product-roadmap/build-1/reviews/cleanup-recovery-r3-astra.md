# Cleanup recovery addendum r3 — independent Astra architecture delta gate

Verdict: APPROVED for the focused cleanup and operation-selector design. 0 Critical, 0 High, 0 Medium, 0 Low.

Reviewed exact artifact: `docs/product-roadmap/build-1/cleanup-recovery-addendum-r3.md`.
SHA-256: `83841b4278d93eeaa7f64160699dc7874a592e2a0fd534a35b57c7eea04e6193`.
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
This is the r2-to-r3 delta review plus confirmation that the previously approved separate recovery array and R1 finding closure remain intact. No implementation had begun under these cleanup addenda. No source edits, subagents, or test execution in this review.

## Delta assessed

R3 replaces the unfinished selector reference with a canonical lowercase UUID `operation_generation`. The CLI assigns it under the journal lock before publishing a recovery descriptor. Projection and repeated starts of one reserved attempt reuse the same generation; a subsequent cleanup attempt receives a fresh generation. Actions and events bind that generation, and typed controls supply expected kind plus generation. The CLI checks the exact UUID/target/kind/generation under its journal lock before reconciliation or cancellation can mutate state.

This closes the selector dependency identified in the r2 review at the cleanup-design level. A cleanup action cannot be confused with its original preparation/evaluation transaction merely because the transaction UUID is shared. An old cancellation cannot acquire authority over a newer cleanup attempt. The adoption descriptor references the successful evaluation generation rather than treating an arbitrary same-UUID result as adoption evidence.

The separate protocol-2 top-level recoveries array, deterministic oldest-per-target selection, prefixed UUID section identity, untouched current rows, historical-key nonauthority, explicit confirmation, and protected owned-staging scope remain unchanged and suitable. R1 CLEANUP-M1 stays closed at the design level.

## Required implementation verification

Carry forward the concrete decoder, empty/view-only model list, dedicated dispatch, unchanged model-row classification, terminal-plus-new-projection, and actual CLI-owner tests recorded in `cleanup-recovery-r2-astra.md`.

Additionally exercise two cleanup attempts with the same transaction UUID and distinct generations. Repeated projection/start of the first reserved generation must be idempotent. Once the next attempt is reserved/running, late cancellation/reconciliation/start requests for the first generation must not mutate it; old terminal readback, when returned, must remain scoped to the original generation and never satisfy the new app transcript. Test generation mismatch before mutation, original prepare/evaluate versus cleanup kind mismatch, delayed event delivery, restart with persisted pending selectors, and adoption result retrieval bound to its evaluation generation. Keep attempt history/terminal outcomes distinguishable without overwriting the original transaction terminal record.

The final producer/consumer implementation must keep the new selector confined to this build’s unshipped protocol-2/action and transaction-event contract. Protocol-1 encoding and closed decoding must remain unchanged. A protocol-2 peer missing selectors must not gain actionable new mutation/control authority through default generation values.

## Remaining independent gate

This approval does not approve executable custody or helper lifecycle. The separately authored transaction-control addendum still requires its independent exact-digest gate, and combined cleanup/control implementation remains prohibited until both gates pass. Its final Action/event/CLI selector grammar must agree with this r3 artifact; any mismatch requires an explicit reviewed contract delta before implementation.

Final combined-diff review and fresh fixture tests remain mandatory. No physical MLX, B1-T10/B1-T11, release or production qualification is established here, and unrelated audit findings remain open until their own corrections are verified.
