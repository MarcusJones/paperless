# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker-based Paperless-ngx document management system with AI tagging, running locally in WSL2. The repo is a collection of Bash scripts that orchestrate 7 Docker containers + Ollama for a document ingestion → OCR → AI classification pipeline.

## Tech Stack

- **Core:** Paperless-ngx (document storage, Tesseract OCR, web UI)
- **AI Tagging:** paperless-ai (clusterzx/paperless-ai) → polls documents, sends to Ollama llama3.1 for title/tags/correspondent/type
- **Vision OCR:** paperless-gpt (icereed/paperless-gpt) → re-OCRs scanned docs using minicpm-v:8b vision model
- **LLM Host:** Ollama running on WSL host (not in Docker), bound to `0.0.0.0:11434`
- **Database:** PostgreSQL 16 + Redis 7 (task queue)
- **Doc Processing:** Apache Tika (office extraction) + Gotenberg (PDF rendering)
- **Language:** Bash (all scripts), no application code in this repo

## Architecture

### Document Pipeline (3 stages)

**⚠️ Pipeline chaining is not yet fully implemented.** See `tasks/prd-ai-tagging-pipeline.md` for the active PRD. Current status: each stage runs independently; the tag-driven handoff between paperless-gpt and paperless-ai is in-progress.

1. **Paperless-ngx** (:8000) — ingests files from Dropbox consume folder, runs Tesseract OCR, stores in Postgres
2. **paperless-gpt** (:8080) — if document has `paperless-gpt-ocr-auto` tag, re-OCRs with vision LLM (minicpm-v:8b). ~1-2 min/page on CPU
3. **paperless-ai** (:3000) — polls every 5 min, sends text to llama3.1 via Ollama, assigns title/tags/correspondent/document type

### Container Start Order (defined in `config.sh:CONTAINERS`)

`paperless-redis` → `paperless-db` → `paperless-tika` → `paperless-gotenberg` → `paperless` → `paperless-ai` → `paperless-gpt`

Stop order is reversed (consumers before dependencies).

### Networking

Containers talk to each other via Docker network `paperless`. Containers reach Ollama on the WSL host via `172.17.0.1:11434` (Docker bridge gateway), NOT localhost. Ollama must bind `0.0.0.0`.

### Configuration Split

- **`config.sh`** — all non-secret config (ports, paths, models, container list, tag taxonomy). Every script sources this.
- **`.env`** — secrets only: `PAPERLESS_API_TOKEN`, `DROPBOX_USER`, `SECRET_KEY`, `PG_PASSWORD`. Never committed.
- **`bootstrap.sh`** — creates taxonomy via Paperless REST API (tags, document types, Status custom field, storage path). Idempotent.

### Key Paths

- Consume dir: `/mnt/c/Users/$DROPBOX_USER/Dropbox/paperless-consume` (WSL2 bridge to Windows Dropbox)
- Export dir: `~/paperless-ngx/export`
- AI config: `~/paperless-ai-data/.env` (written by `setup.sh`, preserves wizard-added keys)
- Docker volumes: `paperless-pgdata`, `paperless-data`, `paperless-media`

## Scripts Reference

| Script         | Purpose                                                        |
| -------------- | -------------------------------------------------------------- |
| `setup.sh`     | First-time: starts Ollama, pulls models, creates all containers |
| `start.sh`     | Daily: starts Ollama + all containers                          |
| `stop.sh`      | Daily: stops containers (reverse order) + kills Ollama         |
| `remove.sh`    | DESTRUCTIVE: removes containers, network, volumes (prompts)    |
| `bootstrap.sh` | Creates taxonomy via API (tags, types, Status field, paths)    |
| `status.sh`    | Health check: Ollama PID, container states, service URLs       |
| `backup.sh`    | Exports docs + copies to Dropbox (timestamped)                 |
| `logs.sh`      | Tails all container logs with color-coded prefixes             |
| `diagnose.sh`  | Pipeline diagnostics: 10-check pass/fail for all prerequisites |
| `config.sh`    | Sourced by all scripts — central config, not run directly      |

## AI Tagging Pipeline — Integration Guide

### How the Three AI Components Connect

```
Paperless-ngx (:8000)        — REST API, stores documents + metadata
       ↕ API (Token auth)
paperless-gpt (:8080)        — polls by tag, does vision OCR via Ollama minicpm-v
       ↕ (no direct link — both talk to Paperless API independently)
paperless-ai  (:3000)        — polls on cron, does classification via Ollama llama3.1
       ↕ HTTP
Ollama (host:11434)          — serves both models, runs on WSL host (not in Docker)
```

### paperless-gpt (icereed/paperless-gpt) — Vision OCR

- **Tag-driven workflow**: watches for documents with `paperless-gpt-ocr-auto` tag
- Converts PDF pages to images → sends to minicpm-v:8b vision model → replaces document text
- **Removes the trigger tag** after processing (no infinite loops)
- Tagging mode disabled in current config (`AUTO_TAG=""`, `MANUAL_TAG=""`)
- Reaches Ollama via `http://host.docker.internal:11434`
- Debug: `LOG_LEVEL=debug`, web UI at `:8080`, `docker logs paperless-gpt`

### paperless-ai (clusterzx/paperless-ai) — AI Classification

- **Cron-driven**: polls every 5 min (`SCAN_INTERVAL=*/5 * * * *`), no tag trigger needed
- Sends document text to llama3.1 → gets back title, tags, correspondent, document type
- Applies results via Paperless API PATCH
- **CRITICAL: Requires setup wizard** at `http://localhost:3000/setup` to be completed once. The app validates API/Ollama connectivity and writes internal state. Setting env vars alone may not work (upstream issue #358).
- Config lifecycle: `setup.sh` writes managed keys → wizard adds its own keys → subsequent `setup.sh` runs preserve wizard keys
- Debug endpoints: `/health`, `/debug/tags`, `/debug/documents`, `/debug/correspondents`, `/api-docs`
- Dashboard: `http://localhost:3000/dashboard`
- Logs: `docker logs paperless-ai` or HTML logs inside container at `/app/data/logs.html`

### Key Config Interactions

| Setting | What it does |
|---|---|
| `USE_PROMPT_TAGS=yes` | AI can only assign tags from `PROMPT_TAGS` list |
| `PROMPT_TAGS=...` | Comma-separated whitelist (defined in `config.sh`, excludes workflow tags) |
| `RESTRICT_TO_EXISTING_TAGS=yes` | Backup: drops any tag not already in Paperless-ngx |
| `ADD_AI_PROCESSED_TAG=yes` | Adds `ai-processed` marker tag after processing |
| `PROCESS_PREDEFINED_DOCUMENTS=yes` + `TAGS=ai-process` | Only process documents with the `ai-process` trigger tag (target state). `=no` would process ALL documents — avoid, leads to over-tagging. |

### Common AI Tagging Failures

1. **Setup wizard never completed** → paperless-ai sits idle. Check: `curl localhost:3000/health`
2. **Ollama not reachable from container** → tagging silently fails (no retry). Check: `docker exec paperless-ai curl -s http://172.17.0.1:11434/api/tags`
3. **Old env var names** → `TAGS=true` may not work in v3.x, needs `ACTIVATE_TAGGING=yes`
4. **Model swapping thrash** → only one model loaded at a time by default. Fix: `OLLAMA_MAX_LOADED_MODELS=2` (needs ~12GB RAM)
5. **API token still placeholder** → paperless-ai can't authenticate. Check: `docker exec paperless-ai cat /app/data/.env | grep TOKEN`
6. **Poor OCR = poor tagging** → garbage Tesseract text means garbage AI output. Enable vision OCR via `paperless-gpt-ocr-auto` workflow tag

### Diagnostic One-Liners (run on WSL host)

```bash
# Is Ollama running and reachable?
curl -s http://localhost:11434/api/tags | head -1

# Can paperless-ai reach Ollama?
docker exec paperless-ai curl -s http://172.17.0.1:11434/api/tags

# Can paperless-ai reach Paperless-ngx?
docker exec paperless-ai curl -s http://paperless:8000/api/tags/ -H "Authorization: Token $(grep PAPERLESS_API_TOKEN .env | cut -d= -f2)"

# What models are currently loaded in Ollama?
curl -s http://localhost:11434/api/ps

# Is paperless-ai healthy?
curl -s http://localhost:3000/health

# What tags does paperless-ai see?
curl -s http://localhost:3000/debug/tags

# Test Ollama classification directly
curl -s http://localhost:11434/api/generate -d '{"model":"llama3.1","prompt":"Classify this document: Invoice from Deutsche Telekom for March 2026","stream":false}' | head -5
```

## Tasks & Planning

- `tasks/` — active PRDs and feature specs. Currently: `prd-ai-tagging-pipeline.md` (pipeline chaining fix, in-progress)
- `tasks/done/` — completed PRDs (archived for reference)
- Write a PRD here for any non-trivial feature before implementing

## Important Patterns

- All scripts use `set -euo pipefail` and source `config.sh` for shared state
- `setup.sh` uses `create_if_absent()` — safe to re-run, skips existing containers
- `bootstrap.sh` is idempotent — existing API items return 400 (treated as success)
- `setup.sh` merges paperless-ai config: overwrites managed keys, preserves wizard-added keys
- Ollama systemd service must be disabled — scripts manage Ollama directly to avoid dual-instance model directory conflicts
- Consumer polling (`CONSUMER_POLLING=10`) is required because inotify doesn't work across the WSL2/Windows bridge

## Environment: Dev Container

This project runs inside a **VS Code dev container**.
- **⚠️ NO DOCKER IN DEV CONTAINER** — Docker daemon is NOT available. Never run `docker` commands, `./setup.sh`, `./start.sh`, etc. from inside the container. The user runs these on the WSL host.
- **Port forwarding** — Devcontainer forwards port 8080 to host; Paperless runs on 8000.
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
