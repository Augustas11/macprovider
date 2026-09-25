# #1690 M8 audit: common brief

**READ-ONLY.** Do NOT run builds, package resolves, or tests on this machine. Review by reading the source, specs and diff only. This is a first-party software-correctness review: do not author exploit payloads, and describe gaps abstractly.

**Focus diff:** `git diff f44e5ef6 HEAD`. It contains M8 plus a SPEC-015 dependency refresh:
- mlx_lm.server joins as runtime class `mlxlm_loopback` through an allowlist entry and an MLX-snapshot identity leg (SPEC-010 R009, SPEC-010 1.12; SPEC-023 v0.17.0; SPEC-042 0.0.34; SPEC-046 0.3.0; SPEC-006 0.9.35; SPEC-047 0.2.1; SPEC-032 v0.3.1).
- The CLI `mlxlm:` selector hashes the served snapshot directory with the native snapshot-manifest algorithm (`MLXLMLoopback.swift`), validates file identity before every report and request, and binds the process via `/v1/models`.
- A separate offer path carries the snapshot pair.
- The coordinator admits the row's own snapshot pair for `mlxlm_loopback` only when the release-bound primary artifact lists that runtime (`ws/model_admission_binding.go`, `ws/model_admission_pool_route.go` format-class rule).
- Ollama gets a lab end-to-end run through the existing `ollama:` path.
- Vocabulary is extended across the feed matrix, allowlist, engine filter, gateway `engine=mlxlm`, hello vocabulary, billing, and the Python generator.
- Lab evidence is appended to `docs/runbooks/runtime-agnostic-m6-lab-e2e-evidence-2026-09-24.md`.

**Context:** the full epic `git diff origin/main...HEAD` (M0-M7) already passed a three-lane audit at 0 C/H/M. Report defects only in the M8 changes, or in any interaction where M8 breaks an earlier invariant.

**Invariants:**
- An external runtime earns only on an allowlisting pool route, for the pool-creator's non-delegated member, with a coordinator-derived runtime class (never a provider-asserted one).
- An mlxlm session serving a non-snapshot (e.g. GGUF) member never binds.
- A snapshot not in the catalog fails closed.
- Global routes are unchanged.
- Older CLIs and coordinators fail closed.
- There is no money-path arithmetic change.

**Output format.** Numbered findings with severity, file:line, the failure scenario, and a fix. End with `VERDICT: <c> CRITICAL / <h> HIGH / <m> MEDIUM / <l> LOW`.
