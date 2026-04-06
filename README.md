# Paperless-ngx — WSL2 Local Setup

Docker Compose-based Paperless-ngx with Ollama AI tagging, vision OCR, and Dropbox
ingestion — all local inside WSL2.

---

## What you get

| Service              | Port  | Role                                              |
| -------------------- | ----- | ------------------------------------------------- |
| Paperless-ngx        | 8000  | Document storage, Tesseract OCR, web UI           |
| paperless-ai-next    | 3000  | AI auto-tagging via Ollama (qwen3:14b)            |
| paperless-gpt        | 8080  | Vision OCR for scanned docs (qwen3-vl:8b)         |
| PostgreSQL 16        | —     | Database (internal)                               |
| Redis 7              | —     | Task queue (internal)                             |
| Apache Tika          | —     | Office doc extraction (internal)                  |
| Gotenberg            | —     | PDF rendering (internal)                          |
| Dozzle               | 9999  | Container log viewer (web UI)                     |
| Open WebUI           | 3001  | Ollama model management (web UI)                  |
| Ollama               | 11434 | Local LLM host (runs on WSL host, not in Docker)  |

---

## Prerequisites

**1. Docker Engine** running in WSL2 (not Docker Desktop — just the engine):

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # then log out and back in
```

**2. Ollama** installed on the WSL host:

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

After install, **disable the systemd service** — start Ollama manually so it binds
to `0.0.0.0` (required for containers to reach it):

```bash
sudo systemctl stop ollama
sudo systemctl disable ollama
# Start manually:
OLLAMA_HOST=0.0.0.0 ollama serve
```

---

## First-time setup

```bash
# 1. Clone and enter the repo
cd /workspaces/paperless

# 2. Start Ollama on the WSL host (must bind to 0.0.0.0 so containers can reach it)
OLLAMA_HOST=0.0.0.0 ollama serve &
# Leave this running. Verify: curl http://localhost:11434  → "Ollama is running"

# 3. Create your secrets file
cp .env.example .env
# Fill in required values — or use these generators:
#   DROPBOX_USER          — your Windows username (for Dropbox path symlink)
#   SECRET_KEY            — python3 -c "import secrets; print(secrets.token_hex(32))"
#   PG_PASSWORD           — openssl rand -base64 18
#   PAPERLESS_API_TOKEN   — leave as placeholder for now (step 7)
#   PAPERLESS_AI_NEXT_API_KEY — openssl rand -hex 24

# 4. Start the stack
docker compose up -d

# 5. Create the admin account
docker compose exec paperless python3 manage.py createsuperuser

# 6. Get your API token
docker compose exec paperless python3 manage.py shell -c \
  "from rest_framework.authtoken.models import Token; \
   from django.contrib.auth.models import User; \
   u=User.objects.get(username='admin'); \
   t,_=Token.objects.get_or_create(user=u); print(t.key)"

# 7. Paste the token into .env → PAPERLESS_API_TOKEN
#    Recreate affected containers to pick up the change:
docker compose up -d --force-recreate paperless-gpt paperless-ai-next

# 8. Bootstrap taxonomy (tags, types, custom fields, storage path, workflows)
#    This is idempotent — safe to re-run. Creates everything including the two
#    Paperless Workflows that drive the pipeline (no manual UI config needed).
./scripts/bootstrap.sh

# 9. Pull required models (Ollama must be running — see step 2)
ollama pull qwen3-vl:8b   # vision OCR base model
ollama pull qwen3:14b     # AI classification (Stage 3)

# 10. Create a custom vision model with a larger context window
#     qwen3-vl:8b defaults to 4096 tokens — too small for full-page images.
#     Vision models encode images as patch tokens (~10k tokens for an A4 page).
#     qwen3-vl-ocr is identical to qwen3-vl:8b but with a 32k context window.
ollama create qwen3-vl-ocr -f - <<'EOF'
FROM qwen3-vl:8b
PARAMETER num_ctx 32768
EOF

# 11. Complete the paperless-ai-next setup wizard at http://localhost:3000/setup

# 12. Drop a PDF into your Dropbox/paperless-consume folder — watch it flow
```

### Paperless Workflows

Both workflows are created automatically by `./scripts/bootstrap.sh` — no manual UI configuration needed. For reference, here's what they do:

**Workflow 1 — Auto Vision OCR**
- Trigger: Document Added
- Action: Assign tag → `paperless-gpt-ocr-auto`

**Workflow 2 — AI Classification after OCR**
- Trigger: Document Updated
- Condition: has tag `ai-process`
- Action: Webhook POST → `http://paperless-ai-next:3000/api/webhook/document`
- Header: `x-api-key: <PAPERLESS_AI_NEXT_API_KEY>` (from your `.env`)
- Body: `{"doc_url": "{{ doc_url }}"}`

To inspect or edit them: **http://localhost:8000 → Settings → Workflows**

---

## Daily operations

```bash
# Start Ollama (WSL host — must be running before the pipeline can tag anything)
OLLAMA_HOST=0.0.0.0 ollama serve &

# Start full stack
docker compose up -d

# Stop (data preserved in bind-mount dirs)
docker compose down

# Tail all logs with timestamps
docker compose logs -f --timestamps

# Per-document pipeline timing
./scripts/pipeline-timing.sh

# Full pipeline health check
./scripts/diagnose.sh

# Backup to Dropbox
./scripts/backup.sh

# All container states
docker compose ps
```

---

## How the pipeline works

Documents flow through three stages automatically:

```
Drop file into consume folder
        ↓
1. Paperless-ngx (:8000)
   Ingests file, runs Tesseract OCR, stores it.
   Workflow assigns tag: paperless-gpt-ocr-auto
        ↓
2. paperless-gpt (:8080)
   Detects paperless-gpt-ocr-auto tag.
   Re-OCRs using qwen3-vl:8b (vision LLM) — much better on scanned/handwritten docs.
   Removes paperless-gpt-ocr-auto, adds: ai-process
        ↓
3. paperless-ai-next (:3000)
   Webhook fires immediately when ai-process tag is applied.
   Sends text to qwen3:14b via Ollama.
   Assigns title, tags, correspondent, document type.
   Fallback: cron polls every 5 min for missed webhooks.
```

**Note on model swap:** qwen3-vl:8b (Stage 2) and qwen3:14b (Stage 3) cannot coexist
in 12GB VRAM. `OLLAMA_MAX_LOADED_MODELS=1` ensures they swap sequentially — expect
10–20s between Stage 2 completing and Stage 3 starting.

---

## Models

### What's running by default

| Stage | Model | Role | VRAM | Speed |
|---|---|---|---|---|
| Vision OCR | `qwen3-vl-ocr` | Reads scanned pages as images, extracts text | ~6 GB | ~15–30s/page |
| AI classify | `qwen3:14b` | Assigns title, tags, correspondent, doc type | ~9 GB | ~10–20s/doc |

`qwen3-vl-ocr` is a custom Ollama model — it's `qwen3-vl:8b` with `num_ctx 32768` set via a Modelfile. The weights are identical; only the KV cache size changes.

**Why this is needed:** qwen3-vl uses dynamic resolution — it tiles images into 28×28px patches and tokenizes each patch. An A4 page at 300 DPI (~2400×3400px) produces ~10,000 patch tokens. Ollama's default `num_ctx` of 4096 can't hold them all, so it silently truncates the image mid-process and returns empty OCR output. `num_ctx 32768` allocates a large enough KV cache buffer to hold the full image token sequence. The model itself has no fixed input size limit — this is purely a runtime memory allocation.

The custom model must be created once with `ollama create` (see First-time setup step 10).

These two models **cannot coexist** in 12 GB VRAM. `OLLAMA_MAX_LOADED_MODELS=1` in `paperless/.env` forces sequential loading — the 10–20s gap between Stage 2 and Stage 3 is the model swap.

### Swapping models

- **Vision OCR:** edit `paperless-gpt/.env` → `VISION_LLM_MODEL` and `LLM_MODEL`
- **AI classify:** edit `paperless-ai-next/.env` → `OLLAMA_MODEL`
- Then: `docker compose up -d --force-recreate paperless-gpt paperless-ai-next`

### Alternatives by hardware tier

**CPU only / integrated graphics (no dedicated GPU)**
Slow but functional. Expect 2–5 min per document.

| Stage | Model | Notes |
|---|---|---|
| Vision OCR | `moondream2` | Tiny (1.8B), fast, OCR quality is basic |
| AI classify | `gemma3:2b` or `qwen3:4b` | Acceptable tagging for simple docs |

**8 GB VRAM (e.g. RTX 3070, RX 6700 XT)**
Drop the classify model to fit within budget. Still sequential.

| Stage | Model | Notes |
|---|---|---|
| Vision OCR | `qwen3-vl:8b` | Keep — best quality at this size |
| AI classify | `qwen3:8b` | Slightly less capable than 14b but fits comfortably |

**12 GB VRAM — default (e.g. RTX 3060 12GB, RTX 4070)**
Current setup. Both models run sequentially, one at a time.

| Stage | Model | Notes |
|---|---|---|
| Vision OCR | `qwen3-vl:8b` | Default |
| AI classify | `qwen3:14b` | Default |

**16–24 GB VRAM (e.g. RTX 3090, RTX 4090, RTX 4080)**
Both models fit simultaneously — no swap delay. Set `OLLAMA_MAX_LOADED_MODELS=2` in `paperless/.env` and the pipeline becomes fully continuous.

| Stage | Model | Notes |
|---|---|---|
| Vision OCR | `qwen3-vl:8b` | Or upgrade to `qwen2.5-vl:32b` for better handwriting |
| AI classify | `qwen3:32b` | Noticeably better title and tag quality |

**32 GB+ VRAM (e.g. A100, dual GPU, Mac Studio M2 Ultra)**
Run everything simultaneously with maximum quality.

| Stage | Model | Notes |
|---|---|---|
| Vision OCR | `qwen2.5-vl:72b` | Near-human OCR accuracy |
| AI classify | `qwen3:32b` or `llama3.3:70b` | Excellent classification, handles ambiguous docs well |

---

## Organization system

**Correspondents** — who sent it. One per document. Auto-detected by AI.
Examples: Telekom, Landlord, Health Insurance, Tax Office, Bank, Employer.

**Document types** — what it is. One per document. Auto-detected by AI.
Examples: Invoice, Contract, Receipt, Certificate, Statement, Letter, Manual, Payslip.

**Tags** — what it's about. Multiple per document. Your taxonomy:

```
Finance /  Tax, Insurance, Banking
Housing /  Rent, Utilities
Health  /  Medical, Dental, health-xnc, health-ms, health-po
Car     /  Car Insurance, Service
Work    /  Payslip, Employment

Top-level: Bank, School, Munster, Hoflein, Heinl, Altenberg
Pipeline:  paperless-gpt-ocr-auto  ← triggers vision OCR (Stage 2)
           ai-process              ← triggers AI classification (Stage 3)
           ai-processed            ← marks completed AI classification
```

**Status** — custom Select field: `Inbox` → `Action needed` → `Waiting` → `Done`

**Storage path** — files on disk follow `Correspondent/Year/Title.pdf` — browsable
in the filesystem without opening Paperless.

### Recommended saved views

| View          | Filter                 | Sort         |
| ------------- | ---------------------- | ------------ |
| Inbox         | Status = Inbox         | Newest first |
| Action needed | Status = Action needed | Oldest first |
| Waiting       | Status = Waiting       | —            |

### Daily workflow

1. Check **Inbox** → review AI-assigned tags
2. Set Status to **Action needed** or **Done**
3. Check **Action needed** for things to pay / reply / sign
4. Move to **Waiting** or **Done**

---

## Scripts reference

| Script                      | What it does                                                      |
| --------------------------- | ----------------------------------------------------------------- |
| `scripts/bootstrap.sh`      | Create taxonomy via API: tags, types, Status field, storage path. Idempotent. |
| `scripts/diagnose.sh`       | 10-check pipeline health: Ollama, models, connectivity, tags, LLM smoke test |
| `scripts/backup.sh`         | Export docs + copy to Dropbox (timestamped subfolder)             |
| `scripts/pipeline-timing.sh`| Tail compose logs and print per-document stage timing             |

Old bash scripts (`setup.sh`, `start.sh`, `stop.sh`, etc.) are in `scripts-archive/`
for reference — no longer used.

---

## Troubleshooting

### Ollama not reachable from containers

Containers use `http://host.docker.internal:11434` (via `extra_hosts: host-gateway`).
Ollama must bind to `0.0.0.0`:

```bash
# Kill any existing instance and restart with correct binding
pkill -f 'ollama serve'
OLLAMA_HOST=0.0.0.0 ollama serve

# Verify a container can reach it
docker compose exec paperless-gpt curl -s http://host.docker.internal:11434
# Should print: Ollama is running
```

### paperless-ai-next not tagging anything

Check in order:

```bash
# 1. Is the setup wizard complete?
curl -s http://localhost:3000/health

# 2. Can it reach Paperless?
docker compose exec paperless-ai-next curl -s http://paperless:8000/api/ \
  -H "Authorization: Token $(grep PAPERLESS_API_TOKEN .env | cut -d= -f2)"

# 3. Is the API token still a placeholder?
docker compose exec paperless-ai-next cat /app/data/.env | grep TOKEN
```

### Models keep disappearing

Two Ollama instances fighting over different directories (systemd vs user session):

```bash
sudo systemctl stop ollama && sudo systemctl disable ollama
# Then always start manually: OLLAMA_HOST=0.0.0.0 ollama serve
```

### OCR quality is poor

Tesseract struggles with scanned documents. paperless-gpt handles this via vision OCR.
Confirm the `paperless-gpt-ocr-auto` tag exists and Workflow 1 is configured.

### View all logs

Open Dozzle at **http://localhost:9999** — live log stream for all containers without
needing a terminal.

---

## Useful one-liners

```bash
# Check all container states
docker compose ps

# Tail specific service logs
docker compose logs -f paperless-ai-next
docker compose logs -f paperless-gpt

# Extract API token after creating superuser
docker compose exec paperless python3 manage.py shell -c \
  "from rest_framework.authtoken.models import Token; \
   from django.contrib.auth.models import User; \
   u=User.objects.get(username='admin'); \
   t,_=Token.objects.get_or_create(user=u); print(t.key)"

# Reindex the search database
docker compose exec paperless python3 manage.py document_index reindex

# Manual backup export
docker compose exec paperless document_exporter /usr/src/paperless/export

# What models are loaded in Ollama right now?
curl -s http://localhost:11434/api/ps

# Full pipeline diagnosis
./scripts/diagnose.sh
```

---

## Networking

Containers use `http://host.docker.internal:11434` to reach Ollama on the WSL host
(configured via `extra_hosts: host.docker.internal:host-gateway` in `compose.yaml`).
This is more reliable than hardcoding `172.17.0.1` which can change. Ollama must bind
to `0.0.0.0` (not `127.0.0.1`) to accept these connections.

---

## References

- [Paperless-ngx docs](https://docs.paperless-ngx.com)
- [paperless-ai-next (admonstrator)](https://github.com/admonstrator/paperless-ai-next)
- [paperless-gpt (icereed)](https://github.com/icereed/paperless-gpt)
- [Ollama](https://ollama.com)
- [Dozzle](https://dozzle.dev)
- [Open WebUI](https://github.com/open-webui/open-webui)
