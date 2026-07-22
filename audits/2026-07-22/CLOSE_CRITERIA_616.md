# Close criteria — Issue #616 (signed compatibility-set convergence)

**Issue:** [#616 — P0: converge legacy upgrades to one complete signed compatibility set](https://github.com/Augustas11/macprovider/issues/616)  
**Parent:** [#585](https://github.com/Augustas11/macprovider/issues/585)  
**Date:** 2026-07-22  
**Status:** **OPEN** — merged Partials + one private physical proof ≠ closed

This document states what is **done**, the **exact remaining close gates**, and which
non-PATH acceptance criteria are still **required** versus **not yet paid**. It does
not authorize closing #616.

---

## Executive summary

| Layer | State (2026-07-22) |
|---|---|
| Code on `main` | **DONE** — [#672](https://github.com/Augustas11/macprovider/pull/672) (PATH symlink converge on activation) + [#678](https://github.com/Augustas11/macprovider/pull/678) (PATH regular-file repair + canonical set resolution) |
| Physical PATH strand (J4) | **PASS** — private candidate `Augustas11/macprovider:v1.8.58@8c4c57d87a2c59d7f7dd93556e05e3204ee4b093`; PATH regular-file 1.8.48 → symlink/payload/set converge; buyer HTTP 200 |
| Public release / tag | **NOT DONE** — no public tag containing #678; Pearl coordinator advertise still ~1.8.49 |
| Fleet cohort | **NOT DONE** — hosts on legacy PATH shapes remain until they hop |
| Broader whole-set ACs | **UNPAID** — see §Non-PATH acceptance criteria; not waived |

**Close rule:** #616 closes only when every row in §Remaining close gates is satisfied
and unpaid issue-body ACs have physical evidence or an explicit waiver recorded in
`beta/DECISION_CRITERIA.md`.

---

## What is done

### G1 — Implementation merged (PATH convergence strand)

Both Partials are on `main`:

| PR | Merged | Scope |
|---|---|---|
| [#672](https://github.com/Augustas11/macprovider/pull/672) | 2026-07-21 | After successful activation, converge `~/.local/bin/macprovider-cli` to a symlink of the canonical payload binary; fail closed if repair is unsafe |
| [#678](https://github.com/Augustas11/macprovider/pull/678) | 2026-07-22 | Repair PATH **regular-file** copies before set admission; resolve current set from canonical install when PATH lacks sibling `compatibility-set.json`; watchdog best-effort repair after older activators |

Automated coverage includes `AutoUpdateTests` (PATH regular-file, symlink idempotency,
canonical fallback, unsafe-bin fail-closed) and `watchdog_health_scope.test.sh`.

Related but **not** owned by #616: [#610](https://github.com/Augustas11/macprovider/issues/610) first-hop bridge,
[#631](https://github.com/Augustas11/macprovider/pull/631) signed discovery, [#612](https://github.com/Augustas11/macprovider/issues/612) autotune continuity.

### G2 — Physical PATH regular-file proof (J4 PASS)

Private acceptance candidate only — **not** a public release.

| Field | Value |
|---|---|
| Set ID | `Augustas11/macprovider:v1.8.58@8c4c57d87a2c59d7f7dd93556e05e3204ee4b093` |
| Proof shape | Shape A (two-step): restore failing PATH regular-file 1.8.48, canonical-payload hop seeds post-#678 binary, provider startup repairs PATH |
| Machine | `Augustas-Air.local` (MacBook Air Mac17,3; sponsor Air fixture) |
| Final state | PATH symlink → payload; both CLI 1.8.58 same hash; installed + Malibu `compatibility-set.json` byte-identical to signed candidate; one launchd PID; `buyer_serving`; buyer chat HTTP 200 |
| Evidence | Issue comment [2026-07-22](https://github.com/Augustas11/macprovider/issues/616#issuecomment-5043213952); cache `…/Library/Caches/macprovider/physical-reproof/2026-07-22-j1-j4-v1.8.58-071839Z` |

Prior J4 **FAIL** on v1.8.57 (pre-#678) and **BLOCKED** preflight are recorded on the
issue thread; they motivated #678 and the v1.8.58 candidate renewal.

### G3 — Issue reproduction (PATH/payload divergence)

The mixed PATH/payload/set topology from production ground truth (2026-07-16) and
[#610 acceptance](https://github.com/Augustas11/macprovider/issues/616#issuecomment-5021028442)
was reproduced and repaired in the J4 proof. That satisfies the **PATH strand** of
“reproduce mixed state” and “one supported update converges entrypoints.”

---

## Remaining close gates

All items below must pass before #616 closes.

### Gate R1 — Public release / tag containing the fix

| Requirement | Status |
|---|---|
| Signed public GitHub Release + tag whose provider CLI component includes merged commits through #678 (commit `7a44d277` lineage) | **Open** |
| Release ledger / compatibility-set ID published and discoverable via ordinary signed discovery | **Open** |
| Pearl production coordinator `latest_binary_version` / `target_id` promoted to that release (not private acceptance overlay only) | **Open** — advertise still ~1.8.49 at time of writing |

**Evidence to attach at close:** public tag name, compatibility-set ID, SHA-256 of
`macprovider-cli` and `compatibility-set.json`, coordinator health/advertise snapshot
after promote, link to release workflow run.

**Explicit non-gate:** temporary Pearl acceptance overlay used for private J4 proof
does not count; overlay was reverted per issue comment.

### Gate R2 — Fleet PATH-shape cohort emptied or converged

Legacy installs may still have:

- PATH **regular-file** copy with no sibling set (pre-#678 failure mode)
- PATH copy divergent from payload after partial self-update (pre-#672 failure mode)

| Requirement | Status |
|---|---|
| Every production provider has hopped through a release ≥ the public tag from R1 **or** documented operator repair with post-hop verification | **Open** |
| No authoritative PATH entrypoint reporting a version/hash/set ID that disagrees with payload + signed set | **Open** |
| Coordinator pool shows converged set IDs matching R1 target for the cohort (or explicit exception register entry with expiry) | **Open** |

First-hop recovery for stranded public 1.8.48 remains coordinated with [#610](https://github.com/Augustas11/macprovider/issues/610) runbook
(`ops/runbooks/entry-610-first-hop-recovery.md`); #616 closure assumes the cohort
can reach a #678-capable CLI, then PATH repair runs automatically.

### Gate R3 — Unpaid non-PATH acceptance criteria

Issue-body ACs not satisfied by J4 alone. **None are waived** as of 2026-07-22.

| AC (issue body) | J4 / code status | Close requirement |
|---|---|---|
| Obsolete `watchdog.sh` absent; macOS shows normal helper name | Not exercised in J4 | Physical proof from a fixture with legacy watchdog LaunchAgent args |
| Manifest, lifecycle, signed set, CLI, Malibu, artifact hashes all agree | Partial — PATH/payload/set/Malibu set file only | Full whole-set proof including `install_manifest.json`, lifecycle state, launchd plists, catalog digests |
| Deliberately mixed installs cannot report success | Code fail-closed paths merged; no full mixed-member physical matrix | Physical mixed fixture (e.g. 2026-07-16 ground truth: manifest v1.8.3, Malibu 1.8.39, CLI 1.8.40 claims) must fail closed or fully converge — not declare success while mixed |
| Interrupted convergence restores exact complete previous set | Not proven | Rollback/interruption matrix with byte-verified prior set restoration |
| Physical fixtures: main Mac **and** 8 GB Air from actual starting states | J4 on sponsor Air (32 GB M5); **8 GB Air fixture unpaid** | Distinct proof on the 8 GB Air hardware from its true starting state |
| Closure evidence: before/after manifests, plists, digests, buyer request, **and rollback** | J4 has before/after for PATH strand + buyer 200; **no rollback bundle** | Attach full evidence pack per AC; rollback case mandatory |

**Waiver policy:** narrowing scope requires a new `beta/DECISION_CRITERIA.md` entry
that names which ACs are deferred and why. Until then, treat all rows as **required**.

---

## Three-gate model (tracking)

| Gate | Meaning | 2026-07-22 |
|---|---|---|
| **G1** — PATH convergence code merged | #672 + #678 on `main`, tests green | **PASS** |
| **G2** — Private physical PATH proof | J4 regular-file strand on signed candidate ≥ #678 | **PASS** (v1.8.58@8c4c57d8) |
| **G3** — Production close | R1 public release + R2 fleet hop + R3 unpaid ACs | **OPEN** |

G2 does **not** imply G3. Private candidate proof explicitly does not close the issue.

---

## Recommended close sequence

1. **Publish** public release/tag containing #678 (R1).
2. **Promote** Pearl to that set ID; remove temporary acceptance overlay.
3. **Hop fleet** through ordinary `macprovider-cli update` or documented first-hop
   bridge (#610), verifying PATH/payload/set convergence per host (R2).
4. **Run whole-set fixtures** on main Mac and 8 GB Air: mixed-member baseline,
   watchdog legacy, interruption/rollback (R3).
5. **Attach evidence** to #616: public set ID, per-host before/after manifests,
   plists, digests, buyer HTTP proof, rollback proof.
6. **Close #616** only when G3 rows are green; keep #585 parent tracking until
   sibling issues (#610, #612, …) reach their own close criteria.

---

## References

- Issue: https://github.com/Augustas11/macprovider/issues/616
- Runbook (first-hop / PATH preflight): `ops/runbooks/entry-610-first-hop-recovery.md`
- SPEC authority split: `specs/SPEC-020-provider-autoupdate.md` (whole-set convergence owned by #616)
- Decision log: `beta/DECISION_CRITERIA.md` Entry 177 (#585 / private candidate framing)
