Lane: SECURITY REVIEW, focus DOWNGRADE-ATTACK RESISTANCE. Assume an attacker
may control or compromise the coordinator, a network path (TLS terminates at
the coordinator), the GitHub release listing/mirror, or local unprivileged
files. Can any input make a provider install a release older than the running
one other than exactly the recommended set's version after an exact
revocation of its own build? Check: binding of the revocation signal to the
provider's own reported set; type confusion of the JSON flag; parsing of
compatibility ids (leading zeros, repository, version extraction); the
compiled-in floor; signed policy minimum/revoked enforcement; whether any
verification step (signature, SHA-256, manifest/artifact index, staged binary
version, code identity, Malibu bundle) is skipped or weakened for a
downgrade; the discovery and manual-update rails; rollback-marker behaviour
when the older target is unhealthy (rollback to V, loops); and the ops
rollback step (argument injection, refusing to revoke the post-edit target,
policy-mismatch fail-closed). State the residual risk under coordinator
compromise and whether the spec's threat model T-4 records it accurately.
