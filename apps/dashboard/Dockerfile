# ── Stage 1: Builder ───────────────────────────────────────────────────────────
FROM node:22-alpine AS builder
RUN corepack enable && corepack prepare pnpm@latest --activate
WORKDIR /app
COPY package.json ./
RUN pnpm install
COPY . .
RUN pnpm build

# ── Stage 3: Runner ────────────────────────────────────────────────────────────
FROM node:22-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

# Copy standalone output
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public

# Collector runs as a sibling process alongside the Next.js server.
# It uses dockerode which is included in the standalone node_modules
# because it is listed in serverExternalPackages.
COPY --from=builder /app/collector.js ./collector.js

# Config dir — overridden by bind mount in compose
RUN mkdir -p /app/config

# Runs as root — required for Docker socket access (same as dozzle, pipeline-timing).
# This dashboard is local-only with no external exposure.

EXPOSE 3000
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"

# Start collector in background, then start the web server in foreground.
# If the collector crashes it is restarted by the shell loop.
# The container exits when server.js exits.
CMD ["sh", "-c", "node collector.js & node server.js"]
