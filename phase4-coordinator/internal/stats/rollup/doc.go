// Package rollup is the SPEC-017 rollup job package. It runs as
// the stats_rollup role per SPEC §7.2.2 and produces the rows
// that internal/stats/store reads.
//
// Step 1 establishes the package layout so the depguard
// import-graph lint (AC-16) has a real package to anchor on. The
// rollup tick code lands in Step 2.
//
// Per SPEC §4.2 + AC-16, this package MAY import
// billing/session/pool READ-ONLY paths (the rollup runs
// out-of-band) but MUST NOT import internal/explorer (an
// operator-only admin surface; AC-16 forbidden set) and MUST NOT
// import internal/ws. It MUST NOT import internal/stats or
// internal/stats/store — the rollup is the writer side; the
// request-path is the reader side; they share only the database,
// not Go imports.
package rollup
