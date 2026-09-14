# Independent storage-test correction gate — revision 1

Verdict: **APPROVED**. Open findings: **0 Critical, 0 High, 0 Medium, 0 Low**.

Approved addendum: `storage-test-addendum-r1.md`, SHA-256 `2bf83b9cc55140c634aec51a08703967243af7db33913967b750b4dd1460adb6`, independently checked. This approval corrects the database-backend reference in approved plan-r4/test-spec-r4 and its physical/integration journey descriptions; other plan requirements and the approved retry-journal addition remain unchanged.

## Independent code evidence

- `phase4-coordinator/cmd/coordinator/main.go:199` and `:205` open auth and request-log stores against `cfg.Storage.DBPath`. `:257` constructs `NewSQLiteModelAdmissionStore(reqLogStore.DB())`; `:280` constructs `billing.NewStore(reqLogStore.DB())`. Admission, request evidence and ledger persistence therefore share the actual SQLite-backed coordinator path.
- `phase4-coordinator/internal/requestlog/store.go:156`–`:179` opens the SQLite driver and enables WAL. `phase4-coordinator/internal/billing/store.go:72`–`:76` explicitly verifies WAL journal mode.
- `phase5-gateway/cmd/gateway/main.go:48` opens its SQLite store from `cfg.Storage.DBPath`. `phase5-gateway/internal/storage/sqlite/store.go` enables `journal_mode = WAL` on the write store.
- `test/integration/harness_test.go` builds coordinator/gateway as opaque binaries, allocates isolated `coordinator.db` and `gateway.db` files (`:346`–`:347`), starts actual service processes, and queries persisted SQLite records. This is an existing integration foundation, not PostgreSQL or an in-memory store.

The PostgreSQL wording in the earlier plan was an incorrect factual premise. Using the implementation's actual persistent backend is a correction, not a reduction to a mock or a storage-architecture change. Adding PostgreSQL solely to satisfy that premise would test a new implementation rather than the shipped ownership path.

## Acceptance preserved

B1-T09 still requires real coordinator/gateway binaries, authenticated provider WS traffic, signed fixture feeds and receipts, exact model/rate/artifact provenance, immutable admission/snapshot evidence, persisted settlement and exact buyer/provider/operator accounting. Reopen/process-restart tests additionally prove persistence and replay/dedup across service lifetimes. They must reopen the same database files rather than reseed successful admissions, snapshots or ledger entries after restart. A fixture provider remains explicitly a fixture; database fidelity does not prove physical inference.

B1-T10 remains mandatory actual MLX preparation, measurement, activation, authoritative admission, buyer execution, receipt persistence and verified accounting on the specified Mac with isolated custody and independently qualified material. Its persistent service stores use the same production SQLite paths in isolated test locations. Nothing in this approval permits fixture evidence to substitute for physical acceptance or permits production activation.

Tests for changed PostgreSQL-owning subsystems, if any, retain their real backend/Docker requirements. Existing required tests cannot be skipped and reported as passed. Restart/reopen evidence proves the tested process-recovery cases; it does not by itself establish hardware power-loss guarantees beyond the deployed SQLite durability configuration.

This was a read-only code and addendum review except for this report. No tests, database mutations, operator-store access or external-service operations were performed. Only this review file was written. Implementation and cumulative code/security/architecture audit gates still apply; the review approves the corrected test design, not current WIP correctness or completed acceptance.
