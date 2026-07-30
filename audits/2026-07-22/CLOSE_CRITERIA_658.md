# Close criteria — issue #658 (signed release discovery × immutable GitHub releases)

Issue: [Augustas11/macprovider#658](https://github.com/Augustas11/macprovider/issues/658)  
Parent umbrella: [#585](https://github.com/Augustas11/macprovider/issues/585) (G3 / physical acceptance)  
Normative contract: `specs/SPEC-020-provider-autoupdate.md` v0.1.11  
Decision record: `beta/DECISION_CRITERIA.md` Entry 176  
Status as of **2026-07-22**: **OPEN** — Partial code on `main`; physical public journey unpaid

This document is the authoritative close checklist for #658. It separates **done**
Partial delivery from the **remaining close gates**. Merged workflow/tests and a
private physical matrix do **not** close #658.

> **Advertise/release reconcile — 2026-07-24.** The snapshot below (public stable
> `v1.8.56`; "public `v1.8.57` absent") predates the promote. Since then, **public
> `v1.8.60` shipped (2026-07-23)** — tag commit `530e2479`, immutable, latest — and Pearl
> advertises `v1.8.60`. This makes **Gate 1** (public immutable discovery on production
> vNext) and **Gate 3** (physical public journey) **runnable** — they were previously
> blocked on private-only candidates — but **neither is paid yet**: the anonymous
> discovery proof bound to `v1.8.60` and the physical public journey (installed v1.8.55
> → public v1.8.60 + buyer 200) are still owed. **Gate 2** (renew-before-expiry) is being
> exercised: a renewal of the current head `release-discovery-v1-1966299389624321`
> (expires `2026-07-24T12:09:18Z`) was dispatched 2026-07-24 (run pending
> `production-release` approval). Evidence on
> [#585](https://github.com/Augustas11/macprovider/issues/585#issuecomment-5067431589)
> and [#658](https://github.com/Augustas11/macprovider/issues/658#issuecomment-5067432118).

---

## Explicit non-closure rule

> **Merged Partial #674 on `main` + private physical J2 PASS ≠ closed #658.**

Closure requires the remaining gates below on **public production vNext** discovery
and buyer-serving, not acceptance-coordinator overlays or private candidates alone.

---

## Snapshot (2026-07-22)

| Layer | State |
|-------|-------|
| Code on `main` | Partial [#674](https://github.com/Augustas11/macprovider/pull/674) merged 2026-07-21 |
| Public stable | **`v1.8.60`** (latest immutable numeric release, 2026-07-23; was `v1.8.56` at authoring) |
| Append-only transport | `release-discovery-v1-1954431381209089` (immutable prerelease) |
| Fixed v1.8.55 transport | `release-discovery` tag — permanently immutable, pinned to v1.8.55 |
| Private acceptance | `Augustas11/macprovider:v1.8.57@ea9093e406c7c85764d65e21d31c12ddcca45208` (physical drills only; **no public tag**) |
| Physical J2 | **PASS** on private v1.8.57 matrix (`1.8.55` → candidate via supported bridge, buyer HTTP 200) |
| Public / Pearl | Public `v1.8.60` shipped + Pearl advertises `1.8.60` (2026-07-24); **anonymous discovery proof bound to v1.8.60 + physical public journey still unpaid** |

---

## Done (Partial #674 — do not re-litigate)

These items are satisfied on `main` and are **not** reopeners for #658 closure:

| Deliverable | Evidence |
|-------------|----------|
| Append-only immutable transport publication in protected promotion | `.github/workflows/promote-acceptance-candidate.yml` publishes exactly one `release-discovery-v1-<sequence>` prerelease; refuses tag/asset reuse |
| Anonymous post-publication discovery proof (new + prior CLI) | `scripts/verify-anonymous-release-discovery.sh` in promotion workflow |
| v1.8.55 fixed-tag bridge proof at promotion time | `scripts/verify-v1855-discovery-bridge.sh` when `PREVIOUS_TAG=v1.8.55` |
| Protected recurring head renewal under immutability | `.github/workflows/renew-release-discovery-head.yml` — strictly greater sequence, one new immutable prerelease, never mutates `release-discovery` |
| Renewal fail-closed controls | `scripts/test-renew-release-discovery-head.sh` |
| SPEC/conformance/decision updates | SPEC-020 v0.1.11; Entry 176 |

**Important boundary:** Partial #674 proves the **anonymous CI bridge** and **renewable append-only transports**. It does **not** prove that a **physically installed public v1.8.55 provider** completes ordinary supported-bridge update to a **public** vNext through production discovery and buyer-serving.

---

## Remaining close gates

All three gates must pass on a **public production vNext** before #658 closes.

### Gate 1 — Public immutable discovery journey on production vNext

**Requirement:** After the next **public** stable promotion (not a private acceptance candidate), the full discovery stack must be live and anonymously verifiable on GitHub:

1. Public immutable numeric release `vX.Y.Z` exists and matches the signed acceptance bytes.
2. Exactly one new append-only transport `release-discovery-v1-<sequence>` is public, prerelease, and immutable.
3. Promotion workflow anonymous proofs pass for both the new CLI and the prior public CLI (v1.8.55 bridge path when applicable).
4. No mutation of the fixed `release-discovery` tag or its assets.

**Verified locally (repo controls, not production journey):**

```bash
bash scripts/test-release-discovery-head.sh
bash scripts/test-renew-release-discovery-head.sh
```

**Verified against live GitHub after each public promote (example for v1.8.56-era transport):**

```bash
scripts/verify-v1855-discovery-bridge.sh v1.8.56 <40-char-commit> release-discovery-v1-<sequence>
```

Replace `<40-char-commit>` and `<sequence>` with the promoted release values from the promotion workflow outputs.

**Status (2026-07-24):** Public vNext now **exists** (`v1.8.60`, immutable, latest), so this gate is **runnable** — but not yet paid: run the anonymous discovery proof bound to `v1.8.60` (`verify-v1855-discovery-bridge.sh v1.8.60 530e2479… release-discovery-v1-<sequence>`) and attach. Private physical J2 on `v1.8.57@ea9093e4` still does not substitute for this gate.

---

### Gate 2 — Renew-head-before-expiry ops

Signed discovery heads expire (`expires_at` ≤ 7 days after `issued_at`; renewal default validity 24h). Under immutable releases, freshness requires **append-only renewal**, not in-place upload.

**Operator procedure:**

1. Monitor the greatest public transport sequence and head `expires_at` (from `macprovider-release-discovery.json` on the latest `release-discovery-v1-*` release).
2. Before expiry, dispatch the protected workflow:

   ```bash
   gh workflow run renew-release-discovery-head.yml \
     --repo Augustas11/macprovider \
     -f validity_hours=24
   ```

3. Confirm the run publishes exactly one new `release-discovery-v1-<new-sequence>` immutable prerelease.
4. Confirm anonymous same-target discovery still resolves (renewal job runs `verify-anonymous-release-discovery.sh`).

**Fail-closed rules (must remain true):**

- Renewal MUST NOT call `gh release upload --clobber` on any existing transport.
- Renewal MUST NOT create or mutate the fixed `release-discovery` tag.
- New sequence MUST exceed the greatest existing public transport sequence.
- Client MUST fail closed on expired/mutable/malformed heads (no unsigned `latest` fallback).

**Not satisfied today:** No production ops runbook entry records a scheduled renew-before-expiry cadence tied to the live transport on Pearl/public releases. Dispatch renewal and document the recurring schedule before declaring discovery continuously operable in production.

---

### Gate 3 — Stop condition: physical public journey + buyer HTTP 200

This is the issue body acceptance criterion and Entry 176 closure line. It is **unpaid** until executed against a **public** vNext.

**Pass checklist (all required, on production-equivalent hardware):**

| Step | Pass criterion |
|------|----------------|
| Starting state | Physically installed **public v1.8.55** provider (ordinary install path, not a one-off dev tree) |
| Discovery authority | Supported bridge only for first hop: authenticated coordinator recommendation for exact signed numeric target **or** supported exact signed acceptance-candidate installer — **not** fabricated ordinary `update --check` success from v1.8.55 alone |
| Update | `macprovider-cli update` (or equivalent supported path) reaches exact signed **public** vNext without manual launchd surgery |
| Process model | Exactly **one** launchd-managed provider process throughout |
| Serving | Real buyer HTTP **200** after update (not merely local HTTP-ready) |
| Rollback posture | Supported rollback/recovery behavior unchanged (no regression vs SPEC-020 controls) |

**Explicit stop (issue remains OPEN if any occur):**

- Public promote declares success while anonymous discovery proof fails.
- Fixed `release-discovery` tag or assets are mutated, recreated, or deleted.
- Transport renewal skips monotonic sequence comparison or overwrites an existing transport.
- Physical proof uses only a **private** candidate when the close gate requires **public** vNext discovery on production releases.
- Buyer serving fails, multiple provider processes appear, or update requires undocumented manual repair.

**Private J2 reference (evidence, not closure):** Physical J2 **PASS** on private `v1.8.57@ea9093e406c7c85764d65e21d31c12ddcca45208` (`1.8.55` → candidate, buyer 200). Record minimized artifacts on #658 when posting; do not close from this alone.

---

## Ground-truth anchors (v1.8.55 incident)

| Item | Value |
|------|-------|
| v1.8.55 source/tag commit | `ce1158e8c53595150f61a34e55c7e52ac052d477` |
| Public release | https://github.com/Augustas11/macprovider/releases/tag/v1.8.55 |
| Fixed transport | https://github.com/Augustas11/macprovider/releases/tag/release-discovery |
| Root cause | Promotion published signed discovery assets inside `v1.8.55` but not the separate transport read by shipped v1.8.55 fixed-tag clients |
| Remediation pattern | Append-only `release-discovery-v1-*` immutable prereleases + protected renewal |

---

## Related artifacts

| Artifact | Role |
|----------|------|
| `.github/workflows/promote-acceptance-candidate.yml` | Publishes numeric release + one append-only transport + anonymous proofs |
| `.github/workflows/renew-release-discovery-head.yml` | Recurring signer for same-target head renewal |
| `scripts/verify-anonymous-release-discovery.sh` | Anonymous download + crypto binding proof |
| `scripts/verify-v1855-discovery-bridge.sh` | v1.8.55 fixed-tag bridge proof |
| `scripts/verify-release-discovery-transport.py` | Head signature, sequence, expiry, artifact-index binding |
| `specs/SPEC-020-provider-autoupdate.md` § R-1.2 / bridge / renewal | Normative requirements |

---

## Closure declaration template

When all gates pass, close #658 with a comment containing:

1. Public vNext tag + commit + promotion workflow run URL.
2. Published transport tag + sequence + head `expires_at`.
3. Anonymous proof command output (redacted if needed).
4. Physical journey: machine id (redacted), bridge path used, final CLI version, buyer 200 evidence, single-process confirmation.
5. Renewal ops: last renewal run URL and next scheduled dispatch before expiry.

Until then: **keep #658 OPEN**. Do not conflate Partial #674, private physical J2, or Pearl private candidate work with public production discovery closure.
