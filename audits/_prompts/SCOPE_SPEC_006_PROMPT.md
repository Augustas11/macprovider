# Scope prompt — SPEC-006 design exploration (pre-draft)

Operator-paste prompt that frames the SPEC-006 design challenge and asks
for a structured design analysis BEFORE the spec is drafted. Output of
this run is a design document the operator reviews + uses to lock a
single path; a separate `BUILD_SPEC_006_PROMPT.md` then drafts the spec
against that locked path in a fresh session.

Run in **Claude Code** or **Codex**. Expected duration: ~60-90 min for a
thorough design exploration. The output is prose + tradeoff tables, not
a normative spec.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session rooted at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are producing a design exploration for SPEC-006 (Mac Provider's
first buyer-facing surface). You are NOT drafting the spec yet — that
comes in a separate run after the operator locks a path from your
output. Your job is to structure the design space, name the real
tradeoffs, and recommend a single path given the operator's locked
principles.

Output location:
  /Users/augstar/macprovider-poc/specs/SPEC-006-design.md

Target length: ~800-1500 lines. Prose + tables + decision trees. Not a
normative spec — a design document that lets the operator make one
informed call rather than ten under-informed ones.

## The operator's locked framing (do not relitigate)

The operator has explicitly rejected the framing that drove an earlier
advisor pass. Specifically:

> "We shouldn't optimize for a market we don't know yet and don't have
> users to judge. We should optimize for network, infrastructure, and
> capabilities — meaning users who want easy access, no thrills installs,
> and cheapest price. Then we can get users and understand what our
> positioning is."

This is your north star. Three corollaries you must respect:

1. **No invented buyer personas.** Do NOT argue from "the kind of buyer
   who values privacy" or "enterprises in regulated industries" or any
   other speculative persona. We have no users; we cannot pretend to.

2. **No premium positioning.** Mac Provider's compute is consumer
   Apple Silicon at 4-bit quantization, ~20-30 tok/s on 3B-7B models.
   The market clearing price for that capability — at Groq, Cerebras,
   Together, DeepInfra, Fireworks — is $0.05-$0.90/M tokens at 80-2000
   tok/s on better hardware. There is no premium hiding. Don't invent
   one.

3. **No market-shape speculation.** Don't recommend "vertical" vs
   "horizontal," "B2B" vs "B2C," "enterprise" vs "indie." The operator
   has decided to learn this by observation, not assumption.

The optimization function for SPEC-006 is:

> Maximize (ease of access) + (capability surfaced) + (price advantage
> or non-extraction) - (operator effort to run)
> subject to:
>   - operator is one person
>   - no payment infrastructure currently exists
>   - no abuse defense currently exists
>   - existing coordinator at coordinator.malibu.tech serves
>     OpenAI-compat /v1/chat/completions today
>   - existing Vercel demo at web-three-lime-59.vercel.app is the
>     natural front-door

## Critical previous-pass mistake to avoid

A prior advisor (Claude) recommended "Venice-flavored Together.ai" with
premium pricing for curated open-weight models. The operator pushed
back correctly: there is no defensible premium for running Llama 3.2 3B
or Qwen 2.5 7B when Groq serves Llama 3.1 70B at $0.59/M at 500 tok/s.

Do NOT repeat this mistake. If your analysis arrives at "charge $0.50/M
because of [story]," you have failed. The story doesn't sell at that
price against the alternatives a buyer can google in 30 seconds.

## What you must do

Produce a design document that answers ten concrete questions, in
order. For each question, present 2-4 honest options, the tradeoffs,
and a recommendation. The operator will read this and lock a path.

### Q1. Access shape

What does "easy access, no thrills install" mean concretely for a
first-time user? Options to compare:

- (a) No signup at all — open API with IP rate limiting + per-IP quota
- (b) Email-only signup — magic link or one-click GitHub OAuth, get
      API key, no credit card
- (c) Signup + email verification + manual approval (waitlist)
- (d) Anonymous key issuance — visit page, click "give me a key,"
      get a UUID-shaped bearer token, no email at all

Evaluate against the operator's principles. What's the lowest-friction
that's still operable by one person without abuse spiraling?

### Q2. Price shape

What does "cheapest price" mean concretely given we want users to
actually use the network?

- (a) Free for everyone, capped at N tokens/day/user
- (b) Free first M tokens then $X/M after (X = ?)
- (c) Tiny flat per-token price ($0.01-$0.05/M), no free tier
- (d) Donation-funded — "pay what you want" / Stripe button, no metered
      billing
- (e) Tip the provider — bypass our cut entirely; donations go directly
      to the Mac that served the request

What's the math? With our coordinator costing ~$10/mo to host and
providers donating compute, what does the operator actually owe to
keep the lights on? Is "free with cap" sustainable indefinitely on
the operator's personal budget for the network size we expect in the
first 90 days?

### Q3. Capability surface

What capabilities of the existing network should v1 expose? Be
concrete about what the buyer can DO from day 1:

- Just `/v1/chat/completions` (text in, text out)?
- Plus `/v1/models` for discovery?
- Streaming SSE (we have it)?
- Multi-turn conversations? (we have it; it's part of OpenAI-compat)
- Function calling / tool use? (we technically support it through
  the model — does v1 expose it?)
- Vision? (no, not in our current model lineup)
- Embeddings? (no, not in scope)

The principle is "surface what we have." Make the inventory explicit.

### Q4. Identity + auth shape

How are requests authenticated?

- (a) Bearer token in `Authorization` header (standard OpenAI pattern)
- (b) API key in query string (lower friction, less standard)
- (c) JWT with usage-baked claims (complex, future-proof)
- (d) No auth at all v1 — just IP-based identification

What level of auth is the minimum that prevents abuse but doesn't
become an obstacle to "easy access"?

### Q5. Dashboard / observability for users

What does a user see about their own usage?

- (a) Nothing — fire and forget API
- (b) A `/usage` endpoint returning JSON they can curl
- (c) A web dashboard with charts (significant build cost)
- (d) Email reports (cron-driven)

What's the minimum that's still useful given the operator's effort
budget?

### Q6. Abuse defense (the unavoidable problem)

"Easy access + cheap/free" is exactly the configuration that attracts
abuse. What's the minimum-viable defense?

Concrete abuse vectors to consider:
- Scraping / harvesting outputs at scale to train competing models
- Spam (using us as a generic text-gen behind a different product)
- Adversarial inputs (jailbreaks, harmful prompts at scale)
- Denial-of-service (exhaust per-user quota across many fake users)
- Crypto-mining-style abuse (running indefinite generation jobs)

What's the floor of defenses that lets us open the door without
the door immediately falling off the hinges?

### Q7. Brand / front door

What does the existing Vercel demo (web-three-lime-59.vercel.app)
become under SPEC-006?

- (a) Stays as it is — "seeing is believing" chat demo, separate from
      the API product
- (b) Gets a signup flow added — chat demo becomes the conversion
      funnel for API access
- (c) Replaced by a new site at api.malibu.tech with docs + signup
- (d) Multiple surfaces (chat at malibu.tech, API at api.malibu.tech,
      docs at docs.malibu.tech)

What's a one-person-operator's minimum?

### Q8. Documentation surface

What docs exist day 1?

- (a) README on GitHub linking the API
- (b) A single-page docs site with curl examples + OpenAI SDK snippet
- (c) Full ReadMe.com / Mintlify-style docs
- (d) Just OpenAI compatibility — point users at the OpenAI docs since
      our API is the same shape

The principle is "no thrills install" applies to the API too — what
makes it dead-simple to integrate?

### Q9. The provider-side question

Providers are running Mac Provider for some reason. Today they
donate compute. Does SPEC-006 introduce a relationship change?

- (a) No change v1 — keep them on donation, SPEC-005 (rewards) handles
      compensation later when revenue exists
- (b) Show providers their contribution (per-provider request count,
      tokens served) — purely observational
- (c) Promise eventual revenue share without committing the mechanism
- (d) Implement basic revenue share v1 (couples SPEC-006 and SPEC-005)

What's the minimum that doesn't break the social contract with M4 +
M1?

### Q10. Failure mode

When the network is degraded (no providers ready, all draining, all
unavailable), what does the buyer experience?

- (a) HTTP 503 immediately
- (b) Queue request for up to N seconds, then 503
- (c) Friendly error explaining the network state, suggest retry
- (d) Health page (https://malibu.tech/status) showing live state

Tied to Q5; also a chance to make Mac Provider's nature ("real Macs,
sometimes asleep") part of the product experience rather than an
embarrassment.

## What you must NOT do in this design exploration

- Don't draft a normative spec (no MUST / SHOULD / RFC 2119 language).
  This is a design analysis, not a specification.
- Don't recommend a price denominated in dollars/M without showing the
  math against current market prices (Groq, Together, DeepInfra,
  OpenAI mini) for the same models.
- Don't invent buyer personas to justify a feature.
- Don't recommend any feature that requires more than 1 week of one
  person's work for v1.
- Don't speculate about what users WILL want — recommend what's
  observable + buildable + cheap to run while we wait for them.
- Don't add Stripe / billing / invoicing complexity to v1 unless your
  Q2 analysis specifically demands it. The operator's principle of
  "cheapest price" + "no payment infra yet" suggests deferring this.

## Required reading

1. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md`
   — read Entries 16-21 (the Day 2 + Day 3 production arc). Critical
   context for understanding the operator's situation and why the
   network exists.

2. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   — focus on § 6.2 (`/v1/models`) and § 6.4 (`/v1/chat/completions`).
   These define what the existing buyer-side wire format looks like
   on the provider end.

3. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   — focus on § 3 (mode resolution), § 5 (routing), § 7 (HTTP
   surfaces). The coordinator already exposes
   `/v1/chat/completions` on `https://coordinator.malibu.tech`;
   SPEC-006 layers auth + billing + signup on top of that, not a new
   protocol underneath.

4. `/Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md`
   — the distribution-side parallel of SPEC-006. SPEC-003 made
   provider onboarding `curl-pipe-bash` easy; SPEC-006 should make
   buyer onboarding equally easy.

5. The existing Vercel demo's repo (if accessible). The operator
   notes there's a working "seeing is believing" chat UI at
   web-three-lime-59.vercel.app that proxies to the coordinator.
   It's a candidate front door.

6. Current market prices for the models we serve. Reference the
   table in DECISION_CRITERIA.md Entry-22 (the operator's
   counter-pushback message — Groq Llama 70B at $0.59/M, DeepInfra
   8B at $0.05/M, etc.) Use these as your price-floor reality check.

## Output structure

```
# SPEC-006 Design Exploration

## 1. Operator's framing (1 paragraph, restate to confirm understanding)

## 2. What Mac Provider actually is, infrastructure-wise (1 page)
   - The network as it stands May 2026
   - What we can serve (model lineup, latencies, capacities)
   - What we cannot serve (be explicit about the ceiling)

## 3. The ten questions
   ### Q1. Access shape
   - Options
   - Tradeoff table
   - Recommendation + why
   ### Q2. Price shape
   ...
   ### Q10. Failure mode
   ...

## 4. Recommended path (synthesizing Q1-Q10)
   - The single coherent product shape that emerges
   - What it does day 1
   - What it explicitly defers
   - Estimated 1-week build scope

## 5. Open questions for operator
   - Things you couldn't decide without operator input
   - List with one-sentence framing each

## 6. What would falsify this design
   - In 90 days of running this, what observed user behavior would
     tell us "the design was wrong and we should pivot to X"?
   - In 90 days of running, what would tell us "the design was right,
     here's what to build next"?
```

The Section 6 reframe is the most important one: this design only
works if it's instrumented to teach us something. Spell out what we
learn from running it and how.

When done, print a 200-word handback summary noting:
- the recommended product shape in one sentence
- the three biggest tradeoffs the operator must confirm
- the explicit list of features deferred to v2/SPEC-007+

Then stop. Do not begin drafting the spec.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist (~30 min):

1. Read `specs/SPEC-006-design.md` start to finish.
2. For each of Q1-Q10, decide: accept recommendation, modify, or
   reject. Mark up in a separate notes file or directly in the
   design doc.
3. Section 4 (recommended path) is the lock decision: does this
   coherently match the operator's principles?
4. Section 6 (falsification) is the most important — if the design
   can't fail in a way we'd notice, it can't succeed in a way we'd
   notice either.

After review, draft `BUILD_SPEC_006_PROMPT.md` with:
- The locked design from Section 4 as the "Locked design choices"
  header
- The deferred features list as explicit out-of-scope
- The falsification metrics from Section 6 as acceptance criteria

Then run BUILD prompt in a fresh session to produce
`specs/SPEC-006-buyer-api.md` v0.1, ready for audit.

## Why two prompts instead of one

The earlier SPEC-001/002/003 BUILD prompts conflated "decide the
design" with "draft the normative spec." That worked because those
were protocol specs where the design space was narrow (it's a
WebSocket protocol, what is there to design beyond "what messages?").

SPEC-006 is the first product spec. The design space is genuinely
open — auth model, pricing, abuse defense, front door — and
conflating "decide" with "draft" produces specs that hide the
tradeoffs in normative language ("the system MUST X" without showing
that X was one of four options and Y/Z were rejected for these
reasons).

Splitting the two stages forces the design analysis to surface and
makes the eventual normative spec readable as "here's the locked
decision and why" rather than "here's some MUSTs."
