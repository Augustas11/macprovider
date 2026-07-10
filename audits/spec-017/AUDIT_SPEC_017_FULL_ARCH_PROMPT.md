# SPEC-017 v0.1.8 — Final whole-implementation ARCHITECTURE audit (adversarial)

You are the architecture lane on the final pre-merge adversarial
audit of the SPEC-017 v0.1.8 Network Stats API implementation.
This is the LAST audit pass before PR #173 ships to production.
Your job is to REFUTE the "ready to ship" claim. Default to
finding blockers. A green verdict only if you cannot.

## Scope

ALL of SPEC-017 v0.1.8 on branch `impl/spec-017-step-1` at HEAD
`9ef3d92` — Step 1 (Postgres schema + roles + DSNs) + Step 2
(rollup) + Step 3 (handlers + middleware + store) + Step 4
(4.A CLI + 4.B nginx + 4.C observability). 189 files changed,
30,456 insertions vs main.

Diff base for the full sweep:
`git diff --name-only $(git merge-base HEAD main)..HEAD`.

## Controlling contracts

- `specs/SPEC-017-network-stats-api.md` (v0.1.8 LOCKED).
- `specs/BUILD_SPEC_017_IMPL_PROMPT.md` (build prompt with the
  22 AC matrix + step decomposition).
- 22-AC sweep: `specs/SPEC-017-IMPL-STEP_4-22AC-sweep.md`.
- Whole-step convergence: `specs/SPEC-017-IMPL-STEP_4-convergence.md`.
- Per-sub-step convergence: `specs/SPEC-017-IMPL-STEP_4C-r5-convergence.md`
  (this also references the 4.A and 4.B lock audits).
- §6.6.2 disclosure sign-off lives in `OPS.md` §10.5.

## Adversarial posture

Set yourself the burden of FINDING reasons NOT to ship. Don't
treat the convergence record as gospel — it's a self-report. The
prior audit rounds were also self-reports from the same author.
Probe assumptions other rounds may have anchored on.

Categories to attack (suggested, not exhaustive):

A. **Cross-step interaction bugs.** Step 1's role grants + Step 2's
   rollup pool + Step 3's reader-only handler + Step 4.A's admin
   DSN — does any combination violate the principle of least
   privilege? E.g. can the partner-keys CLI accidentally write
   through a pool that bypasses an invariant? Does the rollup
   pool gain anything from the handler's projection logic?

B. **Step 4.B contract reconciliation.** The latest commit
   (9784ef5) chose `burst=59 nodelay` to satisfy AC-8 "60 succeed,
   61st 429s" while preserving SPEC §5.6 "60 req/min sustained,
   no burst absorption". The commit message argues these are
   compatible because sustained rate is unchanged. Is that
   reading correct? Look at SPEC §5.6 prose verbatim — does it
   forbid burst at the implementation level or only at the
   sustained-throughput level? Are there hostile reading paths
   that would consider `burst=59` a SPEC violation?

C. **Money-path drift.** SPEC-017 surfaces the exact-USD partner
   projection (§6.6.2). If a regression in this PR weakens the
   redaction story, the impact is regulatory. Trace every site
   that could leak the partner projection: rollup → handler →
   middleware → nginx cache → response logs → Prometheus
   metrics → structured log events → CLI partner-keys list /
   issue / revoke output. Each layer has explicit guards; does
   ANY combination create a bypass?

D. **Test surface honesty.** The 22-AC sweep claims 22/22 PASS.
   Sample 5 ACs at random; re-derive the assertion from the SPEC
   text and check the cited test actually proves what the SPEC
   asks. Look for "looks-like-PASS" tests that don't exercise
   the production code path the AC names.

E. **`/metrics` endpoint surface.** Step 4.C mounts
   `promhttp.HandlerFor(statsRegistry, ...)` on the provider
   port 8444 (loopback-only). The registry is coordinator-owned
   so only stats metrics land. Verify the registry isolation —
   could any other package's `prometheus.DefaultRegisterer`
   side-effect land metrics in the stats registry? Could any
   metric label set leak partner_keys.id with semantically
   meaningful content via a misuse path?

F. **Migration safety.** Step 1 introduces 3 schema migrations
   + Step 2 / Step 3 / Step 4 layer additional ones. Is the
   migration ordering correct on a stock checkout? Is the
   bootstrap (002) idempotent? Does any seed conflict with a
   user's existing data on a hot upgrade path?

G. **CHANGELOG honesty.** Does
   `docs/network-stats-api/CHANGELOG.md` v0.1.8 entry
   accurately describe the locked behavior, or does it
   undersell / oversell what shipped?

H. **OPS.md runbook executability.** The four §10 runbook
   entries each have an "If this fails" paragraph. Walk each
   from a fresh operator's perspective — would they actually
   succeed running these commands on a production Pearl host
   with the documented credentials? Are env vars, file paths,
   service names all consistent with the deploy scripts?

I. **§6.6.2 sign-off gate non-bypassability.** The convergence
   record says the sign-off is "wired and non-bypassable". Is
   that actually true? Could an operator with admin DSN access
   issue a partner key without recording the sign-off? If yes,
   that's a CRITICAL finding for the regulatory contract.

J. **Anything else.** A category above is a hint, not a
   limit. Find your own attack surface.

## Verdict format

Write your output to
`specs/SPEC-017-FINAL-arch-audit.md`. Required structure:

1. `## Verdict` — one of `REQUEST CHANGES`, `READY TO LOCK`.
2. `Blocking count: NC CRITICAL / NH HIGH / NM MEDIUM / NL LOW / N INFO`.
3. `## Required reading + commands run` — what you actually
   read and executed; cite exact `rg` / `grep` / `git` commands
   so this is reproducible.
4. `## Findings` with sections `### CRITICAL`, `### HIGH`,
   `### MEDIUM`, `### LOW`, `### INFO`. Each finding has:
   - Numbered title
   - Evidence (file paths + line numbers + exact phrases)
   - Risk (what production impact if this is real)
   - Fix direction (what would close it)
5. `## Category sweep` (A–J above) — PASS / FAIL per category,
   one sentence per.
6. `## Final recommendation` — one paragraph. If you found NO
   blockers, name 3 specific things you tried to refute that
   you could not, so the reader can see the adversarial work.

## Severity bar

- **CRITICAL**: production data loss, money-path bypass,
  security gate that doesn't gate, or §6.6.2 sign-off
  bypass-able by any path including operator error.
- **HIGH**: a SPEC AC silently fails, or a redaction layer
  has a real leak, or a CI gate misses regression class.
- **MEDIUM**: documentation drift that misleads operators,
  test coverage gap that lets a class of regression through,
  or a deferred SPEC-vs-impl tension that is materially
  unresolved.
- **LOW**: comment / doc polish that wouldn't change behavior.
- **INFO**: noteworthy but not actionable.

Bar to lock: 0 CRITICAL + 0 HIGH + 0 MEDIUM. Anything less is
`REQUEST CHANGES`.
