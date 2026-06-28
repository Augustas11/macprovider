# [HIGH] Provider-reported prompt_tokens can inflate payouts

**File:** [`phase4-coordinator/internal/billing/formula.go`](https://github.com/Augustas11/macprovider/blob/main/phase4-coordinator/internal/billing/formula.go#L119-L141) (lines 119, 136, 141)
**Project:** macprovider
**Severity:** HIGH  •  **Confidence:** high  •  **Slug:** `other-payment-integrity`

## Owners

**Suggested assignee:** `augstar@gmail.com` _(via last-committer)_

## Finding

ComputeCredits copies promptTokens directly into the billable prompt count, only rejecting negative values or values above maxBillableTokens, then multiplies that value by the prompt rate. The completion side is protected by billableCompletion(), which clamps provider-reported completion_tokens to the coordinator-observed estimated_completion_tokens, but there is no equivalent coordinator-derived bound for prompt_tokens. In production flow, provider usage.prompt_tokens reaches HotPathInput.PromptTokens and then ComputeCredits; a malicious onboarded provider can report an inflated prompt token count up to 10,000,000 for a small buyer request and receive inflated prompt-side provider credits while still passing the current range checks.

## Recommendation

Carry a coordinator-observed prompt token estimate or reservation into billing, clamp provider-reported prompt_tokens to that value plus a tight tolerance, and quarantine or zero-credit rows with implausible prompt usage. Apply the same rule in hot path and recovery, and add regression tests for prompt over-reporting.

## Revalidation

**Verdict:** true-positive

ComputeCredits copies promptTokens into the billable prompt count at lines 119-122 and only applies invalidBillableTokenCount before multiplying by the prompt rate at line 141. The completion path is different: billableCompletion receives estimatedCompletionTokens and clamps provider-reported completion to the coordinator-observed estimate when present. I traced the hot path through buyer.billingRecorder.recordRow into billing.HotPathInput and WriteHotPath, and provider response usage is parsed directly by tokenPointersFromChatResponse/tokenPointersFromUsageObject. The only coordinator-derived prompt value I found is a fallback estimate when prompt tokens are absent on certain error/estimated-completion paths; it is not used as a cap when the provider supplies prompt_tokens. Recovery also reads request_log.prompt_tokens and passes it through to ComputeCredits. A malicious onboarded provider can return usage.prompt_tokens=10000000 for a small request, stay within the current maxBillableTokens check, and inflate gross/provider credits on the prompt-rate side while completion remains clamped.

## Recent committers (`git log`)

- a11 <augstar@gmail.com> (2026-06-03)
