# Round 3 — CODE lane re-audit, CB per-tuple acceptance coverage

Worktree `/Users/augstar/macprovider-cb-tuple-acceptance`, branch
`fix/cb-tuple-acceptance-coverage`, based on `origin/main` at `a912e039`.

Review the FULL combined diff as it will land (`git diff`), not just the
round-3 delta.

History: round 1 returned 0C/1H/1M/1L; round 2 returned 0C/0H/1M/1L. Fixes now
applied for round 2's findings:

- **MEDIUM Unicode hex** (`Config.swift`) — the canonical-SHA test no longer
  uses `Character.isHexDigit`. It is now ASCII-byte based:
  `value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }`.
  Two fullwidth confusable cases (U+FF41, U+FF11) added to the rejection test.
- **LOW CODEOWNERS** — `ModelRuntime.swift` and `MacProviderCLI.swift`, the two
  files that thread and enforce the coverage gate, added to the CB block.

Verify those fixes are correct and complete, and check for anything they
introduced. Then confirm the whole diff once more.

IMPORTANT — do not let a verification side effect become a finding: running
`swift build` or `swift test` in this worktree prunes
`phase3-binary/Package.resolved` locally. It is clean in the submitted diff
(`git diff -- phase3-binary/Package.resolved` is empty right now). If your own
build dirties it, that is your run, not the landing state. Note it as INFO at
most, and check `git stash list`/`git diff` before and after your commands so
you can tell the two apart.

Report CRITICAL / HIGH / MEDIUM / LOW / INFO with file:line, a concrete failure
scenario, and a fix. Gate is 0 CRITICAL, 0 HIGH, 0 MEDIUM. State explicitly if
you find none. Do not propose SPEC edits.
