You are auditing the Phase C IMPL of SPEC-004 Pillar C from a
SECURITY lens.

# Repository context

- Branch `feat/spec-004-pillar-b` (bundled-PR mode), HEAD `761baaa`
  (Phase C step 2). Phase C wires server.go through the new
  routing.EligibleCandidates helper.

# Audit scope (SECURITY lens)

- **No breaker-held / state-ineligible bypass.** SPEC-002 FR-P5
  and FR-P11a recovery-hold checks MUST gate every candidate
  before selection. The refactor moves the inline state check
  into eligibilityCtx.ProviderMatchesRequest (combined with
  model/class match). Verify no path lets a not-ready /
  breaker-held / recovery-held provider into the result set.
- **Excluded set integrity.** F-4 failover + SPEC-004 retry share
  one excluded set per FR-SR-19. Verify the keyer-callback
  pattern does not let two semantically-distinct providers
  collide on the same key (key derivation should be the same
  routeKey buyer.go uses elsewhere — provider_id + assigned_id).
- **No selection of excluded providers.** Verify the Excluded.Has
  short-circuits BEFORE any other check (excluded providers do
  not even fire tier2 logging side effects — important for not
  leaking "provider X failed verification" info on a request
  where X was already excluded for a prior fault).
- **Tier2 verification preserved.** All tier2 require_* gates
  (hash_verified, encrypted_leg, attestation) MUST still gate
  selection identically. Logging emissions
  (LogHashRequiredProviderExcluded /
  LogEncryptedLegRequiredMissing) MUST fire from the same
  branches.
- **Quota soft-filter preserved.** Quota was always a SOFT filter
  (drives 429 only when EVERY otherwise-eligible candidate is
  blocked). Verify no change inadvertently makes quota a hard
  filter that returns 503 instead.
- **No new buyer-input paths.** Phase C introduces no new buyer
  headers / body fields / config keys.
- **Logging side-effect parity.** Verify
  tier2.LogHashRequiredProviderExcluded and
  tier2.LogEncryptedLegRequiredMissing are not double-fired or
  silently dropped by the refactor.

# Severity vocabulary

- CRITICAL = money-path vulnerability (selection of ineligible
  provider, F-4 / retry deselection bypass).
- HIGH = vulnerability an implementer would likely open.
- MEDIUM = precision improvement preventing unlikely-but-possible
  misimplementation.
- LOW = wording or framing.

# Output format

```
Location: <file:line or symbol>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence proposed change>
```

End with `Tally: C/H/M/L`. Goal: 0/0/0/0. Any HIGH or MEDIUM blocks
merge.

Read the BUILD prompt §Phase C + 4 routing files + the refactored
selectProviderExcluding + relevant origin/main `internal/buyer/` and
`internal/pool/` code before writing any finding. Do not speculate;
cite quotes.
