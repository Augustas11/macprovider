You are the CODE lane auditor for PR #1934 (Augustas11/macprovider), branch ops/release-registrations, checkout /Users/augstar/macprovider-release-registrations. Review the COMPLETE diff `git diff origin/main...HEAD` and the code it touches. Do not edit files and do not contact Pearl or GitHub.

Context: CLI 1.8.230 shipped while Pearl approved only the 1.8.224 privacy code identity, so upgraded providers' privacy advertisements were rejected for ~12 h unnoticed; promotion also kept failing for a missing signed tag. This PR adds train steps and gates so every CLI release registers itself and promotion is refused until it has, plus coordinator metrics and a rollout check.

Lane focus: correctness of the new cli-release.sh steps and gate (privacy_release_identity, registrations, release_tag), the Pearl-side helper scripts/ops/lib/release-registrations.py, done/refuse detection, idempotency, partial failure (JSON written but .sig not), quoting/injection in ssh commands, the coordinator metrics and verify_live_rollout logic (false positives that block rollout forever, false negatives), test adequacy in scripts/ops/test-entrypoints.sh.

Output: findings with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, failure scenario, fix; say "pre-existing" when relevant. End with "C/H/M/L = n/n/n/n". Gate: 0 C/H/M.
