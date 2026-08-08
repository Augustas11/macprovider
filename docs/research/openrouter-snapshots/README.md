# OpenRouter pricing artifact archive

This directory is the durable UTC archive for validated OpenRouter pricing
snapshots and the proposals computed from them. A successful operator run must
copy the atomically emitted files here without editing their contents:

- `openrouter-pricing-snapshot-<YYYYMMDDTHHMMSSZ>.json`
- `openrouter-rate-card-proposal-<YYYYMMDDTHHMMSSZ>-<digest8>.json`

The snapshot is the source of truth for its proposal. Preserve the snapshot
content digest, proposal source-snapshot digest, command logs, exit statuses,
and review notes with the archived artifacts. A failed-closed fetch produces no
snapshot and must not be represented by a hand-created placeholder. The
proposal step must not run unless fetch emitted a validated snapshot. There is
no apply operation in this archive workflow.