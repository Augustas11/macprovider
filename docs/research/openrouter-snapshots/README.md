# OpenRouter pricing artifact archive

This directory is the durable UTC archive for OpenRouter pricing runs. A
successful operation copies the atomically emitted file without editing it:

- `openrouter-pricing-snapshot-YYYY-MM-DDTHH-MM-SSZ-<digest16>.json`
- `openrouter-rate-card-proposal-YYYY-MM-DDTHH-MM-SSZ-<digest16>.json`

`<digest16>` is the first 16 lowercase hexadecimal characters of the SHA-256
of the complete artifact mapping encoded as canonical JSON (keys sorted, no
insignificant whitespace, and non-ASCII characters preserved), as implemented
by the engine's `artifact_suffix`. For a snapshot, this filename digest is
distinct from its semantic `content_digest` and from the receipt's SHA-256 of
the serialized file bytes.

The snapshot is the proposal's source of truth. Its semantic digest must equal
the proposal's `source_snapshot.content_digest`. A failed fetch produces no
snapshot and must never be represented by a placeholder. Compute must not run
unless fetch emitted a validated snapshot. This workflow has no apply step.

Artifacts older than 48 hours are stale for pricing review. Every review must
archive the snapshot, proposal, their SHA-256 file checksums, and the associated
credential-redacted receipts before that deadline.

## Receipt contract

New runs use the executable schema-version 2 contract implemented by
`scripts/openrouter_pricing_receipt.py`. The runner refuses a dirty worktree,
binds both receipts to the full committed HEAD, binds the fetch receipt to the
exact policy bytes used for normalization, captures and redacts both process
streams, validates an exact compute replay, and verifies byte identity after
copying both receipts and both artifacts into this archive.

The validator also requires the recorded commit to exist and be an ancestor of
the current validator worktree, requires that commit to contain the engine and
receipt runner, requires the current engine bytes to equal the committed engine
bytes, and matches the recorded command exactly to the receipt type and bound
paths/options. A recomputed self-digest cannot make an invented commit or
command valid.

Run the authenticated top-50/30-day operation from a clean committed worktree:

```powershell
python scripts/openrouter_pricing_receipt.py run
```

`OPENROUTER_API_KEY` must be configured in the process environment. It is
passed only through the child-process environment and is never written to a
command array, receipt, or artifact. The command defaults are the reviewed
contract: top 50, 30 days, three retries, 20-second request timeout, and
900-second generation deadline. It has no apply mode.

Independently validate the archived result and exact proposal replay:

```powershell
python scripts/openrouter_pricing_receipt.py validate `
  --receipt docs/research/openrouter-snapshots/<fetch-receipt>.json `
  --receipt docs/research/openrouter-snapshots/<compute-receipt>.json
```

Schema-version 2 adds `execution: {"worktree_clean": true}` to every receipt,
adds `policy_path` and `policy_file_sha256` to fetch `source`, and adds
`snapshot_path` to compute `inputs`. The validator requires the current policy
and rate-card bytes to match the receipt, validates the snapshot, and rebuilds
the proposal at its recorded `generated_at`; any unequal field fails closed.
The runner validates the temporary evidence first, copies it without editing,
then compares the archived receipt and artifact byte counts and SHA-256 values
to their temporary sources before validating the archived copies again.
Publication is transactional: every source is first copied to a private
temporary file in the archive and verified, then atomically linked to its final
non-overwriting name. Any copy, publication, or post-publication verification
failure removes every final name published by that operation while preserving
a concurrently created target.

Fetch and compute failures emit and archive credential-redacted schema-version
2 receipts before the runner exits nonzero:

- `openrouter-pricing-fetch-failure-YYYY-MM-DDTHH-MM-SSZ.json` has `source`, a
  nonzero `exit_status`, captured streams, and an empty artifact inventory.
- `openrouter-pricing-compute-failure-YYYY-MM-DDTHH-MM-SSZ.json` has the same
  exact `inputs` binding as compute success, a nonzero `exit_status`, captured
  streams, and an empty artifact inventory. The already validated fetch receipt
  and snapshot remain durable when compute fails.

Failure receipts never stand in for snapshots or proposals. They prove the
bounded attempt and preserve its redacted error; a later successful stage still
requires its real validated artifact. Before recording an empty failure
inventory, the runner requires the failed stage's output directory to be empty;
any unexpected partial artifact aborts receipt publication.

The schema-version 1 receipts already committed here are historical evidence
created before the executable runner existed. The manual contract below
documents those receipts; it is retained for auditability, not as the procedure
for a new run.

Historical schema-version 1 receipts are manually assembled operator metadata,
not engine output and not a substitute for the replayable snapshot/proposal.
They use these names:

- `openrouter-pricing-fetch-success-YYYY-MM-DDTHH-MM-SSZ.json`
- `openrouter-pricing-fetch-failure-YYYY-MM-DDTHH-MM-SSZ.json`
- `openrouter-pricing-compute-success-YYYY-MM-DDTHH-MM-SSZ.json`

Every historical receipt has schema version 1 and these common fields:

| Field | Requirement |
| --- | --- |
| `schema_version` | Integer `1`. |
| `receipt_type` | One of the three filename types above. |
| `started_at`, `finished_at` | UTC RFC 3339 timestamps captured immediately around the process. |
| `engine_commit` | Full output of `git rev-parse HEAD` at execution time. |
| `command` | JSON string array, with paths generalized if needed and no credential. |
| `exit_status` | Exact child-process exit status. Success is zero; failure is nonzero. |
| `stdout`, `stderr` | UTF-8 captured streams after mandatory redaction below. |
| `output_directory_listing` | Array of emitted filename, byte count, and `sha256` objects; empty on failed fetch. |
| `evidence_digest` | Canonical receipt digest described below. |

Fetch receipts additionally require `source` and prohibit `inputs`. Both fetch
types require exactly `rankings_url`, `ranking_window_start_date`,
`ranking_window_end_date`, and only the boolean
`openrouter_api_key_configured` (never the key). A fetch-success receipt also
requires exactly `confirmed_empty_model_ids`, `confirmation_request_count`, and
`successful_source_count`, all copied from or verified against the emitted
snapshot. A fetch-failure receipt stops at the four base fields because no
validated snapshot exists; it must not claim confirmation or a final source
count that the failed generation could not validate.

Compute receipts additionally require `inputs` and prohibit `source`. `inputs`
contains `snapshot_content_digest`, `snapshot_file_sha256`, `policy_path`,
`policy_file_sha256`, `rate_card_path`, and a rate-card binding. The snapshot and
policy are immutable archived inputs bound by whole-file SHA-256. The rate card,
however, is a live signed feed whose `generated_at` is periodically re-stamped to
renew freshness without changing pricing, so new receipts bind
`rate_card_content_sha256`: a canonical hash of the rate card with `generated_at`
excluded. That binding is freshness-tolerant yet still changes on any real
pricing change (`version`, `policy_version`, `usd_per_million_credits`, or a
`rows` value). Pre-migration archived receipts bind the whole rate-card file as
`rate_card_file_sha256`; the validator still accepts that legacy form so those
historical receipts and their engine binding stay byte-unchanged. This freshness
decoupling lives entirely in the receipt validator (`openrouter_pricing_receipt.py`):
the engine and every archived proposal are untouched. During the exact proposal
replay the validator excludes the freshness-coupled `rate_card_reference_digest`
(the engine's whole-rate-card digest, which a re-stamp changes even though every
priced row is identical); the rate-card content binding and the priced rows
themselves still fail the replay closed on any real pricing change.

A success receipt is invalid unless its inventory contains exactly one artifact
of the matching type. A fetch-failure receipt is invalid if its inventory is
non-empty or a snapshot exists in its run directory.

## Exact manual receipt procedure (PowerShell)

Run from the repository root. The API key must already exist in the process
environment; never place it on the command line.

```powershell
$runDir = Join-Path $env:TEMP ("openrouter-pricing-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $runDir | Out-Null
$startedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$engineCommit = git rev-parse HEAD
$apiKeyConfigured = [bool]$env:OPENROUTER_API_KEY

$stdoutPath = Join-Path $runDir "stdout.txt"
$stderrPath = Join-Path $runDir "stderr.txt"
python scripts/openrouter_pricing_engine.py fetch `
  --output-dir $runDir `
  --top-n 50 `
  --demand-window-days 30 `
  --retries 3 `
  --timeout-seconds 20 `
  --generation-timeout-seconds 900 `
  1> $stdoutPath 2> $stderrPath
$exitStatus = $LASTEXITCODE
$finishedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$artifactPattern = "openrouter-pricing-snapshot-*.json"
$outputInventory = Get-ChildItem -LiteralPath $runDir -File |
  Where-Object { $_.Name -like $artifactPattern } |
  ForEach-Object {
    [ordered]@{
      filename = $_.Name
      bytes = $_.Length
      sha256 = "sha256:" + (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant()
    }
}
```

For compute, use a new empty `$runDir`, capture new start/end timestamps and
streams around this exact command, and set `$artifactPattern` to
`openrouter-rate-card-proposal-*.json`:

```powershell
$snapshotPath = "docs/research/openrouter-snapshots/<exact-snapshot-filename>.json"
$policyPath = "scripts/openrouter_pricing_policy.json"
$rateCardPath = "phase3-binary/catalog/autotune/rate-card.json"
python scripts/openrouter_pricing_engine.py compute `
  --snapshot $snapshotPath `
  --policy $policyPath `
  --rate-card $rateCardPath `
  --output-dir $runDir `
  1> $stdoutPath 2> $stderrPath
```

Capture the ranking window from the validated snapshot, not from a guessed
local date. Derive the fetch `source` object from that snapshot and the exact
fetch invocation. Derive the compute `inputs` object from `$snapshotPath`,
`$policyPath`, and `$rateCardPath` using `Get-FileHash -Algorithm SHA256`; copy
the snapshot's semantic `content_digest` without recomputing or editing it.

When fetch observes an authoritative empty provider set, the receipt source
must list the exact model ID and the snapshot must record
`endpoint_set_confirmation: "confirmed_empty_second_fetch"`. The engine's
`successful_source_count` includes both endpoint requests. A receipt must not
claim confirmation when the snapshot says `not_required`, and a
`no_provider_endpoints` row without confirmation provenance is invalid.

Before assembling JSON, read both streams as UTF-8 and apply this exact
redaction function to each:

```powershell
function Protect-OpenRouterReceiptText {
  param([string]$Text, [string]$ApiKey)

  $redacted = $Text
  if (-not [string]::IsNullOrEmpty($ApiKey)) {
    $redacted = $redacted.Replace($ApiKey, "<redacted>")
  }
  $redacted = [regex]::Replace(
    $redacted,
    '(?i)Authorization:\s*Bearer\s+\S+',
    'Authorization: Bearer <redacted>'
  )
  $redacted = [regex]::Replace(
    $redacted,
    '(?i)Bearer\s+sk-or-\S+',
    'Bearer <redacted>'
  )
  if ($redacted -match '(?i)sk-or-[A-Za-z0-9_-]+') {
    throw "receipt redaction failed: OpenRouter credential remains"
  }
  return $redacted
}

$stdout = Protect-OpenRouterReceiptText `
  ([IO.File]::ReadAllText($stdoutPath, [Text.Encoding]::UTF8)) `
  $env:OPENROUTER_API_KEY
$stderr = Protect-OpenRouterReceiptText `
  ([IO.File]::ReadAllText($stderrPath, [Text.Encoding]::UTF8)) `
  $env:OPENROUTER_API_KEY
```

The exact redaction order is:

1. Replace the exact `OPENROUTER_API_KEY` value with `<redacted>` if present.
2. Replace case-insensitive `Authorization: Bearer <non-whitespace>` with
   `Authorization: Bearer <redacted>`.
3. Replace case-insensitive `Bearer sk-or-<non-whitespace>` with
   `Bearer <redacted>`.
4. Reject the receipt instead of archiving it if any `sk-or-` token remains.
5. Preserve all other bytes as UTF-8 text; do not paraphrase errors.

Assemble one ordered mapping with the common fields plus exactly one of
`source` or `inputs`, set `evidence_digest` by the algorithm below, and write it
with UTF-8 encoding. The receipt timestamp in the filename is `started_at`
rendered as `YYYY-MM-DDTHH-MM-SSZ`.

## Canonical evidence digest

To calculate `evidence_digest`, remove that field, encode the remaining JSON as
UTF-8 with keys sorted, no insignificant whitespace, and non-ASCII characters
preserved, then hash those bytes with SHA-256:

```python
import hashlib, json

payload = dict(receipt)
payload.pop("evidence_digest", None)
canonical = json.dumps(
    payload,
    sort_keys=True,
    separators=(",", ":"),
    ensure_ascii=False,
).encode("utf-8")
receipt["evidence_digest"] = "sha256:" + hashlib.sha256(canonical).hexdigest()
```

## Mandatory validation and archive-copy checks

Before copying anything into this directory, validate all of the following:

1. The receipt contains only the common fields and its type-specific field;
   timestamps are UTC RFC 3339, `started_at <= finished_at`, `engine_commit` is
   40 lowercase hex characters, `command` is a string array, and no string
   contains an `sk-or-` token.
2. Recompute `evidence_digest` with the algorithm above and require an exact
   match.
3. Recompute every inventory entry's byte count and SHA-256 from the temporary
   artifact. Require one matching artifact for success and no snapshot for a
   failed fetch.
4. For fetch success, run the engine's snapshot validation, require the
   snapshot ranking window/source count to match `source`, and require the
   sorted `no_provider_endpoints` row IDs and confirmation count to match
   `source.confirmed_empty_model_ids` and `confirmation_request_count`.
5. For compute success, require every `inputs` file hash to match, run proposal
   validation, and require the proposal's source snapshot digest to equal both
   `inputs.snapshot_content_digest` and the validated snapshot.
6. Copy the finalized receipt and the single legitimate artifact to this
   archive. Do not copy temporary stream files. Re-hash the archived copies and
   require their byte counts and SHA-256 values to equal the pre-copy values.

The archive-copy check is literal:

```powershell
$archive = "docs/research/openrouter-snapshots"
Copy-Item -LiteralPath $receiptPath -Destination $archive
Copy-Item -LiteralPath $artifactPath -Destination $archive

$archivedArtifact = Join-Path $archive ([IO.Path]::GetFileName($artifactPath))
$archivedBytes = (Get-Item -LiteralPath $archivedArtifact).Length
$archivedSha256 = "sha256:" + (
  Get-FileHash -Algorithm SHA256 -LiteralPath $archivedArtifact
).Hash.ToLowerInvariant()
if ($archivedBytes -ne $outputInventory[0].bytes -or
    $archivedSha256 -ne $outputInventory[0].sha256) {
  throw "archived artifact does not match validated temporary artifact"
}
```

Historical receipts in this directory were manually assembled from captured
process metadata and validated against this type-specific contract. Only the
snapshot/proposal files themselves are independently replayable engine output.

## Governance mapping

No current normative requirement directly governs this standalone,
non-money-path OpenRouter ingestion/proposal evidence tool. SPEC-023-R001 and
the `installer-autotune-policy` authority domain are the nearest structural
governance route because the output is reviewed autotune pricing research; they
are not claimed as semantic conformance authority for OpenRouter receipts.
Owner Option 2 in Decision Entry 225 is therefore an explicit
`DECISION_REQUIRED` policy choice in addition to the endpoint-validation
`CODE_BUG` repair. Component 3 remains the only authority that may apply a
proposal to the live rate card.
