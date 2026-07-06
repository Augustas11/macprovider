# SECURITY AUDIT PROMPT — Load/fairness harness kickstart PR 1

You are the SECURITY audit lane for `feat/load-harness-pr1-baseline`.
Work read-only. Do not edit files.

Audit the implementation of PR 1 from `specs/BUILD_SPEC_LOAD_FAIRNESS_HARNESS_KICKSTART_PROMPT.md`
with focus areas from BUILD_SPEC §7 SECURITY.

## Scope

Same in-scope files as `AUDIT_BUILD_SPEC_LOAD_HARNESS_PR1_IMPL_CODE_PROMPT.md`.

## Threats to look for

### PROD-side DoS (highest priority)

- `validateProdLoadGuard` in `scenario/schema.go`: does it correctly reject `buyers.count > 10` against ANY `*.streamvc.live` host? Try to construct a bypass:
  - IPv6 literal for `api.streamvc.live` — `url.Hostname()` unwraps brackets but the check is a suffix on lowercased hostname; verify.
  - Uppercase host `HTTPS://API.STREAMVC.LIVE` — verify lowercasing.
  - Non-standard port `https://api.streamvc.live:8443` — verify the port doesn't affect suffix match.
  - Authority-only URL with userinfo — verify userinfo doesn't sneak past `Hostname()`.
  - Trailing dot `api.streamvc.live.` — does the suffix still trip? (DNS treats these as equivalent; the guard should trip.)
- Does the guard fire in `sku-econ` mode too, or is it correctly scoped to `buyer-fleet`? sku-econ has its own host pin; guard scope is correct if it doesn't misfire on sku-econ but still catches buyer-fleet mistakes.
- `ALLOW_PROD_LOAD=1` is the only bypass. Are other truthy values like `"true"`, `"yes"`, `"TRUE"` inadvertently accepted? Only literal `"1"` should pass — verify.

### Token leakage

- The rig mints a fresh gateway API key (`mp_...`) via `seedGatewayAccountAndKey`. Grep every call to `Config.Logger` / `log.Printf` / `fmt.Errorf` under `internal/localrig/**` for anything that could echo the returned string. Same for provider tokens minted by `issueProviderToken`.
- Coordinator + gateway YAML files are written under the rig tempdir with mode `0o600`? Verify. World-readable configs leak `key_hash_secret` + `service_token` + `operator_key`.
- The rig tempdir cleanup: on `Shutdown`, are YAMLs + DBs unlinked, or left in `/tmp` for later inspection? Persisting to disk is a defensible tradeoff for triage, BUT if kept, the tempdir must be `0o700` and the token must not appear inside any file (grep `os.ReadFile` behavior on the seeded gateway DB before deletion is fine — key hash is HMAC, not the raw key).
- Load scenario 17's `expected_shape` / `description` doesn't inline any placeholder that could accidentally be filled by env expansion (grep for `${` in scenario YAML).

### Network exposure

- Every listener in `internal/localrig/**` binds to `127.0.0.1` (or `[::1]`). Grep for any bare port literal, `":8080"`, `"0.0.0.0"`, `net.Listen("tcp", ":`, or `http.Server{Addr: ":`. Any hit is a HIGH finding — a load rig accidentally bound on `0.0.0.0` is an open coord/gateway to the LAN during the run window.
- Coord + gateway configs use `bind_address: "127.0.0.1"` per `test/integration/harness_test.go:478,689`. Confirm the rig writes the same.
- Fake providers advertise `endpoint_url: http://127.0.0.1:<port>` — anything else is a hole.

### Buyer authentication

- The rig's minted `BuyerToken` is fresh per Start (not a static hard-coded token). Verify.
- The token is passed through `Scenario.Target.BuyerToken` — which the standard buyer runner puts in the `Authorization: Bearer <token>` header. Ensure the harness doesn't ALSO write the token to any artifact file (`run_meta.json`, `per_request.jsonl`, etc.). Grep for `BuyerToken` usage in `internal/artifact/**` and `internal/runmeta/**`.

### Subprocess spawn hygiene

- `exec.CommandContext` calls in `internal/localrig/**` inherit env via `os.Environ()`. If the parent shell has a `BUYER_TOKEN`, does it accidentally get read by the spawned coord or gateway? Coord/gateway don't read env for buyer tokens, but confirm there is no path where a rig helper (`coordinator-cli issue-token`) accepts an env override that would leak Pearl credentials.
- `go build` runs with `CGO_ENABLED=0`. Confirm — a rig build that pulls system libc pins the reproducibility.

### Rig authorization

- The rig auto-mints a gateway API key without any user confirmation. Rig lifecycle is scoped to a single scenario run, so this is fine. Confirm the token is NOT persisted beyond `Rig.Shutdown()` — no write to `~/.config/macprovider/*`, no export.

## Method

1. `git diff origin/main...HEAD -- test/network-harness/` and read every changed file.
2. Grep patterns above; each hit becomes a candidate finding.
3. Prove or disprove each candidate by tracing the code path end-to-end.
4. For each real finding, cite `file:line`, severity, and demonstrate the attack scenario in one paragraph.

Return findings ordered by severity with file:line references.
If no issues remain, say `No findings.`

End with:
`STATUS: SECURITY lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>`
