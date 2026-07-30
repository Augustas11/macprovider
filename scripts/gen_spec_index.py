#!/usr/bin/env python3
"""Regenerate the canonical spec index table in specs/README.md.

The hand-maintained index drifts (it listed SPEC-001..013 while 24 canonical
specs exist). The spec *headers* do not drift — so we derive the index from
them. A file in specs/ is a CANONICAL spec iff:

  1. its first line is a title:   `# SPEC-<NNN> <sep> <Title>`   (sep = — – : -)
  2. it carries a version header:  `**Version:** ...`  in the first 15 lines

Everything else in specs/ (round-N audits, FIX/ABSORB prompts, impl notes,
step docs) is a *supporting* artifact and is intentionally excluded.

Usage:
  python3 scripts/gen_spec_index.py           # rewrite the index in place
  python3 scripts/gen_spec_index.py --check    # exit 1 if the index is stale (CI)

The table is written between these markers in specs/README.md, leaving all
human-authored prose intact:

  <!-- AUTOGEN:spec-index START ... -->
  <!-- AUTOGEN:spec-index END -->
"""
from __future__ import annotations
import glob, json, os, re, sys

SPECS_DIR = os.path.join(os.path.dirname(__file__), "..", "specs")
README = os.path.join(SPECS_DIR, "README.md")
CONFORMANCE = os.path.join(SPECS_DIR, "CONFORMANCE.json")
BEGIN = "<!-- AUTOGEN:spec-index START"
END = "<!-- AUTOGEN:spec-index END -->"

TITLE_RE = re.compile(r"^#\s+SPEC[-\s]0*(\d+)\s*[—–:\-]\s*(.+?)\s*$", re.I)
# Version header is written `**Version:** 1.6 (...)` — the colon sits inside the
# bold markers, so strip all `*` before matching rather than trying to anchor them.
VER_RE = re.compile(r"^Version\s*:\s*(\S+)", re.I)
# some specs (025+) carry the version in a `Status: DRAFT v0.13 · …` line instead
STATUS_RE = re.compile(r"^Status\b.*?\b(v?\d+\.\d+(?:\.\d+)?)", re.I)
FNAME_RE = re.compile(r"^SPEC-0*(\d+)-", re.I)


def parse_spec(path: str):
    """Return (num, title, version) if path is a canonical spec, else None.

    num comes from the FILENAME (authoritative); a title/filename number
    mismatch is reported as a warning rather than silently trusted.
    """
    base = os.path.basename(path)
    try:
        head = open(path, encoding="utf-8", errors="replace").read(3000).splitlines()
    except OSError:
        return None
    if not head:
        return None
    tm = TITLE_RE.match(head[0].strip())
    if not tm:
        return None
    version = None
    for line in head[:15]:
        clean = line.replace("*", "").strip()
        vm = VER_RE.match(clean)
        if vm:
            version = vm.group(1).rstrip(".,;")
            break
        # second convention (SPEC-025+): `Status: DRAFT v0.13 · Owner: …`
        sm = STATUS_RE.match(clean)
        if sm:
            version = sm.group(1)
            break
    if version is None:
        return None
    fm = FNAME_RE.match(base)
    num = int(fm.group(1)) if fm else int(tm.group(1))
    title_num = int(tm.group(1))
    if fm and title_num != num:
        print(f"WARN {base}: filename says SPEC-{num:03d} but title says "
              f"SPEC-{title_num:03d}", file=sys.stderr)
    return num, tm.group(2).strip(), version


def collect():
    specs, seen = [], {}
    for path in sorted(glob.glob(os.path.join(SPECS_DIR, "*.md"))):
        parsed = parse_spec(path)
        if not parsed:
            continue
        num, title, version = parsed
        rel = os.path.basename(path)
        if num in seen:
            print(f"WARN duplicate canonical SPEC-{num:03d}: "
                  f"{seen[num]} and {rel}", file=sys.stderr)
        seen[num] = rel
        specs.append((num, title, version, rel))
    specs.sort(key=lambda s: (s[0], s[3]))
    # gap report — canonical numbers missing in the 1..max range
    nums = {s[0] for s in specs}
    if nums:
        gaps = [n for n in range(1, max(nums) + 1) if n not in nums]
        if gaps:
            print("NOTE no canonical spec doc for SPEC numbers: "
                  + ", ".join(f"{n:03d}" for n in gaps), file=sys.stderr)
    return specs


def load_governance():
    try:
        with open(CONFORMANCE, encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        sys.exit(f"error: cannot read {CONFORMANCE}: {exc}")
    if not isinstance(manifest, dict):
        sys.exit(f"error: {CONFORMANCE} root must be an object")
    spec_records = manifest.get("specs")
    requirement_records = manifest.get("requirements")
    if not isinstance(spec_records, list) or not isinstance(requirement_records, list):
        sys.exit(f"error: {CONFORMANCE} specs and requirements must be arrays")
    metadata = {}
    for index, record in enumerate(spec_records):
        if not isinstance(record, dict) or not isinstance(record.get("spec_id"), str):
            sys.exit(f"error: {CONFORMANCE} specs[{index}] must be an object with spec_id")
        metadata[record["spec_id"]] = record
    states = {}
    for index, requirement in enumerate(requirement_records):
        if not isinstance(requirement, dict) or not isinstance(requirement.get("spec_id"), str) or not isinstance(requirement.get("state"), str):
            sys.exit(f"error: {CONFORMANCE} requirements[{index}] must contain string spec_id and state")
        states.setdefault(requirement["spec_id"], {}).setdefault(requirement["state"], 0)
        states[requirement["spec_id"]][requirement["state"]] += 1
    return metadata, states


def render(specs, metadata, states) -> str:
    rows = [
        "| SPEC | Title | Version | Lifecycle | ID migration | Conformance | Link |",
        "|---|---|---|---|---|---|---|",
    ]
    for num, title, version, rel in specs:
        spec_id = f"SPEC-{num:03d}"
        record = metadata.get(spec_id, {})
        requirement_states = states.get(spec_id, {})
        summary = ", ".join(f"{name}: {count}" for name, count in sorted(requirement_states.items()))
        if not summary:
            summary = "pending corpus migration"
        rows.append(
            f"| {spec_id} | {title} | {version} | {record.get('status', 'untracked')} | "
            f"{record.get('requirement_id_migration', 'untracked')} | {summary} | [{rel}]({rel}) |"
        )
    return "\n".join(rows)


def splice(readme_text: str, table: str) -> str:
    if BEGIN not in readme_text or END not in readme_text:
        sys.exit(f"error: markers not found in {README}. Add:\n"
                 f"  {BEGIN} -->\n  {END}\naround the index table.")
    pre = readme_text.split(BEGIN, 1)[0]
    post = readme_text.split(END, 1)[1]
    marker_line = (f"{BEGIN} — regenerated by scripts/gen_spec_index.py; "
                   f"do not edit between markers -->")
    return f"{pre}{marker_line}\n{table}\n{END}{post}"


def lint_root() -> int:
    """Fail if any TRACKED specs/*.md is neither a canonical spec nor an allowed
    meta file — keeps specs/ root canonical-only so the reorg doesn't erode.
    Uses `git ls-files` (not glob) so local untracked scratch is ignored."""
    import subprocess
    repo = os.path.abspath(os.path.dirname(SPECS_DIR))
    keep = {"README.md", "REORG_PLAN.md", "TEMPLATE.md", "PROCESS.md"}
    all_tracked = subprocess.run(["git", "ls-files", "specs/*.md"],
                                 capture_output=True, text=True, cwd=repo).stdout.split()
    # only specs/ ROOT — subdirs (specs/design/**, specs/v0_3-design/**) are
    # intentionally non-canonical design records, not clutter.
    tracked = [rel for rel in all_tracked if rel.count("/") == 1]
    bad = [rel for rel in tracked
           if os.path.basename(rel) not in keep
           and parse_spec(os.path.join(repo, rel)) is None]
    if bad:
        print("error: non-canonical files tracked in specs/ root — relocate them "
              "(audits/ or docs/) or give them a canonical spec header:",
              file=sys.stderr)
        for rel in bad:
            print(f"  {rel}", file=sys.stderr)
        return 1
    print(f"ok: specs/ root is canonical-only ({len(tracked)} tracked)", file=sys.stderr)
    return 0


def main() -> int:
    if "--lint" in sys.argv[1:]:
        return lint_root()
    check = "--check" in sys.argv[1:]
    specs = collect()
    metadata, states = load_governance()
    print(f"canonical specs: {len(specs)}", file=sys.stderr)
    try:
        current = open(README, encoding="utf-8").read()
    except (OSError, UnicodeDecodeError) as exc:
        sys.exit(f"error: cannot read {README}: {exc}")
    updated = splice(current, render(specs, metadata, states))
    if check:
        if current != updated:
            sys.exit("error: specs/README.md is stale — run "
                     "`python3 scripts/gen_spec_index.py` and commit.")
        print("ok: spec index is up to date", file=sys.stderr)
        return 0
    if current != updated:
        open(README, "w", encoding="utf-8").write(updated)
        print(f"updated {README}", file=sys.stderr)
    else:
        print("no change", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
