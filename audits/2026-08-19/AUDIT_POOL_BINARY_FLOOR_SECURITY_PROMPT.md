# Codex audit — SPEC-042 pool binary-version floor — SECURITY lane

Tenant-isolation change on a money/security path. The product promise: a pool
request is never served by a pool-blind (under-version) provider. Review the
FULL slice diff as it will land.

Diff: `audits/2026-08-19/pool-binary-floor-fulldiff.patch`. Read changed files in
the worktree. Spec: `specs/SPEC-042-pool-control-plane.md` (R004 fail-closed
predicates, R010 positive capability handshake + taxonomy, R005 generation
fence). Design: `docs/design/spec-042-v0.1-slice-pool-binary-floor.md`.

## Threat model to attack
- A buyer / operator tries to get a pool request served by a member whose binary
  is below the pool's floor (mixed-binary rollout spill): via the ordinary
  filter, a hard pin (session/provider header), or the slot queue / a same-ID
  reconnect after selection.
- A revocation-style race: floor raised mid-flight; can an in-flight reservation
  fenced to the old generation still dispatch to a now-under-version member?
- An empty or crafted `binary_version` that bypasses the floor (Compare returns
  ok=false — is that treated as excluded everywhere, or does any path fail open?).
- Does `pool_binary_too_old` leak anything it shouldn't? (It is authorized-only
  visibility — returned only for a credential-authorized pool selection.)

## Focus (Critical/High/Medium/Low/Info, file:line + concrete exploit)
1. Fail-closed completeness: is EVERY dispatch-authorizing path gated (filter,
   pinned session, pinned/self-route, slot-queue enter, slot-queue poll, and any
   retry/failover re-dispatch)? Give a concrete path if one is missed.
2. Fail-open on malformed input: empty/`v`-prefixed/garbage `binary_version`
   while a floor is in force MUST be excluded. Any path returning true on
   Compare-not-ok?
3. Snapshot/fence integrity: floor + members + generation captured atomically;
   `SetMinBinaryVersion` bumps generation; the fence rejects a stale-generation
   dispatch. Any window where a raised floor is not enforced.
4. No global/poolless regression: the gate is a strict no-op when poolID=="" or
   floor=="". Confirm no behavior change for non-pool traffic.
5. Any secret/PII logged; any concurrency hazard on the trustpool lock.

Give concrete exploit steps for any finding. The go 1.26 stdlib toolchain
finding (if govulncheck flags it) is pre-existing (#1055), not a slice defect —
note but do not score it. Report 0 if genuinely clean.
