# `specs/` reorganization migration record

**Status:** complete (2026-07-16) · **Owner:** @Augustas11

The physical reorganization proposed on 2026-07-10 is complete. The original
directory held 1,571 Markdown files, only 24 of which matched the canonical
header contract. Audit transcripts and prompts were evacuated to `audits/`,
supporting notes were relocated, missing headers were repaired, and the
canonical corpus grew to 33 indexed specs as new specs were added.

The completed controls are:

- `scripts/gen_spec_index.py` generates the canonical table in `README.md`.
- `python3 scripts/gen_spec_index.py --check` rejects index drift.
- `python3 scripts/gen_spec_index.py --lint` rejects non-canonical Markdown in
  the root of `specs/`.
- `.github/workflows/spec-index.yml` runs both checks in CI.
- `PROCESS.md`, `TEMPLATE.md`, `AUTHORITY.json`, and `CONFORMANCE.json` now
  govern semantic authority and conformance separately from physical layout.

The historical migration phases were: add index guardrails; move round-N audits
to `audits/spec-NNN/`; move agent prompts to `audits/_prompts/`; normalize or
relocate miscellaneous root documents; and repair canonical headers. Commits
`cb36abd8`, `1defc166`, and `43c4de4a` preserve the detailed migration history.

This record is non-normative. Current governance requirements live in
[`PROCESS.md`](PROCESS.md); the remaining semantic reconciliation program is
tracked by GitHub issue #614.
