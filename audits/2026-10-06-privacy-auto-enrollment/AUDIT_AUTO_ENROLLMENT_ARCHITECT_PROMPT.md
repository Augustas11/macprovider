# Audit R1: SPEC-049 v0.2.0 automatic enrollment (ARCHITECTURE lane)

Read `audits/2026-10-06-privacy-auto-enrollment/AUDIT_AUTO_ENROLLMENT_CONTEXT.md` first; its METHOD constraint applies.

Check for this lane:

- SPEC consistency: SPEC-049 v0.2.0 and SPEC-041 v0.5.0 versus the code, including R001 (provider default-on vs other components default-off), R004 precedence, R006 approval order, R017 trigger list, R018 CLI, R020 strings (gateway, client, runbook identical), R021 suite, R024..R028, the error inventory, and §6 runbook requirement. Are any normative statements unimplemented, or any behaviour unspecified?
- Authority boundaries: SPEC-041 owns identities and pins, SPEC-049 owns enrollment and the directory, SPEC-025 owns `provider_code_identity`, SPEC-008 cross-check, SPEC-022 R-14 settlement unchanged, SPEC-042-R009 still rejects pool-scoped requests. Does any change leak into plain relay-blind, plaintext routing, settlement, or admission?
- Rollout compatibility: a new default-on CLI connecting to the current production coordinator (privacy class disabled, older parser), an older CLI connecting to the new coordinator, the coordinator enabled before the Pearl updater has staged any release metadata, release metadata lagging a CLI release, and gateway or client version skew. Does anything fail closed in a way that breaks ordinary serving?
- Key and trust model: the choice of an online dedicated directory key instead of reusing the offline static-feed keyring; custody, rotation, and compromise handling; the wallet-session limitation; whether the directory belongs on the coordinator buyer port behind the gateway.
- Operational: durable enrollment growth and retention, directory size bounds (4096 entries, 1 MiB) against fleet size, re-enrollment burden after reinstalls (state directory and Secure Enclave key persistence), release-identity reload cadence, log volume, and the `main.go`-free wiring through `NewPrivacyAuthority`.
- Governance: CONFORMANCE.json and AUTHORITY.json mappings, `specs/README.md`, promotion gate R023 unchanged, journey evidence script still validating the committed v0.1 journey.

Lane: ARCHITECTURE.
