# #1690 M3 SPEC audit round 3: resolution

Base `c525ae95`. SPEC versions are unchanged, because M3 is still unmerged. The fixes below do not touch the SECURITY areas that passed in round 2.

## ARCH lane (0C/0H/1M/1L)
- M1 pool usage reported as `coordinator_observed`: fixed with a new SPEC-022 R-12.6a that traces the usage source end to end.
  - **Set:** once per attempt at `billing_recorder.go:747-757`.
  - **Persisted:** in `settlement_attempt_outputs.usage_source`. The CHECK constraint at `store.go:365` is widened by a migration that does not rewrite existing rows.
  - **Read:** by ingestion and the verifier (R-12.4).
  - **Reported:** request-finality `token_source` (`settlement_finality.go:283-304`) is derived from the persisted per-attempt sources and never hardcoded. `pool_operator_attested` wins if any verified attempt has it (the weaker provenance governs a mixed request). The same rule applies to the overlap-blocked result, and aggregates group by the persisted source.
  - AC-022-65 now asserts the pool-only, mixed, and all-native finality results.
- L2 `allowed_runtime_sources` absent from the recorded member: fixed by deriving it instead of recording it. SPEC-047-R003(iv) step 1 checks admissibility on the session's release-bound artifact member (`p.ArtifactIdentity.Member.AllowsRuntimeSource`, `artifactidentity/index.go:52`) once its identity equals the recorded member. This is the check the global feed path already makes. The persisted event schema (`ModelAdmissionCatalogMember`, `ws/model_admission.go:178`) is unchanged.

## SPEC lane (0C/0H/0M/1L)
- L1 runbook says the CLI has no GGUF serving runtime: fixed. `catalog-artifact-feed-release.md` marks that statement as historical R007-slice context and points to SPEC-046-R009 (`llamacpp:`/`ollama:`) and the pool-only serving rules (SPEC-047-R003(iv), SPEC-022-R012).
