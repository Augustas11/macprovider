# IMPL audit prompt — SPEC-016 FULL implementation, **SECURITY REVIEW lane, r1**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_FULL_PROMPT_r1.md`.

Fire via:

```
omc ask codex --agent-prompt security-reviewer --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the security-reviewer lane (2 of 3) auditing the FULL
SPEC-016 implementation — round 1.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_FULL_PROMPT_r1.md`. HEAD: `47e4f24`.
Holistic security audit of Step 1+2+3+4 together.

## Threat model (FULL implementation)

1. **Provider with stolen provider_token.** Can they:
   - Register a payout address for a victim provider via Step 1
     §3.3? §3.2 EIP-712 binds the signer to the address; provider
     token authn binds the request to provider_id. Verify the
     interaction cannot let token-A bind addr-X to provider-B.
   - Read another provider's payouts via Step 4 §7.3
     `/providers/{id}/payouts`? Token's provider_id vs path
     provider_id mismatch must return 403, not 401 + not 200.
2. **Operator-key-compromised attacker with config write.** Can
   they:
   - Widen `payout.tuning.confirmation_blocks` to 1 via SIGHUP?
     §6.5 bound matrix must reject.
   - Inject fake funding via `/admin/payout/record-funding`? Step
     3 + Step 4 chain-balance worker must detect.
   - Bypass the run-now rate limit via Step 4
     `RunNowMinInterval`? RunNowController must enforce.
   - Replay the SIGHUP listener with malicious YAML mutating
     payout.security.*? `LoadPayoutTuningOnly` must ignore
     security namespace.
   - Submit operations while runner is halted? IsHalted gate +
     halt-state persistence (process-restart required to clear)
     must hold.
3. **Lying RPC primary.** Can they:
   - Return inflated balanceOf to silence
     payout_chain_balance_drift_negative? Step 4 worker compares
     primary + secondary; disagreement → skip + emit
     payout_chain_balance_rpc_disagreement (Step 4 r3 rename).
   - Fabricate receipts to make a payout appear confirmed when
     it isn't? Step 2 ReceiptsAgree + verifyChainSideTransfer on
     BOTH receipts (Step 2 r1 sec:2.2 closure).
   - Verify against a stale SPKI pin after operator SIGHUPs a
     new one? Step 4 r3 closure: live `pinFn()` + Step 4 r3
     [sec:r3-1] closure: CloseIdleConnections on SPKI change.
4. **Race attacker.**
   - TOCTOU on pause vs §3.3 write (Step 1 [arch:1.3]).
   - TOCTOU on Step 4 RunNowController IsHalted check (r2-3
     race body fix).
   - Race on bootstrap-sentinel during Step 3 reopen
     (sec:1 CRITICAL closure).
5. **Wallet key exfiltration.** Step 2 + Step 4 production path:
   - KEK loaded from systemd CREDENTIALS_DIRECTORY or env
   - LocalFileSigner zeroizes KEK + raw on all error paths
   - DevMode requires explicit opt-in
   - No bearer / token / private-key leakage in any §7.1 emit

## High-leverage probes (FULL)

### A. End-to-end money path security

Trace a happy-path payout: any path bypasses ANY of:
- EIP-712 signer recovery for §3.3 register?
- Pre-auth pause check?
- Anti-replay nonce check?
- Two-RPC discipline on confirmation?
- ConfirmationBlocks depth?
- C3 invariant (amount == provider_credits)?
- Self-fence before broadcast?
- Self-fence after COMMIT, before sendTx?
- Daily cap enforcement (per_day_cap)?
- Per-payout cap enforcement?
- In-broadcast insufficient-funds check?

### B. Cross-step authority gaps

1. The Step 4 halt primitive is the authority for "stop processing".
   Verify EVERY entry point to the payout cycle has the gate:
   - cadence loop's RunOnce (top check)
   - admin run-now (RunNowController)
   - abandon endpoint (Step 2) — should this refuse when halted?
   - pause/resume (Step 3)
   - record-funding (Step 3)
   - record-orphan (Step 3)
   - register-payout-address (Step 1) — should provider
     registration be blocked while halted? §3.3 says no, but
     verify there's no SPEC drift.
2. The TuningProvider is the authority for live config. Verify
   no admin endpoint or background reads a stale value
   (everything goes through Snapshot()).
3. The lease (Step 2) is the authority for "I am the sole runner".
   Verify EVERY chain-write critical section (broadcast,
   StampBroadcastAt) is preceded by SelfFence.

### C. Provider-token / operator-key / bearer surface

Walk every authn-required endpoint:
| Endpoint | Auth | Authz |
|----------|------|-------|
| POST /providers/{id}/payout-address | provider-token | path id == token id |
| GET /providers/{id}/payouts | provider-token | path id == token id |
| POST /admin/payout/run-now | operator-key | constant-time |
| POST /admin/payout/abandon-attempt | operator-key | constant-time |
| POST /admin/payout/pause-registration | operator-key | constant-time |
| POST /admin/payout/resume-registration | operator-key | constant-time |
| POST /admin/payout/record-funding | operator-key | constant-time |
| POST /admin/payout/record-orphan | operator-key | constant-time |

Verify the operator-key middleware uses constant-time compare
(Step 2 r2 [sec:r2-2.2] closure). Verify provider-token
middleware uses constant-time compare.

### D. SQL injection across the corpus

The 4 steps add MANY new SQL queries. Walk every parameterized
query — verify NO string concatenation, NO format-injection,
ALL `?` bindings. Particular focus:
- §7.3 payouts query (provider_id bind)
- §7.4 reconcile queries (hot_wallet bind, no injection)
- Step 3 admin endpoints (record-funding amounts, txhash)
- Step 4 chain-balance worker `eth_call` calldata construction
  — verify NO injection via hot_wallet address

### E. Secret-leak sweep

Walk every log emission across all 4 Steps:
- No bearer
- No KEK
- No wallet private key
- No raw_signed_tx in logs (only tx_hash)
- SPKI pin redacted (Step 4 r1 [sec:r1-2] closure)
- holder_token redacted to 8-char prefix (Step 3 r1 [sec:3] closure)
- payout_config_reload_rejected actor field is non-bearer

### F. govulncheck + race + secrets scan

- `govulncheck ./...` from `phase4-coordinator/`
- `go test -race -count=1 ./...`
- secrets pattern scan across the implementation: no production
  hot wallet addresses, no production keys, no production
  bearer tokens, no production RPC URLs (env: indirection only).

### G. OWASP Top 10 (FULL)

Re-evaluate each control across the FULL surface:
- A01 Broken Access Control
- A02 Cryptographic Failures
- A03 Injection
- A04 Insecure Design
- A05 Security Misconfiguration (deploy gate)
- A06 Vulnerable Components (govulncheck)
- A07 Auth Failures
- A08 Software/Data Integrity Failures
- A09 Logging Failures
- A10 SSRF

## Output

Write findings to
`specs/SPEC-016-IMPL-FULL-security-r1-audit.md`. Standard
structure. If 0/0/0/0 — declare CONVERGENT.

## Discipline

- Cross-step security focus. The 4 Step audits closed their
  surface; look for what only shows in the holistic view.
- Wall-clock target: 35-45 min.

=== END PROMPT ===
```
