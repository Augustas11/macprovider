# AUDIT — PR #164 merge-resolution slice (impl/spec-016 ← main, 2026-07-30)

## Scope

Audit ONLY the merge-resolution diff of the commit titled
"Merge origin/main into impl/spec-016 (revive SPEC-016 payout pipeline)"
on branch `impl/spec-016`. The branch's own payout implementation was
already audited to 0/0/0/0 across 20 codex round-passes (see
`specs/SPEC-016-IMPL-FULL-r3-convergence.md`); `origin/main`'s side is
already-merged, reviewed code. What is NEW and unaudited is the human
resolution of the 7 conflicted files plus the SPEC-016 lineage
reconciliation:

- `phase4-coordinator/cmd/coordinator/main.go` — import union; payout
  wiring block now coexists with the trust-promotion mux mount; the
  interleaved `startPayoutSIGHUPListener` / `observeRollupLag` conflict
  was resolved by reconstructing BOTH functions in full.
- `phase4-coordinator/internal/config/config.go` — import union
  (`math`); `LoadPayoutTuningOnly` + wrapper coexist with main's
  `unmarshalYAMLFile` / `finalizeLoadedConfig` refactor of `Load`.
- `phase4-coordinator/internal/config/config_env_test.go` — union of
  both sides' tests; `TestLoadResolvesPayoutSecurityEnvFields` updated
  for main's stricter validation (gateway_service_token now required,
  32-byte operator-key strength check).
- `phase4-coordinator/go.mod` / `go.sum` — union of direct deps;
  `golang.org/x/crypto` promoted to direct at main's v0.51.0; `go mod tidy`.
- `phase4-coordinator/dist/check-deploy-config.sh` — payout deploy-gate
  block retained ahead of main's WARN-count summary footer.
- `specs/SPEC-016-payout-pipeline.md` — v0.1.23 lineage reconciliation
  per issue #586: main's v0.1.20 Wave-2 provider-token custody content
  AND branch v0.1.21/v0.1.22 IMPL-follow-up deltas both retained;
  changelog reordered; Status updated to IMPL-merged-default-off.

## Questions each lane must answer

1. Does the resolved `main.go` wire payout correctly against main's
   CURRENT startup/mux topology (nothing dropped from either side; no
   double-mount; `/providers/` fallback still correct when payout
   disabled; shutdown ordering intact)?
2. Does `LoadPayoutTuningOnly` remain correct given main's `Load`
   refactor (no security-namespace parsing on SIGHUP path; defaults
   still sourced correctly)?
3. go.mod/go.sum: any dependency downgrade or silent regression per
   the pr-rebase-silent-dependency-regression trap?
4. Deploy gate: payout block still executes before the summary/exit;
   `warns` counter unaffected by payout block insertion?
5. SPEC-016 v0.1.23: grep-verify BOTH lineages' normative deltas are
   present (custody gate; three §7.1 events; staleOutboxScanCeiling;
   TrackingRPCClient/ChronicOutageTracker); changelog coherent.
6. Money-path regression risk introduced BY the resolution itself
   (not by either parent).

## Bar

0 CRITICAL / 0 HIGH / 0 MEDIUM to pass. LOW/INFO may be carried
explicitly in the PR body.

## How to diff

```
git diff <merge-commit>^1 <merge-commit> -- \
  phase4-coordinator/cmd/coordinator/main.go \
  phase4-coordinator/internal/config/config.go \
  phase4-coordinator/internal/config/config_env_test.go \
  phase4-coordinator/go.mod phase4-coordinator/go.sum \
  phase4-coordinator/dist/check-deploy-config.sh \
  specs/SPEC-016-payout-pipeline.md
```

(^1 = the pre-merge branch tip; the interesting delta is what the
resolution changed relative to EACH parent on the conflicted files.)
