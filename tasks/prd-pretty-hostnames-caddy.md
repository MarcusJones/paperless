# PRD: Pretty hostnames for the paperless stack via Caddy
## Status: Draft
## Last Updated: 2026-04-21

## 1. Problem Statement

Today every web-facing service in the stack is reached at `localhost:<port>`
on the WSL2 host — `localhost:8000` for Paperless, `:5000` for the dashboard,
`:9999` for Dozzle, `:3000` for paperless-ai-next, `:8080` for paperless-gpt,
`:3001` for Open WebUI, `:9000` for QuestDB. Eight services, eight port
numbers to remember. The dashboard maintains a registry of these URLs as the
de facto cheat sheet, which is the actual proof that the port-juggling has
become a UX problem.

The fix is to put a single reverse proxy on `:80` and address every service
by name: `paperless.pstack.localhost`, `dashboard.pstack.localhost`,
`dozzle.pstack.localhost`, etc. The user explicitly wants this as a quality-
of-life upgrade and is also explicitly worried about breaking working flows
(bookmarks, scripts, muscle memory). The PRD therefore covers a **phased
rollout**: this initial scope adds the proxy *alongside* the existing ports
so both URL schemes work; a follow-up PRD will drop the ports once Caddy
has proven stable for a week or two.

## 2. Goals & Success Metrics

- **G1 — Hostname access for every user-facing web service.** All 7
  user-facing services answer at `<svc>.pstack.localhost` from the Windows
  browser without editing `C:\Windows\System32\drivers\etc\hosts`.
  *Verify:* manual browser test of each URL after `docker compose up -d caddy`.

- **G2 — Zero regressions to existing access.** Every `localhost:<port>` URL
  in use today continues to work exactly as before.
  *Verify:* `scripts/diagnose.sh` passes; manual `curl localhost:8000/`,
  `localhost:11434/api/tags`, etc.

- **G3 — Pipeline integrity.** The full document pipeline (Tesseract → AI
  classify, plus the `ocr-pending` vision-OCR re-run path) keeps working.
  *Verify:* drop a PDF in consume folder, confirm AI tags appear; apply
  `ocr-pending` to a finished doc, confirm `advanced-ocr` and `processed`
  end up on it.

- **G4 — Dashboard surfaces the pretty URLs.** The dashboard's "Open"
  buttons take users to `<svc>.pstack.localhost`, not `localhost:<port>`.
  *Verify:* visit `http://dashboard.pstack.localhost`, click each "Open"
  button, confirm the target URL.

- **G5 — Trivial rollback.** If Caddy misbehaves, removing the
  `caddy` block from `compose.yaml` and `docker compose down caddy`
  restores the prior-state behavior with no other changes needed.
  *Verify:* by inspection of the diff; the change to per-service `ports:`
  blocks is **zero** in this PRD.

- **G6 — Streaming and WebSocket protocols are not regressed by the proxy.**
  Dozzle's live log tail (WebSocket) and Open WebUI's chat token streaming
  (long-poll) work identically through `dozzle.pstack.localhost` and
  `ollama.pstack.localhost`.
  *Verify:* manual smoke test of each.

## 3. User Stories

- **US-1** — As the operator of the paperless stack, I want to type
  `paperless.pstack.localhost` instead of `localhost:8000` so I stop
  context-switching between port numbers.
- **US-2** — As a power user, I want my existing bookmarks and scripts
  pointing at `localhost:<port>` to keep working unchanged so I'm not
  forced to migrate everything in one go.
- **US-3** — As a developer iterating on the dashboard, I want a single
  source of truth for both the legacy URL and the pretty URL so the
  registry doesn't drift.
- **US-4** — As the operator, I want a clear rollback path so trying this
  change is not a one-way door.

## 4. Functional Requirements

- **FR-1 (US-1).** A new `caddy` service in `compose.yaml` runs the
  `caddy:2-alpine` image, publishes only host port `80:80`, and mounts a
  read-only `./caddy/Caddyfile`. It depends on the seven user-facing
  services (`paperless`, `paperless-ai-next`, `paperless-gpt`,
  `open-webui`, `dozzle`, `dashboard`, `questdb`).

- **FR-2 (US-1).** A new `caddy/Caddyfile` defines exactly seven virtual
  hosts, each forwarding to its target via the compose-network DNS name:
  - `paperless.pstack.localhost` → `paperless:8000`
  - `ai.pstack.localhost` → `paperless-ai-next:3000`
  - `gpt.pstack.localhost` → `paperless-gpt:8080`
  - `ollama.pstack.localhost` → `open-webui:8080`
  - `dozzle.pstack.localhost` → `dozzle:8080`
  - `dashboard.pstack.localhost` → `dashboard:3000`
  - `questdb.pstack.localhost` → `questdb:9000`

- **FR-3 (US-2).** Existing per-service `ports:` blocks in `compose.yaml`
  are **not modified** in this PRD. `localhost:8000`, `:3000`, `:8080`,
  `:3001`, `:9999`, `:9000`, `:5000` all keep working. `ollama:11434`,
  `questdb:9009`, `questdb:8812` stay untouched too.

- **FR-4 (US-3).** `apps/dashboard/config/stack.yaml` gains a new optional
  field per service: `prettyUrl: http://<svc>.pstack.localhost`. The
  existing `url` field stays as-is (legacy port URL).

- **FR-5 (US-3).** `apps/dashboard/src/lib/config.ts` `ServiceConfig`
  interface gains `prettyUrl?: string`, and `buildDefaultConfig()` populates
  it for each service.

- **FR-6 (US-1).** `apps/dashboard/src/components/service-cards.tsx` "Open"
  button targets `prettyUrl` when present, otherwise falls back to `url`.
  Existing internal-only logic (Open button hidden if both are absent)
  is preserved.

- **FR-7 (US-1).** `README.md` and `CLAUDE.md` document the pretty URLs
  prominently in the daily-operations section, with the legacy port URLs
  shown as still-valid alternatives.

- **FR-8 (US-1, G6).** Caddy must pass through WebSocket upgrades and
  streamed/chunked HTTP responses without buffering. (Caddy 2 does this by
  default — no extra `flush_interval` or `header_upstream` directives
  needed; this requirement is kept explicit to gate the integration test.)

- **FR-9 (US-4).** A new `caddy/data/` directory is created and
  bind-mounted to the container's `/data`. The directory is added to
  `.gitignore`.

## 5. Non-Goals / Out of Scope

- **No port removal.** Per-service `ports:` blocks stay. Dropping them is a
  separate follow-up PRD (`prd-drop-legacy-ports.md`) intended for ~2 weeks
  after this lands, contingent on Caddy proving stable in daily use.
- **No HTTPS / no `tls internal`.** `.localhost` over plain HTTP is fine
  for local browsers. Not installing Caddy's root cert into Windows in
  this round.
- **No rescan-proxy exposure.** The internal sidecar stays internal — it
  is only called by Paperless workflow webhooks over the compose network.
- **No `gpu-monitor` / `pipeline-timing` exposure.** Same reason — they
  emit logs to Dozzle, not user-facing HTTP.
- **No QuestDB ILP / Postgres-wire proxy** (`:9009`, `:8812`). Caddy is
  HTTP-only; non-HTTP wire protocols stay on their published host ports.
- **No DNS server.** No dnsmasq, no Avahi, no Pi-hole. The whole point of
  `.localhost` is browsers resolve it without DNS.
- **No mDNS / `.local` TLD.** Bonjour conflicts and per-machine setup
  ritual ruled it out at plan time.
- **No new env vars or new dependencies in `package.json` /
  `requirements.txt`.** Caddy is a stock container image.

## 6. Design Considerations

Not applicable — no UI surface change beyond the dashboard "Open" button
targets, which is functional, not visual. The cards keep their current
layout.

## 7. Technical Considerations

### Why Caddy, not Traefik or nginx-proxy

A 7-service static stack doesn't benefit from Traefik's label-driven
auto-discovery. A 15-line Caddyfile is shorter than the equivalent label
soup spread across 7 service blocks, and it lives in one file that's easy
to grep and code-review. Caddy 2 also gives WebSocket upgrades and
streaming responses for free, without the `flush_interval` / `proxy_buffering off`
incantations nginx-proxy needs.

### Why `.localhost`, not `.local` / `.lab` / a custom TLD

Chromium-family browsers (Chrome, Edge) and modern Firefox treat
`*.localhost` as `127.0.0.1` per RFC 6761 — no `/etc/hosts` edit on
Windows, no per-developer machine setup, no friction adding new
subdomains. `.local` is hijacked by mDNS and stalls Windows DNS lookups.
Custom TLDs (`.lab`, `.test`, `.home`) require Administrator-edited host
files on Windows for every new subdomain.

### Why "phased" instead of "drop ports now"

See the **Trade-offs** section below — this is the central design
decision and the reason this PRD's scope is deliberately narrow.

### File integration points

- `compose.yaml` — adds the `caddy` service; nothing else changes.
- `caddy/Caddyfile` (NEW) — single file, ~25 lines including blank lines.
- `caddy/data/` (NEW dir) — bind-mount target; gitignored.
- `apps/dashboard/config/stack.yaml` — additive: new `prettyUrl` field per service.
- `apps/dashboard/src/lib/config.ts` — additive: new optional field on the
  type, and population in the env-fallback defaults.
- `apps/dashboard/src/components/service-cards.tsx` — one-line change to
  prefer `prettyUrl` over `url` for the Open button target.
- `README.md`, `CLAUDE.md` — additive documentation; no removals.
- `.gitignore` — append `caddy/data/`.

### Compose-network topology

Internal service-to-service URLs (e.g. `http://paperless:8000` referenced
in `paperless-ai-next`'s environment) are **untouched**. Containers reach
each other by service name over the default compose network — Caddy is
not in that path. The webhook chain (Paperless → paperless-ai-next →
rescan-proxy) is unaffected.

### Trade-offs: big-bang vs phased vs keep-both-forever

| Strategy | Pros | Cons | Risk |
|---|---|---|---|
| **Big-bang (drop ports same PR)** | Single canonical URL per service from day one. No documentation drift. No "which URL is real?" confusion. | Browser bookmarks die. Any external script or IDE plugin pointing at `localhost:<port>` dies. If Caddy itself misconfigures, *everything* is unreachable until rolled back — no fallback. Hard to diagnose ("did Caddy fail or is the hostname wrong?") because there's no working baseline to compare against. | **High.** Single point of failure on day one. |
| **Phased (this PRD: ship Caddy with ports kept; drop ports in v2)** | Zero instantaneous breakage. Caddy is provably-additive — if it doesn't work, nothing else degrades. Bookmarks survive the transition. Easy A/B compare ("hostname loads slowly but `localhost:8000` is fast → Caddy issue, not stack issue"). Naming is iterable: if `pstack` feels wrong after a week, change one file before ports get dropped. Rollback is `docker compose rm -sf caddy`. | Two URL schemes coexist for a window (~2 weeks). Documentation has to mention both temporarily. The actual port removal is deferred work that needs follow-through. | **Low.** Worst case is "Caddy doesn't help" — nothing actively breaks. |
| **Keep both forever** | Never breaks anything, period. Total flexibility. | Permanent documentation drift ("which URL do I cite in my PR?"). Port collision risk stays present forever (if a second compose project shows up). The complexity tax of two URLs per service is paid every time a new dev joins or a new service is added. The original UX problem (eight ports to juggle) only shrinks halfway — the legacy ports still show up in `docker compose ps` output. | **Medium-low.** Doesn't *break* anything but undermines the "single canonical URL" goal forever. |

**Recommendation: phased.** This PRD ships the additive half. After ~2
weeks of using the pretty URLs daily without issues, file the follow-up
PRD `prd-drop-legacy-ports.md` to remove `ports:` blocks, update the
dashboard's `url` field, and delete the legacy URLs from documentation.
That second PRD is one-paragraph short and one-commit small — the work
itself is mechanical. The risk reduction comes from doing the *risky*
half (introducing the proxy) decoupled from the *destructive* half
(removing the fallback).

If at any point during the 2-week soak you're confident it's working,
running the v2 PRD is a 10-minute commit — there's no penalty for
moving fast once you have evidence.

### Big-bang escape hatch

If you'd rather just commit, the diff to convert this phased PRD into a
big-bang PR is mechanical: in addition to the tasks below, delete the
`ports:` block from each of `paperless`, `paperless-ai-next`,
`paperless-gpt`, `open-webui`, `dozzle`, `dashboard`, and the `9000:9000`
entry from `questdb`. Nothing else changes. The functional requirements
above are unchanged; FR-3 just becomes a non-goal.

## 8. Open Questions

None — all questions resolved during plan-mode discovery. The locked
decisions are:
- Reverse proxy: Caddy
- TLD: `.localhost`
- Namespace label: `pstack`
- Port strategy: phased (this PRD adds Caddy alongside ports; v2 drops ports)
- HTTPS: deferred

---

## Implementation

### Pre-flight Requirements

> ⚠️ This project runs in a **VS Code dev container**. Dependencies cannot be
> installed at runtime. Any items listed here MUST be completed and the container
> rebuilt BEFORE running `/implement`.
> Starting a new Claude session after rebuilding is required.

**New packages:** None — `caddy:2-alpine` is a stock Docker Hub image
pulled at `docker compose up` time, not a devcontainer dependency.

**Environment variables:** None — Caddy reads its config from the mounted
Caddyfile.

**Other system changes:** None — no migrations, no external services, no
firewall changes (port 80 is free on the WSL2 host).

---

### Relevant Files

- `compose.yaml` — add `caddy` service block (~12 lines). No changes to other services.
- `caddy/Caddyfile` (NEW) — virtual-host definitions, one block per service.
- `caddy/data/.gitkeep` (NEW) — placeholder so the bind-mount dir exists in fresh clones.
- `.gitignore` — append `caddy/data/*` (keep `.gitkeep` tracked).
- `apps/dashboard/config/stack.yaml` — add `prettyUrl` per service.
- `apps/dashboard/src/lib/config.ts` — extend `ServiceConfig` interface; populate `prettyUrl` in `buildDefaultConfig()`.
- `apps/dashboard/src/components/service-cards.tsx` — extend `ServiceStatus` interface; "Open" button targets `prettyUrl ?? url`.
- `apps/dashboard/src/app/api/status/route.ts` — pass `prettyUrl` through in the `ServiceStatus` response (it already spreads `...config`, so this may be free; verify).
- `README.md` — add hostname section to "What you get" / "Daily operations".
- `CLAUDE.md` — add hostname row to the access table.

### Notes

- No automated test suite for the dashboard exists — verification is manual browser checks.
- All `docker compose ...` commands run from `/home/ubuntu/git/paperless/` (the WSL host project root). `docker compose -f compose.yaml ...` works from anywhere.
- The dashboard rebuild is `docker compose up -d --build dashboard`.

### Tasks

- [ ] **1.0 Caddy service scaffold**
  - [ ] 1.1 Create `caddy/Caddyfile` with the seven virtual-host blocks listed in FR-2.
  - [ ] 1.2 Create `caddy/data/.gitkeep`; append `caddy/data/*` (and `!caddy/data/.gitkeep`) to `.gitignore`.
  - [ ] 1.3 Add `caddy` service block to `compose.yaml` (image `caddy:2-alpine`, port `80:80`, mounts Caddyfile read-only and `caddy/data` read-write, depends_on the seven user-facing services). (FR-1)
  - [ ] 1.4 Run `docker compose config > /dev/null` on the WSL host to validate the merged compose file parses without errors.

- [ ] **2.0 Bring up Caddy and verify routing for all 7 services**
  - [ ] 2.1 `docker compose up -d caddy` on the WSL host; tail logs and confirm "serving" messages, no `dial tcp: lookup` errors. (FR-1)
  - [ ] 2.2 From the Windows browser, load each of the seven `<svc>.pstack.localhost` URLs and confirm the expected service responds (Paperless login, dashboard, dozzle, etc.). (FR-2)
  - [ ] 2.3 Verify Dozzle live tail still streams via `dozzle.pstack.localhost` (WebSocket smoke test). (FR-8, G6)
  - [ ] 2.4 Verify Open WebUI streams tokens from a small Ollama prompt via `ollama.pstack.localhost` (long-poll smoke test). (FR-8, G6)
  - [ ] 2.5 Verify the legacy `localhost:<port>` URLs (`:8000`, `:3000`, `:8080`, `:3001`, `:9999`, `:9000`, `:5000`, `:11434`) all still respond with the same content as before. (FR-3, G2)

- [ ] **3.0 Dashboard registry: surface the pretty URLs**
  - [ ] 3.1 Edit `apps/dashboard/config/stack.yaml`: add a `prettyUrl: http://<svc>.pstack.localhost` line under each of the 7 service entries (paperless, paperless-ai-next, paperless-gpt, open-webui, dozzle, questdb, and a 7th — note `dashboard` itself isn't listed in stack.yaml today; verify and add if missing). (FR-4)
  - [ ] 3.2 Edit `apps/dashboard/src/lib/config.ts`: add `prettyUrl?: string` to the `ServiceConfig` interface; populate it in `buildDefaultConfig()` for each service. (FR-5)
  - [ ] 3.3 Edit `apps/dashboard/src/components/service-cards.tsx`: extend `ServiceStatus` interface with `prettyUrl?: string`; change the Open button `href={svc.url}` to `href={svc.prettyUrl ?? svc.url}`. Preserve the existing "hide Open if no url" logic — the new check becomes "hide if neither prettyUrl nor url is set". (FR-6)
  - [ ] 3.4 Verify `apps/dashboard/src/app/api/status/route.ts` passes `prettyUrl` through (the `...config` spread should handle this automatically — confirm by reading the response shape).
  - [ ] 3.5 `docker compose up -d --build dashboard` on the WSL host. From the Windows browser, open `dashboard.pstack.localhost`, hover/click each "Open" button and confirm the target is `<svc>.pstack.localhost`. (FR-6)

- [ ] **4.0 Documentation**
  - [ ] 4.1 `README.md`: add a "URLs" subsection in the "What you get" or "Daily operations" area, listing both the pretty URL and the legacy port URL per service. Mark pretty URL as the recommended default. (FR-7)
  - [ ] 4.2 `CLAUDE.md`: add the hostname table to the operations area; note that internal-to-stack calls still use service DNS (unchanged), and the devcontainer-to-host pattern (`http://172.17.0.1:8000`) is also unchanged. (FR-7)
  - [ ] 4.3 Update the per-service `# URL: http://localhost:…` comments in `compose.yaml` to mention both URLs (e.g. `# URLs: http://paperless.pstack.localhost (preferred) | http://localhost:8000 (legacy)`). (FR-7)

- [ ] **5.0 End-to-end pipeline + rollback verification**
  - [ ] 5.1 Drop a fresh PDF in `paperless/consume/`. Confirm via `paperless.pstack.localhost` that the doc ingests, gets Tesseract OCR'd, and is auto-classified by paperless-ai-next within ~30s. (G3)
  - [ ] 5.2 Apply `ocr-pending` to a previously-processed doc via the Paperless UI; confirm the doc ends up with both `advanced-ocr` and `processed` tags after vision OCR + reclassification completes. Rescan-proxy must remain unreachable from outside the compose network (no `rescan-proxy.pstack.localhost`). (G3, non-goal)
  - [ ] 5.3 Run `./scripts/diagnose.sh` on the WSL host. All 10 checks must pass (this script uses `localhost:11434` for Ollama, which we deliberately kept). (G2)
  - [ ] 5.4 Confirm rollback: stop and remove only the Caddy container with `docker compose rm -sf caddy`. Verify all eight `localhost:<port>` URLs still respond. Restart Caddy with `docker compose up -d caddy` to leave the system in the desired state. (G5)

### Progress Log

| Date | Task | Notes |
|------|------|-------|
| | | |
