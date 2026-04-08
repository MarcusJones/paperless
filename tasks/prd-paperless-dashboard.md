# Paperless Dashboard & Hybrid Cloud Platform — PRD Index

**Status:** Draft
**Author:** Marcus Jones
**Date:** 2026-04-08

---

This feature is split into 3 standalone PRDs that build on each other sequentially:

## PRD Series

| # | PRD | Scope | Depends on |
|---|-----|-------|-----------|
| 1 | [Dashboard & Pipeline Visibility](prd-dashboard-visibility.md) | Next.js 16 dashboard, service cards, GPU/pipeline timeline (ECharts), QuestDB, data collection, settings modal, Turborepo monorepo setup | — |
| 2 | [Smart Document Pipeline](prd-smart-pipeline.md) | Triage routing (metadata heuristics + LLM pre-screen), fast vs. vision OCR paths, fuzzy text matching rule engine, LLM-to-rule feedback loop, suggestions queue | PRD 1 |
| 3 | [Hybrid Cloud Architecture](prd-hybrid-cloud.md) | Consul service discovery, WireGuard VPN, SST v3 IaC for all components (EC2 GPU, RDS, ECS, S3), OpenAI-compatible API adapter, central config, cloud badges | PRD 1 + 2 |

## Document Pipeline (Target Architecture)

```
Upload → Triage (metadata) → OCR (fast or vision) → Rule Engine (fuzzy match)
                                                         ↓ matched → done
                                                         ↓ unmatched → LLM → tag + suggest new rules
```

## Deployment Spectrum

```
All Local (default)  ←──────────────────────────────→  All Cloud
├── docker compose up                                    ├── sst deploy
├── everything on one machine                            ├── everything in AWS eu-central-1
└── zero cloud cost                                      └── ~$100-800/mo depending on components

                    Hybrid (mix and match)
                    ├── Ollama on EC2 GPU, rest local
                    ├── PostgreSQL on RDS, rest local
                    ├── Storage on S3, rest local
                    └── any combination via dashboard settings
```

## Key Design Decisions

1. **Smart pipeline** replaces fixed 3-stage flow — triage routes by document complexity, rule engine handles known patterns, LLM only processes unmatched docs.
2. **Rule engine + suggestions queue** — LLM proposes rules, user approves. System gets smarter over time without manual rule authoring.
3. **Consul for service discovery** — no hardcoded hostnames. Services register themselves, dashboard reads from Consul catalog.
4. **WireGuard for secure networking** — encrypted tunnel between local and cloud. Services talk as if on same network.
5. **SST v3 for IaC** — TypeScript-native, `sst.aws.Nextjs` for dashboard, raw AWS providers for everything else. State in S3.
6. **OpenAI-compatible API adapter** — LLM layer works with any provider (Ollama, Bedrock, Together, Groq) via config change.
7. **Data sovereignty first** — document storage is local-only by default. S3 is opt-in, encrypted, in user's own AWS account.
