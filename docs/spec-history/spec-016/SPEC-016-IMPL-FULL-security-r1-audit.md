# Security Review Report

Verdict: NOT CONVERGENT - 0 CRITICAL / 1 HIGH / 0 MAJOR / 0 MEDIUM / 1 LOW. The HIGH finding blocks the SPEC-016 full security lane.

Scope: Full SPEC-016 payout implementation on checked-out branch `impl/spec-016`, current HEAD `7b49cd7` (prompt expected `47e4f24`; audit evidence is for the working tree actually checked out). Reviewed Step 1+2+3+4 payout surfaces under `phase4-coordinator/internal/payout`, `phase4-coordinator/internal/config/config.go`, `phase4-coordinator/cmd/coordinator/main.go`, and payout deploy/runbook files under `phase4-coordinator/dist`.

Risk Level: HIGH

## Summary

| Severity | Count |
| --- | ---: |
| CRITICAL | 0 |
| HIGH | 1 |
| MAJOR | 0 |
| MEDIUM | 0 |
| LOW | 1 |

- Critical Issues: 0
- High Issues: 1
- Medium Issues: 0
- Low Issues: 1

## High Issues

### [full-sec:r1-1] Payout RPC URLs are not constrained to secure, independent origins

Severity: HIGH

Category: OWASP A05 Security Misconfiguration, A10 SSRF, A08 Software/Data Integrity Failures

Location:
- `phase4-coordinator/internal/config/config.go:1051`
- `phase4-coordinator/internal/config/config.go:1055`
- `phase4-coordinator/internal/config/config.go:1058`
- `phase4-coordinator/internal/payout/rpc.go:140`
- `phase4-coordinator/internal/payout/rpc.go:256`
- `phase4-coordinator/dist/check-deploy-config.sh:351`

Exploitability: Local/config-write attacker or deployment mistake; not unauthenticated remote. This matches the full-audit threat model branch for an operator-key/config-write attacker and also weakens deployments that rely on the deploy gate.

Blast Radius: Payout chain integrity. An attacker who can make the coordinator use attacker-controlled RPC origins can defeat the intended two-RPC discipline by returning agreeing chain IDs, nonce views, receipts, and `balanceOf` results. That can make fake broadcasts/confirmations appear valid, silence chain-balance drift, or route coordinator egress to internal services. Plain `http://` URLs also bypass the TLS SPKI verifier entirely because pin verification only runs on TLS handshakes.

Issue: `Validate()` requires payout RPC URLs to be non-empty and string-distinct, but it does not parse them, require HTTPS, reject userinfo, reject loopback/private/link-local hosts, or require distinct trusted origins/providers. The deploy gate likewise checks only presence/placeholders for `payout.security.rpc_url_primary` and `rpc_url_secondary`. Production wiring then passes those raw strings to `NewHTTPRPCClient`, and every JSON-RPC call uses `http.NewRequestWithContext` against that URL.

Remediation:

```go
// BAD
if c.Payout.Security.RPCURLPrimary == "" || c.Payout.Security.RPCURLSecondary == "" {
    return fmt.Errorf("payout.security.rpc_url_primary and rpc_url_secondary must both be set")
}
if c.Payout.Security.RPCURLPrimary == c.Payout.Security.RPCURLSecondary {
    return fmt.Errorf("payout.security.rpc_url_primary and rpc_url_secondary must differ")
}

// GOOD
func validatePayoutRPCURL(name, raw string) (*url.URL, error) {
    u, err := url.Parse(strings.TrimSpace(raw))
    if err != nil || u.Hostname() == "" {
        return nil, fmt.Errorf("%s must be a valid URL", name)
    }
    if u.Scheme != "https" {
        return nil, fmt.Errorf("%s must use https", name)
    }
    if u.User != nil {
        return nil, fmt.Errorf("%s must not contain userinfo", name)
    }
    if ip, err := netip.ParseAddr(u.Hostname()); err == nil {
        if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() {
            return nil, fmt.Errorf("%s must not target loopback/private/link-local IPs", name)
        }
    }
    return u, nil
}

primary, err := validatePayoutRPCURL("payout.security.rpc_url_primary", c.Payout.Security.RPCURLPrimary)
if err != nil {
    return err
}
secondary, err := validatePayoutRPCURL("payout.security.rpc_url_secondary", c.Payout.Security.RPCURLSecondary)
if err != nil {
    return err
}
if strings.EqualFold(primary.Hostname(), secondary.Hostname()) {
    return fmt.Errorf("payout RPC primary and secondary must use independent hostnames/providers")
}
```

Also update `dist/check-deploy-config.sh` to reject non-HTTPS RPC URLs and obvious loopback/private/link-local targets after resolving `env:` values. If production allows only named vendors, prefer an explicit hostname allowlist and document the operational override path for test/dev only.

## Low Issues

### [full-sec:r1-2] Decrypted wallet plaintext is not zeroized on malformed-length error path

Severity: LOW

Category: OWASP A02 Cryptographic Failures / Secrets Management

Location: `phase4-coordinator/internal/payout/signer.go:140`

Exploitability: Local malformed encrypted-wallet file with valid GCM authentication; no remote exploit path found.

Blast Radius: Limited process-memory exposure of decrypted wallet plaintext when the decrypted payload is not exactly 32 bytes. The normal success path wipes `pt`, production KEK is wiped by caller defer, and wrong-KEK decrypt failures produce no plaintext.

Issue: `LoadLocalFileSigner` checks `len(pt) != 32` and returns before wiping `pt`. The prompt requires signer plaintext zeroization on all error paths. The successful path wipes after importing the key, but the malformed-length path leaves decrypted bytes for GC.

Remediation:

```go
// BAD
pt, err := gcm.Open(nil, nonce, ct, nil)
if err != nil {
    return nil, errors.New("LoadLocalFileSigner: wallet decrypt failed")
}
if len(pt) != 32 {
    return nil, fmt.Errorf("LoadLocalFileSigner: decrypted key length = %d, want 32", len(pt))
}
priv := secp256k1.PrivKeyFromBytes(pt)
for i := range pt {
    pt[i] = 0
}

// GOOD
pt, err := gcm.Open(nil, nonce, ct, nil)
if err != nil {
    return nil, errors.New("LoadLocalFileSigner: wallet decrypt failed")
}
defer func() {
    for i := range pt {
        pt[i] = 0
    }
}()
if len(pt) != 32 {
    return nil, fmt.Errorf("LoadLocalFileSigner: decrypted key length = %d, want 32", len(pt))
}
priv := secp256k1.PrivKeyFromBytes(pt)
```

## OWASP Top 10 Coverage

| Category | Result |
| --- | --- |
| A01 Broken Access Control | PASS. Provider-token path binding returns 403 on token/path mismatch in address registration and payout read. Admin payout endpoints are behind constant-time operator-key middleware. |
| A02 Cryptographic Failures | LOW. KEK/dev raw zeroization and EIP-712/signer checks are present; malformed wallet plaintext zeroization gap remains. |
| A03 Injection | PASS. Reviewed payout SQL paths use `?` bindings; chain calldata is ABI-built from validated addresses/amounts, not string-concatenated SQL or shell. |
| A04 Insecure Design | PASS with HIGH related config concern. Money path includes EIP-712 recovery, nonce anti-replay, C3 amount invariant, self-fence before chain writes, cap checks, and two-RPC receipt/balance discipline, but that discipline depends on trustworthy RPC origins. |
| A05 Security Misconfiguration | HIGH. Payout RPC URL validation/deploy gate does not enforce HTTPS, non-internal targets, or independent origins. |
| A06 Vulnerable Components | PASS. `govulncheck ./...` from `phase4-coordinator/` found 0 called vulnerabilities. |
| A07 Authentication Failures | PASS. Operator-key middleware uses `subtle.ConstantTimeCompare`; provider token validation uses hashed token lookup and enforces provider subject matching. |
| A08 Software/Data Integrity Failures | HIGH related. Two-RPC agreement can be defeated if config allows attacker-controlled RPC origins. |
| A09 Logging/Monitoring Failures | PASS. No bearer/KEK/private key/raw signed tx leaks found in scoped log sweep; holder token and SPKI emissions are prefix/redacted. |
| A10 SSRF | HIGH. Raw configured payout RPC URLs are used for outbound HTTP without URL/host network constraints. |

## High-Leverage Probe Results

- End-to-end money path: PASS for code controls reviewed. Address registration enforces provider token subject match, EIP-712 verification, skew/nonce anti-replay, deny-list, pause pre-check and in-transaction pause re-check. Runner enforces C3 amount invariant, per-payout cap, daily cap, insufficient-funds halt, self-fence before critical chain-write sections, post-COMMIT self-fence before broadcast, and two-RPC confirmation checks.
- Cross-step authority: PARTIAL because RPC trust roots are under-validated. Tuning reads use `Snapshot()` for live consumers reviewed; SIGHUP uses `LoadPayoutTuningOnly` and does not load `payout.security.*`; run-now uses the live `RunNowMinInterval` and halted gate.
- Provider/operator/bearer surface: PASS. Provider mismatch is 403 for both provider payout routes; missing/bad token is 401. Admin endpoints are operator-key authenticated via constant-time comparison.
- SQL injection: PASS. Payout implementation queries reviewed use bind parameters; no string-built SQL injection path found.
- Secret leak sweep: PASS for production secrets. Scoped high-confidence pattern scan found no production bearer tokens, wallet keys, API keys, production RPC URLs, or private keys in implementation paths.
- Dependency/race: PASS. `govulncheck ./...` reported no called vulnerabilities. `go test -race -count=1 ./...` passed in `phase4-coordinator/`.

## Security Checklist

- [x] No hardcoded production secrets found in scoped implementation scan
- [x] Provider-token path authorization verified
- [x] Operator-key middleware constant-time comparison verified
- [x] Input sizes bounded on payout JSON endpoints
- [x] SQL injection prevention verified for reviewed payout queries
- [x] EIP-712 signer recovery and anti-replay registration path reviewed
- [x] Two-RPC receipt/balance agreement logic reviewed
- [ ] Payout RPC URL scheme/host/origin validation enforced
- [ ] Decrypted wallet plaintext zeroized on malformed-length error path
- [x] Dependencies audited with `govulncheck`
- [x] Race tests run with `go test -race -count=1 ./...`
