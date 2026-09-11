# SPEC-046 - Provider BYOM Discovery

**Version:** 0.1.3

```json
{
  "spec_id": "SPEC-046",
  "title": "Provider BYOM Discovery",
  "version": "0.1.3",
  "path": "specs/SPEC-046-provider-byom-discovery.md",
  "status": "draft",
  "owner": "@Augustas11",
  "authority_domains": ["provider-byom-discovery"],
  "supersedes": [],
  "depends_on": ["SPEC-001", "SPEC-010", "SPEC-011", "SPEC-013", "SPEC-018", "SPEC-019", "SPEC-023", "SPEC-032", "SPEC-033", "SPEC-045", "SPEC-047"],
  "implementation_status": "pending-reconciliation",
  "production_status": "not-deployed",
  "last_reconciled_commit": null,
  "last_reconciled_at": null,
  "evidence": [],
  "requirement_id_migration": "complete",
  "gap": {
    "verdict": "DECISION_REQUIRED",
    "owner": "@Augustas11",
    "issue": "https://github.com/Augustas11/macprovider/issues/1240",
    "rationale": "Issue #1240 changes the Malibu model strategy from catalog-first discovery to provider-local BYOM discovery while keeping paid network admission separate. No provider-side discovery/evaluation contract exists today."
  }
}
```

## 1. Purpose and scope

SPEC-046 defines the CLI-owned provider-local discovery and evaluation surface for bring-your-own-model candidates. The goal is to let providers see and test locally available models and local runtime endpoints without waiting for Malibu or MacProvider operators to add each model to the signed network catalog.

Discovery is inventory, not earning. A candidate discovered under this spec is not buyer-routable, catalog-priced, settlement-capable, trust-tiered, or provider-creditable until a separate network admission contract admits it under SPEC-047 and the money-path owner specs.

The first release is CLI-first. Malibu may later render this information, but v0.1 requires the stable behavior to exist in `macprovider-cli` before any app view depends on it.

Accepted journey id: `JOURNEY-PROVIDER-BYOM-DISCOVERY`.

### Explicit non-goals

SPEC-046 does not create a public gateway, buyer API surface, coordinator routing state, provider payout rule, rate-card entry, model catalog entry, or settlement-capable receipt profile.

SPEC-046 does not authorize `macprovider-cli` to bind public listeners, scan LAN/public hosts, download arbitrary weights, execute model repository code, install runtimes, mutate provider serving config, or upload raw local transcripts.

SPEC-046 does not allow Malibu or the CLI to present discovered candidates as higher-paying, verified, trusted, catalog-priced, settlement-capable, or eligible to earn.

SPEC-046 does not replace SPEC-045. SPEC-045 is buyer-side local endpoint mode. SPEC-046 is provider-side local model/runtime discovery and evaluation.

## 2. Dependencies and authority

SPEC-046 owns `provider-byom-discovery`: local runtime adapter discovery, candidate identity projection, local evaluation, discovery privacy, and the CLI command contract for provider-side BYOM candidates.

SPEC-001 remains authoritative for the `macprovider-cli` binary lifecycle, provider process boundaries, control socket conventions, and provider-side serving behavior. SPEC-046 consumes that authority by reserving provider-local `models discover` and `models evaluate` behavior.

SPEC-001 §6.14a owns the model command taxonomy and the legacy JSON
compatibility oracle. SPEC-046 discovery/evaluation MUST remain separate from
the existing `models list` / `models browse` surfaces and MUST NOT reuse
`models_list.v1`, `models_browse.v1`, `model_catalog_error.v1`,
`model_catalog_json_v1`, `models list.v1`, or `models browse.v1` for BYOM
candidate inventory.

SPEC-010 remains authoritative for signed catalog model identity. SPEC-046 may compare a discovered candidate with catalog identifiers, but it must not create canonical catalog identities or imply that a candidate is catalog-backed.

SPEC-011 remains authoritative for warm-swap and loaded-model state. SPEC-046 evaluation must not switch the production serving model unless a later SPEC-011-compatible transaction explicitly does so.

SPEC-013 and SPEC-023 remain authoritative for installer/autotune recommendation policy and signed static feed trust. SPEC-046 may reuse fit estimation and local artifact discovery helpers, but it must not consume candidate feeds as admission authority.

SPEC-018 and SPEC-019 remain authoritative for tool-calling and structured-output semantics. SPEC-046 may report whether an adapter appears to pass through those fields, but it must not redefine the semantics.

SPEC-032 and SPEC-033 remain authoritative for hardware evidence and verifier semantics. SPEC-046 may report local fit estimates as advisory input only.

SPEC-045 is related local endpoint prior art. SPEC-046 must reuse its loopback, local-auth, bounded-parser, and redaction posture where a provider-side adapter speaks HTTP locally, but SPEC-046 does not proxy buyer traffic.

## 3. Normative requirements

**SPEC-046-R001 - CLI-owned discovery commands.** `macprovider-cli` MUST expose a provider-local discovery command with stable spelling reserved for `models discover --json` and a provider-local evaluation command with stable spelling reserved for `models evaluate <candidate-id-or-ref> --json`. Both commands MUST emit JSON only to stdout when `--json` is set and MUST emit warnings, progress, and redacted diagnostics to stderr. The commands MUST follow the SPEC-001 §6.14a taxonomy: `models discover` is provider-local BYOM inventory, `models evaluate` is bounded local evaluation, and neither command replaces or extends the legacy catalog browse/list schemas. If Malibu consumes discovery in a later app release, it MUST consume the CLI projection or capability-negotiated equivalent and MUST NOT inspect runtime files, local HTTP endpoints, or model caches directly.

**SPEC-046-R002 - Safe adapter scope.** Discovery adapters MUST be explicit, bounded, and local. The v0.1 adapter enum is `mlx_cache`, `ollama_loopback`, `lmstudio_loopback`, `llamacpp_loopback`, and `openai_compatible_loopback`. Loopback HTTP adapters MUST accept only IPv4 loopback addresses in `127.0.0.0/8` and IPv6 `::1`; they MUST reject wildcard, LAN, VPN, public, private non-loopback, link-local, multicast, Unix-domain, unresolved, redirected, proxied, or hostname-expanded non-loopback targets. The CLI MUST NOT scan ports or networks; an adapter endpoint is either a well-known loopback default for that runtime or an operator-supplied loopback origin. Adapter requests MUST use short timeouts, bounded response headers, bounded decoded body bytes, bounded JSON nesting/parser work, and a closed endpoint allowlist. Adapter failures MUST produce warning codes, not partial trust claims.

**SPEC-046-R003 - Candidate identity schema.** Discovery output MUST use a closed JSON envelope with `schema: "provider_byom_discovery.v1"`, `generated_at`, `cli_version`, `projection_sequence`, `adapters`, `candidates`, and `warnings`. Each candidate MUST include `candidate_id`, `runtime_source`, `display_name`, `served_model_ref`, nullable `catalog_model_key`, `identity_state`, `locality`, nullable `estimated_gb`, nullable `context_window_tokens`, `capabilities`, `readiness_state`, `fit_state`, `evaluation_state`, `admission_state`, `admission_state_source`, `provider_guidance`, and `warning_codes`. `candidate_id` MUST be stable for the same runtime source and served model reference on the same host but MUST NOT be derived from provider id, wallet, username, hardware serial, MAC address, stable hardware UUID, absolute private path, bearer token, or endpoint credential. The v0.1 allowed construction is `byom_` plus base32url without padding of `HMAC-SHA256(local_discovery_namespace, runtime_source || 0x00 || normalized_served_model_ref)`, where `local_discovery_namespace` is a CLI-owned random 256-bit secret stored in a user-private config file with user-only permissions and never sent to the coordinator; if that namespace is missing or unreadable, the CLI MUST emit `candidate_id_unstable` and MUST NOT submit offers until a valid namespace exists. `candidate_id` is a provider-local candidate key, not a global model key; the coordinator MUST NOT use it alone to deduplicate model supply across providers. The `provider_guidance` object MUST include `state_label_key`, `state_meaning_key`, `next_action`, nullable `transition_reason_code`, and `earning_path_class`; those fields are localization-safe keys or closed enums for CLI/Malibu presentation and MUST NOT contain raw prompts, completions, paths, endpoints, or secrets. `identity_state` enum values are `catalog_matched`, `artifact_hash_available`, `runtime_reported`, `opaque_endpoint`, and `unknown`. `locality` enum values are `local_artifact`, `loopback_runtime`, `opaque_local_endpoint`, and `unknown`. `readiness_state` enum values are `ready`, `needs_runtime`, `needs_weights`, `requires_preparation`, `unreachable`, and `unknown`. `fit_state` enum values are `fits`, `does_not_fit`, and `unknown`. `evaluation_state` enum values are `not_evaluated`, `running`, `passed`, `failed`, `timed_out`, and `blocked`. `admission_state_source` enum values are `local_default` and `coordinator`; `local_default` states are advisory CLI inventory state, while `coordinator` states are readback from SPEC-047 admission authority. `admission_state` enum values are `local_only`, `not_offered`, `offerable`, `offer_submitted`, `offer_rejected`, `sandbox_probe_only`, `network_visible_unpriced`, `network_admitted_unsettled`, `catalog_priced`, `settlement_capable`, `withdrawn`, and `revoked`; SPEC-046 may only report SPEC-047 network states supplied by the coordinator or local defaults `local_only`, `not_offered`, and `offerable`, and MUST NOT promote a candidate into a network state by itself. `provider_guidance.next_action` enum values are `fix_local_blocker`, `evaluate`, `offer_dry_run`, `submit_offer`, `revise_and_reoffer`, `check_status`, `withdraw`, `wait_for_coordinator`, `maintain_runtime`, and `none`. `provider_guidance.earning_path_class` enum values are `local_inventory_only`, `not_earning_yet_catalog_or_receipt_path_exists`, `no_earning_path_in_v0_1`, and `settlement_capable`. The warning-code enum is `candidate_id_unstable`, `adapter_unavailable`, `adapter_timeout`, `adapter_rejected_non_loopback`, `adapter_malformed_response`, `adapter_response_truncated`, `catalog_match_unverified`, `capability_unevaluated`, `evaluation_required`, `evaluation_failed`, `requires_preparation`, `namespace_permission_invalid`, and `coordinator_state_unavailable`.

`provider_guidance.earning_path_class: "settlement_capable"` is a conditional
eligibility class owned by SPEC-047. It means only that the provider/candidate
pair may participate in positive settlement for a later request that satisfies
every route-time and verified-receipt predicate. It does not mean the candidate
is prepared, serving, receiving demand, currently earning income, or guaranteed
to receive or settle a request. Human rendering MUST use the exact SPEC-001
source verdict **Eligible to earn on qualifying settled requests** and MUST NOT
substitute current-income wording.

Redaction provenance extends the warning-code enum above with `capability_family_redacted`, `capability_quantization_redacted`, `capability_runtime_version_redacted`, and `model_reference_redacted`. R007 defines their field and warning-array placement. These codes use the existing v1 envelope keys and nullable capability types; they do not add a capability value, admission state, or trust claim.

For `admission_state_source: "local_default"`, the CLI MUST use this local-state ladder:

| Local state | Provider-facing meaning | Provider next action | Local transition rule |
|---|---|---|---|
| `local_only` | The candidate is usable only as local inventory because identity, readiness, fit, adapter safety, or operator policy is insufficient for offering. It is not network-routable or earning-eligible. | Fix the blocking local condition or run `models evaluate <candidate> --json` when evaluation is available. | May become `offerable` only after local checks show safe loopback/locality, stable candidate id, acceptable readiness, and no blocking warning code. |
| `offerable` | The candidate appears locally eligible to preflight an offer, but the coordinator has not accepted any network admission state. It is not network-routable or earning-eligible. | Run `models offer <candidate> --dry-run --json`, preferably after evaluation. | May enter SPEC-047 `offer_submitted` only through a provider-signed offer; if coordinator readback confirms no active offer, the CLI MUST report `admission_state_source: "coordinator"` with `admission_state: "not_offered"` rather than treating that readback as a local default. |
| `not_offered` | No active coordinator offer is known for this candidate from this provider. With `local_default`, this means coordinator state is unavailable or has not been queried; with `coordinator`, it is authoritative SPEC-047 readback. | Run status readback, offer dry-run, or submit a refreshed offer if local checks still pass. | May become `offerable` when local checks pass without coordinator readback, or may enter SPEC-047 `offer_submitted` only through a provider-signed offer. |

The same `not_offered` value may appear with either `admission_state_source`; callers MUST read the source field before deciding whether the state is local advisory inventory or coordinator readback.

When coordinator reachability changes, a locally eligible candidate may move between `offerable` and `not_offered` without provider action; this label change is action-neutral unless the source becomes `coordinator` and supplies a SPEC-047 state or reason code.

**SPEC-046-R004 - Advisory capability reporting.** Capability fields discovered from local runtimes are advisory until confirmed by evaluation or network admission. The v0.1 capability object MUST include nullable booleans for `chat_completions`, `streaming`, `tool_call_passthrough`, `structured_output_passthrough`, `json_mode`, and `usage_reporting`, plus nullable numeric `max_context_tokens` and nullable strings for `quantization`, `family`, and `runtime_version`. Unknown values MUST be null, not false. Malibu and CLI human-readable output MUST label unevaluated capability values as detected or reported, not verified.

**SPEC-046-R005 - Local evaluation harness.** `models evaluate` MUST run through a CLI-owned harness that exercises the candidate using MacProvider-shaped requests without sending buyer traffic, creating provider credit, mutating production serving configuration, or claiming settlement evidence. Evaluation MUST have explicit timeout, token, request-count, and output-size limits. Any temporary prompt, response, or adapter transcript MUST stay local and be redacted or content-hashed in machine output unless the operator supplies a dedicated diagnostic-export flag defined by a later spec. Evaluation output MUST use `schema: "provider_byom_evaluation.v1"` and include the candidate identity, adapter identity, health result, latency/token-throughput measurements when available, usage-reporting source, capability test results, fit estimate source, mutation summary, provider guidance including `earning_path_class`, warning codes, and whether SPEC-047 offer preconditions appear satisfied.

**SPEC-046-R006 - No hidden mutation or download.** Discovery MUST be read-only. Evaluation MAY create bounded temporary files under a CLI-owned temporary directory, but it MUST NOT download model artifacts, promote model symlinks, edit provider config, start login items, install packages, change the current production model, or persist adapter credentials. Any evaluation that would require a runtime to download or prepare weights MUST fail with `requires_preparation` unless a later preparation spec defines confirmation, staging, cancellation, and cleanup invariants equivalent to SPEC-044 preparation safety.

**SPEC-046-R007 - Privacy and secret boundary.** Discovery and evaluation MUST NOT expose or persist provider bearer tokens, buyer API keys, wallet secrets, endpoint credentials, environment variables, home-directory paths, usernames, raw local absolute paths, hardware serials, MAC addresses, stable hardware UUIDs, raw prompts, raw completions, raw receipts, raw adapter error bodies, or full local endpoint URLs that contain secret-bearing components. Diagnostics MAY expose redacted adapter type, redacted host class, candidate display name, catalog match key, runtime version, and warning codes sufficient for support. Logs and JSON output MUST distinguish redacted values from absent values.

For discovery-originated optional capability labels and model references, that distinction MUST use the following closed provenance mapping:

| Withheld input | Warning code | JSON placement and retained value |
|---|---|---|
| `capabilities.family` | `capability_family_redacted` | Selected candidate `warning_codes`; capability value is null. |
| `capabilities.quantization` | `capability_quantization_redacted` | Selected candidate `warning_codes`; capability value is null. |
| `capabilities.runtime_version` | `capability_runtime_version_redacted` | Selected candidate `warning_codes`; capability value is null. |
| Unsafe model reference | `model_reference_redacted` | Source adapter `warning_codes`; the unsafe candidate is omitted. |

Missing fields and explicit JSON nulls MUST NOT emit a redaction warning. A present string rejected by the existing privacy/label policy, including an empty, whitespace-only, or oversized string, MUST emit its mapped warning. The withheld optional capability value MUST remain null; a literal redaction sentinel MUST NOT replace it. Safe labels retain their ordinary advisory value without a redaction warning. Malformed JSON or unexpected non-string field types remain malformed-response diagnostics, not evidence that a secret was present; raw rejected values MUST NOT be reflected in those diagnostics.

An unsafe model reference MUST NOT produce a placeholder candidate. The CLI MUST NOT synthesize a candidate id, display name, or served model reference from a withheld identity. Safe records in the same bounded inventory MAY remain visible with their normal checks. An otherwise valid, successfully read inventory containing only withheld model references MUST retain `model_reference_redacted` on its adapter even when its candidate list is empty; an actually empty inventory MUST NOT carry that code. Adapter status `ok` denotes successful bounded parsing, not an assertion that no records were withheld. Missing or wrong-type model-reference fields MUST report `adapter_malformed_response` rather than disappear silently or be misclassified as privacy redaction. These diagnostics MUST NOT expand existing parser, record-count, or byte limits to inspect or count additional records.

Discovery MUST include the union of candidate and adapter redaction codes in its top-level `warnings`. Evaluation of a retained candidate MUST carry that candidate's optional-label redaction codes into its existing evaluation warning array; an omitted identity MUST NOT become evaluable through a placeholder. The CLI MUST deduplicate warning codes within each warning array and emit the same fixed codes in stderr diagnostics under R001. Codes MUST NOT include the withheld value, its hash, its length, a record index, or a count; diagnostic output MUST NOT retain or serialize raw rejected content. No new JSON fields or dynamic warning suffixes are permitted by this mapping.

Optional-label redaction warnings MUST NOT be admission blockers and MUST NOT be substituted with `adapter_malformed_response`. They do not erase an independent identity, readiness, fit, namespace, adapter-safety, or evaluation blocker. Adapter-level `model_reference_redacted` MUST NOT block an unrelated retained safe candidate, and MUST NOT make the omitted candidate offerable. Redaction codes MUST NOT grant coordinator authority, routing, earning, catalog pricing, or settlement capability. Consumers that do not recognize these codes MUST NOT treat the affected projection as actionable, whether or not they display the unknown codes; they MUST preserve or report the incompatibility without raw content.

Redaction provenance is local diagnostic metadata, not an advisory capability value. Implementations MUST NOT add redaction fields to a SPEC-047 offer package or substitute warning text for a nullable capability claim. A selected candidate's withheld capability remains null when projected into an offer; SPEC-047 retains authority over its closed offer schema and acceptance rules.

The R008 automated-test gate for this mapping MUST cover absent/null, safe, withheld, and wrong-type optional labels separately; mixed and all-withheld inventories; stderr/JSON parity without raw content; parser-bound preservation; non-blocking optional warnings with independent blockers retained; and offer projection retaining null capability values. Signed journey evidence remains pending; text-level contract tests do not satisfy that runtime or release-evidence gate. The current adapters do not collect runtime version labels, so `capabilities.runtime_version` remains absent/null without a redaction warning; collecting that field in a future adapter must apply this same provenance mapping.

**SPEC-046-R008 - Release evidence.** Promotion beyond draft MUST include automated tests for adapter allowlisting, loopback rejection, bounded HTTP parsing, malformed adapter responses, candidate schema validation, local-state ladder meaning and next-action projection, advisory capability nullability, catalog-match labeling, read-only discovery, evaluation timeouts and byte caps, no production config mutation, path/token redaction, unevaluated copy restrictions, command-taxonomy separation from legacy `models list`/`models browse`, and SPEC-047 state consumption. Before any provider-visible human discovery/evaluation rendering ships, tests MUST reject forbidden earning-copy meanings with parity to SPEC-044-R004/R009, including claims that a discovered, evaluated, offered, or non-settlement candidate earns, is higher-paying, is buyer-routable by default, is verified, is catalog-priced, or is settlement-capable. For `settlement_capable`, every shipped localization and accessibility fixture MUST preserve **Eligible to earn on qualifying settled requests** as conditional eligibility and reject current-income, current-serving, guaranteed-demand, and guaranteed-settlement meanings. Production promotion MUST include a signed journey result covering at least one MLX-cache candidate, one loopback runtime candidate, one opaque endpoint candidate, one adapter failure, one evaluated-but-not-network-admitted candidate, and local `local_only`/`offerable`/`not_offered` state-ladder evidence.

## 4. Implementation, tests, and journeys

The intended implementation is a CLI-first projection:

1. Add discovery adapter interfaces behind `malibu-cli models discover --json`.
2. Add the closed discovery envelope and schema tests.
3. Add `malibu-cli models evaluate <candidate> --json` with a bounded local harness.
4. Persist no long-lived state except optional redacted local evaluation cache records defined by the implementation.
5. Let SPEC-047 own all coordinator submission and network state.
6. Let SPEC-044 consume only network-eligible economics after admission.

The first journey id is `JOURNEY-PROVIDER-BYOM-DISCOVERY`.

## 5. Open gaps

| Requirement/domain | Verdict | Owner | Issue | Evidence needed |
|---|---|---|---|---|
| `SPEC-046-R001..R008` | `DECISION_REQUIRED` | `@Augustas11` | `#1240` | Product approval of adapter list, CLI schema, privacy posture, evaluation harness scope, and signed discovery journey. |
| `provider-byom-discovery` | `DECISION_REQUIRED` | `@Augustas11` | `#1240` | Authority acceptance that local discovery is provider-side inventory only and cannot imply network earning or trust. |

## 6. Evidence

No implementation or production evidence exists yet.

## 7. Current contract notes

The core invariant is that local discovery is deliberately cheap and broad because it has no money-path authority. Any implementation that wants to route buyer traffic, show trusted provider economics, or create positive provider credit must leave SPEC-046 and satisfy SPEC-047 plus the settlement owner specs.

## 8. Changelog and history

- v0.1.3 - Defines `settlement_capable` guidance as conditional eligibility for
  qualifying settled requests and requires localization/accessibility tests to
  reject current-income or guaranteed-request meanings. No discovery state gains
  money-path authority.
- v0.1.2 - Define fixed redaction-provenance warning codes and null-preserving
  projection rules under R003/R007, with runtime test obligations under R008.
  Keep optional-label warnings non-blocking and unsafe identities omitted.
  This draft amendment supplies no runtime or signed journey evidence.
- v0.1.1 - Narrow contract-lock amendment for issue #1249. Registers SPEC-001
  command-taxonomy separation, forbids BYOM reuse of legacy browse/list schema
  strings, and requires forbidden earning-copy tests before provider-visible
  human rendering.
- v0.1.0 - Initial draft for issue #1240. Establishes CLI-first provider BYOM discovery/evaluation and separates local inventory from paid network admission.
