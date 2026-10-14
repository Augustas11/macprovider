# Security Policy

## Reporting a vulnerability

Please report security issues privately through GitHub:

1. Open the repository's **Security** tab.
2. Choose **Report a vulnerability** to open a private advisory.

Do not open a public issue, pull request, or discussion for a suspected
vulnerability.

Useful details:

- the affected component (`phase3-binary/` provider CLI or Malibu app,
  `phase4-coordinator/`, `phase5-gateway/`, `phase7-verify/`, installer, or
  release tooling) and version or commit;
- steps to reproduce, or a proof of concept;
- the impact you expect (for example credential exposure, billing or
  settlement manipulation, receipt forgery, or provider impersonation).

We acknowledge each report and keep the reporter updated through the private
advisory until a fix ships.

## Scope

In scope:

- the provider CLI, Malibu app, and installer (`get.malibu.tech/install.sh`);
- the coordinator (`coordinator.malibu.tech`) and buyer gateway
  (`api.malibu.tech`);
- receipt signing and verification (`macprovider-verify`);
- release signing, update, and catalog feeds.

Out of scope:

- denial of service by volume against production endpoints;
- findings that need a compromised provider Mac or operator host;
- reports from automated scanners without a demonstrated impact.

## Supported versions

Security fixes land on `main` and ship in the next provider CLI and
service release. Providers on autoupdate receive them automatically.

## Handling secrets

Never commit API keys, private keys, payout keys, `.env` files, buyer prompts,
provider tokens, or receipt bundles with private contents. If you find a
secret in this repository, report it through the private channel above.
