# Pubkey Cache Implementation Notes

## File Format

The cache is JSON-Lines at:

- `$XDG_CONFIG_HOME/macprovider/verify-cache.jsonl` when `XDG_CONFIG_HOME` is set.
- `$HOME/.config/macprovider/verify-cache.jsonl` otherwise.

Each line is one independent entry keyed by `(coordinator_host, provider_id, receipt_pubkey)`.
Pubkeys are stored as standard padded base64 and decoded to 32-byte raw keys in Go.
`fetched_at`, `rotated_at`, and `expires_at` are stored as RFC3339 UTC strings.

## Atomic Write Strategy

`Put` reads valid existing entries, replaces only the entry with the same
`(coordinator_host, provider_id, receipt_pubkey)`, appends otherwise, then writes
the complete file to a temp file in the same directory. The temp file is synced,
closed, and moved into place with `os.Rename`; the cache directory is synced after
rename when the platform allows it.

This provides atomic replacement for readers and crash recovery at the file level:
after an interrupted write, callers should see either the previous complete file
or the renamed complete file, not a partially overwritten cache file.

## TTL

`TTL` is exported as `7 * 24 * time.Hour`. `Lookup` returns the freshest exact
tuple match plus a `fresh` boolean based on `now - fetched_at <= TTL`.

The resolver owns the policy decision for stale entries. The cache may return a
stale entry, but stale entries are not a trust root by themselves.

## Corruption Handling

Reads are line-tolerant. A malformed JSON line, invalid base64 key, or invalid
timestamp is logged and skipped. Valid lines before and after the corrupted line
remain usable. Whole-file read errors still abort the operation.
