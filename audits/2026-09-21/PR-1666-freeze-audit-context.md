# PR #1666 freeze audit — keyed first-turn CB canary

Gate: 0 CRITICAL, 0 HIGH, 0 MEDIUM. LOW/INFO may be carried explicitly.
Review the complete landing diff vs origin/main, not a follow-up slice.

## Campaign

Pearl/wholesale chats always carry a conversation key (or auto-prefix).
Studio 175 canary serial-routed every keyed request as
`conversation_key_rollout_unavailable`, so keyless loopback 4-wide was
theater. This change: a conversation key alone no longer blocks scheduler
admission. First-turn / cache-miss (`cached_prompt_tokens = 0`) may batch.
Positive cache hits without a retained FR-PKV10 paged-KV handoff still
serial-route as `sticky_cache_handoff_unavailable`.

Do not set `continuous_batching: on`. Do not raise slots. Do not promote
the fleet. Do not treat a worktree binary as an enable path.

## Lab PASS (isolated 127.0.0.1:18084, 8B, live 8080 untouched)

Evidence: `docs/runbooks/cb-keyed-first-turn-canary-lab-e2e-2026-09-21.md`

- 4 concurrent keyed POSTs, unique conversation keys, unique X-Request-ID
- 4/4 HTTP 200, cached_prompt_tokens=0, overlap wall 1.111s vs ~1s each
- no `conversation_key_rollout_unavailable` on the request path
- live 8080 stayed PID 24569 / signed 175

## Must not regress

- Sticky/cross-turn **positive** cached tokens without retained paged-KV
  handoff still serial-route (AC-26).
- `conversation_key_rollout_unavailable` remains in the reason enum for
  API compatibility but must not be assigned by admission.
- Buyer receipts/usage/billing schema unchanged.
- Keyless loopback 200 is not buyer-enable evidence.

## Diff vs origin/main

The freeze diff is attached after this heading. Files: ContinuousBatching.swift,
ModelRuntime.swift, ServingKnobsConfigTests.swift, SPEC-038, SPEC-024,
CONFORMANCE, specs/README.md, enable-gate runbook, train row, this evidence.

Return findings as:
CRITICAL / HIGH / MEDIUM / LOW / INFO
or explicitly: 0 CRITICAL, 0 HIGH, 0 MEDIUM.
