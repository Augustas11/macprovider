# B6 — Close the identity re-registration wash

**Type**: deferred design brief — a FUTURE separate SPEC with its own three-lane audit loop. Analysis, not a commitment.

> **Verified against `origin/main` @ `51a60c23` (2026-07-28)** — see [VERIFICATION-2026-07-28.md](VERIFICATION-2026-07-28.md). Status: **VALID**.

**Status (2026-07-29)**: complete in PR #812 at `2cd5bd7f` ("Close
fresh-provider registration wash with invite admission").

**Gated on**: complete.

## Problem / shape
Sanction *storage* is already correct (`provider_id`-keyed, durably persisted).
The real gap: a sanctioned operator re-registers with a fresh keypair for a new
`provider_id`, because registration is open (`referrals.require_for_registration:
false`, `coordinator.yaml:116`; `provider_id` is bound to `identity_pubkey`, `apptrack.go:313`). This is
a **policy** question, not a storage one: gate registration (invite/operator
approval), or bind sanctions to a durable admission root above the credential.
The trade (roadmap §11 Q5): does closing registration cost more supply than the
wash costs in abuse?
