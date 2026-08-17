# ARCHITECT audit — Phase 3 live MDA observe path (#1033)

## Worktree (absolute)

`/Users/augstar/macprovider-attest-phase3-audit`

Branch: `audit/phase3-live-mda` (reset to `origin/main`).

## Diff under review (full squash — not a slice)

- **SQUASH**: `8e0c07c28613a0eb5f0f34c3d5e3019ddf6ebfba`  
  `feat(attest): Phase 3 live MDA observe path (DeviceInformation + SE freshness) (#1033)`
- **BASE** (parent of squash): `e40290c2996545538816a6a5cc8a1706f73c97a3`
- **Full patch**: `audits/2026-08-17/phase3-fulldiff.patch`
- **File list**: `audits/2026-08-17/phase3-files.txt`

```
docs/runbooks/hardware-attestation-phases.md
phase4-coordinator/cmd/coordinator/main.go
phase4-coordinator/dist/coordinator.yaml.example
phase4-coordinator/internal/config/config.go
phase4-coordinator/internal/mdm/client.go
phase4-coordinator/internal/mdm/client_test.go
phase4-coordinator/internal/mdm/live_mda.go
phase4-coordinator/internal/pool/provider.go
phase4-coordinator/internal/tier2/pillar_c.go
phase4-coordinator/internal/tier2/pillar_c_se.go
phase4-coordinator/internal/tier2/pillar_c_se_test.go
phase4-coordinator/internal/tier2/pillar_c_test.go
phase4-coordinator/internal/ws/server.go
```

## Mandatory reading order

1. Read `CLAUDE.md` / `AGENTS.md`.
2. Read the **entire** `audits/2026-08-17/phase3-fulldiff.patch`.
3. Read surrounding source for listed files (wiring in `main.go`, pool cache fields, WS option pattern, tier2 SE helpers).
4. Read Phase 3 + Phase 4 sections of `docs/runbooks/hardware-attestation-phases.md` and relevant SPEC-008 claims for honesty against the implementation.

```bash
cd /Users/augstar/macprovider-attest-phase3-audit
git diff e40290c2996545538816a6a5cc8a1706f73c97a3..8e0c07c28613a0eb5f0f34c3d5e3019ddf6ebfba -- $(cat audits/2026-08-17/phase3-files.txt)
```

## Lane focus (ARCHITECT)

System boundaries, lifecycle honesty, and architectural completeness:

1. **Phase 3 / Phase 4 boundary** — Phase 3 must be observe-path only (DeviceInformation + SE freshness bind, optional tier label upgrade for observation). Phase 4 owns `require_attestation` / C4b enforce flip. Flag any bleed: enforce semantics, routing gates, or docs that claim Phase 3 completes hardware trust for buyers.
2. **Cache invalidation** — When SE key rotates, serial changes, or MDA refresh interval expires: is pool MDA proof cleared / re-verified? Can a stale `hardware` label persist across identity change? Is dual-mode freshness the single source of truth for “still valid”?
3. **Incomplete response ingest** — Enqueue-only `RequestAndMaybeUpgrade` vs later attach/upgrade: what happens if DeviceInformation never returns, returns partial chain, or webhook/poll path is absent in this squash? Is the architecture honest that round-trip completion may be deferred, and are incomplete states non-corrupting?
4. **SPEC-008 honesty** — Do code + runbook claims match SPEC-008 observe/enforce / attestation status semantics? No overclaim that live MDA is fully closed-loop if ingest is best-effort. Flag doc checkboxes that mark done what the diff does not deliver.
5. **Layering** — `mdm.LiveMDAService` vs `tier2` verify helpers vs `pool.Registry` vs `ws.Server`: clean dependency direction? Config knobs (`LiveMDAEnabled`, `APIURL`, `MDARefreshIntervalHours`) coherent defaults for observe rollout.
6. **Operability** — Failure modes observable (logs/metrics) without coupling auth success to MDM availability; clear disable path when APIURL empty / flag false.

Out of scope: line-level race nitpicks without architectural import (code); pure secret-handling bugs (security) unless they imply a wrong trust architecture.

## Severity gate

- Report findings as **CRITICAL / HIGH / MEDIUM / LOW / INFO**.
- Final verdict **APPROVE** only if **0 CRITICAL, 0 HIGH, 0 MEDIUM**.
- LOW/INFO may be carried explicitly.
- Any C/H/M → **REJECT** (do not APPROVE).

## Required output format

For each finding:

```
### [SEVERITY] Short title
- File: <path>:<line>
- Evidence: …
- Impact: boundary / honesty / lifecycle failure
- Fix direction: …
```

End with exactly:

```
## Tally
CRITICAL=N
HIGH=N
MEDIUM=N
LOW=N
INFO=N (optional)

## Verdict
APPROVE | REJECT
```

If zero C/H/M: state that explicitly before the tally.
