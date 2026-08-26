# Acceptance candidate signing key

`acceptance-candidate-signing-public.pem` is the public half of a dedicated
P-256 key used only for private, short-lived acceptance-candidate envelopes.
It is deliberately distinct from the permanent production release key.

Before merging the acceptance workflow, a release administrator must run this
once from a clean checkout:

```bash
bash scripts/provision-acceptance-signing-key.sh Augustas11/macprovider
```

The command creates the private key only inside a mode-0700 temporary
directory, pipes it directly into the `production-release` environment secret
`MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM`, derives
`security/acceptance-candidate-signing-public.pem`, and securely removes the
temporary directory on exit. Review and commit only the public key. Never copy
the private key into a worktree, log, issue, artifact, or commit.

SPEC-043 production-release approver keys are separate. Register only an
operator-supplied P-256 public key with
`scripts/register-spec043-production-release-key.py`. The committed keyring at
`spec-043-production-release-keyring.json` stays empty/fail-closed until that
happens. Never generate a SPEC-043 launch key in this repository, and never
reuse `MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM` or
`security/acceptance-candidate-signing-public.pem` to sign
`PoolPromotionTransitionV1`.

The production release key still signs the inner compatibility manifest so an
accepted installation can start and reboot without an expiring runtime bypass.
The dedicated acceptance key signs the mandatory outer envelope and
acceptance-only Pearl metadata. `checksums.txt` has no production signature,
so this private artifact is not accepted by the normal release/update path.
