#!/usr/bin/env python3
"""Move the mlx-swift-lm fork pin (SPEC-048 R003) across every site at once.

Usage:
  python3 scripts/bump-mlx-swift-lm-pin.py --tag TAG --revision REV \\
      --summary "One sentence for the changelog and rationale." [--issue N]

The current tag and revision are read from scripts/read_swiftpm_pins.py
(SPEC048_MLX_SWIFT_LM_TAG / _REVISION). Every site below is located and
rewritten in memory first; if any expected anchor is missing or ambiguous
(found other than exactly once, or not at all where a count is open), nothing
is written and the script exits 1, so drift between the sites is loud.

Machine sites (rewritten exactly):
  phase3-binary/Package.swift            revision, and a new "// Tag ..." comment
  phase3-binary/Package.resolved         mlx-swift-lm "revision"
  phase3-binary/Sources/macprovider-cli/KVConversationColdTierAdapter.swift
                                         static let mlxSwiftLMRevision
  scripts/read_swiftpm_pins.py           SPEC048_MLX_SWIFT_LM_TAG / _REVISION + comment
  scripts/tests/test_upstream_watch.py   every literal of the old revision
  docs/runbooks/MLX_ENGINE_UPGRADE_MATRIX.md  the LM row; an "As of" paragraph
  specs/SPEC-048-native-mtp-serving.md   **Version:** (line 3), metadata "version",
                                         the R003 tuple row, a prose paragraph, a
                                         changelog entry (patch version + 1, today)
  specs/CONFORMANCE.json                 SPEC-048 "version"; SPEC-048-R003 rationale

Prose it cannot rewrite safely gets a short templated paragraph built from
--summary (the matrix "As of" paragraph and the SPEC-048 R003 paragraph); a
reminder to edit them is printed. Then it runs gen_spec_index.py and
decode_path_digest.py --write, and checks check_spec_governance.py,
gen_spec_index.py --check, decode_path_digest.py --check and
scripts.tests.test_upstream_watch. A failing check exits 1 (files stay written
for inspection; `git diff` / `git checkout --` them).

--root (default: the repository) and --skip-regenerate exist for tests.
"""

from __future__ import annotations

import argparse
import datetime
import json
import pathlib
import re
import subprocess
import sys
import textwrap

REPO = pathlib.Path(__file__).resolve().parents[1]

PACKAGE_SWIFT = "phase3-binary/Package.swift"
PACKAGE_RESOLVED = "phase3-binary/Package.resolved"
KV_ADAPTER = "phase3-binary/Sources/macprovider-cli/KVConversationColdTierAdapter.swift"
PINS = "scripts/read_swiftpm_pins.py"
WATCH_TEST = "scripts/tests/test_upstream_watch.py"
MATRIX = "docs/runbooks/MLX_ENGINE_UPGRADE_MATRIX.md"
SPEC = "specs/SPEC-048-native-mtp-serving.md"
CONFORMANCE = "specs/CONFORMANCE.json"

TAG_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+-macprovider\.[0-9]+(\.[0-9]+)*$")
REV_RE = re.compile(r"^[0-9a-f]{40}$")
VERSION_RE = re.compile(r"^([0-9]+)\.([0-9]+)\.([0-9]+)$")

REGENERATE = [
    ["python3", "scripts/gen_spec_index.py"],
    ["python3", "scripts/decode_path_digest.py", "--write"],
]
CHECKS = [
    ["python3", "scripts/check_spec_governance.py"],
    ["python3", "scripts/gen_spec_index.py", "--check"],
    ["python3", "scripts/decode_path_digest.py", "--check"],
    ["python3", "-m", "unittest", "scripts.tests.test_upstream_watch"],
]


class SiteError(Exception):
    pass


def replace_once(text: str, pattern: str, repl, site: str, flags: int = 0) -> str:
    """re.subn that insists on exactly one match."""
    new, count = re.subn(pattern, repl, text, flags=flags)
    if count != 1:
        raise SiteError(f"{site}: expected exactly one match for /{pattern}/, found {count}")
    return new


def wrap(text: str, indent: str, first: str = "", width: int = 78) -> str:
    return textwrap.fill(text, width=width, initial_indent=indent + first,
                         subsequent_indent=indent, break_on_hyphens=False, break_long_words=False)


def bump_patch(version: str) -> str:
    m = VERSION_RE.match(version)
    if not m:
        raise SiteError(f"{SPEC}: version {version!r} is not X.Y.Z")
    return f"{m.group(1)}.{m.group(2)}.{int(m.group(3)) + 1}"


def plan(root: pathlib.Path, tag: str, rev: str, summary: str, issue: str, date: str):
    """Return ({relative path: new text}, reminders). Raises SiteError."""
    read = {p: (root / p).read_text(encoding="utf-8") for p in
            (PACKAGE_SWIFT, PACKAGE_RESOLVED, KV_ADAPTER, PINS, WATCH_TEST, MATRIX, SPEC, CONFORMANCE)}
    out = dict(read)
    ref = f" (#{issue})" if issue else ""

    pins = read[PINS]
    tag_m = re.findall(r'^SPEC048_MLX_SWIFT_LM_TAG = "([^"]+)"$', pins, flags=re.M)
    rev_m = re.findall(r'^SPEC048_MLX_SWIFT_LM_REVISION = "([0-9a-f]{40})"$', pins, flags=re.M)
    if len(tag_m) != 1 or len(rev_m) != 1:
        raise SiteError(f"{PINS}: SPEC048_MLX_SWIFT_LM_TAG/_REVISION not found exactly once")
    old_tag, old_rev = tag_m[0], rev_m[0]
    if tag == old_tag or rev == old_rev:
        raise SiteError(f"the pin is already {old_tag} ({old_rev}); a new pin needs a new tag and revision")
    qt, qr = re.escape(old_tag), re.escape(old_rev)

    # read_swiftpm_pins.py: the comment block between _FORK and _TAG, the tag, the revision.
    comment = "\n".join("# " + line for line in textwrap.wrap(
        f"{tag}{ref} on {old_tag}: {summary}", width=76, break_on_hyphens=False, break_long_words=False))
    pins = replace_once(
        pins,
        r'(^SPEC048_MLX_SWIFT_LM_FORK = "[^"]+"\n)(?:#[^\n]*\n)*(SPEC048_MLX_SWIFT_LM_TAG = )"' + qt + '"',
        lambda m: m.group(1) + comment + "\n" + m.group(2) + json.dumps(tag), PINS, re.M)
    pins = replace_once(pins, r'^(SPEC048_MLX_SWIFT_LM_REVISION = )"' + qr + '"',
                        lambda m: m.group(1) + json.dumps(rev), PINS, re.M)
    out[PINS] = pins

    # Package.swift: the revision pin and a new tag comment above the current one.
    swift = replace_once(
        read[PACKAGE_SWIFT],
        r'(url: "https://github\.com/Augustas11/mlx-swift-lm\.git",\n\s*revision: )"' + qr + '"',
        lambda m: m.group(1) + json.dumps(rev), PACKAGE_SWIFT)
    swift = replace_once(
        swift, r"^( *)(// Tag " + qt + r"\b)",
        lambda m: wrap(f"Tag {tag}{ref} on {old_tag}: {summary}", m.group(1) + "// ") + "\n"
        + m.group(1) + m.group(2),
        PACKAGE_SWIFT, re.M)
    out[PACKAGE_SWIFT] = swift

    out[PACKAGE_RESOLVED] = replace_once(
        read[PACKAGE_RESOLVED],
        r'("location" : "https://github\.com/Augustas11/mlx-swift-lm\.git",\n\s*"state" : \{\n\s*"revision" : )"'
        + qr + '"',
        lambda m: m.group(1) + json.dumps(rev), PACKAGE_RESOLVED)
    out[KV_ADAPTER] = replace_once(
        read[KV_ADAPTER], r'(static let mlxSwiftLMRevision = )"' + qr + '"',
        lambda m: m.group(1) + json.dumps(rev), KV_ADAPTER)

    watch, n = re.subn(r'"' + qr + '"', json.dumps(rev), read[WATCH_TEST])
    if n == 0:
        raise SiteError(f"{WATCH_TEST}: no literal of the current revision {old_rev}")
    out[WATCH_TEST] = watch

    # Engine matrix: the LM row and a templated "As of" paragraph.
    matrix = replace_once(
        read[MATRIX],
        r"^(\| `Augustas11/mlx-swift-lm` \|[^\n]*?\| )`" + qt + r"` \| `" + qr + r"` \|",
        lambda m: m.group(1) + f"`{tag}` | `{rev}` |", MATRIX, re.M)
    matrix = replace_once(
        matrix, r"^(### Current tuple delta\n\n)",
        lambda m: m.group(1) + wrap(
            f"As of {date} the LM row is `{tag}` (`{rev[:7]}`), on `{old_tag}`{ref}: {summary} "
            "No Swift, core or C pin changes.", "") + "\n\n",
        MATRIX, re.M)
    out[MATRIX] = matrix

    # SPEC-048: version in three places, the tuple row, a paragraph, the changelog.
    spec = read[SPEC]
    head = spec.split("\n")
    if len(head) < 3 or not re.fullmatch(r"\*\*Version:\*\* [0-9]+\.[0-9]+\.[0-9]+", head[2]):
        raise SiteError(f"{SPEC}: line 3 is not '**Version:** X.Y.Z'")
    old_version = head[2].split()[-1]
    new_version = bump_patch(old_version)
    meta = re.search(r"```json\n\{.*?\n\}\n```", spec, flags=re.S)
    if not meta:
        raise SiteError(f"{SPEC}: no embedded metadata JSON block")
    meta_text = meta.group(0)
    meta_versions = re.findall(r'^  "version": "([^"]+)",$', meta_text, flags=re.M)
    if meta_versions != [old_version]:
        raise SiteError(f"{SPEC}: metadata version {meta_versions} != **Version:** {old_version}")
    new_meta = meta_text.replace(f'  "version": "{old_version}",', f'  "version": "{new_version}",')
    spec = spec[:meta.start()] + new_meta + spec[meta.end():]
    spec = replace_once(spec, r"\A((?:[^\n]*\n){2})\*\*Version:\*\* " + re.escape(old_version) + r"$",
                        lambda m: m.group(1) + f"**Version:** {new_version}", SPEC, re.M)
    spec = replace_once(
        spec,
        r"^(\| `https://github\.com/Augustas11/mlx-swift-lm\.git` \| )`" + qt + r"` \| `" + qr + r"` \|",
        lambda m: m.group(1) + f"`{tag}` | `{rev}` |", SPEC, re.M)
    spec = replace_once(
        spec, r"^The mlx-swift-lm row(\s+`" + qt + r"`\s+is\s)",
        lambda m: wrap(f"The mlx-swift-lm row `{tag}` is on `{old_tag}` (`{old_rev}`){ref}, at "
                       f"`{rev}`: {summary} The Swift, core and C rows are unchanged.", "") + "\n\n"
        + "The prior mlx-swift-lm row" + m.group(1),
        SPEC, re.M)
    spec = replace_once(
        spec, r"^(## [0-9]+\. Changelog and history\n\n)",
        lambda m: m.group(1) + wrap(
            f"**{new_version} ({date})** — R003 names mlx-swift-lm `{tag}` (`{rev}`) on "
            f"`{old_tag}`{ref}: {summary} Other model sources and the Swift, core and C rows are unchanged.",
            "  ", "").replace("  **", "- **", 1) + "\n",
        SPEC, re.M)
    out[SPEC] = spec

    # CONFORMANCE.json: text edits so the file's formatting is untouched.
    conf_text = read[CONFORMANCE]
    conf = json.loads(conf_text)
    specs = [s for s in conf.get("specs", []) if s.get("spec_id") == "SPEC-048"]
    if len(specs) != 1 or specs[0].get("version") != old_version:
        raise SiteError(f"{CONFORMANCE}: SPEC-048 entry missing or its version is not {old_version}")
    conf_text = replace_once(
        conf_text,
        r'("spec_id": "SPEC-048",\n\s*"title": "[^"\n]*",\n\s*"version": )"' + re.escape(old_version) + '"',
        lambda m: m.group(1) + json.dumps(new_version), CONFORMANCE)
    reqs = [r for r in conf.get("requirements", []) if r.get("requirement_id") == "SPEC-048-R003"]
    old_rationale = (reqs[0].get("gap") or {}).get("rationale") if len(reqs) == 1 else None
    if not isinstance(old_rationale, str):
        raise SiteError(f"{CONFORMANCE}: SPEC-048-R003 gap.rationale not found exactly once")
    new_rationale = (f"SPEC-048 v{new_version} names LM {tag} ({rev}){ref} on {old_tag}: {summary} "
                     f"Prior tuple context: {old_rationale}")
    encoded = json.dumps(old_rationale, ensure_ascii=False)
    if conf_text.count(encoded) != 1:
        raise SiteError(f"{CONFORMANCE}: the SPEC-048-R003 rationale text is not found exactly once")
    out[CONFORMANCE] = conf_text.replace(encoded, json.dumps(new_rationale, ensure_ascii=False))
    json.loads(out[CONFORMANCE])

    reminders = [
        f"{MATRIX}: the 'As of {date}' paragraph under 'Current tuple delta' is templated; name the commits.",
        f"{SPEC}: the R003 paragraph 'The mlx-swift-lm row `{tag}`' is templated; describe the delta.",
        f"{PACKAGE_SWIFT}: the '// Tag {tag}' comment is templated from --summary.",
    ]
    return {p: t for p, t in out.items() if t != read[p]}, reminders, (old_tag, old_rev, old_version, new_version)


def run(root: pathlib.Path, commands) -> bool:
    for command in commands:
        print("+ " + " ".join(command), flush=True)
        if subprocess.run(command, cwd=root, env=None).returncode != 0:
            print(f"bump-mlx-swift-lm-pin: FAILED: {' '.join(command)}", file=sys.stderr)
            return False
    return True


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--tag", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--issue", default="")
    parser.add_argument("--date", default=datetime.date.today().isoformat())
    parser.add_argument("--root", type=pathlib.Path, default=REPO)
    parser.add_argument("--skip-regenerate", action="store_true",
                        help="rewrite the sites only; no regeneration and no checks (tests)")
    args = parser.parse_args(argv)

    if not TAG_RE.match(args.tag):
        parser.error(f"--tag {args.tag!r} is not <upstream>-macprovider.<n>")
    if not REV_RE.match(args.revision):
        parser.error("--revision must be a full lowercase 40-hex commit id")
    if args.issue and not re.fullmatch(r"[0-9]+", args.issue.lstrip("#")):
        parser.error("--issue must be an issue number")
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", args.date):
        parser.error("--date must be YYYY-MM-DD")
    summary = " ".join(args.summary.split())
    if not summary:
        parser.error("--summary must be one non-empty sentence")
    if not summary.endswith("."):
        summary += "."

    root = args.root.resolve()
    try:
        files, reminders, (old_tag, old_rev, old_version, new_version) = plan(
            root, args.tag, args.revision, summary, args.issue.lstrip("#"), args.date)
    except (SiteError, OSError, ValueError) as error:
        print(f"bump-mlx-swift-lm-pin: REFUSED (nothing written): {error}", file=sys.stderr)
        return 1
    for path, text in files.items():
        (root / path).write_text(text, encoding="utf-8")
        print(f"updated {path}")
    print(f"mlx-swift-lm {old_tag} ({old_rev}) -> {args.tag} ({args.revision}); "
          f"SPEC-048 {old_version} -> {new_version}")
    if not args.skip_regenerate:
        if not run(root, REGENERATE) or not run(root, CHECKS):
            return 1
    for reminder in reminders:
        print(f"REMINDER: {reminder}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
