# Paperless-ngx on WSL2 — setup guide

> Docker-based Paperless-ngx with Ollama AI tagging, vision OCR, and optional Dropbox ingestion.

---

## What you get

- Paperless-ngx with full OCR (Tesseract + OCRmyPDF)
- Office doc support (Word, Excel, PowerPoint via Tika + Gotenberg)
- AI auto-tagging and classification via paperless-ai + Ollama
- Vision-LLM OCR for messy scans via paperless-gpt + Ollama
- RAG chat — ask questions across your entire archive
- Optional Dropbox ingress folder for scanning on the go

---

## Prerequisites

**Docker Engine** running in WSL2. Not Docker Desktop — just the engine.

**Ollama** installed on the WSL host (not in Docker):

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

After install, **disable the systemd service** — setup.sh manages Ollama directly to avoid the ghost-models bug where systemd and your user store models in different directories:

```bash
sudo systemctl stop ollama
sudo systemctl disable ollama
sudo rm -rf /usr/share/ollama/.ollama
```

---

## Installation order

```bash
chmod +x setup.sh start.sh stop.sh remove.sh bootstrap.sh

# 1. Create the stack
./setup.sh

# 2. Create admin account
docker exec -it paperless python3 manage.py createsuperuser

# 3. Get your API token
#    Log in at http://localhost:8000 → username (top right) → My Profile → copy token

# 4. Paste token into setup.sh → PAPERLESS_API_TOKEN, then recreate:
./remove.sh
./setup.sh

# 5. Bootstrap tags, types, custom fields
./bootstrap.sh

# 6. Drop a PDF into ~/paperless-ngx/consume and watch it flow
```

After initial setup, daily use is just:

```bash
./start.sh          # start everything
./stop.sh           # stop everything
```

---

## How the pipeline works

Each tool does one job. Documents flow through all three automatically:

1. **Paperless-ngx** (`:8000`) — ingests the file, runs Tesseract OCR, extracts text, stores the document. This happens in seconds.

2. **paperless-gpt** (`:8080`) — if the document has the `paperless-gpt-auto` tag, re-OCRs it using the vision model `minicpm-v:8b`. Dramatically better on scanned/handwritten docs. Takes 1–2 min per page on CPU.

3. **paperless-ai** (`:3000`) — polls every 5 minutes for new documents, sends the text to Ollama (`llama3.1`), assigns title, tags, correspondent, document type from your predefined taxonomy.

To make every document go through vision OCR automatically, create a workflow in `:8000` → Settings → Workflows:
- Trigger: **Document Added**
- Action: **Assign tag** → `paperless-gpt-auto`

---

## Organization system

The community-recommended approach uses three axes plus a status layer.

**Correspondents** (who sent it) — one per document. Examples: Telekom, Landlord, Health Insurance, Tax Office, Bank, Employer. Auto-detected by paperless-ai.

**Document types** (what it is) — one per document. Examples: Invoice, Contract, Receipt, Certificate, Statement, Letter, Manual, Payslip. Auto-detected by paperless-ai.

**Tags** (what it's about) — multiple per document, nested for hierarchy:

```
Finance/Tax, Finance/Insurance, Finance/Banking
Housing/Rent, Housing/Utilities
Health/Medical, Health/Dental
Car/Car Insurance, Car/Service
Work/Payslip, Work/Employment
```

**Status** (what to do with it) — a custom Select field with values: `Inbox`, `Action needed`, `Waiting`, `Done`. Use saved views pinned to the dashboard:

- **Inbox** — filter: Status = Inbox, sorted newest first
- **Action needed** — filter: Status = Action needed, sorted oldest first
- **Waiting** — filter: Status = Waiting

**Storage path** — files on disk organized as `Correspondent/Year/Title.pdf` so they're browsable even without Paperless.

The `bootstrap.sh` script creates all of this via the API. Saved views are easier to set up in the web UI.

**Daily workflow:** check Inbox → review AI tags (corrections train the classifier) → set Status to "Action needed" or "Done" → check Action needed for things to pay/reply/sign → move to Waiting or Done.

---

## Networking — why the weird IPs

**`localhost` inside a container is the container itself**, not your WSL host. So Ollama at `localhost:11434` is unreachable from paperless-ai.

**`172.17.0.1` is the Docker bridge gateway.** It always points to your WSL host. This is the address used for Ollama from inside containers.

**Ollama must bind to `0.0.0.0`**, not `127.0.0.1` (the default). Otherwise Docker containers can't reach it. Both scripts handle this.

Debug connectivity:

```bash
docker exec paperless-ai curl -s http://172.17.0.1:11434
# Should print: Ollama is running
```

---

## Ollama management

Both scripts manage Ollama for you. Manual commands if needed:

```bash
OLLAMA_HOST=0.0.0.0 ollama serve &      # start
pkill -f 'ollama serve'                  # stop
curl -s http://localhost:11434           # check
ollama list                              # show models
echo "hi" | ollama run llama3.1          # test
```

**Never use the systemd service.** It stores models in a different directory, causing models to appear and vanish.

---

## Dropbox integration

Edit `CONSUME_DIR` in `setup.sh`:

```bash
CONSUME_DIR="/mnt/c/Users/YOURNAME/Dropbox/paperless-consume"
```

`CONSUMER_POLLING` must be `>0` (default `10`). inotify does not work on `/mnt/c/`.

**Do NOT put the database or media on `/mnt/c/`.** 9x performance penalty.

Backup via cron:

```bash
0 3 * * 0 docker exec paperless document_exporter /usr/src/paperless/export && \
  cp -r ~/paperless-ngx/export /mnt/c/Users/YOURNAME/Dropbox/paperless-backup/
```

---

## Useful commands

```bash
docker logs -f paperless                 # main app logs
docker logs -f paperless-ai              # AI tagging logs
docker logs -f paperless-gpt             # vision OCR logs
docker exec paperless python3 manage.py document_index reindex
docker exec paperless document_exporter /usr/src/paperless/export
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

---

## Troubleshooting

**"Ollama connection failed"** — use `http://172.17.0.1:11434`, not localhost. Check Ollama is bound to `0.0.0.0`:
```bash
pkill -f 'ollama serve' && OLLAMA_HOST=0.0.0.0 ollama serve &
docker exec paperless-ai curl -s http://172.17.0.1:11434
```

**"Failed to initialize connection to Paperless-ngx"** — use `http://paperless:8000`, not localhost.

**Models disappear** — systemd and your user use different model stores. Fix:
```bash
sudo systemctl stop ollama && sudo systemctl disable ollama
sudo rm -rf /usr/share/ollama/.ollama
```

**Container name conflict** — run `./stop.sh` then `./start.sh`.

**OCR is terrible** — that's Tesseract. Tag with `paperless-gpt-auto` for vision OCR, or set up the workflow to auto-tag every document.

**paperless-ai not tagging anything** — check the token: `cat ~/paperless-ai-data/.env | grep TOKEN`. If it says PASTE_YOUR_TOKEN_HERE, update `setup.sh` and re-run `./remove.sh` + `./setup.sh`.

---

## Configuration reference

All config lives in `setup.sh`. Edit there, then `./remove.sh` + `./setup.sh` to apply.

| Variable | Default | Notes |
|----------|---------|-------|
| `PAPERLESS_API_TOKEN` | (paste after first login) | From Profile page |
| `CONSUME_DIR` | `~/paperless-ngx/consume` | Point to Dropbox for auto-sync |
| `CONSUMER_POLLING` | `10` | Seconds. Must be >0 for `/mnt/c/` |
| `OLLAMA_MODEL` | `llama3.1` | Tagging and classification |
| `OLLAMA_VISION_MODEL` | `minicpm-v:8b` | Vision OCR |
| `OCR_LANGUAGES` | `deu+eng` | Tesseract codes joined with `+` |
| `PAPERLESS_PORT` | `8000` | Web UI |
| `AI_PORT` | `3000` | paperless-ai |
| `GPT_PORT` | `8080` | paperless-gpt |
| `SECRET_KEY` | (change this) | Random string for auth |

---

## Scripts

### setup.sh — first-time setup (creates everything)

```bash
#!/bin/bash
set -euo pipefail

# ============================================
# Configuration — edit these
# ============================================
NETWORK="paperless"
TIMEZONE="Europe/Vienna"
OCR_LANGUAGES="deu+eng"
SECRET_KEY="change-this-to-something-random"

PAPERLESS_PORT=8000
AI_PORT=3000
GPT_PORT=8080

PG_DB="paperless"
PG_USER="paperless"
PG_PASSWORD="paperless"

OLLAMA_MODEL="llama3.1"
OLLAMA_VISION_MODEL="minicpm-v:8b"

# Paste your API token here after first login
PAPERLESS_API_TOKEN="PASTE_YOUR_TOKEN_HERE"

# Paths
CONSUME_DIR="$HOME/paperless-ngx/consume"
EXPORT_DIR="$HOME/paperless-ngx/export"
AI_DATA_DIR="$HOME/paperless-ai-data"

# Uncomment for Dropbox ingestion:
# CONSUME_DIR="/mnt/c/Users/YOURNAME/Dropbox/paperless-consume"

# Must be >0 for /mnt/c/ paths (inotify broken on WSL2 bridge)
CONSUMER_POLLING=10

# ============================================
# Directories
# ============================================
mkdir -p "$CONSUME_DIR"
mkdir -p "$EXPORT_DIR"
mkdir -p "$AI_DATA_DIR"

# ============================================
# Ollama
# ============================================
if ! command -v ollama &>/dev/null; then
  echo "ERROR: Ollama not installed. Run: curl -fsSL https://ollama.com/install.sh | sh"
  exit 1
fi

if systemctl is-active ollama &>/dev/null; then
  echo "  ↳ Stopping systemd ollama (we manage it ourselves)..."
  sudo systemctl stop ollama
  sudo systemctl disable ollama 2>/dev/null
fi

if ! curl -sf http://localhost:11434/api/tags &>/dev/null; then
  echo "  ↳ Starting ollama serve..."
  nohup env OLLAMA_HOST=0.0.0.0 ollama serve &>/dev/null &
  for i in 1 2 3 4 5; do
    sleep 2
    curl -sf http://localhost:11434/api/tags &>/dev/null && break
  done
  if ! curl -sf http://localhost:11434/api/tags &>/dev/null; then
    echo "ERROR: Ollama failed to start"
    exit 1
  fi
fi
echo "  ↳ Ollama running (PID $(pgrep -f 'ollama serve'))"

for model in "$OLLAMA_MODEL" "$OLLAMA_VISION_MODEL"; do
  if ! ollama list | grep -q "$model"; then
    echo "  ↳ Pulling $model..."
    ollama pull "$model"
  fi
done
echo "  ↳ Models: $(ollama list | tail -n +2 | awk '{print $1}' | paste -sd', ')"

# ============================================
# paperless-ai config (skip the setup wizard)
# ============================================
cat > "$AI_DATA_DIR/.env" << EOF
PAPERLESS_API_URL=http://paperless:8000
PAPERLESS_API_TOKEN=${PAPERLESS_API_TOKEN}
PAPERLESS_NGX_URL=http://paperless:8000
PAPERLESS_URL=http://paperless:8000
PAPERLESS_HOST=http://paperless:8000
PAPERLESS_TOKEN=${PAPERLESS_API_TOKEN}
PAPERLESS_APIKEY=${PAPERLESS_API_TOKEN}
PAPERLESS_USERNAME=admin
AI_PROVIDER=ollama
OLLAMA_API_URL=http://172.17.0.1:11434
OLLAMA_MODEL=${OLLAMA_MODEL}
OLLAMA_MODEL_NAME=${OLLAMA_MODEL}
SCAN_INTERVAL=*/5 * * * *
ADD_AI_PROCESSED_TAG=yes
USE_PROMPT_TAGS=yes
RESTRICT_TAGS=no
RESTRICT_DOCUMENT_TYPES=no
RESTRICT_CORRESPONDENTS=no
USE_EXISTING_DATA=no
PROCESS_PREDEFINED_DOCUMENTS=no
PAPERLESS_AI_INITIAL_SETUP=no
TAGS=true
DOCUMENT_TYPES=true
CORRESPONDENTS=true
TITLE=true
CREATED_DATE=true
EOF
echo "  ↳ paperless-ai config written"

# ============================================
# Docker network
# ============================================
docker network create "$NETWORK" 2>/dev/null || true

# ============================================
# Create containers
# ============================================
echo "Creating containers..."

docker run -d --name paperless-redis \
  --add-host host.docker.internal:host-gateway \
  --network "$NETWORK" \
  --restart unless-stopped \
  redis:7

docker run -d --name paperless-db \
  --add-host host.docker.internal:host-gateway \
  --network "$NETWORK" \
  --restart unless-stopped \
  -e POSTGRES_DB="$PG_DB" \
  -e POSTGRES_USER="$PG_USER" \
  -e POSTGRES_PASSWORD="$PG_PASSWORD" \
  -v paperless-pgdata:/var/lib/postgresql/data \
  postgres:16

docker run -d --name paperless-tika \
  --add-host host.docker.internal:host-gateway \
  --network "$NETWORK" \
  --restart unless-stopped \
  apache/tika:latest

docker run -d --name paperless-gotenberg \
  --add-host host.docker.internal:host-gateway \
  --network "$NETWORK" \
  --restart unless-stopped \
  gotenberg/gotenberg:8 \
  gotenberg \
  --chromium-disable-javascript=true \
  --chromium-allow-list=file:///tmp/.*

docker run -d --name paperless \
  --add-host host.docker.internal:host-gateway \
  --network "$NETWORK" \
  --restart unless-stopped \
  -p "${PAPERLESS_PORT}:8000" \
  -e PAPERLESS_REDIS=redis://paperless-redis:6379 \
  -e PAPERLESS_DBHOST=paperless-db \
  -e PAPERLESS_DBNAME="$PG_DB" \
  -e PAPERLESS_DBUSER="$PG_USER" \
  -e PAPERLESS_DBPASS="$PG_PASSWORD" \
  -e PAPERLESS_TIKA_ENABLED=1 \
  -e PAPERLESS_TIKA_GOTENBERG_ENDPOINT=http://paperless-gotenberg:3000 \
  -e PAPERLESS_TIKA_ENDPOINT=http://paperless-tika:9998 \
  -e PAPERLESS_TIME_ZONE="$TIMEZONE" \
  -e PAPERLESS_OCR_LANGUAGE="$OCR_LANGUAGES" \
  -e PAPERLESS_OCR_MODE=skip \
  -e PAPERLESS_OCR_DESKEW=true \
  -e PAPERLESS_OCR_ROTATE_PAGES=true \
  -e PAPERLESS_OCR_IMAGE_DPI=300 \
  -e PAPERLESS_CONSUMER_POLLING="$CONSUMER_POLLING" \
  -e PAPERLESS_CONSUMER_POLLING_RETRY_COUNT=5 \
  -e PAPERLESS_CONSUMER_POLLING_DELAY=5 \
  -e PAPERLESS_SECRET_KEY="$SECRET_KEY" \
  -v paperless-data:/usr/src/paperless/data \
  -v paperless-media:/usr/src/paperless/media \
  -v "$CONSUME_DIR":/usr/src/paperless/consume \
  -v "$EXPORT_DIR":/usr/src/paperless/export \
  ghcr.io/paperless-ngx/paperless-ngx:latest

docker run -d --name paperless-ai \
  --add-host host.docker.internal:host-gateway \
  --network "$NETWORK" \
  --restart unless-stopped \
  -p "${AI_PORT}:3000" \
  -v "$AI_DATA_DIR":/app/data \
  clusterzx/paperless-ai:latest

docker run -d --name paperless-gpt \
  --add-host host.docker.internal:host-gateway \
  --network "$NETWORK" \
  --restart unless-stopped \
  -p "${GPT_PORT}:8080" \
  -e PAPERLESS_BASE_URL=http://paperless:8000 \
  -e PAPERLESS_API_TOKEN="$PAPERLESS_API_TOKEN" \
  -e LLM_PROVIDER=ollama \
  -e LLM_MODEL="$OLLAMA_MODEL" \
  -e OLLAMA_HOST=http://host.docker.internal:11434 \
  -e OCR_PROVIDER=llm \
  -e VISION_LLM_PROVIDER=ollama \
  -e VISION_LLM_MODEL="$OLLAMA_VISION_MODEL" \
  -e PAPERLESS_PUBLIC_URL="http://localhost:${PAPERLESS_PORT}" \
  icereed/paperless-gpt:latest

echo ""
echo "Setup complete:"
echo ""
echo "  Paperless-ngx   http://localhost:${PAPERLESS_PORT}"
echo "  Paperless-AI     http://localhost:${AI_PORT}"
echo "  Paperless-GPT    http://localhost:${GPT_PORT}"
echo "  Ollama           http://localhost:11434"
echo ""
echo "Next steps:"
echo "  1. docker exec -it paperless python3 manage.py createsuperuser"
echo "  2. Log in, copy API token from My Profile"
echo "  3. Paste token into PAPERLESS_API_TOKEN in this script"
echo "  4. ./remove.sh && ./setup.sh"
echo "  5. ./bootstrap.sh"
echo ""
```

---

### bootstrap.sh — create tags, types, fields (run once after setup)

```bash
#!/bin/bash
set -euo pipefail

# ============================================
# Configuration — must match setup.sh
# ============================================
API="http://localhost:8000/api"
TOKEN="PASTE_YOUR_TOKEN_HERE"

H=(-H "Authorization: Token $TOKEN" -H "Content-Type: application/json")

# ============================================
# Wait for Paperless
# ============================================
echo "Waiting for Paperless API..."
until curl -sf "${API}/tags/" "${H[@]}" >/dev/null 2>&1; do sleep 2; done
echo "  ↳ API ready"

# ============================================
# Document types
# ============================================
echo "Creating document types..."
for t in Invoice Contract Receipt Certificate Statement Letter Manual Payslip; do
  curl -sf -X POST "${API}/document_types/" "${H[@]}" -d "{\"name\":\"$t\"}" >/dev/null 2>&1 || true
  echo "  ↳ $t"
done

# ============================================
# Tags (nested via parent ID)
# ============================================
echo "Creating tags..."

create_tag() {
  local name="$1" parent_id="${2:-null}"
  local resp
  resp=$(curl -sf -X POST "${API}/tags/" "${H[@]}" \
    -d "{\"name\":\"$name\", \"parent\":$parent_id}" 2>/dev/null) || true
  echo "$resp" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*'
}

FIN=$(create_tag "Finance")
create_tag "Tax" "$FIN" >/dev/null
create_tag "Insurance" "$FIN" >/dev/null
create_tag "Banking" "$FIN" >/dev/null
echo "  ↳ Finance/*"

HOUSING=$(create_tag "Housing")
create_tag "Rent" "$HOUSING" >/dev/null
create_tag "Utilities" "$HOUSING" >/dev/null
echo "  ↳ Housing/*"

HEALTH=$(create_tag "Health")
create_tag "Medical" "$HEALTH" >/dev/null
create_tag "Dental" "$HEALTH" >/dev/null
echo "  ↳ Health/*"

CAR=$(create_tag "Car")
create_tag "Car Insurance" "$CAR" >/dev/null
create_tag "Service" "$CAR" >/dev/null
echo "  ↳ Car/*"

WORK=$(create_tag "Work")
create_tag "Payslip" "$WORK" >/dev/null
create_tag "Employment" "$WORK" >/dev/null
echo "  ↳ Work/*"

# paperless-gpt auto-processing tag
create_tag "paperless-gpt-auto" >/dev/null
echo "  ↳ paperless-gpt-auto"

# ============================================
# Custom field: Status
# ============================================
echo "Creating custom fields..."
curl -sf -X POST "${API}/custom_fields/" "${H[@]}" -d '{
  "name": "Status",
  "data_type": "select",
  "extra_data": {
    "select_options": ["Inbox", "Action needed", "Waiting", "Done"]
  }
}' >/dev/null 2>&1 || true
echo "  ↳ Status (Inbox / Action needed / Waiting / Done)"

# ============================================
# Storage path
# ============================================
echo "Creating storage path..."
curl -sf -X POST "${API}/storage_paths/" "${H[@]}" -d '{
  "name": "Default",
  "path": "{{ correspondent }}/{{ created_year }}/{{ title }}",
  "match": "",
  "matching_algorithm": 0
}' >/dev/null 2>&1 || true
echo "  ↳ correspondent/year/title"

# ============================================
# Done
# ============================================
echo ""
echo "Bootstrap complete."
echo ""
echo "Manual steps in the web UI (http://localhost:8000):"
echo ""
echo "  1. Settings → Workflows → Add:"
echo "     Trigger: Document Added"
echo "     Action: Assign tag → paperless-gpt-auto"
echo ""
echo "  2. Dashboard → Saved Views:"
echo "     - Inbox:          filter Status = Inbox"
echo "     - Action needed:  filter Status = Action needed"
echo "     - Waiting:        filter Status = Waiting"
echo ""
```

---

### start.sh — start the stack (daily use)

```bash
#!/bin/bash
set -euo pipefail

# ============================================
# Ollama
# ============================================
if ! command -v ollama &>/dev/null; then
  echo "ERROR: Ollama not installed"
  exit 1
fi

if systemctl is-active ollama &>/dev/null; then
  sudo systemctl stop ollama
fi

if ! curl -sf http://localhost:11434/api/tags &>/dev/null; then
  echo "  ↳ Starting ollama..."
  nohup env OLLAMA_HOST=0.0.0.0 ollama serve &>/dev/null &
  for i in 1 2 3 4 5; do
    sleep 2
    curl -sf http://localhost:11434/api/tags &>/dev/null && break
  done
  if ! curl -sf http://localhost:11434/api/tags &>/dev/null; then
    echo "ERROR: Ollama failed to start"
    exit 1
  fi
fi
echo "  ↳ Ollama running"

# ============================================
# Docker containers
# ============================================
CONTAINERS="paperless-redis paperless-db paperless-tika paperless-gotenberg paperless paperless-ai paperless-gpt"

echo "Starting containers..."
for c in $CONTAINERS; do
  if docker container inspect "$c" >/dev/null 2>&1; then
    docker start "$c" >/dev/null
    echo "  ↳ $c"
  else
    echo "  ↳ $c not found — run setup.sh first"
    exit 1
  fi
done

echo ""
echo "Stack is up:"
echo "  Paperless-ngx   http://localhost:8000"
echo "  Paperless-AI     http://localhost:3000"
echo "  Paperless-GPT    http://localhost:8080"
echo ""
```

---

### stop.sh — stop without losing data

```bash
#!/bin/bash

CONTAINERS="paperless-gpt paperless-ai paperless paperless-gotenberg paperless-tika paperless-db paperless-redis"

echo "Stopping..."
docker stop $CONTAINERS 2>/dev/null
pkill -f 'ollama serve' 2>/dev/null

echo ""
echo "Stopped. Run ./start.sh to resume."
```

---

### remove.sh — full teardown including data

```bash
#!/bin/bash

CONTAINERS="paperless-gpt paperless-ai paperless paperless-gotenberg paperless-tika paperless-db paperless-redis"
NETWORK="paperless"
VOLUMES="paperless-pgdata paperless-data paperless-media"

read -p "This will DELETE all Paperless data. Type 'yes' to confirm: " confirm
if [ "$confirm" != "yes" ]; then
  echo "Aborted."
  exit 1
fi

docker stop $CONTAINERS 2>/dev/null
docker rm   $CONTAINERS 2>/dev/null
docker network rm "$NETWORK" 2>/dev/null
docker volume rm $VOLUMES 2>/dev/null
pkill -f 'ollama serve' 2>/dev/null

echo ""
echo "Fully removed. Run ./setup.sh to start fresh."
```
