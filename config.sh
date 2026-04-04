#!/usr/bin/env bash
# config.sh — all non-secret configuration for the Paperless-ngx stack
#
# Every other script sources this file. To change a setting, edit here.
# Secrets (API token, Dropbox username) live in .env — see .env.example.
#
# Usage (in every script):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/config.sh"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Secrets (.env) ────────────────────────────────────────────────────────────
ENV_FILE="$SCRIPT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found."
  echo "  cp $SCRIPT_DIR/.env.example $SCRIPT_DIR/.env"
  echo "  Then fill in: PAPERLESS_API_TOKEN, DROPBOX_USER, SECRET_KEY, PG_PASSWORD"
  exit 1
fi
# shellcheck source=.env
source "$ENV_FILE"

# ── Required secrets validation ───────────────────────────────────────────────
# Fail loudly here rather than letting containers start with empty/wrong values.
_missing=()
[[ -z "${PAPERLESS_API_TOKEN:-}" ]] && _missing+=("PAPERLESS_API_TOKEN")
[[ -z "${DROPBOX_USER:-}"        ]] && _missing+=("DROPBOX_USER")
[[ -z "${SECRET_KEY:-}"          ]] && _missing+=("SECRET_KEY")
[[ -z "${PG_PASSWORD:-}"         ]] && _missing+=("PG_PASSWORD")
if [[ ${#_missing[@]} -gt 0 ]]; then
  echo "ERROR: Missing required values in .env: ${_missing[*]}"
  echo "  See .env.example for instructions."
  exit 1
fi
unset _missing

# ── Locale ────────────────────────────────────────────────────────────────────
TIMEZONE="Europe/Vienna"
OCR_LANGUAGES="deu+eng"

# ── Ports ─────────────────────────────────────────────────────────────────────
PAPERLESS_PORT=8000
AI_PORT=3000
GPT_PORT=8080

# ── Docker ────────────────────────────────────────────────────────────────────
NETWORK="paperless"

# Ordered start sequence (dependencies first)
CONTAINERS=(
  paperless-redis
  paperless-db
  paperless-tika
  paperless-gotenberg
  paperless
  paperless-ai
  paperless-gpt
)

VOLUMES=(paperless-pgdata paperless-data paperless-media)

# ── Database ──────────────────────────────────────────────────────────────────
PG_DB="paperless"
PG_USER="paperless"
# PG_PASSWORD comes from .env

# ── Paperless admin ───────────────────────────────────────────────────────────
# Must match the username you create with: docker exec -it paperless python3 manage.py createsuperuser
PAPERLESS_ADMIN_USER="admin"

# ── AI tagging ────────────────────────────────────────────────────────────
# Content tags that paperless-ai is allowed to assign.
# MUST NOT include workflow tags like paperless-gpt-ocr-auto.
# Keep in sync with bootstrap.sh when you add/remove tags.
PROMPT_TAGS="Finance,Tax,Insurance,Banking,Housing,Rent,Utilities,Health,Medical,Dental,health-xnc,health-ms,health-po,Car,Car Insurance,Service,Work,Payslip,Employment,Bank,School,Munster,Hoflein,Heinl,Altenberg"

# ── Ollama ────────────────────────────────────────────────────────────────────
OLLAMA_MODEL="llama3.1"
OLLAMA_VISION_MODEL="minicpm-v:8b"

# ── paperless-ai system prompt ────────────────────────────────────────────────
# Written to ~/paperless-ai-data/.env as SYSTEM_PROMPT on each setup.sh run.
# Edit here to update — setup.sh converts newlines to \n for dotenv compatibility.
AI_SYSTEM_PROMPT='You are a personalized document analyzer. Your task is to analyze documents
and extract relevant information. Documents may be in German or English.

Rules for tags:
- You will be given a list of allowed tags — use ONLY tags from that list
- Use the EXACT tag name as given — NEVER translate tags into the document language
- Use only relevant tags
- Maximum 4 tags per document, fewer if sufficient
- Do not use dates, years, or cities as tags
- Locality mappings (apply these tags when the document involves these places/institutions):
  - "Altenberg": any document from or mentioning "Marktgemeinde St. Andra-Wörden", "St. Andra-Wörden", or "Altenberg"

Rules for correspondent:
- Identify the sender, company, or institution the document originates from
- Use ONLY the name — exclude addresses, reference numbers, account numbers, and any other text

Rules for document_type:
- Use ONLY existing document types — NEVER create or invent new ones
- NEVER translate document type names into the document language
- Prefer the closest existing match (e.g. use "Invoice" not "Rechnung", "Contract" not "Vertrag")

Rules for title:
- Short and concise
- No addresses
- Should describe the document content meaningfully
- Use the document language

---

CONDITIONAL RULES FOR KIDS MEDICAL DOCUMENTS ONLY:
The following rules ONLY apply if the document is a medical invoice,
Arztrechnung, Honorarnote, Laborbefund with charges, or therapy receipt
for a child. For all other documents, IGNORE these rules entirely and
do NOT set these custom fields.

If kids medical invoice:
- Set document_type to "XNC medical"
- Examine the patient name on the document:
  - If the patient is Xander, apply tag "X"
  - If the patient is Cassian, apply tag "C"
  - If the patient is Nathaniel, apply tag "N"
- Also apply tag "health-xnc"
- Custom fields (ONLY for these documents):
  - Treatment date: Extract the date of treatment/service (Behandlungsdatum,
    Leistungsdatum, Ordinationsdatum). If multiple dates, use the most recent.
    ALWAYS format as YYYY-MM-DD (e.g. 2026-02-21).
    NEVER use DD.MM.YYYY or any other format.
    If you are not certain of the exact date, omit this field entirely — do not guess.
  - Amount: Extract the total amount (Gesamtbetrag, Honorar, Rechnungsbetrag).
    ALWAYS format as EUR followed by the amount with a dot as decimal separator
    and exactly two decimal places (e.g. EUR250.00).
    NEVER use a comma as decimal separator. NEVER omit the EUR prefix.
    If you are not certain of the exact amount, omit this field entirely — do not guess.
- Title format: [X/C/N] - [Doctor/Practice] - [short description]
  Example: C - Dr. Müller - Kontrolluntersuchung'

# ── Paths ─────────────────────────────────────────────────────────────────────
# Dropbox folder on the Windows side — documents dropped here are auto-ingested.
# inotify does not work across the WSL2 bridge, so polling is used instead.
CONSUME_DIR="/mnt/c/Users/${DROPBOX_USER}/Dropbox/paperless-consume"
EXPORT_DIR="$HOME/paperless-ngx/export"
AI_DATA_DIR="$HOME/paperless-ai-data"

# Dropbox backup destination
BACKUP_DIR="/mnt/c/Users/${DROPBOX_USER}/Dropbox/paperless-backup"

# ── Polling ───────────────────────────────────────────────────────────────────
# Must be >0 for /mnt/c/ paths (inotify broken on WSL2 bridge)
CONSUMER_POLLING=10
