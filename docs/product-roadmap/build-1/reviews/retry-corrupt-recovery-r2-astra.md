# Independent corrupt-journal withdrawal recovery gate — revision 2

Verdict: **APPROVED FOR IMPLEMENTATION** for the bounded non-destructive withdrawal improvement. Open findings: **0 Critical, 0 High, 0 Medium, 0 Low**. Main-plan, retry-journal and storage-test approvals remain unchanged.

Approved proposal: `retry-corrupt-recovery-r2.md`, SHA-256 `fd957ea3833b82e25ccfbf0c446e74744146ad042c8eedc05a7d4a1032a7366d`, independently checked. Base `914f7cafcdbcfc1805a10f4f34167218341d5587` and prior dependency `f5edeaebfb6c712a2cb6dced9020c8c78ed1053e` independently resolve to identical tree `30bbf6180005bdf2bb225170f2a58ca08954ac72`.

The reviewer read the exact durable proposal and the current WIP `BYOMPendingOfferJournal.Operation.load/reconcile` and `BYOMModelAdmissionRuntime.withdraw`, using the strict response-codec inspection from r1. Current WIP is not assumed complete. Only this review artifact was written; no code changes, tests, secret access, operator-store changes or external operations were performed.

## R1 M1 disposition

**Closed at plan level.** R2 removes deletion, replacement and quarantine of unrecoverable records. An authoritative withdrawal of selected coordinator tuple B no longer destroys or claims to reconcile undecodable local evidence A. Corrupt bytes remain byte-identical; subsequent retry/new-offer still require a valid signed envelope and remain blocked. This directly addresses the missing semantic binding identified in r1 without guessing a tuple, weakening server authority or losing recovery-critical bytes.

The improvement allows an explicitly requested network withdrawal to succeed independently of JSON corruption while truthfully reporting the continuing local recovery limitation. It does not claim that arbitrary corruption can be repaired automatically or that terminal state for B proves unrelated A was terminal.

## Required implementation interpretation and verification

- Bypass only the record-decoding failure after safe lock acquisition and bounded private regular-file validation. `JournalError.invalid` currently also covers security/identity/file validation failures; a blanket catch of that error would not implement the proposal. Unsafe paths, permissions, symlinks, nonregular files, read failures and inaccessible roots must not become permission to send a withdrawal.
- Obtain withdrawal authority from the current provider key and the explicit discovered/coordinator tuple. Retain strict response binding to provider, candidate, served-model reference, catalog key, idempotency key and reason; a generic `withdrawn` label is insufficient.
- Leave corrupt bytes untouched for success, rejection, timeout and malformed responses. Keep stdout as the existing closed coordinator wire response. Emit the sanitized success-plus-local-blocker warning only after verified withdrawal success; do not print envelope contents or secrets.
- Preserve generation checks for the existing valid-record cleanup path. This narrow approval does not certify unrelated WIP valid-record retirement logic or waive its normal authority-tuple checks and cumulative audits.
- Run the specified malformed-wrapper/unrelated-envelope preservation test, blocked retry/new-offer checks, valid cleanup regression, unsafe-file/root negatives and unsuccessful-withdrawal truthfulness checks. Verify byte identity before and after the action and absence of operator-identity changes.

No additional plan finding was identified. The explicit limitation for persistent unrecoverable local corruption preserves existing fail-closed behavior while adding safe withdrawal; it is not acceptance evidence for the full Build 1 journey. Fresh implementation tests, cumulative code/security/architecture audits, and the mandatory independently qualified physical preparation-to-settlement journey remain required.
