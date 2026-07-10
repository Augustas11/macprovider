# ISS-185 R1 — security-lane audit prompt

Audit target: the diff on branch `fix/iss-185-cold-start-404-to-503`
against `origin/main`. The change adds an append-only model-id
accumulator (`Registry.seenModelsLifetime`, capped at 4096) that
survives provider disconnect, to satisfy SPEC-002 § 7.2's 404 vs
503 distinction.

## Scope of this lane

You are the **security lane**. Focus on:

- **DoS via model-id flooding.** Providers control the model id they
  advertise (`hello.model_id`, heartbeat updates). A misbehaving or
  compromised provider could churn through synthetic model ids
  to consume the lifetime accumulator's 4096-slot cap and degrade
  the SPEC-002 § 7.2 contract for legitimate models that arrive
  later.
  - Is the per-provider cap (32) still in effect to bound how many
    distinct ids ONE provider can contribute?
  - Is there a per-second / per-minute insertion rate that an
    attacker can exploit? Look for the heartbeat path's model-id
    handling.
- **Memory exhaustion.** 4096 string entries × ~64 byte avg model
  id ≈ 256KB worst case. Acceptable, but verify:
  - The accumulator is per-Registry, not global. Multiple Registry
    instances would multiply.
  - Are there callers that allocate multiple Registry instances?
- **Cap-reached behavior.** When the lifetime cap is reached, the
  silent-drop degrades cold-start races back to 404 for the dropped
  ids. Is that the right failure mode (silent permissive) vs
  something louder (warn-log, metric)?
- **Read-side amplification.** ModelKnown iterates
  `seenModelsLifetime` with case-insensitive `strings.EqualFold`.
  At the 4096 cap, that's a 4096-step string compare per buyer
  request 404-vs-503 decision. Is that on the hot path? If so, is
  the cost bounded?
- **Side channels.** Can an attacker probe whether a model id was
  ever advertised by timing the 404-vs-503 response or by direct
  observation? (Spec already publishes this via `/v1/models`, so
  probably not a new leak — confirm.)
- **Provider impersonation.** A new provider connecting with a
  reused provider_id (session replacement) doesn't reset the
  lifetime accumulator. Is that correct? (Yes per SPEC § 7.2 — the
  pool retains memory across sessions. But confirm no privilege
  state is implicitly trusted by virtue of being in the
  accumulator.)

Out of scope for this lane (other lanes own):

- **Code lane:** Go idiom, lock placement, test coverage.
- **Architect lane:** spec consistency vs SPEC-002 § 7.2, naming.

Do NOT duplicate their work.

## Files in the diff

```
phase4-coordinator/internal/pool/provider.go
phase4-coordinator/internal/pool/provider_test.go
phase4-coordinator/internal/buyer/server_test.go
```

Useful command:
```
git diff origin/main -- phase4-coordinator/
```

## Scope: PR-INTRODUCED findings only

Per the locked three-lane convergence convention: this audit gates
this PR on findings INTRODUCED by the diff against origin/main.
Pre-existing vulnerabilities visible to your audit but NOT modified
by this PR are out of scope for blocking convergence — they may be
worth filing as separate issues but they do NOT block this PR.

Example of in-scope: a provider can churn model ids to consume the
lifetime cap and degrade SPEC § 7.2 for legitimate models.

Example of out-of-scope: the heartbeat path doesn't authenticate
the provider's model_id claim against any catalog — that's a
pre-existing trust model, file separately if it's wrong.

## Output format

For each finding:

- **Severity:** CRITICAL | MAJOR | MINOR | NOTE
- **File:line(s):** exact reference
- **Threat model / attack surface:** one-sentence statement
- **Evidence:** quote relevant code
- **Recommendation:** specific change

Severity definitions:

- **CRITICAL:** exploitable now or under realistic adversary
  assumptions. Must fix before this lands.
- **MAJOR:** weakens defense in depth; likely to be problematic
  at scale or in beta.
- **MINOR:** hardening opportunity.
- **NOTE:** future-proofing observation.

End with:
```
Found: <N> CRITICAL, <N> MAJOR, <N> MINOR, <N> NOTE.
```

Keep response under 800 words.
