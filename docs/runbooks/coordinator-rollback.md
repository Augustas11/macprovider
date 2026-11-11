# Coordinator rollback

**Scope**: what happens when a Pearl runtime apply (coordinator and gateway)
fails, and what to do if the automatic rollback itself fails. The mechanism is
the signed Pearl updater, documented in
[`ops/runbooks/pearl-release-updater.md`](../../ops/runbooks/pearl-release-updater.md)
("Automatic rollback"). Applies and every other live change go through
`scripts/ops/pearl-runtime.sh` (AGENTS.md rule 8); do not swap binaries by hand.
Rollout rules and expected downtime:
[`pearl-coordinator-rollout.md`](pearl-coordinator-rollout.md).

The old `.prev` binary swap is retired. Do not use it.

## What rolls back automatically

An install, restart, semantic-health, provider-recovery, public-TLS or buyer
canary failure during an apply makes the updater roll the transaction back:

- it stops both daemons and proves them inactive;
- it restores the previous binaries and configuration;
- it checks every pre-rollout database copy with `PRAGMA quick_check` and
  restores the databases only if all copies pass (otherwise no database is
  touched and the rollback continues with binaries, configuration and state);
- it starts the prior coordinator, then the prior gateway, and proves provider
  reconnect, gateway serving and the restored public versions.

The apply is synchronous and rollback-armed: success is persisted only after the
serving proofs pass.

## Check the outcome

```
scripts/ops/pearl-runtime.sh status
```

`status` is read-only. If the previous apply of the tag failed and was rolled
back, its apply step reports that and tells you to read the updater journal
first. Confirm the live version from the public `/healthz` of the coordinator
and gateway: after a rollback both report the previous tag. Fix the cause
before retrying; every failed apply is another outage (rollout runbook, rule 4).

## If automatic rollback fails

Only what the updater runbook documents:

1. Leave the buyer canary timer disabled. Do not delete or edit
   `active-transaction.json`, and keep the named transaction directory under
   `/var/lib/macprovider-pearl-updater` for forensics.
2. Run the idempotent reconcile and read the updater journal, as written in
   "Automatic rollback" in the updater runbook (`--reconcile`, then
   `journalctl -u macprovider-pearl-updater -u 'macprovider-pearl-updater-alert@*'`).
3. If rollback itself reports a failure, recover from the named transaction
   directory before accepting traffic.
4. Do not clear a provider sanction automatically. Inspect `/poolz` and use the
   authenticated provider-scoped recovery only after confirming a false sanction.

If the rollback refuses because the daemons cannot be proven stopped, it leaves
binaries, configuration, state and databases untouched for operator recovery.
