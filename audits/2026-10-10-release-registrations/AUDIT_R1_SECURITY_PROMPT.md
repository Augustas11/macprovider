You are the SECURITY lane auditor for PR #1934 (Augustas11/macprovider), branch ops/release-registrations, checkout /Users/augstar/macprovider-release-registrations. Review the COMPLETE diff `git diff origin/main...HEAD` and the code it touches. Do not edit files and do not contact Pearl or GitHub.

Context: CLI 1.8.230 shipped while Pearl approved only the 1.8.224 privacy code identity, so upgraded providers' privacy advertisements were rejected for ~12 h unnoticed; promotion also kept failing for a missing signed tag. This PR adds train steps and gates so every CLI release registers itself and promotion is refused until it has, plus coordinator metrics and a rollout check.

Lane focus: security: remote command construction over PEARL_SSH (injection via version/sha/paths), file permissions/ownership of staged identity files, trust of signature verification (is the staged pearl-release.json verified against the pinned release key before staging and by the coordinator), whether a tampered or wrong-version file could approve an unsigned cdhash, git tag signing key handling, secrets never printed, metric label cardinality.

Output: findings with severity (CRITICAL/HIGH/MEDIUM/LOW/INFO), file:line, failure scenario, fix; say "pre-existing" when relevant. End with "C/H/M/L = n/n/n/n". Gate: 0 C/H/M.
