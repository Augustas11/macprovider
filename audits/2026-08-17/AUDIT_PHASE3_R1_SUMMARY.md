# Phase 3 live MDA — Audit R1 summary

**Worktree:** `/Users/augstar/macprovider-attest-phase3-audit`  
**Branch:** `audit/phase3-live-mda` (review of squash `8e0c07c` / #1033)  
**Date:** 2026-08-17  
**Overall:** **NOT APPROVE** (all three lanes REJECT)

Gate: APPROVE only if every lane has 0 CRITICAL / 0 HIGH / 0 MEDIUM.

## Per-lane tallies

| Lane | CRITICAL | HIGH | MEDIUM | LOW | INFO | Verdict |
|------|----------|------|--------|-----|------|---------|
| CODE | 0 | 1 | 3 | 2 | 0 | REJECT |
| SECURITY | 0 | 1 | 2 | 1 | 0 | REJECT |
| ARCHITECT | 0 | 0 | 3 | 2 | 0 | REJECT |

## C/H/M finding titles

### CODE (REJECT)
- **[HIGH]** Documented `api_token: env:...` config is never resolved
- **[MEDIUM]** MDA cache is lost on reconnect, so the 7-day cache path cannot work
- **[MEDIUM]** Live raw-chain verification skips the MDA device-property invariant
- **[MEDIUM]** Claimed concatenated DER parsing returns a single cert instead of a chain
- *[LOW]* `UpgradeFromParsedAttestation` can panic on nil result
- *[LOW]* Refresh interval floor does not match its documented behavior

### SECURITY (REJECT)
- **[HIGH]** Provider can borrow another enrolled Mac’s MDA by self-asserting its serial
- **[MEDIUM]** Live MDA API token is neither env-resolved nor fail-closed when enabled
- **[MEDIUM]** Dependency audit finds reachable Go stdlib vulnerabilities
- *[LOW]* MDM client accepts arbitrary APIURL without scheme/host guardrails

### ARCHITECT (REJECT)
- **[MEDIUM]** MDA cache is not reusable across reconnects
- **[MEDIUM]** Expired MDA proof does not clear the hardware label
- **[MEDIUM]** Live MDA enqueue has no closed-loop response ingest
- *[LOW]* SPEC-008 is stale against the new tier semantics
- *[LOW]* Empty MicroMDM API token is documented as disabled but still wires live MDA

## Cross-lane themes (for fix round)

1. **MicroMDM `api_token` env resolution / fail-closed** — CODE HIGH + SECURITY MEDIUM + ARCHITECT LOW.
2. **MDA cache lost on reconnect** — CODE MEDIUM + ARCHITECT MEDIUM.
3. **Identity binding / serial spoof** — SECURITY HIGH (MDA borrow via self-asserted serial).
4. **Incomplete DeviceInformation round-trip** — ARCHITECT MEDIUM (enqueue without closed-loop ingest).
5. **Verifier gap (device properties on live path)** — CODE MEDIUM.

## Full outputs

### Lane stdout pointers
- `audits/2026-08-17/lane-code.out`
- `audits/2026-08-17/lane-security.out`
- `audits/2026-08-17/lane-architect.out`

### OMC ask artifacts
- CODE: `/Users/augstar/macprovider-attest-phase3-audit/.omc/artifacts/ask/codex-code-audit-phase-3-live-mda-observe-path-1033-worktree-absol-2026-08-17T08-28-27-803Z.md`
- SECURITY: `/Users/augstar/macprovider-attest-phase3-audit/.omc/artifacts/ask/codex-security-audit-phase-3-live-mda-observe-path-1033-worktree-a-2026-08-17T08-29-05-890Z.md`
- ARCHITECT: `/Users/augstar/macprovider-attest-phase3-audit/.omc/artifacts/ask/codex-architect-audit-phase-3-live-mda-observe-path-1033-worktree--2026-08-17T08-28-04-203Z.md`

All three `omc ask codex` processes exited 0. No PR/push/merge performed.
