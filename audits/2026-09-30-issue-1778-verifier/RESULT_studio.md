# Issue #1778 verifier-only Studio evidence

Date: 2026-09-30

## Scope

This run validates the corrected load-time paged-KV isolation verifier. It is
not a signed/notarized packaged release campaign and did not connect the local
candidate to the Malibu coordinator.

- Host: designated Mac Studio, `Mac15,14`, Apple M3 Ultra, 256 GB
- Candidate: release-mode source build from the #1778 follow-up branch rebased
  onto `origin/main`
- Isolation: `serve --no-join`, loopback `127.0.0.1:18193`, isolated home,
  lifecycle, temporary, and watchdog roots
- Live provider: the installed process on `127.0.0.1:8080` was not restarted,
  replaced, or contacted by the candidate
- Signed policy: intentionally empty, so this run proves local runtime attach
  eligibility but does not claim production authorization or scheduler
  activation

## Verifier correction

The earlier Qwen3.8 failure compared the production backend with a synthetic
serial oracle that repeatedly ran direct model forwards. That oracle did not
use `TokenIterator`'s `model.prepare` lifecycle and reported token `8160` where
production serial serving and the continuous-batch backend both produce token
`32`.

The corrected verifier:

1. prefills the complete prompt and samples the first token from final-prompt
   logits, matching the scheduler lifecycle;
2. advances recurrent hybrids one token before the peer leave/rejoin check;
3. obtains serial references from the production `TokenIterator`, including
   its parameter-bound cache and `model.prepare` path; and
4. requires exact token equality for those iterator references because the
   iterator does not expose processed logits from which a sound runner-up
   tolerance could be derived.

No serving-backend behavior change was required.

## Results

| Catalog identity | Artifact SHA-256 | Shared parity | Isolation / rejoin | Attach result |
| --- | --- | --- | --- | --- |
| `qwen/qwen3.5-27b` | `7777cf15fbd096d66ccec5f0f76ec915eb4800f4f3e8dd899d1b4ae3041387ae` | PASS, 48 tokens, 1,024/1,024 gather calls | PASS, 2 rows, 0 failures, 0 divergences; first two prompt pairs rejected as non-distinguishing and the third proved isolation | eligible |
| `qwen/qwen3.5-35b-a3b` | `893c5fd5a4f6adf19a97faeff19d67f2b7a5d8c29e81cd857bd5949ce0b31e43` | PASS, 48 tokens, 640/640 gather calls | PASS, 2 rows, 0 failures, 0 divergences; first two prompt pairs rejected as non-distinguishing and the third proved isolation | eligible |
| `qwen/qwen3.8-27b` | `8a8786e902127e9175f5be0d7c8bcf4dd32323a0521e4d9a20761608a07a6d05` | PASS, 48 tokens, 1,024/1,024 gather calls | PASS, 2 rows, 0 failures, 0 divergences; unequal-row continuation and peer leave/rejoin matched production serial tokens | eligible |

For the final Qwen3.8 run, the batched and production-serial references matched
exactly: final-prefill tokens `[271, 271]`, first shared-decode tokens `[40, 32]`,
and peer leave/rejoin tokens `[635, 32]`.

All three runs observed a non-identity physical-block permutation and the
packaged gather kernel identifier `macprovider_paged_kv_gather_v1`. The
metallib SHA-256 observed by the candidate was
`84e487182336648a826132e50e7a4cd2cae0bc77ac6eafa89cc72f3a964fdbaf`.

## Remaining gates

This evidence closes the Qwen3.8 local-proof blocker recorded after #1808. It
does not close the release boundary in #1778. The following still require a
separately authorized release campaign:

- reviewed signed and notarized packaged candidate;
- Malibu.app / standalone CLI byte-identity and previous-version updater proof;
- nonempty signed production CB policy bound to the final packaged identities;
- real coordinator buyer routing, billing, receipt, settlement, warm-swap, and
  rollback evidence for all three models.
