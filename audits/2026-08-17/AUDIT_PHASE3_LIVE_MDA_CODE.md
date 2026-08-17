# CODE audit — Phase 3 live MDA observe path (#1033)

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

1. Read `CLAUDE.md` / `AGENTS.md` for repo conventions (observe vs enforce, money-path PR rules — this is coordinator attestation, not billing).
2. Read the **entire** `audits/2026-08-17/phase3-fulldiff.patch`.
3. For every path in the file list, read the **current worktree source** around changed symbols (not only hunks) so you catch interaction bugs with unchanged neighbors.
4. Skim `docs/runbooks/hardware-attestation-phases.md` Phase 3 section for claimed acceptance vs code.

Reconstruct scope if needed:

```bash
cd /Users/augstar/macprovider-attest-phase3-audit
git diff e40290c2996545538816a6a5cc8a1706f73c97a3..8e0c07c28613a0eb5f0f34c3d5e3019ddf6ebfba -- $(cat audits/2026-08-17/phase3-files.txt)
```

## Lane focus (CODE)

Correctness and behavioral regressions only. Prioritize:

1. **Freshness dual-mode** — `VerifyMDACertChain` / `VerifyMDACertChainWithSEKey` (or equivalent) paths: SE-bound vs unbound freshness; clock skew; empty/malformed chains; wrong SE key hash binding; refresh interval vs cache hit.
2. **`LiveMDAService`** — `NewLiveMDAService` nil-when-disabled; `RequestAndMaybeUpgrade` timeout/cancel; enqueue-then-upgrade race with concurrent auth; `AttachCachedMDAProof` / `UpgradeFromParsedAttestation` / `tryUpgradeFromCache` / `verifyAndUpgrade` consistency; pool tier upgrade to `hardware` only when chain + SE bind succeed.
3. **WS wiring** — `liveMDAUpgrader` / `WithLiveMDA`; goroutine after SE auth must never block auth; nil service skip; serial/assignedID/providerID wiring correctness.
4. **MDM HTTP client** — DeviceInformation enqueue, lookup-by-serial, response parsing, retries/errors do not panic or corrupt pool state.
5. **Races / concurrency** — pool registry updates vs concurrent WS sessions; cache invalidation on SE key rotation; double-enqueue; stale proof attach after key change.
6. **Tests** — freshness dual-mode coverage, client HTTP tests, pillar_c / SE tests actually assert the claimed invariants (not vacuous).

Out of scope for this lane: design honesty / Phase 4 boundary (architect); auth-token / forge threat model (security) — unless a correctness bug is also a security bug, then still report it here with severity.

## Severity gate

- Report findings as **CRITICAL / HIGH / MEDIUM / LOW / INFO**.
- Final verdict **APPROVE** only if **0 CRITICAL, 0 HIGH, 0 MEDIUM**.
- LOW/INFO may be carried explicitly; list them but they do not block APPROVE.
- If any CRITICAL/HIGH/MEDIUM remains: **REJECT** (or **APPROVE WITH FIXES REQUIRED** — but do not say APPROVE).

## Required output format

For each finding:

```
### [SEVERITY] Short title
- File: <path>:<line> (and related lines)
- Evidence: what the code does (quote or paraphrase precisely)
- Impact: what breaks / who is wronged
- Fix direction: concrete, minimal
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
