# SPEC-009 — MacProvider Console v2

**Version:** 0.1  
**Status:** Implementation  
**Replaces:** `frontdoor/console/index.html` (the current v1 single-panel demo page)

---

## 1. Goals

Redesign `console.streamvc.live` from a bare demo widget into a developer-grade chat console modelled after Cursor's UI/UX.  Target users are heavy developers; first impression must read as "best-in-class tooling", not "weekend POC".

Non-goals for v0.1:
- Multi-file upload, tool-use display, agentic workflows
- Real-time provider leaderboard (Phase 7 scope)
- Backend-persisted session history (added once auth is solid)

---

## 2. Layout

```
┌──────────────┬──────────────────────────────────────────┐
│   SIDEBAR    │                  MAIN                    │
│   220 px     │                                          │
│              │  [view:chat] or [view:dashboard]         │
│ brand        │                                          │
│ ──────────── │  chat/empty-state:                       │
│ + New Chat   │    hero heading + 3 suggestion chips     │
│ ──────────── │    input dock (textarea + model + send)  │
│ Recent       │                                          │
│  ○ session 1 │  chat/active:                            │
│  ○ session 2 │    scrollable message thread             │
│  ...         │    sticky input dock at bottom           │
│              │                                          │
│ (spacer)     │  dashboard:                              │
│ ──────────── │    stats row (cards: req/day, tok/day,   │
│ ⊞ Dashboard  │      avg latency, sessions)              │
│ ↗ API Docs   │    7-day activity chart (CSS bars)       │
│ ──────────── │    provider pool card                    │
│ ● pool idle  │                                          │
│ [Sign in]    │                                          │
└──────────────┴──────────────────────────────────────────┘
```

---

## 3. Component inventory

### 3.1 Sidebar

| Element | Behaviour |
|---------|-----------|
| Brand mark | Static. `⬡ MacProvider` wordmark. |
| New Chat button | Creates a new session; switches view to chat; clears message thread; focuses input. |
| Recent history list | Last 10 sessions from `localStorage`. Shows auto-generated title (first 40 chars of first user turn). Clicking restores messages. |
| Dashboard nav | `onclick` route swap (no page reload). |
| API Docs nav | External link to `https://api.streamvc.live/docs`. |
| Pool status | Small dot (green=up, amber=idle, red=down) + one-word label. Updated on load + every 30 s. |
| User area | Unauthenticated: "Sign in with GitHub" link. Authenticated: avatar initials chip + username. |

### 3.2 Chat view — empty state

Centered vertically and horizontally in the main area.  
- Hero icon + title + subtitle
- 3 suggestion chips (same content as v1, styled as pills)
- Input dock (same component as active chat)

### 3.3 Chat view — active state

- Scrollable `<div>` grows from top; newest message at bottom; auto-scrolls during streaming.
- **User message bubble**: right-side visual treatment, subtle surface background.
- **Assistant message**: no background, model label + latency in muted footer.
- Blinking cursor `▌` appended to last assistant turn during streaming.

### 3.4 Input dock

Fixed at bottom of chat view (both empty and active states share this component).

| Sub-element | Behaviour |
|-------------|-----------|
| Textarea | 3-row min, auto-expands up to 10 rows. `⌘↵` submits. |
| Model chip | Shows shortened model name (strip `mlx-community/`, `-Instruct-4bit`). Opens a popover listing all models from `/v1/status`. Disabled when streaming. |
| Model popover | Closes on outside click or Escape. Items show full model id + availability status. |
| ⌘↵ hint | Muted label. |
| Send button | Enabled only when textarea non-empty and not streaming. Label: "Send" → "Stop" during stream (clicking stop aborts the reader). |

### 3.5 Dashboard view

| Card | Data source |
|------|-------------|
| Requests today | `localStorage` `mp_usage[today].requests` |
| Tokens today | `localStorage` `mp_usage[today].tokens` |
| Avg latency today | `localStorage` `mp_usage[today].latencies` (mean) |
| This week | Sum of last 7 days requests |
| 7-day chart | CSS flex bars, max bar = highest day, relative height |
| Provider pool | Live from `/v1/status`: pool size, models, status |
| Quick links | API Docs, Status endpoint |

---

## 4. State management

All persistence is `localStorage` (no backend dependency).

```
mp_sessions   → JSON: Session[]   (capped at 50 sessions, trimmed oldest-first)
mp_current    → string: session id
mp_usage      → JSON: Record<YYYY-MM-DD, { requests: n, tokens: n, latencies: number[] }>
mp_models     → JSON: string[]    (model id cache; refreshed on status fetch)
```

`Session` shape:
```json
{
  "id": "ses_<8 random chars>",
  "title": "First 40 chars of first user message",
  "created": "ISO-8601",
  "messages": [
    { "role": "user",      "content": "...", "ts": "ISO-8601" },
    { "role": "assistant", "content": "...", "ts": "ISO-8601",
      "model": "...", "tokens": 0, "latencyMs": 0 }
  ]
}
```

---

## 5. API contract

All calls go to `https://api.streamvc.live`.

| Call | When |
|------|------|
| `GET /v1/status` | On load + every 30 s. |
| `POST /auth/demo-session` | On first user keystroke (lazy); token cached in memory for session lifetime. |
| `POST /v1/chat/completions` | On send. SSE stream. Model from selected model or `mp_models[0]`. |

Demo token passed as `X-Demo-Token` header.  
Unauthenticated users are limited to 1 000 tokens/IP/day (inherited from v1 behaviour).

---

## 6. Visual design tokens

```
--bg:      #0c0d10   main canvas
--sb:      #111316   sidebar
--surface: #16181d   cards, raised areas
--border:  #252830   default border
--border2: #323743   hover/focus borders
--text:    #e1e3e8   primary text
--muted:   #878d99   secondary text
--hint:    #4a5060   placeholder / keyboard hints
--accent:  #7c6af6   purple (MacProvider brand colour, replaces GitHub blue)
--ok:      #22c55e   green (pool up)
--warn:    #f59e0b   amber (idle)
--bad:     #ef4444   red (down/error)
```

Font: `-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Inter", sans-serif`  
Code / model labels: `ui-monospace, SFMono-Regular, Menlo, Consolas, monospace`

---

## 7. Acceptance criteria

- [ ] Sidebar renders with all nav items; New Chat creates a fresh session
- [ ] Last 10 sessions visible in history; clicking one restores messages
- [ ] Empty state renders hero + 3 suggestion chips; clicking a chip populates input
- [ ] Sending a message transitions empty→active state; message appears immediately
- [ ] Streaming works; blinking cursor visible; Stop button aborts stream
- [ ] Model chip shows shortened name; popover lists all available models
- [ ] Pool dot reflects live status on load and auto-refreshes
- [ ] Dashboard shows today's counters and 7-day chart from localStorage
- [ ] Dashboard provider pool card shows live data
- [ ] Mobile (< 720 px): sidebar collapses behind hamburger or hides gracefully
- [ ] No external runtime dependencies (no CDN, no build step)
