## Lane: SECURITY / MONEY PATH

Check:
- `coordinator.db` holds money-path state. Granting the `macprovider-stats` user a read ACL on it: is that least privilege acceptable, is the database read-only in the sandbox, and does the rollback restore the ACLs exactly?
- Is there any write path to `coordinator.db` from the mirror?
- `InaccessiblePaths` still hides secrets.
