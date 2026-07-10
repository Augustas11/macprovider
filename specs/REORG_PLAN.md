# `specs/` reorganization plan

**Status:** proposed · **Owner:** @Augustas11 · **Companion:** `scripts/gen_spec_index.py` (index auto-gen, landed in this change)

## The problem (measured 2026-07-10)

`specs/` holds **1,571 markdown files**. Of those, only **24 are canonical specs**
(a `# SPEC-NNN — Title` first line + a `**Version:**` header). The rest is
supporting exhaust from the per-spec review process:

| category | count |
|---|--:|
| **canonical specs** (the normative surface) | **24** |
| round-N audit files (`*_audit.md`) | 1,309 |
| agent prompts (`*_PROMPT.md`, `ABSORB_*`) | 160 |
| impl/step/notes | 26 |
| fix/decision | 6 |
| other | 34 |

Consequences:
- The hand-maintained index drifted badly — it listed 13 specs and stale versions
  (SPEC-001 shown as v1.4 when the header says **1.6**; SPEC-003 v0.9.2 vs **0.10.1**).
  *(Fixed now: the index is generated from headers and CI-checked.)*
- Canonical specs are unfindable in a 1,571-file directory.
- Three naming schemes coexist: `SPEC-014-…`, `SPEC_015_…`, and work-item names
  like `125_TRUSTED_PROXIES_…`, `82_ITEM3_…`, `ARC_3_NESTED_QUERIES_…`.
- Data bug: `SPEC-012-source.md`'s title line reads `# SPEC-010 — …` (generator warns).
- Header gaps: SPEC **007, 021, 025, 026, 027** have no canonical doc with the
  standard header (generator prints them as `NOTE` gaps).

**This is an organization problem, not a governance problem.** The review rigor is
already excellent (independent architect/code/security + adversarial + product-design
audits per spec — more than most public IP processes have). It does not need AIP-style
governance; it needs the supporting artifacts out of the normative directory. See the
"Not in scope" section.

## Target structure

```
specs/
  README.md                     # AUTO-GENERATED index (do not hand-edit the table)
  TEMPLATE.md                   # copy this to start a new spec (header contract below)
  PROCESS.md                    # 1-page: how a spec is born, versioned, reviewed
  SPEC-001-phase3-binary.md     # canonical specs ONLY — one per number, kebab slug
  SPEC-002-coordinator.md
  ...
audits/
  spec-001/ … spec-029/         # round-N audit files move here, grouped by spec
audits/_prompts/                   # agent PROMPT/ABSORB files move here (disposable exhaust)
docs/notes/                     # impl/step notes that are worth keeping
```

**Header contract** (what makes a file canonical — enforced by the generator):
1. line 1: `# SPEC-NNN — <Title>` (em-dash separator)
2. a `**Version:** <x.y.z>` line within the first 15 lines
3. filename `SPEC-NNN-<lowercase-kebab-slug>.md`, exactly one per number

## Migration — phased, each phase independently shippable

**P0 — guardrails (this change).** `scripts/gen_spec_index.py` + `.github/workflows/spec-index.yml`.
The index can no longer drift. Do this first so the cleanup below is verifiable.

**P1 — evacuate audits (biggest win, lowest risk).** Move the 1,309 `*_audit.md`
into `audits/spec-<NNN>/`. Pure `git mv`, no content change. Suggested:
```sh
for f in specs/*_audit.md; do
  n=$(grep -oiE 'spec[-_]?0*[0-9]+' "$f" | head -1 | grep -oE '[0-9]+')
  [ -n "$n" ] && mkdir -p "audits/spec-$(printf %03d "$n")" && git mv "$f" "audits/spec-$(printf %03d "$n")/"
done
```
(Dry-run first; hand-place the handful that don't self-identify a spec number.)

**P2 — evacuate prompts.** `git mv specs/*_PROMPT.md specs/ABSORB_* audits/_prompts/`.
These are agent scaffolding, not spec content.

**P3 — normalize names.** Rename the non-conforming work-item docs
(`125_…`, `82_ITEM3_…`, `ARC_3_…`) to either a canonical `SPEC-NNN-slug.md` (if
they are in fact a spec) or move them under `docs/notes/`. Add a CI lint (below)
so new offenders can't land.

**P4 — close the header gaps.** Backfill the standard header on SPEC **007, 012,
021, 025, 026, 027** (007 & 012 have docs but not the header; 012 also has the
title/number mismatch to fix). Re-run the generator; they appear in the index.

## New guardrail to add after P3 (root-of-`specs/` lint)

Once the directory is clean, forbid non-canonical files from re-accumulating in
`specs/` root — extend `gen_spec_index.py` or add a tiny CI step:

```sh
bad=$(ls specs/*.md | grep -vE '/(README|TEMPLATE|PROCESS|SPEC-[0-9]{3}-[a-z0-9-]+)\.md$')
[ -z "$bad" ] || { echo "non-canonical files in specs/ root:"; echo "$bad"; exit 1; }
```

## Not in scope (deliberately)

- **No AIP/EIP-style governance process.** MacProvider is a single implementation,
  solo-operated, centrally-coordinated — none of the preconditions (independent
  implementations, external contributors, decentralized consensus) that justify a
  public Improvement-Proposal process exist yet. `SPEC-NNN` already *is* the right
  weight (design docs / ADRs). Revisit only when a self-hosted coordinator ships
  (a second implementation), external contributors appear, or the receipt format
  gets a second independent verifier.
- **The one exception** — the SPEC-015 verifiable-receipt format has an independent
  consumer (`macprovider-verify`), so it alone warrants being treated as a stable,
  publicly-versioned wire standard. Track that separately from this cleanup.
