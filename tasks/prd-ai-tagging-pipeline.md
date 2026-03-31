# PRD: AI Tagging Pipeline — Chained OCR → Classification
## Status: In Progress
## Last Updated: 2026-03-31

## 1. Overview

The Paperless-ngx stack has all the right components — paperless-ngx for ingestion, paperless-gpt for vision OCR, paperless-ai for AI classification, and Ollama for local LLM inference — but they don't talk to each other. Documents get ingested and Tesseract-OCR'd, but AI tagging never fires.

**Two root causes:**
1. **No chaining** — paperless-gpt (OCR) and paperless-ai (tagging) operate independently. There's no signal from "OCR is done" to "start classifying." Running them concurrently causes a race condition: paperless-ai reads garbage Tesseract text before paperless-gpt has re-OCR'd with the vision model.
2. **paperless-ai misconfigured** — the setup wizard set `PROCESS_PREDEFINED_DOCUMENTS=yes` but no trigger tag exists, so paperless-ai processes zero documents.

**The fix:** Build a deterministic, tag-driven pipeline using Paperless-ngx workflows to chain the stages. Each stage completes and signals the next via tag manipulation — no polling races, no timing hacks.

### Target Pipeline

```
Document dropped into consume folder
        ↓
Paperless-ngx ingests + Tesseract OCR (seconds)
        ↓
Workflow 1 (Document Added):
  → Assigns "paperless-gpt-ocr-auto" tag
        ↓
paperless-gpt detects tag, runs vision OCR (minicpm-v:8b, 1-2 min)
  → REMOVES "paperless-gpt-ocr-auto"
  → ADDS "ocr-complete" (via PDF_OCR_TAGGING=true)
        ↓
Workflow 2 (Document Updated):
  Conditions: has "ocr-complete", does NOT have "paperless-gpt-ocr-auto"
  → Assigns "ai-process" tag
        ↓
paperless-ai detects "ai-process" tag on next poll (≤5 min)
  → Sends improved OCR text to llama3.1
  → Assigns: title, tags (≤4, from whitelist), correspondent, document type
  → Adds "ai-processed" marker tag
  → Marks document as processed in SQLite (won't re-process)
        ↓
Document fully classified ✓
```

## 2. Goals

- **G1**: Documents dropped into the consume folder are fully classified (title, tags, correspondent, document type) within 10 minutes, with zero manual intervention
- **G2**: Vision OCR always completes BEFORE AI classification starts — no race conditions
- **G3**: AI assigns ≤4 tags per document, chosen only from the bootstrap.sh taxonomy (never invents tags, never assigns workflow tags)
- **G4**: The full pipeline survives `docker rm -f paperless-ai paperless-gpt && ./setup.sh` — all config is baked into scripts
- **G5**: Each pipeline stage is independently verifiable via logs and diagnostic commands

## 3. User Stories

- **US-1**: As a user, I want to drop a PDF into my Dropbox folder and have it fully classified within 10 minutes without touching the web UI.
- **US-2**: As a user, I want AI tagging to use the improved vision-OCR text, not the garbage Tesseract output, so classification is accurate.
- **US-3**: As a user, I want to see which stage each document is in (OCR pending → OCR complete → AI processing → done) by looking at its tags.
- **US-4**: As a user, I want the AI to only assign tags from my defined taxonomy, not invent its own.
- **US-5**: As a user, I want my pipeline config to survive container rebuilds without re-running the setup wizard or manually editing files.

## 4. Functional Requirements

### FR-1: Enable paperless-gpt post-OCR tagging

paperless-gpt supports adding a tag after OCR completes, but it's disabled by default. Enable it by adding to the `paperless-gpt` container config in `setup.sh`:

| Env Var | Value | Purpose |
|---|---|---|
| `PDF_OCR_TAGGING` | `true` | Enable post-OCR tag assignment |
| `PDF_OCR_COMPLETE_TAG` | `ocr-complete` | Tag name added after OCR finishes |

This makes paperless-gpt **remove** `paperless-gpt-ocr-auto` and **add** `ocr-complete` after processing.

**Known issues:** This feature has had bugs in older versions (#438, #820, #910). Using latest image and testing.

### FR-2: Create Paperless-ngx Workflow 1 — Trigger OCR on ingestion

In Paperless-ngx web UI (Settings → Workflows → New):
- **Name**: "Auto Vision OCR"
- **Trigger**: Document Added
- **Action**: Assign tag `paperless-gpt-ocr-auto`

This workflow already exists per earlier setup. Verify it's active.

### FR-3: Create Paperless-ngx Workflow 2 — Trigger AI after OCR

In Paperless-ngx web UI (Settings → Workflows → New):
- **Name**: "AI Classification after OCR"
- **Trigger**: Document Updated
- **Conditions**:
  - Has tag: `ocr-complete`
  - Does NOT have tag: `paperless-gpt-ocr-auto`
- **Action**: Assign tag `ai-process`

This ensures the AI trigger tag is only applied AFTER OCR is fully done.

### FR-4: Create the pipeline tags via bootstrap.sh

Add these workflow/pipeline tags to `bootstrap.sh` (they are NOT content tags — exclude from `PROMPT_TAGS`):

| Tag | Purpose | Created by | Removed by |
|---|---|---|---|
| `paperless-gpt-ocr-auto` | Triggers vision OCR | Workflow 1 | paperless-gpt |
| `ocr-complete` | Signals OCR is done | paperless-gpt | Never (marker) |
| `ai-process` | Triggers AI classification | Workflow 2 | Never (marker) |
| `ai-processed` | Signals AI is done | paperless-ai | Never (marker) |

The `ocr-complete` and `ai-process` tags stay on the document permanently. paperless-ai tracks processed state in its SQLite DB, so the trigger tag being present doesn't cause re-processing.

### FR-5: Fix paperless-ai configuration in setup.sh

Update the managed config block to set:

| Key | Value | Why |
|---|---|---|
| `PROCESS_PREDEFINED_DOCUMENTS` | `yes` | Only process documents with the trigger tag |
| `TAGS` | `ai-process` | The trigger tag to watch for |
| `USE_PROMPT_TAGS` | `yes` | Restrict AI to whitelist only |
| `PROMPT_TAGS` | (from config.sh) | Content tags from bootstrap.sh, excludes all workflow tags |
| `RESTRICT_TO_EXISTING_TAGS` | `yes` | Safety net: drop any tag not in Paperless-ngx |
| `ADD_AI_PROCESSED_TAG` | `yes` | Add marker after processing |
| `AI_PROCESSED_TAG_NAME` | `ai-processed` | Marker tag name |
| `ACTIVATE_TAGGING` | `yes` | Enable tag assignment |
| `ACTIVATE_CORRESPONDENTS` | `yes` | Enable correspondent detection |
| `ACTIVATE_DOCUMENT_TYPE` | `yes` | Enable document type classification |
| `ACTIVATE_TITLE` | `yes` | Enable title generation |

Also update `_MANAGED_KEYS` array to include all keys above so `setup.sh` always overwrites them (preventing the wizard from overriding critical pipeline settings like `PROCESS_PREDEFINED_DOCUMENTS`).

### FR-6: Fix paperless-gpt container config in setup.sh

Update the `create_if_absent paperless-gpt` block to add the new env vars:

```bash
-e PDF_OCR_TAGGING=true \
-e PDF_OCR_COMPLETE_TAG=ocr-complete \
```

### FR-7: Add Ollama performance tuning

Add to the Ollama launch in both `start.sh` and `setup.sh`:

```bash
nohup env OLLAMA_HOST=0.0.0.0 OLLAMA_MAX_LOADED_MODELS=2 OLLAMA_KEEP_ALIVE=30m ollama serve &>/dev/null &
```

This keeps both models (llama3.1 + minicpm-v:8b) loaded simultaneously, avoiding 10-30s swap delays. Requires ~12GB RAM.

### FR-8: Create diagnose.sh

A diagnostic script that verifies each stage of the pipeline:

```
1. Ollama reachable from host?
2. Both models present?
3. Ollama reachable from paperless-gpt container?
4. Ollama reachable from paperless-ai container?
5. Paperless-ngx API up and token valid?
6. paperless-gpt can reach Paperless-ngx?
7. paperless-ai can reach Paperless-ngx?
8. paperless-ai health endpoint?
9. Pipeline tags exist in Paperless-ngx? (paperless-gpt-ocr-auto, ocr-complete, ai-process, ai-processed)
10. Test LLM generation (smoke test)?
```

## 5. Non-Goals / Out of Scope

- Changing Ollama models (llama3.1 and minicpm-v:8b stay)
- Custom SYSTEM_PROMPT (using built-in prompt with USE_PROMPT_TAGS restriction — max 4 tags is acceptable)
- Modifying the tag taxonomy itself
- Removing trigger/marker tags after processing (paperless-ai tracks state in SQLite, tag stays)
- Automating Paperless-ngx workflow creation (must be done once in web UI — cannot be scripted via API)
- Bulk-cleaning previously over-tagged documents (separate manual task)

## 6. Design Considerations

N/A — this is backend configuration and shell scripts only.

## 7. Technical Considerations

### paperless-gpt PDF_OCR_TAGGING internals

When `PDF_OCR_TAGGING=true`, the Go code in `background.go` builds a `DocumentSuggestion` that:
- Sets `RemoveTags: []string{autoOcrTag}` (removes trigger)
- Sets `AddTags: []string{app.pdfOCRCompleteTag}` (adds complete marker)
- Sets `KeepOriginalTags: true` (preserves all other tags)

**Caveat with `PDF_UPLOAD=true`**: When PDF replacement is enabled, `AddTags` is left empty because the upload flow handles tagging differently. We do NOT use `PDF_UPLOAD=true`, so this is not an issue.

### Paperless-ngx workflow trigger mechanics

- **Document Added** fires via `document_consumption_finished` signal — after Tesseract OCR, before file finalization
- **Document Updated** fires via `document_updated` signal — triggered by any PATCH/PUT to `/api/documents/{id}/`
- Workflow conditions support `filter_has_tags` (AND), `filter_has_not_tags` (exclusion)
- Workflows CAN chain: Workflow A's tag assignment triggers Document Updated, which can fire Workflow B
- **No infinite loop protection** — must ensure workflow conditions prevent re-triggering

### paperless-ai document selection logic

With `PROCESS_PREDEFINED_DOCUMENTS=yes`:
1. Reads `TAGS` env var, splits by comma
2. Resolves each tag name to Paperless-ngx tag ID via API
3. Queries `GET /api/documents/?tags__id__in=<ids>` — only returns matching docs
4. Checks each against SQLite `processed_documents` table — skips already-processed
5. No document locking — reads content, sends to LLM, then PATCHes results
6. Tag merge: re-fetches current tags before PATCH, merges (narrows race window)

**Known bug:** `getAllDocumentIdsScan()` (used by dashboard scan-now button) ignores tag filter. The cron-based `scanDocuments()` correctly filters — so automatic processing works, but manual "Scan Now" may process untagged docs.

### Race condition analysis of the chained pipeline

| Race | Possible? | Why not |
|---|---|---|
| paperless-ai reads before OCR done | **No** | `ai-process` tag only assigned by Workflow 2, which requires `ocr-complete` tag (set by paperless-gpt after OCR) AND absence of `paperless-gpt-ocr-auto` (removed by paperless-gpt after OCR) |
| Workflow 2 fires before OCR done | **No** | Requires `has: ocr-complete` AND `not has: paperless-gpt-ocr-auto` — both conditions are only true after paperless-gpt's single atomic PATCH |
| paperless-ai re-processes same doc | **No** | SQLite `processed_documents` table prevents re-processing |
| Workflow 2 re-fires on unrelated update | **Possible but harmless** | `ai-process` tag is already present; adding it again is a no-op. paperless-ai's SQLite check prevents re-processing |

### WSL2 memory requirements

Both models loaded simultaneously need ~12GB. WSL2 defaults to 50% of host RAM. If host has 16GB, WSL2 gets 8GB — not enough. May need `%USERPROFILE%\.wslconfig`:
```ini
[wsl2]
memory=12GB
```

## 8. Success Metrics

- Drop a test PDF → within 10 min it has: title, 1-4 content tags, correspondent, document type
- `paperless-gpt-ocr-auto` and other workflow tags never appear in AI-assigned content tags
- Tag progression visible: `paperless-gpt-ocr-auto` → `ocr-complete` → `ai-process` → `ai-processed`
- `diagnose.sh` passes all 10 checks
- Config survives `docker rm -f paperless-ai paperless-gpt && ./setup.sh` — no wizard re-run needed

## 9. Open Questions

- **Q1**: Has the paperless-ai setup wizard state been preserved in `~/paperless-ai-data/.env`? If yes, `setup.sh`'s merge logic will keep wizard keys (API_KEY, JWT_SECRET, etc.) and overwrite managed keys. If no, may need one more wizard run.
- **Q2**: How much RAM does the WSL2 VM have? (`free -h`) Can it hold both models simultaneously?
- **Q3**: Is Workflow 1 (Document Added → assign `paperless-gpt-ocr-auto`) already set up in the web UI?
- **Q4**: Does paperless-gpt's `PDF_OCR_TAGGING` feature work on the latest image? Need to verify empirically.

---

## Implementation

### Pre-flight Requirements

> This project uses shell scripts to configure Docker containers. No dev container rebuild needed.
> All `docker` and `./script.sh` commands must be run on the **WSL host**, not inside the dev container.

**New packages**: None.

**Environment variables**: None new in `.env` — all changes are in `setup.sh`'s managed config block and container env vars.

**Other system changes**:
- WSL2 may need `.wslconfig` memory increase (check Q2)
- Two new Paperless-ngx workflows must be created in the web UI (cannot be scripted)

---

### Relevant Files
- `setup.sh` — paperless-ai config block (lines ~92-162), paperless-gpt container creation (lines ~257-276), Ollama startup (lines ~50-88)
- `start.sh` — Ollama startup (lines ~14-38)
- `config.sh` — `PROMPT_TAGS` variable, container list
- `bootstrap.sh` — tag creation, now includes pipeline tags (ocr-complete, ai-process)
- `diagnose.sh` — NEW: 10-check pipeline diagnostic script

### Notes
- Test cycle: `docker rm -f paperless-ai paperless-gpt && ./setup.sh && docker logs -f paperless-gpt`
- Workflow creation must be done in Paperless-ngx web UI: `http://localhost:8000`
- paperless-ai dashboard for monitoring: `http://localhost:3000/dashboard`
- paperless-ai debug endpoints: `/health`, `/debug/tags`, `/debug/documents`

### Tasks
- [x] 1.0 Add pipeline tags to bootstrap.sh
  - [x] 1.1 Add `ocr-complete` tag (top-level, no parent) — signals OCR is done
  - [x] 1.2 Add `ai-process` tag (top-level, no parent) — triggers AI classification
  - [x] 1.3 Verify `paperless-gpt-ocr-auto` already exists (it does)
  - [x] 1.4 Verify `ai-processed` is created automatically by paperless-ai (ADD_AI_PROCESSED_TAG=yes)
  - [x] 1.5 Ensure none of these pipeline tags are in `PROMPT_TAGS` in config.sh
- [x] 2.0 Update paperless-gpt container in setup.sh
  - [x] 2.1 Add `-e PDF_OCR_TAGGING=true` to the `create_if_absent paperless-gpt` block
  - [x] 2.2 Add `-e PDF_OCR_COMPLETE_TAG=ocr-complete` to the same block
  - [x] 2.3 Verify `AUTO_TAG=""` and `MANUAL_TAG=""` remain empty (OCR only, no tagging by paperless-gpt)
- [x] 3.0 Fix paperless-ai config in setup.sh
  - [x] 3.1 Set `PROCESS_PREDEFINED_DOCUMENTS=yes` in managed config block
  - [x] 3.2 Set `TAGS=ai-process` (the trigger tag paperless-ai watches for)
  - [x] 3.3 Verify `USE_PROMPT_TAGS=yes` and `PROMPT_TAGS` are set correctly
  - [x] 3.4 Verify `RESTRICT_TO_EXISTING_TAGS=yes` is set
  - [x] 3.5 Verify `ADD_AI_PROCESSED_TAG=yes` and `AI_PROCESSED_TAG_NAME=ai-processed`
  - [x] 3.6 Replace old-style keys (`TAGS=true`, `DOCUMENT_TYPES=true`, `CORRESPONDENTS=true`, `TITLE=true`, `CREATED_DATE=true`) with v3.x keys (`ACTIVATE_TAGGING=yes`, `ACTIVATE_DOCUMENT_TYPE=yes`, `ACTIVATE_CORRESPONDENTS=yes`, `ACTIVATE_TITLE=yes`)
  - [x] 3.7 Add ALL managed keys to `_MANAGED_KEYS` array (including `PROCESS_PREDEFINED_DOCUMENTS`, `TAGS`, `AI_PROCESSED_TAG_NAME`, `ACTIVATE_*` keys) so setup.sh always overwrites them
  - [x] 3.8 Remove old key names from `_MANAGED_KEYS` array
- [x] 4.0 Add Ollama performance tuning
  - [x] 4.1 In `setup.sh` Ollama launch, add `OLLAMA_MAX_LOADED_MODELS=2 OLLAMA_KEEP_ALIVE=30m` to the env
  - [x] 4.2 In `start.sh` Ollama launch, add the same env vars
  - [ ] 4.3 Verify both models stay loaded: `curl -s http://localhost:11434/api/ps` (should show 2 models)
- [x] 5.0 Create diagnose.sh
  - [x] 5.1 Write `diagnose.sh` with 10 diagnostic checks (see FR-8)
  - [x] 5.2 Make executable and test: `chmod +x diagnose.sh && ./diagnose.sh`
- [ ] 6.0 Rebuild containers and run bootstrap
  - [ ] 6.1 Run `docker rm -f paperless-ai paperless-gpt` on WSL host
  - [ ] 6.2 Run `./setup.sh` to recreate with new config
  - [ ] 6.3 Run `./bootstrap.sh` to create new pipeline tags (ocr-complete, ai-process)
  - [ ] 6.4 Verify paperless-ai config: `docker exec paperless-ai cat /app/data/.env`
  - [ ] 6.5 Verify paperless-gpt env: `docker exec paperless-gpt env | grep PDF_OCR`
  - [ ] 6.6 Check paperless-ai health: `curl -s http://localhost:3000/health`
  - [ ] 6.7 Check paperless-ai sees tags: `curl -s http://localhost:3000/debug/tags`
- [ ] 7.0 Create Paperless-ngx workflows (manual, in web UI)
  - [ ] 7.1 Verify Workflow 1 exists: Document Added → assign `paperless-gpt-ocr-auto`
  - [ ] 7.2 Create Workflow 2: Document Updated, has tag `ocr-complete`, does NOT have tag `paperless-gpt-ocr-auto` → assign tag `ai-process`
  - [ ] 7.3 Verify both workflows are enabled
- [ ] 8.0 End-to-end test
  - [ ] 8.1 Drop a test PDF into the Dropbox consume folder
  - [ ] 8.2 Watch `docker logs -f paperless` — confirm ingestion + Tesseract OCR
  - [ ] 8.3 Watch `docker logs -f paperless-gpt` — confirm vision OCR triggers and completes
  - [ ] 8.4 Check document in web UI: should have `ocr-complete` tag, should NOT have `paperless-gpt-ocr-auto`
  - [ ] 8.5 Check document gets `ai-process` tag (from Workflow 2)
  - [ ] 8.6 Watch `docker logs -f paperless-ai` — confirm AI scan picks up the document
  - [ ] 8.7 Check document in web UI: has title, 1-4 content tags, correspondent, document type, `ai-processed` marker
  - [ ] 8.8 Verify no workflow tags (paperless-gpt-ocr-auto) in the content tags
- [ ] 9.0 Verify persistence
  - [ ] 9.1 Run `docker rm -f paperless-ai paperless-gpt && ./setup.sh`
  - [ ] 9.2 Verify config survived: `docker exec paperless-ai cat /app/data/.env | grep PROCESS_PREDEFINED`
  - [ ] 9.3 Verify paperless-gpt env survived: `docker exec paperless-gpt env | grep PDF_OCR`
  - [ ] 9.4 Run `./diagnose.sh` — all checks pass

### Progress Log
| Date | Task | Notes |
|------|------|-------|
| 2026-03-31 | 1.1–1.2 | Added ocr-complete and ai-process tags to bootstrap.sh; updated finish instructions to include Workflow 2 |
| 2026-03-31 | 2.1–2.3 | Added PDF_OCR_TAGGING=true and PDF_OCR_COMPLETE_TAG=ocr-complete to paperless-gpt container in setup.sh |
| 2026-03-31 | 3.1–3.8 | Fixed paperless-ai config: PROCESS_PREDEFINED_DOCUMENTS=yes, TAGS=ai-process, v3.x ACTIVATE_* keys, AI_PROCESSED_TAG_NAME; updated _MANAGED_KEYS |
| 2026-03-31 | 4.1–4.2 | Added OLLAMA_MAX_LOADED_MODELS=2 OLLAMA_KEEP_ALIVE=30m to Ollama launch in setup.sh and start.sh |
| 2026-03-31 | 5.1–5.2 | Created diagnose.sh with 10 pipeline checks; made executable |
