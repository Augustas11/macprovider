# Shared context — Partial #615 exception enforcement scaffolding

## Goal
Ship tested enforcement scaffolding for the production exception register:
validator/library, deploy + promote gates, operator report (no secrets),
anti-resurrection tombstones/sync-check, runbook update. Partial OK; keep #615
open; no Pearl flag flips; no public release.

## Worktree
`/Users/augstar/macprovider-615-exception-enforce`
Branch: `fix/615-exception-enforcement`
Tip: `f3d71718`
Base: `origin/main`

## Primary files
- `scripts/production_exceptions.py`
- `scripts/check-production-exceptions.py`
- `scripts/test-production-exceptions.sh`
- `scripts/tests/test_production_exceptions.py`
- `ops/exceptions/removed-exception-tombstones.json`
- `ops/runbooks/production-exception-register.md`
- `phase4-coordinator/dist/check-deploy-config.sh` (invokes deploy gate)
- `.github/workflows/promote-acceptance-candidate.yml` (promote gate)
- `Makefile`, `OPS.md`, `scripts/test-acceptance-promotion.sh`

## Default-safe behavior
- Deploy (`gate --mode=deploy`): hard-fail malformed/ownerless/scope-mismatch/
  clock-expired-active/resurrection; warn on status=expired and unbounded active
  unless `MACPROVIDER_EXCEPTION_ENFORCEMENT=1`.
- Promote (`gate --mode=promote`): fail-closed on expired + unbounded active.

## Out of scope
Pearl live mutations, authenticated coordinator `/health` API, clearing #608
catalog-bridge rows, physical exception-free proof, closing #615.

## Gate
0 CRITICAL / 0 HIGH / 0 MEDIUM required before merge.
Write findings to `scratchpad/615-audit/AUDIT_615_<lane>.md`.
