# OpenRouter provider apply

This runbook is the operator packet for listing the live 6-node Malibu pool on
OpenRouter. Chat stays on `https://api.malibu.tech/v1/chat/completions`. The
only additive ingest URL is `GET /v1/openrouter/models`.

## Do not apply until soak passes

Run the readiness probe with the named wholesale/OpenRouter `mp_` key against
`mlx-community/Llama-3.2-3B-Instruct-4bit` and keep its JSON output as the
public soak artifact:

```bash
MACPROVIDER_SPEC015_API_KEY="$OPENROUTER_WHOLESALE_MP_KEY" \
  python3 scripts/openrouter_readiness_probe.py \
    --base-url https://api.malibu.tech \
    --model mlx-community/Llama-3.2-3B-Instruct-4bit \
    --benchmark-requests 100 \
    --benchmark-concurrency 4 \
    --saturation-requests 16 \
    --saturation-concurrency 8 \
    --output "$HOME/.local/state/macprovider/openrouter-readiness/openrouter-readiness-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
```

The probe validates:

- OpenRouter schema-2.4-native model rows: typed modalities, modality-owned
  prices and capacity, an honest deployment-region descriptor, any declared
  datacenters, `compliance.zdr=false`, the requested paid row, and in
  filing mode the ready zero-priced free alias row
- authenticated non-streaming chat completion content plus `usage`
- authenticated streaming chat completion chunks plus final `usage`; if the
  stream is shorter than the gateway keepalive tick, the artifact records
  keepalive as `not_applicable_fast_stream`
- in filing mode, an authenticated chat smoke against the free alias as well as
  the paid model
- bounded TTFT and generated-output-token throughput evidence for
  OpenRouter-like streaming requests
- early provider-capacity shedding as `no_provider_available` HTTP 429 in the
  explicit saturation pass; account/quota/rate-limit 429s do not satisfy this
  check
- `/privacy` retaining the plaintext/no-ZDR/no-training disclosure and the
  default 90-day request-log retention statement

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
- OpenRouter catalog slug: `meta-llama/llama-3.2-3b-instruct` for paid and
  `meta-llama/llama-3.2-3b-instruct:free` for free

Submit at [openrouter.ai/providers/apply](https://openrouter.ai/providers/apply)
only after the soak and after `/privacy` is live.

## Operator statement export

Generate the wholesale statement before filing and attach the JSON plus CSV
headers to the operator evidence packet. The export is invoicing-readiness
evidence for OpenRouter's postpaid path, not proof that a payment has settled.
Malibu does not use auto top-up, Stripe checkout, card collection, or live
request-time HTTP 402 for wholesale accounts.

```bash
curl -sS -H "Authorization: Bearer $OPERATOR_KEY" \
  -H "Content-Type: application/json" \
  -d '{"account_id":"acct_openrouter","period":"2026-09"}' \
  https://coordinator.internal/admin/ledger/wholesale-statements

curl -sS -H "Authorization: Bearer $OPERATOR_KEY" \
  "https://coordinator.internal/admin/ledger/wholesale-statements/<wholesale_statement_id>?format=csv"
```

The readiness probe can verify the statement endpoint and CSV naming when run
from an operator network. Filing mode also verifies the live free alias row and
runs a free-alias chat smoke. Use this command for the final OpenRouter
application artifact:

```bash
MACPROVIDER_SPEC015_API_KEY="$OPENROUTER_WHOLESALE_MP_KEY" \
OPERATOR_KEY="$OPERATOR_KEY" \
  python3 scripts/openrouter_readiness_probe.py \
    --base-url https://api.malibu.tech \
    --admin-url https://coordinator.internal \
    --statement-account-id acct_openrouter \
    --statement-period "$(date -u +%Y-%m)" \
    --filing-mode \
    --benchmark-requests 100 \
    --benchmark-concurrency 4 \
    --saturation-requests 16 \
    --saturation-concurrency 8 \
    --output "$HOME/.local/state/macprovider/openrouter-readiness/openrouter-readiness-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
```
