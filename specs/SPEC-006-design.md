# SPEC-006 Design Exploration
## 1. Operator's Framing
Mac Provider's first buyer-facing surface is not a positioning exercise.
The first version is a learning surface for a real inference network:
make access easy, expose the capabilities already working, make the
price or non-extraction advantage obvious, and keep the operating burden
small enough for one person. The network is consumer Apple Silicon
running small open-weight models; it cannot justify premium pricing
against faster and stronger commodity inference providers. SPEC-006 is
therefore about removing friction and adding enough identity, quota,
documentation, and observability to let strangers try the network without
turning the coordinator into an abuse magnet.
## 2. What Mac Provider Actually Is
### Current Network
As of the May 28, 2026 decision log, Mac Provider has crossed from
prototype into a small live network.
The coordinator is live at `https://coordinator.streamvc.live`.
The coordinator exposes an OpenAI-compatible buyer API:
- `GET /v1/models`
- `POST /v1/chat/completions`
- streaming SSE via `stream: true`
The provider side has moved to outbound WebSocket tunneling for new
providers.
That is the important infrastructure fact.
Providers do not need public inbound URLs in the current architecture.
They connect out to `wss://coordinator.streamvc.live/ws/provider`.
The coordinator routes buyer HTTP requests over that provider WebSocket
when needed.
Pinned providers can still run via legacy direct tunnel paths.
The live production pool has demonstrated two real Macs:
- M4-class MacBook Air serving Qwen 2.5 7B 4-bit.
- M1-class Mac serving Llama 3.2 3B 4-bit.
Decision log entries record real production completions through the
coordinator in roughly 2.3-3.4 seconds for small prompts.
Those numbers are encouraging for "it works."
They are not competitive with hyperscale inference speed.
The coordinator has also demonstrated:
- Aggregated `/v1/models`.
- Non-streaming chat completions.
- Streaming SSE relay.
- Dynamic provider admission.
- Provider drain handling.
- Provider reconnect after coordinator restart.
- Basic provider-side capacity fields.
- Request logs in SQLite.
- Public provider onboarding through `get.streamvc.live/install.sh`.
### What Buyers Can Use Today
The buyer can call the coordinator with standard OpenAI-shaped chat
requests.
The request body can include normal chat fields:
- `model`
- `messages`
- `max_tokens`
- `temperature`
- `top_p`
- `stream`
- `stop`
- `presence_penalty`
- `frequency_penalty`
- `seed`
- `response_format`
- syntactic `tools`
- syntactic `tool_choice`
The coordinator relays responses that match the provider response shape.
For streaming, it relays text/event-stream chunks through nginx without
buffering.
For model discovery, `/v1/models` lists model identifiers plus Mac
Provider extensions:
- `provider_count`
- `max_context_tokens`
- `total_slots`
The extensions are useful because the product is a live volunteer Mac
pool, not an abstract model SKU table.
### Current Model Lineup
The concrete model lineup in the repo and decision log is:
- `mlx-community/Qwen2.5-7B-Instruct-4bit`
- `mlx-community/Llama-3.2-3B-Instruct-4bit`
The rough performance envelope is:
- 3B-7B models.
- 4-bit quantization.
- Consumer Apple Silicon.
- Low concurrency per Mac.
- Roughly tens of tokens per second on warm paths, with current observed
  production round trips around a few seconds for short generations.
The capability is useful for lightweight chat, demos, simple agents,
small structured outputs, and "try a live Mac network" proof.
The capability is not a replacement for fast hosted 70B models.
### Current Ceiling
Mac Provider does not currently offer:
- Vision.
- Embeddings.
- Fine-tuning.
- Batch jobs.
- Dedicated capacity.
- Enterprise auth.
- Billing.
- Payment method collection.
- Abuse scoring.
- Model safety filtering.
- Cryptographic proof of model execution.
- Strong quality guarantees.
- High throughput.
- Always-on availability across many regions.
The biggest product risk is not that users misunderstand these limits.
The biggest product risk is that the surface hides these limits and
causes buyers to compare it to Groq, Cerebras, DeepInfra, Together,
Fireworks, or OpenAI on the wrong axis.
The v1 surface needs to make the network easy to try while remaining
honest that this is a small volunteer Mac pool.
### Market Price Reality Check
Current hosted inference prices reinforce the operator's pushback.
The price floor is brutal.
Representative public pricing checked on May 28, 2026:
| Provider | Example public reference | Reality check |
|---|---|---|
| Groq | Groq lists Llama 3.3 70B Versatile at $0.59/M input, $0.79/M output, and about 394 TPS on its pricing page. | A stronger 70B model is cheap and much faster. |
| DeepInfra | DeepInfra lists Llama 3.1 8B Turbo at $0.02/M input and $0.03/M output. | Commodity small models can be nearly free per request. |
| DeepInfra | DeepInfra's Qwen 2.5 7B page notes the model is redirected due to low usage. | Even model availability is commodity and fluid. |
| Together | Together's pricing page shows small open models in the low cents to low tenths per million tokens. | Buyers can find cheap open-model APIs quickly. |
| Fireworks | Fireworks publishes serverless per-token pricing and points buyers to model-specific docs. | Professional UX exists around the same model class. |
| Cerebras | Cerebras' inference launch pricing put 8B around $0.10/M and 70B around $0.60/M, with very high speeds. | Speed is a visible competing dimension. |
| OpenAI | OpenAI's GPT-4.1 mini page lists $0.40/M input and $1.60/M output. | Even proprietary mini-class models cap willingness to pay. |
Sources used for this checkpoint:
- [Groq pricing](https://groq.com/pricing)
- [DeepInfra Llama 3.1 8B Turbo](https://deepinfra.com/meta-llama/Meta-Llama-3.1-8B-Instruct-Turbo/api)
- [DeepInfra Qwen 2.5 7B](https://deepinfra.com/Qwen/Qwen2.5-7B-Instruct/api)
- [Together pricing](https://www.together.ai/pricing)
- [Fireworks serverless pricing](https://docs.fireworks.ai/serverless/pricing)
- [Cerebras inference launch](https://www.cerebras.ai/press-release/cerebras-launches-the-worlds-fastest-ai-inference)
- [OpenAI GPT-4.1 mini](https://platform.openai.com/docs/models/gpt-4.1-mini)
The implication is simple:
Mac Provider cannot win v1 by charging a premium for small open models.
It can only win early attention by being easy, cheap/free, transparent,
and weirdly real enough that users try it and teach the operator what it
is for.
## 3. The Ten Questions
### Q1. Access Shape
Question: what does "easy access, no thrills install" mean for a first
buyer?
#### Options
| Option | Shape | Ease | Abuse Risk | Operator Burden | Learning Value |
|---|---|---:|---:|---:|---:|
| A | No signup, open API, IP quota | Highest | Highest | Medium once abused | Low identity signal |
| B | Email-only or GitHub OAuth, key, no card | High | Medium | Low-medium | High enough |
| C | Signup plus manual approval | Low | Low | High | Biased sample |
| D | Anonymous key button, no email | Very high | High | Medium-high | Weak identity |
#### Option A: No Signup
This is the purest interpretation of "easy."
The user copies a curl command and gets a completion.
No key.
No account.
No email.
No credit card.
This would maximize trial rate.
It would also collapse identity to IP address.
IP identity is brittle:
- NAT makes unrelated people share quota.
- VPNs make one person look like many people.
- Cloud abuse can rotate IPs.
- The operator has little forensic trail.
The only version that feels safe is a tiny unauthenticated playground
quota.
That can be useful for the Vercel demo.
It is not enough for public API access.
#### Option B: Email or GitHub OAuth
This is the pragmatic low-friction path.
The user clicks "Get API key."
They choose magic link email or GitHub OAuth.
They receive a bearer token.
They do not add a payment method.
They can paste the key into an OpenAI SDK snippet.
This creates:
- A stable account row.
- A revocable API key.
- A daily quota ledger.
- A path to contact real users later.
- Enough friction to slow commodity abuse.
The downside is real:
- Email signup is more friction than "curl now."
- OAuth adds web implementation work.
- Email delivery can become its own little operational chore.
But for one person running a free API, this is the cleanest tradeoff.
#### Option C: Manual Approval
This makes abuse easier to control.
It also converts a network learning surface into a waitlist.
Manual approval biases the sample toward people willing to wait.
That directly conflicts with the operator's goal of observing what
strangers do when access is easy.
It also creates operator toil.
This is the wrong v1 default.
It can remain as an emergency valve if abuse arrives faster than quota
defense.
#### Option D: Anonymous Key Issuance
This is attractive because it preserves the "give me a key" moment.
The user clicks a button and gets a UUID-shaped bearer token.
No email.
No OAuth.
No identity.
It improves over no-auth because the key can be revoked and metered.
It does not solve Sybil abuse.
An attacker can mint many keys unless issuance is tied to IP, browser
fingerprint, proof-of-work, or captcha.
Those defenses are either weak, invasive, or annoying.
For v1, anonymous key issuance is excellent for a tiny demo quota.
It is weak as the main API account model.
#### Recommendation
Use Option B for the public API:
- Email magic link or one-click GitHub OAuth.
- API key issued immediately.
- No credit card.
- No manual approval.
- Low default daily quota.
- Revocation available to operator.
Add a very small Option A/D style demo allowance only inside the chat
front door:
- No-key demo requests.
- Low per-IP cap.
- Small `max_tokens`.
- Clear transition to "get key" when the cap is reached.
This is the lowest-friction shape that still leaves the operator with
identity, revocation, and usage data.
### Q2. Price Shape
Question: what does "cheapest price" mean when the goal is usage and
learning, not extracting revenue before the product exists?
#### Options
| Option | Shape | User Friction | Infra Complexity | Abuse Risk | Revenue |
|---|---|---:|---:|---:|---:|
| A | Free for everyone, capped daily | Low | Low | Medium | None |
| B | Free first M tokens, then $X/M | Medium | High | Medium | Small |
| C | Tiny metered price, no free tier | High | High | Low-medium | Small |
| D | Donation-funded | Low | Low-medium | Medium | Uncertain |
| E | Tip provider directly | Medium | Medium-high | Medium | Bypasses operator |
#### Cost Math
The coordinator cost is approximately $10/month.
Domain cost is already paid.
Cloudflare tunnel cost is currently zero.
Provider compute is donated.
Marginal operator cash cost for the first 90 days is therefore mostly:
- Coordinator VPS: about $10/month.
- Domain amortization: about $1/month.
- Email provider or auth service: likely free tier at v1 volume.
- Logs/storage: likely included.
Call the cash floor $10-$20/month.
The real cost is operator time and provider goodwill.
The monetary burn from inference is not the binding constraint if
providers are donating compute.
The binding constraints are:
- Abuse.
- Provider saturation.
- Support load.
- Network credibility.
#### Market Math
At commodity prices, 1 million tokens of small-model inference can cost
only a few cents at DeepInfra.
A daily quota of 50,000 total tokens per account has market replacement
cost below a cent on the cheapest providers.
A daily quota of 250,000 tokens per account has replacement cost still
in the pennies.
This means buyers will not understand a complicated payment wall for a
small volunteer Mac pool.
It also means the operator can give away a meaningful trial without
pretending the token value is high.
#### Option A: Free With Cap
This best matches the operator's current goals.
It avoids payment infrastructure.
It gets users using the network.
It makes "cheapest" literally true for v1.
It lets the operator observe:
- Signup conversion.
- Time to first request.
- Models selected.
- Error rates.
- Quota exhaustion.
- Repeat usage.
- Abuse patterns.
The risk is that free access attracts abuse.
That risk is handled by identity plus quota, not by premature billing.
#### Option B: Free Then Paid
This sounds businesslike.
It creates a large implementation tail:
- Stripe checkout.
- Metered billing.
- Pricing page.
- Payment failures.
- Invoices.
- Refunds.
- Tax/accounting questions.
- User support.
For a one-person v1 without product-market evidence, this is too much.
It also forces the operator to pick a price before the network has usage
data.
This repeats the mistake the prompt warns against.
#### Option C: Tiny Per-Token Price
Charging $0.01-$0.05/M looks rational because it is below commodity
competitors.
But any required payment method destroys the "try now" path.
The tiny price would not fund meaningful provider compensation.
It would create the full billing burden for trivial revenue.
This is a bad v1 trade.
#### Option D: Donation-Funded
A donation button can exist without metered billing.
It communicates non-extraction.
It gives supportive users an outlet.
It should not be the core price model because donations are not a
reliable access-control mechanism.
It can be added after the API works.
#### Option E: Tip The Provider
This is philosophically appealing.
It aligns money with the Mac that served the request.
It also opens a provider-identity and payout problem before SPEC-005.
It may unintentionally promise fairness accounting the system does not
yet have.
This belongs after provider contribution tracking is trustworthy.
#### Recommendation
Use free capped access for v1.
Concrete default:
- No payment method.
- 25,000-100,000 total tokens/day/account to start.
- 1,000-2,000 total tokens/day/IP for unauthenticated demo traffic.
- Low `max_tokens` default.
- Hard per-request output cap.
- Operator can adjust caps in config without redeploying code.
Add a plain donation/support link only if it takes less than a day and
does not create metered entitlement.
Do not implement billing in SPEC-006.
The first 90 days are sustainable on the operator's personal budget if
the quota is capped and the pool remains small.
If usage grows beyond the personal budget, that is a success signal for
SPEC-007/SPEC-005, not a v1 blocker.
### Q3. Capability Surface
Question: what capabilities should v1 expose?
#### Options
| Capability | Exists Now | Buyer Value | Build Cost | v1 Choice |
|---|---:|---:|---:|---|
| `/v1/chat/completions` | Yes | Highest | Already exists | Expose |
| `/v1/models` | Yes | High | Already exists | Expose |
| Streaming SSE | Yes | High | Already exists | Expose |
| Multi-turn messages | Yes | High | Already exists | Expose |
| Function/tool syntax | Partial | Medium | Already parsed | Document as syntactic |
| JSON object mode | Partial | Medium | Already shaped | Expose carefully |
| Vision | No | Unknown | High | Defer |
| Embeddings | No | Medium | New subsystem | Defer |
| Reranking | No | Unknown | New subsystem | Defer |
| Batch | No | Unknown | New subsystem | Defer |
#### Expose Chat Completions
This is the network's primary buyer contract today.
It is already OpenAI-compatible enough for standard SDK use.
It is the shortest route from "I have an API key" to "I got tokens."
It deserves to be the center of the docs, examples, and demo.
#### Expose Models
`/v1/models` is important because Mac Provider capacity is live and
variable.
Buyers need to know what is available before they call.
The extensions are also useful:
- `provider_count` tells whether a model is served by one Mac or more.
- `total_slots` hints at current concurrency.
- `max_context_tokens` keeps expectations realistic.
This endpoint is also a gentle way to teach the nature of the network.
#### Expose Streaming
Streaming is already verified through nginx and the coordinator relay.
It makes the product feel alive even when total latency is not
hyperscaler-fast.
It also reduces perceived waiting cost for small models.
Streaming is worth highlighting in the first curl example.
#### Expose Multi-Turn Conversations
Multi-turn is not server-side conversation storage.
It is the normal OpenAI chat pattern:
- Client sends prior messages.
- Model sees the context.
- Server returns one response.
This is already supported by the request shape.
Docs can show it without adding server state.
#### Function Calling And Tool Use
The current stack parses tool shapes syntactically.
It does not execute tools.
The model may emit tool-like text or tool calls depending on prompt and
model behavior.
The v1 docs can say:
- Tool fields are accepted when syntactically valid.
- The API does not execute tools.
- Reliability is model-dependent.
- For strict agent use, test before relying on it.
Do not market this as "function calling" equivalent to a mature hosted
model API.
#### JSON Mode
`response_format: { "type": "json_object" }` is a useful small feature.
The decision log already showed earlier criteria confusion around
agent-style JSON reliability.
Expose JSON object mode as best-effort structured generation.
Do not claim schema enforcement.
#### Recommendation
Surface exactly what exists:
- `GET /v1/models`
- `POST /v1/chat/completions`
- Streaming SSE.
- Multi-turn messages in the OpenAI-compatible request shape.
- `response_format: json_object` as best-effort.
- Syntactic tool fields as accepted but not executed.
Explicitly defer:
- Vision.
- Embeddings.
- Tool execution.
- Schema-constrained structured outputs.
- Batch.
- Dedicated endpoints.
The rule is "thin wrapper over the coordinator plus auth/quota."
### Q4. Identity And Auth Shape
Question: how are requests authenticated?
#### Options
| Option | Shape | Standardness | Ease | Abuse Control | Build Cost |
|---|---|---:|---:|---:|---:|
| A | Bearer token header | High | High | Good | Low |
| B | Query string key | Low | Medium | Fair | Low |
| C | JWT claims | Medium | Medium | Good | High |
| D | No auth, IP only | Low | Highest | Weak | Low |
#### Option A: Bearer Token
This matches the OpenAI pattern.
It works with OpenAI SDKs via `api_key`.
It keeps secrets out of URLs.
It is easy to revoke.
It is easy to log safely by hashing.
It composes with a future paid plan.
This is the obvious v1 API auth.
#### Option B: Query String Key
Query strings are easy to paste into a browser.
They also leak into logs, analytics, referrers, screenshots, and browser
history.
They are non-standard for OpenAI-compatible SDK use.
This is worse than bearer tokens for almost no gain.
#### Option C: JWT With Usage Claims
JWTs can carry quotas or account claims.
That is unnecessary complexity for v1.
Rotating quota state inside signed tokens is awkward if usage changes
with every request.
A database lookup is simpler and more controllable.
#### Option D: No Auth
This can exist for the demo.
It is too weak for a public API.
It leaves the operator with no revocation path besides IP blocks.
#### Recommendation
Use bearer tokens in the `Authorization` header.
Key shape:
- Prefix like `mp_` for easy recognition.
- Random high-entropy secret.
- Store only a hash server-side.
- Show the full key once.
- Allow regenerate/revoke.
Authentication flow:
- Unauthenticated demo traffic allowed only through the front door proxy
  and a tiny per-IP quota.
- API traffic to `api.streamvc.live` or a protected coordinator path
  uses `Authorization: Bearer <key>`.
- Invalid/missing key receives an OpenAI-shaped 401.
This is standard, easy, and enough for v1.
### Q5. Dashboard And User Observability
Question: what does a user see about their own usage?
#### Options
| Option | Shape | Build Cost | User Value | Operator Value |
|---|---|---:|---:|---:|
| A | Nothing | Lowest | Low | Low |
| B | `/usage` JSON endpoint | Low | Medium | High |
| C | Web dashboard with charts | High | High | Medium |
| D | Email reports | Medium | Low-medium | Medium |
#### Option A: Nothing
This keeps v1 smallest.
It creates support questions immediately:
- Why did I hit quota?
- How much did I use?
- When does it reset?
- Did my request count?
For a free capped API, usage visibility is part of access.
Nothing is too opaque.
#### Option B: `/usage`
This gives users what they need without dashboard work.
Example fields:
- account id or key label.
- current daily window start.
- requests used.
- prompt tokens used.
- completion tokens used.
- total tokens used.
- quota limit.
- reset time.
It is curlable.
It is easy to test.
It also gives the operator a clean primitive for later dashboard UI.
#### Option C: Web Dashboard
Charts are nice.
They are not needed to make the API usable.
They also drag the work toward product polish before the product has
real usage.
This belongs after the first usage endpoint is proven useful.
#### Option D: Email Reports
Email reports are useful for paid products.
For v1 free capped access, they add cron and deliverability work.
They also do not help the user at the moment a request fails.
#### Recommendation
Build `/v1/usage` or `/usage` JSON for authenticated users.
Also return rate limit headers on API responses:
- `X-RateLimit-Limit`
- `X-RateLimit-Remaining`
- `X-RateLimit-Reset`
The coordinator spec already reserves these headers.
Implementing them now turns quotas into a visible contract.
Do not build a chart dashboard in SPEC-006.
The front door can show a compact account panel only if it is almost
free once `/usage` exists.
### Q6. Abuse Defense
Question: what is the minimum-viable defense for easy cheap/free access?
#### Abuse Vectors
| Vector | Risk | v1 Defense |
|---|---|---|
| Output harvesting | Medium | Daily token caps, request caps, max output |
| Spam backend | High | Account quota, IP quota, key revocation |
| Harmful prompts at scale | Medium | Logs, caps, kill switch, basic blocklist |
| Quota Sybil | High | Email/GitHub identity, IP issuance limits |
| Denial of service | High | Concurrency caps, queue caps, timeouts |
| Long generation abuse | High | `max_tokens` cap, timeout, streaming cancellation |
| Provider exhaustion | High | Per-account concurrent request limit |
| Prompt injection against infra | Low-medium | Do not execute tools, ignore unknown fields |
#### The Unavoidable Tension
Easy access plus free usage attracts abuse.
The goal is not perfect prevention.
The goal is to keep failure bounded.
For v1, bounded means:
- One abusive account cannot consume the whole pool.
- One IP cannot mint unlimited accounts quickly.
- One request cannot run indefinitely.
- The operator can turn off public access fast.
- Logs have enough detail to diagnose and ban.
#### Minimum Defense Set
Identity:
- Email or GitHub account for API keys.
- One default active key per account.
- Revocation and regeneration.
- Optional domain/provider blocklist.
Quota:
- Daily token quota per account.
- Daily request quota per account.
- Per-IP signup issuance limit.
- Per-IP unauthenticated demo quota.
- Per-account concurrent request limit.
Request limits:
- Max `max_tokens` for free tier.
- Max prompt bytes.
- Max messages count.
- Provider timeout inherited from coordinator.
- Streaming cancellation on client disconnect.
Routing protection:
- Respect provider `slots_free`.
- Return 503 rather than queueing indefinitely.
- Do not retry failed requests invisibly in v1.
Operator controls:
- Global public API kill switch.
- Per-key disable.
- Per-account disable.
- IP denylist.
- Model disable.
- Configurable quotas without code changes.
Logging:
- Account/key hash.
- IP hash or truncated IP.
- model.
- prompt tokens.
- completion tokens.
- status.
- latency.
- provider id.
- error code.
Content safety:
- Do not build full moderation in SPEC-006.
- Add a simple abuse terms notice.
- Add an operator-visible abuse log view or query.
- Consider a small static blocklist only for obvious automated abuse
  patterns, not as a general safety product.
#### What Not To Build
Do not build:
- Captcha-first signup.
- Complex reputation scoring.
- Paid anti-abuse gating.
- Human review queues.
- Prompt classification models.
- Enterprise content policy workflows.
These would consume the v1 week and still not solve the basic free-tier
abuse problem.
#### Recommendation
Use identity plus hard quotas plus operator kill switches.
The floor is:
- Email/GitHub account.
- Bearer key.
- Small daily token quota.
- Small per-request output cap.
- Per-account concurrency cap of 1-2.
- Tiny no-key demo quota.
- Revocation UI or admin CLI.
- Global disable flag.
- Quota/rate headers.
This opens the door without pretending the door is a bank vault.
### Q7. Brand And Front Door
Question: what does the existing Vercel demo become?
#### Options
| Option | Shape | Build Cost | Coherence | Operator Burden |
|---|---|---:|---:|---:|
| A | Demo stays separate | Low | Medium | Low |
| B | Demo gains signup/key flow | Medium | High | Medium |
| C | New API site replaces demo | Medium-high | Medium | Medium |
| D | Multiple surfaces | High | Low for v1 | High |
#### Existing Demo Reality
The repo contains `beta/web`.
It is a Vercel single-page chat UI.
It currently proxies to `m1.streamvc.live` and `m4.streamvc.live`
through edge functions.
It proves "seeing is believing":
- choose a Mac.
- send a prompt.
- stream back real local inference.
- show receipt fields.
The deploy notes warn that anyone with the link can spend compute.
That is exactly what SPEC-006 needs to fix.
The demo is not currently using the coordinator as the sole backend.
It is pointed at direct tunnel providers.
SPEC-006 should bring it forward to the coordinator path so the front
door proves the same buyer API that external users will use.
#### Option A: Keep It Separate
This is minimal.
It misses the chance to convert curiosity into API keys.
It also preserves a split between demo path and API path.
That split caused past integration mismatches in other specs.
#### Option B: Add Signup To Demo
This best matches v1.
The first screen remains a working chat demo.
A user can try it with a tiny no-key quota.
When they want API access, they click "Get API key."
Docs are one click away.
The same surface teaches:
- the network is real.
- the API is simple.
- the limits are visible.
#### Option C: New API Site
A clean API site at `api.streamvc.live` or `streamvc.live/api` is
appealing.
Building it from scratch is unnecessary if the Vercel demo is already
the natural front door.
The API base URL can still be a dedicated subdomain later.
#### Option D: Multiple Surfaces
Multiple surfaces are premature.
They multiply deployment, copy, routing, and docs work.
They also confuse the first user journey.
#### Recommendation
Use Option B.
Turn the existing Vercel demo into the front door:
- Update backend calls to the coordinator.
- Keep the chat demo first.
- Add "Get API key" flow.
- Add "Docs" section or page with curl/OpenAI SDK snippets.
- Add account usage readout after login.
- Keep one canonical public URL.
Recommended domain shape:
- Front door: existing Vercel demo initially, optionally mapped to
  `streamvc.live`.
- API base: `https://coordinator.streamvc.live` for v1 if auth proxy is
  added there, or `https://api.streamvc.live` if a small API gateway is
  cleaner.
- Avoid separate docs subdomain in v1.
One person needs one surface.
### Q8. Documentation Surface
Question: what docs exist day 1?
#### Options
| Option | Shape | Build Cost | User Success | Maintenance |
|---|---|---:|---:|---:|
| A | GitHub README | Low | Medium | Low |
| B | Single-page docs with examples | Low-medium | High | Low |
| C | Full docs platform | High | High | Medium-high |
| D | Point at OpenAI docs | Lowest | Low-medium | Low |
#### What "No Thrills Install" Means For API Docs
The first buyer should not reverse-engineer compatibility.
They need:
- Base URL.
- How to get a key.
- `curl /v1/models`.
- `curl /v1/chat/completions`.
- Streaming example.
- OpenAI Python SDK example.
- OpenAI JavaScript SDK example.
- Usage endpoint example.
- Error codes.
- Quota explanation.
- Current model list caveat.
That is one page.
#### Option A: README Only
This is acceptable for developer projects.
It is weaker as the first buyer-facing surface because it sends users to
GitHub before they have succeeded.
GitHub can mirror the docs.
It should not be the only docs.
#### Option B: Single-Page Docs
This is the right v1.
It can live inside the Vercel app.
It can be static HTML or Markdown rendered by the existing frontend.
It can have copyable snippets.
It avoids a docs platform.
It is enough to make integration dead simple.
#### Option C: Full Docs Platform
Mintlify/ReadMe-style docs are not needed for:
- two endpoints.
- one auth scheme.
- one usage endpoint.
- one free quota.
The work would be polish without evidence.
#### Option D: Point At OpenAI Docs
Compatibility is a strength.
But Mac Provider has important differences:
- Models are live pool entries.
- Availability can be transient.
- Quotas are free-tier caps.
- Tool execution is not a full platform feature.
- Vision and embeddings are absent.
- 503 can mean "Mac unavailable."
OpenAI docs cannot explain those differences.
#### Recommendation
Build a single-page docs section in the front door.
Include:
- "Get a key."
- "List models."
- "Chat completion."
- "Streaming."
- "Use OpenAI SDK."
- "Check usage."
- "Understand 404 vs 503."
- "Current limits."
Mirror the same content in README later if cheap.
Do not adopt a docs platform in SPEC-006.
### Q9. Provider-Side Question
Question: does SPEC-006 change the provider relationship?
#### Options
| Option | Shape | Provider Trust | Build Cost | Risk |
|---|---|---:|---:|---:|
| A | No change; donation continues | Medium | Lowest | Ambiguity |
| B | Show contribution counts | High | Low-medium | Accuracy burden |
| C | Promise eventual revenue share | Medium | Low | Promise debt |
| D | Implement revenue share v1 | High if right | High | Coupled specs |
#### Current Social Contract
M4 and M1 providers donated compute to prove the network.
SPEC-003 made provider onboarding stranger-shaped.
SPEC-005 is the natural home for compensation/rewards.
SPEC-006 should not smuggle in a payout model.
There is no buyer revenue in the recommended v1 anyway.
#### Option A: No Change
This keeps scope clean.
It may feel incomplete once buyer traffic exists.
Provider goodwill depends on transparency.
No change is acceptable only if the operator is honest that v1 remains
donation-based and capped.
#### Option B: Show Contribution
This is the best near-term relationship improvement.
It can be purely observational:
- requests served.
- prompt tokens served.
- completion tokens served.
- uptime windows.
- error count.
- last served at.
It gives providers proof that their Macs are useful.
It creates the accounting primitives for SPEC-005 without promising
money.
The risk is accuracy.
If numbers are shown, they need to match request logs well enough to
avoid distrust.
#### Option C: Promise Revenue Share Later
This is tempting but risky.
It creates expectation debt.
The mechanism is not designed yet.
If there is no revenue in SPEC-006, a revenue-share promise is mostly
story.
Avoid it.
#### Option D: Revenue Share v1
This couples SPEC-006 and SPEC-005.
It requires:
- paid billing.
- provider accounting.
- payout identity.
- minimum thresholds.
- tax/payment concerns.
- dispute handling.
It is far outside a one-week buyer surface.
#### Recommendation
Use Option A plus a small slice of Option B.
No compensation change in SPEC-006.
Add provider contribution visibility only if the data already exists in
the coordinator request log or can be derived cheaply.
For the buyer API, do not expose individual provider earnings.
For providers, a `macprovider-cli status` or future provider page can
show contribution counters.
Language to use:
- "v1 is donation-based and capped."
- "Contribution tracking is being collected so rewards can be designed
  from observed usage."
- "Revenue share is deferred to SPEC-005."
Do not promise a mechanism before it exists.
### Q10. Failure Mode
Question: what does the buyer experience when the network is degraded?
#### Options
| Option | Shape | User Honesty | Build Cost | Fit |
|---|---|---:|---:|---:|
| A | Immediate 503 | Medium | Existing | Good baseline |
| B | Queue up to N seconds then 503 | Medium | Medium | Risky |
| C | Friendly error with state | High | Low | Strong |
| D | Health/status page | High | Medium | Useful |
#### Existing Behavior
The coordinator already distinguishes:
- 404 for unknown model.
- 503 for known model but no eligible provider.
- 502 for selected provider failure.
- 504 for provider timeout.
`/v1/models` returns HTTP 200 with an empty list when the pool is empty.
This is a good foundation.
The public product needs to make these states legible.
#### Option A: Immediate 503
This is technically honest.
It is developer-friendly if the error code is stable.
It may feel broken if the body is generic.
#### Option B: Queue Then 503
Queueing sounds friendlier.
It can be worse:
- It ties up buyer requests.
- It hides pool capacity.
- It creates latency surprises.
- It can amplify DoS.
- It complicates cancellation.
Given tiny provider concurrency, v1 should avoid long buyer-side queues.
A very short wait may be acceptable if a provider slot is expected to
free immediately, but it should not be the core behavior.
#### Option C: Friendly Error
This is the best product layer over immediate 503.
The error can still be OpenAI-shaped.
The message can say:
- no provider currently available.
- requested model.
- retry suggestion.
- usage not charged if no provider served.
The docs can show retry/backoff.
#### Option D: Status Page
A live status page is useful because Mac Provider's nature is unusual.
It can show:
- coordinator health.
- available models.
- connected providers count.
- total slots.
- degraded/unavailable state.
- last updated time.
This can be static or served from a lightweight status endpoint.
It does not need incident-management software in v1.
#### Recommendation
Use immediate structured errors plus a lightweight status view.
For API:
- 404 when model is unknown.
- 503 when model is known but no provider is available.
- 502 when selected provider failed.
- 504 on timeout.
- OpenAI-shaped error envelope.
- Rate limit headers where relevant.
For front door:
- Show live model/provider status before the user sends.
- On failure, explain the network state plainly.
- Link or inline a status panel.
Do not implement long request queues in SPEC-006.
Make "real Macs, live pool, sometimes unavailable" part of the product
truth.
## 4. Recommended Path
### Single Coherent Product Shape
SPEC-006 should make Mac Provider a free, capped, OpenAI-compatible API
for a live volunteer Mac pool, with the existing Vercel chat demo as the
front door and key issuance path.
That is the sentence.
It is not premium inference.
It is not a marketplace.
It is not enterprise compute.
It is a simple public door into a small real network.
### Day 1 User Flow
The user lands on the front door.
They see a working chat demo.
They can send a tiny number of no-key demo messages.
They see live model availability.
They click "Get API key."
They authenticate with email magic link or GitHub OAuth.
They receive an API key.
They copy a curl command.
They call `/v1/models`.
They call `/v1/chat/completions`.
They optionally stream.
They can call `/usage`.
They see quota remaining.
They hit clear errors when the pool is unavailable.
### Day 1 API Shape
Public endpoints:
- `GET /v1/models`
- `POST /v1/chat/completions`
- `GET /usage` or `GET /v1/usage`
- `GET /status` or front-door status JSON
Auth:
- Bearer API key for API calls.
- No credit card.
- No manual approval.
- Tiny unauthenticated demo quota.
Quota:
- Daily total token cap.
- Daily request cap.
- Per-request max output.
- Per-account concurrency cap.
- Per-IP demo and signup issuance limits.
Docs:
- Single-page docs in the front door.
- Curl examples.
- OpenAI Python and JavaScript examples.
- Error and quota explanation.
### What It Defers
SPEC-006 should explicitly defer:
- Stripe.
- Metered billing.
- Paid plans.
- Provider payout.
- Revenue share.
- Provider tipping.
- Full dashboard charts.
- Email reports.
- Vision.
- Embeddings.
- Batch.
- Tool execution.
- Strict schema outputs.
- Prompt moderation system.
- Complex abuse scoring.
- Captcha-first signup.
- Long queueing.
- Dedicated docs platform.
- Multi-surface brand architecture.
### Estimated One-Week Build Scope
Day 1:
- Decide whether auth/quota lives in coordinator or a small gateway.
- Add account/key data model.
- Add hashed API key validation.
- Add auth middleware.
- Add config-driven quota defaults.
Day 2:
- Add usage accounting by account/key.
- Add quota enforcement before routing.
- Add rate-limit headers.
- Add `/usage`.
- Add admin disable/revoke path.
Day 3:
- Update Vercel demo to use coordinator/gateway.
- Add tiny no-key demo quota.
- Add signup/key issuance UI.
- Add live model/status panel.
Day 4:
- Write single-page docs.
- Add curl and SDK snippets.
- Document errors and limits.
- Add front-door copy that avoids premium positioning.
Day 5:
- Abuse controls pass.
- Operator kill switch.
- IP signup/demo limits.
- Basic denylist.
- Request caps and timeouts verified.
Day 6:
- Integration testing.
- Stranger-shaped key issuance test.
- OpenAI SDK smoke test.
- Quota exhaustion test.
- Provider unavailable test.
- Streaming test.
Day 7:
- Polish.
- Deployment.
- Runbook.
- SPEC-006 acceptance notes.
- Prepare audit prompt.
This is tight but plausible if the implementation stays boring.
The biggest architectural choice is whether to add auth/quota directly
to the Go coordinator or place a thin gateway in front of it.
For v1, direct coordinator integration is probably less moving parts if
the existing codebase is comfortable.
A gateway is cleaner only if modifying the coordinator risks destabilizing
the provider routing path.
## 5. Open Questions For Operator
1. Where should the canonical public API live?
`coordinator.streamvc.live` is already real; `api.streamvc.live` may be
cleaner as a buyer-facing name.
2. Is GitHub OAuth acceptable as the first identity method?
It is lower support than email magic links, but excludes users without
GitHub accounts.
3. What default free quota feels generous but safe?
The design recommends starting around 25,000-100,000 total tokens per
account per day, then adjusting from observed load.
4. Should unauthenticated demo traffic be allowed at all?
The design recommends yes, but with a tiny per-IP cap and small output
limit.
5. Should auth/quota be built into the coordinator or a gateway?
Coordinator integration is simpler operationally; gateway separation may
protect the routing core.
6. Should provider identity be visible to buyers?
The current coordinator exposes provider route headers; the product can
either keep that as transparency or hide it to reduce surface area.
7. How much status transparency is comfortable?
Showing provider counts and slots is useful; showing hostnames or stable
provider IDs publicly may be too revealing.
8. What is the emergency abuse posture?
The operator should decide whether the global kill switch disables only
new unauthenticated demo requests or all public API access.
9. Is a donation link worth including in v1?
It is harmless only if it does not imply paid entitlement or provider
compensation.
10. What usage metric matters most in the first 90 days?
Time to first successful API call is the strongest candidate because it
directly measures "easy access."
## 6. What Would Falsify This Design
### Falsification Frame
This design is an experiment.
It assumes the best next move is to make the existing network easy to
try, free within caps, and observable.
It does not assume a buyer persona.
It does not assume a premium price.
It does not assume the market shape.
The point is to generate evidence.
### Signals The Design Is Wrong
The design is wrong if 90 days show:
1. Users sign up but do not make a first API call.
This means access is still too confusing or the docs fail.
Pivot: simplify onboarding, possibly remove even more steps or improve
SDK snippets.
2. Users make one demo request but rarely create API keys.
This means the demo is curiosity, not API demand.
Pivot: learn from demo prompts, not API usage; consider consumer/chat
surface exploration later.
3. Users create keys but mostly hit 503 or timeouts.
This means capability surfaced exceeds network capacity.
Pivot: improve provider supply, status messaging, or reduce public
quota until capacity catches up.
4. Quota exhaustion is rare and repeat usage is low.
This means the free cap is not the constraint; usefulness is.
Pivot: study successful prompts and tighten positioning from observed
usage.
5. Abuse consumes most served tokens.
This means the access shape is too open.
Pivot: lower quotas, require stronger identity, add captcha only at the
issuance boundary, or pause public demo traffic.
6. Users ask for capabilities outside the current surface immediately.
Examples include embeddings, vision, batch, stronger models, or tool
execution.
Pivot: rank requested capabilities by frequency and build the smallest
one that matches infrastructure.
7. Users compare price/performance unfavorably to commodity providers.
This means the docs or product framing are inviting the wrong comparison.
Pivot: change front-door copy toward network transparency, non-extraction,
or observable use cases only after data supports them.
8. Providers become uncomfortable with public buyer traffic.
This means the social contract is under-specified.
Pivot: cap public traffic harder and prioritize SPEC-005 provider
contribution/reward design.
9. Operator support load rises before usage quality rises.
This means the one-person burden constraint is violated.
Pivot: reduce access, automate support answers, or simplify the product
surface.
10. No one returns after first successful integration.
This means "easy and cheap" is not enough.
Pivot: use the actual first-session traces to identify what people tried,
then choose a narrower product direction from evidence.
### Signals The Design Is Right
The design is working if 90 days show:
1. A meaningful share of visitors reach first successful API call.
This proves the access/docs path.
2. Some users return across multiple days.
This proves the network has repeat utility even without premium
positioning.
3. `/v1/models` is called before completions by real users.
This means buyers understand the live-pool model.
4. Streaming is used frequently.
This means the UX value of visible token flow matters.
5. 503s do not destroy repeat usage.
This means users accept the live volunteer pool if errors are honest.
6. Quota exhaustion happens for non-abusive accounts.
This indicates real demand and gives pricing/cap data for the next spec.
7. Users ask for the same missing capability repeatedly.
This gives SPEC-007+ direction without inventing personas.
8. Providers stay comfortable or ask for contribution visibility.
This validates deferring compensation while gathering accounting data.
9. Operator time stays bounded.
This validates the one-person operating model.
10. The product produces a ranked list of real uses.
This is the main success condition.
### Metrics To Instrument
Access:
- Visit to key issuance conversion.
- Key issuance to first `/v1/models`.
- Key issuance to first successful completion.
- Time to first successful completion.
Usage:
- Daily active keys.
- Requests per key.
- Tokens per key.
- Streaming vs non-streaming share.
- Models requested.
- Quota exhaustion count.
Reliability:
- 200/4xx/5xx by endpoint.
- 503 rate by model.
- 502/504 rate by provider.
- Median and p95 time to first token.
- Median and p95 total latency.
Capacity:
- Connected provider count.
- Ready provider count.
- Total slots.
- Provider utilization.
- Request rejection due to no slots.
Abuse:
- Signup attempts per IP.
- Keys per IP.
- Disabled keys.
- Top token consumers.
- Repeated high-output requests.
- Error-heavy accounts.
Learning:
- First prompt category by rough operator review.
- Repeat prompt category.
- Docs pages copied from.
- Support questions.
- Capability requests.
### Next Build If Design Is Right
If the design works, the next spec should not be "add everything."
It should choose the strongest observed branch:
- If users mostly need more capacity, build provider rewards and growth.
- If users mostly need reliability, build status, retries, and smarter
  routing.
- If users mostly need a capability, build that capability.
- If users mostly need payment to exceed caps, build billing.
- If providers need fairness, build SPEC-005 rewards before paid scale.
The design is right only if it produces that fork with evidence.
