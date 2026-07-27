# BLIND RE-VERIFY — SPEC-037 KV-survival IMPL — ARCHITECT lane

You are an independent architecture auditor. You have NO prior context on this
change and no knowledge of any earlier review. Judge only what the code does and
how it fits the system.

## Feature under review

`macprovider-cli` (Swift, `phase3-binary/`) has an encrypted provider-local KV
disk tier behind the in-RAM `ConversationCache`, letting a reusable conversation
KV prefix survive a provider restart. Residency-only, default-off,
synthetic-key-only. Normative spec: `specs/SPEC-037-kv-survival-restart.md`
(FR-KVP1..13). Read the spec's FR-KVP1 (residency-only), FR-KVP4 (promotion
validation), FR-KVP5 (fail-closed to miss), and the purge/revocation FRs.

## Scope — audit ONLY this delta

Read `audits/2026-07-26/REVERIFY_DELTA.diff` and the full current text of every
file it touches. The delta: (1) load-time geometry seeding so the first
post-restart request can promote; (2) `kv-cache purge`/`status` decoupled from
disk-tier enablement so a running serve services the in-RAM cache even when the
disk tier is off; (3) uninstall wired to `purgeAllAndForget`.

## What to hunt (seam & contract level)

- **Layering.** Does load-time seeding put a warmup-prefill dependency in the
  right place? Is `ModelRuntime` reaching across a boundary it shouldn't, or
  duplicating state that should live in one owner? Is the seeded template a
  parallel source of truth that could drift from the on-disk manifest?
- **Contract honesty at the control surface.** With the tier disabled, `purge`/
  `status` now report on the RAM cache. Is the reported `detail`/`enabled`
  semantics unambiguous to an operator/script — can a caller tell whether disk
  material still exists? Does the disabled-path contract quietly promise more
  than it delivers (e.g. `--forget` implying disk shred while disabled)?
- **Uninstall ordering.** Is `purgeAllAndForget`-before-file-removal the correct
  order, and is best-effort-on-failure the right policy vs fail-loud? Could a
  half-done uninstall leave the system worse than either extreme?
- **FR-KVP1 / residency-only** preserved end-to-end across the delta.
- **Idempotence & re-entrancy** of the new operator paths (purge twice, uninstall
  after a prior partial uninstall, seed after a real commit already learned).
- **Spec conformance drift:** does anything in the delta contradict a MUST in
  SPEC-037, or add operator-visible surface the spec doesn't sanction?

Report findings as a numbered list with severity, file:line (or spec section),
defect, and fix. A clean delta is an acceptable verdict. End with exactly one line:

`VERDICT: PASS|FAIL — X CRITICAL / Y HIGH / Z MEDIUM / W LOW / V INFO`

PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.
