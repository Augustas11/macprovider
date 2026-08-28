# SPEC-046 - Provider BYOM Discovery

**Version:** 0.1.0

```json
{
  "spec_id": "SPEC-046",
  "title": "Provider BYOM Discovery",
  "version": "0.1.0",
  "path": "specs/SPEC-046-provider-byom-discovery.md",
  "status": "draft",
  "owner": "@Augustas11",
  "authority_domains": ["provider-byom-discovery"],
  "supersedes": [],
  "depends_on": ["SPEC-001", "SPEC-010", "SPEC-011", "SPEC-013", "SPEC-018", "SPEC-019", "SPEC-023", "SPEC-032", "SPEC-033", "SPEC-045"],
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

SPEC-010 remains authoritative for signed catalog model identity. SPEC-046 may compare a discovered candidate with catalog identifiers, but it must not create canonical catalog identities or imply that a candidate is catalog-backed.

SPEC-011 remains authoritative for warm-swap and loaded-model state. SPEC-046 evaluation must not switch the production serving model unless a later SPEC-011-compatible transaction explicitly does so.

SPEC-013 and SPEC-023 remain authoritative for installer/autotune recommendation policy and signed static feed trust. SPEC-046 may reuse fit estimation and local artifact discovery helpers, but it must not consume candidate feeds as admission authority.

SPEC-018 and SPEC-019 remain authoritative for tool-calling and structured-output semantics. SPEC-046 may report whether an adapter appears to pass through those fields, but it must not redefine the semantics.

SPEC-032 and SPEC-033 remain authoritative for hardware evidence and verifier semantics. SPEC-046 may report local fit estimates as advisory input only.

SPEC-045 is related local endpoint prior art. SPEC-046 must reuse its loopback, local-auth, bounded-parser, and redaction posture where a provider-side adapter speaks HTTP locally, but SPEC-046 does not proxy buyer traffic.

## 3. Normative requirements

**SPEC-046-R001 - CLI-owned discovery commands.** `macprovider-cli` MUST expose a provider-local discovery command with stable spelling reserved for `models discover --json` and a provider-local evaluation command with stable spelling reserved for `models evaluate <candidate-id-or-ref> --json`. Both commands MUST emit JSON only to stdout when `--json` is set and MUST emit warnings, progress, and redacted diagnostics to stderr. If Malibu consumes discovery in a later app release, it MUST consume the CLI projection or capability-negotiated equivalent and MUST NOT inspect runtime files, local HTTP endpoints, or model caches directly.

**SPEC-046-R002 - Safe adapter scope.** Discovery adapters MUST be explicit, bounded, and local. The v0.1 adapter enum is `mlx_cache`, `ollama_loopback`, `lmstudio_loopback`, `llamacpp_loopback`, and `openai_compatible_loopback`. Loopback HTTP adapters MUST accept only IPv4 loopback addresses in `127.0.0.0/8` and IPv6 `::1`; they MUST reject wildcard, LAN, VPN, public, private non-loopback, link-local, multicast, Unix-domain, unresolved, redirected, proxied, or hostname-expanded non-loopback targets. The CLI MUST NOT scan ports or networks; an adapter endpoint is either a well-known loopback default for that runtime or an operator-supplied loopback origin. Adapter requests MUST use short timeouts, bounded response headers, bounded decoded body bytes, bounded JSON nesting/parser work, and a closed endpoint allowlist. Adapter failures MUST produce warning codes, not partial trust claims.

**SPEC-046-R003 - Candidate identity schema.** Discovery output MUST use a closed JSON envelope with `schema: "provider_byom_discovery.v1"`, `generated_at`, `cli_version`, `projection_sequence`, `adapters`, `candidates`, and `warnings`. Each candidate MUST include `candidate_id`, `runtime_source`, `display_name`, `served_model_ref`, nullable `catalog_model_key`, `identity_state`, `locality`, nullable `estimated_gb`, nullable `context_window_tokens`, `capabilities`, `readiness_state`, `fit_state`, `evaluation_state`, `admission_state`, and `warning_codes`. `candidate_id` MUST be stable for the same runtime source and served model reference on the same host but MUST NOT be derived from provider id, wallet, username, hardware serial, MAC address, stable hardware UUID, absolute private path, bearer token, or endpoint credential. The v0.1 allowed construction is `byom_` plus base32url without padding of `HMAC-SHA256(local_discovery_namespace, runtime_source || 0x00 || normalized_served_model_ref)`, where `local_discovery_namespace` is a CLI-owned random 256-bit secret stored in a user-private config file with user-only permissions and never sent to the coordinator; if that namespace is missing or unreadable, the CLI MUST emit `candidate_id_unstable` and MUST NOT submit offers until a valid namespace exists. `identity_state` enum values are `catalog_matched`, `artifact_hash_available`, `runtime_reported`, `opaque_endpoint`, and `unknown`. `admission_state` enum values are `local_only`, `not_offered`, `offerable`, `offer_submitted`, `offer_rejected`, `sandbox_probe_only`, `network_visible_unpriced`, `network_admitted_unsettled`, `catalog_priced`, `settlement_capable`, `withdrawn`, and `revoked`; SPEC-046 may only report SPEC-047 network states supplied by the coordinator or local defaults `local_only`, `not_offered`, and `offerable`, and MUST NOT promote a candidate into a network state by itself.

**SPEC-046-R004 - Advisory capability reporting.** Capability fields discovered from local runtimes are advisory until confirmed by evaluation or network admission. The v0.1 capability object MUST include nullable booleans for `chat_completions`, `streaming`, `tool_call_passthrough`, `structured_output_passthrough`, `json_mode`, and `usage_reporting`, plus nullable numeric `max_context_tokens` and nullable strings for `quantization`, `family`, and `runtime_version`. Unknown values MUST be null, not false. Malibu and CLI human-readable output MUST label unevaluated capability values as detected or reported, not verified.

**SPEC-046-R005 - Local evaluation harness.** `models evaluate` MUST run through a CLI-owned harness that exercises the candidate using MacProvider-shaped requests without sending buyer traffic, creating provider credit, mutating production serving configuration, or claiming settlement evidence. Evaluation MUST have explicit timeout, token, request-count, and output-size limits. Any temporary prompt, response, or adapter transcript MUST stay local and be redacted or content-hashed in machine output unless the operator supplies a dedicated diagnostic-export flag defined by a later spec. Evaluation output MUST use `schema: "provider_byom_evaluation.v1"` and include the candidate identity, adapter identity, health result, latency/token-throughput measurements when available, usage-reporting source, capability test results, fit estimate source, mutation summary, warning codes, and whether SPEC-047 offer preconditions appear satisfied.

**SPEC-046-R006 - No hidden mutation or download.** Discovery MUST be read-only. Evaluation MAY create bounded temporary files under a CLI-owned temporary directory, but it MUST NOT download model artifacts, promote model symlinks, edit provider config, start login items, install packages, change the current production model, or persist adapter credentials. Any evaluation that would require a runtime to download or prepare weights MUST fail with `requires_preparation` unless a later preparation spec defines confirmation, staging, cancellation, and cleanup invariants equivalent to SPEC-044 preparation safety.

**SPEC-046-R007 - Privacy and secret boundary.** Discovery and evaluation MUST NOT expose or persist provider bearer tokens, buyer API keys, wallet secrets, endpoint credentials, environment variables, home-directory paths, usernames, raw local absolute paths, hardware serials, MAC addresses, stable hardware UUIDs, raw prompts, raw completions, raw receipts, raw adapter error bodies, or full local endpoint URLs that contain secret-bearing components. Diagnostics MAY expose redacted adapter type, redacted host class, candidate display name, catalog match key, runtime version, and warning codes sufficient for support. Logs and JSON output MUST distinguish redacted values from absent values.

**SPEC-046-R008 - Release evidence.** Promotion beyond draft MUST include automated tests for adapter allowlisting, loopback rejection, bounded HTTP parsing, malformed adapter responses, candidate schema validation, advisory capability nullability, catalog-match labeling, read-only discovery, evaluation timeouts and byte caps, no production config mutation, path/token redaction, unevaluated copy restrictions, and SPEC-047 state consumption. Production promotion MUST include a signed journey result covering at least one MLX-cache candidate, one loopback runtime candidate, one opaque endpoint candidate, one adapter failure, and one evaluated-but-not-network-admitted candidate.

## 4. Implementation, tests, and journeys

The intended implementation is a CLI-first projection:

1. Add discovery adapter interfaces behind `macprovider-cli models discover --json`.
2. Add the closed discovery envelope and schema tests.
3. Add `macprovider-cli models evaluate <candidate> --json` with a bounded local harness.
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

- v0.1.0 - Initial draft for issue #1240. Establishes CLI-first provider BYOM discovery/evaluation and separates local inventory from paid network admission.
