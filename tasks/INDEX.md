# Task Index
## Last Updated: 2026-05-06

Implementation order for all active PRDs. Each PRD file has a matching `## Order` header.

---

## Active PRDs — Implement in this order

| # | File | Status | Effort | Depends on | Notes |
|---|------|--------|--------|------------|-------|
| 1 | [prd-aws-cloud-deployment.md](prd-aws-cloud-deployment.md) | ✅ Ready | Large | — | Full task list. Two blocking pre-flight items: domain name + IMAP creds. |
| 2 | [prd-dashboard-cloud-panels.md](prd-dashboard-cloud-panels.md) | ✅ Ready | Medium | #1 deployed | Full task list. Gracefully degrades in local mode. |
| 3 | [prd-pretty-hostnames-caddy.md](prd-pretty-hostnames-caddy.md) | ⚠️ Needs task list | Small | — | Local-only (WSL2). Good spec. Missing `/implement`-compatible task list. |
| 4 | [prd-log-filter-presets.md](prd-log-filter-presets.md) | ⚠️ Needs task list | Small | — | Good spec. Missing task list. Quick win. |
| 5 | [prd-kanban-boards.md](prd-kanban-boards.md) | ⚠️ Needs task list | Large | dashboard (done) | Well-specced. Missing task list. Needs `@dnd-kit` added to package.json + container rebuild. |
| 6 | [prd-pipeline-reprocess.md](prd-pipeline-reprocess.md) | ⚠️ Needs task list | Small | #5 kanban | Good spec. Missing task list. Pipeline page (`/pipeline` route) is a new dependency. |
| 7 | [prd-smart-pipeline.md](prd-smart-pipeline.md) | 🔴 Needs update | Large | dashboard (done) | Written assuming local Ollama. Must be updated for Bedrock/LiteLLM context before implementing. |

---

## Retired PRDs

| File | Reason |
|------|--------|
| [done/prd-hybrid-cloud.md](done/prd-hybrid-cloud.md) | **SUPERSEDED** by #1 (prd-aws-cloud-deployment). Architecture decision changed: full cloud via Bedrock, no WireGuard/Consul/gradual migration. |

---

## Completed PRDs (done/)

| File | What it delivered |
|------|------------------|
| prd-docker-compose-migration.md | Migrated from bare-metal scripts to docker compose stack |
| prd-ai-tagging-pipeline.md | paperless-ai-next + Ollama classification pipeline |
| prd-ocr-pipeline-split.md | Vision OCR split (paperless-gpt + ocr-pending tag flow) |
| prd-paperless-dashboard.md | Initial dashboard (service cards, pipeline timeline, QuestDB) |
| prd-dashboard-visibility.md | Dashboard v2 (settings modal, stack.yaml config) |
| prd-paperless-update-command.md | `/paperless-update` skill for taxonomy sync |
| paperless-ngx-cli-setup.md | Initial CLI setup |
| PRD.md | Original planning doc |

---

## Notes on PRDs that need work

### #3 prd-pretty-hostnames-caddy
Good spec, no task list. Note: the Caddy config pattern here (local `.pstack.localhost` subdomains) is different from the cloud Caddy config in #1 (public HTTPS via Let's Encrypt). They share the same service but different Caddyfiles — worth aligning. Can run this any time before or after cloud deploy; they don't conflict.

### #4 prd-log-filter-presets
Lightweight. Needs task list added. No new packages, no deps. Could be done in one short session. Run `/prd` to generate task list from the existing spec before `/implement`.

### #5 prd-kanban-boards
Significant feature but well-specced. **Pre-flight required:** `@dnd-kit/core` and `@dnd-kit/sortable` must be added to `apps/dashboard/package.json` and the container rebuilt before implementing. Also needs a task list generated.

### #6 prd-pipeline-reprocess
Small feature, depends on kanban (#5) because the reprocess button appears on kanban cards. Also introduces a new `/pipeline` page (separate route from home) — that page is not in any other PRD and needs to be scoped. Needs task list.

### #7 prd-smart-pipeline
Ambitious — introduces a rule engine, triage system, and LLM suggestion queue. Written in April 2026 assuming local Ollama. With Bedrock, the motivation is even stronger (each unmatched doc costs money → rule engine reduces API calls). Needs a targeted update to §7 Technical Considerations before implementing. Run `/prd` to revise before `/implement`.
