# Codex audit: Qwen3.6 CB performance milestone

Commits:
- `3a91f1bc`: in-place paged KV.
- `2d34c88b`: LaunchAgent `ProcessType` `Standard` (SPEC-003 v0.11.4).
- `b8010f0c`: bounded decode window while prefilling, and no prefill logits
  (SPEC-038 v0.2.10).
- `2615d00f`: allocator-block buffer growth, and freed blocks released on
  `trim`.

The review scope was the full `b0f3d45f..HEAD` diff over `phase3-binary` and
`specs`.

| Lane | R1 | R2 |
| --- | --- | --- |
| Code | **PASS** | not re-run |
| Security / money path | FAIL 0/0/1 (see below) | **PASS**, on the full diff including `2615d00f` |
| Architecture | **PASS** | not re-run |

The R1 security MEDIUM: dense KV buffers grew in 256-token steps beyond the
allocator's block accounting (SPEC-039 FR-PKV2), and `trim` retained that
capacity. `2615d00f` fixed it.

Carried, pre-existing: during a decode session the batch layer buffer holds a
padded copy of the rows' KV. The old `concatenatePadded` path allocated the
same copy on every step.
