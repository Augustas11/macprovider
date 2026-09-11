# OpenRouter provider apply

This runbook is the operator packet for listing the live 6-node Malibu pool on
OpenRouter. Chat stays on `https://api.malibu.tech/v1/chat/completions`. The
only additive ingest URL is `GET /v1/openrouter/models`.

## Do not apply until soak passes

Run ≥100 requests on the named wholesale `mp_` key against
`mlx-community/Llama-3.2-3B-Instruct-4bit` (and the `-free` alias) on the live
pool. Record:

- success ratio versus the current ~5 rpm / 16% utilization baseline
- that coordinator 503 `no_provider_available` is translated to gateway 429
- that stream responses include a final `usage` chunk
- that free-SKU rows are $0 on the wholesale statement and still credit nodes

Do not submit the OpenRouter form on a failing soak.

## Apply packet

- Provider name: Malibu / Mac Provider
- Base URL: `https://api.malibu.tech/v1`
- Models document: `https://api.malibu.tech/v1/openrouter/models`
- Privacy / retention: `https://api.malibu.tech/privacy`
- ZDR: false (plaintext on volunteer Macs)
- Payment: monthly postpaid USD statement (D1a). No Stripe. Unpaid statements
  are an operator kill-switch, never a live HTTP 402.
- Dual SKU: paid pool id plus `-free` alias on the same Llama 3B nodes

Submit at [openrouter.ai/providers/apply](https://openrouter.ai/providers/apply)
only after the soak and after `/privacy` is live.

## Operator statement export

```bash
curl -sS -H "Authorization: Bearer $OPERATOR_KEY" \
  -H "Content-Type: application/json" \
  -d '{"account_id":"acct_openrouter","period":"2026-09"}' \
  https://coordinator.internal/admin/ledger/wholesale-statements

curl -sS -H "Authorization: Bearer $OPERATOR_KEY" \
  "https://coordinator.internal/admin/ledger/wholesale-statements/<wholesale_statement_id>?format=csv"
```
