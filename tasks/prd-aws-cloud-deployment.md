# PRD: AWS Cloud Deployment (Paperless-ngx + Bedrock AI)
## Status: Draft
## Last Updated: 2026-05-06

---

## 1. Problem Statement

The current stack runs entirely on a local WSL2 machine with an NVIDIA GPU. This means Paperless-ngx is only reachable on the local network, the GPU is a single point of failure for all AI classification and vision OCR, and the machine can't be turned off without losing document ingestion capability.

The goal is to move the full stack to AWS so that documents are always accessible from anywhere, AI classification and vision OCR run via managed Bedrock APIs (no local GPU needed), and the total cost is under $40/month — cheaper than keeping a dedicated GPU machine running 24/7.

---

## 2. Goals & Success Metrics

- **G1** — Paperless-ngx UI accessible over HTTPS at a Route53-managed domain from any device, anywhere.
- **G2** — Full AI pipeline functional: new docs auto-classified by paperless-ai-next via Bedrock Nova Lite; opt-in vision OCR via paperless-gpt → Bedrock Claude Haiku.
- **G3** — Monthly AWS cost ≤ $40 (EC2 spot + EBS + Bedrock API + S3 + Route53).
- **G4** — Existing document archive migrated from local stack with zero data loss.
- **G5** — Spot interruptions are self-healing: data survives (separate EBS), instance auto-restarts when capacity returns.
- **G6** — Document ingestion works via email (IMAP) and via a local rclone-synced consume folder.

---

## 3. User Stories

- **US-1** As Marcus, I want to access Paperless from my phone while traveling so that I can find documents without being home.
- **US-2** As Marcus, I want new documents automatically classified without a local GPU running so that I can turn off my desktop without losing the pipeline.
- **US-3** As Marcus, I want to email a PDF directly into Paperless so that I can capture documents from my phone instantly.
- **US-4** As Marcus, I want my existing document archive preserved so that I don't lose years of classified documents.
- **US-5** As Marcus, I want spot interruptions to be self-healing so that I don't need to manually restart the stack.
- **US-6** As Marcus, I want daily backups to S3 so that I can recover from accidental deletion or EBS failure.

---

## 4. Functional Requirements

### Infrastructure
- **FR-1** SST sst.config.ts provisions all AWS infrastructure in eu-central-1 (Frankfurt) using raw Pulumi `aws.ec2.*` resources (SST v3 has no native EC2 component). → US-1, US-2
- **FR-2** EC2 instance is a t3.medium spot request with `instanceInterruptionBehavior: "stop"`. On interruption, instance stops (not terminated); EBS data volume is preserved; instance auto-restarts when spot capacity returns. → US-5
- **FR-3** A separate EBS gp3 volume (150GB, eu-central-1) is created and attached to the instance at `/dev/xvdf`, mounted at `/data`. All compose bind-mounts use `/data/` prefix. The volume is NOT deleted when the instance stops/terminates. → US-4, US-5
- **FR-4** IAM instance profile attached to EC2 grants `bedrock:InvokeModel`, `bedrock:InvokeModelWithResponseStream`, `bedrock:ListFoundationModels` on `arn:aws:bedrock:eu-central-1::foundation-model/*`. No static AWS keys — instance role is used by LiteLLM. → US-2
- **FR-5** Security group allows: inbound SSH (22) from 0.0.0.0/0, inbound HTTP (80) and HTTPS (443) from 0.0.0.0/0. All outbound allowed. → US-1
- **FR-6** Elastic IP allocated and associated with the instance. When instance stops during spot interruption, EIP stays allocated (no cost while associated with a stopped instance). → US-1
- **FR-7** Route53 A record points the chosen domain to the Elastic IP. Managed in SST. → US-1
- **FR-8** S3 bucket created for daily backups (`paperless-backup-<account-id>`). Versioning enabled. Lifecycle rule: expire backup objects after 90 days. → US-6
- **FR-9** All sensitive values (PG_PASSWORD, SECRET_KEY, PAPERLESS_API_TOKEN, PAPERLESS_AI_NEXT_API_KEY, IMAP credentials) are stored as SST Secrets (backed by SSM Parameter Store). Injected into the instance at boot via user-data reading from SSM. → US-2

### EC2 Bootstrap
- **FR-10** user-data cloud-init script runs on first boot and on every restart: installs Docker + Docker Compose plugin, formats and mounts the EBS data volume (idempotent — checks if already formatted before mkfs), clones the paperless repo from GitHub, writes `.env` by reading SSM parameters, and runs `docker compose up -d`. → US-2, US-5
- **FR-11** A systemd unit `paperless-compose.service` ensures `docker compose up -d` runs automatically on every instance start (including spot restarts). → US-5

### Compose Changes
- **FR-12** Remove from compose.yaml: `ollama`, `open-webui`, `gpu-monitor` services. → US-2
- **FR-13** Add `litellm` service using `ghcr.io/berriai/litellm:main-latest`. Config file at `./litellm/config.yaml` maps:
  - Model alias `bedrock-classify` → `bedrock/amazon.nova-lite-v1:0`
  - Model alias `bedrock-vision` → `bedrock/anthropic.claude-3-5-haiku-20241022-v1:0`
  - Auth: uses EC2 instance role (no AWS_ACCESS_KEY_ID needed; set `AWS_REGION_NAME: eu-central-1`)
  LiteLLM listens on port 4000. → US-2
- **FR-14** Update `paperless-gpt/.env`: `LLM_PROVIDER=openai`, `VISION_LLM_PROVIDER=openai`, `OPENAI_BASE_URL=http://litellm:4000`, `OPENAI_API_KEY=placeholder`, `LLM_MODEL=bedrock-classify`, `VISION_LLM_MODEL=bedrock-vision`. Remove Ollama URL env vars. → US-2
- **FR-15** Update `paperless-ai-next/.env`: set `AI_PROVIDER=openai` (or equivalent), `OPENAI_BASE_URL=http://litellm:4000`, `OPENAI_API_KEY=placeholder`, `OLLAMA_MODEL` removed/replaced with the litellm model alias. → US-2
- **FR-16** Update `paperless/.env`: add `PAPERLESS_TASK_WORKERS=1`, `PAPERLESS_WEBSERVER_WORKERS=1` (reduces RAM from ~800MB to ~400MB on t3.medium; can increase on t3.large). → US-2
- **FR-17** Add `backup` service to compose.yaml: runs on a cron schedule (03:00 daily), executes `document_exporter` then `aws s3 sync` to the S3 backup bucket using instance role credentials. → US-6
- **FR-18** All volume bind-mounts updated to use `/data/` prefix (EBS mount): `/data/paperless/media`, `/data/paperless/data`, `/data/postgres/data`, `/data/redis/data`, `/data/questdb/data`, `/data/paperless-ai-next/data`. → FR-3

### Document Ingestion
- **FR-19** Email ingestion configured in `paperless/.env`: `PAPERLESS_EMAIL_TASK_CRON`, `PAPERLESS_CONSUMER_ENABLE_IMAP=true`, plus IMAP host/port/user/password/inbox env vars. Paperless polls the inbox every 5 minutes. → US-3
- **FR-20** An `rclone-consume` sidecar service in compose.yaml runs `rclone sync` on a 60-second loop from a configurable source (S3 bucket or local folder at `/data/consume-inbox/`) into `/data/paperless/consume/`. Config at `./rclone/rclone.conf` (gitignored, injected at deploy time). → US-3

### Access & TLS
- **FR-21** Caddy service added to compose.yaml (replacing raw port 8000 exposure). Caddy terminates TLS via ACME/Let's Encrypt and reverse-proxies:
  - `paperless.<domain>` → paperless:8000
  - `dozzle.<domain>` → dozzle:8080
  - `dashboard.<domain>` → dashboard:3000
  Caddy data volume at `/data/caddy/`. → US-1

### Migration
- **FR-22** Migration procedure documented: export from local stack with `document_exporter`, copy export archive to EC2 via `scp`, import with `document_importer`, verify document count matches. → US-4

---

## 5. Non-Goals / Out of Scope

- **No ECS/Fargate** — single EC2 instance running docker compose. No container orchestration.
- **No RDS** — PostgreSQL runs as a container on the same instance. RDS adds $15+/mo for no benefit at this scale.
- **No pipeline-timing service in cloud** — removed (depends on Docker socket log parsing; nice-to-have locally, not critical remotely).
- **No CI/CD pipeline** — updates are manual: SSH + `git pull` + `docker compose pull && up -d`.
- **No multi-AZ / HA** — single instance, single AZ. Spot stop behavior handles the main failure mode.
- **No Ollama or local LLM** — Bedrock only in the cloud deployment.
- **No Windows/Dropbox integration** — consume folder is email or rclone/S3 in cloud.

---

## 6. Technical Considerations

### SST v3 (Ion) EC2 pattern
SST v3 has no native `Ec2` component — use raw Pulumi resources directly in `sst.config.ts`:
```typescript
import * as aws from "@pulumi/aws";
// aws.ec2.SpotInstanceRequest, aws.ec2.Volume, aws.ec2.VolumeAttachment,
// aws.ec2.SecurityGroup, aws.ec2.Eip, aws.iam.Role, aws.iam.InstanceProfile
// aws.route53.Record, aws.s3.BucketV2
```
SST wraps Pulumi, so this works natively. The `sst.config.ts` lives at repo root (or `infra/` dir).

### Spot + Stop behavior
`aws.ec2.SpotInstanceRequest` with `instanceInterruptionBehavior: "stop"`:
- When AWS reclaims capacity → instance stops, EBS persists
- When capacity returns → instance auto-restarts, systemd unit brings compose back up
- Elastic IP stays associated during stop (no extra cost)
- t3 spot interruption frequency in eu-central-1: <5% historically

### LiteLLM + Instance Role auth
LiteLLM picks up AWS credentials from the EC2 instance metadata (IMDSv2). Set `AWS_REGION_NAME=eu-central-1` in the litellm container env. No static keys. The IAM role attached via instance profile handles Bedrock access.

### Tika memory on t3.medium
Tika is the biggest RAM risk (~1-1.5GB JVM). Mitigations already applied via `PAPERLESS_TASK_WORKERS=1`. If OOM occurs, upgrade to t3.large (~$18/mo spot) — requires only SST re-deploy, no data migration.

### EBS volume idempotency
user-data must check `blkid /dev/xvdf` before running `mkfs` — on spot restart the volume is already formatted and mounted. Script pattern:
```bash
if ! blkid /dev/xvdf; then mkfs -t xfs /dev/xvdf; fi
mount /dev/xvdf /data
```

### Bedrock model availability in eu-central-1
Verify model IDs are available in eu-central-1 before deploying. As of 2026:
- `amazon.nova-lite-v1:0` — available
- `anthropic.claude-3-5-haiku-20241022-v1:0` — available
Request access in the Bedrock console under "Model access" before first deploy.

### Relevant files to create/modify
- `infra/sst.config.ts` — new, all AWS infrastructure
- `infra/package.json` — new, SST + Pulumi deps
- `compose.yaml` — remove ollama/open-webui/gpu-monitor, add litellm/backup/caddy/rclone-consume, update volume paths
- `litellm/config.yaml` — new, model alias config
- `paperless-gpt/.env` — update LLM provider vars
- `paperless-ai-next/.env` — update LLM provider vars
- `paperless/.env` — add worker limits, email ingestion vars
- `rclone/rclone.conf.example` — new, template (actual conf gitignored)
- `scripts/user-data.sh` — new, EC2 bootstrap script
- `scripts/backup.sh` — update to use S3 sync
- `Caddyfile` — new, reverse proxy config

---

## 7. Functional Test Plan

**Setup:**
- SST deployed: `cd infra && npx sst deploy`
- SSH access to EC2: `ssh -i ~/.ssh/paperless.pem ec2-user@<elastic-ip>`
- Bedrock model access enabled in AWS console (eu-central-1)
- DNS propagated: `dig paperless.<domain>` resolves to Elastic IP

**Steps:**

1. **Infrastructure check**
   ```bash
   # From WSL host
   ssh -i ~/.ssh/paperless.pem ec2-user@<elastic-ip> "docker compose ps"
   ```
   Expected: all services show `Up` or `healthy`. No `ollama`, `open-webui`, `gpu-monitor` present.

2. **HTTPS access**
   Open `https://paperless.<domain>` in browser.
   Expected: Paperless-ngx login page loads with valid TLS cert (no browser warning).

3. **Bedrock classification test**
   Upload a test PDF (e.g., any invoice) via the Paperless UI.
   Wait 60 seconds.
   Expected: document gets a title, correspondent, tags, and doc type assigned. `processed` tag appears.

4. **Vision OCR test**
   Apply `ocr-pending` tag to an existing document with poor Tesseract text.
   Wait 90 seconds.
   Expected: `advanced-ocr` tag appears, document text replaced, re-classified.

5. **Email ingestion test**
   Send an email with a PDF attachment to the configured IMAP inbox.
   Wait 5 minutes.
   Expected: document appears in Paperless Inbox view.

6. **Spot interruption simulation**
   ```bash
   # Stop the instance (simulates spot stop)
   aws ec2 stop-instances --instance-ids <id>
   # Wait 2 minutes, then start
   aws ec2 start-instances --instance-ids <id>
   # Wait 90 seconds for compose to come up
   ssh ... "docker compose ps"
   ```
   Expected: all services back up, no data loss.

7. **Backup test**
   ```bash
   ssh ... "docker compose exec backup /scripts/backup.sh"
   aws s3 ls s3://paperless-backup-<account-id>/ --recursive | tail -5
   ```
   Expected: timestamped export files present in S3 bucket.

---

## 8. Open Questions

- **Q1 (blocking):** Which domain/subdomain? Route53 hosted zone must be created or transferred before `sst deploy`. Placeholder: `paperless.example.com`.
- **Q2 (blocking):** Which IMAP provider for email ingestion? Gmail requires App Password (2FA must be on). Fastmail/Proton work with standard IMAP. Credentials needed before first boot.
- **Q3 (nice-to-resolve):** rclone source — S3 bucket, Dropbox, or just a local `/data/consume-inbox/` folder that the user SCPs files into? Affects rclone config template.
- **Q4 (nice-to-resolve):** Should `pipeline-timing` service be kept in the cloud compose? It uses Docker socket log parsing and worked locally. Can be included at no cost but adds complexity.

---

## Implementation

### Pre-flight Requirements

> ⚠️ This project runs in a **VS Code dev container**. Dependencies cannot be installed at runtime. Complete these before running `/implement`.

**New packages:**
- `sst` (Ion/v3) — infrastructure framework. Add to `infra/package.json`.
- `@pulumi/aws` — already bundled with SST Ion; no separate install needed.

**Environment variables (add to `.env.example`):**
```
# SST / AWS
AWS_PROFILE=default            # or set AWS_ACCESS_KEY_ID + SECRET for SST CLI
SST_STAGE=prod

# Email ingestion
PAPERLESS_IMAP_HOST=imap.gmail.com
PAPERLESS_IMAP_PORT=993
PAPERLESS_IMAP_USER=you@gmail.com
PAPERLESS_IMAP_PASSWORD=app-password-here
PAPERLESS_IMAP_INBOX=INBOX

# Backup
BACKUP_S3_BUCKET=paperless-backup-<account-id>
AWS_REGION=eu-central-1
```

**Other system changes:**
- Bedrock model access must be enabled manually in AWS Console → Bedrock → Model access (eu-central-1) for `amazon.nova-lite-v1` and `anthropic.claude-3-5-haiku` before deploy.
- An SSH key pair must exist or be created in eu-central-1 (`aws ec2 create-key-pair --key-name paperless --region eu-central-1`).
- A Route53 hosted zone must exist for your domain (or be created in SST config).

---

### Relevant Files

| File | Action | Purpose |
|------|--------|---------|
| `infra/sst.config.ts` | Create | All AWS infrastructure (EC2, EBS, IAM, SG, EIP, Route53, S3) |
| `infra/package.json` | Create | SST + Node deps for infra |
| `scripts/user-data.sh` | Create | EC2 cloud-init bootstrap script |
| `litellm/config.yaml` | Create | LiteLLM model alias → Bedrock model ID mapping |
| `Caddyfile` | Create | Reverse proxy + TLS config |
| `rclone/rclone.conf.example` | Create | rclone config template (actual conf gitignored) |
| `compose.yaml` | Modify | Remove GPU services, add litellm/caddy/rclone-consume/backup, update paths |
| `paperless-gpt/.env` | Modify | Switch to LiteLLM OpenAI endpoint |
| `paperless-ai-next/.env` | Modify | Switch to LiteLLM OpenAI endpoint |
| `paperless/.env` | Modify | Add worker limits + email ingestion vars |
| `.env.example` | Modify | Add new vars for SST, email, backup |
| `.gitignore` | Modify | Add `rclone/rclone.conf`, `infra/.env` |

---

### Notes

- **Deploy order:** infra first (`cd infra && npx sst deploy`), then SSH to verify, then push compose changes.
- **Bedrock region note:** LiteLLM needs `AWS_REGION_NAME=eu-central-1` set as an env var in the litellm service — it doesn't inherit from the instance metadata automatically in all versions.
- **EBS device name:** On t3 (Nitro), the device appears as `/dev/nvme1n1` inside the instance even if you specify `/dev/xvdf` in AWS. user-data must handle both names.
- **First-boot vs restart:** user-data runs on every boot by default with cloud-init `scripts-user` module. The EBS mount script must be idempotent (check `blkid` before `mkfs`).

---

### Tasks

- [ ] 1.0 SST Infrastructure (`infra/sst.config.ts`)
  - [ ] 1.1 Scaffold `infra/` dir with `package.json` and `sst.config.ts` boilerplate; configure SST app name `paperless`, stage `prod`, region `eu-central-1` (FR-1)
  - [ ] 1.2 Define all SST Secrets: `PgPassword`, `SecretKey`, `PaperlessApiToken`, `PaperlessAiNextApiKey`, `ImapPassword` — each maps to an SSM SecureString parameter (FR-9)
  - [ ] 1.3 Create VPC (or use default), security group with inbound SSH/HTTP/HTTPS rules, and SSH key pair reference (FR-5)
  - [ ] 1.4 Create IAM role + instance profile with inline Bedrock policy (`bedrock:InvokeModel`, `bedrock:InvokeModelWithResponseStream`, `bedrock:ListFoundationModels` on eu-central-1 foundation models) + SSM read policy for secrets (FR-4)
  - [ ] 1.5 Create `aws.ec2.SpotInstanceRequest` (t3.medium, `instanceInterruptionBehavior: "stop"`, Amazon Linux 2023 AMI, attach instance profile, reference user-data script) + Elastic IP + association (FR-2, FR-6)
  - [ ] 1.6 Create EBS gp3 150GB volume in eu-central-1, `aws.ec2.VolumeAttachment` at `/dev/xvdf`, `deleteOnTermination: false` (FR-3)
  - [ ] 1.7 Create S3 backup bucket with versioning + 90-day lifecycle expiry; export bucket name as SST output (FR-8)
  - [ ] 1.8 Create Route53 A record pointing domain to Elastic IP; accept domain as SST config input (FR-7)

- [ ] 2.0 EC2 Bootstrap (`scripts/user-data.sh`)
  - [ ] 2.1 Write idempotent EBS mount block: detect device (`/dev/xvdf` or `/dev/nvme1n1`), `blkid` check, `mkfs.xfs` only if unformatted, add to `/etc/fstab`, `mount /data` (FR-10)
  - [ ] 2.2 Write Docker + Docker Compose plugin install block (Amazon Linux 2023: `dnf install docker`, enable + start service, install compose plugin) (FR-10)
  - [ ] 2.3 Write SSM secrets fetch block: read each SSM parameter by name, write to `/data/paperless/.env` (FR-9, FR-10)
  - [ ] 2.4 Write repo clone block: `git clone` paperless repo to `/data/app`, or `git pull` if already cloned (FR-10)
  - [ ] 2.5 Write systemd unit `paperless-compose.service` that runs `docker compose -f /data/app/compose.yaml up -d` on boot; enable it (FR-11)

- [ ] 3.0 Compose + LiteLLM changes (`compose.yaml`, `litellm/config.yaml`)
  - [ ] 3.1 Remove `ollama`, `open-webui`, `gpu-monitor` services from compose.yaml; remove all `depends_on: ollama` references (FR-12)
  - [ ] 3.2 Create `litellm/config.yaml` with two model aliases (`bedrock-classify` → Nova Lite, `bedrock-vision` → Claude Haiku) and `AWS_REGION_NAME: eu-central-1`; add `litellm` service to compose.yaml (FR-13)
  - [ ] 3.3 Update all bind-mount paths in compose.yaml to `/data/` prefix (FR-18)
  - [ ] 3.4 Update `paperless-gpt/.env`: set `LLM_PROVIDER`, `VISION_LLM_PROVIDER`, `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `LLM_MODEL`, `VISION_LLM_MODEL`; remove Ollama vars (FR-14)
  - [ ] 3.5 Update `paperless-ai-next/.env`: set OpenAI-compatible vars pointing to litellm; remove Ollama vars (FR-15)
  - [ ] 3.6 Update `paperless/.env`: add `PAPERLESS_TASK_WORKERS=1`, `PAPERLESS_WEBSERVER_WORKERS=1` (FR-16)
  - [ ] 3.7 Add `backup` service to compose.yaml: Alpine + awscli image, cron at 03:00, runs `document_exporter` then `aws s3 sync /data/paperless/export s3://<bucket>/` using instance role (FR-17)

- [ ] 4.0 Ingestion: Email + rclone sidecar
  - [ ] 4.1 Add IMAP env vars to `paperless/.env` template: `PAPERLESS_EMAIL_TASK_CRON`, `PAPERLESS_CONSUMER_ENABLE_IMAP`, host/port/user/password/inbox vars (FR-19)
  - [ ] 4.2 Create `rclone/rclone.conf.example` template; add `rclone/rclone.conf` to `.gitignore`; add `rclone-consume` service to compose.yaml (Alpine + rclone, 60s loop sync to `/data/paperless/consume/`) (FR-20)
  - [ ] 4.3 Document in `rclone/README.md`: how to configure rclone for S3, Dropbox, or local folder; how to set up Gmail App Password for IMAP

- [ ] 5.0 Caddy TLS + reverse proxy
  - [ ] 5.1 Create `Caddyfile` with three site blocks: `paperless.<domain>` → `http://paperless:8000`, `dozzle.<domain>` → `http://dozzle:8080`, `dashboard.<domain>` → `http://dashboard:3000`; all with automatic ACME TLS (FR-21)
  - [ ] 5.2 Add `caddy` service to compose.yaml: `caddy:2` image, ports 80+443, volume at `/data/caddy/data` and `/data/caddy/config`, bind-mount `./Caddyfile:/etc/caddy/Caddyfile`; remove direct port exposure from paperless service (FR-21)
  - [ ] 5.3 Verify TLS issuance post-deploy: `curl -I https://paperless.<domain>` returns HTTP 200 with valid cert (FR-21)

- [ ] 6.0 Migration + post-deploy verification
  - [ ] 6.1 Document migration procedure in `scripts/migrate.sh`: `docker compose exec paperless document_exporter /usr/src/paperless/export`, `tar` the export dir, `scp` to EC2, extract to `/data/paperless/import/` (FR-22)
  - [ ] 6.2 Document import procedure: `docker compose exec paperless document_importer /usr/src/paperless/import`, verify doc count via API: `curl -s http://paperless:8000/api/documents/?page_size=1 | jq .count` (FR-22)
  - [ ] 6.3 Write post-deploy verification checklist covering all 7 steps in the Functional Test Plan (§7): Bedrock reachability, full pipeline smoke test, email ingestion, spot stop simulation, backup S3 sync

---

### Progress Log

| Date | Task | Notes |
|------|------|-------|
| | | |

---

## Cost Summary

| Item | $/month |
|------|---------|
| EC2 t3.medium spot (eu-central-1, ~720hr) | ~$7–11 |
| EBS gp3 150 GB | ~$15 |
| Bedrock — Nova Lite (~500 docs/mo classify) | ~$1 |
| Bedrock — Claude Haiku (~50 docs/mo vision OCR, 2pg avg) | ~$2–7 |
| S3 backup bucket (~10 GB) | ~$0.25 |
| Route53 hosted zone + queries | ~$1 |
| Elastic IP (free while attached to running/stopped instance) | $0 |
| **Total** | **~$26–35/mo** |

> Upgrade path: change instance type to `t3.large` in SST config + `sst deploy`. No data migration needed. Cost increases by ~$8–10/mo spot.
