# AUDIT PROMPT — Issue #585 v1.8.40 diff — SECURITY lane (R1)

You are an independent security auditor. Audit the complete diff for v1.8.40
in THIS worktree:

```
git -C /Users/augstar/macprovider-malibu-bootstrap-bridge diff 71eb927a..HEAD
```

Base `71eb927a` is origin/main (= immutable v1.8.39 source).

## Context

- Architecture (Issue #585 Option 2): launchd+CLI own the provider process,
  credentials, identity, update transactions, and lifecycle state; Malibu is a
  read-only client that may only invoke CLI-owned transactions.
- Normative decisions: `beta/DECISION_CRITERIA.md` entries 155–161. In
  particular: Entry 155/156 freeze the one-time Sparkle bootstrap to v1.8.39
  (Malibu 1.8.40 must remain Sparkle key/runtime/feed-free); Entry 158 requires
  stranded hosts to be recovered via the signed v1.8.40 full installer through
  an authorized operator path; Entry 160 re-arms `legacyBootstrapTarget` per
  release under the invariant that an app may only ever pin-install exactly
  the CLI version it shipped as.
- The lifecycle state file lives at
  `~/Library/Application Support/macprovider/lifecycle/state-v1.json`
  (mode 0600, in a 0700 directory) and is now snapshotted/restored by the
  installer transaction (`dist/install.sh`).

## Audit scope (rate every finding CRITICAL / HIGH / MEDIUM / LOW)

1. **Update-authority boundary**: does the `legacyBootstrapTarget` bump to
   1.8.40 (CLIUpdateRunner.swift) grant Malibu ANY authority beyond
   pin-installing its own shipped version? Downgrade/replay resistance: can a
   1.8.40 app be induced to install anything other than v1.8.40? Can any input
   (provider /v1/status fields, malformed versions) re-arm a disarmed bridge or
   bypass the exact-match interlock? Confirm no Sparkle key/feed/runtime is
   introduced anywhere in the diff.
2. **Installer transaction file handling** (`dist/install.sh`): the new
   lifecycle snapshot/restore path — symlink following, TOCTOU between prove-
   copy and swap, permission/ownership preservation (0600 file, 0700 dir; note
   `cp -p` preserves SOURCE ownership — is that correct here?), staging
   directory permissions (could another local user read lifecycle contents
   from the recovery bundle?), predictable temp paths, partial-write/atomicity
   of the final swap, and whether a crafted pre-existing lifecycle file could
   inject content into shell evaluation anywhere (quoting).
3. **Fail-closed behavior**: when the snapshot can't be staged or verified,
   the transaction must abort BEFORE live mutation; when restore fails
   mid-rollback, the outcome must not silently claim success. Verify error
   paths don't downgrade to warnings on security-relevant failures.
4. **Secrets and identity**: confirm the diff never logs, copies to
   world-readable locations, or widens access to provider tokens, Keychain
   items, or provider identity. The lifecycle file itself contains no secrets
   but its handling patterns may be copied to files that do — flag dangerous
   idioms.
5. **Coordinator-advertised version** (coordinator yaml): any way the 1.8.40
   advertisement interacts unsafely with the legacy 1.8.30 fleet (forced
   updates, downgrade offers)?

Attribute every finding as NEW-to-this-diff vs PRE-EXISTING on the v1.8.39
baseline; pre-existing-not-worsened issues are reported but not blocking.

## Output format

Markdown. For each finding: severity, file:line, attack scenario or failure
mode, suggested fix. End with a summary table and an explicit verdict line:
`VERDICT: X CRITICAL / Y HIGH / Z MEDIUM / W LOW`.
