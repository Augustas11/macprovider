# Phase 3 live MDA — Audit R1 findings (CRITICAL / HIGH / MEDIUM)

**Worktree:** `/Users/augstar/macprovider-attest-phase3-audit`  
**Branch:** `audit/phase3-live-mda` (squash `8e0c07c` / #1033)  
**Date:** 2026-08-17  
**Sources:** `.omc/artifacts/ask/*phase-3*` (code / security / architect)  
**Companion:** `audits/2026-08-17/AUDIT_PHASE3_R1_SUMMARY.md`

Gate: fix until **0 CRITICAL, 0 HIGH, 0 MEDIUM**. LOW/INFO omitted from this file (see summary).

Overall: **NOT APPROVE** — CODE REJECT (0/1/3), SECURITY REJECT (0/1/2), ARCHITECT REJECT (0/0/3).

---

## CODE

### CODE-H1 — [HIGH] Documented `api_token: env:...` config is never resolved

| Field | Detail |
|-------|--------|
| **Lane** | code |
| **Severity** | HIGH |
| **Title** | Documented `api_token: env:...` config is never resolved |
| **File:line** | `phase4-coordinator/internal/config/config.go:895`, `config.go:1679` (also `internal/mdm/client.go:234`) |
| **Evidence** | `Tier2MDMConfig.APIToken` documents `env:MICROMDM_API_TOKEN`, but `resolveEnv()` resolves other secrets and never touches `Tier2.MDM.APIToken`. The MDM client then sends the literal `env:...` string as MicroMDM Basic Auth password. |
| **Recommendation** | Call `resolveEnvValue("tier2.mdm.api_token", c.Tier2.MDM.APIToken)` during config load. Add tests for successful resolution and unset-env fail-closed when `live_mda_enabled` is true. |

### CODE-M1 — [MEDIUM] MDA cache is lost on reconnect, so the 7-day cache path cannot work

| Field | Detail |
|-------|--------|
| **Lane** | code |
| **Severity** | MEDIUM |
| **Title** | MDA cache is lost on reconnect, so the 7-day cache path cannot work |
| **File:line** | `phase4-coordinator/internal/pool/provider.go:872`, `internal/ws/server.go:2654` |
| **Evidence** | `RegisterAtDetailed` replaces `r.providers[p.ProviderID] = p` without copying `MDACertChain`, `MDAVerifiedAt`, or `MDABoundSEKeyHash` from the existing provider. The v2 auth path builds a fresh `pool.Provider` and does not populate those fields, so reconnect misses the prior proof. |
| **Recommendation** | Copy the existing MDA proof into the replacement provider when the SE key hash still matches, or store MDA proof in a provider-ID keyed cache independent of live session replacement. Add a reconnect regression test asserting no enqueue on a fresh cached proof. |

### CODE-M2 — [MEDIUM] Live raw-chain verification skips the MDA device-property invariant

| Field | Detail |
|-------|--------|
| **Lane** | code |
| **Severity** | MEDIUM |
| **Title** | Live raw-chain verification skips the MDA device-property invariant |
| **File:line** | `phase4-coordinator/internal/tier2/pillar_c.go:280`, `pillar_c.go:321` (caller `internal/mdm/live_mda.go:217`) |
| **Evidence** | The production token path calls `verifyMDADeviceProperties(certs[0])` before attesting, but `VerifyMDACertChainWithSEKey` verifies roots, leaf key, and freshness only. Live MDA uses that helper before setting `AttestationTierHardware`. |
| **Recommendation** | Call `verifyMDADeviceProperties` inside `VerifyMDACertChainWithSEKey`, and add missing/blank-property tests for the raw-chain helper. |

### CODE-M3 — [MEDIUM] Claimed concatenated DER parsing returns a single cert instead of a chain

| Field | Detail |
|-------|--------|
| **Lane** | code |
| **Severity** | MEDIUM |
| **Title** | Claimed concatenated DER parsing returns a single cert instead of a chain |
| **File:line** | `phase4-coordinator/internal/mdm/client.go:151` (string path ~`client.go:202`) |
| **Evidence** | Comments say `ParseDeviceAttestationFromPlist` handles “a concatenated DER blob”, but the string/base64 case only decodes and returns `[][]byte{der}` without splitting multiple DER certificates. |
| **Recommendation** | Use `x509.ParseCertificates` or an explicit DER loop to split the decoded blob; add a concatenated-chain parser test. |

---

## SECURITY

### SEC-H1 — [HIGH] Provider can borrow another enrolled Mac’s MDA by self-asserting its serial

| Field | Detail |
|-------|--------|
| **Lane** | security |
| **Severity** | HIGH |
| **Title** | Provider can borrow another enrolled Mac’s MDA by self-asserting its serial |
| **File:line** | `phase4-coordinator/internal/tier2/pillar_c_se.go:115`, `internal/mdm/live_mda.go:105`, `internal/tier2/pillar_c.go:445`, `internal/mdm/live_mda.go:217` |
| **Evidence** | `serialNumber` comes from the provider’s SE-signed blob (self-signed by that provider’s SE key). `RequestAndMaybeUpgrade` trusts it for `FindDeviceBySerial` and enqueues MDA for that MicroMDM device. Later verification checks Apple chain + freshness bound to the attacker’s SE key hash as nonce, but does not bind MDA serial/UDID to the requested device; `verifyMDADeviceProperties` only requires any nonblank recognized property. |
| **Recommendation** | Bind MDA response to the exact MicroMDM device: store pending request metadata (providerID, assignedID, expected serial/UDID, SE-key hash) keyed by command UUID/UDID; parse serial/UDID from MDA cert extensions and require equality before `SetMDAProof`. |

### SEC-M1 — [MEDIUM] Live MDA API token is neither env-resolved nor fail-closed when enabled

| Field | Detail |
|-------|--------|
| **Lane** | security |
| **Severity** | MEDIUM |
| **Title** | Live MDA API token is neither env-resolved nor fail-closed when enabled |
| **File:line** | `phase4-coordinator/internal/config/config.go:895`, `config.go:1679`, `internal/mdm/live_mda.go:42`, `internal/mdm/client.go:234` |
| **Evidence** | Docs/config say `api_token: "env:MICROMDM_API_TOKEN"` and empty token disables the client, but `resolveEnv()` never resolves `tier2.mdm.api_token`, and `NewLiveMDAService` only checks `LiveMDAEnabled` + `APIURL`. Empty or literal `env:...` still reaches Basic Auth. |
| **Recommendation** | Resolve `tier2.mdm.api_token` via the env resolver; when `live_mda_enabled=true`, require a nonempty resolved token (fail closed at config load). |

### SEC-M2 — [MEDIUM] Dependency audit finds reachable Go stdlib vulnerabilities

| Field | Detail |
|-------|--------|
| **Lane** | security |
| **Severity** | MEDIUM |
| **Title** | Dependency audit finds reachable Go stdlib vulnerabilities |
| **File:line** | `phase4-coordinator/go.mod:3` (reachability via `internal/mdm/client.go:128`, `internal/tier2/pillar_c.go:643`) |
| **Evidence** | `govulncheck ./internal/mdm ./internal/tier2 ./internal/ws` reports reachable vulns on Go 1.26.5: `GO-2026-6218`, `GO-2026-6090`, `GO-2026-5972`, `GO-2026-5026` — all fixed in Go 1.26.6. Affects MDM HTTP/TLS/URL and ASN.1 freshness parsing. |
| **Recommendation** | Upgrade module/toolchain to Go **1.26.6**, rebuild, re-run `govulncheck`. |

---

## ARCHITECT

### ARCH-M1 — [MEDIUM] MDA cache is not reusable across reconnects

| Field | Detail |
|-------|--------|
| **Lane** | architect |
| **Severity** | MEDIUM |
| **Title** | MDA cache is not reusable across reconnects |
| **File:line** | `phase4-coordinator/internal/pool/provider.go:872` (fields ~`:275`; replace ~`:875`/`:945`; attach `internal/mdm/live_mda.go:142`; WS iface `internal/ws/server.go:221`; call site ~`server.go:2303`) |
| **Evidence** | MDA proof lives only on the in-memory `Provider`. Registration replaces the map entry without copying MDA fields. `AttachCachedMDAProof` exists and is on the WS interface, but the registration path only calls `RequestAndMaybeUpgrade` after SE auth — the attach path is never invoked. |
| **Recommendation** | Persist MDA proof outside the live session object or migrate proof from `existing` → replacement during registration when SE key still matches; then call the cached attach path after the new SE key is known. Add reconnect reuse and SE-key-rotation tests. |

### ARCH-M2 — [MEDIUM] Expired MDA proof does not clear the hardware label

| Field | Detail |
|-------|--------|
| **Lane** | architect |
| **Severity** | MEDIUM |
| **Title** | Expired MDA proof does not clear the hardware label |
| **File:line** | `phase4-coordinator/internal/mdm/live_mda.go:187` (also `:217`, `:179`; clear/downgrade `internal/pool/provider.go:1739`; buyer/stats `internal/buyer/server.go:980`, `internal/stats/poolsnapshot/…:77`) |
| **Evidence** | Cache expiry logs and returns false without clearing proof or downgrading tier. Verification failures also return false without clearing. Only SE key mismatch calls `ClearMDAProof`, which is the only helper that downgrades `hardware` → `self_signed`. Buyer/stats now treat only `AttestationTierHardware` as hardware-attested. |
| **Recommendation** | On expiry or failed re-verification, clear the cached proof and downgrade before enqueueing refresh (or gate public hardware counts through a freshness check). Accept temporary undercount while refresh is pending. |

### ARCH-M3 — [MEDIUM] Live MDA enqueue has no closed-loop response ingest

| Field | Detail |
|-------|--------|
| **Lane** | architect |
| **Severity** | MEDIUM |
| **Title** | Live MDA enqueue has no closed-loop response ingest |
| **File:line** | `phase4-coordinator/internal/mdm/live_mda.go:65` (enqueue `:121`; upgrade `:151`; client helpers `client.go:64`/`:99`/`:148`; runbook `docs/runbooks/hardware-attestation-phases.md:264`) |
| **Evidence** | `RequestAndMaybeUpgrade` only enqueues DeviceInformation and comments that polling/webhook completes later. `UpgradeFromParsedAttestation` is callable but no polling or webhook ingestion is wired. Runbook still marks parse→upgrade as manual E2E work. |
| **Recommendation** | Add a response-ingestion boundary: pending command state, polling or webhook receiver, parser → `UpgradeFromParsedAttestation`, backoff/rate-limit, and explicit handling for no response / partial chains. |

---

## Cross-lane themes (dedupe map for fix round)

| Theme | Findings |
|-------|----------|
| MicroMDM `api_token` env resolve + fail-closed | CODE-H1, SEC-M1 (+ architect LOW empty-token wiring) |
| MDA cache lost on reconnect | CODE-M1, ARCH-M1 |
| Identity binding / serial spoof (MDA borrow) | SEC-H1 |
| Incomplete DeviceInformation round-trip | ARCH-M3 |
| Verifier gap (device properties on live path) | CODE-M2 |
| Expiry without hardware downgrade | ARCH-M2 |
| Concatenated DER parse | CODE-M3 |
| Go toolchain vulns | SEC-M2 |

---

## Source files that need edits

Primary (production / config):

- `phase4-coordinator/internal/config/config.go` — resolve `tier2.mdm.api_token`; fail-closed when live MDA enabled; refresh-interval docs/behavior if touched with HIGH/MEDIUM work
- `phase4-coordinator/internal/mdm/live_mda.go` — pending-request binding; expiry→clear/downgrade; closed-loop ingest wiring; nil-guard if included
- `phase4-coordinator/internal/mdm/client.go` — concatenated DER split; optional APIURL validation if bundled
- `phase4-coordinator/internal/pool/provider.go` — MDA proof migrate/copy on reconnect; clear/downgrade helpers
- `phase4-coordinator/internal/ws/server.go` — invoke attach-cached path / registration handoff
- `phase4-coordinator/internal/tier2/pillar_c.go` — `verifyMDADeviceProperties` inside `VerifyMDACertChainWithSEKey`; MDA identity extract/compare
- `phase4-coordinator/internal/tier2/pillar_c_se.go` — serial trust / SE blob binding for request path
- `phase4-coordinator/go.mod` — Go **1.26.6** toolchain bump

Likely tests / fixtures:

- `phase4-coordinator/internal/config/config_env_test.go` (or adjacent config tests)
- `phase4-coordinator/internal/mdm/client_test.go`
- `phase4-coordinator/internal/mdm/` live-MDA / reconnect / ingest tests (new as needed)
- `phase4-coordinator/internal/pool/` reconnect MDA migration tests
- `phase4-coordinator/internal/tier2/pillar_c_test.go`, `pillar_c_se_test.go`
- `phase4-coordinator/internal/ws/` registration/reconnect coverage if needed

Possibly docs/spec (honesty; not required to clear C/H/M alone but called out by architect LOW):

- `docs/runbooks/hardware-attestation-phases.md`
- `specs/SPEC-008-tier2.md`
- `phase4-coordinator/dist/coordinator.yaml.example`

Wiring entrypoint (if ingest/service construction changes):

- `phase4-coordinator/cmd/coordinator/main.go`

Buyer/stats only if expiry gating is done at disclosure rather than pool clear:

- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/stats/poolsnapshot/` (hardware count path)

---

## Artifact pointers

- CODE: `.omc/artifacts/ask/codex-code-audit-phase-3-live-mda-observe-path-1033-worktree-absol-2026-08-17T08-28-27-803Z.md`
- SECURITY: `.omc/artifacts/ask/codex-security-audit-phase-3-live-mda-observe-path-1033-worktree-a-2026-08-17T08-29-05-890Z.md`
- ARCHITECT: `.omc/artifacts/ask/codex-architect-audit-phase-3-live-mda-observe-path-1033-worktree--2026-08-17T08-28-04-203Z.md`

No production code modified. No PR/push.
