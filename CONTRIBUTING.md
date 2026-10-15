# Contributing to MacProvider

Thanks for your interest. This guide covers building, testing, and opening a
pull request. [AGENTS.md](AGENTS.md) is the full repository manual and applies
to human and agent contributors alike.

## Prerequisites

- Apple Silicon Mac on macOS 14+ for the provider (`phase3-binary/`), with
  Xcode command line tools and Swift tools 5.9+.
- Go 1.26.x for the coordinator, gateway, verifier, and integration tests.
- Python 3 for governance and release scripts.

Do not add new dependencies without discussing them in an issue first.

## Build

```bash
make build-linux
cd phase3-binary && swift build
cd phase4-coordinator && go build ./...
cd phase5-gateway && go build ./...
```

## Test

Run the smallest relevant test while you iterate, then the gate for the
surface you changed:

```bash
make test                  # coordinator, gateway, integration, and dist checks
make vet                   # go vet for coordinator, gateway, integration
make test-coordinator      # coordinator Go tests
make test-gateway          # gateway Go tests
make test-integration      # cross-service integration harness
make test-dist             # release/deploy/script regression suite
make lint-coordinator      # golangci-lint with the repo config
cd phase3-binary && swift test
```

Single tests:

```bash
cd phase4-coordinator && go test ./internal/billing -run TestName
cd phase5-gateway && go test ./internal/router -run TestName
cd test/integration && go test -run TestName -race -count=1
cd phase3-binary && swift test --filter TestName
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_upstream_watch
```

Report the exact command and result in your pull request. An interrupted,
skipped, or timed-out run is not a pass.

## Code style

- Go: `gofmt`, `make vet`, and `make lint-coordinator` where relevant.
- Swift: follow the existing SwiftPM layout and strict concurrency settings.
- Python, shell, and Node scripts used by CI or release automation must stay
  noninteractive.
- Follow neighbouring patterns and do not reformat unrelated files.
- Comments explain non-obvious constraints; they do not restate the code.

## Specs and governance

Behaviour is governed by the SPEC corpus in [specs/](specs/), with
`specs/AUTHORITY.json` and `specs/CONFORMANCE.json` as the machine-readable
manifests. Read the matching `specs/SPEC-NNN-*.md` before changing an area.
When a change edits a canonical SPEC, bump its patch version and add a change
log entry, then regenerate and check the index:

```bash
python3 scripts/gen_spec_index.py
python3 scripts/check_spec_governance.py --base-ref origin/main
```

## Pull requests

- One branch and one pull request per task. Keep the diff focused.
- Write `Related: #N` for issues the PR does not fully complete; only use a
  closing keyword when the PR finishes the issue.
- Fill in the SPEC governance declaration from the
  [pull request template](.github/PULL_REQUEST_TEMPLATE.md). CI validates it
  with:

  ```bash
  python3 scripts/check_spec_pr_declaration.py \
    --event /tmp/pr-event.json --base origin/main --head HEAD
  ```

  Fill it honestly: `behavior_change` and `contract_change` are `"none"` or
  `"yes"`; a behaviour change names the specs, requirement IDs, authority
  domains, arbitration verdicts (`CODE_BUG`, `SPEC_BUG`, `DECISION_REQUIRED`,
  `DUPLICATE_AUTHORITY`, `UNKNOWN`), tests, and journeys (or
  `"not-required"`).
- Changes under `phase4-coordinator/internal/{billing,buyer,auth,requestlog}/`
  and `phase5-gateway/internal/{router,auth}/` need careful tests and review.

## Security

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
Never commit secrets, `.env` files, private keys, or operator credentials.

## License

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
