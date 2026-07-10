# SPEC-020 v0.1.1 — Round 2 audit prompt (per-lane)

You are auditing **SPEC-020 v0.1.1 (2026-06-29, DRAFT)** — provider
autoupdate, post-r1 absorption.

**Bar: 0 CRITICAL + 0 HIGH + 0 MEDIUM before the SPEC PR opens.**

## What changed since r1

r1 returned 0C + 4H + 13M across three lanes. v0.1.1 absorbed every
finding. Specifically:

- New section "Cross-spec amendment and trust state" (before R-1)
  pinning `coordinator_advertised_version.latest_binary_version` as the
  authoritative source and gating autoupdate on the strongest configured
  coord authentication (T-3 absorption).
- New convergence-boundary paragraph (A-r1-H-2 absorption).
- New combined rollback observer + marker/backup hardening subsection
  (T-1 absorption: A-r1-H-3 + B-r1-M-4 + C-r1-M-3).
- Reworked R-6 observability with `source`/`outcome`/`phase`/
  `failure_class` enums + 4096-byte size bound + redaction invariant
  (T-2 absorption: A-r1-M-2 + B-r1-M-6 + C-r1-M-4).
- New R-x.y for release-by-tag, version regex, concrete backoff math
  (B-r1-M-1/M-2/M-3 absorption).
- Opt-out compatibility for both legacy + SPEC config keys (B-r1-M-5).
- New revocation/denylist hook + historical-replay threat T-8 (C-r1-M-1).
- New key rotation policy paragraph (C-r1-M-2).
- Comparator binding to `SelfUpdate.compareSemver` (A-r1-M-3).
- Provider-initiated autoupdate drain distinction (A-r1-M-1).
- Citation typo fixed: SPEC-001 filename is `SPEC-001-phase3-binary.md`.

Counts went: 38→48 R-N.M, 7→8 T-N, 12→17 AC, 0→10 failure_class enums.

## Authoritative inputs

(Same as r1 — re-read `specs/SPEC-020-provider-autoupdate.md`,
`specs/BUILD_SPEC_020_PROMPT.md`, `specs/SPEC-020-r1-audit.md` for the
r1 verdict table + per-finding fixes, and the IMPL anchors at
`phase3-binary/Sources/macprovider-cli/SelfUpdate.swift` +
`phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift`.)

Also verify: `specs/SPEC-001-phase3-binary.md` actually exists in the
worktree (the BUILD prompt typo'd this; v0.1.1 should cite the correct
file). Spot-check by grepping for the citation in the SPEC body.

## Lane-specific focus

You are ONE of the three lanes. Stay in your lens. Do NOT audit the
other lanes' concerns.

### Lane A — Codex architect

- **Did absorption introduce any cross-spec contradictions?** The new
  Cross-spec amendment section names SPEC-001 §6.5/§6.7 — verify those
  sections exist in `specs/SPEC-001-phase3-binary.md` and the SPEC-020
  characterization matches.
- **Trust-state boundary**: is the "strongest configured authentication"
  language unambiguous? What does "strongest configured" mean if Tier2
  is unconfigured on a given provider — does autoupdate fail closed or
  fall back? Pin the matrix.
- **Convergence boundary**: does the new paragraph leave any
  unintentional escape valve? Are watchdog-disabled rigs handled
  identically to opt-out rigs from the convergence-population standpoint?
- **Authority for `coordinator_advertised_version.latest_binary_version`**:
  the SPEC names this as authoritative source but says "policy for
  choosing the value remains out of scope." Does that leave a contract
  gap for the existing coord code path? Spot-check `phase4-coordinator/`
  for where this field is populated.
- **Drain distinction**: does the new R-3 paragraph cleanly distinguish
  provider-initiated autoupdate drain from SPEC-001 coord-initiated
  drain? Any wire-level ambiguity left?
- **Comparator binding**: is the `SelfUpdate.compareSemver` reference
  testable? Does R-x.y let an implementer write a code-level invariant?

### Lane B — Codex code

- **Citations verify**: every `file:line` and `file:section` cite in
  v0.1.1 must resolve. New cites likely include `SPEC-001-phase3-binary.md`
  §6.5/§6.7 and various `SelfUpdate.swift` references. Confirm each.
- **R-N.M implementability** for the newly added Rs: pick the 5 most
  ambiguous of the +10 new requirements and trace IMPL-ability. Edge
  cases to probe:
  - What happens if `update.lock` exists but the holding process is
    dead (stale lock)? Is recovery defined?
  - What happens if `pending.json` exists but `<binary-dir>/.macprovider-cli.rollback-<uid>`
    is missing (partial state)? Is recovery defined?
  - If `recommended_binary_version` matches a release tag that exists
    on GitHub but the tarball asset is missing, what happens?
- **failure_class enum coverage**: the SPEC now enumerates ~10
  failure_class values. Is every R-N.M that says "MUST emit
  failure_class:X" mapped to a value that exists in the enum?
- **Observability size bound** (4096 bytes): is the bound on the
  serialized JSON object or on the JSON-escaped string? Does it include
  `last_autoupdate_event` wrapper keys or just the payload?
- **Backoff key**: backoff is keyed by `(target_version, failure_class)`.
  When the target_version changes (operator bumps), do old cooldowns
  clear, or do they linger?
- **Marker schema**: pending.json schema MUST include update_id,
  target_version, target_path, backup_path, size, mode, SHA-256,
  marker_deadline. Is `marker_deadline` an ISO timestamp or epoch
  seconds? Is `mode` octal int or decimal int?

### Lane C — Codex security

- **Did absorption introduce new attack surface?** New lock file,
  marker file, backup file all live under `$HOME/.local/share/macprovider/`.
  Is the parent-directory ownership and permission inherited from
  installer or set on first use? Trace.
- **Trust-state matrix gaps**: the new boundary requires "strongest
  configured authentication". Audit the matrix:
  - Tier2 unconfigured + v2 auth + pinned token → eligible? Or
    fail-closed because Tier2 is missing?
  - Tier2 configured + Tier2 failed + v2 auth ok → notify-only correctly?
  - Provisional + v2 auth + Tier2 → eligible or notify-only?
- **Revocation hook**: `minimum_safe_binary_version` and
  `revoked_binary_versions` are normative but ship empty in v0.1.0.
  Where do they come from in v0.2.0 — coord-pushed or compiled-in? If
  coord-pushed, attacker-controlled coord can override (so should be
  compiled-in baseline + coord can only narrow).
- **Key rotation**: dual-signed transition release — does the SPEC
  specify what happens if a provider receives a release signed ONLY
  under the new key while still trusting only the old key? Is "skip
  + notify operator" the answer, or "auto-rollback"?
- **`last_autoupdate_event` size**: 4096 bytes — does a maliciously
  crafted error string risk inflating the payload past 4096 (causing
  truncation that could leak the truncation oracle to coord)?
- **Symlink/hardlink rejection**: the new marker/backup hardening
  forbids symlinks. Does it also handle (a) bind mounts, (b) file
  ACLs / extended attributes, (c) Time Machine snapshots that could
  preserve a vulnerable backup version?
- **Crypto residual risk**: T-1/T-5 already accept residual risk for
  signed-malicious binaries. With the new revocation hook (T-8), is
  there a clean mitigation path post-discovery, or is the operator
  still on the hook for out-of-band recovery?

---

## Output format

(Same as r1 — see r1 prompt. Start with `VERDICT: ...`. Each finding:
ID with lane prefix + round (e.g., A-r2-H-1), Severity, SPEC section,
Bug, Fix.)

**Stay in your lane.** Convergent findings across lanes are still the
strongest signal — phrase findings so cross-lane matching is easy.
