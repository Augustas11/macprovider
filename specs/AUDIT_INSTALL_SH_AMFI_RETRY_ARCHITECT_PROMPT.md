# AUDIT: install.sh AMFI/Taskgated race retry — ARCHITECT lens

## Change under audit

Branch: `fix/install-sh-taskgated-retry` on top of `origin/main` (v1.7.9).

One file changed: `phase3-binary/dist/install.sh` (+31 / -3).

Read the DIFF with:

```
git -C /Users/augstar/macprovider-installsh-retry diff origin/main -- phase3-binary/dist/install.sh
```

## What the change does

Adds a helper that retries `macprovider-cli` once after 2s if the first
post-install invocation is SIGKILL'd by the kernel with a CODESIGNING
verdict (Taskgated Invalid Signature / Invalid Page). Motivated by an
observed race on Apple M5 macOS 26.5 during v1.7.9 install; full
crash-report details in `specs/AUDIT_INSTALL_SH_AMFI_RETRY_CODE_PROMPT.md`.

## ARCHITECT lens — what to audit

Focus on architectural fit, scope discipline, and long-term maintenance.
The other two lenses (CODE, SECURITY) audit correctness and security
respectively.

1. **Right layer for the fix.** The retry is applied in `install.sh`,
   the public installer. Argue whether this is the right layer or
   whether the fix belongs elsewhere:
   - `.pkg` postinstall script — could add a `sleep` there so AMFI
     settles before install.sh ever runs the binary.
   - Release-time signing pipeline — could sign in a way that avoids
     the AMFI race entirely.
   - macprovider-cli itself — could handle its own re-exec on
     SIGKILL. (Note: SIGKILL is uncatchable by the target, so this
     is not viable.)
   - Notarization / stapling metadata — argue whether the `.pkg` is
     signed such that AMFI has to re-verify at first execve rather
     than accepting from the notarized cache.

   Given the constraints, argue whether `install.sh` is the least-bad
   layer.

2. **Scope creep risk.** The helper is 15 lines and wraps 3 call sites.
   Any risk that this becomes a "general retry-on-signal wrapper" that
   accumulates other special cases over time (e.g. retry on network
   errors, retry on filesystem errors)? Recommend whether the helper
   name should stay specific (`_amfi_retry`) or be renamed something
   more general.

3. **Diagnostic vs. auto-heal trade-off.** The helper silently retries
   and, on success, the operator sees only a single "Retrying once"
   log line. Argue whether this hides a genuine signal (macOS 26 AMFI
   race) from ops eyes. Alternative: emit a `WARN` line to stderr
   with a link to a knowledge-base entry. Recommend whether the log
   output is sufficient.

4. **Bootstrap coverage — 3 sites or all of them.** The helper wraps
   `--recommend --apply`, `--recommend --apply --donor-mode`, and
   `--recommend --freshness-check`. It does NOT wrap the `nohup`
   foreground-provider launch (~line 1962). Argue whether the latter
   is at risk:
   - Foreground launch happens after multiple prior invocations have
     already succeeded, so AMFI is already primed for this binary.
     Race window has closed by then.
   - Or: the launch is a separate exec via nohup, which forks and
     re-execs; if AMFI has a per-process-tree cache miss, the race
     could recur.

5. **Testing regime.** No dedicated `install.sh` test scaffolding
   exists in the repo. The author validated the helper via an ad-hoc
   smoke script with 9 scenarios (success, exit-10 pass-through,
   SIGKILL-then-success, SIGKILL-both, non-137 non-zero pass-through,
   `if/else` caller pattern, `|| die` caller pattern, `set -e`
   preservation). Argue whether these scenarios are sufficient or
   whether a dedicated `dist/tests/install-sh-test.bats` (or similar)
   should be committed alongside the change. Consider that the file
   is code-signed by the release pipeline and the risk is mostly at
   release-time bugs, not runtime tampering.

6. **Failure-mode observability.** If the retry ALSO fails (rc=137
   twice in a row), the helper returns 137 and the caller falls
   through to `die 6`. The operator sees the same error as before,
   plus one "Retrying once" log line. Is this observably enough for
   the operator to understand what happened? Recommend whether to
   `log` a distinct message ("Retry also SIGKILL'd — this may be a
   genuine signature failure") to disambiguate.

7. **`sleep 2` — magic number.** The 2-second sleep is a magic
   constant. Argue whether it should be a script-level variable
   (`AMFI_RETRY_SLEEP=2`) with an env override for pathological
   systems. Or is that scope creep for a fix that will hopefully
   become obsolete once macOS 26 AMFI behavior settles?

8. **Documentation surface.** The change adds an in-file comment
   block explaining the race. Are there other docs that should be
   updated (README, SPEC-023, an existing "known macOS issues"
   page)? Argue whether the in-file comment is enough.

9. **Interaction with SPEC-023.** SPEC-023 is the autotune-recommend
   specification. Is there any SPEC-023 change required by adding a
   retry around the CLI invocations that ship the recommendation? My
   read is no — the helper is a pure installer-side concern with no
   SPEC touch — but confirm.

10. **Cleanup path.** If macOS 26 point releases fix the AMFI race,
    should this helper be removed, kept as a defensive net, or
    tagged with a removal deadline? Recommend a policy.

## Bar

CRITICAL / HIGH / MEDIUM must be fixed. LOW / INFO may ship with
PR-body documentation. Return findings as a structured list.
