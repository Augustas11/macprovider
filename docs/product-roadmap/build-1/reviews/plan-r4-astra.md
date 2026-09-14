# Independent adversarial Build 1 plan gate — revision 4 approval rebind

Verdict: **APPROVED FOR IMPLEMENTATION**. Open findings: **0 Critical, 0 High, 0 Medium, 0 Low**.

Approved exact inputs:

- Base: `422fc2f13fc62c1ff8987522f822d9ef856e4a96`.
- Explicit unmerged prerequisite: PR #1468, `f5edeaebfb6c712a2cb6dced9020c8c78ed1053e`.
- `plan-r4.md` SHA-256: `a5c7a56a68d3ea111289b122cd0a44d41aa4690900ed6f4b6257cf75c3c36e0d`.
- `test-spec-r4.md` SHA-256: `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be`.

The reviewer independently checked both hashes and the complete diffs against the approved r3 pair. The plan changes only its revision title and replaces the erroneous SPEC-043 adoption citation with SPEC-001 §6.14a / BUILD_SPEC_953 BS953-R015, SPEC-023 recommendation and SPEC-011 warm-swap boundaries. The test specification changes only its revision title and paired plan filename. `diff` exit status 1 reports these expected differences; no runtime scope, implementation requirement or acceptance criterion changed.

R3 L1 is closed. All findings from r1/r2 remain closed under the reasoning and evidence recorded in [the full r3 review](plan-r3-astra.md). That full-plan approval is rebound to the exact r4 pair above. No outcomes were removed, weakened or converted into fixture-only acceptance. Only this review file was written; earlier review records remain unchanged.

This is plan approval only. Normative amendments must precede the affected runtime changes. Implementation still requires the specified targeted and surface verification plus complete cumulative code, security and architecture audits, including the pinned prerequisite and migrations, with zero Critical/High/Medium findings.

Physical B1-T10 remains mandatory and unproven: actual MLX preparation, measured recommendation, explicit activation, coordinator-authoritative admission, buyer inference, persisted receipt verification and settled accounting on the specified Mac. Fixture keys/references, deterministic runner tests, catalog estimates or missing qualified feed/reference material cannot satisfy that physical requirement. Operator custody isolation, separate release qualification and the exclusion of production activation remain unchanged. No tests, physical journey, release or production operations were performed for this rebind.
