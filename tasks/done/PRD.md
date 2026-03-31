# PRD — Paperless-ngx Local WSL Setup

## Problem

Setting up Paperless-ngx with AI tagging and vision OCR on WSL2 involves many manual
steps, scattered `docker run` commands, duplicated config across files, and no clear
runbook for daily use or recovery. The reference guide is a good knowledge base but
not an executable system.

## Goal

Deliver a clean, self-contained shell script kit that can be cloned, configured in
one file (`.env`), and have a fully running document management stack inside WSL2 in
under 15 minutes — with Ollama-powered AI tagging and vision OCR included.

## Non-goals

- No Windows-native setup (WSL2 only for now)
- No Docker Compose (raw `docker run` by design — simpler to debug and understand)
- No cloud sync beyond Dropbox ingestion / backup
- No UI customisation beyond the bootstrapped taxonomy

---

## User Stories

| # | As a user I want to…                                        | So that…                                              |
|---|-------------------------------------------------------------|-------------------------------------------------------|
| 1 | Run `./setup.sh` to bring the full stack up from zero       | I don't have to remember 30 docker commands           |
| 2 | Edit a single `.env` file for secrets                       | API tokens are never committed to git                 |
| 3 | Edit `config.sh` for preferences                            | All non-secret settings live in one place             |
| 4 | Run `./start.sh` / `./stop.sh` for daily use                | Daily workflow is two commands                        |
| 5 | Run `./status.sh` to see what's running                     | I can verify stack health without reading docker ps   |
| 6 | Run `./backup.sh` to archive documents to Dropbox           | I have an off-site backup without manual steps        |
| 7 | Run `./logs.sh` to tail all service logs                    | I can debug issues in one terminal                    |
| 8 | Run `./bootstrap.sh` once to create my taxonomy             | Tags, types, and custom fields are provisioned automatically |
| 9 | Have a `README.md` that walks me through everything         | I can follow setup without reading the reference guide |

---

## Requirements

### Functional

| ID  | Requirement                                                                                       |
|-----|---------------------------------------------------------------------------------------------------|
| R1  | `setup.sh` is idempotent — re-running after partial failure must not duplicate containers or fail noisily |
| R2  | All scripts source `config.sh`, which sources `.env` — no secret duplication across files         |
| R3  | `.env.example` documents every required variable with a description comment                       |
| R4  | `setup.sh` manages Ollama (start, readiness-wait, model pull) before creating containers          |
| R5  | `bootstrap.sh` waits for the Paperless API to be reachable before posting anything               |
| R6  | `bootstrap.sh` creates: nested tags, document types, `Status` custom field (select), storage path |
| R7  | `backup.sh` runs `document_exporter` inside the container, then copies to `$BACKUP_DIR` on `/mnt/c/` |
| R8  | `status.sh` shows Ollama PID/reachability, per-container status, and service URLs               |
| R9  | `logs.sh` tails all containers simultaneously with per-line container-name prefix                |
| R10 | `remove.sh` requires explicit `yes` confirmation and destroys containers, volumes, and network   |

### Non-functional

| ID  | Requirement                                                                              |
|-----|------------------------------------------------------------------------------------------|
| R11 | All scripts use `#!/usr/bin/env bash` + `set -euo pipefail`                              |
| R12 | Container list stored as a bash array (not a string) to avoid word-splitting bugs        |
| R13 | `.env` and data directories (`consume/`, `export/`) are listed in `.gitignore`           |
| R14 | `SCRIPT_DIR` pattern used in every script for reliable relative sourcing of `config.sh`  |

---

## Tag Taxonomy (bootstrap.sh)

### Nested tags

```
Finance/
  Tax, Insurance, Banking
Housing/
  Rent, Utilities
Health/
  Medical, Dental, health-xnc, health-ms, health-po
Car/
  Car Insurance, Service
Work/
  Payslip, Employment
```

### Top-level tags

`Bank`, `School`, `Munster`, `Hoflein`, `Heinl`, `Altenberg`, `paperless-gpt-auto`

### Document types

Invoice, Contract, Receipt, Certificate, Statement, Letter, Manual, Payslip

### Custom field

**Status** — select with options: `Inbox`, `Action needed`, `Waiting`, `Done`

### Storage path

`{{ correspondent }}/{{ created_year }}/{{ title }}`

---

## Defaults

| Variable             | Value                                                        |
|----------------------|--------------------------------------------------------------|
| `TIMEZONE`           | `Europe/Vienna`                                              |
| `OCR_LANGUAGES`      | `deu+eng`                                                    |
| `OLLAMA_MODEL`       | `llama3.1`                                                   |
| `OLLAMA_VISION_MODEL`| `minicpm-v:8b`                                               |
| `PAPERLESS_PORT`     | `8000`                                                       |
| `AI_PORT`            | `3000`                                                       |
| `GPT_PORT`           | `8080`                                                       |
| `CONSUME_DIR`        | `/mnt/c/Users/$DROPBOX_USER/Dropbox/paperless-consume`       |
| `EXPORT_DIR`         | `$HOME/paperless-ngx/export`                                 |
| `BACKUP_DIR`         | `/mnt/c/Users/$DROPBOX_USER/Dropbox/paperless-backup`        |

---

## Deliverables

```
/workspaces/paperless/
  PRD.md              ← this file
  README.md           ← user-facing setup guide
  .env.example        ← secrets template (committed)
  .env                ← secrets (gitignored, created by user)
  config.sh           ← all non-secret config; sources .env
  setup.sh            ← first-time stack creation
  start.sh            ← daily start
  stop.sh             ← daily stop
  remove.sh           ← full teardown with confirmation
  bootstrap.sh        ← create taxonomy via API
  status.sh           ← stack health at a glance
  backup.sh           ← export + copy to Dropbox
  logs.sh             ← tail all container logs combined
  .gitignore
```

## Success Criteria

1. `./setup.sh` on a fresh WSL machine creates all containers and starts the stack
2. `./status.sh` reports UP for all 7 services + Ollama reachable
3. `./bootstrap.sh` creates the full taxonomy without errors
4. `./backup.sh` writes an archive to the Dropbox path
5. All scripts pass `bash -n` syntax check
