Read `audits/2026-09-24/AUDIT_1690_M8_COMMON.md` first.

**Lane: code correctness.** Check:
- the snapshot hashing and file-identity validation (TOCTOU, symlinks, partial writes)
- the `/v1/models` process binding
- the offer path and its interaction with the existing BYOM offer/admission
- the coordinator matcher wrapper
- concurrency in the Swift runtime
- test adequacy
