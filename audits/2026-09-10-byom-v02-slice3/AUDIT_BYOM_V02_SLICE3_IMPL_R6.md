# IMPL audit R6 (closure) — BYOM v0.2 slice 3

**Diff reviewed:** full working tree `git diff origin/main` at `29824065` (R5 fixes) + uncommitted `cmd/coordinator/main.go`. **Bar:** 0 C / 0 H / 0 M — **MET**.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 C / 0 H / 0 M / 1 L |
| security-reviewer | 0 C / 0 H / 0 M / 0 L |
| architect | 0 C / 0 H / 0 M / 0 L |

- **LOW (code): `RefreshTier2HashStatuses` logged the raw verifier verdict before the registry applied the session pin**, so a pinned session reporting another member could log `model_hash_verified`/`allow` while its stored status stayed `hash_mismatch` (telemetry only; routing unaffected). Fixed after R6 without re-firing the lanes (one line: the refresh applies `provider.PinnedVerdict` before computing and logging the transition; the registry applies the pin again when it stores the verdict). `go test ./internal/ws ./internal/pool` ok.

Loop summary: SPEC R1–R3 → bar; IMPL R1–R3 → bar; independent cold-context review (2 H / 8 M / 15 L, all resolved); closure rounds R4 → R5 → R6 narrowing each time to the previous fix pass (session-pin lifecycle) → bar. Anchored rounds after the independent review: three, per the stop rule.

## Post-R6 (CI): the BYOM CLI onboarding E2E harness is a consumer outside the diff
CI `phase3-binary (swift test)` → `make test-byom-e2e` (`test/e2e/byom/run-cli-onboarding-e2e.py`) failed: the harness serves `/api/tags` for `qwen3-8b` with NO Ollama store, discovery reaches `catalog_matched` through the NAME leg (library tag, `catalog_match_unverified`), and the offer's artifact-backed rule treated any `catalog_matched` as digest-backed and failed closed (`artifactIdentityChanged`) on the unresolvable blob. The rule is now: artifact-backed = the CLI itself holds a computed digest for the exact current file (`artifact_hash_available`, or `catalog_matched` with a known digest); a name-leg match is advisory and proceeds identity-less, as v0.1 did. Tests: name-leg `catalog_matched` with no GGUF → identity-less offer; digest-backed `catalog_matched` whose blob vanishes → fails closed; `make test-byom-e2e` green. Applied after R6 without re-firing the lanes (disclosed here and in the PR body). Lesson filed: E2E harnesses under `test/e2e` are wire consumers to grep alongside decoders and validators.
