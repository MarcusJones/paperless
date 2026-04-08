# PRD 4: Custom Kanban Boards

**Status:** Draft
**Author:** Marcus Jones
**Date:** 2026-04-08
**Series:** 4 — standalone feature, integrates with [PRD 1 Dashboard](prd-dashboard-visibility.md)

---

## 1. Introduction / Overview

The Paperless stack already has the data to power workflow tracking — document types, the `Status` custom field, and per-document metadata like `Amount`, `Treatment date`, and `Submitted OEGKK`. But acting on that data requires navigating Paperless's saved views one at a time, with no sense of the whole workflow.

**What this delivers:** A Kanban board system inside the Next.js dashboard. Each board is scoped to a document type, uses a single Paperless custom field to determine which column a document lives in, and lets you move documents between columns by dragging cards (which updates the field in Paperless via the API).

Multiple boards live in the dashboard sidebar. Each board is its own page (`/boards/[slug]`). The dashboard overview page shows a compact summary widget for each board.

Ships with two pre-built boards for the existing taxonomy (Medical Bills, Invoices), both editable.

---

## 2. Goals

| # | Goal | Measurable |
|---|------|-----------|
| G1 | Multiple boards, each a full page | Each board at `/boards/[slug]`; sidebar lists all boards |
| G2 | Move a card → updates Paperless | PATCH to Paperless API within 1s of card drop; field value reflects new column |
| G3 | Board builder | Create or edit a board in <2 minutes with no code |
| G4 | Pre-built boards ready on first run | Medical Bills and Invoices boards visible without setup |
| G5 | Cards show relevant metadata | Each card displays configured custom field values (Amount, dates, etc.) |
| G6 | Boards load fast | Each board renders within 2 seconds; all docs fetched from Paperless API |

---

## 3. User Stories

**US1 — Tracking medical reimbursements**
As a user with a stack of XNC medical bills, I want a Kanban board showing each bill's reimbursement progress (Incoming → Submitted → Waiting → Reimbursed), so I can see at a glance which bills still need action without opening individual Paperless documents.

**US2 — Moving a document forward**
As a user who just submitted a medical bill to the insurance office, I want to drag the card from "Incoming" to "Submitted" (or click a move button), so the document's Status field in Paperless updates automatically without me opening the document.

**US3 — Seeing key metadata on a card**
As a user reviewing unpaid invoices, I want each card to show the Amount and due date, so I can prioritise without clicking into each document.

**US4 — Creating a new board**
As a user with a new workflow (e.g., tracking employment contracts), I want to create a board in under 2 minutes by picking a document type, a custom field, and labelling the columns, so I can track any document workflow without developer help.

**US5 — Editing an existing board**
As a user who wants to rename columns or change which fields show on cards, I want to edit a board's configuration inline, so I can tune the board to my current workflow.

**US6 — Dashboard overview at a glance**
As a user who opens the dashboard home page, I want to see a compact summary of each board (column counts), so I know immediately if anything needs attention without navigating to each board.

---

## 4. Functional Requirements

### 4.1 Board Configuration

**FR-B1:** Board definitions are stored in `apps/dashboard/config/boards.yaml`. This file is bind-mounted in the compose service and survives container restarts.

**FR-B2:** Each board definition contains:

```yaml
boards:
  - id: medical-bills           # URL slug — unique, URL-safe
    name: Medical Bills          # Display name
    icon: stethoscope            # Lucide icon name (optional)
    docType: XNC medical         # Paperless document type name (exact match)
    columnField: Status          # Paperless custom field name whose value determines column
    columns:                     # Ordered list of columns
      - value: Inbox             # The field value that maps to this column
        label: Incoming          # Display label shown in the UI
        color: "#3b82f6"         # Hex color for column header
      - value: Action needed
        label: Action Needed
        color: "#f97316"
      - value: Waiting
        label: Submitted
        color: "#8b5cf6"
      - value: Done
        label: Reimbursed
        color: "#22c55e"
    cardFields:                  # Custom fields shown on each card (optional)
      - Amount
      - Treatment date
      - Submitted OEGKK
      - Submitted Allianz
```

**FR-B3:** A document appears in the column whose `value` matches the document's current `columnField` value. If the field is unset or the value doesn't match any column, the document appears in an **"Unassigned"** overflow column at the left of the board.

**FR-B4:** Documents with no matching column are shown in Unassigned but are not lost. Moving them to a real column sets the field.

### 4.2 Pre-built Boards

**FR-P1:** `boards.yaml` ships with two pre-built boards:

**Medical Bills** (`medical-bills`):
- docType: `XNC medical`
- columnField: `Status`
- Columns: Incoming (Inbox) → Action Needed (Action needed) → Submitted (Waiting) → Reimbursed (Done)
- cardFields: Amount, Treatment date, Submitted OEGKK, Submitted Allianz, Reimbursed OEGKK, Reimbursed Allianz

**Invoices** (`invoices`):
- docType: `Invoice`
- columnField: `Status`
- Columns: Inbox → Action Needed → Waiting → Done
- cardFields: Amount, PaidOn, InvoiceNr

**FR-P2:** Pre-built boards can be edited or deleted by the user via the board builder. If `boards.yaml` is deleted, it is re-created with defaults on next startup.

### 4.3 Navigation & Layout

**FR-N1:** The dashboard gains a persistent left sidebar. Sidebar sections:
- **Overview** (link to `/`)
- **Pipeline** (link to `/pipeline` — the GPU timeline, currently on the home page)
- **Boards** (section header, non-link)
  - One entry per board, showing name + icon
  - **+ New Board** button at the bottom

**FR-N2:** Each board lives at `/boards/[slug]`. The active board is highlighted in the sidebar.

**FR-N3:** The dashboard home page (`/`) shows a compact **Boards Summary** widget below the service cards: one row per board showing name, column names, and document count per column. Clicking a row navigates to the full board page.

### 4.4 Board Page

**FR-K1:** The board page (`/boards/[slug]`) shows:
- Board name + icon as page header
- Edit board button (gear icon → opens Board Builder modal)
- Horizontal column layout; each column shows name, count badge, and cards
- Columns are not scrollable horizontally on the page — they fill the viewport width equally

**FR-K2:** Each column is vertically scrollable if it has many cards. Column header is sticky.

**FR-K3:** Each **card** shows:
- Document title (truncated to 2 lines)
- Document ID (small, monospace)
- Created/added date
- Values of configured `cardFields` — each shown as `Field: Value` in a compact layout
- A link icon that opens the document in Paperless at `http://localhost:8000/documents/[id]/`

**FR-K4:** Cards support **drag-and-drop** between columns. Dragging a card to a new column immediately updates the document's `columnField` value in Paperless via `PATCH /api/documents/[id]/` with the new field value. The card moves optimistically (immediately in UI); if the API call fails, it snaps back to the original column with a toast error.

**FR-K5:** For users who prefer not to drag, each card has a **"Move to →"** dropdown button showing the other columns. Selecting a column performs the same field update.

**FR-K6:** The board auto-refreshes every 60 seconds. A manual refresh button is shown in the board header.

**FR-K7:** If a board's `docType` returns zero documents, show a friendly empty state: "No [docType] documents yet. Drop a file into the consume folder to get started."

### 4.5 Board Builder

**FR-BB1:** Accessible via the **+ New Board** button in the sidebar and the **Edit board** button on the board page. Opens a modal (`<Dialog>`).

**FR-BB2:** The builder has the following fields:

| Field | Input type | Notes |
|-------|-----------|-------|
| Name | Text | Required |
| Icon | Icon picker (small grid of Lucide icons) | Optional |
| Document type | Dropdown | Populated from `GET /api/paperless/document-types` |
| Column field | Dropdown | Populated from `GET /api/paperless/custom-fields` — only shows fields of type `select` |
| Columns | Ordered list | Each row: field value (dropdown, populated from field's choices) + custom label + color picker. Drag to reorder. |
| Card fields | Multi-select | All custom fields for the selected document type |

**FR-BB3:** Column values are populated by fetching the `custom_field` definition from Paperless API. Only `select`-type fields are offered as column fields (this covers `Status` and any future select fields).

**FR-BB4:** Saving the builder writes to `boards.yaml` via `PUT /api/boards/[slug]` (or `POST /api/boards` for new boards). The board page reloads.

**FR-BB5:** Deleting a board removes it from `boards.yaml`. A confirmation dialog is shown. Paperless documents are NOT modified.

### 4.6 Dashboard API Routes

| Route | Method | Description |
|-------|--------|-------------|
| `/api/boards` | GET | List all boards from boards.yaml |
| `/api/boards` | POST | Create a new board |
| `/api/boards/[slug]` | GET | Get single board config |
| `/api/boards/[slug]` | PUT | Update board config |
| `/api/boards/[slug]` | DELETE | Delete board |
| `/api/boards/[slug]/documents` | GET | Fetch documents for board (proxies Paperless API, filtered by docType) |
| `/api/paperless/document-types` | GET | Proxy: list document types from Paperless |
| `/api/paperless/custom-fields` | GET | Proxy: list custom fields from Paperless |
| `/api/documents/[id]/field` | PATCH | Update a single custom field value on a document |

All Paperless proxy routes use the `PAPERLESS_URL` + `PAPERLESS_API_TOKEN` env vars. They exist to avoid CORS from the browser.

### 4.7 Project Structure (additions)

```
apps/dashboard/
├── config/
│   ├── stack.yaml          (existing)
│   └── boards.yaml         (new — board definitions)
├── src/
│   ├── app/
│   │   ├── boards/
│   │   │   └── [slug]/
│   │   │       └── page.tsx       (board page)
│   │   ├── api/
│   │   │   ├── boards/
│   │   │   │   ├── route.ts       (GET list, POST new)
│   │   │   │   └── [slug]/
│   │   │   │       ├── route.ts   (GET, PUT, DELETE)
│   │   │   │       └── documents/
│   │   │   │           └── route.ts
│   │   │   ├── paperless/
│   │   │   │   ├── document-types/route.ts
│   │   │   │   └── custom-fields/route.ts
│   │   │   └── documents/
│   │   │       └── [id]/
│   │   │           └── field/route.ts
│   │   ├── layout.tsx      (updated — adds sidebar)
│   │   └── page.tsx        (updated — adds Boards Summary widget)
│   ├── components/
│   │   ├── sidebar.tsx             (new)
│   │   ├── kanban-board.tsx        (new — full board with columns)
│   │   ├── kanban-column.tsx       (new — single column + cards)
│   │   ├── kanban-card.tsx         (new — document card)
│   │   ├── board-builder.tsx       (new — create/edit modal)
│   │   └── boards-summary.tsx      (new — dashboard overview widget)
│   └── lib/
│       └── boards.ts               (new — boards.yaml reader/writer + types)
```

---

## 5. Non-Goals / Out of Scope

- **No Swimlane / timeline view** — columns only. Gantt is PRD 1's pipeline chart.
- **No card creation** — documents are created by the consume pipeline, not from the board.
- **No within-column ordering** — cards are sorted by date added (newest first). No manual drag-to-reorder within a column.
- **No multi-field columns** — one field determines one column. Complex multi-field logic (e.g., "submitted to BOTH insurers") is shown via card field values, not separate columns.
- **No board sharing / export** — local only.
- **No tag-based columns** — the "tags" column mode was considered and deferred. One select field → one column only.
- **No notifications** — no alerts when a document enters a column.
- **No bulk move** — one card at a time.

---

## 6. Design Considerations

### Layout

```
┌──────────┬─────────────────────────────────────────────────┐
│ Overview │  Medical Bills                    [Edit] [↺]   │
│ Pipeline │                                                  │
│ ──────── │  ┌───────────┐ ┌───────────┐ ┌───────────┐     │
│ BOARDS   │  │ Incoming  │ │ Submitted │ │Reimbursed │     │
│ Medical  │  │    (3)    │ │    (5)    │ │    (12)   │     │
│ Invoices │  ├───────────┤ ├───────────┤ ├───────────┤     │
│ + New    │  │ #42       │ │ #38       │ │ #31       │     │
│          │  │ Telekom   │ │ OEGKK     │ │ Dental    │     │
│          │  │ €123.40   │ │ €88.00    │ │ €44.00    │     │
│          │  │ 2026-04-01│ │ 2026-03-15│ │ 2026-02-10│     │
│          │  │ [→ Move]  │ │ [→ Move]  │ │ [→ Move]  │     │
│          │  └───────────┘ └───────────┘ └───────────┘     │
└──────────┴─────────────────────────────────────────────────┘
```

- **Colors:** Dark theme matching PRD 1. Column headers use configured color as a left border accent, not a full background (avoids visual noise).
- **Cards:** Same `rounded-xl border border-neutral-800 bg-neutral-900` as service cards in PRD 1.
- **Drag handle:** Subtle grip dots on card hover. Drag uses `@dnd-kit` (not HTML5 drag API — more reliable on trackpads).

### Board Builder Modal

```
┌─────────────────────────────────────┐
│  Edit Board                     [×] │
│                                     │
│  Name:  [Medical Bills          ]   │
│  Icon:  [🩺] [📄] [💰] [📋] ...   │
│                                     │
│  Document type:  [XNC medical  ▼]   │
│  Column field:   [Status       ▼]   │
│                                     │
│  Columns (drag to reorder):         │
│  ⠿ [Inbox    ▼] → Incoming   [●]   │
│  ⠿ [Waiting  ▼] → Submitted  [●]   │
│  ⠿ [Done     ▼] → Reimbursed [●]   │
│  [+ Add column]                     │
│                                     │
│  Show on cards:                     │
│  [✓] Amount  [✓] Treatment date     │
│  [✓] Submitted OEGKK  [ ] InvoiceNr │
│                                     │
│        [Cancel]  [Save Board]       │
└─────────────────────────────────────┘
```

---

## 7. Technical Considerations

### Stack

| Layer | Choice | Why |
|-------|--------|-----|
| Drag-and-drop | `@dnd-kit/core` + `@dnd-kit/sortable` | Accessible, pointer+touch, no HTML5 drag issues |
| Board config | `boards.yaml` (same pattern as `stack.yaml`) | Human-readable, version-controlled, already have reader/writer lib |
| Paperless API | REST via server-side Next.js proxy routes | Avoids CORS; reuses existing `PAPERLESS_API_TOKEN` |
| State | React `useState` + optimistic updates | No additional state library needed; boards are not complex enough to warrant Zustand/Jotai |

### Paperless API calls used

- `GET /api/documents/?document_type__name=[type]&page_size=100` — fetch all docs for a board
- `GET /api/document_types/` — list doc types for board builder
- `GET /api/custom_fields/` — list custom fields for board builder
- `PATCH /api/documents/[id]/` — update a document's custom field value when moving a card

### Custom field update format

Paperless custom fields are updated via a `custom_fields` array patch:
```json
PATCH /api/documents/42/
{
  "custom_fields": [
    { "field": 3, "value": "Waiting" }
  ]
}
```
The field ID (integer) must be looked up by name from `/api/custom_fields/`. The board config stores field names (human-readable); the API layer resolves names to IDs at call time, caching the lookup.

### boards.yaml location

Stored at `CONFIG_PATH`'s sibling: `/app/config/boards.yaml` in Docker, or wherever `CONFIG_PATH` points in dev. The `boards.ts` lib uses the same `process.env.CONFIG_PATH` directory as `config.ts`.

---

## 8. Success Metrics

| Metric | Target |
|--------|--------|
| Board page load time | < 2 seconds (100 documents) |
| Card move latency | Optimistic UI instant; Paperless PATCH < 1s |
| Create a new board end-to-end | < 2 minutes first time |
| Medical Bills board pre-built | Visible on first `docker compose up` with no setup |

---

## 9. Open Questions

| # | Question | Owner | Notes |
|---|----------|-------|-------|
| OQ1 | Should boards.yaml be seeded automatically on first run, or require a manual bootstrap step? | Decide at implementation | Recommend: dashboard checks for missing boards.yaml on startup and seeds defaults |
| OQ2 | What happens when a document type is renamed in Paperless? | — | Board stops showing docs. Mitigation: show a warning banner when docType not found |
| OQ3 | Should the sidebar be collapsible? | Marcus | Nice-to-have for narrow screens |
| OQ4 | Pagination — what if a column has >100 docs? | — | Start with 100 doc limit, add "Load more" in Phase 2 |
| OQ5 | Should the Boards Summary widget on the home page be opt-out (shown by default) or opt-in? | Marcus | Recommend shown by default |
