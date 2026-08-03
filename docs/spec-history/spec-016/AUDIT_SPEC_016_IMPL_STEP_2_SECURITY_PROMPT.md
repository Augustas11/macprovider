# IMPL audit prompt — SPEC-016 Step 2, **SECURITY REVIEW lane**

Lane 2 of 3 parallel codex audit lanes for SPEC-016 Step 2 IMPL
on branch `impl/spec-016`. Master shared-context preamble lives
in `specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md`.

Fire via:

```
omc ask codex --agent-prompt security-reviewer --prompt "<this file's body>"
```

Expected wall-clock: 50–70 min (Step 2 surfaces money-OUT and
admin-key paths; adversarial probing matters here).

This is **read-only** — codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are the security-reviewer lane (2 of 3) auditing SPEC-016
Step 2 IMPL. Two sibling lanes (code-reviewer + architect) fire
in parallel; your scope is SECURITY ONLY.

## Shared context

Read `specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md` for the FULL
shared-context preamble. Step 2 is the FIRST IMPL piece where
the runner has the hot-wallet key in process memory and broadcasts
money-out transactions to Base mainnet. **Be paranoid.**

SPEC v0.1.21 LOCKED at `f0152c0`. Step 2 IMPL HEAD at `db5c9ba`.

## Lane scope: security review

### Threat models recap (apply to every finding)

- **Adversary A (stolen `provider_token`):** §3.3 + EIP-712 PoP
  unchanged from Step 1; verify Step 2's mux extension doesn't
  weaken it.
- **Adversary B (on-path / mempool attacker):** replayed
  signed-bytes, malleability, M4 chain-nonce race.
- **Adversary C (operator-key compromise):** Step 2's biggest
  new attack surface — the abandon endpoint can BURN GAS at
  scale if cap-enforcement is wrong. Probe every cap, every
  rate-limit, every txn boundary.
- **Adversary D (compromised Signer):** SPEC §4.3 step 6
  NORMATIVE pre-broadcast verify + §4.3 step 7 chain-side
  verify catch this. Both must be tight.
- **Adversary E (lying RPC):** §4.4 two-RPC discipline.

### Focus areas

1. **EIP-1559 signing correctness.**
   - SignTx digest = keccak256(0x02 || rlp_unsigned). Verify
     this matches an independent reference (ethers.js v6
     `signTransaction` produces an envelope whose
     `keccak256(envelope_minus_signature)` matches our
     SigningHash).
   - Verify y_parity → 27+y reordering for decred RecoverCompact
     is sound: a signature recovered from the runner's signed
     envelope MUST recover to the same address ethers.js would
     recover.
   - Probe RFC 6979 determinism (decred's ecdsa.SignCompact is
     deterministic) — confirm no per-process randomness leaks.

2. **§4.3 step 6 pre-broadcast verification (verifySignedTx).**
   - All 6 checks present (nonce, chain_id, to, value=0, calldata,
     tx_hash, ecrecover).
   - Probe an attack: a compromised Signer returns a tx signed
     by a different key but advertises the right FromAddress;
     verify ecrecover catches this BEFORE broadcast.
   - Probe: calldata bug (wrong recipient address baked into
     the calldata); verify byte-equality vs USDCTransferCalldata.
   - Side-channel: confirm zero raw_signed_tx / tx_hash leaks
     on discard paths.

3. **§4.3 step 7 chain-side verification (verifyChainSideTransfer).**
   - (a) tx.input byte-equality on BOTH RPCs.
   - (b) recovered sender = hot wallet.
   - (c) exactly ONE matching Transfer log with
     correct address / topics / amount.
   - Probe: a "tx succeeds but no USDC transferred" scenario
     (USDC contract upgrade attack); verify all three checks
     would catch it.
   - Probe: receipt has MULTIPLE Transfer logs (sandwich
     attack); verify "exactly one" is enforced.

4. **M4 chain-nonce race (§4.8b).**
   - The post-CAS broadcast race window between post-COMMIT
     lease re-read and eth_sendRawTransaction is unguarded by
     software — chain nonce-uniqueness is the load-bearing
     guard.
   - Runner exposes `SleepAfterPostCommitLeaseReread` hook;
     verify production wiring leaves it at zero.
   - Probe: write a regression test that drives the race; verify
     IsNonceTooLow catches the nonce-collision response WITHOUT
     emitting payout_invariant_violation.

5. **§4.6 abandon endpoint hardening.**
   - Runner-active gate (IsLeaseActive) is INSIDE the BEGIN
     IMMEDIATE txn — confirm the lease cannot stale-out between
     the gate check and the abandon UPDATE.
   - Per-cancel gas cap + 24h aggregate cap both enforced in
     SAME txn.
   - Abandon-marker UPDATE gated on confirmed_at_utc IS NULL
     AND abandoned_at_utc IS NULL — closes v0.1.12 round-13
     MED-1 (don't allow marking a confirmed row abandoned).
   - Cancel envelope preflight via verifyCancelEnvelope BEFORE
     COMMIT; same code-path discipline as §4.3 step 6.
   - broadcast_at_utc persisted NULL at INSERT — closes v0.1.14
     round-15 MAJOR-1.

6. **Signer key custody (signer.go).**
   - LoadLocalFileSigner: KEK len enforced 32; wrong-KEK error
     does NOT leak key material. Probe with multiple wrong
     KEKs.
   - Plaintext slice zeroed after secp256k1.PrivKeyFromBytes
     internalises a copy.
   - SignTx: in any error path, the error MUST NOT include the
     private key bytes or KEK. Probe every error branch.
   - Footgun-check: NO SignMessage primitive. Search the codebase
     for any `Sign[A-Z]` method other than SignTx.

7. **Two-RPC discipline (§4.4).**
   - Cold-start: diff > 1 → halt. Probe with crafted RPC mocks.
   - Receipt: ReceiptsAgree catches block_hash divergence
     (closes the same-block-number-different-content reorg gap).
   - Broadcast: at-least-one accept → success; both reject →
     leave pending; nonce-too-low on ONE side → not invariant
     violation.

8. **Reorg poll (§4.7).**
   - One-RPC error MUST NOT count as reorg.
   - BOTH-RPC-not-found MUST trigger cancel vs provider carve-out.
   - Cancel-side LIVE-AGAIN UPDATE clears
     cancel_reconfirm_stale_paged_at_utc per v0.1.16/17.

9. **DSN durability + concurrent connections (carried from Step 1).**
   - Step 2 didn't change DSN; confirm `synchronous=FULL` still
     holds on every connection the runner opens. 8-conn PRAGMA
     probe.

10. **Dev signer loader escape (cmd/coordinator/main.go).**
    - loadPayoutSigner uses MACPROVIDER_PAYOUT_WALLET_KEY_HEX_DEV_ONLY
      env. Probe: can this env var be set in production by an
      attacker with file-write to /etc/systemd? Compare risk
      vs production LoadCredential= path; recommend Step 4
      hardening.

11. **`govulncheck ./...`** — re-run on Step 2 surface.
    Independent crypto cross-check: drive ethers.js or
    web3.py to sign a tx with the test key, then feed the
    envelope through DecodeSignedEIP1559 + RecoverTxSender;
    assert the same sender comes back.

Findings format:

```
[sec:N.M] [SEVERITY] <short title>
  Asset: <what's at risk>
  Vector: <how the attacker exploits>
  File: <path>:<line>
  Fix: <suggested remediation; cite SPEC §-rule>
```

Severity scale per master prompt.

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_2-security-r1-audit.md`.

## Discipline

- Model the attacker explicitly. Without an attacker model, a
  finding is a smell, not a security defect.
- Reference threat-model adversary (A / B / C / D / E) for every
  finding so the consolidator prioritises by blast radius.
- BLOCK only on new CRITICAL or critical-class regression.

You may run shell commands. You MUST NOT modify any file.

You may take up to 60 min wall-clock.

=== END PROMPT ===
```
