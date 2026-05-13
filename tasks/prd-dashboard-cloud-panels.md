# PRD: Dashboard Cloud Infrastructure Panels
## Status: Draft
## Last Updated: 2026-05-06

---

## 1. Problem Statement

The existing dashboard (`apps/dashboard`) was built for local GPU use — service cards show VRAM and active Ollama model, and the timeline shows GPU utilisation. When deployed to AWS (per `prd-aws-cloud-deployment.md`), none of those panels are meaningful. There's no visibility into disk space (EBS could fill up silently), no indication of whether LiteLLM can actually reach Bedrock, no backup confirmation, and no EC2 spot status.

The goal is to extend the existing Next.js dashboard with a cloud-aware infrastructure row, swap Ollama stats for LiteLLM stats in the service cards, and surface the metrics that actually matter on a remote server: disk, connectivity, and backup recency.

---

## 2. Goals & Success Metrics

- **G1** — Dashboard shows EBS disk usage (used / total / % free) without SSH.
- **G2** — LiteLLM → Bedrock connectivity is visible: green if models are reachable, red with error if not.
- **G3** — Last successful backup timestamp and S3 object count visible at a glance.
- **G4** — EC2 instance type and spot interruption state shown (stopped / running / unknown).
- **G5** — Service cards no longer show VRAM/Ollama stats; show LiteLLM request count and Bedrock model aliases instead.
- **G6** — All new data fetched server-side in Next.js API routes; dashboard client unchanged except component additions.

---

## 3. User Stories

- **US-1** As Marcus, I want to see disk usage without SSH-ing in so that I know when the EBS volume is getting full before it causes failures.
- **US-2** As Marcus, I want to see LiteLLM → Bedrock status so that I know immediately if AI classification is broken.
- **US-3** As Marcus, I want to see the last backup timestamp so that I know my documents are protected.
- **US-4** As Marcus, I want the service cards to show relevant cloud stats (LiteLLM request count) instead of irrelevant GPU stats.
- **US-5** As Marcus, I want EC2 spot status visible so that I know if the instance was recently interrupted and recovered.

---

## 4. Functional Requirements

### API — `/api/system` (new route)
- **FR-1** `GET /api/system` returns a JSON object with four top-level keys: `disk`, `instance`, `bedrock`, `backup`. All fields are best-effort — missing/failed data returns `null` for that field, never throws. → US-1, US-2, US-3, US-4, US-5
- **FR-2** `disk`: call `fs.statfsSync('/data')` (Node 18+). Return `{ usedBytes, totalBytes, freeBytes, usedPct }`. If `/data` is not mounted (local dev), return `null`. → US-1
- **FR-3** `instance`: fetch EC2 IMDSv2 metadata. Step 1: PUT `http://169.254.169.254/latest/api/token` with header `X-aws-ec2-metadata-token-ttl-seconds: 60`, 1s timeout. Step 2: GET `/latest/meta-data/instance-type` and `/latest/meta-data/instance-life-cycle` (returns `"spot"` or `"on-demand"`) using token from step 1. Return `{ instanceType, lifecycle, uptime }` where uptime is parsed from `/proc/uptime`. If metadata is unreachable (non-AWS), return `null`. → US-5
- **FR-4** `bedrock`: fetch `GET http://litellm:4000/health` (internal URL, 5s timeout). Parse response — LiteLLM returns `{ status: "healthy" | "degraded", healthy_endpoints: [...], unhealthy_endpoints: [...] }`. Return `{ status, healthyCount, unhealthyCount, models: string[] }`. If LiteLLM unreachable, return `{ status: "unreachable" }`. → US-2
- **FR-5** `backup`: read `/data/backup-status.json` (written by backup service, see FR-12). Return `{ lastRunAt: ISO string, success: boolean, objectCount: number }`. If file missing, return `null`. → US-3

### API — `/api/status` (modify existing)
- **FR-6** Remove `fetchOllamaStats` function. → US-4
- **FR-7** Add `fetchLiteLLMStats(baseUrl: string)` that calls `GET <baseUrl>/health` (same LiteLLM health endpoint). Extract `total_requests` from the response (LiteLLM includes this in health payload under `litellm_version` block, or fall back to `GET /metrics` Prometheus scrape). Return `{ requestCount?: number, modelAliases?: string[] }` as `stats` for the `litellm` service card. → US-4
- **FR-8** In `fetchStats`, replace the `ollama` branch with a `litellm` branch that calls `fetchLiteLLMStats`. → US-4

### Component — `InfraPanel` (new)
- **FR-9** New `InfraPanel` client component fetches `/api/system` on mount and every 60 seconds. Renders a horizontal row of four cards: Disk, Instance, Bedrock, Backup. → US-1, US-2, US-3, US-5
- **FR-10** **Disk card**: horizontal progress bar showing % used. Text: `X.X GB used / Y GB total`. Bar colour: green < 70%, yellow 70–89%, red ≥ 90%. → US-1
- **FR-11** **Instance card**: shows `instanceType` (e.g. `t3.medium`) and `lifecycle` badge (`SPOT` in orange, `ON-DEMAND` in grey). Uptime formatted as `Xd Xh Xm`. → US-5
- **FR-12** **Bedrock card**: green dot + `X models healthy` if all endpoints healthy; yellow if some unhealthy; red + error text if unreachable. Shows model aliases as small tags (e.g. `nova-lite`, `haiku`). → US-2
- **FR-13** **Backup card**: shows last run timestamp (relative: "3h ago") and green/red indicator for success. Shows object count from S3 status file. If never run, shows "No backup yet". → US-3

### Compose + backup service
- **FR-14** Add `/data:/data:ro` volume mount to the `dashboard` service in `compose.yaml` so `fs.statfsSync('/data')` works inside the container. → FR-2
- **FR-15** The `backup` service (defined in `prd-aws-cloud-deployment.md`) writes `/data/backup-status.json` after each run: `{ "lastRunAt": "<ISO>", "success": true|false, "objectCount": <n> }`. This file is how the dashboard reads backup state without needing AWS SDK or credentials. → FR-5

### Configuration
- **FR-16** `apps/dashboard/config/stack.yaml`: remove `ollama` and `open-webui` entries; add `litellm` entry with `internalUrl: http://litellm:4000`, `probeUrl: http://litellm:4000/health`, `url: ""` (no external UI). → US-4
- **FR-17** `InfraPanel` is added to `apps/dashboard/src/app/page.tsx` between the service cards section and the pipeline timeline, clearly labelled "Infrastructure". → FR-9

---

## 5. Non-Goals / Out of Scope

- No AWS CloudWatch integration — metrics come from local proc/metadata/files only.
- No alerting or notifications — display only.
- No Bedrock cost/spend tracking — that's an AWS console concern.
- No changes to the pipeline timeline component (GPU timeline becomes irrelevant in cloud but removing it is a separate decision).
- No changes to the settings modal.
- No mobile-specific layout changes (existing responsive grid is sufficient).

---

## 6. Technical Considerations

### `fs.statfsSync('/data')`
Available in Node.js 18.15+ (stable). Returns `{ bsize, blocks, bfree, bavail }`. Used bytes = `(blocks - bfree) * bsize`. Total bytes = `blocks * bsize`. Use `bavail` (available to non-root) for free bytes shown to user. Guard with `try/catch` for local dev where `/data` doesn't exist.

### EC2 IMDSv2
IMDSv2 requires the two-step token fetch. Set a short TTL (60s) since we only need it momentarily. The dashboard container can reach `169.254.169.254` from inside the compose network on an EC2 instance. In local dev, this will time out — guard with 1s timeout and return `null`.

```typescript
// Step 1
const token = await fetch("http://169.254.169.254/latest/api/token", {
  method: "PUT",
  headers: { "X-aws-ec2-metadata-token-ttl-seconds": "60" },
  signal: AbortSignal.timeout(1000),
}).then(r => r.text());

// Step 2
const instanceType = await fetch("http://169.254.169.254/latest/meta-data/instance-type", {
  headers: { "X-aws-ec2-metadata-token": token },
  signal: AbortSignal.timeout(1000),
}).then(r => r.text());
```

### LiteLLM health endpoint
`GET /health` returns:
```json
{
  "status": "healthy",
  "healthy_endpoints": [{ "model": "bedrock-classify", ... }],
  "unhealthy_endpoints": []
}
```
Use this directly for FR-4 and FR-7. No Prometheus scraping needed.

### Uptime from `/proc/uptime`
```typescript
import { readFileSync } from "fs";
const [seconds] = readFileSync("/proc/uptime", "utf8").split(" ").map(Number);
```
Format as `Xd Xh Xm`. Works on Linux (EC2 and WSL); on macOS (local dev) `/proc/uptime` doesn't exist — guard with try/catch, return `null`.

### Relevant files
| File | Action | Purpose |
|------|--------|---------|
| `apps/dashboard/src/app/api/system/route.ts` | Create | New system metrics endpoint (FR-1 to FR-5) |
| `apps/dashboard/src/app/api/status/route.ts` | Modify | Replace fetchOllamaStats → fetchLiteLLMStats (FR-6 to FR-8) |
| `apps/dashboard/src/components/infra-panel.tsx` | Create | Four-card infrastructure row (FR-9 to FR-13) |
| `apps/dashboard/src/app/page.tsx` | Modify | Add `<InfraPanel />` section (FR-17) |
| `apps/dashboard/config/stack.yaml` | Modify | Swap ollama/open-webui → litellm (FR-16) |
| `compose.yaml` | Modify | Add `/data:/data:ro` mount to dashboard (FR-14) |

---

## 7. Functional Test Plan

**Setup:**
- Cloud stack deployed (per `prd-aws-cloud-deployment.md`).
- Dashboard accessible at `https://dashboard.<domain>`.
- At least one document processed since deploy (to have backup data).

**Steps:**

1. Open `https://dashboard.<domain>` — confirm page loads, no console errors.

2. **Disk card** — should show a progress bar with used/total GB. Verify it updates by checking `df -h /data` on the instance via SSH and comparing numbers.

3. **Instance card** — should show `t3.medium` and `SPOT` badge. Verify by cross-checking `curl -H "X-aws-ec2-metadata-token: ..." http://169.254.169.254/latest/meta-data/instance-type` from SSH.

4. **Bedrock card** — should show green dot + "2 models healthy" (nova-lite + haiku). Kill litellm container temporarily (`docker compose stop litellm`), refresh dashboard — should turn red "unreachable". Restart litellm, verify it goes green within 60s.

5. **Backup card** — run backup manually (`docker compose exec backup /scripts/backup.sh`), refresh dashboard — should show "just now" with green indicator.

6. **Service cards** — LiteLLM card should show health status and model aliases. No VRAM or "active model" fields should appear.

7. **`/api/system` raw** — `curl https://dashboard.<domain>/api/system | jq .` — verify all four keys present with non-null values.

---

## 8. Open Questions

None — all questions resolved. This PRD depends on `prd-aws-cloud-deployment.md` being implemented first (LiteLLM service, `/data` EBS mount, backup service must exist).

---

## Implementation

### Pre-flight Requirements

No new packages required — `fs.statfsSync` is built into Node 18+, fetch is built in. All dependencies already in `apps/dashboard/package.json`.

**No new env vars required** — LiteLLM URL is internal (`http://litellm:4000`), EC2 metadata is a fixed IP, `/data` is a volume mount, `/proc/uptime` is always available on Linux.

**Other system changes:**
- `compose.yaml`: add `/data:/data:ro` volume to dashboard service (FR-14) — requires compose restart.
- `apps/dashboard/config/stack.yaml`: update service list (FR-16).
- Backup service must write `/data/backup-status.json` (FR-15) — implement as part of the backup script in `prd-aws-cloud-deployment.md` task 3.7.

---

### Relevant Files
- `apps/dashboard/src/app/api/system/route.ts` — Create, new endpoint
- `apps/dashboard/src/app/api/status/route.ts` — Modify, replace Ollama fetching
- `apps/dashboard/src/components/infra-panel.tsx` — Create, four cloud metric cards
- `apps/dashboard/src/app/page.tsx` — Modify, add InfraPanel section
- `apps/dashboard/config/stack.yaml` — Modify, swap service entries
- `compose.yaml` — Modify, add /data mount to dashboard

### Notes
- `InfraPanel` polling interval: 60 seconds (slower than service cards at 30s — system metrics don't change fast).
- All fetch calls in `/api/system` must have short timeouts (1s for metadata, 5s for LiteLLM). Never block the response on a slow probe.
- Guard every `fs` call with try/catch for local dev compatibility.
- This PRD assumes `prd-aws-cloud-deployment.md` is already implemented. If running locally, `/api/system` will return `null` for all fields gracefully — InfraPanel should show a "Not available in local mode" state rather than error cards.

### Tasks

- [ ] 1.0 Update config and types
  - [ ] 1.1 Edit `stack.yaml`: remove `ollama` and `open-webui` service entries; add `litellm` entry (`internalUrl: http://litellm:4000`, `probeUrl: http://litellm:4000/health`, `url: ""`, `dozzleContainer: paperless-litellm-1`) (FR-16)
  - [ ] 1.2 Add TypeScript interface `SystemMetrics` to a new `src/lib/system.ts`: `{ disk: DiskInfo | null, instance: InstanceInfo | null, bedrock: BedrockInfo | null, backup: BackupInfo | null }` with subtypes for each field (FR-1)

- [ ] 2.0 Create `/api/system` route
  - [ ] 2.1 Implement `getDiskInfo()`: `fs.statfsSync('/data')` → `{ usedBytes, totalBytes, freeBytes, usedPct }`, wrapped in try/catch returning null if path missing (FR-2)
  - [ ] 2.2 Implement `getInstanceInfo()`: IMDSv2 two-step token fetch → instance-type + instance-life-cycle + `/proc/uptime` parse, 1s timeouts, return null if metadata unreachable (FR-3)
  - [ ] 2.3 Implement `getBedrockInfo()`: `fetch('http://litellm:4000/health', { timeout: 5000 })` → parse healthy/unhealthy endpoints, extract model aliases, return `{ status, healthyCount, unhealthyCount, models }` (FR-4)
  - [ ] 2.4 Implement `getBackupInfo()`: `fs.readFileSync('/data/backup-status.json')` → parse JSON → return `{ lastRunAt, success, objectCount }`, null if file missing (FR-5)
  - [ ] 2.5 Wire all four into `GET /api/system`: `Promise.allSettled` for parallel fetch, return combined object with `Cache-Control: no-store` (FR-1)

- [ ] 3.0 Update `/api/status` for LiteLLM
  - [ ] 3.1 Delete `fetchOllamaStats` function; add `fetchLiteLLMStats(baseUrl: string)` that calls `GET <baseUrl>/health` and returns `{ requestCount?: number, modelAliases?: string[] }` (FR-6, FR-7)
  - [ ] 3.2 In `fetchStats` switch, replace `case "ollama"` with `case "litellm"` calling `fetchLiteLLMStats` (FR-8)

- [ ] 4.0 Create `InfraPanel` component
  - [ ] 4.1 Create `src/components/infra-panel.tsx`: client component, fetches `/api/system` on mount + 60s interval, renders loading skeleton while fetching (FR-9)
  - [ ] 4.2 Implement **Disk card**: progress bar with dynamic colour (green/yellow/red thresholds), used/total text (FR-10)
  - [ ] 4.3 Implement **Instance card**: instance type text, lifecycle badge (SPOT orange / ON-DEMAND grey), formatted uptime string (FR-11)
  - [ ] 4.4 Implement **Bedrock card**: status dot, healthy/unhealthy count, model alias tags; "unreachable" red state (FR-12)
  - [ ] 4.5 Implement **Backup card**: relative timestamp ("3h ago"), success/failure indicator, object count; "No backup yet" empty state (FR-13)
  - [ ] 4.6 Add "Not available in local mode" empty state for when all four fields are `null` (non-AWS dev environment)

- [ ] 5.0 Wire InfraPanel into page + compose
  - [ ] 5.1 Edit `src/app/page.tsx`: add `<InfraPanel />` section with heading "Infrastructure" between Service Cards and Pipeline Timeline (FR-17)
  - [ ] 5.2 Edit `compose.yaml`: add `- /data:/data:ro` to `dashboard` service volumes (FR-14)
  - [ ] 5.3 Edit backup script (`scripts/backup.sh` or inline compose command): append `echo '{"lastRunAt":"...","success":true,"objectCount":...}' > /data/backup-status.json` after S3 sync completes, with correct timestamp and object count from `aws s3api list-objects-v2` (FR-15)

- [ ] 6.0 Verification and cleanup
  - [ ] 6.1 Verify `/api/system` returns valid JSON with all four keys locally (null values expected); confirm no unhandled promise rejections in Next.js logs
  - [ ] 6.2 Verify service cards no longer render VRAM/activeModel fields for any service
  - [ ] 6.3 Run through all 7 steps in the Functional Test Plan (§7) on the deployed cloud instance

### Progress Log
| Date | Task | Notes |
|------|------|-------|
| | | |
