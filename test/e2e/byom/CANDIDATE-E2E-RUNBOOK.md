# BYOM v0.1 Candidate E2E Runbook (real-Mac)

**Owner:** @SmtTheSE · **Epic:** #1240 · **Gates satisfied by a clean run:** #1245
(live non-MLX adapter proof), #1248 (current automated + real-Mac evidence).

This is the real-Mac last-mile validation the unit tests and the 3-lane audits
cannot cover: a live Ollama loopback runtime, a real coordinator admission
store, and the Malibu app consuming the CLI-owned economics projection. Run it
on the full candidate stack you build locally (same pattern as the post-1.8.117
candidate E2E), against the merged BYOM v0.1 code (main `584fe242` or later).

The hermetic harness `make test-byom-e2e` (see `README.md`) is the scaffold and
should pass first; this runbook is the manual superset that exercises real
runtimes and the app UI.

## Preconditions

- Build the candidate stack from current `main` (all 8 BYOM slices merged:
  #1368 #1370 + slice-3/4 + #1375 #1377 #1379 #1380).
- A local Ollama (or Ollama-compatible) server on loopback with at least one
  small model pulled (e.g. a 3-4B model that fits the test Mac).
- A locally-run coordinator with the admission store wired
  (`WithModelAdmissionStore`, cmd/coordinator/main.go) — the standard candidate
  coordinator already wires it.
- Malibu.app built from the same tree, pointed at the local coordinator.
- Capture all JSON outputs and app screenshots as evidence; attach to #1248.

## Part A — Provider CLI onboarding (loopback + real coordinator)

Run the closed-schema commands in order and assert the schema + fail-closed
fields on each. `MACPROVIDER_BYOM_ALLOW_INSECURE_LOOPBACK_COORDINATOR=1` is only
needed if the coordinator is on `http://127.0.0.1`; production URLs stay
HTTPS/WSS-only by default.

1. `models discover --json` → `provider_byom_discovery.v1`; the Ollama candidate
   appears with `runtime_source: "ollama_loopback"` and `admission_state_source:
   "local_default"`; discovery makes **no** coordinator request (read-only).
2. `models evaluate <ref> --json` → `provider_byom_evaluation.v1`;
   `health_result: passed`, `coordinator_state_mutated: false`.
3. `models offer <ref> --dry-run --json` → `model_admission_offer_dry_run.v1`;
   no state submitted.
4. `models offer <ref> --json` (confirm) → signed offer accepted; coordinator
   records `offer_submitted`.
5. `models admission status <ref> --json` → `model_admission_status.v1`;
   `admission_state_source: "coordinator"`; `earning_path_class` is the honest
   non-earning value; `allowed_next_states` correct.
6. `models admission withdraw <ref> --json` → `model_admission_withdraw.v1`;
   `resulting_admission_state: "withdrawn"`; re-entry requires a fresh signed
   offer.

**Fail-closed assertions (must all hold):**
- A **non-catalog** candidate never reports a positive earning path; it stays
  buyer-invisible and cannot reach paid routing.
- Provider-asserted `served_model_ref` / `catalog_model_key` never become
  catalog-verified without the trusted catalog binding.
- Endpoint/host material in a model ref is rejected (structural IP guard).

## Part B — Coordinator admission + routing gate

- Confirm a non-`settlement_capable` admission (offer_submitted / catalog_priced
  / withdrawn / revoked) is **hidden from default paid routing**:
  `/v1/models` omits it, chat/pinned/queue routing refuses it, and
  `/v1/pool/check?details=readiness|deployment` reports `buyer_serving:false`.
- Confirm `catalog_priced` / `settlement_capable` decisions require trusted
  catalog authority evidence (catalog id + body digest + expected model hash +
  `SnapshotManifestV1`); a decision without it is rejected.
- Confirm **no** ledger credit / buyer-final debit / payout-ready row is created
  for any BYOM route in this run (v0.1 enables no earning).

## Part C — Malibu app consumption

Drive the app's model-management surface and verify the presentation contract:
- Catalog-economics rows come only from the signed CLI projection; malformed /
  duplicate-key / unknown-field input fails the whole projection closed.
- A `catalog_priced` (non-settlement) row: signed rates are shown **with** the
  "No provider credit yet; catalog and receipt checks are still required."
  disclosure — including when the row is switchable ("Ready to switch").
- The coordinator-verified catalog identity is shown as authoritative, with the
  provider-reported name labelled "Provider-reported:".
- Non-catalog / local-only rows show explicit null money fields and are never
  presented as earning-eligible.
- VoiceOver reads the full rate-variability disclosure verbatim.

## Part D — Disablement proof (feeds #1248)

Exercise the switches in `docs/runbooks/byom-disablement-rollback.md` and confirm
each disables the surface **without deleting provider state**:
- Malibu UI off by withdrawing the capability from `MalibuModelCapabilities.json`.
- Settlement side effects stay off unless billing `verified_model_settlement_mode`
  is `enforce`.
- The paid-routing backstop (`ModelAdmissionDefaultPaidRoutingEligible`) stays
  fail-closed.

## Exit criteria

- Parts A–C green with captured JSON + screenshots.
- Part D disablement proven.
- `make test-byom-e2e` green in the same environment.
- Evidence attached to #1248 and the #1245 adapter proof noted. Only then does
  BYOM promotion (release cut) proceed.
