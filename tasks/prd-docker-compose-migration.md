# PRD: Docker Compose Migration & Pipeline Redesign

**Status:** Draft
**Created:** 2026-04-04
**Supersedes:** `prd-ai-tagging-pipeline.md` (pipeline handoff sections)

---

## 1. Introduction / Overview

The current Paperless-ngx stack is orchestrated by hand-written Bash scripts (`setup.sh`, `start.sh`, `stop.sh`, etc.) that call `docker run` / `docker start` / `docker stop` individually. This works but is fragile, hard to update, and doesn't leverage Docker Compose's declarative dependency management, health checks, or single-command lifecycle.

This PRD covers two things:
1. **Compose migration** — replace all container orchestration scripts with a single `compose.yaml` and a folder-per-service layout.
2. **Pipeline redesign** — define the complete document workflow (ingest → vision OCR → AI classification) with clear, working tag-driven handoff between stages.

Key changes from current state:
- **New services:** Dozzle (log viewer), Open WebUI (Ollama management)
- **Upgraded AI:** paperless-ai-next (fork with failure handling) replaces paperless-ai
- **Upgraded models:** qwen3:14b (classification) + qwen3-vl:8b (vision OCR) replace llama3.1 + minicpm-v:8b
- **Taxonomy seeding** via `document_exporter --data-only` / `document_importer --data-only` (official mechanism) or kept as API script
- **Data migration** via official `document_exporter` / `document_importer` (not raw volume copies)
- **Old scripts archived** to `scripts-archive/`

## 2. Goals

| # | Goal | Measurable |
|---|------|-----------|
| G1 | Single `docker compose up -d` starts entire stack (minus Ollama on host) | All 9 services healthy within 120s |
| G2 | Folder-per-service layout with clear config separation | Each service has `<name>/` dir with its own non-secret `.env` |
| G3 | Complete document pipeline with working tag handoff | A document dropped in consume folder gets OCR'd and classified without manual intervention |
| G4 | Zero Bash scripts required for daily operation | `docker compose up/down/logs` replaces start/stop/logs scripts |
| G5 | Model upgrade to qwen3 family | qwen3:14b for classification, qwen3-vl:8b for vision OCR |
| G6 | Reproducible taxonomy seeding | Tags, document types, custom fields importable on fresh install via official exporter/importer or bootstrap script |

## 3. User Stories

- **As the operator**, I want to run `docker compose up -d` and have the full stack (Paperless + AI + monitoring) come up in the right order, so I don't need to remember script names or start order.
- **As the operator**, I want each service's config in its own folder, so I can edit one service without reading a monolithic config.sh.
- **As the operator**, I want a document dropped into the consume folder to be automatically OCR'd (vision model) and classified (tags, title, correspondent, type), so the pipeline works end-to-end without manual tagging.
- **As the operator**, I want to see all container logs in a web UI (Dozzle), so I don't need SSH access or terminal tailing.
- **As the operator**, I want to manage Ollama models through a web UI (Open WebUI), so I can pull/delete models without CLI commands.
- **As the operator**, I want taxonomy (tags, document types, custom fields) created automatically on first boot, so I don't need to run a separate bootstrap command.

## 4. Functional Requirements

### 4.1 — Repository Layout

```
paperless/
├── compose.yaml                  # All services defined here
├── .env                          # Secrets only (gitignored): API token, DB password, secret key, Dropbox user
├── .env.example                  # Template with placeholder values (committed)
│
├── paperless/                    # Paperless-ngx core
│   ├── .env                      # Non-secret config: OCR settings, ports, locale, consumer polling
│   ├── consume/                  # Bind mount: Dropbox consume folder (symlink to /mnt/c/...)
│   ├── data/                     # Bind mount: application data
│   ├── media/                    # Bind mount: document storage
│   └── export/                   # Bind mount: document exports
│
├── postgres/
│   ├── .env                      # Non-secret config: DB name, user (password from root .env)
│   └── data/                     # Bind mount: PG data directory
│
├── redis/
│   └── data/                     # Bind mount: Redis persistence
│
├── gotenberg/
│   └── .env                      # Non-secret config (if any tuning needed)
│
├── tika/                         # (empty dir, no config needed — just needs to exist for pattern)
│
├── paperless-ai-next/
│   ├── .env                      # Non-secret config: scan interval, prompt tags, model settings
│   └── data/                     # Bind mount: persistent state + logs
│
├── paperless-gpt/
│   ├── .env                      # Non-secret config: OCR tags, model, token limit
│   └── prompts/                  # Custom prompt templates (bind-mounted)
│
├── open-webui/
│   └── data/                     # Bind mount: Open WebUI state
│
├── dozzle/                       # (no persistent state needed)
│
├── scripts-archive/              # Old scripts, kept for reference
│   ├── setup.sh
│   ├── start.sh
│   ├── stop.sh
│   ├── remove.sh
│   ├── logs.sh
│   ├── status.sh
│   ├── backup.sh
│   ├── bootstrap.sh
│   └── config.sh
│
├── scripts/                      # Operational scripts that survive the migration
│   ├── bootstrap.sh              # Taxonomy seeding via REST API (idempotent, for fresh installs)
│   ├── diagnose.sh               # Pipeline health checks (updated for compose)
│   ├── backup.sh                 # Export + Dropbox copy (updated for compose)
│   └── pipeline-timing.sh        # Per-document timing across all 3 pipeline stages (see FR-7.2)
│
├── tasks/                        # PRDs (unchanged)
└── CLAUDE.md                     # Updated for compose workflow
```

**FR-1.1:** Every service in `compose.yaml` MUST have a corresponding folder at the repo root, even if empty.

**FR-1.2:** All bind mount paths MUST use relative paths from the repo root (e.g., `./postgres/data`) — not Docker named volumes and not absolute paths. This makes data visible, inspectable, and trivially backupable.

**FR-1.3:** The `data/` directories MUST be gitignored. The `.env` files in service folders are NOT gitignored (they contain only non-secret config). Only the root `.env` is gitignored.

### 4.2 — compose.yaml Services

9 services total. Ollama runs on the WSL host, NOT in compose.

| Service | Image | Exposed Port | Depends On |
|---------|-------|-------------|------------|
| `redis` | `redis:7` | — | — |
| `postgres` | `postgres:16` | — | — |
| `tika` | `apache/tika:latest` | — | — |
| `gotenberg` | `gotenberg/gotenberg:8` | — | — |
| `paperless` | `ghcr.io/paperless-ngx/paperless-ngx:2` | 8000 | redis, postgres, tika, gotenberg |
| `paperless-ai-next` | `admonstrator/paperless-ai-next:latest` | 3000 | paperless |
| `paperless-gpt` | `icereed/paperless-gpt:latest` | 8080 | paperless |
| `open-webui` | `ghcr.io/open-webui/open-webui:main` | 3001 | — |
| `dozzle` | `amir20/dozzle:latest` | 9999 | — |

**FR-2.1:** All services MUST use `restart: unless-stopped`.

**FR-2.2:** `paperless` service MUST include a `healthcheck` (curl to `/api/tags/` with the API token, or a simpler liveness check). `paperless-ai-next` and `paperless-gpt` MUST use `depends_on: paperless: condition: service_healthy` so they don't start before the API is ready.

**FR-2.3:** Services that need to reach Ollama on the WSL host MUST use `extra_hosts: ["host.docker.internal:host-gateway"]` and connect to `http://host.docker.internal:11434`. This replaces the hardcoded `172.17.0.1` bridge IP.

**FR-2.4:** All services MUST be on a single compose-managed network (the default). No explicit network definition needed — compose creates one automatically.

**FR-2.5:** Dozzle MUST mount the Docker socket read-only: `/var/run/docker.sock:/var/run/docker.sock:ro`.

**FR-2.6:** Open WebUI MUST be configured to connect to Ollama at `http://host.docker.internal:11434` (not localhost).

**FR-2.7:** Pin major versions where stability matters (postgres:16, redis:7, gotenberg:8). Use floating tags for actively-developed services (paperless-ngx:2, paperless-gpt:latest, paperless-ai-next:latest).

### 4.3 — Secrets & Configuration

**FR-3.1:** Root `.env` contains ONLY secrets:
```
PAPERLESS_API_TOKEN=<token>
PG_PASSWORD=<password>
SECRET_KEY=<django-secret>
DROPBOX_USER=<windows-username>
PAPERLESS_AI_NEXT_API_KEY=<key>   # Used for webhook auth (x-api-key header)
```

**FR-3.2:** Each service's `<service>/.env` contains non-secret config. Secrets are injected via compose variable interpolation from the root `.env`. Example for `postgres/.env`:
```
POSTGRES_DB=paperless
POSTGRES_USER=paperless
# POSTGRES_PASSWORD comes from root .env via compose.yaml interpolation
```

**FR-3.3:** `compose.yaml` uses `env_file:` to load per-service config AND uses `environment:` to inject secrets from root `.env` interpolation. Example:
```yaml
postgres:
  image: postgres:16
  env_file: ./postgres/.env
  environment:
    POSTGRES_PASSWORD: ${PG_PASSWORD}
```

**FR-3.4:** A `.env.example` at the root MUST document all required secrets with placeholder values.

### 4.4 — Taxonomy Seeding & Data Migration

Paperless-ngx provides official management commands for this: `document_exporter` and `document_importer`. These handle the full database state (tags, document types, correspondents, custom fields, storage paths, workflows, saved views, users, etc.).

#### Initial migration (current instance → compose)

**FR-4.1:** Before tearing down the current stack, export everything using the official exporter:
```bash
# Export database + documents from current running instance
docker exec paperless document_exporter /usr/src/paperless/export
docker cp paperless:/usr/src/paperless/export/. ./migration-export/
```

**FR-4.2:** After the new compose stack is up (fresh DB, migrations applied), import:
```bash
docker compose exec paperless document_importer /path/to/migration-export
```
This restores all documents, metadata, tags, types, custom fields, users — everything. The importer calls Django `loaddata` internally and copies document files.

**FR-4.3:** For a `--data-only` migration (taxonomy + metadata without re-copying document files), use:
```bash
docker exec paperless document_exporter /usr/src/paperless/export --data-only
# ... then on new instance:
docker compose exec paperless document_importer /path/to/export --data-only
```
This is useful if the document files are already in the right bind mount location.

#### Fresh install seeding (no existing instance)

**FR-4.4:** For fresh installs (no data to migrate), keep `bootstrap.sh` as `scripts/bootstrap.sh`. The REST API approach is the most robust for seeding taxonomy because:
- It works across paperless-ngx versions (no fixture format changes)
- It's idempotent (HTTP 400 on duplicates = already exists)
- It doesn't require Django model knowledge or PK management
- It runs against the live API, so it validates connectivity

**FR-4.5:** `scripts/bootstrap.sh` MUST be updated to use `docker compose exec` instead of `docker exec`. The taxonomy definition (tags, types, custom fields) moves from `config.sh` variables into the bootstrap script itself or a `taxonomy.json` reference file.

**FR-4.6:** The full list of seeded items (currently in `bootstrap.sh`):
- All content tags (Finance, Tax, Insurance, etc.)
- All workflow tags (paperless-gpt-ocr-auto, ocr-complete, ai-process, ai-processed)
- All document types (Invoice, Contract, Letter, etc.)
- The "Status" custom field
- Storage path configuration

### 4.5 — Document Workflow (Pipeline Redesign)

Three stages. **Event-driven where possible, fast polling where not.**

```
┌─────────────┐  tag   ┌──────────────────┐  webhook  ┌───────────────────┐
│  Stage 1    │───────▶│   Stage 2        │──────────▶│   Stage 3         │
│  INGEST     │        │   VISION OCR     │           │   AI CLASSIFY     │
│  paperless  │        │   paperless-gpt  │           │  paperless-ai-next│
└─────────────┘        └──────────────────┘           └───────────────────┘
     Tesseract              qwen3-vl:8b                    qwen3:14b
     auto on ingest         fast continuous poll           webhook-triggered
                            (picks up in seconds)          (zero delay)
```

#### Trigger mechanisms (polling vs. event-driven)

| Stage | Trigger type | Mechanism | Latency |
|-------|-------------|-----------|---------|
| 1 → 2 | Tag + fast poll | Paperless-ngx adds `paperless-gpt-ocr-auto` tag. paperless-gpt already polls continuously with optimized short-circuit — picks up tagged docs in **seconds**. | ~1-5s |
| 2 → 3 | **Webhook (event-driven)** | When OCR completes, paperless-gpt adds the `ai-process` tag. A **Paperless-ngx Workflow** (v2.14+) fires a webhook on tag change → `POST http://paperless-ai-next:3000/api/webhook/document`. **Zero polling delay.** | <1s |

**Why the hybrid approach:** paperless-gpt has no webhook endpoint — it only polls. But its polling is already optimized (tag-based document counting, short-circuit when nothing to process, continuous background loop). Adding a webhook would require forking the project. paperless-ai-next, on the other hand, **has a native webhook endpoint** at `/api/webhook/document` — so we use it.

**Stage 1 — Ingest (Paperless-ngx)**
- Documents land in `consume/` folder (from Dropbox)
- Paperless-ngx ingests, runs Tesseract OCR (first pass), stores in Postgres
- **Paperless-ngx Workflow** auto-applies the `paperless-gpt-ocr-auto` tag to newly ingested documents (trigger: "Document Added", action: "Assign Tag")
- This tag triggers Stage 2

**Stage 2 — Vision OCR (paperless-gpt)**
- paperless-gpt's continuous background poller detects the `paperless-gpt-ocr-auto` tag within seconds
- Converts PDF pages to images → sends to qwen3-vl:8b → replaces document text with high-quality OCR
- On completion: removes `paperless-gpt-ocr-auto` tag, adds `ai-process` tag
- Ollama swaps models (~10-20s): unloads qwen3-vl:8b, loads qwen3:14b
- The `ai-process` tag addition triggers a Paperless-ngx Workflow webhook → Stage 3

**Stage 3 — AI Classification (paperless-ai-next)**
- **Webhook-triggered:** Paperless-ngx Workflow fires `POST http://paperless-ai-next:3000/api/webhook/document` with `x-api-key` header when the `ai-process` tag is applied
- paperless-ai-next processes the document immediately — sends text to qwen3:14b → gets back title, tags, correspondent, document type
- Applies results via Paperless API
- On completion: removes `ai-process` tag, adds `ai-processed` tag
- **Fallback:** Keep cron polling enabled at a low frequency (e.g., every 5 min) as a safety net to catch any webhook failures. Disable with `DISABLE_AUTOMATIC_PROCESSING=yes` if webhooks prove reliable.

**FR-5.1:** The tag-driven handoff between Stage 2 and Stage 3 MUST use a Paperless-ngx Workflow with a webhook action. Configure:
- **Trigger:** Tag `ai-process` applied to document
- **Action:** Webhook POST to `http://paperless-ai-next:3000/api/webhook/document`
- **Headers:** `x-api-key: <paperless-ai-next API key>` (from service .env)
- **Body:** `{"doc_url": "{{ doc_url }}"}` (paperless-ngx webhook placeholder)
- Verify that paperless-gpt adds the `ai-process` tag on OCR completion (check `PDF_OCR_COMPLETE_TAG` or equivalent config)

**FR-5.2:** The trigger for Stage 2 (applying `paperless-gpt-ocr-auto` to new documents) MUST use a Paperless-ngx Workflow:
- **Trigger:** "Document Added"
- **Action:** "Assign Tag" → `paperless-gpt-ocr-auto`
- This is configured in the Paperless web UI or seeded via bootstrap. No post-consume script needed.

**FR-5.3:** Documents that already have clean digital text (no OCR needed) SHOULD still go through Stage 2 for consistency, OR have a bypass path that sends them directly to Stage 3. Define this clearly during implementation.

**FR-5.4:** Failed OCR or classification MUST NOT block the pipeline. paperless-ai-next's rescue queue feature handles classification failures. For OCR failures, define what happens (leave tag, retry, log and skip).

**FR-5.5:** The paperless-ai-next webhook endpoint MUST be secured with an API key (`x-api-key` header). This key is stored in the root `.env` and injected via compose interpolation into both the paperless-ai-next service config and the Paperless-ngx Workflow webhook header.

### 4.6 — Model Configuration

**FR-6.1:** Ollama runs on the WSL host (not in Docker). The compose stack expects Ollama to be running at `host.docker.internal:11434`.

**FR-6.2:** Target models:
| Purpose | Model | VRAM | Provider |
|---------|-------|------|----------|
| Classification | qwen3:14b | ~10GB | Ollama (host) |
| Vision OCR | qwen3-vl:8b | ~6GB | Ollama (host) |

**FR-6.3:** With 12GB VRAM, both models CANNOT be loaded simultaneously (10GB + 6GB = 16GB > 12GB). Set `OLLAMA_MAX_LOADED_MODELS=1` (the default). Ollama will swap models on demand — load the vision model for OCR, unload it, then load the classification model. This adds ~10-20s swap latency between pipeline stages, which is acceptable because documents flow through OCR *then* classification sequentially. Document the swap behavior and VRAM constraint in README/CLAUDE.md.

**FR-6.4:** Open WebUI connects to host Ollama and provides a UI for pulling/managing models. First-time setup: user pulls qwen3:14b and qwen3-vl:8b through the Open WebUI interface.

### 4.7 — Monitoring & Observability

#### Log viewing

The current `logs.sh` provides two critical capabilities that must be preserved:
1. **Multi-container interleaved view** — color-coded prefixes, all containers in one stream, easy visual scanning for cross-service issues (e.g., paperless-gpt fails OCR → paperless-ai-next never picks up the doc)
2. **AI pipeline timing** — inline duration annotations showing how long OCR and classification take per document, critical for optimizing model choice and hardware

**FR-7.1:** Dozzle at `:9999` provides a web UI for real-time log streaming. It MUST be configured to support:
- **Multi-container merged view** — Dozzle supports "swarm mode" / merged log streams where you can select multiple containers and see their logs interleaved in a single timeline. This is the primary viewing mode for pipeline debugging.
- **Container filtering** — ability to show only the AI pipeline containers (paperless, paperless-gpt, paperless-ai-next) in one view, or all 9.
- **Search/filter within logs** — regex or keyword search to find specific document IDs or error patterns across all containers.

**FR-7.2:** Dozzle does NOT natively compute per-document processing durations. A **`scripts/pipeline-timing.sh`** script (evolved from the awk logic in `logs.sh`) tails the AI containers via `docker compose logs -f`, parses start/end events, and prints per-document timing summaries. Covers all 3 stages:

  | Stage | Start event | End event | What to measure |
  |-------|-------------|-----------|-----------------|
  | Ingest | `[paperless]` consumer picks up file | `[paperless]` document created in DB | Ingest + Tesseract OCR time |
  | Vision OCR | `[paperless-gpt]` starts processing doc | `[paperless-gpt]` OCR complete, tag removed | Vision model inference time (per page and total) |
  | AI Classify | `[paperless-ai-next]` picks up doc | `[paperless-ai-next]` tags/title applied | LLM classification time |
  | **Model swap** | Vision OCR ends | Classification starts | Ollama model swap latency (~10-20s) |
  | **End-to-end** | File appears in consume | `ai-processed` tag applied | Total pipeline latency |

  Output example:
  ```
  [2026-04-04 14:23:01]  DOC #1842  Ingest: 12s  Vision OCR: 87s (3pg, 29s/pg)  Swap: 14s  Classify: 8s  TOTAL: 121s
  [2026-04-04 14:25:33]  DOC #1843  Ingest: 8s   Vision OCR: 142s (5pg, 28s/pg)  Swap: 12s  Classify: 11s  TOTAL: 173s
  ```

**FR-7.3:** The pipeline timing script MUST track these metrics per document:
- Time spent in each pipeline stage (ingest, vision OCR, classification)
- Per-page OCR duration (for vision OCR stage — helps decide model size vs. speed tradeoff)
- End-to-end latency (file drop to fully tagged)
- Failures (document entered a stage but never exited — stuck or errored)

**FR-7.4:** The timing script SHOULD support a `--summary` mode that shows aggregate stats:
```
Pipeline Summary (last 24h, 47 documents)
──────────────────────────────────────────
Stage 1 (ingest+OCR):   avg 10s   median 8s    max 45s
Stage 2 (vision OCR):   avg 62s   median 55s   max 210s  (avg 24s/page)
Stage 3 (classification): avg 9s  median 7s    max 28s
End-to-end:              avg 81s   median 70s   max 283s

Failures: 2 docs stuck in Stage 2 (IDs: #1847, #1851)
Model: qwen3-vl:8b (vision), qwen3:14b (classify)
```
This directly supports the goal of optimizing the workflow — if Stage 2 is the bottleneck, you know to try a smaller/faster vision model or add GPU resources.

#### Other observability

**FR-7.5:** Open WebUI at `:3001` provides Ollama model management and a chat interface for testing prompts against qwen3:14b directly (useful for tuning the system prompt).

**FR-7.6:** `scripts/diagnose.sh` is updated to work with compose (uses `docker compose exec` instead of `docker exec`, checks compose service health).

### 4.8 — Migration Path

**FR-8.1:** Archive all current scripts to `scripts-archive/` in a single commit before any compose work begins. This is a clean break, not a gradual migration.

**FR-8.2:** Data migration uses the official `document_exporter` / `document_importer` — NOT raw volume copies. This ensures referential integrity and handles all metadata.

**FR-8.3:** Migration steps (for CLAUDE.md / README):

```
Phase 1: Export from current stack (run on WSL host)
─────────────────────────────────────────────────────
1. Ensure current stack is running (./start.sh)
2. Export everything:
   docker exec paperless document_exporter /usr/src/paperless/export
   docker cp paperless:/usr/src/paperless/export/. ~/paperless-migration/
3. Verify export:
   ls ~/paperless-migration/manifest.json  # must exist
4. Stop current stack: ./stop.sh

Phase 2: Set up compose stack
─────────────────────────────
5. Archive scripts: git mv *.sh scripts-archive/
   (keep diagnose.sh, backup.sh → move to scripts/)
6. Create folder-per-service layout + compose.yaml
7. Create bind mount directories (paperless/data, paperless/media, postgres/data, etc.)
8. Configure .env files (root secrets + per-service config)

Phase 3: Import into new stack
──────────────────────────────
9.  docker compose up -d  (starts fresh DB, runs migrations)
10. Wait for paperless to be healthy:
    docker compose exec paperless python3 manage.py migrate --check
11. Copy export into container and import:
    docker compose cp ~/paperless-migration/. paperless:/usr/src/paperless/import/
    docker compose exec paperless document_importer /usr/src/paperless/import
12. Verify: open http://localhost:8000, confirm documents and tags are present

Phase 4: Configure AI services
──────────────────────────────
13. Complete paperless-ai-next setup wizard at http://localhost:3000/setup
14. Pull models via Open WebUI at http://localhost:3001
    - qwen3:14b (classification)
    - qwen3-vl:8b (vision OCR)
15. Run scripts/diagnose.sh to verify full pipeline connectivity
```

**FR-8.4:** After successful migration and verification, the old named volumes (`paperless-pgdata`, `paperless-data`, `paperless-media`) can be removed with `docker volume rm`. Do NOT remove until the new stack is verified working.

## 5. Non-Goals / Out of Scope

- **Ollama in Docker** — stays on WSL host. No GPU passthrough complexity.
- **Reverse proxy / HTTPS** — local-only stack, no Traefik/Caddy.
- **Watchtower / auto-updates** — manual updates only.
- **Custom Paperless-ngx container builds** — use official images, no PaddleOCR replacement.
- **Multi-user / auth** — single operator, no SSO/LDAP.
- **Cloud LLM fallback** — Ollama only, no OpenAI/Gemini integration.
- **Automated backup service** — backup strategy is an open question (see Section 9).
- **CI/CD** — no GitHub Actions, no automated testing of the compose stack.

## 6. Design Considerations

### Folder-per-service rationale
Each service gets its own directory because: (a) config is co-located with data, (b) you can `ls paperless-gpt/` to see everything about that service, (c) bind mounts make data inspectable without `docker volume inspect`. The tradeoff is more directories in the repo root, but this is a flat stack (9 services), not a monorepo.

### Bind mounts vs. named volumes
Named volumes (current approach) are opaque — data lives in `/var/lib/docker/volumes/` and requires `docker cp` or `docker run` tricks to inspect. Bind mounts put data in the repo tree where `ls`, `du`, and file-level backup tools work directly. The tradeoff is that bind mount permissions can be tricky (use `USERMAP_UID`/`USERMAP_GID` in paperless config).

### Why paperless-ai-next over paperless-ai
The fork adds: OCR rescue queue (retries failed docs with a different model), permanent-failure queue (stops retrying known-bad docs), processing history with one-click rescan, and better error handling. These directly address the "silently fails, no retry" problem in the current paperless-ai.

## 7. Technical Considerations

### Data migration via document_exporter/importer
The official `document_exporter` / `document_importer` commands are the safe migration path. The exporter produces a `manifest.json` + all document files. The importer calls Django `loaddata` internally and copies files.

**Risk:** The importer warns about version mismatches — you cannot reliably import data exported from a significantly different paperless-ngx version. Pin the compose image to the same major version as the current containers during migration, then upgrade afterward.

**Risk:** The importer deletes all ContentType and Permission objects before re-importing, then rebuilds the search index. This is safe on a fresh DB but destructive on a populated one. Only import into a freshly-migrated (empty) database.

### Bind mount permissions
Bind mounts require matching UID/GID between the container user and host filesystem. Set `USERMAP_UID` and `USERMAP_GID` in the paperless `.env` to match the WSL host user (typically 1000). If permissions are wrong, Paperless fails to write to `data/` or `media/`.

### Taxonomy seeding approach
The REST API approach (current `bootstrap.sh`) is the most robust for seeding on fresh installs. Django `loaddata` works but has PK collision risks and requires exact model path knowledge. The `document_exporter --data-only` / `document_importer --data-only` is ideal for cloning a configured instance but ties you to a specific paperless-ngx version.

### Ollama host connectivity
`extra_hosts: ["host.docker.internal:host-gateway"]` is the modern Docker way to reach the host. This replaces the hardcoded `172.17.0.1` which can change. All services needing Ollama use `http://host.docker.internal:11434`.

### paperless-ai-next compatibility
This is a fork of paperless-ai. Verify:
- Docker image is published to Docker Hub or GHCR
- Env var names are compatible (or document differences)
- Setup wizard flow still works
- The `ai-process` tag trigger is supported

### Model memory pressure
qwen3:14b (~10GB) + qwen3-vl:8b (~6GB) = ~16GB total, exceeding the 12GB VRAM available. Only one model fits in VRAM at a time. Use `OLLAMA_MAX_LOADED_MODELS=1` (default). The pipeline is sequential (OCR then classify), so model swapping between stages is the natural flow — expect ~10-20s swap latency per stage transition. If the swap latency becomes a bottleneck, consider dropping to qwen3:8b for classification (~6GB), which would allow both models to coexist in VRAM.

## 8. Success Metrics

| Metric | Target |
|--------|--------|
| Stack starts with single command | `docker compose up -d` brings all 9 services to healthy |
| Pipeline end-to-end | Document dropped in consume → tagged + titled within 15 min |
| Pipeline timing visible | Per-document stage durations printed in real-time; summary mode shows avg/median/max |
| No Bash scripts for daily ops | Operator never runs `./start.sh` or similar |
| Config is readable | New operator can understand the stack by reading compose.yaml + service .env files |
| Data is inspectable | `ls postgres/data/`, `ls paperless/media/` shows actual files |
| Zero data loss on migration | All existing documents preserved and accessible after cutover |

## 9. Open Questions

| # | Question | Impact |
|---|----------|--------|
| OQ1 | Does paperless-gpt support adding a specific tag (like `ai-process`) on OCR completion? Or only removing the trigger tag? | Determines if Stage 2→3 webhook handoff fires (webhook triggers on tag addition) |
| OQ2 | ~~Resolved~~: Django model paths confirmed — `documents.tag`, `documents.documenttype`, `documents.correspondent`, `documents.storagepath`, `documents.customfield`. But we're using the API approach (bootstrap.sh) anyway, so this is moot. | N/A |
| OQ3 | Is `admonstrator/paperless-ai-next` published as a Docker image, or does it need to be built from source? | Determines compose image reference |
| OQ4 | How should we auto-tag new documents for Stage 2? Matching rule in Paperless, post-consume script, or paperless-gpt watching all unprocessed docs? | Determines pipeline trigger mechanism |
| OQ5 | Backup strategy: standalone script, cron container, or external (e.g., Dropbox sync of bind mount dirs)? | Deferred — doesn't block compose migration |
| OQ6 | Should `config.sh` values (PROMPT_TAGS, AI_SYSTEM_PROMPT, tag taxonomy) be migrated to the fixture + service .env files, or kept as a reference? | Determines how much config.sh knowledge transfers |
| OQ7 | Does the user want a Makefile for common operations (`make up`, `make down`, `make bootstrap`, `make diagnose`)? | Nice-to-have DX improvement |
| OQ8 | What log format do paperless-gpt and paperless-ai-next emit? Need to verify they include document IDs and clear start/end markers that the timing script can parse. If not, can `LOG_LEVEL=debug` or a config flag enable structured output? | Determines feasibility of per-document timing without code changes to upstream images |
| OQ9 | Does Dozzle support saved multi-container filter presets (e.g., "AI Pipeline" = paperless + paperless-gpt + paperless-ai-next)? Or is it a manual selection each time? | Affects daily UX for log monitoring |
| OQ10 | Does paperless-ai-next's `/api/webhook/document` endpoint accept `doc_url` (paperless-ngx's webhook placeholder) or does it need `document_id` extracted from the URL? What's the exact expected request body? | Determines webhook configuration complexity |
| OQ11 | Can a Paperless-ngx Workflow trigger on "Tag Applied" specifically (not just "Document Added" or "Document Updated")? If only "Document Updated" is available, the webhook may fire on every metadata change, not just the `ai-process` tag addition. | Determines webhook precision — may need filtering logic in paperless-ai-next |
