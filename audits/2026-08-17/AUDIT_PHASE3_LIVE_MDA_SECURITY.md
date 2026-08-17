# SECURITY audit — Phase 3 live MDA observe path (#1033)

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

1. Read `CLAUDE.md` / `AGENTS.md` (attestation / MDM trust boundaries).
2. Read the **entire** `audits/2026-08-17/phase3-fulldiff.patch`.
3. For every path in the file list, read **surrounding source** in this worktree (client auth headers, URL construction, pool upgrade gates, WS trigger).
4. Cross-check runbook Phase 3 claims: observe-only, no `require_attestation` flip.

```bash
cd /Users/augstar/macprovider-attest-phase3-audit
git diff e40290c2996545538816a6a5cc8a1706f73c97a3..8e0c07c28613a0eb5f0f34c3d5e3019ddf6ebfba -- $(cat audits/2026-08-17/phase3-files.txt)
```

## Lane focus (SECURITY)

Threat model for a live MDA observe path that can upgrade pool attestation tier:

1. **API token handling** — `Tier2MDMConfig.APIToken` / client Authorization: not logged, not echoed in errors, not written to example configs as a real secret, not sent to wrong host; empty token fail-closed when LiveMDA enabled.
2. **Forge / spoof paths** — Can a provider forge DeviceInformation / MDA chain / SE bind and get `hardware` tier without a valid Apple MDA + SE freshness? Cached proof reuse across providers? Attacker-controlled serial attaching another device's MDA?
3. **Observe vs enforce** — Confirm Phase 3 cannot silently flip `require_attestation` or block auth/routing on MDM failure. Failures must stay observe/log. Flag any path that turns observe into soft-enforce.
4. **URL / host safety** — `APIURL` parsing: SSRF to link-local/metadata, scheme downgrade, path traversal on MDM endpoints, open redirects, TLS verify behavior.
5. **Serial / UDID mixups** — Lookup-by-serial vs UDID; wrong device command enqueue; cross-provider upgrade if serial collisions or empty serial shortcuts; assignedID vs providerID confusion in pool writes.
6. **Nonce / SE bind** — `nonce=SHA256(SEPublicKey)` (or equivalent) must bind attestation response to the authenticated SE key; constant-time compares where secrets/hashes matter; reject mismatched SE key on cached attach.
7. **Config surface** — `coordinator.yaml.example` must not ship live secrets or encourage insecure defaults (LiveMDA on by default to untrusted URL, etc.).

Out of scope: pure style/test gaps without security impact (code lane); Phase 3/4 product boundary honesty unless it creates a security lie (then report).

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
- Impact: attacker capability / trust failure
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
