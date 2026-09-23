## Raw output

```text
- LOW — `phase4-coordinator/internal/ws/server.go:556`: `buildCompatibleCatalogSet` stores release IDs and catalog SHA-256 values in one map namespace. A retained catalog whose release ID equals another retained catalog’s digest can overwrite that digest entry, causing a valid provider envelope to resolve to the wrong catalog and be rejected as `catalog_incompatible`. This is the carried R1 LOW; release IDs are operator-controlled and conventionally non-hex. Split the index into `byReleaseID` and `byCandidateSHA256` maps, or namespace the keys, and add a collision regression test spanning previous, restamp, and row-continuity entries.

VERDICT: C=0 H=0 M=0 L=1
