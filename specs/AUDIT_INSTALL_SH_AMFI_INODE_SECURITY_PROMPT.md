# AUDIT: install.sh AMFI-inode refresh — SECURITY lens

## Change under audit

Branch: `fix/install-sh-amfi-inode-refresh` on top of `origin/main` (v1.7.10).

Read the diff with:

```
git -C /Users/augstar/macprovider-amfi-inode diff origin/main
```

See `specs/AUDIT_INSTALL_SH_AMFI_INODE_CODE_PROMPT.md` for CODE-lane
context + the two-file change list.

## What the change does — security-relevant summary

When BOTH the first invocation of the freshly-installed
`~/.local/bin/macprovider-cli` AND the 2s-later retry are SIGKILL'd
by the kernel with a CODESIGNING verdict, the helper now:

1. `cp` the binary bytes to a tempfile.
2. `rm` the original at `$INSTALL_DIR/macprovider-cli`.
3. `cp` the tempfile back to `$INSTALL_DIR/macprovider-cli`.
4. `chmod +x` the restored file.
5. Retry the CLI once more.

The rationale is that the AMFI kernel cache holds a stuck rejection
pinned to the inode `installer -pkg` created. `rm` + fresh `cp` gives
the file a new inode; AMFI re-evaluates the (unchanged) signature
against the new inode and passes.

## SECURITY lens — what to audit

Focus strictly on SECURITY properties: signature verification bypass,
race conditions during file replacement, tempfile handling, DoS.

1. **Does the inode refresh bypass any legitimate signature check?**
   The bytes on disk are unchanged (verified `codesign --verify` passes
   before AND after). AMFI's rejection is not about signature validity
   — it's about a cache entry pinned to an old inode. Argue whether
   there is any scenario where AMFI could legitimately reject the
   original inode for a REAL signature failure (not a cache glitch),
   and where our rm+cp would spuriously succeed. Consider:
   - macOS 26 codesigning invariants: is inode identity ever part of
     the signature? (Answer: no — signature is over Mach-O contents,
     not filesystem metadata.)
   - Could macOS's `com.apple.quarantine` xattr, extended attrs, or
     provenance metadata carry rejection state that our `cp` clears?
     If yes, the refresh is effectively an xattr wipe, which is a
     different security operation. Argue.
2. **Tempfile race.** `mktemp -t macprovider-cli-inode-refresh` creates
   a file in `$TMPDIR` (per-user on macOS). Between `cp` to `$tmp`
   and `cp` back to `$INSTALL_DIR/macprovider-cli`, could an attacker
   with local shell access replace `$tmp` with a doctored binary?
   Trace the timing window.
3. **`$INSTALL_DIR/macprovider-cli` race.** Between `rm` of the
   original and `cp` back from `$tmp`, `$INSTALL_DIR/macprovider-cli`
   is briefly absent. Could an attacker create their own binary at
   that path? Consider `$INSTALL_DIR` permissions (per-user
   `~/macprovider/`, mode 0755 on macOS default).
4. **Signed pkg vs. unsigned copy.** The `installer -pkg` writes a
   binary whose lineage is auditable (came from a signed, notarized,
   stapled pkg). The `cp` back from `$tmp` writes a binary whose
   lineage is "somewhere on disk with the same bytes." From macOS's
   perspective at exec time, both cases are the same — signature
   verification happens on the bytes at execve, not on lineage. But
   from an operator-forensics perspective, is there any auditable
   provenance signal that would be lost? Argue.
5. **`chmod +x` on the restored file.** Explicit `+x` — could this
   be exploited to escalate a non-executable file into executable
   state? No — the file is the one we just copied from
   `$INSTALL_DIR/macprovider-cli`, which was itself +x from the pkg.
   Confirm.
6. **`cp` vs `install`.** `install(1)` is the canonical tool for
   file replacement with permissions. We use `cp`. Argue whether
   `install -m 0755` would be safer (atomic replace) or equivalent.
7. **`rm -f` risk.** The `rm -f` cannot fail on a normal file. Could
   it delete something unintended if `$INSTALL_DIR/macprovider-cli`
   were a symlink? Trace.
8. **Concurrency — two operators running the retry simultaneously.**
   Highly unlikely (single-user install script), but if two shells
   raced through the inode-refresh block on the same
   `$INSTALL_DIR/macprovider-cli`, could one clobber the other? Argue.
9. **Failure-mode confidence.** After the refresh, the binary that
   ran is the one at `$INSTALL_DIR/macprovider-cli` after the second
   `cp`. If AMFI accepts it, the operator sees the CLI produce
   output and the install continues. Is there any way the accepted
   binary could differ from the pkg-installed one? No — the bytes
   round-trip through cp. Confirm.
10. **v3 signing keypair / SPEC-023.** This PR does not touch signing
    keys or the SPEC-023 static-feed flow. Confirm no accidental
    surface area was added.

## Bar

CRITICAL / HIGH / MEDIUM findings must be fixed. LOW / INFO may ship
with PR-body documentation. Return findings as a structured list; no
speculative findings without a concrete attack scenario.
