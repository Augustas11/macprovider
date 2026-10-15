# Privacy and retention

Mac Provider routes buyer prompts to volunteer Apple Silicon Macs. Prompts and completions are processed as **plaintext** on those machines. Providers can technically observe the traffic that lands on their hardware.

Authenticated non-demo chat completions may let the serving Mac reuse an encrypted provider-local KV cache under an opaque HMAC conversation identifier. Reuse remains bounded by the conversation-cache TTL (15 minutes by default); encrypted files are cleanup-bounded by the configured retention (60 minutes by default) and cleanup does not extend reuse. The identifier does not pin routing or reveal your account id to the provider. DELETE /v1/sticky durably revokes registered cache scopes; its response remains pending while a disconnected provider or coordinator restart delays provider acknowledgement. GET /v1/sticky reports whether acknowledgements remain pending without starting another revocation.

## Zero data retention

There is **no zero-data-retention (ZDR) guarantee**. The OpenRouter ingest document sets `compliance.zdr` to `false` because that is the honest answer.

Mac Provider does **not** claim:

- private inference
- hardware attestation of provider machines
- a US datacenter region such as `us-east-1`

## Training

Mac Provider does not train foundation models on buyer prompts.

## What we retain

Request metadata needed for routing, quota, settlement, and wholesale partner monthly statements is retained in coordinator `request_log` for 14 days by default, matching the shipped coordinator `storage.request_log_retention_days` configuration. Operators may only change that by changing the coordinator configuration. That metadata includes account identity, model id, token counts, timestamps, and settlement fields. Before an account's rows leave, its successful requests are kept as per-day, per-model totals of requests and tokens, which wholesale partner monthly statements read; those totals carry no request ids, prompts, or outputs. Prompt and completion bodies are not stored as a training corpus.

## Contact

Questions about this page: see [docs](/docs).
