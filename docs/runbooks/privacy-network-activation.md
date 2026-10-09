# Eligible-network privacy Beta activation

Authority: SPEC-049 §8.3, decision-log Entry 251. This is a configuration-only
activation of released CLI224 using the existing reviewed runtime. It does not
authorize another CLI or coordinator release or conformance promotion.

Read `pearl-coordinator-rollout.md` first. The operator authorizes activation,
one session holds Pearl, and public handbacks omit internal inventories and
provider identifiers. Reuse the signed baseline and source acceptance in
`docs/releases/cli-release-train.md`; do not rerun unchanged qualification.

## Approve the existing signed identity

Configure `PEARL_SSH` privately. From clean reviewed `origin/main`:

```bash
bash scripts/ops/privacy-activate.sh status
bash scripts/ops/privacy-activate.sh next
MACPROVIDER_OPS_OWNER=<session-label> bash scripts/ops/privacy-activate.sh next --run
```

Expected downtime: one coordinator restart, typically 13–40 seconds; no
database copy or provider restart. The entry point verifies the signed public
224 metadata using the committed release key, binds the exact SPEC identity,
takes the live actor lock and both remote deploy locks, replaces only the
superseded approval set, validates effective base plus overlay as the service
user, then restarts and checks health. Failed validation restores the previous
block without restarting; failed restart restores it and checks recovery.
Identity/device overrides, denial/quarantine controls, directory key, catalog,
ordinary traffic configuration and all other settings are preserved. Approval
expires at `2026-10-20T00:00:00Z`; no loader extends it. Existing and newly joining
eligible signed providers enroll automatically. Opt-outs and other releases do
not become eligible by this action.

## Buyer confirmation

Use the reviewed reference `phase5-gateway/cmd/relay-blind-client` on the buyer
host, with its buyer API key supplied privately via `MACPROVIDER_API_KEY` and
either an explicit identity pin or an independently obtained directory public
key. Do not publish credentials, machine IDs or private prompt/completion
content. Use both stream and nonstream requests through the public gateway;
the request body's `max_tokens` must equal `--max-output-tokens`. The client
must decrypt the response and report `privacy class satisfied`; verify private
settlement is `relay_blind_settled` and ordinary traffic remains healthy.
Use the pinned Studio first, then the signed directory so the confirmation
proves automatic enrolled-provider selection rather than just a manual pin.
Approval or a green health check alone does not mean activation is complete.
Record sanitized results and live changes in the release-train handback.
The next ops step performs four bounded confirmations (pin/directory,
stream/nonstream). Configure `PRIVACY_BUYER_CLIENT`, `BUYER_TOKEN_FILE`,
`PRIVACY_BUYER_PIN`, `PRIVACY_DIRECTORY_PUBLIC_KEY` and `GATEWAY_URL` privately,
then run `next --run` again. This does not replace the settlement receipt check.

## Immediate rollback and expiry

On an identity/key admission error, plaintext downgrade, redaction failure or
incorrect private settlement, disable durably using the same effective config:

```bash
PRIVACY_ACTIVATION_DISABLE=1 bash scripts/ops/privacy-activate.sh next
PRIVACY_ACTIVATION_DISABLE=1 MACPROVIDER_OPS_OWNER=<session-label> bash scripts/ops/privacy-activate.sh next --run
```

This uses the released coordinator CLI, takes the actor lock, and needs no
service restart. Private requests fail closed; ordinary traffic continues.
At expiry, normal `status`/`next` drives a withdrawal step: durable disablement
first, then class configuration off and the expired approval removed under the
same lock set. A superseding approval is never removed blindly. Runtime code
identity expiry itself already rejects private admission at the deadline.
Quarantine/revoke compromised identities through the reviewed operator CLI;
never rewrite durable enrollment records directly. Release the session's actor
lock after the committed handback:

```bash
bash scripts/ops/live-lock.sh release <session-label>
```
