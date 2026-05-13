# PRD 3: Hybrid Cloud Architecture

**Status:** Draft
**Author:** Marcus Jones
**Date:** 2026-04-08
**Series:** 3 of 3 — [Dashboard & Visibility](prd-dashboard-visibility.md) → [Smart Pipeline](prd-smart-pipeline.md) → [Hybrid Cloud]
**Depends on:** [PRD 1 (Dashboard)](prd-dashboard-visibility.md) — requires the dashboard, settings modal, and config system. [PRD 2 (Smart Pipeline)](prd-smart-pipeline.md) — the pipeline must support configurable model endpoints.

---

## 1. Introduction / Overview

Today, every Paperless component runs on one local machine. There's no path to running the LLM on a GPU EC2 instance, using Bedrock for classification, moving the database to RDS, or storing documents in S3. The user has no visibility into which services are local vs. remote, and switching a service between local and cloud means manually editing config files, updating networking, and hoping health checks still work.

**What this delivers:** A hybrid cloud architecture where every component is independently deployable to AWS while keeping local-first as the default. The system provides:

1. **Consul service discovery** — all services register their endpoints. The dashboard and pipeline resolve services via Consul, not hardcoded hostnames.
2. **WireGuard VPN** — encrypted tunnel between local machine and AWS VPC. Local and cloud services communicate as if on the same network.
3. **SST v3 infrastructure-as-code** — TypeScript definitions for every component's AWS equivalent (EC2 GPU for Ollama, RDS for PostgreSQL, ECS for app services, S3 for storage).
4. **Dashboard settings UI** — view/edit service endpoints, see local vs. cloud badges, switch a service from local to cloud in one click.
5. **OpenAI-compatible API adapter** — the LLM layer talks to any provider (local Ollama, EC2 Ollama, Bedrock, Together, Groq) through a single interface.

**Core constraint: data sovereignty.** The user controls where every byte lives. Document storage is local-only by default. S3 is opt-in, always encrypted, in the user's own AWS account (eu-central-1).

---

## 2. Goals

| # | Goal | Measurable |
|---|------|-----------|
| G1 | Any component swappable to cloud | Switch Ollama from local → EC2 by changing one setting in the dashboard; pipeline continues working within 60 seconds |
| G2 | Data sovereignty visible at a glance | Dashboard shows where each service runs and where documents are stored (local/cloud/region) |
| G3 | Full stack deployable to AWS | `sst deploy` provisions every component; stack accessible via CloudFront URL |
| G4 | Secure cross-boundary communication | All local↔cloud traffic encrypted via WireGuard; no services exposed to public internet except the dashboard (optional) |
| G5 | OpenAI-compatible LLM support | Pipeline LLM stages work with any OpenAI-compatible endpoint (Ollama, Bedrock gateway, Together, Groq) via config change |
| G6 | Service discovery via Consul | All services register in Consul; dashboard reads from Consul catalog; no hardcoded hostnames in application code |
| G7 | Document storage optionally in S3 | S3 as opt-in storage with encryption at rest; local↔S3 sync available; local-only is the safe default |
| G8 | Infrastructure as code | Every AWS resource defined in `sst.config.ts`; reproducible, version-controlled, teardown-able |

---

## 3. User Stories

**US1 — Moving my LLM to a bigger GPU**
As a user whose local GPU can't run the models I want, I want to point the LLM endpoint at an EC2 GPU instance from the dashboard settings — and see the health check confirm the new endpoint is working — without editing config files or restarting containers.

**US2 — Using a cloud AI provider**
As a user who wants to try Claude via Bedrock or use a fast cheap model from Groq, I want to enter the API endpoint and key in the dashboard settings and have the pipeline use it immediately — same as switching between local models.

**US3 — Seeing exactly where my data lives**
As a user who cares about data privacy, I want the dashboard to clearly show which services are local vs. cloud, and where documents are stored — so I always know where my sensitive financial and medical records are.

**US4 — Accessing my documents remotely**
As a user who wants to check a document while away from home, I want the option to deploy Paperless-ngx to AWS so I can access it from anywhere — while keeping local-only as the safe default that I have to explicitly opt out of.

**US5 — Moving my database to managed hosting**
As a user who worries about losing data if my local drive fails, I want to move PostgreSQL to RDS with automated backups — and have the rest of the stack (running locally) seamlessly use the remote database through the VPN tunnel.

**US6 — Tearing it all down**
As a user who spun up cloud resources for testing, I want to run one command (`sst remove`) to delete everything in AWS — no orphaned EC2 instances, no forgotten S3 buckets, no surprise bills.

**US7 — Gradual migration**
As a user who's cautious about cloud, I want to move one component at a time (starting with Ollama), verify it works, then decide whether to move more — never forced into an all-or-nothing migration.

**US8 — Keeping costs visible**
As a user running GPU instances on AWS, I want to see estimated monthly cost per cloud service in the dashboard — so I can make informed decisions about what stays local vs. what goes to cloud.

---

## 4. Functional Requirements

### 4.1 Service Discovery — Consul

**FR-SD1:** Consul runs as a local compose service:

```yaml
consul:
  image: hashicorp/consul:1.19
  ports:
    - "8500:8500"   # UI + HTTP API
    - "8600:8600/udp" # DNS
  volumes:
    - ./consul/data:/consul/data
    - ./consul/config:/consul/config
  command: agent -server -bootstrap-expect=1 -ui -client=0.0.0.0
  restart: unless-stopped
```

**FR-SD2 — Service registration:**
- **Local services (automatic):** Consul watches the Docker socket and auto-registers containers with their compose service name and port. Uses the `consul-registrator` sidecar pattern or native Docker health check integration.
- **Cloud services (explicit):** SST deployment registers the service endpoint in Consul via HTTP API call as a post-deploy step.

**FR-SD3:** Every service has a Consul service definition:

```json
{
  "service": {
    "name": "ollama",
    "tags": ["llm", "gpu"],
    "port": 11434,
    "address": "ollama",
    "meta": {
      "location": "local",
      "mode": "docker"
    },
    "check": {
      "http": "http://ollama:11434/api/tags",
      "interval": "15s",
      "timeout": "5s"
    }
  }
}
```

When moved to cloud, only `address` and `meta.location` change:

```json
{
  "address": "10.13.13.2",
  "meta": {
    "location": "cloud",
    "mode": "ec2",
    "region": "eu-central-1"
  }
}
```

**FR-SD4:** The dashboard resolves all service endpoints via Consul catalog (`GET /v1/catalog/service/{name}`). If Consul is unavailable, falls back to environment variables (backward-compatible with PRD 1).

**FR-SD5:** Consul health checks replace dashboard-side probes. The dashboard reads check status from Consul (`GET /v1/health/service/{name}`) rather than probing endpoints directly. This means health checks work even for services the dashboard can't reach directly (e.g., internal services behind the VPN).

**FR-SD6:** Consul DNS is available on the Docker network. Services can resolve `ollama.service.consul` instead of relying on compose DNS. This is optional — compose DNS still works for local services.

### 4.2 Secure Networking — WireGuard

**FR-WG1:** WireGuard runs as a compose service, only active in hybrid mode:

```yaml
wireguard:
  image: linuxserver/wireguard
  cap_add:
    - NET_ADMIN
    - SYS_MODULE
  environment:
    - PUID=1000
    - PGID=1000
  volumes:
    - ./wireguard/config:/config
  ports:
    - "51820:51820/udp"
  sysctls:
    - net.ipv4.ip_forward=1
  restart: unless-stopped
  profiles: ["hybrid"]
```

**FR-WG2:** The `hybrid` compose profile activates WireGuard. Default `docker compose up` runs everything locally without it. `docker compose --profile hybrid up` enables the VPN tunnel.

**FR-WG3:** WireGuard uses a private subnet (`10.13.13.0/24`):
- Local machine: `10.13.13.1`
- First cloud peer (e.g., EC2 Ollama): `10.13.13.2`
- Additional peers: `10.13.13.3`, etc.

**FR-WG4:** The AWS side runs a WireGuard peer on each EC2 instance (provisioned by SST via user-data script). The tunnel is persistent — reconnects automatically.

**FR-WG5:** Consul advertises service addresses on the WireGuard subnet when the service is cloud-hosted. This means a service at `10.13.13.2:11434` is reachable from local containers via the WireGuard tunnel, and Consul resolves `ollama.service.consul` to that IP.

**FR-WG6:** WireGuard key pairs are generated during SST deploy and stored in AWS Secrets Manager. The local side's config is written to `./wireguard/config/wg0.conf`. Keys are never committed to git.

### 4.3 Component Deployment — SST v3

**FR-SST1 — Project structure:**

```typescript
// sst.config.ts
export default $config({
  app(input) {
    return {
      name: "paperless",
      removal: input?.stage === "production" ? "retain" : "remove",
      home: "aws",
      providers: { aws: { region: "eu-central-1" } },
    };
  },
  async run() {
    const config = loadStackConfig();  // reads stack.yaml

    // Only deploy components configured for cloud
    if (config.services.ollama.mode === "ec2") {
      deployOllamaEc2(config);
    }
    if (config.services.postgres.mode === "rds") {
      deployPostgresRds(config);
    }
    // ... etc for each component
  },
});
```

**FR-SST2 — Ollama on EC2 GPU (first cloud component):**

```typescript
function deployOllamaEc2(config: StackConfig) {
  const sg = new aws.ec2.SecurityGroup("OllamaSg", {
    ingress: [
      { protocol: "udp", fromPort: 51820, toPort: 51820, cidrBlocks: ["0.0.0.0/0"] }, // WireGuard
      { protocol: "tcp", fromPort: 11434, toPort: 11434, cidrBlocks: ["10.13.13.0/24"] }, // Ollama API (VPN only)
    ],
    egress: [{ protocol: "-1", fromPort: 0, toPort: 0, cidrBlocks: ["0.0.0.0/0"] }],
  });

  const instance = new aws.ec2.Instance("OllamaGpu", {
    instanceType: "g5.xlarge",          // 1x A10G GPU, 24GB VRAM
    ami: "ami-xxxxx",                   // Deep Learning AMI (Ubuntu, eu-central-1)
    subnetId: vpc.publicSubnetIds[0],
    securityGroups: [sg.id],
    userData: `#!/bin/bash
      # Install Ollama
      curl -fsSL https://ollama.com/install.sh | sh
      ollama serve &
      sleep 5
      ollama pull ${config.pipeline.classify.model}

      # Install WireGuard peer
      apt-get install -y wireguard
      cat > /etc/wireguard/wg0.conf << 'WG_EOF'
      [Interface]
      Address = 10.13.13.2/24
      PrivateKey = ${ollamaPrivateKey}
      [Peer]
      PublicKey = ${localPublicKey}
      Endpoint = ${localPublicIp}:51820
      AllowedIPs = 10.13.13.0/24
      PersistentKeepalive = 25
      WG_EOF
      systemctl enable --now wg-quick@wg0

      # Register in Consul
      curl -X PUT http://10.13.13.1:8500/v1/agent/service/register -d '{
        "Name": "ollama",
        "Address": "10.13.13.2",
        "Port": 11434,
        "Meta": {"location": "cloud", "mode": "ec2", "region": "eu-central-1"}
      }'
    `,
  });

  return { instanceId: instance.id, privateIp: instance.privateIp };
}
```

**FR-SST3 — All component SST definitions:**

| Component | Local | AWS Equivalent | SST Resource | Estimated Cost |
|-----------|-------|---------------|-------------|---------------|
| Ollama | Docker container | EC2 `g5.xlarge` (A10G GPU) | `aws.ec2.Instance` | ~$1.00/hr on-demand, ~$0.40/hr spot |
| PostgreSQL | `postgres:16` | RDS PostgreSQL `db.t4g.micro` | `aws.rds.Instance` | ~$15/mo |
| Redis | `redis:7` | ElastiCache `cache.t4g.micro` | `aws.elasticache.Cluster` | ~$12/mo |
| Paperless-ngx | Docker container | ECS Fargate (1 vCPU, 2GB) | `aws.ecs.FargateService` | ~$30/mo |
| paperless-ai-next | Docker container | ECS Fargate (0.5 vCPU, 1GB) | `aws.ecs.FargateService` | ~$15/mo |
| paperless-gpt | Docker container | ECS Fargate (0.5 vCPU, 1GB) | `aws.ecs.FargateService` | ~$15/mo |
| Document storage | Local bind mount | S3 (encrypted, versioned) | `sst.aws.Bucket` | ~$0.023/GB/mo |
| Dashboard | Docker container | Lambda + CloudFront | `sst.aws.Nextjs` | ~$5/mo |

**FR-SST4:** SST state stored in S3 (`home: "aws"`). Not Pulumi Cloud.

**FR-SST5:** All AWS resources in `eu-central-1` (Frankfurt) for EU data residency.

**FR-SST6:** `sst remove --stage dev` tears down everything. No orphaned resources.

### 4.4 OpenAI-Compatible API Adapter

**FR-API1:** The pipeline's LLM stages use an adapter that speaks to any backend:

```typescript
interface LLMClient {
  classify(text: string, taxonomy: Taxonomy): Promise<Classification>;
  suggestRule(text: string, classification: Classification): Promise<RuleSuggestion>;
  healthCheck(): Promise<{ healthy: boolean; model: string; latency: number }>;
}

function createLLMClient(config: LLMConfig): LLMClient {
  switch (config.api_format) {
    case "ollama":
      return new OllamaClient(config.url, config.model);
    case "openai":
      return new OpenAICompatibleClient(config.url, config.api_key, config.model);
  }
}
```

**FR-API2:** Supported backends:

| Backend | `api_format` | Notes |
|---------|-------------|-------|
| Local Ollama | `ollama` | Default. `http://ollama:11434` |
| EC2 Ollama | `ollama` | Same format, different URL (`http://10.13.13.2:11434`) |
| AWS Bedrock | `openai` | Via Bedrock OpenAI-compatible gateway |
| Together AI | `openai` | `https://api.together.xyz/v1` |
| Groq | `openai` | `https://api.groq.com/openai/v1` |
| Any OpenAI-compatible | `openai` | Custom endpoint + API key |

**FR-API3:** The dashboard settings UI (Services tab) shows for the LLM:
- Endpoint URL (editable)
- API format: dropdown (ollama / openai)
- API key (editable, masked)
- Model name (editable)
- Health status (green/red + latency)
- "Test Connection" button — sends a short classify request, shows result + latency

**FR-API4:** Changing the LLM config in the dashboard takes effect immediately. No container restart needed — the adapter is stateless and reads config on each request.

### 4.5 Central Configuration (Extended)

**FR-CF1:** `dashboard/config/stack.yaml` is extended from PRD 1:

```yaml
services:
  paperless:
    mode: local                        # local | ecs
    url: http://paperless:8000
    health: /accounts/login/
  ollama:
    mode: local                        # local | ec2 | openai-compatible
    url: http://ollama:11434
    health: /api/tags
    model: qwen3:14b
    api_format: ollama                 # ollama | openai
    api_key: ""                        # only for openai format
  postgres:
    mode: local                        # local | rds
    host: postgres
    port: 5432
    database: paperless
  redis:
    mode: local                        # local | elasticache
    host: redis
    port: 6379
  storage:
    mode: local                        # local | s3
    path: ./paperless/media/
    # s3:
    #   bucket: my-paperless-docs
    #   region: eu-central-1
    #   encryption: SSE-S3
    #   sync_to_local: true

network:
  wireguard:
    enabled: false
    subnet: 10.13.13.0/24
    local_ip: 10.13.13.1
    config_path: ./wireguard/config/wg0.conf
  consul:
    enabled: true
    url: http://consul:8500
```

**FR-CF2:** When the dashboard settings UI saves a change:
1. Writes to `stack.yaml`.
2. Updates the Consul service catalog via API.
3. If the change affects a Docker service's environment (e.g., Paperless DB host changes from `postgres` to an RDS endpoint), triggers a targeted container restart via Docker socket.

**FR-CF3:** `stack.yaml` is version-controlled. Sensitive values (API keys, passwords) are stored in `.env` (gitignored) and referenced as `${VAR_NAME}` in the YAML.

### 4.6 Dashboard Extensions

**FR-DE1 — Service cards show location:**
Each card displays a small badge: "local" (grey pill) or "cloud eu-central-1" (blue pill). The Ollama card additionally shows the API format (Ollama/OpenAI) and active model.

**FR-DE2 — Settings modal: Network tab:**
- WireGuard tunnel status: connected/disconnected, peer IPs, latency to each peer.
- Consul cluster: leader address, member count, registered services list.
- "Enable Hybrid" toggle — activates WireGuard profile.

**FR-DE3 — Settings modal: Storage tab:**
- Shows current storage mode (local path or S3 bucket).
- S3 configuration: bucket name, region, encryption method.
- Sync toggle: enable/disable bidirectional local↔S3 sync.
- Sync status: last sync time, files synced, any errors.

**FR-DE4 — Cost indicator (informational):**
For each cloud service, show estimated monthly cost based on the instance type / service tier. This is a static lookup table, not a real-time AWS billing query.

### 4.7 S3 Document Storage (Opt-in)

**FR-S3-1:** Document storage in S3 is **disabled by default**. Local bind-mount storage (`./paperless/media/`) is the default and always works.

**FR-S3-2:** When enabled:
- An S3 bucket is created via SST (`sst.aws.Bucket` with encryption and versioning).
- Paperless-ngx is configured to use S3 as its media storage backend (Paperless supports S3 natively via Django Storages).
- All new documents are stored in S3. Existing documents remain local unless explicitly migrated.

**FR-S3-3:** Local↔S3 sync (optional):
- When enabled, documents are stored in S3 AND synced to local storage.
- Sync is unidirectional by default: S3 → local (backup copy). Bidirectional available.
- Uses `aws s3 sync` or a background job in the dashboard.
- If S3 is unreachable, local storage continues to work. Documents are synced when connectivity returns.

**FR-S3-4:** S3 bucket configuration:
- Encryption: SSE-S3 (default) or SSE-KMS (configurable).
- Versioning: enabled (protects against accidental deletion).
- Lifecycle: no auto-deletion. User controls retention.
- Region: `eu-central-1` (same as all other resources).
- Bucket policy: private. No public access. Access via IAM role only.

### 4.8 Compose Integration

**FR-CI1:** New services added to `compose.yaml`:

```yaml
consul:
  image: hashicorp/consul:1.19
  ports:
    - "8500:8500"
    - "8600:8600/udp"
  volumes:
    - ./consul/data:/consul/data
    - ./consul/config:/consul/config
  command: agent -server -bootstrap-expect=1 -ui -client=0.0.0.0
  restart: unless-stopped

wireguard:
  image: linuxserver/wireguard
  cap_add:
    - NET_ADMIN
    - SYS_MODULE
  volumes:
    - ./wireguard/config:/config
  ports:
    - "51820:51820/udp"
  sysctls:
    - net.ipv4.ip_forward=1
  restart: unless-stopped
  profiles: ["hybrid"]
```

**FR-CI2:** `./consul/data/` and `./wireguard/config/` are gitignored.

**FR-CI3:** Dashboard `depends_on` updated to include `consul`.

**FR-CI4:** Consul service definitions for all existing services are placed in `./consul/config/services.json`, auto-loaded on startup.

### 4.9 API Routes (New/Extended)

| Route | Method | Description |
|-------|--------|-------------|
| `/api/consul/services` | GET | All registered services from Consul catalog |
| `/api/consul/services/:name` | PUT | Update a service's endpoint in Consul |
| `/api/consul/health` | GET | Consul cluster health summary |
| `/api/network/wireguard` | GET | WireGuard tunnel status, peer list |
| `/api/network/wireguard/enable` | POST | Enable hybrid mode (activate WireGuard) |
| `/api/storage/config` | GET | Current storage configuration |
| `/api/storage/config` | PUT | Update storage config (enable/disable S3) |
| `/api/storage/sync` | GET | S3 sync status |
| `/api/storage/sync` | POST | Trigger manual sync |

---

## 5. Non-Goals / Out of Scope

- **No multi-region** — all AWS resources in `eu-central-1`. Multi-region is a future concern.
- **No auto-scaling** — cloud instances are manually sized. No ASGs or Lambda concurrency tuning.
- **No CI/CD** — SST deploys are manual from the developer's machine.
- **No multi-user or RBAC** — single-user system. No team access control.
- **No Kubernetes** — ECS Fargate for containers, not EKS. Keeps it simple.
- **No custom domain for dashboard** — accessible via CloudFront URL when deployed. Custom domain is a post-deploy config.
- **No cost optimization automation** — cost indicators are informational. No auto-shutdown of idle EC2, no spot fleet management.
- **No data migration tooling** — moving existing local data to S3/RDS is a documented manual process, not an automated button.

---

## 6. Design Considerations

### Dashboard with Cloud Badges

```
┌──────────────────────────────────────────────────────────────────┐
│  Paperless Stack                    [Settings] [updated Xs]      │
├──────────────────────────────────────────────────────────────────┤
│ [Paperless ● local]  [AI Next ● local]  [Ollama ● cloud]       │
│  324 docs             291 AI-done         qwen3:14b 24GB VRAM   │
│                                           eu-central-1 g5.xl    │
│                                           ~$1.00/hr             │
│ [PostgreSQL ● rds]   [Redis ● local]     [Storage ● local]     │
│  eu-central-1         —                   ./paperless/media/     │
│  ~$15/mo                                                         │
└──────────────────────────────────────────────────────────────────┘
```

### Settings: Network Tab

```
┌──────────────────────────────────────────────────────────────────┐
│  Settings > Network                                              │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  WireGuard VPN                                    [● Connected]  │
│  ──────────────────────────────────────────────────────────────  │
│  Local IP:  10.13.13.1                                          │
│  Peers:                                                          │
│    10.13.13.2  ollama (ec2 g5.xlarge)    latency: 12ms  [● Up] │
│    10.13.13.3  postgres (rds)            latency: 8ms   [● Up] │
│                                                                  │
│  Consul Cluster                                   [● Healthy]   │
│  ──────────────────────────────────────────────────────────────  │
│  Leader: 10.13.13.1:8300                                        │
│  Members: 3 (1 server, 2 clients)                               │
│  Services: 8 registered, 8 healthy                              │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 7. Technical Considerations

### Stack (Additional)

| Layer | Choice | Why |
|-------|--------|-----|
| Service Discovery | Consul 1.19 | Health checks, KV store, DNS, catalog API, Docker integration |
| VPN | WireGuard | Kernel-level encryption, ~3ms overhead, simple config, proven |
| IaC | SST v3 | TypeScript-native, `sst.aws.Nextjs` for dashboard, raw AWS providers for EC2/RDS/ECS |
| AWS Adapter | OpenNext (via SST) | Next.js → Lambda adapter |
| S3 Client | AWS SDK v3 (`@aws-sdk/client-s3`) | Tree-shakeable, official |

### Consul Architecture

```
Local machine (compose network)          AWS VPC (eu-central-1)
┌─────────────────────────┐              ┌─────────────────────┐
│ consul (server)         │◄────────────►│ consul (client)     │
│   port 8500             │  WireGuard   │   on EC2 instance   │
│                         │   tunnel     │                     │
│ paperless  ──registered │              │ ollama  ──registered│
│ ai-next    ──registered │              │                     │
│ gpt-ocr    ──registered │              │                     │
│ dashboard  ──registered │              │                     │
│ questdb    ──registered │              │                     │
└─────────────────────────┘              └─────────────────────┘
```

Local Consul is the single server. Cloud instances run Consul agents (clients) that join via WireGuard. This is suitable for single-user / small deployments. For HA, Consul can run 3 servers — but that's out of scope.

### WireGuard Key Management

- **First deploy:** SST generates a WireGuard key pair for the EC2 peer. The private key is stored in AWS Secrets Manager. The public key is written to the local `wg0.conf`.
- **Key rotation:** Manual. User regenerates keys via `wg genkey` and redeploys.
- **Security:** Private keys never appear in SST state, git, or logs. Only in Secrets Manager and the WireGuard config files (which are gitignored).

### ECS Fargate Deployment Pattern

For containerized services (Paperless, AI-next, GPT-OCR):

```typescript
function deployToFargate(name: string, image: string, config: ServiceConfig) {
  const taskDef = new aws.ecs.TaskDefinition(`${name}Task`, {
    family: name,
    requiresCompatibilities: ["FARGATE"],
    networkMode: "awsvpc",
    cpu: config.cpu,
    memory: config.memory,
    containerDefinitions: JSON.stringify([{
      name,
      image,
      portMappings: [{ containerPort: config.port }],
      environment: Object.entries(config.env).map(([k, v]) => ({ name: k, value: v })),
      logConfiguration: {
        logDriver: "awslogs",
        options: {
          "awslogs-group": `/ecs/${name}`,
          "awslogs-region": "eu-central-1",
          "awslogs-stream-prefix": "ecs",
        },
      },
    }]),
  });

  const service = new aws.ecs.Service(`${name}Service`, {
    cluster: cluster.id,
    taskDefinition: taskDef.arn,
    desiredCount: 1,
    launchType: "FARGATE",
    networkConfiguration: {
      subnets: vpc.privateSubnetIds,
      securityGroups: [sg.id],
    },
  });
}
```

### Migration Path (per component)

Moving a component from local to cloud:

1. **Enable hybrid mode** — `docker compose --profile hybrid up` starts WireGuard.
2. **Deploy the component** — `sst deploy --stage dev` provisions the AWS resource.
3. **Update the dashboard** — change the service endpoint in Settings → Services. Dashboard writes to `stack.yaml` and updates Consul.
4. **Verify** — check the service card: health should be green, location badge should show "cloud."
5. **Stop the local container** — `docker compose stop ollama` (for example). Traffic flows to the cloud instance via WireGuard.

This is a manual, deliberate process. No automated failover.

### Cost Estimation Table (Static Lookup)

Used by the dashboard's cost indicator (FR-DE4):

```typescript
const COST_ESTIMATES: Record<string, { hourly: number; monthly: number }> = {
  "ec2:g5.xlarge": { hourly: 1.006, monthly: 724 },
  "ec2:g5.xlarge:spot": { hourly: 0.40, monthly: 288 },
  "rds:db.t4g.micro": { hourly: 0.018, monthly: 13 },
  "elasticache:cache.t4g.micro": { hourly: 0.016, monthly: 12 },
  "ecs:0.5vcpu-1gb": { hourly: 0.02, monthly: 15 },
  "ecs:1vcpu-2gb": { hourly: 0.04, monthly: 30 },
  "s3:per-gb": { hourly: 0, monthly: 0.023 },
  "sst-nextjs": { hourly: 0, monthly: 5 },
};
```

---

## 8. Success Metrics

| Metric | Target |
|--------|--------|
| Switch service local → cloud via settings UI | < 60 seconds (excluding AWS provisioning) |
| WireGuard tunnel latency | < 20ms (within same AWS region) |
| Consul service registration after SST deploy | < 30 seconds |
| Dashboard shows correct location badges | Within 1 health check cycle (< 35s) |
| Full stack SST deploy time (all components) | < 15 minutes |
| `sst remove` tears down everything | 0 orphaned resources |
| S3 sync lag (local → S3) | < 5 minutes for new documents |
| Cost indicator accuracy | Within 20% of actual AWS bill |

---

## 9. Open Questions

| # | Question | Owner | Notes |
|---|----------|-------|-------|
| OQ1 | Which EC2 GPU instance type for Ollama? | Marcus | `g5.xlarge` (A10G, 24GB VRAM) at ~$1/hr. `g5.2xlarge` (same GPU, more CPU) at ~$1.21/hr. Spot pricing available. |
| OQ2 | Consul ACL tokens for cloud agents? | Implementation | Local-only doesn't need ACLs. Cloud agents should use tokens to prevent unauthorized registration. |
| OQ3 | WireGuard key management — manual or SST-automated? | Implementation | SST can generate keys and inject via user-data. Manual is simpler for v1. |
| OQ4 | Should Paperless S3 storage use Django Storages or a custom backend? | Implementation | Django Storages (`django-storages[boto3]`) is the standard approach. Needs to be configured in Paperless env vars. |
| OQ5 | ECS tasks: Fargate or EC2-backed? | Marcus | Fargate is simpler (no instance management). EC2-backed is cheaper for steady-state. Start with Fargate. |
| OQ6 | S3 encryption — SSE-S3 or SSE-KMS? | Marcus | SSE-S3 is simpler and free. SSE-KMS adds CloudTrail audit trail but costs ~$1/mo per key. |
| OQ7 | How to handle Paperless-ngx secrets in ECS? | Implementation | AWS Secrets Manager for `PAPERLESS_SECRET_KEY` and `PAPERLESS_API_TOKEN`. SST can create and inject these. |
| OQ8 | Should the dashboard's WireGuard "enable" button actually modify compose profiles? | Implementation | Risky — dashboard modifying its own compose stack. Might be better as a documented manual step. |
| OQ9 | Bedrock — which models for classification? | Marcus | Claude Haiku (fast, cheap, ~$0.001/doc). Claude Sonnet for complex docs (~$0.01/doc). Both via Bedrock's OpenAI-compatible gateway. |
| OQ10 | What happens to pipeline timing when LLM is remote? | Implementation | Latency increases (network round-trip). The swimlane chart should show this clearly — remote LLM stages will be visibly longer. |
