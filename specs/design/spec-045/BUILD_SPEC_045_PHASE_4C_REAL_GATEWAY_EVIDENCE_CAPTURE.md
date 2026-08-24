# BUILD_SPEC_045_PHASE_4C_REAL_GATEWAY_EVIDENCE_CAPTURE

Phase 4C adds the operator capture primitive for the signed real-gateway
journey required by SPEC-045 local consumer endpoint mode.

## Target Result

An operator can run the staging-or-production local consumer endpoint journey,
review local captures, and commit one schema-closed redacted evidence source
under:

```text
journeys/evidence/local-consumer-endpoint-*.redacted.json
```

The committed file is suitable input for
`scripts/build-local-consumer-endpoint-journey-result.py` and the protected
`promote-signed-local-consumer-endpoint-journey.yml` workflow.

## Scope

- Add a local capture tool that emits
  `macprovider.local-consumer-endpoint-evidence.v1`.
- Reuse the exact journey id, execution mode, artifact id, step order, and
  SPEC-045 requirement set already enforced by Phase 4B.
- Store only booleans, digests, fingerprints, timestamps, and closed metadata
  in the committed evidence source.
- Hash local redacted support captures for CLI binary, ledger, logs, rate card,
  status output, a raw validated loopback base URL, and a raw validated
  allowlisted staging-or-production gateway origin.
- Require a closed `macprovider.local-consumer-endpoint-capture-review.v1`
  review manifest that binds every physical step to named support artifacts and
  explicitly records the real-gateway, OpenAI SDK, and redaction review bases.
  The manifest must pin the reviewed SHA-256 and byte count for every support
  artifact so post-review replacement fails closed.
- Reject fake-gateway captures, wrong output paths, non-SPEC-045 requirement
  IDs, obvious bearer/API-key/private-key material, non-UTF-8 text captures,
  symlink inputs/outputs, fake/local gateway origins, secret-like metadata, and
  transcript-bearing prompt/completion/message fields before writing the
  evidence source.
- Leave `specs/CONFORMANCE.json` pending.

## Non-Goals

- Do not run the staging or production journey automatically.
- Do not sign the journey-result locally.
- Do not promote conformance.
- Do not commit raw logs, raw prompts, raw completions, bearer tokens, upstream
  credentials, local endpoint tokens, hostnames, user names, or operator-local
  paths.
- Do not expand the local endpoint API surface.

## Operator Flow

1. Run the real staging or production journey described by
   `journeys/JOURNEY-LOCAL-CONSUMER-ENDPOINT.md`.
2. Export redacted local support captures outside the repository or under
   ignored scratch space.
3. Write a closed review manifest confirming each required physical step,
   observation, redaction check, support artifact hash, support artifact byte
   count, and support artifact review. The manifest schema is
   `macprovider.local-consumer-endpoint-capture-review.v1`.
4. Run `scripts/capture-local-consumer-endpoint-evidence.py` with:
   - the candidate `--source-sha`;
   - `--candidate commit:<source-sha>`;
   - the reviewed `--review-manifest`;
   - `--gateway-kind staging` or `--gateway-kind production`;
   - fingerprints for the buyer credential, local token, and operator identity;
   - redacted capture files for CLI binary, ledger, logs, rate card, and status;
   - raw non-secret endpoint and allowlisted gateway-origin values to hash.
5. Review the generated
   `journeys/evidence/local-consumer-endpoint-*.redacted.json`.
6. Commit the reviewed evidence source.
7. Dispatch the protected signer workflow from current `origin/main`.
8. Review the short-lived exported signer artifact before a follow-up PR
   commits any signed journey-result and conformance promotion.

## Acceptance Tests

- The capture tool emits the closed Phase 4B evidence shape.
- The generated evidence can be consumed by the Phase 4B builder after it is
  committed at an evidence SHA.
- The capture tool rejects fake-gateway class evidence.
- The capture tool and builder require support-artifact hashes plus a closed
  review block before evidence can become a signed journey-result payload.
- The capture tool rejects transcript-bearing JSON keys, non-UTF-8 redacted
  text captures, symlink paths, fake/local gateway origins, secret-like
  metadata, and obvious secret-like values in the hashed local support captures.
- `specs/CONFORMANCE.json` remains unchanged by this slice.
