# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker-based Paperless-ngx document management system with AI tagging, running locally in WSL2. The repo is a `compose.yaml` + folder-per-service layout that orchestrates 10 Docker containers for a document ingestion → Tesseract OCR → AI classification pipeline, with opt-in vision OCR (paperless-gpt / qwen2.5vl:7b) as a manual re-run path for documents where Tesseract text is insufficient.

## Tech Stack

- **Core:** Paperless-ngx (document storage, Tesseract OCR, web UI)
- **AI Classification:** paperless-ai-next (admonstrator/paperless-ai-next) → webhook-triggered, sends to Ollama qwen3:14b for title/tags/correspondent/type
- **Vision OCR:** paperless-gpt (icereed/paperless-gpt) → re-OCRs scanned docs using qwen2.5vl:7b vision model
- **LLM Host:** Ollama (`ollama/ollama`) — runs as a Docker service with nvidia GPU passthrough, API at `:11434`
- **Database:** PostgreSQL 16 + Redis 7 (task queue)
- **Doc Processing:** Apache Tika (office extraction) + Gotenberg (PDF rendering)
- **Monitoring:** Dozzle (log viewer at :9999), Open WebUI (Ollama management at :3001)
- **Language:** Bash (operational scripts only), no application code in this repo

## Architecture

### Document Pipeline — default path + opt-in vision

**Default path (every new doc, fully automatic):**

```
┌─────────────┐   tag   ┌────────────────────┐
│  INGEST     │────────▶│  AI CLASSIFY       │
│  paperless  │         │  paperless-ai-next │
└─────────────┘         └────────────────────┘
 Tesseract (auto)          qwen3:14b (webhook)
 on document_added,         on classification-pending
 tag: classification-pending tag, via Workflow 3
```

1. **Paperless-ngx** (:8000) — ingests from Dropbox consume folder, runs Tesseract OCR automatically.
   - Workflow "Auto AI Classification": assigns `classification-pending` tag to every new doc.
2. **paperless-ai-next** (:3000) — webhook fires on the tag; runs qwen3:14b to set title / correspondent / doc type / tags / custom fields. Adds `processed` tag. Cleanup workflow removes `classification-pending`.

**Opt-in vision OCR (manual re-run for bad Tesseract text):**

```
┌──────────────────────┐   ocr-pending    ┌──────────────────┐   classification-pending   ┌────────────────────┐
│ User applies         │─────────────────▶│  VISION OCR      │───────────────────────────▶│  AI CLASSIFY       │
│ ocr-pending tag in UI│                  │  paperless-gpt   │                            │  paperless-ai-next │
└──────────────────────┘                  └──────────────────┘                            └────────────────────┘
 single doc or bulk-edit                    qwen2.5vl:7b                                    qwen3:14b re-runs,
                                            replaces doc text                               overwrites classification
```

When the user applies `ocr-pending`:
- Workflow "Re-run pipeline on manual vision request" strips the `processed` tag so re-classification is not short-circuited.
- `paperless-gpt` picks up the tag, runs vision OCR, replaces document text, removes `ocr-pending`, adds `classification-pending` (via `PDF_OCR_COMPLETE_TAG`).
- Workflow 3 fires again → `paperless-ai-next` re-classifies from scratch.

**Model swap:** When vision is invoked, qwen3:14b is unloaded and qwen2.5vl:7b is loaded for OCR (~10-20s), then swapped back for classification (another ~10-20s). Only the default path avoids this cost entirely. Both models cannot coexist in 12GB VRAM (`OLLAMA_MAX_LOADED_MODELS=1`).

### Service Dependencies (compose.yaml)

```
redis ──┐
postgres ──┤
tika ──┤──▶ paperless ──▶ paperless-ai-next ──┐
gotenberg ──┘          └──▶ paperless-gpt ────┤──▶ ollama (GPU)
                                               │
open-webui ────────────────────────────────────┘

(paperless-ai-next and paperless-gpt wait for paperless: service_healthy + ollama: service_started)

dozzle      ──▶ Docker socket (read-only)
gpu-monitor ──▶ nvidia-smi loop → stdout (visible in Dozzle)
```

### Networking

Containers communicate on the default compose network. Services reach Ollama via `http://ollama:11434` (compose service name) — no `extra_hosts` or `host.docker.internal` needed for Ollama.

### Configuration Layout

```
compose.yaml          — all 9 services
.env                  — SECRETS ONLY (gitignored): API token, PG password, secret key, Dropbox user, AI next API key
.env.example          — template for .env (committed)

paperless/.env        — non-secret paperless config (OCR, DB coords, ports, locale)
postgres/.env         — DB name + user (password from root .env)
paperless-ai-next/.env — AI config: model, SYSTEM_PROMPT, PROMPT_TAGS, scan interval
paperless-gpt/.env    — OCR config: model, trigger tag, completion tag

scripts/              — operational scripts (compose-aware)
scripts-archive/      — old pre-compose scripts (reference only)
```

### Key Paths

- Consume dir: `./paperless/consume/` → symlink to `/mnt/c/Users/$DROPBOX_USER/Dropbox/paperless-consume`
- Export dir: `./paperless/export/` (bind-mounted, inspectable with `ls`)
- Data dirs: `./paperless/data/`, `./paperless/media/`, `./postgres/data/`, `./redis/data/` (all gitignored)
- AI state: `./paperless-ai-next/data/` (bind-mounted, includes logs.html)

## Scripts Reference

| Script | Purpose |
|--------|---------|
| `up.sh` | Runs `docker compose up -d`. Ollama is now a compose service — no host process management needed. |
| `scripts/bootstrap.sh` | Creates taxonomy via Paperless REST API (tags, types, Status field, storage path). Idempotent. |
| `scripts/diagnose.sh` | 10-check pipeline health: Ollama, models, container connectivity, tags, LLM smoke test |
| `scripts/backup.sh` | Exports docs with `document_exporter` + copies to Dropbox (timestamped) |
| `scripts/pipeline-timing.sh` | Tails compose logs and prints per-document stage timing (ingest, OCR, classify, swap, total) |

Old scripts are in `scripts-archive/` — kept for reference, no longer used for daily ops.

## Daily Operations (run on WSL host)

```bash
# Start full stack
docker compose up -d

# Stop (data preserved in bind-mount dirs)
docker compose down

# Tail all logs with timestamps
docker compose logs -f --timestamps

# Per-document pipeline timing
./scripts/pipeline-timing.sh

# Pipeline health check
./scripts/diagnose.sh

# Backup to Dropbox
./scripts/backup.sh

# See all container states
docker compose ps

# Exec into a container
docker compose exec paperless python3 manage.py shell
```

### Manual vision OCR (opt-in)

When a doc's Tesseract OCR text is bad enough that the AI mis-classifies it (wrong tags, wrong type, junk title), trigger a vision-OCR re-run:

1. Open the doc (or multi-select several) in the Paperless-ngx web UI at `:8000`.
2. Apply the `ocr-pending` tag via the tag picker or **Bulk Edit → Modify tags → Add `ocr-pending`**.
3. Leave it alone. `paperless-gpt` will pick it up within ~5s, vision-OCR the pages, replace the document text, and hand off to `paperless-ai-next` for re-classification. The `processed` marker is cleared by Workflow 2, so re-classification is not skipped.

Expected timing per doc:
- Model swap in (qwen3:14b → qwen2.5vl:7b): ~10–20s
- Vision OCR: ~30–60s per page at 1 MP (see `vision_ocr` block in `scripts/paperless-config.yaml`)
- Model swap out + classification (qwen2.5vl:7b → qwen3:14b → run): another ~20-30s

Because `OLLAMA_MAX_LOADED_MODELS=1`, bulk-tagged docs drain sequentially, not in parallel — expect ~90s per page of real time. Good for overnight batches; painful for large batches during the day.

Visibility: the "OCR Pending" saved view in the Paperless-ngx sidebar shows the live vision-OCR queue (filter on tag id 26).

## AI Tagging Pipeline — Integration Guide

### How the Components Connect

```
Paperless-ngx (:8000)        — REST API, stores documents + metadata
       ↕ API (Token auth)
paperless-gpt (:8080)        — polls by tag; idle unless a doc is tagged `ocr-pending`
       ↕ tag change fires Paperless Workflow webhook
paperless-ai-next (:3000)    — webhook-triggered, runs qwen3:14b classification
       ↕ HTTP
Ollama (host:11434)          — serves both models (sequential, one at a time)
```

### paperless-gpt (icereed/paperless-gpt) — Vision OCR (opt-in)

- Watches for `ocr-pending` tag. The tag is **applied manually by the user** (single doc or bulk-edit) when Tesseract OCR is insufficient — there is no longer an auto-workflow that applies it.
- When the tag is absent (the common case), paperless-gpt sits idle and does not load a model into GPU memory.
- Converts PDF pages → images → qwen2.5vl:7b → replaces document text.
- Removes `ocr-pending`, adds `classification-pending` tag (configured via `PDF_OCR_COMPLETE_TAG`) — this re-triggers `paperless-ai-next` to re-classify the doc from the improved text.
- Tagging mode disabled (`AUTO_TAG=""`) — classification is handled by paperless-ai-next.
- Config: `./paperless-gpt/.env`
- Debug: `docker compose logs paperless-gpt`, UI at `:8080`

### paperless-ai-next (admonstrator/paperless-ai-next) — AI Classification

- **Webhook-triggered**: Paperless Workflow fires `POST http://paperless-ai-next:3000/api/webhook/document` when `classification-pending` tag is applied
- Fallback: cron polling every 5 min (`SCAN_INTERVAL=*/5 * * * *`) catches missed webhooks
- **CRITICAL: Setup wizard required** once at `http://localhost:3000/setup`
- Config: `./paperless-ai-next/.env` (SYSTEM_PROMPT, PROMPT_TAGS, OLLAMA_MODEL)
- Debug: `/health`, `/debug/tags`, `/debug/documents`, HTML logs at `/app/data/logs.html`

### Required Paperless-ngx Workflows (managed via `scripts/paperless-config.yaml`)

Do not edit workflows in the UI — edit the YAML and run `/paperless-update` to push.

**Workflow 1 — Auto AI Classification** (default path)
- Trigger: Document Added
- Action: Assign tag → `classification-pending`
- Effect: every new doc goes straight to Tesseract + paperless-ai-next.

**Workflow 2 — Re-run pipeline on manual vision request** (opt-in safety)
- Trigger: Document Updated
- Condition: has tag `ocr-pending`
- Action: Remove tag `processed`
- Effect: a user applying `ocr-pending` to a previously-finished doc guarantees re-classification once vision OCR completes.

**Workflow 3 — AI Classification after OCR** (fires on both default path and opt-in path)
- Trigger: Document Updated
- Condition: has tag `classification-pending`
- Action: Webhook POST → `http://paperless-ai-next:3000/api/webhook/document`
- Header: `x-api-key: <PAPERLESS_AI_NEXT_API_KEY>`
- Body: `{"doc_url": "{{ doc_url }}"}`

**Workflow 4 — Remove classification-pending after processing** (cleanup)
- Trigger: Document Updated
- Condition: has tag `processed`
- Action: Remove tag `classification-pending`

### Key Config Interactions

| Setting | What it does |
|---|---|
| `USE_PROMPT_TAGS=yes` | AI can only assign tags from `PROMPT_TAGS` list |
| `PROMPT_TAGS=...` | Comma-separated whitelist (in `paperless-ai-next/.env`, excludes workflow tags) |
| `RESTRICT_TO_EXISTING_TAGS=yes` | Backup: drops any tag not already in Paperless-ngx |
| `ADD_AI_PROCESSED_TAG=yes` | Adds `processed` marker tag after processing |
| `PROCESS_PREDEFINED_DOCUMENTS=yes` + `TAGS=classification-pending` | Only process docs with the trigger tag |
| `PDF_OCR_COMPLETE_TAG=classification-pending` | paperless-gpt adds this tag after OCR — triggers Stage 3 |

### Common AI Tagging Failures

1. **Setup wizard never completed** → paperless-ai-next sits idle. Check: `curl localhost:3000/health`
2. **Ollama not reachable** → tagging silently fails. Check: `docker compose exec paperless-ai-next curl http://ollama:11434/api/tags`
3. **Workflow 2 not configured** → webhook never fires, fallback cron is the only path (5 min delay)
4. **Model swap latency** → ~10-20s between Stage 2 and 3 is expected (`OLLAMA_MAX_LOADED_MODELS=1`)
5. **API token placeholder** → paperless-ai-next can't authenticate. Check: `docker compose exec paperless-ai-next cat /app/data/.env | grep TOKEN`
6. **Poor OCR = poor tagging** → run `./scripts/pipeline-timing.sh` to see if Stage 2 is completing

### Diagnostic One-Liners (WSL host)

```bash
# Is Ollama running?
curl -s http://localhost:11434/api/tags | head -1

# Can paperless-gpt reach Ollama?
docker compose exec paperless-gpt curl -s http://ollama:11434/api/tags

# Can paperless-ai-next reach Paperless?
docker compose exec paperless-ai-next curl -s http://paperless:8000/api/tags/ \
  -H "Authorization: Token $(grep PAPERLESS_API_TOKEN .env | cut -d= -f2)"

# What models are loaded right now?
curl -s http://localhost:11434/api/ps

# paperless-ai-next health + tags
curl -s http://localhost:3000/health
curl -s http://localhost:3000/debug/tags

# Test qwen3:14b directly
curl -s http://localhost:11434/api/generate \
  -d '{"model":"qwen3:14b","prompt":"Classify: Invoice from Deutsche Telekom March 2026","stream":false}' | head -5

# Full pipeline diagnosis
./scripts/diagnose.sh
```

## Taxonomy (managed by /paperless-update — last updated 2026-04-19)

<!-- [paperless-update:tags:begin] -->
### Tags

**Hierarchy:**
- **Finance** → Tax, Insurance, Banking
- **Housing** → Rent, Utilities
- **Health** → Medical, Dental, health-xnc *(AI: child medical docs)*, health-ms, health-po, logo *(Logopädie/speech therapy)*
- **Car** → Car Insurance, Service
- **Work** → Payslip, Employment

**Standalone:** Bank, School, Munster, Hoflein, Heinl
- **Altenberg** — matches literal "St. Andra-Wörden"

**Patient tags (XNC medical):** X *(Xander)*, C *(Cassian)*, N *(Nathaniel)*

**Pipeline (not AI-assignable):** ocr-pending, classification-pending, processed
<!-- [paperless-update:tags:end] -->

<!-- [paperless-update:document_types:begin] -->
### Document Types & Custom Fields

| Type | Custom Fields |
|------|---------------|
| Invoice | Amount, Paid, PaidOn, PaidBy, PaidWith, InvoiceNr |
| Contract | — |
| Receipt | Amount, Paid, PaidOn, PaidBy, PaidWith |
| Certificate | — |
| Statement | — |
| Letter | — |
| Manual | — |
| Payslip | — |
| XNC medical | Amount, Paid, PaidOn, PaidBy, PaidWith, InvoiceNr, Treatment date, Submitted OEGKK, Submitted Allianz, Reimbursed OEGKK, Reimbursed Allianz, Reimbursed amount OEGKK, Reimbursed amount Allianz, Rejected OEGKK, Rejected Allianz, Rejection reason OEGKK, Rejection reason Allianz, Related documents |
| Anonymverfügung | — |
| Legal Document | — |
| List of Standards | — |
| Order confirmation | — |
| Weather Data | — |
<!-- [paperless-update:document_types:end] -->

<!-- [paperless-update:custom_fields:begin] -->
### Custom Fields

| Field | Type |
|-------|------|
| Status | select: Inbox / Action needed / Waiting / Done |
| Amount | monetary |
| Paid | boolean |
| PaidOn | date |
| PaidBy | select: Marcus / Sabrina / Sofiia |
| PaidWith | string |
| InvoiceNr | string |
| Treatment date | date |
| Submitted OEGKK | date |
| Submitted Allianz | date |
| Reimbursed OEGKK | date |
| Reimbursed Allianz | date |
| Reimbursed amount OEGKK | monetary |
| Reimbursed amount Allianz | monetary |
| Rejected OEGKK | boolean |
| Rejected Allianz | boolean |
| Rejection reason OEGKK | longtext |
| Rejection reason Allianz | longtext |
| Related documents | documentlink |
<!-- [paperless-update:custom_fields:end] -->

<!-- [paperless-update:workflows:begin] -->
### Workflows

1. **Auto Vision OCR** — on document_added → assign tag `ocr-pending`
2. **Remove classification-pending after processing** — on document_updated with tag `processed` → remove tag `classification-pending`
3. **AI Classification after OCR** — on document_updated with tag `classification-pending` → webhook to paperless-ai-next
4. **[auto] Attach fields: Invoice** — on document_updated with doc type Invoice → assign Amount, Paid, PaidOn, PaidBy, PaidWith, InvoiceNr
5. **[auto] Attach fields: Receipt** — on document_updated with doc type Receipt → assign Amount, Paid, PaidOn, PaidBy, PaidWith
6. **[auto] Attach fields: XNC medical** — on document_updated with doc type XNC medical → assign Amount, Paid, PaidOn, PaidBy, PaidWith, InvoiceNr, Treatment date, Submitted OEGKK, Submitted Allianz, Reimbursed OEGKK, Reimbursed Allianz, Reimbursed amount OEGKK, Reimbursed amount Allianz, Rejected OEGKK, Rejected Allianz, Rejection reason OEGKK, Rejection reason Allianz, Related documents
<!-- [paperless-update:workflows:end] -->

<!-- [paperless-update:saved_views:begin] -->
### Saved Views

| View | Filter | Sort |
|------|--------|------|
| Inbox | Status = Inbox | newest first |
| Action needed | Status = Action needed | oldest first |
| Waiting | Status = Waiting | oldest first |
| XNC Medical: Incoming | doc type = XNC medical + Status = Inbox | newest first |
| XNC Medical: Submitted | doc type = XNC medical + submitted to at least one insurer AND NOT both insurers terminal | oldest first |
| XNC Medical: Reimbursed | doc type = XNC medical + Status = Done | oldest first |
| XNC Reimbursed/Complete | doc type = XNC medical + BOTH insurers terminal: `(ReimbursedAmtOEGKK > 0 OR RejectedOEGKK) AND (ReimbursedAmtAllianz > 0 OR RejectedAllianz)` | newest first |
<!-- [paperless-update:saved_views:end] -->

## Data Migration (old stack → compose)

See `tasks/prd-docker-compose-migration.md` Section 4.8 for the full migration guide.

**Short version:**
1. Export from running old stack: `docker exec paperless document_exporter /usr/src/paperless/export`
2. Copy export: `docker cp paperless:/usr/src/paperless/export/. ~/paperless-migration/`
3. Archive old scripts: already done (see `scripts-archive/`)
4. Stand up new stack: `docker compose up -d`
5. Import: `docker compose cp ~/paperless-migration/. paperless:/usr/src/paperless/import/`
6. `docker compose exec paperless document_importer /usr/src/paperless/import`
7. Seed taxonomy (if fresh): `./scripts/bootstrap.sh`
8. Complete setup wizard: `http://localhost:3000/setup`
9. Pull models via Open WebUI: `http://localhost:3001`
10. Run: `./scripts/diagnose.sh`

## Tasks & Planning

- `tasks/` — active PRDs and feature specs. Current: `prd-docker-compose-migration.md`
- `tasks/done/` — completed PRDs (archived)
- Write a PRD for any non-trivial feature before implementing

## Important Patterns

- `scripts/bootstrap.sh` is idempotent — HTTP 400 on duplicates = already exists, not an error
- All bind-mount data dirs are gitignored; `.env` files in service subdirs are NOT gitignored (no secrets)
- Consumer polling (`CONSUMER_POLLING=10`) is required — inotify doesn't work across WSL2/Windows bridge
- Ollama runs as a Docker service (`ollama` in compose.yaml) — do not start a host Ollama process on port 11434 or it will conflict
- `docker compose exec` (not `docker exec`) — compose resolves service names to containers

## Environment: Dev Container

This project runs inside a **VS Code dev container**.
- **Docker-in-Docker IS available.** The daemon on the WSL host is reachable from inside the container — `docker`, `docker compose`, `docker compose exec ...` all work and operate on the real host-side stack. Use them directly; do not hand docker commands off to the user unless the command is destructive or long-running enough to warrant confirmation.
- **Paperless API from inside the container:** use `http://172.17.0.1:8000` (Docker bridge gateway). `localhost` does NOT reach Paperless from inside the devcontainer — port forwarding only works for the user's browser.
- **Port forwarding** — Devcontainer forwards ports for the user's browser; Paperless runs on 8000, Dozzle on 9999.
- **Persistent state** — `.claude/` is symlinked to `/agentic-central` mount (survives rebuilds).

### Claude Code Configuration Strategy

**Project Settings** (`.claude/settings.json`): Git-tracked, shared config.
**User Settings** (`/agentic-central/claude.json` → `~/.claude.json`): Copied on container start via `postStartCommand`. Edit source at `/agentic-central/claude.json`.

## ⚠️ CRITICAL: No Package Installation in Dev Container

**NEVER install dependencies** with `pnpm add`, `npm install`, `pip install`, etc. Tell the user which packages are needed and where to add them. Wait for container rebuild.

## Who I Am

Experienced full stack engineer and former CTO. Familiar with Python; TypeScript/JS/Go are secondary. Know AWS (EC2, IAM, Lambda), Docker deeply, Mongo, and basic relational DB.

## Interaction Style

- **Use AskUserQuestion liberally** — for clarifications, design choices, preferences. Never dump plain-text numbered lists of questions.
- Explain reasoning during/after implementation. Teach concepts as you code.
- After major features, write an inline summary.

## Workflow Preferences

- **NEVER start the dev server** or any long-running processes unless explicitly asked.
- After implementation, summarize what was built and suggest next steps.
- **Never add `Co-Authored-By: Claude` to commit messages.**

## Code Quality

- Be brutally explicit. Never assume defaults, always expect inputs.
- Clean, readable code with meaningful names.
- Comments only where the WHY isn't obvious.
- Handle errors explicitly, never silently swallow.
- Prefer simple over clever. Include types/interfaces where supported.

## When Planning

- Break complex tasks into steps fitting one context window.
- Write a PRD for large features.
- Identify risks and dependencies upfront.
- **ALWAYS use AskUserQuestion** for clarifying questions — never plain-text numbered lists.

## Teaching Mode

After completing any task, include a brief "Learn" section (2-4 sentences max) teaching something relevant. Topics: language concepts, engineering principles, framework insights, tradeoffs, doc pointers. Tailor to a fullstack CTO. Keep practical, rotate topics.
