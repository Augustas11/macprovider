# BYOM CLI Onboarding E2E

This harness exercises the provider-visible BYOM onboarding path through the
real `macprovider-cli` executable with hermetic loopback fixtures:

1. import provider credentials into the configured protected-file store;
2. discover a local Ollama-compatible catalog candidate;
3. evaluate the candidate locally without coordinator mutation;
4. dry-run an offer without coordinator mutation;
5. submit a coordinator-backed offer with the provider admission identity;
6. read coordinator admission status;
7. project catalog economics while money and settlement remain fail-closed;
8. withdraw the admission and verify withdrawn economics remain fail-closed.

Run from the repository root:

```bash
test/e2e/byom/run-cli-onboarding-e2e.py
```

Set `MACPROVIDER_CLI_BINARY=/path/to/macprovider-cli` to reuse an existing
binary. The script otherwise runs `swift build --product macprovider-cli`.

The fake coordinator uses `http://127.0.0.1:<port>` and the CLI accepts that
only when the harness sets
`MACPROVIDER_BYOM_ALLOW_INSECURE_LOOPBACK_COORDINATOR=1`; production coordinator
URLs remain HTTPS/WSS-only by default.
