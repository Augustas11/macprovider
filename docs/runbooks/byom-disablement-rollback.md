# BYOM v0.1 Disablement & Rollback Map

**Epic:** #1240 · **Gate:** #1248 (require evidence, rollout, rollback, and
old-client compatibility before promotion).

This is the concrete answer #1248 demands: for every provider-visible and
buyer-facing BYOM surface, the exact switch that turns it off **without deleting
provider state**. "Rollback exists" is not enough — each row names the switch.

## Design fact: BYOM v0.1 is fail-closed by construction

There is **no** single BYOM feature flag, by design. v0.1 ships discovery +
evaluation + honest non-earning disclosure + a coordinator settlement-evidence
gate, and **earning is impossible regardless of state**. The money-path
backstops are hardcoded/fail-closed, so the disablement points below are
defense-in-depth for individual surfaces, not the thing standing between BYOM
and provider payouts (nothing here can pay a provider in v0.1).

## Surface-by-surface disablement

| Surface | Slice / PR | Disable switch (no state loss) | Default |
|---|---|---|---|
| Paid routing for BYOM | #1254 / #1377 | `ModelAdmissionDefaultPaidRoutingEligible` returns hardcoded `false` (`phase4-coordinator/internal/ws/model_admission.go`). No BYOM state can reach default paid routing until a later settlement slice flips it. | fail-closed (false) |
| Settlement side effects (credit/debit/ledger) | #1256 / #1379 | `Server.settlementEnforceMode()` (`phase4-coordinator/internal/buyer/server.go:7571`) reads billing `verified_model_settlement_mode`. `observe` or a nil billing store ⇒ no settlement side effects. Set/keep the mode non-`enforce` to disable. | observe (no enforce) unless configured |
| Coordinator admission endpoints (`/v1/provider/model-admission/{offers,withdrawals,status}`) | #1253/#1254 / #1375/#1377 | Endpoints are wired via `providerws.WithModelAdmissionStore(byomOfferStore)` (`phase4-coordinator/cmd/coordinator/main.go`). Hard-off = deploy a coordinator build that does not pass `WithModelAdmissionStore` (store becomes the in-memory default; provider offer/withdraw calls no-op against durable state). Provider tokens and existing admission rows are untouched. | on (fail-closed) |
| Provider CLI BYOM commands (`models discover/evaluate/offer/admission ...`) | #1249–#1254 | Client-side; harmless without a coordinator that accepts admission. Production coordinator URLs are HTTPS/WSS-only; `MACPROVIDER_BYOM_ALLOW_INSECURE_LOOPBACK_COORDINATOR` (default off) is E2E-only. To withhold from the fleet, do not cut a CLI release containing them (they stay merged-but-unreleased). | HTTPS/WSS-only |
| Malibu app catalog-economics UI | #1257 / #1380 | Gated by the checked-in capability manifest `phase3-binary/app/Sources/Malibu/Resources/MalibuModelCapabilities.json`. Remove/withhold `model_catalog_economics_v1` (and `model_ready_switch_v1`) to hide the economics rows and switch action; the app falls back to its existing static model management. No provider state touched. | on if manifest advertises the caps AND a fresh provider observation agrees |
| Catalog economics trust (rates shown) | #1256 / #1379 | Requires `rate_card_source: live_signed` + fresh signed rate card + trusted catalog authority. Revoke/expire the signed rate card ⇒ rows degrade to non-trusted (no rates), fail-closed. | requires live-signed evidence |

## Rollback of a bad promotion

- **Coordinator (Go):** redeploy the prior tagged coordinator build. The
  admission store is append-only and additive; rolling back the binary leaves
  provider tokens and any recorded admission events intact. No schema migration
  is destructive.
- **Provider CLI / Malibu.app (fleet):** a BYOM release is a normal
  Malibu.app + `macprovider-cli` release cut and rolls back the normal way — cut
  a new release from the prior stable tag; do **not** patch an immutable release
  in place. Follow `docs/runbooks/provider-cli-release-verification.md` (SHA
  byte-identity between the app-embedded and standalone `macprovider-cli`,
  updater path from the previous stable, `release-builds.tsv` row). The
  fleet-updater hazard here is standard release safety, not BYOM: BYOM enables no
  earning, so a rollback loses no money-path state.
- **Fastest partial kill without a release:** withdraw the Malibu capability
  (manifest) to hide the app UI, and keep `verified_model_settlement_mode` off —
  both are config/resource changes, no fleet update required.

## Old-client compatibility

- Pre-BYOM CLIs simply do not send admission offers; the coordinator endpoints
  are additive and unused by them.
- The Malibu economics projection is a closed, versioned schema
  (`model_catalog_economics.v1`); older apps that do not advertise the capability
  never fetch or render it.
- No existing provider/billing schema field changed meaning; admission storage is
  keyed on `(provider_id, candidate_id)`, separate from existing identities
  (#1247).

## Promotion checklist (closes #1248 + #1240)

1. `make test-byom-e2e` green + the real-Mac candidate E2E green
   (`test/e2e/byom/CANDIDATE-E2E-RUNBOOK.md`), evidence captured.
2. Gates #1243–#1247 closed with per-gate evidence.
3. This disablement/rollback map reviewed and current.
4. Coordinator admission endpoints deployed from a tag (Go).
5. Malibu.app + CLI release cut passing provider-CLI-release-verification.
6. Signed journey evidence where the governance process requires it.
