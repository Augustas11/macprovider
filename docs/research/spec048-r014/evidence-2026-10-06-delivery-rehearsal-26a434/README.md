# Native-MTP delivery, serving, accounting and revocation rehearsal (2026-10-06)

This is the isolated Studio rehearsal of the post-merge path, run against a
test key (#1770). It covers plan section 5, G3/G5/G14 delivery, G8, and the
emergency-revocation drill.

| Field | Value |
| --- | --- |
| Source | `mtp/enablement` at `84a28cadc`. The lab-harness build is `swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS`, with the v1.8.217 `mlx.metallib`. |
| Lab binary | SHA-256 `b2438f77…`, ad-hoc CDHash `9d33390c…` (`rehearsal-release.json` `facts`) |
| Coordinator, gateway | Built from the same branch. Loopback 19301/19302/19310, SQLite, settlement in observe mode, `enforce_provider_admission: true` |
| Release | `scripts/native_mtp_rehearsal_release.py` re-cuts the artifact-feed activation and then the native-MTP release with the local-only test key `native-mtp-rehearsal-test-v1`. 144 revocation slots were pre-signed. |
| Runner | `scripts/native_mtp_enablement_rehearsal.py`, under the lab lock, with `--isolate-lifecycle` and isolated local state using a cloned target fixture (no drafter). |
| Host | Apple M3 Ultra, 256 GB, macOS 26A434. The live provider and auxiliary provider pools were not touched. |

## Result (`result-full-run.json`, 16:40–17:01Z)

| Check | Result |
| --- | --- |
| Static feeds served by the coordinator (catalog, CB policy, artifact feed, native set, revocations) | pass |
| Lab origin and test key active (release builds have neither) | pass |
| Admission set fetched and materialized into the private 0700 directory | pass |
| Drafter `mlx-community/Qwen3.6-35B-A3B-MTP-4bit@0295b814` fetched into the store and verified (G14) | pass |
| CB authorized by the signed policy (`mixed`, `live_verified`) | pass |
| Native admitted; self-test passed; tuple offered; coordinator canary `pass` | pass |
| Native rows served through the gateway: 7 requests, 225 proposed, 193 accepted, 419 committed | pass |
| G8: greedy content, usage, ledger, request log and usage deltas identical with native on and native off | pass in `result-g8-rerun.json`; see note |
| Restarted provider re-admits (third start in the run) | pass |
| Emergency revocation: a replacement slot batch was swapped in at 16:45:52Z; the provider disabled the tuple (`tuple_revoked`) at its next poll, 17:00:53Z; ordinary decode still served 200 | pass |

**G8 note.** In the full run, `request_log.estimated_completion_tokens` for
the one streamed request was 1410 with native on and NULL with native off.
Every billed column was identical (completion tokens, charged prompt tokens,
gross and provider credits). The rerun with SSE capture reproduced identical
deltas, with byte-identical SSE content in both modes. Its two capture
streams both recorded an estimate of 356. The byte estimate is filled
intermittently when a delivered stream's usage frame is not counted. It does
not depend on the decode path, and it is not billed when the provider usage
is present. It is recorded here as a pre-existing coordinator observation.

## Defects found and fixed on the branch

Each defect below would have kept native MTP off in production.

1. `0d40cc7ff`: a lab join skipped the catalog preflight, and with it the
   native fetch.
2. `9cc16573e` (G14): the fetched set's projection resolved against the
   member directory, and nothing delivered the drafter.
3. `c43ad1a80`: static feeds hit the coordinator's 10/s
   limiter at serve start (429 → silent fallback), and the revocation fetcher
   refused the lab origin.
4. `608c9b0ff`: the revocation anchor needs a login keychain that an SSH lab
   session cannot write. This is a lab-only file store.
5. `2a416bfa4`: both bank parsers required `committed == len(tokens)`. The
   scheduler commits one fewer, so no real bank could load.
6. `fee90fa05`: the coordinator canary required `alg: "Ed25519"`, but the
   release's static-feed signature says `ed25519`.
7. `9840be696`: native status was published into a sink the scheduler never
   held, so status always reported zero native activity.
8. `3ef43ea83`: the tuple offer compared the catalog key with the served wire
   id as strings, so the canary never ran.
9. `84a28cadc`: the self-test probe claimed the durable replay window, so
   every restart failed the self-test.

The rehearsal is the evidence for each fix.
