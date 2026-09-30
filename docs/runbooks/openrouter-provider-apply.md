# OpenRouter provider apply

This runbook is the operator packet for listing Malibu on OpenRouter. The
listing is one model: `mlx-community/Qwen3.6-35B-A3B-4bit` (OpenRouter slug
`qwen/qwen3.6-35b-a3b`), paid only, no free alias (SPEC-006 v0.9.40 §5.3.2).
Chat stays on `https://api.malibu.tech/v1/chat/completions`. The only additive
ingest URL is `GET /v1/openrouter/models`.

## Do not apply until soak passes

Run the readiness probe with the named wholesale/OpenRouter `mp_` key against
`mlx-community/Qwen3.6-35B-A3B-4bit` (the probe default) and keep its JSON output as the
public soak artifact:

```bash
EXPECTED_GATEWAY_VERSION="$(git describe --always --tags origin/main)"
MACPROVIDER_SPEC015_API_KEY="$OPENROUTER_WHOLESALE_MP_KEY" \
  python3 scripts/openrouter_readiness_probe.py \
    --base-url https://api.malibu.tech \
    --model mlx-community/Qwen3.6-35B-A3B-4bit \
    --expected-healthz-version "$EXPECTED_GATEWAY_VERSION" \
    --benchmark-requests 100 \
    --benchmark-concurrency 4 \
    --saturation-requests 16 \
    --saturation-concurrency 8 \
    --output "$HOME/.local/state/macprovider/openrouter-readiness/openrouter-readiness-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
```

The probe validates:

- OpenRouter schema-2.4-native model rows: typed modalities, modality-owned
  prices and capacity, an honest deployment-region descriptor, any declared
  datacenters, `compliance.zdr=false`, and exactly the listed Qwen3.6 paid
  row: any other row fails. The row must carry exactly the SPEC-006 `tools` /
  `tool_choice` / `response_format` / `structured_outputs` descriptors, and
  rows outside the SPEC-018/SPEC-019 families must not declare them. A free
  alias row is checked only for a listing that declares one; Qwen3.6 does not
- authenticated non-streaming chat completion content plus `usage`
- authenticated streaming chat completion chunks plus final `usage`; if the
  stream is shorter than the gateway keepalive tick, the artifact records
  keepalive as `not_applicable_fast_stream`
- in filing mode, an authenticated chat smoke against the paid model (and the
  free alias only when the listing declares one)
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
- Model: `mlx-community/Qwen3.6-35B-A3B-4bit`, paid only, no free SKU
- OpenRouter catalog slug: `qwen/qwen3.6-35b-a3b`
- Features declared on the row: `tools`, `tool_choice` (`auto` only),
  `response_format` (object descriptor whose `type` is `text`, `json_object`
  or `json_schema`), `structured_outputs`. `json_schema` is strict-only (SPEC-019): a schema
  without `additionalProperties:false` on every object returns HTTP 400.

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
from an operator network. Filing mode requires the listed Qwen3.6 row to be
`is_ready=true` and checks the paid statement line. Use this command for the
final OpenRouter
application artifact:

```bash
EXPECTED_GATEWAY_VERSION="$(git describe --always --tags origin/main)"
MACPROVIDER_SPEC015_API_KEY="$OPENROUTER_WHOLESALE_MP_KEY" \
OPERATOR_KEY="$OPERATOR_KEY" \
  python3 scripts/openrouter_readiness_probe.py \
    --base-url https://api.malibu.tech \
    --expected-healthz-version "$EXPECTED_GATEWAY_VERSION" \
    --admin-url https://coordinator.malibu.tech \
    --statement-account-id acct_openrouter \
    --statement-period "$(date -u +%Y-%m)" \
    --filing-mode \
    --benchmark-requests 100 \
    --benchmark-concurrency 4 \
    --saturation-requests 16 \
    --saturation-concurrency 8 \
    --output "$HOME/.local/state/macprovider/openrouter-readiness/openrouter-readiness-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
```
