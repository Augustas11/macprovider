# Headless provider updates

`headless_fleet` providers run as system-domain LaunchDaemons and keep their
credentials in protected files owned by the fleet user. They do not use the
consumer LaunchAgent autoupdater.

When a newer release is recommended, the provider remains available and emits:

```text
phase: eligibility
outcome: skipped
reason: headless_operator_update_required
```

This is an operator handoff, not an update failure. It must not produce a
cooldown, drain the provider, download release bytes, or invoke a user-domain
reload helper.

## Supported update path

Use only a protected signed acceptance bundle produced by the repository's
`Sign private acceptance candidate` workflow. Run the bundled installer as the
existing non-root fleet user over SSH with:

- `MACPROVIDER_HEADLESS=1`;
- `MACPROVIDER_NO_PROMPT=1`;
- `MACPROVIDER_HEADLESS_USER` set to that fleet user;
- all six acceptance identity fields set to the exact bundle version,
  candidate commit, control commit, run ID, and run attempt;
- `MACPROVIDER_CREDENTIAL_STORE=protected_file` and the incumbent protected
  credential root.

The candidate must be strictly newer than the installed compatibility set. Do
not use a public mutable `latest` download as a headless substitute, fabricate
an install manifest, copy bearer/key files into a new profile, or point the
consumer updater at `/Library/LaunchDaemons`.

Before cutover, capture only redacted evidence:

1. installed and running CLI versions;
2. provider ID digest or approved short prefix, never the full identity in a
   public artifact;
3. `credentials verify` status (`ready` and `restart_safe`, without paths or
   credential bytes);
4. system LaunchDaemon state and absence/presence of pending recovery state;
5. acceptance-bundle SHA-256 and exact provenance pins.

After cutover, prove that the installed and running versions match the signed
target, the provider ID did not change, protected credentials still verify,
the service returned to buyer-serving, and restart/reboot persistence works
without a GUI login.

## Noncanonical incumbents

A provider created by an older smoke or manually staged headless flow may run
from a noncanonical support directory and may lack the installer manifest or
managed LaunchDaemon copy. The consumer autoupdater correctly refuses that
shape. Preserve the node and use the signed headless installer migration path.

For the historical SSH-smoke topology only, set both:

- `MACPROVIDER_ADOPT_HEADLESS_INCUMBENT=1`;
- `MACPROVIDER_INSTALL_DIR` to the incumbent support directory reported by the
  root LaunchDaemon.

The bridge is available only with the protected signed acceptance bundle and
all its provenance pins. It requires a loaded system provider service, an
absent managed provider plist, an absent install manifest, and no unmanaged
root watchdog. It descriptor-validates the root-owned `0644` plist against the
exact historical program, arguments, user, config, credential root, environment,
working directory, logging paths, and keepalive shapes. Before any live cutover,
it writes a byte-identical, user-owned managed plist for transactional rollback.
It does not change the running service and does not create an install manifest.

Any mismatch fails before mutation. Do not repair it by inventing metadata,
loosening the accepted plist shape, copying credentials, or silently trusting
the running path. A later successful signed installer transaction creates the
normal manifest and canonical provider/watchdog LaunchDaemons.
