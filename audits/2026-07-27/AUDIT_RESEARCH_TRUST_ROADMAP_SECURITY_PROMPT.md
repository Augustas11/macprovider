# Security audit — RESEARCH-TRUST-MINIMIZED-BENCHMARK-CATALOG-ROADMAP.md

ROLE: security auditor. Target is a research/design document, not code: `specs/RESEARCH-TRUST-MINIMIZED-BENCHMARK-CATALOG-ROADMAP.md` in this checkout. The repo code is available for cross-reference; do not modify anything.

The document audits the macprovider trust model (catalog signing, bench_gate, hardware verifier SPEC-033, hello gate SPEC-032, routing, tier2/attestation, UX) and proposes a roadmap (R1–R10) toward a trust-minimized prebeta, including a probationary model-upgrade flow (§6) and catalog gate promotion rules (§7).

Audit the DOCUMENT for security defects:

1. THREAT-MODEL SOUNDNESS: does the proposed target model (§5) and upgrade flow (§6) actually resist the adversaries it names? Attack the probation design: fabricated-evidence entry, probation-cap gaming, cherry-picking easy traffic to clear observed floors, sybil/identity-churn around demotions, collusion against `trusted_provider_matrix` quorums (§7), TOCTOU between evidence submission and serving. Any exploitable hole in a proposed mechanism = finding.
2. MISCHARACTERIZED CURRENT SECURITY: any place the document overstates or understates what an existing mechanism proves (verify against code/specs: `internal/autotune/gate.go`, `internal/stats/hardwareverify/verify.go`, `internal/onboarding/hardware_evidence.go`, `internal/ws/server.go` hello/heartbeat paths, `internal/tier2/`, SPEC-032/033 limitation sections). A wrong security claim in a roadmap document propagates into implementation.
3. NEW ATTACK SURFACE created by roadmap items (R1–R10): e.g. R2's persisted per-provider timings (privacy/anonymity-set leakage vs SPEC-017 constraints), R3's gate-on rollout on a single-provider pool (availability as a security property), R9's rate-card signing rotation story.
4. SECRETS/KEY HYGIENE: confirm the document does not leak or imply private key locations or handling guidance inappropriate for a public repo.
5. OMITTED SECURITY WORK that belongs in the roadmap ranking.

Severity scale: CRITICAL / HIGH / MEDIUM / LOW. Only findings about the document (wrong claims, unsound designs, missing items, ranking errors) — not restatements of known gaps the document itself already reports accurately.

OUTPUT: numbered findings with severity, doc section, evidence (file:line where applicable), one-line proposed fix. End with exact summary line: `SUMMARY C=<n> H=<n> M=<n> L=<n>`.
