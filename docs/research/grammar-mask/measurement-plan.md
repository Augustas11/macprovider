# Grammar-mask measurement plan

Related: #2107. Hardware measurements are deferred by the operator. This is a
plan, not new qualification or evidence of live capability. Run only on the
designated Studio after host identity is verified; no model loads or benchmarks
are authorized by this document alone. Use the existing isolated lab window,
with an unreleased candidate isolated by `--no-join`. Never connect that binary
to Malibu or replace the live provider.

Existing evidence to inspect before scheduling a run:

- `docs/evidence/glm53-flash-t4-2026-10-17/final-mtp/e2e-20261017T103928Z/mtp-e2e.json`
- `docs/evidence/glm53-flash-t4-2026-10-17/final-mtp/journey-20261017T135947Z/mtp-journey.json`
- `docs/evidence/glm53-flash-mtp-gateway-eligibility-2026-10-19/`

Those artifacts establish their recorded tuple only. The changed decode path
is `ContinuousBatchRowSampler.sample`: per-row `grammarConstraint.mask(logits:)`
now precedes penalties and sampling, and its accepting state controls EOS.
Serial generation receives the same request-local constraint. Constrained rows
are excluded from native MTP. This change justifies grammar correctness and
same-row-count end-to-end comparison, not rerunning unrelated qualification.

Use an already-built lab candidate and frozen fixtures; substitute the existing
absolute paths in these environment variables. Keep outputs outside the repo.
No kernel microbenchmark can decide this campaign.

```bash
"$CLI" msb-throughput --model "$MODEL" --engine scheduler --rows 2 \
  --prompt-tokens 1536 --decode-tokens 512 --runs 5 --output "$OUT/cb-s2.json"
"$CLI" msb-throughput --model "$MODEL" --engine scheduler --scenario parity \
  --rows 2 --prompt-tokens 1536 --decode-tokens 512 --parity-tokens 512 \
  --runs 5 --output "$OUT/cb-s2-parity.json"
MACPROVIDER_NATIVE_MTP_E2E=1 "$CLI" native-mtp-bench \
  --root "$FIXTURE_ROOT" --model-id "$MODEL" --policy "$FROZEN_POLICY" \
  --provider-commit "$COMMIT" --out "$OUT/r015.jsonl"
python3 scripts/native_mtp_r015_analyze.py "$OUT/r015.jsonl" "$FROZEN_POLICY"
```

These existing harnesses measure ordinary CB and native-versus-ordinary R015
cells; they do not exercise tool grammar requests. Report output tokens/s,
acceptance, TTFT and token parity at equal row counts from R015. Do not label
the CB harness a grammar throughput measurement. For actual grammar serving,
use the existing buyer conformance entry point against an isolated local
coordinator/gateway and candidate provider, with a lab-only buyer credential:

```bash
python3 scripts/buyer_ux_conformance.py run --gateway "$LAB_GATEWAY/v1" \
  --key-file "$LAB_BUYER_KEY_FILE" --model "$MODEL" --catalog-key "$CATALOG_KEY" \
  --record "$OUT/buyer-ux.json"
python3 scripts/buyer_ux_conformance.py check --catalog-key "$CATALOG_KEY" \
  --model-id "$MODEL" --record "$OUT/buyer-ux.json"
```

Repeat conformance per template family with the exact loaded model identity.
Require valid declared function/arguments in required and named streaming and
non-streaming replies, none without calls, valid tool-result round trips,
bounded 400 compiler rejection, no constrained native-MTP dispatch, and row
isolation. The existing conformance command is a correctness gate; it does not
report end-to-end token throughput or prove real Malibu routing, billing or
settlement. A constrained-throughput number remains pending an authorized
measurement with existing request/timing capture; do not invent a new harness
or claim a speed gain from the commands above. No catalog/feed changes or live
activation follow from a passing local run.
