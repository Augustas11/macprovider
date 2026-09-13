# Privacy and retention

Mac Provider routes buyer prompts to volunteer Apple Silicon Macs. Prompts and completions are processed as **plaintext** on those machines. Providers can technically observe the traffic that lands on their hardware.

## Zero data retention

There is **no zero-data-retention (ZDR) guarantee**. The OpenRouter ingest document sets `compliance.zdr` to `false` because that is the honest answer.

Mac Provider does **not** claim:

- private inference
- hardware attestation of provider machines
- a US datacenter region such as `us-east-1`

## Training

Mac Provider does not train foundation models on buyer prompts.

## What we retain

Request metadata needed for routing, quota, settlement, and wholesale partner monthly statements is retained in coordinator `request_log` for 90 days by default, matching the shipped coordinator `storage.request_log_retention_days` configuration. Operators may only change that by changing the coordinator configuration. That metadata includes account identity, model id, token counts, timestamps, and settlement fields. Prompt and completion bodies are not stored as a training corpus.

## Contact

Questions about this page: see [docs](/docs).
