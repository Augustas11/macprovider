# Build 1 integration storage correction — revision 1

Status: awaiting independent Astra gate. Supplements plan-r4/test-spec-r4.
The plan mistakenly named PostgreSQL for the request/admission/receipt/ledger
integration journey. Replace that specific backend name with the production
SQLite WAL stores used by the actual coordinator/gateway binaries. Do not add
a database migration or PostgreSQL support to implement a mistaken test premise.

Evidence: phase4-coordinator/cmd/coordinator/main.go opens auth/requestlog stores
from Storage.DBPath and constructs NewSQLiteModelAdmissionStore on reqLogStore.DB;
internal/billing/store.go uses modernc.org/sqlite with WAL.
phase5-gateway/cmd/gateway/main.go opens sqlite stores; test/integration/harness_test.go
runs opaque real binaries with coordinator.db/gateway.db fixtures. PostgreSQL
is used by other subsystems, not this admission/receipt/ledger persistence path.

B1-T09 remains real binaries, real authenticated WS transport, signed fixture
feeds and receipts, exact model/rate/provenance binding, durable persisted
admission/snapshot/ledger and exact buyer/provider/operator accounting. Add
database reopen/process restart checks proving persistence and replay/dedup
after restart. No mock store or in-memory-only substitute. B1-T10 actual MLX
physical evidence remains independently mandatory; deterministic providers are
fixture-only. Docker-dependent tests for changed PostgreSQL subsystems, if any,
must still run with real Docker and never count skipped runs as passed.

This correction changes the test backend to match production ownership without
reducing acceptance. No implementation or service storage architecture change.
