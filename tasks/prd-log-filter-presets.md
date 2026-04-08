# PRD 6: Log Filter Presets

**Status:** Draft
**Author:** Marcus Jones
**Date:** 2026-04-08
**Series:** 6 — standalone enhancement to [PRD 1 Dashboard](prd-dashboard-visibility.md)

---

## 1. Introduction / Overview

The dashboard's service cards already have a **Logs** button that deep-links to Dozzle for that container. But once in Dozzle, you're looking at a firehose — GIN access log spam, heartbeat noise, and the occasional real error all mixed together.

**What this delivers:** Each service card gets a set of **filter preset chips** next to the Logs button. Clicking a preset opens Dozzle for that container *and* copies the filter string to the clipboard so you can paste it into Dozzle's search box immediately. Presets are defined per-service in `stack.yaml` — no code changes needed to add or edit them.

Dozzle v10.2.1 does not support URL-based filter parameters, so clipboard-copy is the bridge until that changes.

---

## 2. Goals

| # | Goal | Measurable |
|---|------|-----------|
| G1 | Reduce time to find relevant logs | User reaches filtered log view in ≤ 2 clicks from any service card |
| G2 | Filter presets configurable without code changes | Adding/editing a preset requires only editing `stack.yaml` and restarting the dashboard |
| G3 | Works for all services | Any service entry in `stack.yaml` can have 0–5 presets |

---

## 3. User Stories

**US1 — Filter paperless-gpt noise**
As a user debugging OCR, I want to click an "Errors only" preset on the paperless-gpt card so I can see only OCR failures without the GIN access log spam.

**US2 — Watch classification in real time**
As a user watching a document process, I want a "Classification" preset on the paperless-ai-next card that filters to AI classification log lines so I don't have to type the filter manually.

**US3 — Add a new preset without touching code**
As a user who found a useful filter, I want to add it to `stack.yaml` so it appears as a preset chip on the relevant card after a dashboard restart.

---

## 4. Functional Requirements

### 4.1 stack.yaml Schema Extension

**FR-1:** Each service entry in `stack.yaml` gains an optional `logFilters` list:

```yaml
services:
  paperless-gpt:
    name: paperless-gpt
    url: http://localhost:8080
    internalUrl: http://paperless-gpt:8080
    dozzleContainer: paperless-paperless-gpt-1
    probeUrl: http://paperless-gpt:8080/
    logFilters:
      - label: "Errors"
        filter: "level=error"
      - label: "OCR"
        filter: "Using binary image format"
      - label: "Hide GIN"
        filter: "-GIN"
```

**FR-2:** Each filter entry has exactly two fields:
- `label` — short display name shown on the chip (max 20 chars)
- `filter` — the string to copy to clipboard and use as Dozzle search text

**FR-3:** A service with no `logFilters` key (or an empty list) shows no preset chips — just the existing Logs button unchanged.

**FR-4:** Maximum 5 presets per service (UI space constraint).

### 4.2 Service Card UI

**FR-5:** When a service has presets, the Logs button is replaced by a **Logs button + preset chips** group:

```
[Logs ↗]  [Errors]  [OCR]  [Hide GIN]
```

**FR-6:** Clicking the **Logs** button (no preset) opens Dozzle for that container in a new tab — existing behaviour, unchanged.

**FR-7:** Clicking a **preset chip**:
1. Opens Dozzle for that container in a new tab (same as Logs button)
2. Copies the `filter` string to the clipboard
3. Shows a brief toast: `"Filter copied — paste in Dozzle search"`

**FR-8:** Preset chips are styled as small secondary buttons, visually subordinate to the main Logs button.

**FR-9:** The toast disappears after 2 seconds.

### 4.3 Config Loading

**FR-10:** `logFilters` is read from `stack.yaml` via the existing `readConfig()` lib. The `/api/status` route includes `logFilters` in each service's response payload so the client can render chips without an extra fetch.

**FR-11:** If `label` or `filter` is missing from a preset entry, that entry is silently skipped.

---

## 5. Non-Goals / Out of Scope

- **No URL-based filter injection into Dozzle** — Dozzle v10.2.1 doesn't support it. If a future Dozzle version adds `?filter=` URL params, the clipboard step can be dropped in a follow-up.
- **No inline log viewer** — logs stay in Dozzle, not embedded in the dashboard.
- **No regex validation** — filter strings are passed as-is; whatever Dozzle accepts is valid.
- **No per-user presets** — presets are global, defined in `stack.yaml`.
- **No preset management UI** — edit `stack.yaml` directly.

---

## 6. Design Considerations

### Service card with presets

```
┌─────────────────────────────────────────┐
│ paperless-gpt          ● Online    [↗]  │
│ Vision OCR — qwen2.5vl:7b               │
│                                         │
│ [Logs ↗]  [Errors]  [OCR]  [Hide GIN]  │
└─────────────────────────────────────────┘
```

### Toast on preset click

```
┌──────────────────────────────────────┐
│ ✓ Filter copied — paste in Dozzle   │
└──────────────────────────────────────┘
```

---

## 7. Technical Considerations

- **`stack.yaml` type extension:** Add `logFilters?: { label: string; filter: string }[]` to the `ServiceConfig` TypeScript interface in `src/lib/config.ts`.
- **`/api/status` response:** Already returns per-service config; add `logFilters` to the `ServiceStatus` type returned to the client.
- **Clipboard API:** Use `navigator.clipboard.writeText()` — available in all modern browsers over `localhost`. No polyfill needed.
- **Toast:** Reuse whatever toast/notification pattern already exists in the dashboard (or a simple `useState` timeout if none).
- **Dozzle URL:** Already built in `service-cards.tsx` as `http://localhost:9999/container/${dozzleContainerId}` — preset chips reuse the same URL.

### Default presets to ship in stack.yaml

| Service | Preset | Filter |
|---------|--------|--------|
| paperless-gpt | Errors | `level=error` |
| paperless-gpt | OCR activity | `binary image` |
| paperless-gpt | Hide GIN | `-[GIN]` |
| paperless-ai-next | Errors | `level=error` |
| paperless-ai-next | Classification | `classification` |
| paperless | Errors | `ERROR` |
| ollama | Model load | `loading model` |

---

## 8. Success Metrics

| Metric | Target |
|--------|--------|
| Clicks to reach filtered logs | 2 (preset chip → paste in Dozzle) |
| Time to add a new preset | < 30 seconds (edit stack.yaml, restart dashboard) |
| Zero regressions on existing Logs button | Existing behaviour unchanged when no presets defined |

---

## 9. Open Questions

| # | Question | Notes |
|---|----------|-------|
| OQ1 | Does a future Dozzle version support `?filter=` URL params? | If yes, drop the clipboard step entirely — just pass the filter in the URL |
| OQ2 | Should preset chips also appear in the pipeline page per-stage? | Could be useful: click OCR stage → opens paperless-gpt logs filtered to that document |
| OQ3 | Should `-` prefix mean "exclude" in filter strings, matching Dozzle's own syntax? | Document the convention in stack.yaml comments |
