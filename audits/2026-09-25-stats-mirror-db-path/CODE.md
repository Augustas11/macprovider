## Lane: CODE

Check:
- Every former `request-log.sqlite` path is covered, including rollback restore of the ACLs.
- The WAL/SHM `ReadOnlyPaths` for `coordinator.db`.
- The mirror reads `coordinator.db` read-only (`ReadOnlyDSN`) without blocking the coordinator writer.
- The tests.
