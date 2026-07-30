# Review: #769 hello-gate reconciliation + sticky risk-acceptance (docs-only PR)

Review the FULL diff: `git diff origin/main...HEAD` (single commit; docs/spec
only — SPEC-032 v0.2-draft corrections, a new runbook
`ops/runbooks/seam-769-gate-posture-2026-07-27.md`, findings.md P2-4 update).
This is a SECURITY-lens documentation review, not a code audit.

Context: the live Pearl coordinator was probed read-only on 2026-07-27. Facts
recorded: the running process loads --config-overlay /etc/macprovider/coordinator.pearl-overlays.yaml, which EXPLICITLY sets require_autotune_hello_gate: false (hello-gate OFF; corrected from an earlier zero-value-absent reading); canary timer inactive + DISABLED sentinel (accepted P0 #584
exception); `warmup_gate_enabled` false live vs true committed (drift,
surfaced not auto-fixed); `sticky_enabled` true (so the same-account TTFT
side-channel risk-acceptance the issue requires is written, with a
MUST-re-evaluate trigger before OpenRouter enrollment).

Assess:
1. Is the risk-acceptance note technically sound — is the side-channel
   description accurate to how sticky affinity + KV residency work in this
   codebase (spot-check the cited mechanisms: X-MacProvider-Conversation
   routing, account-scoped sticky keys, #762 fingerprint keying)? Does it
   under- or over-claim the isolation properties? Is the OpenRouter
   marketplace-credential re-evaluation trigger correctly reasoned (many end
   users behind one account credential)?
2. Does the SPEC-032 correction introduce any NEW inaccuracy (verify the
   corrected claims against the code: is the gate really config-gated
   zero-value-off when the section is absent)?
3. Does the runbook leak anything sensitive (paths, tokens, infra details
   beyond what existing committed runbooks already expose — compare with
   ops/runbooks/production-exception-register.md conventions)?
4. Is the warmup-drift surfacing framed safely (does it avoid instructing a
   dangerous action; is the "next deploy flips it ON" consequence claim
   accurate given how the deploy scripts treat dist/coordinator.yaml —
   check deploy tooling / check-deploy-config.sh)?

Report severity CRITICAL / HIGH / MEDIUM / LOW / INFO with file:line and
concrete reasoning, ending `VERDICT: PASS (0 critical, 0 high, 0 medium)` or
`VERDICT: FAIL (<counts>)`.
