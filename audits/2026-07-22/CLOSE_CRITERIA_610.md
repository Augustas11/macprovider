# Close criteria — Issue #610 (first-hop recovery)

**Issue:** https://github.com/Augustas11/macprovider/issues/610  
**Parent umbrella:** https://github.com/Augustas11/macprovider/issues/585 (G3 physical acceptance)  
**As of:** 2026-07-22  
**Issue state:** **OPEN** — merged Partial + private physical J1 PASS does **not** close #610.

This document is the authoritative close checklist for #610. It supersedes stale
“physical acceptance still open” wording in older runbook sections where they
conflict.

---

## What is done

### Contract and code (merged on `main`)

| Deliverable | PR / commit | Notes |
|---|---|---|
| SPEC-020 recovery contract (`SPEC-020-R001`–`R003`) | [#630](https://github.com/Augustas11/macprovider/pull/630) → `50bbec6a` | Coordinator-independent signed discovery authority; local commit vs network readiness split |
| Production first-hop bridge (`first_hop_bridge_ids`, `update_bridge` admission) | [#673](https://github.com/Augustas11/macprovider/pull/673) → `603da99d` | Server bridge public 1.8.48 can accept without weakening client signature/downgrade checks |
| PATH regular-file repair before set admission | [#678](https://github.com/Augustas11/macprovider/pull/678) → `7a44d277` | Fixes stale `~/.local/bin/macprovider-cli` regular-file copy vs coherent payload |
| Signed discovery / transactional updater cluster | [#631](https://github.com/Augustas11/macprovider/pull/631) and related Partials | Post-hop disconnected/rejected recovery path on CLI ≥1.8.49 |

Automated tests for connected, disconnected, rejected-old-version, opt-out, rollback,
and Malibu/CLI version-mismatch scenarios are on `main` as part of the above Partials.
They satisfy the **test** acceptance bullet but do not substitute for remaining
production and physical gates below.

### Physical evidence (private acceptance only)

| Journey | Result | Candidate | Evidence |
|---|---|---|---|
| J1 Shape A two-step first-hop (stranded public 1.8.48 PATH regular-file → exact set + buyer HTTP 200) | **PASS** | `Augustas11/macprovider:v1.8.58@8c4c57d87a2c59d7f7dd93556e05e3204ee4b093` | Issue comment [2026-07-22 Shape A PASS](https://github.com/Augustas11/macprovider/issues/610#issuecomment-5043211212); operator cache `/Users/augstar/Library/Caches/macprovider/physical-reproof/2026-07-22-j1-j4-v1.8.58-071839Z` |
| J1 on v1.8.57 (pre-#678) | **FAIL** (buyer OK, PATH postcondition failed) | `v1.8.57@ea9093e4` | Issue comment [2026-07-21 J1 FAIL](https://github.com/Augustas11/macprovider/issues/610#issuecomment-5039054526) |
| Earlier pre-fix bootstrap boundary | **BLOCKED** | various | Issue thread through [2026-07-20](https://github.com/Augustas11/macprovider/issues/610#issuecomment-5021028673) |

Key Shape A PASS properties (2026-07-22 UTC):

- Baseline reproduced the bug class: PATH CLI 1.8.48 regular file, payload on v1.8.57.
- Canonical-payload seed (permitted Shape A step) activated exact v1.8.58.
- Post-#678 startup repaired PATH to a symlink; PATH and payload SHA-256 match.
- Ordinary PATH `macprovider-cli update` reached the repaired binary without
  `invalid_current_or_target_set`.
- One launchd provider, connected, `buyer_serving`; demo chat HTTP 200.
- Isolated Pearl acceptance overlay bridged only exact public v1.8.48; production
  Pearl was restored byte-for-byte after the drill.

**Not done:** no public `v1.8.58` tag/release; Pearl production advertise remains
~**1.8.49**. Private candidate proof ≠ production release.

---

## Explicit non-closure rule

> **Merged Partial on `main` + private physical J1 PASS ≠ closed #610.**

Closure requires the remaining gates in the next section on **production-supported**
artifacts and journeys, not acceptance-coordinator overlays alone.

---

## Remaining close gates

### 1. Public release + Pearl advertise (required — not waived)

| Gate | Current state | Close requirement |
|---|---|---|
| Public GitHub Release / tag containing #673 + #678 Partial | Absent (`v1.8.58` private only) | Ship reviewed public release whose artifact index binds the merged recovery Partial |
| Pearl `coordinator_advertised_version.latest_binary_version` (and aligned `target_id`) | ~**1.8.49** on live Pearl | Promote Pearl to advertise/install the same public recovery release |
| Provider cohort on public pre-fix 1.8.48 | Unknown production count | Recovery journey must work for real public installs without alternate binary paths or launchctl surgery |

Rationale: operators and stranded public 1.8.48 hosts cannot consume private
acceptance candidates. Until public release and Pearl advertise align, the issue
contract (“normal recovery flow is `macprovider-cli update`”) is not production-true.

### 2. Production first-hop bridge enablement (required if 1.8.48 cohort remains)

| Gate | Register id | Current state |
|---|---|---|
| Pearl `first_hop_bridge_ids` for exact public v1.8.48 set | `exc-v1848-first-hop-update-bridge` | **planned**, not live on Pearl |

Close requirement (when cohort non-empty):

1. Enable reviewed Pearl overlay per [`ops/runbooks/entry-610-first-hop-recovery.md`](../../ops/runbooks/entry-610-first-hop-recovery.md).
2. Prove ordinary PATH `macprovider-cli update` on a **production-reachable** Pearl
   (not acceptance overlay only) completes the hop.
3. Remove bridge id after cohort empties; validate per exception
   `post_removal_validation`.

Fallback for disconnected hosts remains signed `install.sh` upgrade-in-place
(documented in the runbook). Bridge enablement and public release are complementary,
not substitutes.

### 3. Unpaid physical acceptance criteria (still required unless explicitly waived here)

Issue #610 lists nine acceptance bullets. Status as of 2026-07-22:

| AC (issue body) | Status | Notes |
|---|---|---|
| Disconnected manual `macprovider-cli update` without admission state | **Unpaid (physical)** | Automated tests on `main`; no dedicated physical drill logged after J1 focus |
| Rejected-old-version deadlock broken via update | **Partially paid** | Shape A PASS via isolated first-hop bridge; full rejected-version **matrix** not exhaustively rerun |
| Default autoupdate without accepted session | **Unpaid (physical)** | Skipped on v1.8.57 J1 (single Mac); not in v1.8.58 Shape A scope |
| Opt-out blocks auto but not manual update | **Unpaid (physical)** | Skipped on v1.8.57 J1 |
| Invalid/downgrade/revoked releases fail closed | **Paid (automated)** | Covered by merged updater tests; no separate physical gate |
| Rollback restores previous complete set on activation/health failure | **Unpaid (physical)** | Skipped on v1.8.57 J1; requires rollback snapshot discipline |
| Coordinator unavailability reported separately from integrity failure | **Paid (code)** | SPEC-020-R003 / merged implementation |
| Test matrix (connected, disconnected, rejected, opt-out, rollback, Malibu mismatch) | **Paid (automated)** | CI on `main`; does not waive physical rows above |
| User docs: `macprovider-cli update` recovery flow | **Paid (docs)** | [`README.md`](../../README.md), [`ops/runbooks/entry-610-first-hop-recovery.md`](../../ops/runbooks/entry-610-first-hop-recovery.md) |

**Waived:** none of the unpaid physical rows are waived by policy. They were
**deferred** on the single acceptance Mac during v1.8.57 J1 and not replayed in the
v1.8.58 Shape A re-proof (which targeted PATH + first-hop only).

**Minimum to close #610:**

1. Gates **1** and **2** (public release + Pearl + production bridge if needed).
2. Either physical replay of deferred ACs (disconnected-only autoupdate, opt-out,
   rollback) **or** a new decision entry documenting intentional scope reduction
   with operator sign-off — **not** assumed here.

---

## Relationship to parent #585

| Issue | Role | Close dependency |
|---|---|---|
| [#585](https://github.com/Augustas11/macprovider/issues/585) | G3 / physical-acceptance **umbrella** for Option 2 lifecycle + updater cluster | Stays OPEN until Gate G3 (both Macs, soak, child proofs) completes |
| [#610](https://github.com/Augustas11/macprovider/issues/610) | Focused child: disconnected/rejected **update/recovery** contract | Closes independently when **this document’s** gates pass; does not close #585 alone |

#610 must not close because one Mac was manually recovered or because private
acceptance passed on an isolated coordinator. #585 must not close while #610 (and
sibling child issues) remain OPEN.

Related sibling issues (remain OPEN despite merged Partials): #612, #616, #658.

---

## Close checklist (operator)

Use this ordered checklist when preparing to close #610:

- [ ] Public release published containing #673 + #678 Partial (artifact index + tag).
- [ ] Pearl promote: advertise/install matches that public release.
- [ ] If any production provider remains on public 1.8.48 set: enable
      `first_hop_bridge_ids` per runbook; prove production PATH update journey;
      plan bridge removal when cohort empty.
- [ ] Deferred physical ACs replayed **or** explicitly waived in `beta/DECISION_CRITERIA.md`.
- [ ] Issue body Status/Remaining updated; issue closed with links to public release,
      Pearl deploy evidence, and physical proof roots.
- [ ] Parent #585 Status updated to reflect #610 closed; #585 itself remains OPEN
      until its G3 matrix completes.

---

## References

- Runbook: [`ops/runbooks/entry-610-first-hop-recovery.md`](../../ops/runbooks/entry-610-first-hop-recovery.md)
- Exception: `exc-v1848-first-hop-update-bridge` in [`ops/exceptions/production-exceptions.json`](../../ops/exceptions/production-exceptions.json)
- Decision log: Entry 167 (signed release authority), Entry 176 (first-hop bridge), Entry 177 (#585 reframing)
- Spec: [`specs/SPEC-020-provider-autoupdate.md`](../../specs/SPEC-020-provider-autoupdate.md)
