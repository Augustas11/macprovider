# Privacy and retention

Mac Provider routes buyer prompts to volunteer Apple Silicon Macs. There are two modes:

## Default mode

Ordinary requests without the opt-in privacy class are **plaintext to the gateway and the serving Mac**. Providers can technically observe prompts and outputs that route through their machine. This mode has no private-inference guarantee.

## Opt-in privacy class

The Beta privacy class, `operator_constrained_beta_v1` (SPEC-049), is available for **chat completions only**, using the encrypting `relay-blind-client`. Ordinary OpenAI-compatible clients do not opt in automatically.

The client encrypts the request to the reserved provider, and the provider runtime encrypts its response to the client. The **gateway and coordinator cannot read request or response content**. Routing admits only enrolled providers whose freshly verified posture reports an approved, signed, hardened runtime. A request that requires the class fails rather than silently falling back to plaintext.

The **provider runtime still reads plaintext to run inference**. On a genuine approved signed runtime, documented ordinary operator access paths are blocked or refused, including debugger attach, core dumps, content logs and traces, disk caches, and plaintext proxy or subprocess hops. This is not provider-blind inference, confidential compute, a hardware enclave, or end-to-end encryption that excludes the provider.

The default assurance, `device_bound_self_attested_beta`, uses device-bound signed posture; a modified runtime can forge that posture because its key is not bound to the code signature. The optional `code_bound_attested` assurance adds a Malibu.app App Attest assertion after a kernel code-identity check, verified by the coordinator, not the buyer. Neither assurance protects against root or kernel compromise, physical attacks, or a malicious signed release, or proves that the provider did not retain plaintext.

Relays still see request metadata such as account, model, sizes, timing, token counts, and status. The privacy class does not provide zero data retention.

## Conversation cache

Privacy-class requests bypass provider disk and conversation caches. For ordinary requests:

Authenticated non-demo chat completions may let the serving Mac reuse an encrypted provider-local KV cache under an opaque HMAC conversation identifier. Reuse remains bounded by the conversation-cache TTL (15 minutes by default); encrypted files are cleanup-bounded by the configured retention (60 minutes by default) and cleanup does not extend reuse. The identifier does not pin routing or reveal your account id to the provider. DELETE /v1/sticky durably revokes registered cache scopes; its response remains pending while a disconnected provider or coordinator restart delays provider acknowledgement. GET /v1/sticky reports whether acknowledgements remain pending without starting another revocation.

## Zero data retention

There is **no zero-data-retention (ZDR) guarantee**. The OpenRouter ingest document sets `compliance.zdr` to `false` because that is the honest answer.

Mac Provider does **not** claim:

- provider-blind inference or end-to-end encryption that excludes the provider
- hardware attestation of provider machines
- a US datacenter region such as `us-east-1`

## Training

Mac Provider does not train foundation models on buyer prompts.

## What we retain

Request metadata needed for routing, quota, settlement, and wholesale partner monthly statements is retained in coordinator `request_log` for 14 days by default, matching the shipped coordinator `storage.request_log_retention_days` configuration. Operators may only change that by changing the coordinator configuration. That metadata includes account identity, model id, token counts, timestamps, and settlement fields. Before an account's rows leave, its successful requests are kept as per-day, per-model totals of requests and tokens, which wholesale partner monthly statements read; those totals carry no request ids, prompts, or outputs. Prompt and completion bodies are not stored as a training corpus.

## Contact

Questions about this page: see [docs](/docs).
