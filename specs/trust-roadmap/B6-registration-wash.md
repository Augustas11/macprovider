# B6 — Close the identity re-registration wash

**Type**: deferred design brief — a FUTURE separate SPEC with its own three-lane audit loop. Analysis, not a commitment.

**Gated on**: a registration-policy decision. Not G0.

## Problem / shape
Sanction *storage* is already correct (`provider_id`-keyed, durably persisted).
The real gap: a sanctioned operator re-registers with a fresh keypair for a new
`provider_id`, because registration is open (`referrals.require_for_registration:
false`; `provider_id` is bound to `identity_pubkey`, `apptrack.go:313`). This is
a **policy** question, not a storage one: gate registration (invite/operator
approval), or bind sanctions to a durable admission root above the credential.
The trade (roadmap §11 Q5): does closing registration cost more supply than the
wash costs in abuse?
