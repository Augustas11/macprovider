Lane: SECURITY REVIEW. Read audits/2026-10-13-1644/AUDIT_COMMON.md first and follow it.

Focus:
- Can a provider distinguish a verification request from buyer traffic through
  any field, header, id shape, account scope, conversation key, timing, or
  sampling parameter visible on the provider side (inference_request frame and
  settlement metadata)?
- Can a provider or scorer forge, replay, or misroute compute_score_result_v1,
  frame another provider, or avoid scoring; are scorer/session bindings
  enforced? Can a scorer learn anything it should not?
- Admin and provider endpoints: authentication, input validation, audit
  logging, information exposure (prompts/outputs never exposed or logged).
- In-process dispatch: service-token use, internal headers, no buyer debit,
  correct provider credit; reserved cip_ accounts.
- Money path: can a hold be bypassed, made permanent by an attacker, or used to
  create or destroy money? R-7.8 interplay. SQL construction safety.
- Resource exhaustion: bounds on sizes, concurrency, memory, DB growth.
