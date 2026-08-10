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

Receipts are manually assembled operator metadata, not engine output and not a
substitute for the replayable snapshot/proposal. Use these names:

- `openrouter-pricing-fetch-success-YYYY-MM-DDTHH-MM-SSZ.json`
- `openrouter-pricing-fetch-failure-YYYY-MM-DDTHH-MM-SSZ.json`
- `openrouter-pricing-compute-success-YYYY-MM-DDTHH-MM-SSZ.json`

Every receipt has schema version 1 and these fields:

| Field | Requirement |
| --- | --- |
| `schema_version` | Integer `1`. |
| `receipt_type` | One of the three filename types above. |
| `started_at`, `finished_at` | UTC RFC 3339 timestamps captured immediately around the process. |
| `engine_commit` | Full output of `git rev-parse HEAD` at execution time. |
| `command` | JSON string array, with paths generalized if needed and no credential. |
| `source` | Endpoint/window metadata, confirmed-empty model IDs/count, and only the boolean `openrouter_api_key_configured`; never the value. |
| `exit_status` | Exact child-process exit status. Success is zero; failure is nonzero. |
| `stdout`, `stderr` | UTF-8 captured streams after mandatory redaction below. |
| `output_directory_listing` | Array of emitted filename, byte count, and `sha256` objects; empty on failed fetch. |
| `evidence_digest` | Canonical receipt digest described below. |

Successful compute receipts additionally identify the exact snapshot, policy,
and rate-card paths/checksums. A success receipt is invalid if its expected
artifact is absent. A failure receipt is invalid if it claims a snapshot.

## Exact operator capture procedure (PowerShell)

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

$artifactPattern = "openrouter-pricing-snapshot-*.json" # use openrouter-rate-card-proposal-*.json for compute
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

Capture the ranking window from the requested rankings URL/validated snapshot,
not from a guessed local date. For compute, repeat the same start/process/end
capture using the exact archived snapshot, current policy, current reference
rate card, and a new empty output directory.

When fetch observes an authoritative empty provider set, the receipt source
must list the exact model ID and the snapshot must record
`endpoint_set_confirmation: "confirmed_empty_second_fetch"`. The engine's
`successful_source_count` includes both endpoint requests. A receipt must not
claim confirmation when the snapshot says `not_required`, and a
`no_provider_endpoints` row without confirmation provenance is invalid.

Before placing streams in JSON, redact in this order:

1. Replace the exact `OPENROUTER_API_KEY` value with `<redacted>` if present.
2. Replace case-insensitive `Authorization: Bearer <non-whitespace>` and
   `Bearer sk-or-<non-whitespace>` values with `Bearer <redacted>`.
3. Reject the receipt instead of archiving it if any `sk-or-` token remains.
4. Preserve all other bytes as UTF-8 text; do not paraphrase errors.

The receipt writer must verify that a nonzero fetch has an empty snapshot
inventory. Copy only the finalized receipt and legitimate engine artifact into
this archive; the temporary stream files are not archived.

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

Validation repeats that algorithm and requires an exact match. It also hashes
every archived artifact named by the receipt and compares its byte count and
SHA-256 value. Historical receipts in this directory were manually assembled
from captured process metadata and validated with this algorithm; only the
snapshot/proposal files themselves are independently replayable engine output.
