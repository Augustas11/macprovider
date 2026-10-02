# Runbook: run the #1816 fake-Pearl VM acceptance (Lima, this Mac)

**Audience:** any agent session on Augustas's Mac that has to continue #1816 VM work. Read `docs/handoffs/1816-pool-scoped-models.md` first: it says where the work stands and which failures to chase. This file explains how to drive the VM.

**Rule for this campaign:** no further audit rounds. The VM run is the only gate that raises bugs. Merge requires two consecutive full passes with no FAIL, or each remaining failure filed with a repro in `docs/testing/1816-vm-acceptance-plan.md` (Findings).

## 0. What the VM is

| Thing | Value |
|---|---|
| Lima instance | `macprovider-1690`: x86_64 Ubuntu 26.04 under qemu, 4 CPU, 6 GiB, 30 GiB. Config is `test/e2e-1690/lima-macprovider-1690.yaml`. |
| Role | A Pearl-shaped "fake Pearl": real coordinator and gateway systemd units, nginx on 443 (forwarded to host `127.0.0.1:28443`), Postgres, the production SQLite layout, and the real Pearl updater. |
| Harness | `test/e2e-1816/`, which is new and lives on branch `feat/1816-pool-scoped-models`. It reuses `test/e2e-1690/` as a shared lib (fakeprov, loadgen, oracle, in-VM `lib*.sh`). |
| Plan and findings | `docs/testing/1816-vm-acceptance-plan.md` |
| Code under test | `E2E_NEW_REF` = the #1816 commit. The baseline is `E2E_OLD_REF` (default `origin/main`). |

**Hard boundaries:**
- Never use the Lima VMs `macprovider-1693` or `macprovider-540`; `env.sh` refuses them.
- Never touch Pearl, GitHub (from inside the VM), or the Mac Studio's live provider.
- Every key is generated inside the VM and never printed.
- The Mac host only runs `limactl`, `git archive` and file copies.

## 1. Before you start

```bash
cd /Users/augstar/macprovider-1816-pool-models        # campaign worktree; create it if missing:
#   git -C /Users/augstar/macprovider-poc worktree add ../macprovider-1816-pool-models feat/1816-pool-scoped-models
git status -sb                                          # must be clean: the VM ships COMMITTED trees only (git archive)
git log --oneline -1                                    # this is your E2E_NEW_REF
limactl list | grep macprovider-1690                    # Stopped or Running
```

- **Is the VM in use?** If it is Running, check whether another session's run is active before doing anything:
  ```bash
  limactl shell macprovider-1690 -- sudo systemctl is-active e2e-1816-passes.service   # "active" = a run is in progress; don't start another
  ```
- **The VM doesn't exist:** create it with `bash test/e2e-1690/00-setup-vm.sh`. It downloads the pinned Ubuntu image and needs `limactl` and Homebrew `qemu`.
- **Uncommitted changes don't reach the VM.** `01-sources.sh` uses `git archive` on the ref. Commit first, even as a WIP commit on the branch.

## 2. Run the full acceptance (two passes)

```bash
cd /Users/augstar/macprovider-1816-pool-models
E2E_NEW_REF=$(git rev-parse HEAD) bash test/e2e-1816/run-all.sh 2
```

What happens:
1. `00-setup-vm.sh` starts the VM (up to 30 min under qemu) and installs packages.
2. `01-sources.sh` puts old and new trees in the VM as `/root/e2e/wt-old` (tag `v1.8.210`) and `/root/e2e/wt-new` (tag `v1.8.211`). These are scratch tags that are never pushed.
3. `02-push-harness.sh` copies the harness to `/root/e2e/h` (shared) and `/root/e2e/h16` (#1816).
4. It starts the in-VM driver **detached** as systemd unit `e2e-1816-passes`, logging to `/root/e2e/run-passes-1816.out`.
5. It waits, then copies evidence to `$E2E_WORK` (default `$TMPDIR/e2e-1816-work`) and prints a summary.

**Duration:** about 4 h 10 min for two passes, including the in-VM Go build. Each pass is B1, B2, S1 to S6, from a fresh bootstrap.

**The 2-hour tool limit.** A backgrounded Bash call in Claude Code is killed after at most 2 h. `run-all.sh` may die mid-wait, but **the in-VM run keeps going**, because it is a systemd unit and so survives the host process, network drops and session ends. Don't restart it. Poll it instead (section 4) and collect evidence yourself (section 5).

A recommended pattern for agents:
1. Launch `run-all.sh` in the background with the maximum timeout.
2. If it is killed, run a fresh poll loop of at most 55 iterations with 60 s sleeps, also in the background, until the unit is inactive.
3. Then collect.

## 3. Run a subset or one scenario

The scenarios depend on each other in chain order: B1 and B2 bootstrap fresh state, S2 leaves the new coordinator and gateway pair in place, S3 creates the pools that S4, S5 and S6 use. To iterate on one scenario, always include its prerequisites:

```bash
E2E_NEW_REF=$(git rev-parse HEAD) bash test/e2e-1816/run-all.sh 1 "B1 B2 S1 S2 S3"         # pool traffic
E2E_NEW_REF=$(git rev-parse HEAD) bash test/e2e-1816/run-all.sh 1 "B1 B2 S1 S2 S3 S5"      # rotation / revocation
E2E_NEW_REF=$(git rev-parse HEAD) bash test/e2e-1816/run-all.sh 1 "B1 B2 S1 S2 S3 S4 S5 S6" # one full pass
```

| Step | Script (in VM) | What it covers |
|---|---|---|
| B1 | `h/vm/20-bootstrap.sh` | Fresh old/old host (shared #1690 bootstrap) |
| B2 | `h16/vm/21-bootstrap-1816.sh` | Rest of the Pearl-shaped state: provider tokens for pool members and the catalog canary, the Pearl nginx vhost without the `/v1/catalog-artifacts` blocks, updater prerequisites, and a fake Better Stack |
| S1 | `h/vm/s1-baseline.sh` | Old coordinator and gateway, catalog traffic: the baseline shape |
| S2 | `h16/vm/s2-updater.sh` | Real Pearl updater rollout old to new, plus the artifact-feed catalog release, nginx feed, canary, rollback rehearsal and order tests |
| S3 | `h16/vm/s3-pool-models.sh` | Trusted pools on; v2 manifest with `pool_model_entries/v1`; GGUF (llama.cpp) and native MLX fake members; paid traffic of all four kinds; entry-price oracle |
| S4 | `h16/vm/s4-refusals.sh` | Global, other-pool, out-of-bounds, overlap, blocked artifact, unset bounds, runtime pairing |
| S5 | `h16/vm/s5-rotation.sh` | Rotation under load, entry removal, member and attestation revocation, future-dated cores, SIGHUP of bounds and owner accounts, policy-terms delegation |
| S6 | `h16/vm/s6-rollback.sh` | The full runbook rollback with pool-model cores present |

**Run in-VM steps directly**, without re-shipping sources, when only the harness changed and you already ran `02-push-harness.sh`:
```bash
limactl shell macprovider-1690 -- sudo bash -c 'cd /root/e2e && systemd-run --unit=e2e-1816-passes --collect -E HOME=/root -p WorkingDirectory=/root/e2e bash -c "bash h16/vm/run-passes.sh 1 \"B1 B2 S1 S2 S3\" >/root/e2e/run-passes-1816.out 2>&1"'
```
- `run-passes.sh [passes] [steps] [first-pass-id]`.
- `E2E_KEEP_EVIDENCE=1` keeps earlier results instead of truncating `results.jsonl`.
- `DRAIN_MAX` (default 660 s) bounds the per-run settlement drain.

## 4. Watch a run

```bash
limactl shell macprovider-1690 -- sudo systemctl is-active e2e-1816-passes.service
limactl shell macprovider-1690 -- sudo tail -20 /root/e2e/run-passes-1816.out
limactl shell macprovider-1690 -- sudo bash -c 'wc -l < /root/e2e/evidence/results.jsonl; python3 -c "
import json,collections; rs=[json.loads(l) for l in open(\"/root/e2e/evidence/results.jsonl\") if l.strip()]
print(collections.Counter(r[\"result\"] for r in rs)); [print(r[\"result\"],r[\"scenario\"]) for r in rs if r[\"result\"] in (\"FAIL\",\"GAP\",\"BUG\")]"'
```

The driver writes `ALL-PASSES-DONE` as the last line of `run-passes-1816.out` when it finishes. `RUN-PASSES-ABORTED` means the build or bootstrap failed.

## 5. Collect evidence and summarize

```bash
D=/Users/augstar/macprovider-1816-pool-models/.omc/e2e-1816/vm-$(git -C /Users/augstar/macprovider-1816-pool-models rev-parse --short HEAD)
mkdir -p "$D"
limactl shell macprovider-1690 -- sudo cat /root/e2e/evidence/results.jsonl > "$D/results.jsonl"
limactl shell macprovider-1690 -- sudo tar -C /root/e2e -czf - evidence logs > "$D/evidence.tgz"
python3 - "$D/results.jsonl" <<'PY'
import json,sys,collections
rs=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(len(rs), collections.Counter(r["result"] for r in rs))
for r in rs:
    if r["result"] in ("FAIL","GAP","BUG"): print(r["result"], r["scenario"], r.get("detail","")[:240])
PY
```

- `.omc/` is gitignored and survives reboots. `$TMPDIR` does not survive reliably, so don't leave the only copy of the evidence there.
- Earlier runs are kept under `.omc/e2e-1816/vm-1832627e7/` in the campaign worktree.

Each result row has `scenario`, `result` (PASS, FAIL, INFO, GAP or BUG), `detail` and `ts`. Oracle details (I1 to I5, EXPECT, P0) are explained in the plan's Oracle section:
- **I3:** buyer debit must equal provider payable.
- **EXPECT:** the per-kind outcome a scenario expects.
- **P0:** the case precondition wasn't met (for example, "never in flight"). That usually means a harness problem, not a product one.

## 6. Debug inside the VM

```bash
limactl shell macprovider-1690                     # then: sudo -i
```

| What | Where |
|---|---|
| Trees under test | `/root/e2e/wt-old`, `/root/e2e/wt-new` |
| Harness copies | `/root/e2e/h` (shared #1690), `/root/e2e/h16` (#1816) |
| Driver log | `/root/e2e/run-passes-1816.out` |
| Results and evidence | `/root/e2e/evidence/` (`results.jsonl`, per-run `p<pass><chain>*` dirs), `/root/e2e/logs/` |
| Pools, keys and manifests | `/root/e2e/pools16/`, `/root/e2e/keys` (never print) |
| Live services | `systemctl status macprovider-coordinator macprovider-gateway nginx`, `journalctl -u macprovider-coordinator --since -30min` |
| Coordinator DB | `sqlite3 -readonly /var/lib/macprovider/request-log.sqlite`. On this Pearl-shaped host the coordinator store and the billing ledger share it (`h/vm/lib.sh` `CDB`). |
| Gateway DB | `sqlite3 -readonly /var/lib/macprovider/gateway.db` (`quota_reservations`, `usage_events`) |
| Buyer entry | `https://api.malibu.tech` inside the VM (pinned in `/etc/hosts`), or `https://127.0.0.1:28443` from the Mac |

To reproduce a single failing case by hand: run the chain up to just before it (section 3), then run the scenario script's relevant block from `/root/e2e/h16/vm/sN-*.sh` interactively. The oracle is `python3 /root/e2e/h16/tools/pool-oracle.py` (pool cases) or `/root/e2e/h/tools/oracle.py` (catalog cases).

## 7. The fix loop

1. Reproduce the bug in a Go test (unit or `test/integration`) on the branch. Code goes to an Opus executor; Codex is not used for code.
2. Commit the fix on the branch (`feat/1816-pool-scoped-models` or a lane branch merged into it).
3. Re-run the narrowest chain subset that shows it (section 3), then the full two-pass run (section 2) at the final HEAD.
4. Record what's left in `docs/testing/1816-vm-acceptance-plan.md` Findings and update the handoff.
5. Post the run summary on PR #1830 (`gh pr comment 1830 --body-file ...`).

## 8. Known traps

- **Guest kernel panic at boot.** An `int3` Oops in `trace_syscall_exit`, from qemu TCG x86 emulation, has been seen once. `run-all.sh` then fails after 30 min with "did not receive an event with the running status". Fix: `limactl stop -f macprovider-1690 && limactl start macprovider-1690 --timeout 20m`, check `limactl shell macprovider-1690 -- uptime`, then rerun. It is not disk corruption (fsck passes).
- **A power or network outage mid-run.** The in-VM run continues if the VM survived. Poll the unit (section 4). If the VM died, restart it and rerun from scratch.
- **The updater catalog verifier timeout under qemu.** The real verifier takes about 36 s against a 30 s budget. The harness replays its output only for byte-identical inputs (plan deviation D7). Don't "fix" this by raising production timeouts.
- **The nginx `/v1/catalog-artifacts` step must run before the updater apply,** exactly as the production runbook says. S2 does this.
- **Deploy order:** pool-model `route_snapshot_v2` needs the new gateway before the new coordinator. S2 and S3 test both orders on purpose. An old gateway is now *refused* for pool-model routes (`pool_model_requires_gateway_upgrade`), so an S3 coordinator-first case that expects "settled" is stale.
- **The host load affects Swift perf tests.** Don't run local `swift test` perf suites while the VM is busy; `ReceiptPerfTests` p95 fails under load.
- **`Package.resolved`:** local `swift build` or `make test-dist` prunes it. Run `git checkout origin/main -- phase3-binary/Package.resolved` before any commit.
- **The secret-preflight hook** blocks commits that touch `phase4-coordinator/cmd/coordinator/main.go` or `dist/coordinator.yaml.example`, and also when untracked raw audit transcripts are present. Keep raw `log_*.txt` transcripts out of the worktree; the operator commits `main.go` with `SKIP_MACPROVIDER_SECRET_PREFLIGHT=1`.
- **Studio time** (the real-engine pass after the VM is green): coordinate with the MTP session (`macprovider-poc-20`) before using the Mac Studio, and never touch its `:8080` provider.

## 9. Stop and clean up

```bash
limactl shell macprovider-1690 -- sudo systemctl is-active e2e-1816-passes.service   # must be inactive
limactl stop macprovider-1690
```

Leave the VM defined: deleting it costs a full re-provision. Disk use is about 8 GB under `~/.lima/macprovider-1690`.
