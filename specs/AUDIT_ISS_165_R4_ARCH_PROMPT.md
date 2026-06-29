# Audit: ISS-165 R4 architect lens — verify R3 fixes

R3 returned 0/1/1/0 (arch). R4 verifies on `a8574cd`.

## R3 arch findings to verify

- **HIGH**: `payout_spki_drain_skipped_unsupported_client` missing
  from §7.1 + §9. Fix: both added with severity + per-rpc_label
  verification line in runbook.
- **MEDIUM**: SPEC version line + v0.1.22 paragraph understated
  scope (claimed "two events, no normative changes" while body
  changed substantially). Fix: 3-round audit narrative documented,
  three events listed, keyset migration mentioned.

## What I want (arch lens)

- Self-consistency: do §7.1 backlog row + v0.1.22 paragraph +
  code emit agree on `scan_ceiling_hit` + `total_scanned` + the
  WARN→PAGE escalation rule?
- Does v0.1.22 §payout.tuning prose anywhere reference a `LIMIT`-
  bounded scan that was the original A1 sketch and would now be
  stale?
- Cross-spec — SPEC-005 / SPEC-007 / SPEC-014 dependencies still
  intact?
- `Run()` goroutine lifecycle: clean shutdown verified against
  `shutdownCtx` cancel? Any race against `payoutS2.stop()`?
- Is there a tracking-issue / future-version note for: removing
  the defensive scan ceiling (i.e. when does operator scale
  warrant rethinking)?

Find arch defects. Severity + Convergence line.
