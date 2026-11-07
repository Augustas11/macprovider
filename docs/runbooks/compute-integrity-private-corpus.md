# Compute-integrity scoring: private prompt corpus

Related: #1644, SPEC-036 §5A (FR-20).

Cross-provider scoring ships enabled, but the coordinator schedules no
verification request until `compute_integrity.scoring.corpus_path` names a
private prompt corpus. The checked-in corpus is public, so a provider could
recognize its prompts. Without a private corpus the coordinator logs
`compute_integrity_private_corpus_missing` and
`compute_integrity_scoring_started enabled=false`, and scoring stays inert.

The corpus is an operator secret. It never enters this repository: the repo
holds only the generator and the install tooling.

## 1. Build the corpus (operator Mac)

Write a private topics file outside the repository: one topic per line, at
least 16 distinct topics, written the way buyers ask about things. The topics
are what keep the corpus private. The generator's phrasing templates are
public and deliberately buyer-like.

```bash
python3 -I scripts/compute-integrity-corpus.py \
  --topics ~/.config/macprovider/operator-secrets/compute-integrity/topics.txt
```

It draws `--count` distinct prompts (default 400) from the template × topic
space with a random draw. It checks them with the coordinator's corpus rules
and writes
`~/.config/macprovider/operator-secrets/compute-integrity/corpus-<version>.json`
(directory 0700, file 0600, never overwritten). It prints only the path, the
prompt count and the sha256.

Corpus format (`internal/computeintegrity/scoring_corpus.go`): a JSON object
with exactly `version` (non-blank string) and `prompts` (non-empty list).
Each prompt has exactly `system` and `user`, both non-blank UTF-8 strings of
at most 2 KiB. The ops check also caps the file at 4 MiB. It is stricter than
the coordinator, never looser:
`internal/computeintegrity/testdata/corpus_parse_cases.json` pins both.

## 2. Install it on Pearl

```bash
export COMPUTE_INTEGRITY_CORPUS=~/.config/macprovider/operator-secrets/compute-integrity/corpus-<version>.json
PEARL_RUNTIME_TASK=compute-integrity-enable scripts/ops/pearl-runtime.sh status
PEARL_RUNTIME_TASK=compute-integrity-enable scripts/ops/pearl-runtime.sh next
MACPROVIDER_OPS_OWNER=<session-label> PEARL_RUNTIME_TASK=compute-integrity-enable \
  scripts/ops/pearl-runtime.sh next --run
```

Expected downtime: one coordinator restart, about 5–40 seconds. In-flight
requests drain first, then the coordinator starts. Buyer and provider traffic
through the coordinator is interrupted for that time. If the post-restart
check fails, the tooling restores the overlay and the corpus and restarts the
coordinator once more.

`next --run` prints the downtime first and takes the live-ops lock. It then
does the following:

1. Checks the local corpus again. It must be outside the repository, mode
   0600, and pass the corpus rules, and its sha256 must match the one
   `status` named.
2. Stages the corpus root-only next to its target on Pearl and runs
   `scripts/ops/lib/pearl-cli-config.py apply-compute-integrity` under both
   Pearl locks. The helper refuses on a pricing transaction journal.
3. Checks the staged copy's sha256 and the corpus rules again on Pearl.
4. Refuses when `compute_integrity.scoring.enabled` is `false` in
   `coordinator.yaml` or the overlay. That is the kill switch, and this task
   never overrides it.
5. Installs the corpus at `/etc/macprovider/compute-integrity-corpus.json`
   (`PEARL_COMPUTE_INTEGRITY_CORPUS_PATH`). The file is owned by root,
   carries the coordinator's group, and has mode 0640. The coordinator runs
   as its own user and must be able to read it; the helper checks that it
   can.
6. Backs up `/etc/macprovider/coordinator.pearl-overlays.yaml` under
   `/root/macprovider-backups`, then appends only:

   ```yaml
   compute_integrity:
     scoring:
       corpus_path: /etc/macprovider/compute-integrity-corpus.json
   ```

   An overlay that already sets `compute_integrity` differently is refused.
   Reconcile it by hand first.
7. Validates the base and the new overlay with the running coordinator's
   binary, user and environment (`--validate-config`), then does one restart.
8. Requires the new process to log `compute_integrity_corpus_loaded` with
   this corpus's prompt count and version, and
   `compute_integrity_scoring_started` with `enabled=true`. Otherwise it
   restores the overlay and the corpus and restarts again.

`status` then reports `scheduled: done`: the running coordinator logged
scheduling enabled with the installed corpus. It reads Pearl's state, so it
also works on a machine without the local corpus. The journal carries no
corpus hash, so "the installed corpus" means: the file is still root-owned,
in the coordinator's group, mode 0640, and unchanged since the coordinator
process started (its ctime is not newer), and its version and prompt count
match what the process logged. Any later change to the file, even a
`chmod`, makes `enable` the next step again; that run restarts once.

## Replacing the corpus

Build a new corpus with a new `--version` and run the same three commands
with `COMPUTE_INTEGRITY_CORPUS` pointing at it. A different sha256 makes
`enable` the next step again. It replaces the file, leaves the overlay as it
is, and restarts once.

## Reference scorers (SPEC-036 FR-26)

The coordinator falls back to Malibu-operated reference scorers when no
independent peer can score a key. It needs a runtime that has FR-26. When
the running coordinator logs `compute_integrity_scoring_started` without a
`reference_operators` count, it is older than FR-26: `status` blocks with
"release the runtime first", and `next --run` changes nothing and restarts
nothing. Keep the operator keys private, because a `provider:` key names a
provider.

Roll out in this order: the coordinator first, then the scorer Macs. Before
rolling the coordinator back below FR-26, disable `compute_score_reference`
on every scorer Mac. An older coordinator would treat a scorer Mac as an
ordinary provider.

```bash
export COMPUTE_INTEGRITY_REFERENCE_OPERATORS='github:<user id>,provider:<provider id>'
PEARL_RUNTIME_TASK=compute-integrity-reference-operators scripts/ops/pearl-runtime.sh status
PEARL_RUNTIME_TASK=compute-integrity-reference-operators scripts/ops/pearl-runtime.sh next
MACPROVIDER_OPS_OWNER=<session-label> PEARL_RUNTIME_TASK=compute-integrity-reference-operators \
  scripts/ops/pearl-runtime.sh next --run
```

Expected downtime: one coordinator restart, about 5–40 seconds, as above.

The list must pass the coordinator's rules. Each key is
`github:<positive integer up to 2^63-1, no leading zeros>` or
`provider:<1-64 characters of A-Z a-z 0-9 _ . ->`, with no duplicates and at
least one key. To remove the overlay key, set
`COMPUTE_INTEGRITY_REFERENCE_OPERATORS=none` and run the same three
commands. That removal uses the same backup, validation and single restart.
It also drops a `scoring` or `compute_integrity` mapping that the removal
leaves empty. An overlay that already holds an empty or null list is valid,
and setting a list replaces it. `status` prints only the count and the
sha256 of the list. `next --run` takes the live-ops lock and both Pearl locks.
It then:

1. Sets `compute_integrity.scoring.reference_operators` in the overlay to
   exactly this list. It keeps every other key, including `corpus_path`, and
   replaces a different list.
2. Backs up the overlay and validates it with the running coordinator.
3. Restarts the coordinator once and requires the new process to log
   `compute_integrity_scoring_started` with that many `reference_operators`.

If any of these fails, it restores the overlay and restarts again. Running it
again with the same list changes nothing. Each scorer Mac also runs the CLI
with `compute_score_reference: true`. The coordinator never routes buyer
requests to it.

### Operator review of reference-only failures

With no independent peer, the FR-24 scorer-integrity checks cannot run. A
failure that only a reference scorer reports therefore changes no state and
opens no hold. The key keeps its state and gets `review_pending`. The
coordinator logs `compute_integrity_review_pending`, and the
`compute_integrity_review_pending{state}` gauge counts these keys. Operator
review is the bound. Resolve each one with the `confirm-failure` or `clear`
admin action.

- Credits that settle while a key is under review stay paid. Confirm a real
  failure before the next weekly settlement.
- Clearing a key that is `recovering` does not release its open recovery
  hold. Release that hold separately.
