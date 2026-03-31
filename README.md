# Paperless-ngx — WSL2 Local Setup

Docker-based Paperless-ngx with Ollama AI tagging, vision OCR, and Dropbox
ingestion — all local inside WSL2.

---

## What you get

| Service       | Port  | Role                                             |
| ------------- | ----- | ------------------------------------------------ |
| Paperless-ngx | 8000  | Document storage, OCR (Tesseract), web UI        |
| paperless-ai  | 3000  | AI auto-tagging via Ollama (llama3.1)            |
| paperless-gpt | 8080  | Vision OCR for scanned/messy docs (minicpm-v:8b) |
| PostgreSQL    | —     | Database (internal)                              |
| Redis         | —     | Task queue (internal)                            |
| Apache Tika   | —     | Office doc extraction (internal)                 |
| Gotenberg     | —     | PDF rendering (internal)                         |
| Ollama        | 11434 | Local LLM host (runs on WSL host, not in Docker) |

---

## Prerequisites

**1. Docker Engine** running in WSL2. Not Docker Desktop — just the engine:

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER   # then log out and back in
```

**2. Ollama** installed on the WSL host:

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

After install, **disable the systemd service**. The setup script manages Ollama
directly. If systemd runs it too, the two processes use different model directories
and models appear and vanish unpredictably:

```bash
sudo systemctl stop ollama
sudo systemctl disable ollama
sudo rm -rf /usr/share/ollama/.ollama
```

---

## First-time setup

```bash
# 1. Clone and enter the repo
cd /workspaces/paperless

# 2. Create your secrets file
cp .env.example .env
# Fill in all four required values:
#   DROPBOX_USER       — your Windows username
#   SECRET_KEY         — run: python3 -c "import secrets; print(secrets.token_hex(32))"
#   PG_PASSWORD        — any strong password, e.g.: openssl rand -base64 18
#   PAPERLESS_API_TOKEN — leave as placeholder for now, you'll get it in step 6

# 3. Make scripts executable
chmod +x *.sh

# 4. Create the full stack
./setup.sh

# 5. Create the admin account
docker exec -it paperless python3 manage.py createsuperuser
# Username: admin          ← or any name you prefer
# Email: (leave blank)     ← just press Enter, not required
# Password: yourpassword

# --- OR get the token automatically after creation (no browser needed): ---
# docker exec paperless python3 manage.py shell -c \
#   "from rest_framework.authtoken.models import Token; \
#    from django.contrib.auth.models import User; \
#    u=User.objects.get(username='admin'); \
#    t,_=Token.objects.get_or_create(user=u); print(t.key)"
```

```bash
docker exec paperless python3 manage.py shell -c \
   "from rest_framework.authtoken.models import Token; \
    from django.contrib.auth.models import User; \
    u=User.objects.get(username='admin'); \
    t,_=Token.objects.get_or_create(user=u); print(t.key)"
```

```bash
# 6. Get your API token
#    Either: log in at http://localhost:8000 → username → My Profile → Token
#    Or:     use the one-liner above (outputs the token directly to the terminal)

# 7. Paste the token into .env → PAPERLESS_API_TOKEN
#    Then apply it (recreates only the two AI containers — does NOT wipe the database):
docker rm -f paperless-gpt paperless-ai && ./setup.sh

# 8. Bootstrap taxonomy (tags, types, custom fields)
./bootstrap.sh

# 9. Drop a PDF into your Dropbox/paperless-consume folder — watch it flow
```

After initial setup, daily use is just two commands:

```bash
./start.sh    # start everything
./stop.sh     # stop everything
```

---

## How the pipeline works

Documents flow through three stages automatically:

```
Drop file into consume folder
        ↓
1. Paperless-ngx (:8000)
   Ingests the file, runs Tesseract OCR, stores it.
   Happens in seconds.
        ↓
2. paperless-gpt (:8080)
   If the document has the paperless-gpt-auto tag:
   re-OCRs it using minicpm-v:8b (vision LLM).
   Far better on scanned, handwritten, or tilted docs.
   ~1–2 min per page on CPU.
        ↓
3. paperless-ai (:3000)
   Polls every 5 minutes for new documents.
   Sends text to llama3.1 via Ollama.
   Assigns title, tags, correspondent, document type.
```

To make **every** document go through vision OCR automatically, create a workflow
in the web UI:

- Settings → Workflows → New
- Trigger: **Document Added**
- Action: **Assign tag** → `paperless-gpt-auto`

---

## Organization system

Three axes plus a status layer:

**Correspondents** — who sent it. One per document. Auto-detected by paperless-ai.
Examples: Telekom, Landlord, Health Insurance, Tax Office, Bank, Employer.

**Document types** — what it is. One per document. Auto-detected by paperless-ai.
Examples: Invoice, Contract, Receipt, Certificate, Statement, Letter, Manual, Payslip.

**Tags** — what it's about. Multiple per document. Your taxonomy:

```
Finance /  Tax, Insurance, Banking
Housing /  Rent, Utilities
Health  /  Medical, Dental, health-xnc, health-ms, health-po
Car     /  Car Insurance, Service
Work    /  Payslip, Employment

Top-level: Bank, School, Munster, Hoflein, Heinl, Altenberg
Special:   paperless-gpt-auto  ← triggers vision OCR
```

**Status** — a custom Select field with values:
`Inbox` → `Action needed` → `Waiting` → `Done`

**Storage path** — files on disk follow: `Correspondent/Year/Title.pdf`
Browse them in the filesystem without opening Paperless at all.

### Recommended saved views (set up in the web UI)

| View          | Filter                 | Sort         |
| ------------- | ---------------------- | ------------ |
| Inbox         | Status = Inbox         | Newest first |
| Action needed | Status = Action needed | Oldest first |
| Waiting       | Status = Waiting       | —            |

### Daily workflow

1. Check **Inbox** → review AI-assigned tags (corrections train the classifier)
2. Set Status to **Action needed** or **Done**
3. Check **Action needed** for things to pay / reply / sign
4. Move to **Waiting** or **Done**

---

## Scripts reference

| Script         | What it does                                                     |
| -------------- | ---------------------------------------------------------------- |
| `setup.sh`     | First-time setup: Ollama, models, network, all 7 containers      |
| `start.sh`     | Daily start: Ollama + docker start for each container            |
| `stop.sh`      | Daily stop: containers in reverse order + kill Ollama            |
| `remove.sh`    | Full teardown: containers, network, volumes (with confirmation)  |
| `bootstrap.sh` | Create taxonomy via API: tags, types, Status field, storage path |
| `status.sh`    | Stack health: Ollama PID, container states, service URLs         |
| `backup.sh`    | Export archive + copy to Dropbox (timestamped subfolder)         |
| `logs.sh`      | Tail all container logs simultaneously, prefixed by name         |

### Key config variables (`config.sh`)

| Variable              | Default                                                |
| --------------------- | ------------------------------------------------------ |
| `TIMEZONE`            | `Europe/Vienna`                                        |
| `OCR_LANGUAGES`       | `deu+eng`                                              |
| `OLLAMA_MODEL`        | `llama3.1`                                             |
| `OLLAMA_VISION_MODEL` | `minicpm-v:8b`                                         |
| `PAPERLESS_PORT`      | `8000`                                                 |
| `AI_PORT`             | `3000`                                                 |
| `GPT_PORT`            | `8080`                                                 |
| `CONSUME_DIR`         | `/mnt/c/Users/$DROPBOX_USER/Dropbox/paperless-consume` |
| `BACKUP_DIR`          | `/mnt/c/Users/$DROPBOX_USER/Dropbox/paperless-backup`  |
| `SECRET_KEY`          | Change this before first run                           |

Edit `config.sh` for non-secret settings. Edit `.env` for secrets.

---

## Troubleshooting

### "Ollama connection failed" in paperless-ai logs

Containers cannot reach `localhost` — that's the container itself, not the host.
Ollama must be reachable at `http://172.17.0.1:11434` (the Docker bridge gateway).

```bash
# Verify Ollama is bound to 0.0.0.0 (not 127.0.0.1)
pkill -f 'ollama serve'
OLLAMA_HOST=0.0.0.0 ollama serve &
docker exec paperless-ai curl -s http://172.17.0.1:11434
# Should print: Ollama is running
```

### Models keep disappearing

You have two Ollama instances fighting over different directories — systemd and your
user session. Fix:

```bash
sudo systemctl stop ollama && sudo systemctl disable ollama
sudo rm -rf /usr/share/ollama/.ollama
```

Then let `./start.sh` manage Ollama from now on.

### "Failed to initialize connection to Paperless-ngx" in paperless-ai

paperless-ai must use `http://paperless:8000` (the container's Docker DNS name),
not `localhost`. This is set automatically in `setup.sh`. Check the env file:

```bash
cat ~/paperless-ai-data/.env | grep PAPERLESS_API_URL
```

### paperless-ai not tagging anything

The token is likely still a placeholder:

```bash
cat ~/paperless-ai-data/.env | grep TOKEN
```

If it shows `PASTE_YOUR_TOKEN_HERE`, update `.env`, then re-run `docker rm -f paperless-gpt paperless-ai && ./setup.sh`.

### OCR quality is poor

Tesseract struggles with scanned documents. Enable vision OCR by tagging the document
with `paperless-gpt-auto` — or set up the Document Added workflow to auto-tag everything.

### Container name conflict on startup

```bash
./stop.sh && ./start.sh
```

---

## Useful one-liners

```bash
# Watch main app logs live
docker logs -f paperless

# Watch AI tagging logs
docker logs -f paperless-ai

# Watch vision OCR logs
docker logs -f paperless-gpt

# Extract API token after creating superuser (no browser needed)
docker exec paperless python3 manage.py shell -c \
  "from rest_framework.authtoken.models import Token; \
   from django.contrib.auth.models import User; \
   u=User.objects.get(username='admin'); \
   t,_=Token.objects.get_or_create(user=u); print(t.key)"

# Reindex the search database
docker exec paperless python3 manage.py document_index reindex

# Manual export
docker exec paperless document_exporter /usr/src/paperless/export

# Check all container states
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

---

## Networking — why `172.17.0.1`?

`localhost` inside a Docker container refers to that container, not your WSL host.
`172.17.0.1` is the Docker bridge gateway — it always points back to the WSL host.
That's why Ollama is configured at `http://172.17.0.1:11434` inside containers,
and Ollama must bind to `0.0.0.0` (not `127.0.0.1`) to accept those connections.

---

## Backup schedule (optional cron)

Add to your crontab (`crontab -e`) to auto-backup every Sunday at 03:00:

```
0 3 * * 0 /workspaces/paperless/backup.sh >> ~/paperless-backup.log 2>&1
```
