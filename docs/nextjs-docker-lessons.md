# Next.js Dashboard — Docker & Runtime Lessons Learned

Accumulated during PRD 1 (Dashboard & Pipeline Visibility) implementation, April 2026.

---

## 1. pnpm + Multi-stage Docker builds: don't copy `node_modules` across stages

**Problem:** Classic multi-stage pattern (deps stage → builder stage) breaks with pnpm.

```dockerfile
# ❌ BROKEN with pnpm
FROM node:22-alpine AS deps
RUN pnpm install

FROM node:22-alpine AS builder
COPY --from=deps /app/node_modules ./node_modules  # symlinks point to a store that doesn't exist here
RUN pnpm build  # → Cannot find module '/app/node_modules/next/dist/bin/next'
```

pnpm uses a content-addressable store (`~/.local/share/pnpm/store`). `node_modules` entries are symlinks into that store. Copying `node_modules` to a new stage leaves dangling symlinks.

**Fix:** Install and build in the same stage.

```dockerfile
# ✅ WORKS
FROM node:22-alpine AS builder
RUN corepack enable && corepack prepare pnpm@latest --activate
WORKDIR /app
COPY package.json ./
RUN pnpm install
COPY . .
RUN pnpm build
```

---

## 2. Always add `.dockerignore` before `COPY . .`

**Problem:** Without `.dockerignore`, `COPY . .` copies the devcontainer's `node_modules` into the image — overwriting the freshly `pnpm install`'d ones. The devcontainer modules have symlinks built for the host OS and glibc; Alpine uses musl. Same error as #1.

**Fix:** `apps/dashboard/.dockerignore`:
```
node_modules
.next
.turbo
*.tsbuildinfo
```

---

## 3. `instrumentation.node.ts` is NOT compiled in Next.js standalone output

**Problem:** Next.js 15.3 introduced `instrumentation.node.ts` as a Node.js-only alternative to `instrumentation.ts`. But in `output: "standalone"` mode (used for Docker), only `instrumentation.ts` is compiled to `.next/server/instrumentation.js`. The `.node.ts` file sits in `src/` as dead source — `register()` is never called.

```bash
# Confirms the problem:
docker compose exec dashboard find . -name "instrumentation*"
# → ./.next/server/instrumentation.js     ✓ (the shim)
# → ./src/instrumentation.node.ts         ✗ (uncompiled source, ignored at runtime)
```

**Fix:** Don't use `instrumentation.ts` for background processes at all. Run a sibling Node.js process instead (see #5).

---

## 4. Turbopack statically analyzes `instrumentation.ts` for Edge runtime — native modules fail the build

**Problem:** Turbopack analyzes `instrumentation.ts` for BOTH Node.js and Edge runtimes, following ALL imports (including dynamic `await import()`). Any native module in the import chain (e.g., `dockerode → ssh2 → cpu-features → cpufeatures.node`) causes a fatal build error:

```
Error: Turbopack build failed with 1 errors:
Module not found: Can't resolve '../build/Release/cpufeatures.node'
Import traces:
  Edge Instrumentation:
    ./src/lib/docker.ts → ./src/instrumentation.ts
```

`serverExternalPackages` prevents bundling but does NOT prevent Edge static analysis.

**Fix (build):** Keep `instrumentation.ts` completely clean — no Node.js-only imports, even dynamic ones. Move all heavy server-side startup code out of instrumentation entirely.

---

## 5. Background collectors belong in a sibling process, not `instrumentation.ts`

**The right pattern for startup background jobs in a Next.js Docker container:**

```dockerfile
# Copy collector alongside standalone output
COPY --from=builder /app/collector.js ./collector.js

# Start collector in background, server in foreground
CMD ["sh", "-c", "node collector.js & node server.js"]
```

**Benefits over `instrumentation.ts`:**
- Collector crashes don't affect the web server
- No Next.js runtime constraints (can freely import Node.js modules)
- Logs appear alongside server logs in `docker compose logs`
- Not affected by Edge/Node.js runtime analysis issues

**Note:** `serverExternalPackages` (e.g., `dockerode`) ARE copied to `standalone/node_modules`, so the collector can `require('dockerode')` without a separate install step.

---

## 6. `docker compose restart` vs rebuild — know which you need

| Change made to | Command needed |
|----------------|---------------|
| A file baked into the image (source code, config copied by Dockerfile) | `docker compose build <service> && docker compose up -d <service>` |
| A bind-mounted file (e.g., `stack.yaml`, `boards.yaml`) | `docker compose restart <service>` |
| An environment variable in `compose.yaml` | `docker compose up -d <service>` (recreates) |

`docker compose restart` reuses the existing image — it does NOT pick up source code changes.

---

## 7. Docker socket access requires root (or docker group membership)

**Problem:** A container running as a non-root user gets `EACCES /var/run/docker.sock`. The socket is owned by `root:docker` (mode 660) on the host.

```
[collector] Pipeline tailer error: connect EACCES /var/run/docker.sock
```

**Fix:** For local-only internal tools (dozzle, pipeline-timing, dashboard collector), running as root in the container is acceptable. Remove the `USER <non-root>` directive from the Dockerfile.

If you must run as non-root: add the user to a `docker` group with the same GID as the host's docker socket group — but the GID varies by host, making this fragile in portable images.

---

## 8. QuestDB 8.2.1 does not support `TTL` in `CREATE TABLE`

**Problem:** `PARTITION BY HOUR TTL 7d` causes `unexpected token [TTL]` in QuestDB 8.2.1. TTL/retention may be a feature added in a later version.

**Fix:** Omit `TTL` from DDL. Manage data retention manually or via the QuestDB UI if needed.

```sql
-- ❌
CREATE TABLE gpu_metrics (...) TIMESTAMP(ts) PARTITION BY HOUR TTL 7d;

-- ✅
CREATE TABLE IF NOT EXISTS gpu_metrics (...) TIMESTAMP(ts) PARTITION BY HOUR;
```

---

## 9. Dozzle log URLs require the container short ID, not the name

**Problem:** `http://localhost:9999/container/paperless-paperless-1` returns 404. Dozzle uses the Docker short ID (12-char hex) in its URLs.

**Fix:** Resolve container names → IDs server-side via `docker.listContainers()`, return the short ID in the `/api/status` response, and build the URL from it:

```
http://localhost:9999/container/0dc5ad80d81d   ✓
http://localhost:9999/container/paperless-paperless-1   ✗
```

Short ID = `container.Id.slice(0, 12)` from the Docker API response.

---

## 10. Next.js `instrumentationHook` experimental flag was removed in v15

```typescript
// ❌ Next.js 15+ — this key doesn't exist in ExperimentalConfig
experimental: {
  instrumentationHook: true,
}

// ✅ Instrumentation is stable — no flag needed
```

---

## 11. Comply with `.claude/docs/Unified tech stack reference.md` for new apps

Checklist when scaffolding a new Next.js app in this repo:

- [ ] `next` version matches reference (currently 16.x)
- [ ] `turbopack: {}` in `next.config.ts`
- [ ] Dev script uses `--turbopack` flag: `next dev --turbopack -p <port>`
- [ ] `turbo.json` `lint` task: `"dependsOn": ["^build"]` (not `"^lint"`)
- [ ] Package named `@app/<name>` (apps) or `@repo/<name>` (packages)
- [ ] `pnpm-workspace.yaml` at repo root covers `apps/*` and `packages/*`
