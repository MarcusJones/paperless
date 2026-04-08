# PRD 1: Dashboard & Pipeline Visibility

**Status:** Complete
**Author:** Marcus Jones
**Date:** 2026-04-08
**Series:** 1 of 3 — [Dashboard & Visibility] → [Smart Pipeline](prd-smart-pipeline.md) → [Hybrid Cloud](prd-hybrid-cloud.md)

---

## 1. Introduction / Overview

The Paperless stack runs 11 Docker containers with no unified entry point. Checking stack health requires opening 6 browser tabs, remembering port numbers, and mentally correlating GPU spikes with document activity. There's no way to profile pipeline performance — which model is running, how long each stage takes — without reading raw logs.

**What this delivers:** A Next.js 16 dashboard (port 5000) that serves as the single landing page for the entire Paperless stack. It shows:

1. **Service cards** — live status, links to each service UI, direct link to its logs in Dozzle, and key stats (doc count, active model, VRAM usage).
2. **GPU / pipeline timeline** — a real-time chart with GPU% and VRAM% as line graphs, overlaid with a per-document swimlane showing each doc's lifecycle through the 3-stage pipeline (Ingest → Vision OCR → AI Classify).
3. **Settings modal** — view and edit service endpoints, see the current configuration at a glance.

Time-series data (GPU samples + pipeline events) is stored in **QuestDB**, a lightweight SQL time-series database running as a new compose service.

**Note:** This PRD covers the existing 3-stage pipeline. [PRD 2 (Smart Pipeline)](prd-smart-pipeline.md) upgrades the pipeline to smart routing with triage, rule engine, and feedback loop. The dashboard is designed to accommodate both — the swimlane chart supports arbitrary stage types.

---

## 2. Goals

| # | Goal | Measurable |
|---|------|-----------|
| G1 | Single URL for all services | `http://localhost:5000` opens the dashboard; all service links are one click away |
| G2 | GPU timeline with 60-min rolling window | GPU% and VRAM% lines visible, updating every 10s |
| G3 | Per-document swimlane | Each document processed in the last 60 min has a visible swimlane row with stage bars |
| G4 | Service health at a glance | Each card shows green/yellow/red within 35s of a service going up or down |
| G5 | Pipeline profiling | Each swimlane bar shows which model ran, how long it took |
| G6 | Zero manual data entry | All data collected automatically from Docker logs and APIs |
| G7 | Lightweight | Dashboard + QuestDB together use < 512 MB RAM at idle |

---

## 3. User Stories

**US1 — Is my system working?**
As a user who just scanned a stack of bills, I want to glance at one page and see that all services are green, so I can trust that my documents will be processed without checking multiple admin panels.

**US2 — Profiling the pipeline**
As a user who just dropped a medical invoice into the consume folder, I want to see it progress through each pipeline stage in real time — which model is running, how long each stage takes, and where time is being spent — so I can make informed decisions about my setup (swap models, adjust max loaded models, change OCR strategy) without digging through logs.

**US3 — Why is my document stuck?**
As a user waiting for a tax document to be classified, I want to see which pipeline stage it's in and how long it's been there, so I can tell whether it's still processing or something went wrong.

**US4 — Quick access to any service**
As a user who needs to check Paperless to review a tagged document or open the AI logs to see why something was misclassified, I want one-click links to every service UI from the dashboard, so I don't have to remember port numbers or bookmark each tool separately.

**US5 — What happened while I was away?**
As a user who scanned documents before leaving for work, I want to see which documents were processed in the last hour and whether any are still pending, so I can catch up on what got filed and spot anything that needs attention.

**US6 — Confidence the system is keeping up**
As a user who processes batches of receipts, insurance letters, and payslips throughout the week, I want to see GPU and processing activity over time, so I can tell whether the system is handling my volume or falling behind.

---

## 4. Functional Requirements

### 4.1 Service Cards

Service cards are displayed in a responsive grid below the timeline chart.

| Service | UI URL | Dozzle container name | Stats to show |
|---------|--------|-----------------------|---------------|
| Paperless-ngx | `localhost:8000` | `paperless-paperless-1` | Doc count, unprocessed count |
| paperless-ai-next | `localhost:3000` | `paperless-paperless-ai-next-1` | AI-processed doc count |
| paperless-gpt | `localhost:8080` | `paperless-paperless-gpt-1` | — |
| Open WebUI | `localhost:3001` | `paperless-open-webui-1` | — |
| Dozzle | `localhost:9999` | `paperless-dozzle-1` | — |
| Ollama | `localhost:11434` | `paperless-ollama-1` | Loaded models, VRAM used, model name |
| QuestDB | `localhost:9000` | `paperless-questdb-1` | Row counts |

**FR-C1:** Each card shows a colored status dot: green (healthy), yellow (reachable but degraded), red (unreachable).

**FR-C2:** Status is determined by server-side HTTP probes (avoids CORS). Probe targets:
- Paperless: `GET http://paperless:8000/accounts/login/` → any 2xx/3xx = green
- paperless-ai-next: `GET http://paperless-ai-next:3000/health` → 200 = green
- paperless-gpt: `GET http://paperless-gpt:8080/` → any 2xx/3xx = green
- Open WebUI: `GET http://open-webui:3001/` → any 2xx/3xx = green
- Dozzle: `GET http://dozzle:9999/` → any 2xx/3xx = green
- Ollama: `GET http://ollama:11434/api/tags` → 200 = green
- QuestDB: `GET http://questdb:9000/` → any 2xx/3xx = green

**FR-C3:** Each card has two link buttons: "Open" (→ service UI) and "Logs" (→ Dozzle per-container log URL, e.g., `http://localhost:9999/container/{name}`).

**FR-C4:** Stats (doc count, AI-processed count, Ollama models + VRAM) are fetched via server-side Next.js API routes. The Ollama card prominently displays the **active model name** and **VRAM usage** — this is critical for the profiling use case (US2).

**FR-C5:** Cards auto-refresh every 30 seconds, silently. Status dots update in place.

**FR-C6:** Service endpoints are configurable via environment variables. The settings modal (§4.5) shows the current values and allows editing. This is forward-compatible with [PRD 3 (Hybrid Cloud)](prd-hybrid-cloud.md) where endpoints can be local or remote.

### 4.2 GPU / Pipeline Timeline Chart

**FR-T1:** The chart uses **Apache ECharts** (via `echarts-for-react`). Single canvas with two vertically stacked areas sharing a time X-axis:

- **Top area (60% height):** Two line series — GPU utilization % and VRAM used %. Y-axis: 0–100%.
- **Bottom area (40% height):** Swimlane / Gantt-style view. One row per document (doc ID + truncated title). Each row shows colored bars for each pipeline stage.

**FR-T2:** Time window is a rolling 60-minute view. X-axis advances in real time.

**FR-T3:** Pipeline stages are color-coded:
- **Stage 1 – Ingest** (Tesseract OCR): blue
- **Stage 2 – Vision OCR** (paperless-gpt / qwen2.5vl): orange
- **Model swap gap** (idle between model loads): grey hatched
- **Stage 3 – AI Classify** (paperless-ai-next / qwen3:14b): green

**Note:** [PRD 2 (Smart Pipeline)](prd-smart-pipeline.md) adds more stage types (triage, fast OCR, rules). The chart is designed with a `stageColors` map that is extensible — new stages just need a new color entry.

**FR-T4:** Hovering over a swimlane bar shows tooltip: doc ID, title (truncated), stage name, **model used** (for OCR/LLM stages), start time, end time, duration.

**FR-T5:** Hovering over the GPU line shows: timestamp, GPU%, VRAM (MiB), VRAM total (MiB), and — if a document was being processed at that moment — the doc ID and active stage.

**FR-T6:** Chart updates every 10 seconds by polling `/api/metrics`.

**FR-T7:** Show the last 20 documents. If >20 in the 60-min window, show most recent.

### 4.3 Data Collection

**FR-D1:** A background collector runs inside the dashboard container (started via Next.js `instrumentation.ts` on server startup). It has two jobs:

**Job A — GPU poller** (every 5 seconds):
- Reads the last log line from the `gpu-monitor` container via Docker socket (`/var/run/docker.sock` mounted read-only).
- Parses `nvidia-smi` output → GPU%, VRAM used MiB, VRAM total MiB.
- Writes to QuestDB `gpu_metrics` table via HTTP API.

**Job B — Pipeline event tailer** (continuous):
- Reads stdout of the `pipeline-timing` container via Docker socket.
- The upgraded `pipeline-timing-container.sh` (§4.4) emits JSON Lines.
- Parses each JSONL event and writes to QuestDB `pipeline_events` table.

**FR-D2:** QuestDB tables:

```sql
CREATE TABLE IF NOT EXISTS gpu_metrics (
  ts         TIMESTAMP,
  gpu_pct    INT,
  vram_used  INT,   -- MiB
  vram_total INT    -- MiB
) TIMESTAMP(ts) PARTITION BY HOUR;

CREATE TABLE IF NOT EXISTS pipeline_events (
  ts         TIMESTAMP,
  doc_id     LONG,
  title      SYMBOL,
  stage      SYMBOL,    -- extensible: 'ingest_start' | 'ocr_start' | etc.
  model_name SYMBOL,    -- which model ran this stage
  pages      INT
) TIMESTAMP(ts) PARTITION BY DAY;
```

**FR-D3:** QuestDB retains 7 days. Older partitions auto-dropped via TTL.

**FR-D4:** Collector is resilient: retries after 30s on Docker socket or QuestDB failure. Never crashes the Next.js process.

### 4.4 Upgraded Pipeline Timing Script

**FR-P1:** When `OUTPUT_FORMAT=jsonl`, each pipeline event is emitted as a single JSON object:

```jsonc
{"ts":"2026-04-08T12:01:00.000Z","doc_id":42,"title":"Invoice Telekom","stage":"ingest_start","model":"tesseract","pages":0}
{"ts":"2026-04-08T12:01:15.000Z","doc_id":42,"title":"Invoice Telekom","stage":"ingest_end","model":"tesseract","pages":0}
{"ts":"2026-04-08T12:01:16.000Z","doc_id":42,"title":"Invoice Telekom","stage":"ocr_start","model":"qwen2.5vl:7b","pages":0}
{"ts":"2026-04-08T12:01:45.000Z","doc_id":42,"title":"Invoice Telekom","stage":"ocr_end","model":"qwen2.5vl:7b","pages":3}
{"ts":"2026-04-08T12:02:05.000Z","doc_id":42,"title":"Invoice Telekom","stage":"classify_start","model":"qwen3:14b","pages":0}
{"ts":"2026-04-08T12:02:28.000Z","doc_id":42,"title":"Invoice Telekom","stage":"classify_end","model":"qwen3:14b","pages":0}
```

**FR-P2:** Human-readable format remains the default when `OUTPUT_FORMAT` is not set.

**FR-P3:** Doc titles fetched from Paperless API on first sight (one GET per doc, cached in memory). Falls back to `"doc_{id}"`.

### 4.5 Settings Modal

**FR-S1:** Accessible from a gear icon in the dashboard header. A shadcn/ui `<Dialog>` with tabs:

**Tab 1 — Services:**
- Lists every service with: name, current endpoint URL, health status, latency (ms).
- Each endpoint is editable inline. Changes write to env-based config and trigger a re-probe.

**Tab 2 — Pipeline:**
- Shows current pipeline configuration (OCR model, classify model, tag lists).
- Read-only in this PRD. [PRD 2](prd-smart-pipeline.md) makes triage thresholds and model selection editable.

**FR-S2:** Settings persist to a config file (`dashboard/config/stack.yaml`). This is the same config file that [PRD 3 (Hybrid Cloud)](prd-hybrid-cloud.md) extends with cloud endpoints and network config.

### 4.6 Dashboard API Routes

| Route | Method | Description |
|-------|--------|-------------|
| `/api/status` | GET | Health probe results for all services + stats |
| `/api/metrics?minutes=60` | GET | GPU time-series from QuestDB |
| `/api/events?minutes=60` | GET | Pipeline events from QuestDB |
| `/api/config` | GET | Current service configuration |
| `/api/config` | PUT | Update service endpoints |

### 4.7 Compose Integration

**FR-I1:** Two new services added to `compose.yaml`:

```yaml
questdb:
  image: questdb/questdb:8.x
  ports:
    - "9000:9000"   # web UI + REST API
    - "9009:9009"   # ILP (line protocol)
    - "8812:8812"   # PostgreSQL wire protocol
  volumes:
    - ./questdb/data:/var/lib/questdb
  restart: unless-stopped

dashboard:
  build: ./dashboard
  ports:
    - "5000:3000"
  environment:
    - PAPERLESS_URL=http://paperless:8000
    - PAPERLESS_API_TOKEN=${PAPERLESS_API_TOKEN}
    - QUESTDB_URL=http://questdb:9000
    - OLLAMA_URL=http://ollama:11434
    - PIPELINE_TIMING_CONTAINER=paperless-pipeline-timing-1
    - CONFIG_PATH=/app/config/stack.yaml
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock:ro
    - ./dashboard/config:/app/config
  depends_on:
    - questdb
    - paperless
  restart: unless-stopped
```

**FR-I2:** `./questdb/data/` is gitignored.

### 4.8 Project Structure

```
paperless/
├── apps/
│   └── dashboard/                 # @app/dashboard — Next.js 16
│       ├── src/
│       │   ├── app/               # App Router pages + API routes
│       │   │   ├── api/
│       │   │   │   ├── status/route.ts
│       │   │   │   ├── metrics/route.ts
│       │   │   │   ├── events/route.ts
│       │   │   │   └── config/route.ts
│       │   │   ├── layout.tsx
│       │   │   └── page.tsx
│       │   ├── components/
│       │   │   ├── service-cards.tsx
│       │   │   ├── pipeline-timeline.tsx
│       │   │   └── settings-modal.tsx
│       │   ├── lib/
│       │   │   ├── questdb.ts     # QuestDB HTTP client
│       │   │   ├── docker.ts      # dockerode wrapper
│       │   │   └── config.ts      # stack.yaml reader/writer
│       │   └── instrumentation.ts # Background collector
│       ├── config/
│       │   └── stack.yaml
│       ├── Dockerfile
│       ├── next.config.ts
│       └── package.json
├── packages/
│   └── ui/                        # @repo/ui — shared shadcn/ui components
├── turbo.json
├── pnpm-workspace.yaml
└── package.json
```

---

## 5. Non-Goals / Out of Scope

- **No authentication** — dashboard is localhost-only, no login.
- **No document management** — can't upload, tag, or edit docs from the dashboard.
- **No alerting** — no notifications when services go red.
- **No cloud deployment** — this is local Docker Compose only. See [PRD 3](prd-hybrid-cloud.md).
- **No smart pipeline routing** — uses existing 3-stage flow. See [PRD 2](prd-smart-pipeline.md).
- **No rule engine or suggestions queue** — see [PRD 2](prd-smart-pipeline.md).
- **No mobile optimization** — desktop browser only (1280px+).
- **No GPU fan/temperature data** — GPU% and VRAM only.
- **No historical data beyond 7 days** — QuestDB TTL drops older partitions.

---

## 6. Design Considerations

### Layout

```
┌─────────────────────────────────────────────────────────────┐
│  Paperless Stack                       [Settings] [updated Xs] │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  GPU/VRAM %  ▂▃▅▇███▇▅▃▂  (line chart, 60min)             │
│  ────────────────────────────────────────────────────────── │
│  Doc #42     [══ingest══][═══OCR (3pg)═══][═classify═]      │
│  Doc #43               [══════OCR══════][══classify══]      │
│  Doc #44                         [═══OCR═══]                │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│ [Paperless ●] [AI Next ●] [GPT-OCR ●] [Ollama ●]          │
│  324 docs      291 AI-done             qwen3:14b 9.3GB     │
│ [Open WebUI ●] [Dozzle ●] [QuestDB ●]                     │
└─────────────────────────────────────────────────────────────┘
```

- **Color scheme:** Dark background (#0f0f0f), green/orange/blue stage colors, subtle grid lines.
- **Font:** Geist Mono for stats/numbers, Geist Sans for labels (via `next/font`).
- **Components:** shadcn/ui `<Card>`, `<Dialog>`, `<Tabs>`, `<Badge>`.

### ECharts Implementation

`custom` series for swimlane, `line` series for GPU, shared `dataZoom`. The `stageColors` map is extensible for [PRD 2](prd-smart-pipeline.md) stages.

---

## 7. Technical Considerations

### Stack

| Layer | Choice | Why |
|-------|--------|-----|
| Framework | Next.js 16, App Router, TypeScript | Standard stack per tech reference |
| Build | Turborepo + pnpm monorepo | Standard stack; dashboard is `@app/dashboard` |
| Styling | Tailwind v4 + shadcn/ui | Standard stack |
| Charts | Apache ECharts via `echarts-for-react` | Swimlane + line on shared time axis |
| Time-series DB | QuestDB | Lightweight (~200MB), SQL, HTTP API, built-in web UI |
| Collection | `instrumentation.ts` background job | No separate sidecar |
| Docker client | `dockerode` | Stream log tailing |
| Config | YAML (`stack.yaml`) | Human-readable, version-controlled |

### QuestDB vs TimescaleDB

- TimescaleDB requires a different Postgres image — can't add to existing `postgres:16`.
- Adding it risks disrupting the Paperless database.
- QuestDB is standalone, purpose-built, ~200MB Docker image.
- At 1 GPU sample/5s = ~17k rows/day, QuestDB is overspecified but adds SQL queryability and a web UI.

### Dev Workflow

- Local dev: `pnpm dev` in devcontainer on port 5001. QuestDB runs in compose.
- Production local: `docker compose up` builds dashboard image, runs everything.
- Dockerfile: multi-stage `node:22-alpine` builder + runner with `output: "standalone"`.

---

## 8. Success Metrics

| Metric | Target |
|--------|--------|
| Dashboard first load | < 2 seconds |
| Service status reflects reality | < 35 seconds of state change |
| GPU line lag | < 15 seconds |
| Swimlane shows new doc | < 20 seconds of Stage 1 completion |
| Dashboard + QuestDB RAM at idle | < 512 MB combined |
| QuestDB disk after 7 days | < 100 MB |

---

## 9. Open Questions

| # | Question | Owner | Notes |
|---|----------|-------|-------|
| OQ1 | Exact Dozzle per-container log URL format? | Verify | Likely `http://localhost:9999/container/{name}` — check Dozzle docs. |
| OQ2 | Does `pipeline-timing-container.sh` receive doc titles? | Check logs | May need Paperless API call per doc. |
| OQ3 | Docker socket available in devcontainer for `next dev`? | Marcus | Devcontainer has no Docker daemon. Socket only in compose mode. |
| OQ4 | Should QuestDB web UI (port 9000) be a service card? | Marcus | Useful debugging tool, added as 7th card in this PRD. |
| OQ5 | Should the dashboard be the default browser tab on stack startup? | Marcus | Low effort, nice QoL improvement. |

---

## 10. Task List

### Pre-flight Requirements

- **npm packages:** Listed in `apps/dashboard/package.json`. Run `pnpm install` inside `apps/dashboard/` after creation.
- **Environment variables:** `PAPERLESS_API_TOKEN` must be present in root `.env` (already required by existing services).
- **System:** Docker socket available at `/var/run/docker.sock` (only in compose mode, not devcontainer — see OQ3).

---

### Phase 1: Infrastructure

- [x] **T1.1** Add pnpm workspace root config (`pnpm-workspace.yaml`, `turbo.json`, root `package.json`)
- [x] **T1.2** Add QuestDB service to `compose.yaml`
- [x] **T1.3** Add dashboard service to `compose.yaml` with correct volumes/env
- [x] **T1.4** Update `.gitignore` with `questdb/data/` and `apps/dashboard/.next/`

### Phase 2: Dashboard App Scaffold

- [x] **T2.1** Create `apps/dashboard/package.json` with all dependencies
- [x] **T2.2** Create `apps/dashboard/next.config.ts` (standalone output)
- [x] **T2.3** Create `apps/dashboard/tsconfig.json`
- [x] **T2.4** Create `apps/dashboard/postcss.config.mjs` (Tailwind v4)
- [x] **T2.5** Create `apps/dashboard/Dockerfile` (multi-stage, standalone output)
- [x] **T2.6** Create `apps/dashboard/config/stack.yaml` (initial service config)

### Phase 3: Core Libraries

- [x] **T3.1** Create `apps/dashboard/src/lib/config.ts` (stack.yaml reader/writer + types)
- [x] **T3.2** Create `apps/dashboard/src/lib/questdb.ts` (QuestDB HTTP client for reads + writes)
- [x] **T3.3** Create `apps/dashboard/src/lib/docker.ts` (dockerode wrapper for log streaming)

### Phase 4: API Routes

- [x] **T4.1** Create `apps/dashboard/src/app/api/status/route.ts` (health probes + stats)
- [x] **T4.2** Create `apps/dashboard/src/app/api/metrics/route.ts` (GPU time-series from QuestDB)
- [x] **T4.3** Create `apps/dashboard/src/app/api/events/route.ts` (pipeline events from QuestDB)
- [x] **T4.4** Create `apps/dashboard/src/app/api/config/route.ts` (GET + PUT service config)

### Phase 5: React Components

- [x] **T5.1** Create `apps/dashboard/src/components/service-cards.tsx` (status dots, links, stats)
- [x] **T5.2** Create `apps/dashboard/src/components/pipeline-timeline.tsx` (ECharts GPU + swimlane)
- [x] **T5.3** Create `apps/dashboard/src/components/settings-modal.tsx` (shadcn Dialog + Tabs)

### Phase 6: Pages + Background Collector

- [x] **T6.1** Create `apps/dashboard/src/app/globals.css` + `layout.tsx` + `page.tsx`
- [x] **T6.2** Create `apps/dashboard/src/instrumentation.ts` (GPU poller + pipeline log tailer)

### Phase 7: Pipeline Script Upgrade

- [x] **T7.1** Upgrade `scripts/pipeline-timing-container.sh` with `OUTPUT_FORMAT=jsonl` mode (FR-P1, FR-P2)
- [x] **T7.2** Add `PAPERLESS_API_TOKEN` + `PAPERLESS_URL` env vars to pipeline-timing service in `compose.yaml`

---

### Relevant Files

*Updated as implementation progresses.*

| File | Purpose |
|------|---------|
| `apps/dashboard/package.json` | Dashboard app dependencies |
| `apps/dashboard/Dockerfile` | Multi-stage production build |
| `apps/dashboard/config/stack.yaml` | Service endpoint config |
| `apps/dashboard/src/instrumentation.ts` | Background GPU + pipeline event collector |
| `apps/dashboard/src/lib/questdb.ts` | QuestDB HTTP client |
| `apps/dashboard/src/lib/docker.ts` | Dockerode log-streaming wrapper |
| `apps/dashboard/src/lib/config.ts` | stack.yaml reader/writer |
| `apps/dashboard/src/app/api/status/route.ts` | Service health probes |
| `apps/dashboard/src/app/api/metrics/route.ts` | GPU metrics from QuestDB |
| `apps/dashboard/src/app/api/events/route.ts` | Pipeline events from QuestDB |
| `apps/dashboard/src/app/api/config/route.ts` | Config GET + PUT |
| `apps/dashboard/src/components/service-cards.tsx` | Service status cards |
| `apps/dashboard/src/components/pipeline-timeline.tsx` | ECharts GPU + swimlane |
| `apps/dashboard/src/components/settings-modal.tsx` | Settings dialog |
| `apps/dashboard/src/app/page.tsx` | Main dashboard page |
| `scripts/pipeline-timing-container.sh` | Updated with JSONL mode |
| `compose.yaml` | Added questdb + dashboard services |

---

### Progress Log

| Date | Task | Note |
|------|------|------|
| 2026-04-08 | PRD | Added task list, started implementation |
| 2026-04-08 | T1.1–T1.4 | Monorepo setup, QuestDB + dashboard in compose, .gitignore |
| 2026-04-08 | T2.1–T2.6 | Dashboard app scaffold (package.json, next.config, tsconfig, Dockerfile, stack.yaml) |
| 2026-04-08 | T3.1–T3.3 | Core libraries: config.ts, questdb.ts, docker.ts |
| 2026-04-08 | T4.1–T4.4 | API routes: /api/status, /api/metrics, /api/events, /api/config |
| 2026-04-08 | T5.1–T5.3 | React components: ServiceCards, PipelineTimeline (ECharts), SettingsModal |
| 2026-04-08 | T6.1–T6.2 | Pages (globals.css, layout, page) + instrumentation.ts background collector |
| 2026-04-08 | T7.1–T7.2 | pipeline-timing-container.sh JSONL mode + env vars in compose |
| 2026-04-08 | All | All tasks complete. TypeScript passes clean. |
