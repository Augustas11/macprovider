# #1646 M5 durable relay replay evidence

Date: 2026-09-26

Result: **PASS for the M5 real-Mac lab regression.** This is not packaged or
signed continuous-batching enable evidence and does not authorize `canary` or
`on`.

## Studio evidence

- The Mac Studio built the test artifact from the synced campaign `Sources`.
  The audited local release binary SHA-256 was
  `74a6ae9157059fc3909beb58c71ec93b95a72b8e22ee1e901d6a0e8b665ce33a`.
- The exercised surface was the test-only relay fixture. Stable request
  `relay-stable-m5-terminal-replay-studio` first completed with disposition
  `eligible_owner` and generation count `1`.
- The signed v4 receipt was cryptographically verified and bound to the
  provider, model, model hash, terminal timestamp, and usage.
- After relay reconstruction, the same request completed with disposition
  `non_settling_replay`. Generation count remained `1`, usage was identical,
  and no duplicate receipt was emitted.
- The replay authority contained exactly one durable JSON claim. Every store
  directory had mode `0700`, and the claim file had mode `0600`.
- The live provider was untouched. After the lab run, the installed live CLI
  status said exactly `Provider is ready`.

This closes M5 as real-Mac regression evidence only. The binary was locally
built on the Studio from campaign sources and was not packaged, signed, or
installed as an enable candidate; the requirements in
[`continuous-batching-enable-gate.md`](continuous-batching-enable-gate.md)
remain open.

## Local validation and audit gate

- Focused Go durable-terminal-replay test: **PASS**.
- Full Swift suite: **PASS** — 3545 executed, 55 skipped, 0 failures in
  272.022 seconds.
- Code audit R1: **PASS**.
- Security audit R1: **PASS**.
- Architecture audit R1: one **MEDIUM**, fixed before the Studio run.
- Architecture audit R2: **PASS**.
- Final audit gate: **0 CRITICAL, 0 HIGH, 0 MEDIUM**.

Audit details are recorded in
[`audits/2026-09-26-cb-m5-replay/README.md`](../../audits/2026-09-26-cb-m5-replay/README.md).
