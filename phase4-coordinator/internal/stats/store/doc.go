// Package store is the SPEC-017 request-path DAO. It runs as the
// stats_reader role per SPEC §7.2.1 and is consumed by the
// handlers in internal/stats (Step 3).
//
// Step 1 establishes the package layout so the depguard
// import-graph lint (AC-16) has a real package to anchor on. The
// DAO methods land in Step 3 alongside the handlers.
//
// Per SPEC §7.6 + AC-16, this package MUST NOT import
// internal/billing, internal/explorer, internal/ws, or
// internal/auth (except a minimal Bearer parser whose exact
// symbol the depguard allowlist names — none in Step 1 since
// handlers do not exist yet).
package store
