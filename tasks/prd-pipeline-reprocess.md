# PRD 5: Manual Pipeline Reprocess

**Status:** Draft
**Author:** Marcus Jones
**Date:** 2026-04-08
**Series:** 5 — standalone feature, integrates with [PRD 1 Dashboard](prd-dashboard-visibility.md) and [PRD 4 Kanban](prd-kanban-boards.md)

---

## 1. Introduction / Overview

Documents sometimes get stuck in the pipeline — they sit with `ocr-pending` or `classification-pending` tags for minutes or hours without progressing. The current workaround is to manually remove and re-add the trigger tag in the Paperless UI, which requires knowing the tag names, navigating to the document, and performing two separate saves.

**What this delivers:** A single **↺ Reprocess** button that appears anywhere a document is visible in the dashboard. One click restarts the document from Stage 1 by cycling the trigger tag via the Paperless API. No Paperless UI navigation needed.

A **Stuck Documents** count also surfaces on the Paperless service card so problems are visible at a glance.

---

## 2. Goals

| # | Goal | Measurable |
|---|------|-----------|
| G1 | One-click reprocess from anywhere in the dashboard | Button present on service card stuck-docs list, kanban cards, and pipeline page |
| G2 | Stuck document detection | Paperless service card shows count of docs with pipeline tags held >10 min |
| G3 | Reprocess completes cleanly | After button press, tag is removed then re-added; document re-enters Stage 1 within 30s |
| G4 | Feedback to the user | Button shows loading state; success or error toast on completion |

---

## 3. User Stories

**US1 — Unstick a document**
As a user who sees a document sitting with `ocr-pending` for 15 minutes, I want to click ↺ Reprocess so it re-enters the pipeline without me opening Paperless.

**US2 — Spot stuck documents at a glance**
As a user opening the dashboard, I want the Paperless service card to show "2 stuck" in red so I know immediately something needs attention.

**US3 — Reprocess from the Kanban board**
As a user reviewing the Medical Bills kanban, I want a reprocess button on documents stuck in "Incoming" so I can kick them along without leaving the board.

**US4 — Reprocess from the pipeline page**
As a user watching the GPU timeline, I want to click reprocess on a document that stopped progressing so I can see it start moving in the swimlane immediately.

---

## 4. Functional Requirements

### 4.1 What "Reprocess" Does

**FR-R1:** Reprocess performs exactly two Paperless API calls in sequence:
1. `PATCH /api/documents/[id]/` — remove the `ocr-pending` tag from the document's tag list
2. `PATCH /api/documents/[id]/` — re-add the `ocr-pending` tag

This fires a `document_updated` webhook which paperless-gpt picks up on its next poll cycle, restarting the document from Stage 1.

**FR-R2:** Both calls are made server-side via a Next.js API route (`POST /api/documents/[id]/reprocess`) to avoid CORS and keep the API token server-side.

**FR-R3:** The route resolves the tag ID for `ocr-pending` by name from `GET /api/tags/` on first call, then caches it in memory for the process lifetime.

**FR-R4:** If the remove call fails (e.g. document didn't have the tag), the route still proceeds with the add call. If the add call fails, the route returns an error.

**FR-R5:** The reprocess action is idempotent — calling it on a document already being processed just restarts it from Stage 1 again.

### 4.2 ↺ Reprocess Button

**FR-B1:** The button appears in three locations:
1. **Stuck-docs list** on the Paperless service card (see §4.3)
2. **Kanban board document cards** — small icon button in the card footer (see §4.4)
3. **Pipeline page document list** — inline action button next to each document row (see §4.5)

**FR-B2:** Button states:
- **Default:** ↺ icon, neutral colour
- **Loading:** spinner, disabled, "Reprocessing…" tooltip
- **Success:** brief green checkmark, then reverts to default after 2s
- **Error:** red ✕ with a toast: "Failed to reprocess doc #[id]: [error message]"

**FR-B3:** On success, the UI refreshes the relevant view (card stats, kanban column, pipeline list) after 3s to reflect the document's new state.

### 4.3 Stuck Documents — Paperless Service Card

**FR-S1:** The Paperless service card gains a **stuck count** below the doc count stat:

```
324 docs
2 stuck ●   ← red dot, clickable
```

**FR-S2:** A document is "stuck" if it currently has `ocr-pending` OR `classification-pending` tag AND the document's `modified` timestamp is >10 minutes ago.

**FR-S3:** The count is fetched as part of the existing `/api/status` probe for Paperless (one additional API call per 30s refresh cycle).

**FR-S4:** Clicking "stuck" opens a small popover listing the stuck documents: doc ID, truncated title, which tag it's stuck on, and how long it's been there. Each row has a ↺ Reprocess button.

**FR-S5:** If stuck count is 0, the stuck indicator is hidden entirely.

### 4.4 Kanban Board Cards

**FR-K1:** Each kanban document card gains a small ↺ button in the bottom-right corner, visible on hover.

**FR-K2:** The button is always present (not just for "stuck" documents) — any document can be reprocessed by the user's choice.

**FR-K3:** Clicking it triggers reprocess (§4.1) without moving the card between columns.

### 4.5 Pipeline Page Document List

**FR-P1:** The pipeline page (currently the GPU timeline) gains a **Recent Documents** table below the chart. Shows the last 20 documents from `pipeline_events` in QuestDB: doc ID, title, last stage seen, time since last event.

**FR-P2:** Documents with no event in the last 10 minutes AND whose last stage was a `_start` (not `_end`) are highlighted in amber as potentially stuck.

**FR-P3:** Each row in the table has a ↺ Reprocess button.

**FR-P4:** This table replaces the swimlane's role as the "what's happening" view for users who want a list rather than a chart.

### 4.6 New API Route

| Route | Method | Description |
|-------|--------|-------------|
| `/api/documents/[id]/reprocess` | POST | Remove then re-add `ocr-pending` tag via Paperless API |

Request body: none required.

Response:
```json
{ "ok": true, "docId": 42 }
```
or
```json
{ "error": "Failed to re-add tag: 404 Not Found", "docId": 42 }
```

### 4.7 Project Structure (additions)

```
apps/dashboard/src/
├── app/
│   ├── api/
│   │   └── documents/
│   │       └── [id]/
│   │           └── reprocess/
│   │               └── route.ts       (new)
│   └── pipeline/
│       └── page.tsx                   (new — pipeline page with document list)
└── components/
    ├── reprocess-button.tsx           (new — shared button with loading/error states)
    ├── stuck-docs-popover.tsx         (new — popover for service card)
    └── pipeline-document-list.tsx     (new — recent docs table with reprocess buttons)
```

---

## 5. Non-Goals / Out of Scope

- **No stage-level control** — always restarts from Stage 1. Re-OCR only or re-classify only is out of scope.
- **No bulk reprocess** — one document at a time.
- **No scheduling** — reprocess is always immediate on click.
- **No auto-retry** — the dashboard detects stuck docs but does not automatically reprocess them.
- **No notification** — no alert when a document gets stuck. Detection is passive (visible on next dashboard load).

---

## 6. Design Considerations

### Stuck docs popover

```
┌─────────────────────────────────────────┐
│ 2 documents stuck                       │
├─────────────────────────────────────────┤
│ #42  Invoice Telekom    ocr-auto  14m   │
│                                   [↺]  │
│ #38  Arzt Rechnung…     classification-pending 32m  │
│                                   [↺]  │
└─────────────────────────────────────────┘
```

### Kanban card reprocess button

```
┌─────────────────────┐
│ #42 Invoice Telekom  │
│ €123.40              │
│ 2026-04-01      [↺] │  ← hover to reveal
└─────────────────────┘
```

---

## 7. Technical Considerations

- **Tag ID caching:** Resolve `ocr-pending` tag ID once per process startup. Store in a module-level variable in the route file. Cost: one `GET /api/tags/` call on first reprocess request.
- **Race condition:** If the pipeline processes the document between the remove and re-add calls (~50ms gap), it gets a duplicate trigger. Acceptable — worst case it processes twice.
- **Stuck detection query:** Fetch `GET /api/documents/?tags__name__in=ocr-pending,classification-pending&page_size=50` from Paperless, then filter client-side for `modified < now - 10min`. Runs as part of the status probe every 30s.

---

## 8. Success Metrics

| Metric | Target |
|--------|--------|
| Reprocess API round-trip | < 2 seconds |
| Stuck count visible on dashboard load | Within one 30s refresh cycle of a doc getting stuck |
| Clicks to reprocess a stuck document | 1 (from service card popover or kanban card) |

---

## 9. Open Questions

| # | Question | Owner | Notes |
|---|----------|-------|-------|
| OQ1 | Should the pipeline page replace the current home page GPU timeline, or be a separate `/pipeline` route? | Marcus | Recommend separate route — keeps home page focused on service health |
| OQ2 | 10-minute stuck threshold — too long? Too short? | Marcus | Could be configurable in stack.yaml |
| OQ3 | Should reprocess also clear the `classification-pending` tag (for docs stuck in Stage 3)? | — | Yes — add a second code path: if doc has `classification-pending` but not `ocr-pending`, cycle `classification-pending` instead |
