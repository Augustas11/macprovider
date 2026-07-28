# B4 — Probationary admission

**Type**: deferred design brief — a FUTURE separate SPEC with its own three-lane audit loop. Analysis, not a commitment.

**Gated on**: G0 + a pricing/settlement design. The largest brief; must NOT be bundled with anything. Design sketch: roadmap §6.

## Shape the SPEC must resolve (before any code)
1. **A new per-(provider, model) probation state** — `pool.Tier` is a
   per-provider scalar *and already* the canary sanction state
   (`pool/provider.go:1352`, `TierProvisional`→ban), and there is a second
   unrelated `rewards.TierProvisional`; neither can be reused.
2. **Pricing + settlement** — probation traffic proposed discounted/unbilled, but
   unbilled traffic yields zero `provider_credits` and can void payout under
   `minPayoutCredits` (`payout.go`), and no discount mechanism exists. Spans
   `internal/billing/`, `phase5-gateway/` (`usage_events`, `ReservationSettlement`),
   and a SPEC-022/005/006 amendment. Candidate direction: bill the buyer full,
   escrow the provider share, release on promotion / forfeit on demotion.
3. **An absolute numeric exposure budget** — relative caps give zero dilution at
   `pool_size: 1`.
4. **Anti-self-dealing that binds** — the "≥2 payer accounts" rule is a
   two-account speed bump while registration is open (B6); the canarycorr prior
   art is provider-side, not payer-side.
5. **Grandfathering** — existing providers are not retroactively placed in probation.
6. **Cross-class promotion** — observed latency cannot authorize a cross-model-class
   raise (substitution beats honest service); until B9 supplies a
   model-discriminating signal, a cross-class raise rests on capacity + a named,
   logged, capped, buyer-visible operator grant.
