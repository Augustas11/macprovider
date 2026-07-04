# SPEC-027 — Provider Proof of Ownership for App-Track Wallet Changes

Status: SKELETON v0.1 · Owner: augstar · Target: follow-up to SPEC-026 Wave 2

## 1. Purpose

SPEC-027 will define the non-bearer proof mechanisms required before App-track
providers can change payout wallets, cancel pending wallet swaps, or rotate
proof roots without weakening token custody.

This Wave 2 skeleton exists so SPEC-026 and coordinator handlers can fail
closed with a named dependency instead of inventing partial proof semantics.

## 2. Blocking Requirements

- App-track wallet changes MUST remain unavailable until this spec defines a
  provider proof that does not rely only on the bearer token.
- Receipt-key rotation MUST prove possession of the currently-published receipt
  key. A request signed only by the proposed replacement key is not proof.
- Provider-token mutation MUST require proof of the existing token or an
  operator recovery action. Tokenless reconnects MUST NOT revoke or replace
  active token rows.
- Any user-visible wallet-swap cancel affordance MUST have coordinator-side
  state-machine semantics before it ships.

## 3. Non-Goals for the Skeleton

- No endpoint shapes are locked here.
- No EIP-712 domain is locked here.
- No email, deep-link, or push-notification channel is locked here.
- No recovery SLA or operator approval quorum is locked here.

## 4. Interim Coordinator Behavior

Until this spec is complete, `POST /v1/provider/wallet` returns:

```json
{"error":"wallet_change_requires_spec_027"}
```

with HTTP `501 Not Implemented`.
