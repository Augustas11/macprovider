# BUILD_SPEC_045_PHASE_1_ENDPOINT_SHELL

Implement the non-proxying local endpoint shell for SPEC-045. This slice establishes the command, listener, local authentication material, status discovery, and credential custody foundations. It must not forward chargeable requests upstream.

## Target result

`malibu-cli consume` starts a macOS loopback-only HTTP/1.1 process, prints redacted setup information, writes a user-private active endpoint descriptor, supports `malibu-cli consume status`, and loads the upstream buyer credential through the SPEC-045 source order without exposing token material.

## Required implementation shape

1. Add the `consume` subcommand and startup validation:
   - default bind address `127.0.0.1`;
   - default port `11435`;
   - reject port `0`, port collision, bind failure, wildcard, LAN, VPN, public, Unix-domain, hostname-resolved non-loopback, and interface-scoped exposure with `local_bind_rejected`;
   - allow IPv6 loopback `::1` only if explicitly supported;
   - normalize `localhost` to an accepted loopback literal when supported.

2. Generate and protect the local token:
   - per-run token from at least 128 bits of CSPRNG input;
   - accepted local auth headers are `Authorization: Bearer`, `api-key`, and `x-api-key`;
   - verifier uses HMAC-SHA256 keyed by a per-run secret distinct from the token, or a stronger keyed fixed-length construction;
   - malformed bearer syntax, conflicting accepted auth headers, token-length mismatch, missing token, and wrong token all fail through the same redacted path.

3. Implement credential-source loading:
   - source order: `--credential-file <path>`, `MACPROVIDER_HTTP2_API_KEY_FILE`, `~/.config/macprovider/buyer-api-key`, `MACPROVIDER_HTTP2_API_KEY`, `MP_API_KEY`, `BUYER_TOKEN`;
   - explicit file sources override default file; default file precedes raw-key environment variables;
   - credential-source class values are `explicit_file`, `default_config_file`, `environment`, and `missing`;
   - reject raw API keys as command-line flag values with `local_credential_flag_rejected`;
   - validate file ownership, permissions, parent directory safety, symlink ambiguity, no-follow open, file descriptor identity, reload metadata changes, and zeroization of superseded credentials.

4. Implement startup/status output:
   - startup status goes to stderr, structured machine output only to stdout when an explicit future flag defines it;
   - print local base URL, upstream gateway origin, model allowlist summary, budget mode, unpriced override state, and credential-source class;
   - never print upstream token, local token outside setup/descriptor, raw prompts/completions, usernames, expanded credential paths, secret-bearing paths, or full upstream errors.

5. Implement active endpoint discovery:
   - descriptor path `$HOME/Library/Application Support/macprovider/consume/active-endpoint.json`;
   - descriptor lock `$HOME/Library/Application Support/macprovider/consume/active-endpoint.lock`;
   - descriptor contains only bound loopback URL, process id, process launch id, started-at timestamp, ledger path class, and local token or same-security token reference;
   - parent directories are current-user-owned, not other-user-writable, and not symlink-ambiguous;
   - descriptor write is atomic with user-only temp-file permissions;
   - concurrent local endpoint instances fail with `local_active_endpoint_exists`;
   - stale descriptors are ignored using process id plus launch id.

6. Implement `malibu-cli consume status` without proxying:
   - idle/no endpoint returns nonzero `local_endpoint_not_running`;
   - active status reports schema version, launch id, bound URL, upstream origin, credential-source class, credential state, model allowlist, local-auth state, budget placeholders, ledger path class, active request count, pricing trust placeholder, no-store status semantics, and redacted error ring shape;
   - no raw token, prompt, completion, credential path, receipt, upstream body, hostname, OS username, hardware serial, MAC address, stable hardware UUID, or interface name appears in status.

## Acceptance tests

- default startup and shutdown;
- port `0`, port collision, non-loopback bind, and localhost normalization;
- stdout/stderr separation and startup redaction;
- credential-source precedence and raw-key flag rejection;
- credential file permission, ownership, symlink, no-follow, reload, deletion, and zeroization behavior;
- local token generation, descriptor permissions, HMAC verifier, malformed/conflicting auth-header rejection;
- active descriptor lock serialization, stale descriptor handling, and `consume status` no-endpoint behavior;
- status schema, no-store behavior, bounded error ring shape, and redaction.

## Non-goals

- Do not implement upstream proxying.
- Do not implement budget admission or ledger mutation.
- Do not expose browser CORS access.
