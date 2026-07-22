# #608 Llama-3.2 Tier-2 vs autotune CONFLICT — reviewed republish

**Status:** tooling ready; Pearl apply steps in §3 are **DO NOT EXECUTE YET**
**Scope:** resolves the single live `mlx-community/Llama-3.2-3B-Instruct-4bit`
hash CONFLICT between Pearl's autotune release and Pearl's Tier-2 dual file.
**Not in scope:** ledger/compatibility-set Tier-2 feed membership, explicit
`macprovider.snapshot-manifest.v1` `hash_scope`, physical dual-file removal,
`exc-catalog-compatibility-bridges` clearance, or any `#609`
`require_hash_verified` flip. See
`audits/2026-07-22/PEARL_608_DUAL_CATALOG_CUTOVER_PREP.md` for the full gap
list; this runbook only closes gap item 1 of 5 (the Llama CONFLICT).

## 0. Read-only facts this runbook is built from

Recorded by the 2026-07-22 read-only Pearl inventory
(`audits/2026-07-22/PEARL_608_DUAL_CATALOG_CUTOVER_PREP.md`). Re-verify these
before acting — do not assume they are still current.

| Field | Value |
| --- | --- |
| Active autotune release | `published-2026-07-10-catalog-recovery-v1` |
| `autotune-candidates.json` sha256 | `776182f6230eff098345b188322dba0c7fce47a6da46447432991ffdc37eabda` |
| Repo `tier2-identity-binding.json` `autotune_candidates_sha256` | `776182f6230eff098345b188322dba0c7fce47a6da46447432991ffdc37eabda` (matches) |
| Live Pearl `/opt/macprovider/tier2-catalog.json` sha256 | `309f67affe840974d04b571db86f343933e3a5785a388d4a39d61c3da0fe1874` |
| Live Pearl Tier-2 `catalog_id` | `macprovider-tier2-model-catalog-2026-07-07-p2-qwen3-8b` |
| Live Pearl Tier-2 model count | 9 |
| `tier2.require_hash_verified` | `false` (must stay `false` for this runbook) |
| CONFLICT | `mlx-community/Llama-3.2-3B-Instruct-4bit`: autotune `e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90` vs Tier-2 `3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a` |
| AGREE | remaining 8 overlapping `model_id`s (includes live Qwen3-Coder `10adb5da…`) |

Expected post-republish state: the same 9 `model_id`s, the same 8 unchanged
hashes, and Llama-3.2-3B updated to `e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90`.
`scripts/catalog-release.py check-tier2-binding` must report zero conflicts
against `published-2026-07-10-catalog-recovery-v1` afterward.

## 1. Local, no-production-credentials staging (safe to run now)

All commands run from the repository root in this worktree. Nothing in this
section touches Pearl.

```bash
# 1a. Reproduce the live CONFLICT locally against the fixture that encodes
#     the exact stale/current Llama hash pair (proves fail-closed detection
#     before touching any real file).
python3 scripts/catalog-release.py check-tier2-binding \
  --candidate phase3-binary/catalog/autotune/autotune-candidates.json \
  --tier2 phase3-binary/catalog/autotune/testdata/tier2-llama-conflict-template.json
# Expected: exits non-zero, prints an "autotune/tier2 identity conflict"
# error naming mlx-community/Llama-3.2-3B-Instruct-4bit and both hashes.

# 1b. Stage an unsigned republish body from the SAME fixture shape (in a
#     real run, --template is a copy of the operator-pulled live
#     /opt/macprovider/tier2-catalog.json, not the test fixture).
python3 scripts/catalog-release.py stage-tier2-republish \
  --candidate phase3-binary/catalog/autotune/autotune-candidates.json \
  --binding phase3-binary/catalog/autotune/tier2-identity-binding.json \
  --template phase3-binary/catalog/autotune/testdata/tier2-llama-conflict-template.json \
  --output /tmp/tier2-catalog.staged.json
# Expected: prints the single changed row
# ("mlx-community/Llama-3.2-3B-Instruct-4bit: 3975387f... -> e7e5bff4...")
# and confirms check-tier2-binding already passed on the staged body.

# 1c. Confirm the staged body now agrees on all 9 model_ids.
python3 scripts/catalog-release.py check-tier2-binding \
  --candidate phase3-binary/catalog/autotune/autotune-candidates.json \
  --tier2 /tmp/tier2-catalog.staged.json
# Expected: "tier2 binding ok: ... agrees with ..." (exit 0).

diff <(python3 -m json.tool /tmp/tier2-catalog.staged.json 2>/dev/null || cat /tmp/tier2-catalog.staged.json) \
     phase3-binary/catalog/autotune/testdata/tier2-llama-conflict-template.json || true
# Manually review: the diff must show exactly one changed field
# (Llama-3.2 sha256) and zero changes to hash_scope, artifact_kind,
# min_ram_gb, notes, or source for any row.
```

`stage-tier2-republish` never invents `hash_scope`; it only copies the
autotune sha256 for overlapping `model_id`s onto whatever operator-reviewed
template it is given, and it refuses to write output unless the staged body
already passes `check-tier2-binding`. It is not a second identity authority —
see the function docstring in `scripts/catalog-release.py`.

## 2. Get the real template and sign it (still no Pearl mutation)

```bash
# 2a. Pull the CURRENT live Tier-2 file read-only (no write, no restart).
ssh <pearl-operator-target> \
  'cat /opt/macprovider/tier2-catalog.json' > /tmp/tier2-catalog.live.json
sha256sum /tmp/tier2-catalog.live.json
# Expected: 309f67affe840974d04b571db86f343933e3a5785a388d4a39d61c3da0fe1874
# (re-verify — do not proceed if this drifted from §0).

# 2b. Strip the live signature block before using it as a stage-tier2-
#     republish template (the tool accepts a signed body and ignores
#     `signature`, but keep the diff obviously unsigned for review).
python3 -c '
import json, sys
body = json.load(open("/tmp/tier2-catalog.live.json"))
body.pop("signature", None)
json.dump(body, open("/tmp/tier2-catalog.live.unsigned.json", "w"), indent=2, sort_keys=True)
'

python3 scripts/catalog-release.py stage-tier2-republish \
  --candidate phase3-binary/catalog/autotune/autotune-candidates.json \
  --binding phase3-binary/catalog/autotune/tier2-identity-binding.json \
  --template /tmp/tier2-catalog.live.unsigned.json \
  --output /tmp/tier2-catalog.republish.json

# 2c. Operator review: confirm only Llama-3.2 sha256 changed, then sign with
#     the existing production Tier-2 private key (already escrowed; never
#     generate a new keypair for this).
go run scripts/sign-catalog.go sign \
  -key <path-to-existing-tier2-private-key> \
  -key-id <existing-tier2-key-id> \
  -out /tmp/tier2-catalog.republish.signed.json \
  /tmp/tier2-catalog.republish.json

go run scripts/sign-catalog.go verify \
  -public-key <path-to-existing-tier2-public-key> \
  /tmp/tier2-catalog.republish.signed.json

python3 scripts/catalog-release.py check-tier2-binding \
  --candidate phase3-binary/catalog/autotune/autotune-candidates.json \
  --tier2 /tmp/tier2-catalog.republish.signed.json
```

## 3. Pearl apply — **DO NOT EXECUTE YET**

Everything below mutates production and requires an explicit operator go/no-go
plus the pre-flight in `ops/runbooks/catalog-release-provider-upgrade.md`
§6.3 (direct deploy) — including the deploy mutex, canary proof, and rollback
snapshot. This runbook does not authorize running it.

```text
DO NOT EXECUTE YET:
1. Snapshot /opt/macprovider/tier2-catalog.json and its signature per the
   direct-deploy recovery procedure (catalog-release-provider-upgrade.md
   §6.3 step 3) before any write.
2. Upload /tmp/tier2-catalog.republish.signed.json to Pearl through
   phase4-coordinator/dist/deploy-pearl-vps.sh (never scp the file directly
   onto the live path — the deploy script owns the mutex, verification, and
   rollback).
3. Confirm the deployed sha256 differs from 309f67affe840974d04b571db86f343933e3a5785a388d4a39d61c3da0fe1874
   (the stale Llama file) and that check-tier2-binding against the active
   autotune release passes on Pearl.
4. Re-run the 2026-07-22 drift matrix read-only probe: expect CONFLICT=0,
   AGREE=9.
5. Confirm tier2.require_hash_verified is still false and
   exc-tier2-hash-mismatch-containment / exc-catalog-compatibility-bridges
   are unchanged (this runbook does not clear either exception).
```

## 4. What this closes vs what remains open on #608

Closes: the Llama-3.2 CONFLICT align path (tooling + fail-closed fixture
proof) described in
`audits/2026-07-22/PEARL_608_DUAL_CATALOG_CUTOVER_PREP.md` §5 item 1.

Still open (unchanged by this runbook):

1. Ledger / compatibility-set membership for signed Tier-2 bytes (§5 item 2).
2. Explicit Tier-2 `macprovider.snapshot-manifest.v1` `hash_scope`; keep
   `derive-tier2` disabled until then (§5 item 3).
3. Promote a Pearl coordinator binary carrying #682 `catalogbind` + #688
   deploy-only mutate gate — the live binary predates both (§5 item 4).
4. Physical `/opt/macprovider/tier2-catalog.json` dual-file removal + Pearl
   journey proof, then `exc-catalog-compatibility-bridges` clearance (§5
   item 5).
5. `#609` `require_hash_verified` enforce flip — explicitly out of scope for
   #608 and for this runbook.
