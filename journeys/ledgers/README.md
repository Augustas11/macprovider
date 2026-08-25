# SPEC-043 promotion ledger

Named subsystem: `spec043-promotion-ledger`.

Store: append-only JSONL at `journeys/ledgers/spec-043-promotion-auth.jsonl`.

This file is the R012 rollback-resistant store for run-id high-watermarks, consumed authorization ids, per-pool transition epochs, launch-key revocations, and emergency-disable tombstones. It is separate from coordinator snapshot/SQLite state. Restoring coordinator storage MUST NOT rewind this ledger.

`JOURNEY-TRUSTED-POOL-CREATOR-MVP` candidate envelopes remain evidence-only. This ledger is consumed only by a valid `PoolPromotionTransitionV1` artifact (`spec-043-promotion-auth-v1`).
