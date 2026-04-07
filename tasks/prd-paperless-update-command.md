# PRD: `/paperless-update` — Paperless-ngx Config Command

**Status:** Draft — v2 (OQ1 + OQ2 resolved)  
**Author:** Marcus Jones  
**Date:** 2026-04-07

---

## 1. Introduction / Overview

Today, Paperless-ngx taxonomy (tags, document types, custom fields, workflows, saved views) is managed two ways:

1. **`scripts/bootstrap.sh`** — a hand-crafted bash script that creates the initial state via the Paperless REST API. It's idempotent but append-only: there is no way to update or delete items, and adding something new means hand-editing bash.
2. **Manual UI clicks** — any change made post-bootstrap in the web UI is not tracked anywhere and will be lost on a fresh stack.

This PRD specifies a Claude Code custom command (`/paperless-update`) that:

- Uses `scripts/paperless-config.yaml` as the **single source of truth** for all Paperless-ngx entities.
- Applies changes from the YAML to a live Paperless instance via its REST API (CREATE, UPDATE, DELETE).
- **Regenerates the relevant section of `scripts/bootstrap.sh`** from the YAML so a fresh stack always produces the same state.

The command is invoked as `/paperless-update` inside a Claude Code session. It supports two primary modes: **push** (apply YAML → live API) and **pull** (read live API → write YAML, for initial adoption of existing state). Claude reads the YAML, queries the live API, computes a diff, and applies changes — keeping code and runtime in sync.

---

## 2. Goals

| # | Goal | Measurable outcome |
|---|------|--------------------|
| G1 | Single source of truth for taxonomy | All entity definitions live in `scripts/paperless-config.yaml`; nothing hand-coded in bootstrap.sh |
| G2 | Full CRUD on all five entity types | Command can CREATE, UPDATE, and DELETE tags, document types, custom fields, workflows, and saved views |
| G3 | Safe deletes | No item is deleted without explicit per-item confirmation from the user |
| G4 | bootstrap.sh stays in sync | After every command run, bootstrap.sh is regenerated from the YAML so `./scripts/bootstrap.sh` reproduces the live state |
| G5 | Idempotent creates | Running the command twice with no YAML changes is a no-op (skip & report existing items) |
| G6 | Self-contained auth | Token sourced from root `.env` (`PAPERLESS_API_TOKEN`); no token prompt at runtime |
| G7 | Pull mode for adoption | `--pull` reads live API and writes/merges into YAML + bootstrap.sh so existing state is never lost |
| G8 | Per-tag AI hints | `ai_hint` on any tag gets compiled into `SYSTEM_PROMPT` in `paperless-ai-next/.env`; `PROMPT_TAGS` auto-generated from non-pipeline tags |
| G9 | Doc type → custom field attachment | Declaring `custom_fields` on a document type auto-generates a managed workflow that attaches those fields to documents when classified |

---

## 3. User Stories

**US1.** As a homelab operator, I want to add a new tag to the YAML and run `/paperless-update` so the tag appears in Paperless-ngx and in bootstrap.sh without me touching bash.

**US2.** As a homelab operator, I want to add a custom field definition to the YAML so it is created in the live system and will be recreated on a fresh stack.

**US3.** As a homelab operator, I want to rename or recolour a tag in the YAML and have the live system updated without having to find the item's numeric ID.

**US4.** As a homelab operator, I want to remove a tag from the YAML and have the command ask me to confirm before it deletes from the live system.

**US5.** As a homelab operator, I want to define a saved view in the YAML so I don't have to recreate it after every stack rebuild.

**US6.** As a homelab operator, I want to run the command in dry-run mode to preview what would change without touching the live system.

**US7.** As a homelab operator with an existing Paperless stack (tags, views, etc. created via the UI), I want to run `/paperless-update --pull` to adopt my current live state into the YAML so I have a complete source of truth from day one — without losing anything.

**US8.** As a homelab operator, I want workflow trigger and action types written as `document_added` / `assign_tag` in the YAML instead of magic integers, so I can read and edit the config without cross-referencing API docs.

**US9.** As a homelab operator, I want to add an `ai_hint` to a tag in the YAML and have that hint automatically compiled into the paperless-ai-next `SYSTEM_PROMPT`, so qwen3:14b gets explicit guidance on when to assign that tag — without me manually editing a long environment variable string.

---

## 4. Functional Requirements

### 4.1 Command Invocation

**FR-01.** The command is invoked as `/paperless-update [flags]` inside a Claude Code session.  
**FR-02.** Supported flags:
- `--dry-run` — print what would change, make no API calls (except reads)
- `--pull` — reverse direction: read live Paperless state → write/merge into `scripts/paperless-config.yaml` (see §4.7)
- `--entity <type>` — limit run to one entity type: `tags`, `document_types`, `custom_fields`, `workflows`, `saved_views`
- `--apply` — skip confirmation for creates and updates (deletes still prompt)

### 4.2 Config File

**FR-03.** The command reads `scripts/paperless-config.yaml` relative to the repo root.  
**FR-04.** The YAML file has top-level keys for each entity type. Example structure (authoritative — implementation must match this schema):

```yaml
# scripts/paperless-config.yaml
# Single source of truth for Paperless-ngx taxonomy.

tags:
  - name: Finance
    color: "#808080"
    children:
      - name: Tax
      - name: Insurance
      - name: Banking
  - name: paperless-gpt-ocr-auto
    matching_algorithm: none
    match: ""
  - name: Altenberg
    matching_algorithm: literal
    match: "St. Andra-Wörden"
    is_insensitive: true
    ai_hint: "Assign when the document relates to the municipality of Altenberg,
              the village of St. Andrä-Wördern, or addresses in Hoflein."

  - name: health-xnc
    ai_hint: "Assign when the document is a medical invoice, receipt, or letter
              concerning a child. Look for a child's name in the document."

  - name: Tax
    ai_hint: "Assign for tax returns, assessments, or correspondence from
              Finanzamt (Austrian/German tax authority)."

document_types:
  - name: Invoice
    custom_fields:
      - Amount
      - Paid
  - name: Contract
  - name: Receipt
    custom_fields:
      - Amount
      - Paid
  - name: Medical Invoice
    custom_fields:
      - Amount
      - Paid
      - Submitted OEGKK
      - Submitted Allianz
      - Reimbursed OEGKK
      - Reimbursed Allianz

# Global custom field definitions — referenced by name from document_types above.
# Fields are created as global Paperless entities; the doc-type association is
# enforced via auto-generated workflows (see §4.9).
custom_fields:
  - name: Status
    data_type: select        # select | text | date | monetary | integer | float | url | boolean
    select_options:
      - label: Inbox
      - label: Action needed
      - label: Waiting
      - label: Done
  - name: Amount
    data_type: monetary
  - name: Paid
    data_type: boolean
  - name: Submitted OEGKK
    data_type: date
  - name: Submitted Allianz
    data_type: date
  - name: Reimbursed OEGKK
    data_type: date
  - name: Reimbursed Allianz
    data_type: date

workflows:
  - name: Auto Vision OCR
    order: 1
    enabled: true
    triggers:
      - type: document_added
        sources: ["1", "2", "3"]
        matching_algorithm: none
        filter_has_tags: []
        filter_has_all_tags: []
        filter_has_not_tags: []
    actions:
      - type: assign_tag
        assign_tags:
          - ref: paperless-gpt-ocr-auto    # resolved to numeric ID at runtime

saved_views:
  - name: Inbox
    sort_field: created
    sort_reverse: true
    filter_rules:
      - rule_type: 17        # 17=custom field value equals
        value: "Inbox"
        custom_field: Status

# AI classification config — compiled into paperless-ai-next/.env
ai_classification:
  system_prompt_base: |
    You are a document classifier for a personal document management system.
    Analyse the document text and return a JSON object with: title, tags, correspondent,
    document_type, and custom_fields. Only assign tags from the approved list.
    Prefer specific tags over general ones. If uncertain, omit rather than guess.
  # Per-tag ai_hint entries are compiled into a "Tag assignment rules:" section
  # and injected between the base prompt and the closing instruction.
```

**FR-05.** Tag references in workflows (`ref: <tag-name>`) are resolved by the command to live numeric IDs before the API call — the user never has to know IDs.  
**FR-06.** Custom field references in saved view filter rules (`custom_field: Status`) are similarly resolved to IDs at runtime.

### 4.3 Auth

**FR-07.** The command reads `PAPERLESS_API_TOKEN` from the root `.env` file (same logic as bootstrap.sh lines 22-41).  
**FR-08.** If the token is missing or is the placeholder value, the command prints an actionable error and exits.  
**FR-09.** The Paperless API base URL defaults to `http://localhost:8000/api`. The command verifies the API is reachable before any writes.

### 4.4 Diff / Apply Logic

**FR-10.** For each entity type, the command:
1. Fetches all existing items from the live API (paginated, `page_size=200`).
2. Compares by **name** against the YAML.
3. Classifies each YAML item as: **new** (create), **changed** (update), or **unchanged** (skip).
4. Classifies items present in the live API but absent from the YAML as: **orphan** (candidate for delete).

**FR-11.** Creates: send `POST` to the relevant endpoint. On 201, report created. On 400, report already-exists (treat as success, update YAML if needed).  
**FR-12.** Updates: send `PATCH` to the item's ID endpoint with only the changed fields.  
**FR-13.** Orphan / Delete flow:
1. List each orphan with its name and ID.
2. Ask the user to confirm each deletion individually using `AskUserQuestion`.
3. Only send `DELETE` if the user confirms. Otherwise, leave it.

**FR-14.** Unchanged items are silently skipped (no output unless `--verbose`).  
**FR-15.** In `--dry-run` mode, steps FR-11 through FR-13 print what **would** happen but make no API calls.

### 4.5 Entity-Specific Rules

**Tags**
- **FR-16.** Nested tags: create the parent first (capture its ID), then create children with `"parent": <id>`.
- **FR-17.** After creating/updating a tag, if the YAML entry has `matching_algorithm`, apply it via `PATCH`.

**Custom Fields**
- **FR-18.** `select` type: include `extra_data.select_options` array with `{"label": "...", "id": "<n>"}` where `id` is the 1-based string index.
- **FR-19.** The Paperless API does not support updating select options on an existing custom field. If options differ, report the mismatch and tell the user to delete and recreate the field manually (or via `--entity custom_fields` with delete confirmation).
- **FR-48.** (See §4.9) — field names referenced in `document_types[].custom_fields` are validated against the `custom_fields` top-level list before any API calls.

**Document Types**
- **FR-49.** Document types are created first (before auto-workflows), so their IDs are available when generating field-attachment workflows.
- **FR-50.** The `custom_fields` key on a document type is metadata for the command — it is NOT sent to the Paperless `/api/document_types/` endpoint (the API has no such field). It only controls auto-workflow generation (§4.9).

**Workflows**
- **FR-20.** Workflows reference tags by name (`ref: <name>`). The command resolves these to IDs before posting.
- **FR-21.** Workflow actions of type `webhook` include the `webhook` sub-object verbatim from the YAML.
- **FR-22.** The `x-api-key` header value in webhook actions reads `PAPERLESS_AI_NEXT_API_KEY` from root `.env`.
- **FR-23a.** Trigger `type` and action `type` fields in the YAML use **human-readable strings**, not integers. The command translates them to the Paperless integer codes before any API call, and back to strings on pull. Mapping:

  **Trigger types:**
  | YAML string | API integer | Meaning |
  |---|---|---|
  | `consumption_started` | 1 | Document entering consume folder |
  | `document_added` | 2 | Document created in Paperless |
  | `document_updated` | 3 | Document metadata changed |
  | `document_deleted` | 4 | Document removed |

  **Action types:**
  | YAML string | API integer | Meaning |
  |---|---|---|
  | `assign_tag` | 1 | Add tag(s) to document |
  | `assign_correspondent` | 2 | Set correspondent |
  | `assign_document_type` | 3 | Set document type |
  | `webhook` | 4 | POST to an external URL |
  | `assign_view` | 5 | Add to saved view |
  | `assign_custom_field` | 6 | Set a custom field value |
  | `remove_tag` | 7 | Remove tag(s) |
  | `email` | 8 | Send email |

  **Matching algorithm** (used in tags and trigger filters):
  | YAML string | API integer |
  |---|---|
  | `none` | 0 |
  | `any_word` | 1 |
  | `all_words` | 2 |
  | `literal` | 3 |
  | `regex` | 4 |
  | `fuzzy` | 5 |
  | `auto` | 6 |

**Saved Views**
- **FR-23.** Filter rules that reference a custom field by name resolve to the field's numeric ID via a live API lookup.
- **FR-24.** Saved views support `sort_field`, `sort_reverse`, and a list of `filter_rules` objects with `rule_type` and `value`.

### 4.8 AI Classification Config

This section explains the two matching layers and how the YAML bridges them.

#### Background: two matching layers

| Layer | When | Input text | What it can assign |
|---|---|---|---|
| **Built-in Paperless matching** | Stage 1 (ingest) | Tesseract OCR — potentially noisy | Tags, correspondents, doc types, storage paths |
| **AI classification** (paperless-ai-next) | Stage 3 (after vision OCR) | High-quality vision OCR text | Tags, correspondent, doc type, title, custom fields |

The layers **stack**: built-in matching pre-assigns obvious cases fast (e.g. literal "St. Andrä-Wördern" → Altenberg tag). The AI then runs on better text and can confirm, add, or correct.

#### Per-tag AI hints

**FR-35.** Any tag in the YAML may include an optional `ai_hint` string field:
```yaml
tags:
  - name: Altenberg
    matching_algorithm: literal
    match: "St. Andra-Wörden"
    ai_hint: "Assign when the document relates to the municipality of Altenberg..."
```

**FR-36.** The `ai_hint` field is **not** sent to the Paperless-ngx API. It is only used to compile the `SYSTEM_PROMPT` for paperless-ai-next.

**FR-37.** When the command runs (push or pull), it compiles all `ai_hint` entries into a structured block and injects it into the `SYSTEM_PROMPT` in `paperless-ai-next/.env`. The compiled format:
```
Tag assignment rules (follow these before general reasoning):
- "Altenberg": Assign when the document relates to the municipality of Altenberg, the village of St. Andrä-Wördern, or addresses in Hoflein.
- "health-xnc": Assign when the document is a medical invoice, receipt, or letter concerning a child. Look for a child's name in the document.
- "Tax": Assign for tax returns, assessments, or correspondence from Finanzamt.
```

**FR-38.** The full `SYSTEM_PROMPT` is assembled as:
```
{system_prompt_base from YAML}

Tag assignment rules (follow these before general reasoning):
{compiled ai_hint lines — one per tag that has ai_hint}

Only use tags from this approved list: {PROMPT_TAGS list from paperless-ai-next/.env}
Return a JSON object with keys: title, tags, correspondent, document_type.
```

**FR-39.** `system_prompt_base` is a top-level key under `ai_classification` in the YAML. If absent, the command uses a sensible default preamble.

**FR-40.** The command writes the assembled `SYSTEM_PROMPT` to `paperless-ai-next/.env` under the key `SYSTEM_PROMPT=`. It preserves all other keys in that file.

**FR-41.** The `PROMPT_TAGS` list in `paperless-ai-next/.env` is also regenerated from the YAML: it is the list of all tag names that are **not** pipeline tags (i.e., not `paperless-gpt-ocr-auto`, `ai-process`, `ai-processed`). Tags can be flagged `pipeline_tag: true` in the YAML to exclude them from `PROMPT_TAGS`.

**FR-42.** On `--pull`, `ai_hint` fields are **not** reverse-synced from the live API (the API has no concept of hints). Existing `ai_hint` fields in the YAML are preserved verbatim during a pull merge.

### 4.9 Auto-Generated Field-Attachment Workflows

Paperless-ngx has no native "document type → show these fields" feature. Custom fields attach to a specific **document** (not a type) by having a value assigned to them. To make fields appear automatically when the AI classifies a document as type X, the command generates managed workflows.

**FR-43.** For each document type in the YAML that has a non-empty `custom_fields` list, the command creates a workflow named:
```
[auto] Attach fields: {document_type_name}
```

**FR-44.** The generated workflow structure:
```yaml
name: "[auto] Attach fields: Medical Invoice"
order: 100          # high order number — runs after user-defined workflows
enabled: true
triggers:
  - type: document_updated
    filter_has_document_type: Medical Invoice   # resolved to ID at runtime
actions:
  - type: assign_custom_field
    assign_custom_fields:
      - field: Submitted OEGKK   # each field resolved to ID at runtime
        value: null               # null = add field to document with no value set
      - field: Submitted Allianz
        value: null
      # ... one entry per field in custom_fields list
```

**FR-45.** `[auto]`-prefixed workflows are **fully managed** — they are recreated from the YAML on every push and never prompt for delete confirmation when orphaned. The user must not manually create workflows with the `[auto]` prefix.

**FR-46.** If the Paperless-ngx workflow API does not support `filter_has_document_type` as a trigger condition (to be verified against the live API during implementation), the fallback is:
- The command also creates a tag named `type-{slugified-document-type}` (e.g. `type-medical-invoice`)
- The auto-generated workflow triggers on that tag instead
- The AI classification hints (`ai_hint` on the doc type) instruct the AI to also assign that tag
- This is the fallback path only; prefer native `filter_has_document_type` if available.

**FR-47.** Document types without a `custom_fields` key (or with an empty list) do not generate a field-attachment workflow.

**FR-48.** Field names listed under `document_types[].custom_fields` must exist in the top-level `custom_fields` list. The command validates this at load time and errors on any unknown reference before making any API calls.

### 4.7 Pull Mode (`--pull`)

**FR-30.** When `--pull` is specified, the command reverses direction: it reads the live Paperless-ngx API and writes the result into `scripts/paperless-config.yaml`.

**FR-31.** Pull behaviour:
1. Fetch all items for each entity type from the live API.
2. Convert integer codes → human-readable YAML strings (trigger types, action types, matching algorithms).
3. Resolve numeric tag IDs referenced in workflows back to tag names (using `ref: <name>` syntax).
4. Resolve numeric custom field IDs in saved view filter rules back to field names.
5. Write the resulting YAML to `scripts/paperless-config.yaml`.

**FR-32.** If `scripts/paperless-config.yaml` already exists, pull performs a **merge**:
- Items present in the live API but absent from the YAML are **added**.
- Items present in both are **updated** to match the live API (live API wins).
- Items present in the YAML but absent from the live API are **left in place** with a YAML comment: `# WARNING: not found in live Paperless — may have been deleted`.

**FR-33.** After pull, the command also regenerates `bootstrap.sh` (same sentinel logic as push, FR-25 through FR-29).

**FR-34.** Pull is the recommended first step on a stack with existing data. Typical workflow:
```
/paperless-update --pull        # adopt existing live state into YAML
# review + edit scripts/paperless-config.yaml
/paperless-update               # push YAML back to live (dry-run first)
```

### 4.6 bootstrap.sh Regeneration

**FR-25.** After any successful create, update, or delete, the command regenerates the bootstrap-managed sections of `scripts/bootstrap.sh`.  
**FR-26.** The regenerated bootstrap.sh is a complete, standalone bash script — it must be runnable without the YAML file present.  
**FR-27.** The regeneration replaces only the auto-generated sections, which are delimited by sentinel comments:
```bash
# [paperless-update:tags:begin]
...
# [paperless-update:tags:end]
```
Each entity type has its own sentinel pair. Content outside the sentinels is preserved verbatim.  
**FR-28.** If bootstrap.sh does not yet contain sentinels for an entity type, the command appends the generated section before the `# ── Done ──` line.  
**FR-29.** The generated bash uses the same helper functions already present in bootstrap.sh (`create_tag`, `api_post`, `create_workflow`, etc.). The command must not duplicate helper definitions.

### 4.10 README Update

**FR-51.** After any push or pull that changes state, the command updates `CLAUDE.md` (the project README) to reflect the current taxonomy. Specifically, it regenerates the following sections between sentinels:

```markdown
<!-- [paperless-update:tags:begin] -->
...
<!-- [paperless-update:tags:end] -->
```

**FR-52.** The sections regenerated in `CLAUDE.md` are:

| Section | Content |
|---|---|
| Tags | Flat list of all tags with hierarchy, matching rules, and `ai_hint` if set |
| Document types | List of types with their associated custom fields |
| Custom fields | List of all fields with data type |
| Workflows | List of user-defined workflows (excludes `[auto]` workflows) |
| Saved views | List of views with filter summary |

**FR-53.** Content outside the sentinel blocks in `CLAUDE.md` is preserved verbatim — same sentinel strategy as bootstrap.sh (FR-27).

**FR-54.** The README sections are written in plain English, not raw YAML — they are human-readable documentation of the current state, not a config dump. Example:

```markdown
<!-- [paperless-update:tags:begin] -->
### Tags
- **Finance** → Tax, Insurance, Banking
- **Health** → Medical, Dental, health-xnc, health-ms, health-po
- **Altenberg** — matches literal "St. Andra-Wörden" · AI: assign for Altenberg/Hoflein documents
<!-- [paperless-update:tags:end] -->
```

---

## 5. Non-Goals / Out of Scope

- **Correspondents** — not managed (the AI assigns these dynamically; they should not be pre-seeded).
- **Mail rules** — out of scope for v1; too dependent on personal email setup.
- **Documents themselves** — the command only manages metadata/taxonomy, not document content.
- **User accounts** — Paperless-ngx users are managed outside this tool.
- **Rollback** — no undo beyond the user declining a delete prompt.
- **Remote stacks** — the command assumes Paperless is reachable at `http://localhost:8000`.
- **GUI wizard** — no web UI; this is a terminal/Claude Code command only.

---

## 6. Design Considerations

### Single source of truth vs. live drift

The YAML is the intended source of truth, but a user may also click through the web UI and create items there. Items created in the UI that are absent from the YAML will appear as "orphans" and the command will offer to delete them. The user can also choose to add them to the YAML to adopt them.

### YAML vs. JSON

YAML is chosen (over JSON) because:
- It supports comments (critical for explaining `matching_algorithm` integer codes).
- It's more human-readable for nested structures like workflow triggers/actions.
- `yq` or Python's `pyyaml` can parse it in bash or Claude tool calls.

### bootstrap.sh sentinel strategy

Rather than generating bootstrap.sh from scratch, we preserve the manual sections (e.g., the `paperless-ai-next` user creation block) and only replace the taxonomy sections. This is less fragile and easier to review in git diffs.

---

## 7. Technical Considerations

### Paperless-ngx REST API (v5+)

| Entity | Endpoint | Notes |
|--------|----------|-------|
| Tags | `GET/POST/PATCH/DELETE /api/tags/` | Supports `parent` field for nesting |
| Document types | `GET/POST/PATCH/DELETE /api/document_types/` | Simple name-only entities |
| Custom fields | `GET/POST/DELETE /api/custom_fields/` | No PATCH on options; delete+recreate required |
| Workflows | `GET/POST/PATCH/DELETE /api/workflows/` | Nested triggers/actions; no name-uniqueness enforced by API |
| Saved views | `GET/POST/PATCH/DELETE /api/saved_views/` | Filter rules are a nested array |

All endpoints paginate via `?page_size=200`. For large installs, the command must follow `next` links.

### Command implementation

The command is a markdown file at `.claude/commands/paperless-update.md`. It instructs Claude to:

1. Read `scripts/paperless-config.yaml` (Read tool).
2. Read root `.env` for the token (Read tool).
3. Query live API endpoints (Bash tool: `curl`).
4. Compute the diff (Claude reasoning, no external diff tool needed).
5. Apply changes via Bash `curl` calls.
6. Ask for confirmation before deletes (AskUserQuestion tool).
7. Regenerate bootstrap.sh sections (Edit tool).

### YAML parsing

Claude can parse YAML natively in its reasoning. For any bash-level parsing needed inside bootstrap.sh regeneration, use `python3 -c "import yaml, sys; ..."` — Python + PyYAML is available in the dev container and on the WSL host via Docker.

### No new dependencies

The command uses only tools already present: `curl`, `python3`, `bash`. No `yq` install required.

---

## 8. Success Metrics

| Metric | Target |
|--------|--------|
| A new tag added to YAML is live in Paperless within one `/paperless-update` run | 100% |
| bootstrap.sh, when run on a fresh stack, produces the same state as the YAML | 100% |
| No item is deleted without a user confirmation prompt | 100% |
| Dry-run mode makes zero write API calls | 100% |
| A user can onboard (understand the YAML schema and run the command) without reading this PRD | Stretch goal |

---

## 9. Open Questions

| # | Question | Decision |
|---|----------|----------|
| OQ1 | Pull mode — adopt live state into YAML? | **Yes** — `--pull` flag, see §4.7 |
| OQ2 | Human-readable strings or integers in YAML for trigger/action types? | **Human-readable strings** — see FR-23a mapping table |
| OQ3 | Enforce workflow name uniqueness at YAML level? | **Yes** — command errors if duplicate workflow names exist in YAML |
| OQ4 | bootstrap.sh regeneration: auto or separate sub-command? | **Always auto** after any push or pull that changes state |
| OQ5 | Does Paperless-ngx workflow trigger support `filter_has_document_type`? | **Verify during implementation** — if not, fall back to tag-based trigger (FR-46) |
| OQ6 | Does `assign_custom_field` action support `value: null` to add a field with no value? | **Verify during implementation** — may need to omit value key entirely |
