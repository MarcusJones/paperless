# PRD 2: Smart Document Pipeline

**Status:** Draft
**Author:** Marcus Jones
**Date:** 2026-04-08
**Series:** 2 of 3 — [Dashboard & Visibility](prd-dashboard-visibility.md) → [Smart Pipeline] → [Hybrid Cloud](prd-hybrid-cloud.md)
**Depends on:** [PRD 1 (Dashboard)](prd-dashboard-visibility.md) — requires the dashboard, QuestDB, pipeline event schema, and settings modal.

---

## 1. Introduction / Overview

The current Paperless pipeline is a fixed 3-stage linear flow: every document goes through Tesseract OCR → Vision OCR (GPU) → LLM Classification, regardless of complexity. A simple 1-page text PDF burns the same GPU time as a 20-page scanned handwritten document. The LLM prompt is overloaded with pattern-matching instructions ("if text contains 'Deutsche Telekom' tag as Utilities...") that simple string comparisons could handle in microseconds.

**What this delivers:** An intelligent document routing pipeline that:

1. **Triages** each document based on metadata (page count, file size, embedded text) and routes it to the appropriate OCR path — fast Tesseract for simple docs, Vision OCR for complex/scanned ones.
2. **Matches known patterns first** via a fuzzy text matching rule engine, tagging documents instantly without an LLM call.
3. **Sends only unmatched documents to the LLM**, with a focused prompt that doesn't waste tokens on pattern matching.
4. **Learns from the LLM** — every LLM classification proposes a new rule. Users approve/reject/edit proposals in a suggestions queue on the dashboard.

The result: most documents are classified in seconds without GPU usage. The LLM handles genuinely ambiguous documents and continuously trains the rule engine.

```
Upload → Triage (metadata) → OCR (fast or vision) → Rule Engine (fuzzy match)
                                                         ↓ matched → done
                                                         ↓ unmatched → LLM → tag + suggest new rules
```

---

## 2. Goals

| # | Goal | Measurable |
|---|------|-----------|
| G1 | Smart document routing | Triage routes >80% of simple docs (1-page text PDFs) to fast OCR, skipping Vision OCR |
| G2 | Rule engine reduces LLM calls | After 30 days of use, >60% of documents are classified by rules without an LLM call |
| G3 | LLM-to-rule feedback loop | Every LLM classification produces a rule suggestion visible in the dashboard |
| G4 | Rule management from the dashboard | Users can create, edit, delete, and test rules from the settings UI |
| G5 | Pipeline profiling shows routing | The swimlane chart displays which path each document took (fast vs. vision, rules vs. LLM) |
| G6 | No regression on current docs | Documents that were correctly classified by the old pipeline are still correctly classified |
| G7 | Rule engine latency | < 100ms per document for fuzzy matching |

---

## 3. User Stories

**US1 — Simple docs processed fast**
As a user who scans single-page bank statements every week, I want the system to recognize these are simple text documents and skip the slow Vision OCR entirely, so they're tagged within seconds instead of minutes.

**US2 — Known senders tagged instantly**
As a user who receives the same Deutsche Telekom invoice every month, I want the system to recognize "Deutsche Telekom" in the text and immediately tag it as Utilities/Invoice, without waiting for the LLM to think about it.

**US3 — Teaching the system my patterns**
As a user who just approved a rule suggestion for "Allianz Versicherung" → Insurance, I want future Allianz documents to be tagged instantly — and I want to see the rule's hit count grow over time so I know it's working.

**US4 — Reviewing what the AI suggested**
As a user who wants to stay in control of classification, I want a queue of rule suggestions from the LLM that I can approve, edit, or reject — so the system gets smarter over time but never acts beyond what I've sanctioned.

**US5 — Complex docs still get full treatment**
As a user who occasionally scans handwritten doctor's notes or multi-page insurance contracts, I want the system to detect these are complex and route them through Vision OCR + LLM — not try to shortcut them through the fast path.

**US6 — Seeing which path my document took**
As a user watching the pipeline timeline on the dashboard, I want to see whether a document went through the fast path or the full path, and whether it was classified by a rule or the LLM — so I can profile performance and understand why some docs are fast and others slow.

**US7 — Testing a rule before saving it**
As a user creating a new matching rule, I want to paste some document text and see if the rule matches (and at what confidence) before I save it — so I don't accidentally create rules that match the wrong documents.

**US8 — Bulk-processing old documents through rules**
As a user with 300+ existing documents that were classified by the LLM, I want to run the rule engine against my existing document archive so that common patterns are identified and future documents benefit from those rules immediately.

---

## 4. Functional Requirements

### 4.1 Triage Stage

Runs on every new document immediately after upload/consume, before any OCR.

**FR-TR1 — Metadata extraction:**
- Page count (from PDF metadata or image count)
- File size (bytes)
- File type: native PDF (has embedded text), scanned PDF (images only), image file (JPEG/PNG/TIFF), office document (DOCX/XLSX via Tika)
- Whether embedded text is already present (and if so, how much — character count)

**FR-TR2 — Routing decision (heuristic rules, configurable via dashboard):**

| Signal | Route to Fast OCR | Route to Vision OCR |
|--------|-------------------|---------------------|
| Has embedded text + < 3 pages | Yes | |
| Native PDF (not scanned) | Yes | |
| File size < 500KB + single page | Yes | |
| Scanned PDF > 10 pages | | Yes |
| Image files (JPEG, PNG, TIFF) | | Yes |
| File size > 5MB | | Yes |
| Ambiguous (partial text, 3-10 pages) | → LLM pre-screen | |

**FR-TR3 — LLM pre-screen for ambiguous documents:**
- When heuristics can't decide (e.g., 3-page PDF with partial embedded text), send the first page to a small/fast model for a complexity assessment.
- The pre-screen model returns a single decision: `fast` or `vision`.
- The pre-screen model is configurable (default: smallest available model, e.g., qwen3:1.7b).
- Pre-screen is optional — can be disabled in settings. When disabled, ambiguous docs default to Vision OCR.

**FR-TR4 — Triage thresholds are editable** in the dashboard settings modal (Pipeline tab). Changes take effect immediately for the next document.

**Open question — OQ-TRIAGE-1: Does visual complexity (dense tables, forms) cause Vision OCR to be disproportionately slow?**
Observation (2026-04-08): a multi-table Austrian medical referral form (Überweisung, ÄrzteZentrale, doc #25) ran for 14+ minutes in Vision OCR (qwen2.5vl:7b) without completing. Tesseract had already extracted key fields ("JONES Xander", doctor name) correctly in Stage 1. It is unknown whether the slowness was caused by the table-heavy layout, document length, model behaviour on this specific content, or an unrelated issue.

Questions to answer before finalising triage heuristics:
- Does Vision OCR consistently slow down on form/table-heavy documents vs plain-text scans?
- Was Tesseract quality sufficient for classification on this doc? (Check Content tab in Paperless)
- Is checking Tesseract word count/quality a reliable fast-path signal?

Until answered, do not assume visual complexity alone is a triage signal.

### 4.2 OCR Paths

**FR-OCR1 — Fast OCR path:**
- Uses Tesseract (CPU-only, already running inside Paperless-ngx).
- For docs with embedded text: skips OCR entirely, uses existing text.
- For simple scanned docs: Tesseract extracts text. No GPU model involved.
- Result: extracted text ready for Rule Engine.

**FR-OCR2 — Vision OCR path:**
- Same as current Stage 2: paperless-gpt sends pages to the vision model (qwen2.5vl:7b).
- For complex, handwritten, or poor-quality scans.
- Requires GPU (model load + inference).
- Result: higher-quality extracted text ready for Rule Engine.

**FR-OCR3 — OCR model is configurable** in dashboard settings. Vision OCR model can be changed without restarting the pipeline.

### 4.3 Rule Engine (Fuzzy Text Matching)

Runs after OCR, before LLM classification. Matches extracted text against user-defined rules.

**FR-RE1 — Rule structure:**

```yaml
# Example rule
- id: "deutsche_telekom"
  name: "Deutsche Telekom invoices"
  pattern: "Deutsche Telekom"
  match_type: contains          # exact | contains | fuzzy | regex
  confidence_threshold: 80      # 0-100
  case_sensitive: false
  actions:
    tags: ["Utilities", "Finance"]
    document_type: "Invoice"
    correspondent: "Deutsche Telekom"
  priority: 10                  # lower = higher priority
  enabled: true
```

**FR-RE2 — Match types:**
- **exact**: Pattern must match the full text exactly (rarely useful).
- **contains**: Pattern appears anywhere in the text (case-insensitive by default).
- **fuzzy**: Levenshtein distance / similarity score. Matches if similarity ≥ confidence threshold. Useful for OCR typos ("Deutche Telekom" still matches).
- **regex**: Full regex pattern matching.

**FR-RE3 — Execution:**
- Rules are ordered by priority (lowest number = highest priority).
- Rules are evaluated sequentially. First match above confidence threshold wins.
- If a rule matches at ≥ 80% confidence: document is tagged immediately. **No LLM call.**
- If no rule matches (or all below threshold): document proceeds to LLM classification.
- Multi-match mode (optional, off by default): apply ALL matching rules instead of first-match.

**FR-RE4 — Rule storage:**
- Rules persist in `dashboard/config/rules.yaml` (version-controlled, human-readable).
- Loaded into memory on dashboard startup. Reloaded when rules are added/edited via UI.

**FR-RE5 — Rule stats:**
- Each rule tracks: hit count, last matched timestamp, last matched doc ID.
- Stats displayed in the rule editor UI.

### 4.4 LLM Classification (Unmatched Docs Only)

**FR-LLM1:** Receives only documents that the Rule Engine couldn't classify. The LLM prompt is focused:

> "This document didn't match any known patterns. Classify it based on its content. Assign tags, document type, and correspondent from the available taxonomy."

No pattern-matching instructions in the prompt. The LLM does what it's good at: understanding ambiguous content.

**FR-LLM2 — Rule suggestion output:**
After classifying, the LLM also returns a proposed rule:

```json
{
  "classification": {
    "tags": ["Insurance"],
    "document_type": "Letter",
    "correspondent": "Allianz Versicherung"
  },
  "suggested_rule": {
    "pattern": "Allianz Versicherung",
    "match_type": "contains",
    "reasoning": "Sender name 'Allianz Versicherung' appears in header. Future documents from this sender should match."
  }
}
```

**FR-LLM3:** The suggested rule is added to the suggestions queue (§4.5). It does NOT take effect automatically — the user must approve it.

**FR-LLM4 — LLM model is configurable** in dashboard settings. Supports Ollama native and OpenAI-compatible API formats (forward-compatible with [PRD 3 Hybrid Cloud](prd-hybrid-cloud.md) for Bedrock/cloud LLMs).

### 4.5 Suggestions Queue

A dedicated section on the dashboard, below the service cards.

**FR-SQ1:** Each suggestion shows:
- The document that triggered it (title, doc ID, link to Paperless).
- The proposed rule: pattern, match type, confidence threshold, actions.
- The LLM's reasoning for the suggestion.
- Timestamp of when it was suggested.

**FR-SQ2:** Actions per suggestion:
- **Approve** — adds to rule engine immediately. Future matching docs skip the LLM.
- **Edit & Approve** — opens the rule editor pre-filled with the suggestion. User tweaks before saving.
- **Reject** — dismisses the suggestion permanently.
- **Ignore** — hides from the queue but keeps for analytics.

**FR-SQ3:** Suggestions persist in QuestDB (for analytics) and in `dashboard/config/suggestions.json` (for the queue UI).

**FR-SQ4:** Dashboard shows a badge count of pending suggestions in the header (e.g., "3 suggestions").

### 4.6 Dashboard Integration

This PRD extends the dashboard from [PRD 1](prd-dashboard-visibility.md).

**FR-DI1 — Swimlane chart extensions:**
New stage colors added to the timeline:
- **Triage**: grey
- **Fast OCR**: light blue (distinct from current Ingest blue)
- **Vision OCR**: orange (same as current)
- **Rule Engine**: purple
- **LLM Classify**: green (same as current)
- Skipped stages are not shown (e.g., a doc matched by rules has no green LLM bar).

**FR-DI2 — Settings modal extensions (Pipeline tab becomes editable):**
- Triage thresholds (page count cutoffs, file size thresholds).
- Toggle for LLM pre-screen on ambiguous docs.
- OCR model selection.
- LLM model selection + API format.
- Toggle for rule suggestions.

**FR-DI3 — Settings modal new tab (Rules):**
- Full CRUD for fuzzy matching rules.
- Each rule row shows: name, pattern, match type, confidence, hit count, last matched.
- "Test rule" button: paste text or select a doc, see match result + confidence.
- Import/export rules as YAML.

**FR-DI4 — Suggestions queue section** on the main dashboard page.

### 4.7 Pipeline Events (Extended Schema)

Extends the QuestDB `pipeline_events` table from PRD 1:

```sql
CREATE TABLE IF NOT EXISTS pipeline_events (
  ts           TIMESTAMP,        -- event time (nanosecond precision)
  doc_id       LONG,
  stage        SYMBOL,           -- triage | ocr_fast | ocr_vision | rule_engine | llm_classify
  event        SYMBOL,           -- start | end | error | skip
  model        SYMBOL,           -- tesseract | qwen2.5vl:7b | qwen3:14b | rule:<rule_id>
  duration_ms  INT,              -- null on start events; populated on end events
  route        SYMBOL,           -- triage output: fast | vision
  matched      BOOLEAN,          -- rule_engine: did a rule match?
  rule_name    SYMBOL,           -- which rule matched (null if none)
  pages        INT
) TIMESTAMP(ts) PARTITION BY DAY;
```

The dashboard swimlane chart queries this table by `doc_id`, pairs `start`/`end` events per stage, and renders a horizontal timeline bar per stage — color-coded by stage type, labeled with model name and duration in ms.

### 4.8 API Routes (New/Extended)

| Route | Method | Description |
|-------|--------|-------------|
| `/api/rules` | GET | All fuzzy matching rules |
| `/api/rules` | POST | Create a new rule |
| `/api/rules/:id` | PUT | Update a rule |
| `/api/rules/:id` | DELETE | Delete a rule |
| `/api/rules/test` | POST | Test a rule against provided text, returns match + confidence |
| `/api/suggestions` | GET | Pending LLM rule suggestions |
| `/api/suggestions/:id` | POST | Approve/reject/ignore a suggestion |
| `/api/pipeline/config` | GET | Current pipeline configuration (thresholds, models) |
| `/api/pipeline/config` | PUT | Update pipeline configuration |

---

## 5. Non-Goals / Out of Scope

- **No custom orchestration code** — Kestra handles DAG execution, branching, and retry logic. No bespoke pipeline runner.
- **No ML-based triage** — triage uses metadata heuristics + optional LLM pre-screen, not a trained classifier.
- **No automatic rule promotion** — all rules require human approval. No "auto-add after N matches."
- **No document re-processing UI** — bulk re-processing (FR-US8) is a CLI/script operation, not a dashboard button (for now).
- **No rule versioning** — rules are current state only. Version history is via git (rules.yaml is committed).
- **No cross-document learning** — rules match individual documents. No clustering or similarity-based grouping.
- **No cloud deployment of the pipeline itself** — pipeline services run locally. [PRD 3](prd-hybrid-cloud.md) handles moving individual services (like the LLM) to the cloud.

---

## 6. Design Considerations

### Suggestions Queue UI

```
┌──────────────────────────────────────────────────────────────────┐
│  Rule Suggestions (3 pending)                                    │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ Doc #87 "Rechnung Telekom März 2026"                       │  │
│  │ Pattern: "Deutsche Telekom"  Type: contains                │  │
│  │ → Tags: Utilities, Finance  Type: Invoice  Corr: Telekom   │  │
│  │ Reason: "Sender name in header, recurring monthly invoice" │  │
│  │                                                            │  │
│  │ [Approve]  [Edit & Approve]  [Reject]  [Ignore]           │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ Doc #89 "Allianz Versicherung Schreiben"                   │  │
│  │ ...                                                        │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

### Rule Editor UI (Settings → Rules tab)

```
┌──────────────────────────────────────────────────────────────────┐
│  Rules (12 active)                          [+ New Rule] [Import]│
├──────────────────────────────────────────────────────────────────┤
│  Name            │ Pattern          │ Type    │ Hits │ Last      │
│  ────────────────┼──────────────────┼─────────┼──────┼────────── │
│  Deutsche Telekom│ Deutsche Telekom │ contains│  47  │ 2 days ago│
│  Allianz         │ Allianz Versich. │ fuzzy   │  12  │ 1 week    │
│  Dr. Müller      │ Dr\. Müller      │ regex   │   8  │ yesterday │
│  Wien Energie    │ Wien Energie     │ contains│  23  │ 3 days    │
├──────────────────────────────────────────────────────────────────┤
│  Test Rule:                                                      │
│  [paste document text here...]          [Test] → Match: 92%     │
└──────────────────────────────────────────────────────────────────┘
```

---

## 7. Technical Considerations

### Architecture: Container-per-Step DAG

Each pipeline stage runs as an independent Docker container. Stages are wired together as a DAG by **Kestra**, a lightweight declarative workflow orchestrator added to `compose.yaml`. The dashboard (Next.js) remains the UI layer for rules, suggestions, and pipeline visibility — it is not the orchestrator.

```
Paperless webhook → Kestra (new compose service)
                         │
                   [YAML Flow DAG]
                         │
         ┌───────────────┼────────────────┐
         ▼               ▼                ▼
     triage          ocr-fast         ocr-vision
     container       container        container
         │           (if fast)        (if vision)
         └───────────────┼────────────────┘
                         ▼
                   rule-engine
                   container
                    │         │
               matched     unmatched
                  ▼              ▼
                done       llm-classify
                           container
                               ▼
                     suggestion → QuestDB → dashboard
```

Kestra replaces both `paperless-gpt` and `paperless-ai-next`. The Paperless Workflow that previously fired to `paperless-ai-next` now fires to the Kestra webhook trigger.

### Step Container Contract

Every step container exposes a standard interface:

**Input (environment variables injected by Kestra):**
```
DOCUMENT_ID        — Paperless document ID
STEP_CONFIG        — JSON string with step-specific parameters
WORKSPACE_DIR      — Shared volume path: /pipeline-workspace/<doc_id>/
QUESTDB_URL        — http://questdb:9000 (for event emission)
PAPERLESS_URL      — http://paperless:8000
PAPERLESS_TOKEN    — API token (from Kestra secrets)
OLLAMA_URL         — http://ollama:11434 (where applicable)
```

**Output (one JSON line to stdout):**
```json
{ "status": "ok", "route": "fast", "matched": false, "rule_name": null, "metadata": {} }
```

**Exit codes:** `0` = success, `1` = error, `2` = skip (step not applicable)

Kestra reads stdout JSON and maps fields to flow variables for branching conditions (`Switch`, `If`).

### Step Containers

| Step | Replaces | Language | Key Logic |
|---|---|---|---|
| `triage` | (new) | Python | PyMuPDF reads PDF metadata; outputs `route: fast\|vision` |
| `ocr-fast` | Tesseract inside paperless-ngx | Python | Calls Paperless API to retrieve Tesseract-extracted text; no GPU |
| `ocr-vision` | `paperless-gpt` | Python | Calls Ollama `qwen2.5vl:7b` directly; replaces paperless-gpt polling |
| `rule-engine` | (new) | Python | Loads `rules.yaml`, runs fuzzy/regex matching; outputs `matched`, `rule_name` |
| `llm-classify` | `paperless-ai-next` | Python | Calls Ollama `qwen3:14b`; outputs classification + `suggested_rule` |

All step containers extend a shared base image (`paperless-pipeline/base:latest`) that provides the `emit_event()` helper — ensuring no step can skip lifecycle event emission.

### Lifecycle Events (first-class requirement)

Every step container emits two events to QuestDB's line protocol ingestion API: `stage_start` at container startup and `stage_end` before exit. The dashboard reads these events per `doc_id` and renders a swimlane timeline.

```python
# Base image helper — used by every step
def emit_event(doc_id: int, stage: str, event: str,
               model: str = "", duration_ms: int = 0, **extra):
    line = (
        f"pipeline_events,doc_id={doc_id},stage={stage},event={event} "
        f"model=\"{model}\",duration_ms={duration_ms}i "
        f"{int(time.time() * 1e9)}"
    )
    requests.post(f"{os.environ['QUESTDB_URL']}/api/v1/write", data=line)
```

### Kestra DAG (Flow YAML)

Stored at `kestra/flows/paperless-document-pipeline.yaml`:

```yaml
id: paperless-document-pipeline
namespace: paperless
triggers:
  - id: webhook
    type: io.kestra.plugin.core.trigger.Webhook
    key: "{{ secret('KESTRA_WEBHOOK_KEY') }}"

tasks:
  - id: triage
    type: io.kestra.plugin.docker.Run
    containerImage: paperless-pipeline/triage:latest
    env:
      DOCUMENT_ID: "{{ trigger.body.document_id }}"
    outputFiles: ["result.json"]
    volumes: ["/pipeline-workspace/{{ trigger.body.document_id }}:/workspace"]

  - id: branch_ocr
    type: io.kestra.plugin.core.flow.Switch
    value: "{{ outputs.triage.vars.route }}"
    cases:
      fast:
        - id: ocr_fast
          type: io.kestra.plugin.docker.Run
          containerImage: paperless-pipeline/ocr-fast:latest
      vision:
        - id: ocr_vision
          type: io.kestra.plugin.docker.Run
          containerImage: paperless-pipeline/ocr-vision:latest
          env:
            OLLAMA_URL: "http://ollama:11434"

  - id: rule_engine
    type: io.kestra.plugin.docker.Run
    containerImage: paperless-pipeline/rule-engine:latest
    volumes: ["/pipeline-workspace/rules:/rules:ro"]
    outputFiles: ["result.json"]

  - id: llm_classify
    type: io.kestra.plugin.core.flow.If
    condition: "{{ outputs.rule_engine.vars.matched == false }}"
    then:
      - id: classify
        type: io.kestra.plugin.docker.Run
        containerImage: paperless-pipeline/llm-classify:latest
        env:
          OLLAMA_URL: "http://ollama:11434"
```

### compose.yaml Changes

Add Kestra (mounts Docker socket to run step containers):

```yaml
kestra:
  image: kestra/kestra:latest
  ports:
    - "8090:8080"      # Kestra UI + API
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock
    - ./kestra/flows:/flows
    - ./pipeline-workspace:/pipeline-workspace
  depends_on:
    - postgres
```

Kestra uses the existing `postgres` container (a second database within the same instance). Remove `paperless-gpt` and `paperless-ai-next` services after shadow-run validation.

### Rule Engine Implementation

The rule engine runs as a Python container, not as TypeScript inside the dashboard. The dashboard manages the `rules.yaml` file via its API (`/api/rules`), which the `rule-engine` container mounts read-only.

Rule data model (unchanged from §4.3, now implemented in Python):

```python
@dataclass
class Rule:
    id: str
    name: str
    pattern: str
    match_type: Literal["exact", "contains", "fuzzy", "regex"]
    confidence_threshold: int  # 0-100
    case_sensitive: bool
    actions: dict              # tags, document_type, correspondent
    priority: int
    enabled: bool

@dataclass
class MatchResult:
    matched: bool
    rule: Rule | None
    confidence: float
    matched_text: str
```

**Fuzzy matching** uses `rapidfuzz` (Python, C extension, ~3x faster than `python-Levenshtein`). For 500-word document against 100 rules: expected < 50ms.

### LLM Prompt Design

The classification prompt is intentionally lean:

```
You are classifying a document that didn't match any known patterns.

Available taxonomy:
- Tags: {tag_list}
- Document types: {type_list}
- Correspondents: {correspondent_list}

Document text (first 2000 chars):
{text}

Respond in JSON:
{
  "tags": ["..."],
  "document_type": "...",
  "correspondent": "...",
  "suggested_rule": {
    "pattern": "the key identifying text you used",
    "match_type": "contains",
    "reasoning": "why this pattern identifies this class of document"
  }
}
```

No pattern-matching instructions. No "if X then Y" lists. The taxonomy list is the only context. This keeps the prompt under 1000 tokens for most cases.

### Migration from Current Pipeline

The current pipeline (Tesseract → paperless-gpt → paperless-ai-next) continues to work unchanged. The smart pipeline runs in parallel initially:

1. **Week 1:** Kestra pipeline runs on new documents but only logs decisions (no writes to Paperless). Compare its routing/classification decisions with the current pipeline's results.
2. **Week 2:** Kestra pipeline handles new documents. Current pipeline is fallback.
3. **Week 3+:** Remove `paperless-gpt` and `paperless-ai-next` from `compose.yaml`. Kestra is primary.

This avoids a risky cutover and lets the rule engine build up suggestions during the comparison period.

### LLM Prompt Design

The classification prompt is intentionally lean:

```
You are classifying a document that didn't match any known patterns.

Available taxonomy:
- Tags: {tag_list}
- Document types: {type_list}
- Correspondents: {correspondent_list}

Document text (first 2000 chars):
{text}

Respond in JSON:
{
  "tags": ["..."],
  "document_type": "...",
  "correspondent": "...",
  "suggested_rule": {
    "pattern": "the key identifying text you used",
    "match_type": "contains",
    "reasoning": "why this pattern identifies this class of document"
  }
}
```

No pattern-matching instructions. No "if X then Y" lists. The taxonomy list is the only context. This keeps the prompt under 1000 tokens for most cases.

### Migration from Current Pipeline

The current pipeline (Tesseract → paperless-gpt → paperless-ai-next) continues to work unchanged. The smart pipeline runs in parallel initially:

1. **Week 1:** Smart pipeline logs decisions but doesn't act. Compare its routing/classification with the current pipeline's results.
2. **Week 2:** Smart pipeline handles new documents. Current pipeline is fallback.
3. **Week 3+:** Current pipeline disabled. Smart pipeline is primary.

This avoids a risky cutover and lets the rule engine build up suggestions during the comparison period.

---

## 8. Success Metrics

| Metric | Target |
|--------|--------|
| Triage routes simple docs to fast path | > 80% of 1-page text PDFs |
| Rule engine handles known patterns | > 60% of docs skip LLM after 30 days |
| Rule engine match latency | < 100ms per document |
| LLM classification (when needed) | < 30s per document |
| Suggestion approval rate | > 50% of LLM suggestions approved |
| No classification regression | 0 documents misclassified vs. current pipeline |
| Triage decision time | < 500ms per document |

---

## 9. Open Questions

| # | Question | Owner | Notes |
|---|----------|-------|-------|
| OQ1 | ~~How does the smart pipeline integrate with paperless-gpt?~~ | ~~Implementation~~ | **Resolved:** `paperless-gpt` is replaced by the `ocr-vision` step container. The `ocr-fast` step uses the Tesseract text already extracted by Paperless-ngx via API. The `ocr-pending` / `classification-pending` tag workflow is replaced by the Kestra webhook trigger fired from Paperless Workflow 1. |
| OQ2 | Should the triage LLM pre-screen use a separate model? | Marcus | qwen3:1.7b is fast but requires a model swap if the main model is larger. Could use the same model with a shorter prompt instead. |
| OQ3 | Fuzzy matching library — `python-Levenshtein` vs `rapidfuzz`? | Implementation | `rapidfuzz` is the modern replacement: faster (C extension), same API, handles partial ratios and multi-string scoring. Use `rapidfuzz`. |
| OQ4 | Should rules be able to set custom field values (Amount, PaidBy, etc.)? | Marcus | Current scope is tags + document type + correspondent. Custom field extraction is more complex — likely needs the LLM. |
| OQ5 | Bulk re-processing — how to run the rule engine against existing 300+ docs? | Implementation | Script that fetches all docs from Paperless API, calls the `rule-engine` container per doc (or in batch), reports matches. Doesn't auto-apply — shows a preview. |
| OQ6 | ~~Should paperless-ai-next be absorbed into the dashboard?~~ | ~~Marcus~~ | **Resolved:** `paperless-ai-next` is replaced by the `llm-classify` step container. Both `paperless-gpt` and `paperless-ai-next` are removed from `compose.yaml` after shadow-run validation (see §7 Migration). |
