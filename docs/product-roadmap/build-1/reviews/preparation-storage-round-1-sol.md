# Build 1 preparation secure storage: implementation review round 1

Date: 2026-09-12
Status: **FAIL; correction required before PR or acceptance**

## Reviewed revision and evidence

- Base: merged authority `c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f`.
- Contract: `9e72f1fdb6efefbfcd38e175e13444a6f88b17d8` (#1491); four intent-to-add storage/source-test files in `codex/build1-preparation-storage`. The cumulative six-file working diff was reviewed, not merely the four new files.
- Approved v20 plan SHA-256: `8045eccb1660e98a8213bbcf41b5a0b26f72970324a7f92bcf3afca152addf57`; test specification SHA-256: `f218249c00586c829a8364971ea3fa2382c789e2f7c78b019c60741a96794c0f`.
- Fresh `swift test --disable-automatic-resolution --filter 'ModelPreparation(Root|PrivateStore|PrivateCodec)Tests'`: 37 selected XCTest cases, 0 failures; the separate Swift Testing runner selected zero and is not counted. `git diff --check c8c97f66` passed. Neither establishes full storage acceptance.

## Independent native GPT-5.6 Sol verdicts

| Lane | Critical | High | Medium | Low | Result |
| --- | ---: | ---: | ---: | ---: | --- |
| Code | 0 | 3 | 3 | 0 | FAIL |
| Security | 0 | 0 | 8 | 1 | FAIL |
| Architecture | 0 | 6 | 2 | 0 | FAIL |

Findings overlap; counts are per lane, not an additive count of unique defects. Evidence is in the reviewed `ModelPreparationPrivateStore.swift`, `ModelPreparationSecureFilesystem.swift`, `ModelPreparationContracts.swift`, and focused tests at the working revision above.

## Consolidated required corrections

1. **Lock and authority custody (High):** creating lock files does not acquire `flock`; writes and recovery need the specified lock graph, saved-root locator verification, and cross-process/config-change tests (`PrivateStore.swift:40-155`).
2. **Inner semantic validation (High):** arbitrary bytes currently pass checksum-only outer envelopes in write/read/recovery; decode and validate each closed kind and root correlation before mutation or use. Tests currently use invented payloads (`PrivateStore.swift:80-127,425-454,509-590`; `PrivateStoreTests.swift:13,40,48`).
3. **Cleanup namespace mismatch (High):** codec accepts published `artifactIdentityDigest`/`<digest>.tombstone` leaves while v20 places objects under `<tuple-sha256>` and tombstones under `.tombstone-<cleanup-transaction>`; verify staging leaves too (`ModelPreparationContracts.swift:1606-1614`; v20 plan layout). Reopen #1491 exact contract audit after correction.
4. **Monotonic generations (High):** a lower generation replaces a newer durable state; enforce increasing generations under custody and test rollback (`PrivateStore.swift:426,455-462`).
5. **Recovery classification and bounds (High/Medium):** empty crash-created temps wedge both paths; arbitrary names are ignored or opened before exact grammar checks; malformed entries evade caps; valid-but-misbound records are deleted; excess throws instead of bounded deterministic cleanup. Distinguish incomplete recognized writes from hostile complete records, stream/count bounded entries, and test every branch (`PrivateStore.swift:333-375,487-552`).
6. **Descriptor and ACL races (High/Medium):** a regular-file precheck can be swapped to FIFO before blocking open; sensitive reads, writes, renames and unlinks need immediately adjacent same-descriptor/name/parent checks and race tests (`SecureFilesystem.swift:159-224,287-318`; `PrivateStore.swift:433-472`).
7. **Root durability and conflict (Medium):** complete conflicting root identity must fail closed rather than be erased; post-rename recovery requires source/target parent barriers and final reopen/readback (`PrivateStore.swift:203-205,358-402`).

The security lane additionally recorded Low source-parent sync omission; it is included in item 7. The initial tests omitted injected syscall failure, descriptor-swap, saved-root, and complete hostile-temp cases. These are open verification requirements, not passed checks. This round does not change the approved v20 architecture. Any material contract/architecture change must reopen its plan gate before implementation.
