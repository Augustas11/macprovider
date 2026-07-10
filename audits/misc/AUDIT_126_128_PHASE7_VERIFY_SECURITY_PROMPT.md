# Issue #126 + #128 phase7-verify hardening — SECURITY-lane audit

You are the **security** lane of a three-lane audit (code / security /
architect) of the bundled #126 + #128 phase7-verify hardening. Stay
narrowly in your lane.

**This lane is the primary stakeholder for #128 (the MEDIUM security
finding the PR closes).** Your verdict on whether the new warning
adequately closes the silent-TLS-trust-widening surface IS the
load-bearing security check.

## Branch / commit
- Branch: `fix/phase7-verify-tls-warn-and-exit64`
- Worktree: `../macprovider-126-128-phase7-verify-hardening`
- Files in scope (`git diff origin/main`).

## Why security cares about this diff

#128 was reported as a MEDIUM by Claude security-reviewer on PR
#124 (commit 99d0c1e):
- `MACPROVIDER_VERIFY_TLS_CA_FILE` silently widens TLS trust when
  honored.
- Attack scenario: buyer running under wrapper script (CI helper,
  devcontainer setup, ~/.profile modification by malware) where
  env var is set to attacker-controlled CA chain.
- Combined with a public-DNS attacker-controlled coordinator host,
  verifier silently trusts attacker's pubkey response → false
  `valid` verdict.
- PR #124's private-coordinator deny (issue #126's other half)
  blocks the localhost / RFC1918 variant but NOT public-DNS
  attacker-controlled hosts.

The fix surfaces the trust widening as a `non_default_tls_trust`
warning that the buyer sees on stderr (unless `--quiet`) and ALWAYS
in the JSON `warnings[]` output (per the existing v0.2.4 §10.4.2
quiet-doesn't-suppress-JSON contract).

## Security-lane scope (apply each; stay in lane)

### SEC-1. Does the warning adequately close the silent-trust gap?
- The warning fires IFF `MACPROVIDER_VERIFY_TLS_CA_FILE` is set AND
  the file is readable AND `AppendCertsFromPEM` succeeds. This is
  the SAME predicate `extraTLSRootsFromEnv` uses to actually
  augment the pool, so the warning is precise:
  - false-positive (warning without augmentation) impossible —
    augmentation predicate identical.
  - false-negative (augmentation without warning) impossible —
    same reason.
- The warning fires at Resolve()-time (before the live fetch), not
  fetchLive-time. Does that matter? Trace: the augmentation
  happens at fetchLive's configuredClient. If Resolve() bails
  before calling fetchLive (e.g. offline + cache hit), the warning
  STILL fires — even though the TLS pool wasn't actually used.
  - Pro: defensive ("env var is set, you've configured a non-
    default trust posture, you should know").
  - Con: warns even when no live request happens, which could be
    seen as noise.
  - The current shape is "warn-on-config", not "warn-on-use". Is
    that the right boundary?
- The buyer's stderr displays `warning: …`. Confirm the stderr-
  formatting code path actually renders `non_default_tls_trust` —
  trace through `renderWarningsToStderr` / similar.

### SEC-2. Spoof / poisoning surfaces around the env var
- The env var value lands directly in the warning's `ca_file_path`
  field. If an attacker controls the env var, they also control
  this string. Could the path contain ANSI escape codes, terminal
  control chars, or anything that poisons the stderr display? The
  `warning: non_default_tls_trust …` line includes the path
  verbatim. Cross-reference [[c1-control-chars-terminal-sanitizer-bypass]]
  memory rule — does the verifier's stderr path go through a
  terminal sanitizer?
  - If NOT, this is a new injection surface (low blast — only
    visible to a buyer who already trusts the env var).
- The path is also embedded in the JSON `warnings[]` output.
  json.Marshal escapes control chars in strings, so JSON consumers
  are safe. Stderr line MIGHT not.

### SEC-3. The exit-code change (#126) and its security implications
- The exit-code change is purely cosmetic — same error message,
  same failure mode, just exit 64 vs 70. No new attack surface;
  no behavior change for an attacker.
- But: the error message string now wraps the sentinel via
  `fmt.Errorf("%w: host %q; …")`. Confirm `%q` for the host name
  safely escapes any control chars or quotes. (Go's %q is
  injection-safe.)

### SEC-4. SPEC v0.3.4 lock criteria
- The v0.3.4 bump is additive on the LOCKED v0.3.3. The 2026-06-24
  v0.3 lock memo says "v0.3 changes the wire shape (7-field tuple
  → 9-field tuple)" — v0.3.4 does NOT touch the wire tuple shape,
  only the `warnings[]` enum. Confirm.
- The warning's `ca_file_path` is a STRING field. Schema enforces
  type. Confirm.

### SEC-5. Integration test coverage
- The integration test now expects `non_default_tls_trust` in every
  scenario's warnings (because every scenario runs with the env
  var set to the mock CA path). Does ANY scenario disprove the
  warning ever surfaces a real issue (e.g. a scenario where the env
  var is set but augmentation fails)?
- Coverage gap: there's no integration scenario where the env var
  is set to a malformed CA file (e.g. junk PEM). The unit test
  covers it (`TestResolveDoesNotEmitNonDefaultTLSTrustWarningWhen-
  CAFileNotPEM`). Worth promoting to integration, or unit is
  sufficient?

### SEC-6. Adjacent surface — does the warning interact with the
###       private-coordinator deny (#126's other half)?
- A buyer who sets `MACPROVIDER_VERIFY_TLS_CA_FILE` AND points
  `--coordinator` at a private host AND sets
  `MACPROVIDER_VERIFY_ALLOW_PRIVATE_COORDINATOR=1` is opting into
  TWO non-default trust postures. Does the verifier emit BOTH the
  `non_default_tls_trust` warning AND a `non_default_coordinator`
  warning? The integration tests show both fire together. Confirm.

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence fix>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write to
`specs/126_128_PHASE7_VERIFY_SECURITY_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM AND the warning adequately closes the #128
silent-trust-widening gap, end with:
`VERDICT: security lane READY TO MERGE — #128 silent-trust gap closed`
