# BUILD_SPEC — Drive the Compute-Integrity Receipt Companion to full (from stale PR #390)

You are a senior technical product manager and protocol/systems engineer on the
macprovider repo (P2P Mac-based LLM inference marketplace; coordinator on Pearl
VPS, buyer gateway). Your job in this session is to take an **abandoned,
mis-numbered draft SPEC** and drive it all the way to a merged, LOCK-ready,
audited, implemented normative spec + implementation.

Work autonomously to completion. Do not stop to ask "proceed or hold" — the
default is always to complete the full scope in priority order. If you hit a
genuine two-sided design fork, make the call, record it in the decision log, and
keep going.

---

## 0. What you are inheriting (self-contained context — do not assume prior chat)

**PR #390** (`gh pr view 390`) — OPEN, **draft**, branch
`feat/compute-integrity-receipt-companion`, base `main`, +1862/-0, last touched
2026-07-10. It adds four docs and **zero code**:

- `specs/SPEC-030-compute-integrity-receipt.md` (1225 lines, 17 FRs, 17
  acceptance criteria, 5 open questions) — the normative draft.
- `docs/research/compute-integrity-receipt-2026-07.md` (research memo).
- `specs/RESEARCH_COMPUTE_INTEGRITY_RECEIPT_PROMPT.md` (its research prompt).
- `.omc/logs/compute-integrity-receipt-open-questions-2026-07.md`.

**What it is:** an *additive compute-integrity drift gate for paid settlement*.
It extends the SPEC-022 settlement decision with a coordinator-owned
provider-vs-trusted-reference TV-distance drift state, `quarantined_compute_drift`.
When enforce mode is active, a covered paid request whose request-start
compute-integrity key is quarantined MUST NOT create buyer debit, provider
credit, earnings visibility, sweep inclusion, or payout readiness. It preserves
the SPEC-015 v0.4 receipt wire shape (no new receipt/usage fields). Wire
constant: `compute_integrity_probe_v1`.

### THE TWO BLOCKING DEFECTS THIS PR CARRIES

1. **Number collision.** The file is `SPEC-030-*` but **SPEC-030 on `main` is
   already `SPEC-030-losslessness-probe.md`** (a different spec — a *cooperative*
   implementation-health probe for speculative-decoding losslessness). Both
   cannot be 030. This PR predates and was never reconciled with the 2026-07-10
   corpus-hygiene renumber that moved losslessness into slot 030.

2. **Stale dependency numbering.** The draft's header says
   `Depends on: ... SPEC-029 v0.1-draft` and FR-6 says it *"inherits SPEC-029's
   distribution snapshot primitive."* But **SPEC-029 on `main` is now
   `SPEC-029-sweep-workload-class-stratification.md`** — it has no snapshot
   primitive. That primitive moved *into* `specs/SPEC-030-losslessness-probe.md`
   during the same renumber. So the draft's core dependency points at the wrong
   spec.

### Relationship to the landed losslessness probe (READ THIS SPEC FIRST)

`specs/SPEC-030-losslessness-probe.md` (on `main`) and this draft share the same
machinery — TV interval over compact next-token distributions, non-billable
overt WS canaries, `support_selection_v1`, K=64→256 retry, calibration,
warm-swap/target-generation handling, operator dashboard — but differ in two
ways:

- **Comparison arm:** losslessness compares a provider's *plain path vs its own
  spec path* (self-consistency). Compute-integrity compares
  *provider vs a coordinator-held trusted reference* (cross-node).
- **Consumer:** losslessness gates SPEC-028 spec-decode *eligibility*.
  Compute-integrity gates SPEC-022 *settlement / payout*.

The losslessness spec explicitly names this as future work: *"Stronger claims
require a later covert or independently verifiable probe spec."* This draft is
that stronger-claim direction (though it still disclaims hardware/binary/honesty
proof).

---

## 1. House rules — non-negotiable (this repo)

- **Fresh worktree, never the canonical checkout.** Do all work in a sibling
  worktree. Because the work lives on an existing PR branch, base the worktree on
  that branch and rebase it onto latest `origin/main` first:
  ```bash
  git fetch origin
  git worktree add ../macprovider-spec036 feat/compute-integrity-receipt-companion
  cd ../macprovider-spec036
  git rebase origin/main    # resolve conflicts; the spec/docs are additive so this should be clean
  ```
- **Git identity is automatic.** `git push origin <branch>` routes to the
  `Augustas11` account via a per-repo credential helper. Do not switch accounts
  to push. See project `CLAUDE.md`.
- **Money-path → PR, never direct push.** This spec gates settlement/payout, so
  every code change goes through a PR, not direct push. (Docs-only prompt/memo
  files may direct-push, but the SPEC + IMPL here are money-path.)
- **PR review/merge pattern:** author the PR as `Augustas11`; `antfleet-ops`
  approves; then squash-merge as `Augustas11`:
  ```bash
  gh auth switch -u antfleet-ops && gh pr review <n> --approve
  GH_TOKEN=$(gh auth token -u Augustas11) gh pr merge <n> --squash --delete-branch
  ```
  A merge-commit/rebase push dismisses a stale approval — re-approve after any
  post-approval push. The auto-mode classifier blocks review/merge in this
  money-path repo; the human operator casts approval/merge — surface the exact
  commands and wait for the user to run them if a step is classifier-blocked.
- **Codex-only audits, three lanes, every pass.** SPEC and IMPL audit loops use
  **codex** via `omc ask codex --prompt "$(cat <promptfile>)"`, NOT Claude
  subagents. Every audit pass is **three independent invocations**: `code`,
  `security`, `architect`. Bar = **0 CRITICAL, 0 HIGH, 0 MEDIUM**. LOW/INFO may
  ship documented in the PR body. Write each lane's prompt to a file under
  `audits/<YYYY-MM-DD>/` (NOT under `specs/` — a CI gate rejects stray prompt
  files there). Backtick-heavy prompts: write to a file and `cat` it; don't
  inline double-quoted strings (shell command substitution trap).
  - Once a lane returns 0/0/0, do not re-fire it unless a later fix touched its
    scope.
  - Anchored loops validate your own framing — if you exceed ~3–4 rounds without
    convergence, STOP and rethink the design rather than re-审. For a
    settlement/money-path spec, prefer an independent-framing review pass.
- **Governance gate.** Any spec-bearing PR must include a
  `SPEC-GOVERNANCE-DECLARATION` block (schema `spec-pr-governance-v1`) whose
  `specs` / `requirements` / `authority_domains` validate against
  `specs/CONFORMANCE.json` and `specs/AUTHORITY.json`. Editing the PR body does
  not re-trigger the `check` run — close+reopen the PR (or push a commit) to
  re-run it. Verify the *latest* run per context (`group_by(.name) |
  map(sort_by(.started)|last)`), not the first.
- **Decision log:** `beta/DECISION_CRITERIA.md` (table format; latest entries are
  180 — your new entry is **181**). The decision-log PR merges **last**, after
  the spec/impl land, so the entry reflects shipped state.
- **No GitHub issues from audit findings.** Fix them in-branch or carry LOW in
  the PR body.
- **Verify commit content before push:** `git show --stat HEAD` + grep the
  load-bearing lines.

---

## 2. Phase A — Renumber + dependency rewire + scope reconciliation

This is the unblock. Do it before touching acceptance-criteria fixtures.

### A1. Claim the next free spec number (verify at runtime — numbers drift)
`main` currently runs through **SPEC-035**, so the next free slot is **SPEC-036**.
Re-verify before committing:
```bash
ls specs/SPEC-*.md | grep -oE 'SPEC-[0-9]+' | sort -t- -k2 -n | tail -1
gh pr list --state open --json title | jq -r '.[].title' | grep -iE 'SPEC-03[6-9]'
git ls-remote --heads origin | grep -iE 'spec-03[6-9]'
```
Take the lowest free number ≥036. Rename:
- File `specs/SPEC-030-compute-integrity-receipt.md` →
  `specs/SPEC-036-compute-integrity-receipt.md`.
- Title, every internal `SPEC-030` self-reference, and the doc's status line.
- The research memo/prompt/log may keep their date-stamped names but update any
  in-body `SPEC-030` references to `SPEC-036`.
- Consider renaming the wire constant `compute_integrity_probe_v1` only if a
  version bump is warranted; renaming a wire constant is back-compat-bearing, and
  since nothing is shipped yet, prefer keeping `compute_integrity_probe_v1` and
  documenting that it is the SPEC-036 carrier. Record the choice.

### A2. Rewire the dependency
- Change `Depends on:` to reference `SPEC-030-losslessness-probe` (which now owns
  the distribution-snapshot primitive) instead of the old `SPEC-029`. Refresh the
  other pinned versions to current `main` state (SPEC-015, SPEC-022, SPEC-026 —
  check each spec's header line 3 for the current version of record; do not trust
  the stale pins in the draft).
- Rewrite **FR-6 ("Probe schema and SPEC-029 inheritance")** to inherit from the
  losslessness probe's snapshot/transport primitive by its correct number and
  section, or to explicitly define what it does not inherit.

### A3. Reconcile scope vs the losslessness probe (the real design decision)
Decide and **record in `beta/DECISION_CRITERIA.md` (Entry 181)**: does
compute-integrity **compose on** the losslessness probe's snapshot/transport/TV
machinery (recommended — reuse `support_selection_v1`, the TV interval math, the
validation rules, warm-swap/generation handling; the only genuinely new arm is
*provider-vs-trusted-reference* comparison + the settlement-gating consumer +
trusted-reference admission/quorum), or does it **duplicate** that machinery, or
should the settlement-gating consumer instead **fold into** SPEC-030 as a second
consumer of one shared probe?

Default recommendation to evaluate first: **compose**. Reuse the losslessness
probe's overt WS carrier, snapshot capture, and TV interval computation; add only
(a) the trusted-reference comparison arm, (b) trusted-reference admission +
quorum + independence rules (FR-5/FR-15 of the draft), and (c) the SPEC-022
settlement-gating consumer + `quarantined_compute_drift` state (FR-2/FR-3/FR-10).
If you choose compose, strip the draft's redundant re-specification of the shared
primitive and replace it with normative references. Record the decision, the
rejected alternatives, and the reason.

### A4. Governance + spec-index
Add/update `specs/CONFORMANCE.json` and `specs/AUTHORITY.json` entries for
SPEC-036 (new authority domain for compute-integrity settlement gating; declare
its requirements). Run the repo's spec-index/governance `check` locally if a
runner exists; ensure the SPEC-GOVERNANCE-DECLARATION you'll attach to the PR
validates.

---

## 3. Phase B — Spec to LOCK-ready, then SPEC audit loop

1. Resolve the **5 open questions** (§8 of the draft): enforce mode
   (trusted-reference-only vs mandatory hybrid), initial threshold floors
   `0.015/0.030/0.060/0.120`, new-provider gate window, warn-only→enforce
   calibration timeline, and consensus-telemetry funding. Make defensible v0.1
   calls; where a call needs maintainer sign-off, state the recommended default
   and mark it "maintainer-approval-required at LOCK."
2. Confirm all **17 acceptance criteria** (§7) are fully specified and consistent
   with the composed design. Add any that the renumber/reconcile changed.
3. Ensure the receipt/usage-invariant criteria (no new SPEC-015 v0.4 fields) and
   the settlement-outcome mapping (`outcome=quarantined`,
   `reason=compute_drift_quarantined`, never `zero_settled`) stay intact.
4. **SPEC audit loop:** write three codex lane prompts under
   `audits/<today>/` (code, security, architect) framed as a proof-review of the
   spec's correctness/coherence/threat-model/settlement-safety. Run each via
   `omc ask codex`. Fix → re-audit until **0 C/H/M** on all three. Put findings +
   convergence narrative in `specs/SPEC-036-rN-audit.md` files (skip a dedicated
   file for LOW-only rounds; fold those into the PR body).

Open the **SPEC PR** (spec + research memo/prompt/log + governance manifests +
declaration block). Author as `Augustas11`; drive it green through the `check`
gate; get `antfleet-ops` approval; merge as `Augustas11`. Then in the worktree:
`git checkout main && git fetch origin && git reset --hard origin/main`.

> Bundling note: incremental SPEC + its IMPL normally bundle in one PR. This is a
> net-new-ish, money-path, large spec with a big IMPL; prefer **SPEC PR first,
> then IMPL PR(s)** so the audit surfaces stay reviewable. Use judgment.

---

## 4. Phase C — Implementation, then BUILD audit loop

Implement the coordinator-side compute-integrity gate. Map each FR to code:

- Compute-integrity canary state store keyed by
  `(provider, model, target_model_hash, tokenizer_identity, sampler_stage,
  target_generation, sampling_profile, corpus_version, threshold_version)`,
  stored separately from echo-canary and losslessness state.
- Trusted-reference admission (signed catalog-hash match, tokenizer/sampler-stage
  match, runtime-build provenance or golden-fixture digest, freshness TTL,
  refresh triggers) + reference quorum/independence and
  `blocked:reference_missing` / `blocked:reference_fault`.
- Probe issuance/result over the composed carrier; provider-vs-reference TV
  interval; K=64→256 retry predicates; high-tail inconclusive.
- Window state machine (`quarantine_candidate_count`, no reset on intervening
  passes, 5-pass clear, abusive-inconclusive → `blocked`, circuit-breaker hold,
  `blocked:manual_review_required`).
- **Settlement wiring:** request-start capture of the covered key; SPEC-022
  outcome mapping to `quarantined` / `compute_drift_quarantined`;
  circuit-breaker `compute_integrity_circuit_breaker_hold` making captured rows
  non-payable; **no** new SPEC-015 v0.4 receipt/usage fields.
- SPEC-026 onboarding gate (warn-only vs enforce), warm-swap/generation expiry,
  audit logging/export (recomputable TV from exported compact evidence),
  disclosure surfaces, operator controls (dual approval, enforce↔warn,
  fail-closed).

Then land the **17 acceptance-criteria fixtures/tests** (§7). These are the
concrete completion bar — each criterion is a test that must exist and pass.

Build + test the affected modules (`phase4-coordinator`, and
`phase5-gateway`/settlement if touched). Run `go build ./... && go vet ./... &&
go test ./...` (and any Swift provider-side hook design/tests) green before
audit.

**BUILD audit loop:** fresh three-lane codex audit (code, security, architect)
on the IMPL diff, framed on settlement-safety, replay/nonce/expiry, fail-closed
behavior, and no-money-path-regression. Fix → re-audit to **0 C/H/M**. If a HIGH
lands on a line that predates this diff, run an attribution lane (NEW-to-diff vs
pre-existing baseline); pre-existing-not-worsened ships documented.

Open the **IMPL PR** (governance declaration included since it touches spec-bound
behavior). Green CI → `antfleet-ops` approve → `Augustas11` squash-merge. Reset
local main to origin after merge.

---

## 5. Phase D — Decision log + close-out

- Land `beta/DECISION_CRITERIA.md` **Entry 181** (the reconciliation + renumber +
  enforce-mode decision) in its **own PR, merged LAST**, so it reflects shipped
  state. Include: what was decided (compose vs duplicate vs fold, renumber to
  036, enforce-mode default, threshold floors), why, rejected alternatives, and
  owner.
- Ensure PR #390's branch is either the vehicle you drove (renamed content) or is
  closed with a pointer to the SPEC-036 PR, so no stale "SPEC-030" draft lingers.
- Final report to the user: SPEC-036 merged (link), IMPL merged (link), audit
  convergence per lane, decision entry, and any carried LOW/maintainer-approval
  residuals. No open loops.

---

## 6. Definition of done

- [ ] Spec renamed to SPEC-036, no `SPEC-030` collision, dependency rewired to
      the losslessness-probe primitive, versions refreshed.
- [ ] Scope reconciliation decided + recorded (Entry 181).
- [ ] 5 open questions resolved; 17 acceptance criteria fully specified.
- [ ] SPEC audit 0 C/H/M (3 lanes); SPEC PR merged via governance gate.
- [ ] IMPL complete: coordinator state + trusted-reference + probe + settlement
      wiring + onboarding/warm-swap/audit/operator controls.
- [ ] All 17 acceptance-criteria fixtures exist and pass; modules build/vet/test
      green.
- [ ] BUILD audit 0 C/H/M (3 lanes); IMPL PR merged.
- [ ] Decision-log Entry 181 merged last.
- [ ] No new SPEC-015 v0.4 receipt/usage fields; SPEC-022 outcome enum unchanged
      in v0.1.
- [ ] Worktree/branches cleaned; user briefed; no open loops.
