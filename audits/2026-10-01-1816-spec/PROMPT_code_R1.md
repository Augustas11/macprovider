LANE: CODE/CORRECTNESS. Focus on internal consistency between the amended SPECs (SPEC-042/047/005/022/010/023/032/043), the encodings, state machines, closed enums, versioning and changelog, CONFORMANCE.json rows, and whether each normative rule is implementable against the cited code anchors without contradiction.

# Audit — Pool-scoped model admission and pricing SPEC amendments (#1816)

METHOD CONSTRAINT (read first): this is a SPEC correctness, security-boundary,
and governance review. Review the COMPLETE working-tree diff against
`origin/main`: `git diff origin/main`. This branch intentionally changes only
SPEC markdown and `specs/CONFORMANCE.json`; do not propose implementation code
in this pass. Evaluate the normative contract, internal consistency, migration
rules, and whether the pending conformance gaps honestly describe the absent
implementation.

## What the change does

Issue #1816 lets an enforce-mode Trusted Pool admit, route, quote, and pay for
a model absent from the global signed catalog. The creator signs a bounded
`model_entries[]` entry into PolicyCore v3; that entry is authoritative only
inside the same pool. The change also adds creator-signed member attestations,
pool-manifest admission bindings and evidence, pool-only trusted pricing,
replayable route-snapshot provenance, buyer disclosure, catalog-intake signals,
and a hello-gate sandbox exemption. Global routes remain catalog-only and a
pool binding never becomes `settlement_capable`.

## Invariants to verify (challenge them)

- PolicyCore v1/v2 bytes and verification remain unchanged; v2 has no model
  entries or member attestations, v3 is domain-separated, closed, bounded, and
  canonical. Downgrade, duplicate id/hash, malformed entry, and stale or rolled
  back generation paths fail closed.
- A `pool/<pool_id>/<slug>` identity cannot equal or shadow a SPEC-010 canonical
  id and cannot escape its signing pool. Exact artifact algorithm/hash matching
  is the only identity join; provider names and asserted catalog ids never bind.
- Pricing comes from the current creator-signed entry, is bounded by the signed
  network rate card, and is consumed only by quote/reservation/snapshot paths
  carrying the same pool and manifest provenance. Formula, platform fee, and
  historical no-repricing rules are unchanged.
- Creator-attested non-creator members are explicitly named and runtime-scoped;
  removal takes effect at the next generation. The creator is accountable, and
  a disputed label falls back to byte-estimated zero rather than earning.
- Pool bindings are routeable only on the same pool, remain
  `catalog_priced`/`pool_attested_earning`, and never assert global catalog
  identity, recommendation, network verification, or `settlement_capable`.
- Route snapshots bind the exact expected hash source and manifest digest so a
  verifier can replay the accepted core. Existing catalog rows remain
  compatible and no trust claim beyond SPEC-042-R006 is introduced.
- Pool-proven intake counts only final paid, verified, non-disputed evidence;
  permits only an out-of-band `listed` addition; and cannot auto-promote to
  `recommendable` or create permissionless global earning.
- Every new requirement has a `pending` CONFORMANCE row with an honest gap; no
  requirement is promoted and no executable source is changed.

## Lanes to report (this pass is: {{LANE}})

Report findings as CRITICAL / HIGH / MEDIUM / LOW / INFO. The merge bar is
0 CRITICAL, 0 HIGH, 0 MEDIUM.

- CODE: implementability, closed schemas/enums, field names, bounds, migration
  rules, state transitions, revision semantics, and contradictions with the
  cited current storage/runtime anchors.
- SECURITY: signature/domain separation, identity confusion or shadowing,
  cross-pool/global scope escape, rollback/replay, membership revocation,
  pricing substitution, license attestation, and evidence laundering.
- ARCHITECTURE: ownership boundaries across SPEC-005/010/022/023/032/042/043/047,
  global-versus-pool trust semantics, compatibility with existing requirements,
  and whether the conformance gaps map cleanly to future implementation slices.

End with a line
`VERDICT: <N> CRITICAL / <N> HIGH / <N> MEDIUM / <N> LOW / <N> INFO`.
Be specific and cite `file:line`. Do not invent findings to fill a lane.

Output: a findings list, each item with a severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, the defect, and a concrete fix. End with a totals line: 'TOTALS: C=<n> H=<n> M=<n> L=<n> I=<n>'. Do not edit files.
