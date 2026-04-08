import { NextResponse } from "next/server";
import Dockerode from "dockerode";
import { readConfig, type ServiceConfig } from "@/lib/config";

export const dynamic = "force-dynamic";
export const revalidate = 0;

interface ServiceStatus extends ServiceConfig {
  key: string;
  status: "green" | "yellow" | "red";
  latencyMs: number;
  dozzleContainerId?: string; // short 12-char Docker ID for Dozzle URL
  stats?: Record<string, unknown>;
}

// Resolve container names → short IDs via Docker socket.
// Returns {} gracefully if Docker is unavailable (e.g. devcontainer).
async function resolveContainerIds(
  names: string[]
): Promise<Record<string, string>> {
  try {
    const docker = new Dockerode({ socketPath: "/var/run/docker.sock" });
    const containers = await docker.listContainers({ all: false });
    const map: Record<string, string> = {};
    for (const c of containers) {
      const shortId = c.Id.slice(0, 12);
      for (const rawName of c.Names) {
        const name = rawName.replace(/^\//, "");
        if (names.includes(name)) {
          map[name] = shortId;
        }
      }
    }
    return map;
  } catch {
    return {};
  }
}

// Probe a single service endpoint and measure latency.
async function probeService(
  key: string,
  config: ServiceConfig
): Promise<ServiceStatus> {
  const start = Date.now();
  try {
    const res = await fetch(config.probeUrl, {
      cache: "no-store",
      signal: AbortSignal.timeout(5000),
    });
    const latencyMs = Date.now() - start;
    const status = res.ok || (res.status >= 300 && res.status < 400)
      ? "green"
      : "yellow";

    const stats = await fetchStats(key, config);
    return { ...config, key, status, latencyMs, stats };
  } catch {
    return { ...config, key, status: "red", latencyMs: Date.now() - start };
  }
}

// Fetch service-specific stats.
async function fetchStats(
  key: string,
  config: ServiceConfig
): Promise<Record<string, unknown> | undefined> {
  try {
    if (key === "paperless") {
      return await fetchPaperlessStats(config.internalUrl);
    }
    if (key === "ollama") {
      return await fetchOllamaStats(config.internalUrl);
    }
    if (key === "questdb") {
      return await fetchQuestDbStats();
    }
  } catch {
    // stats are best-effort
  }
  return undefined;
}

async function fetchPaperlessStats(
  baseUrl: string
): Promise<Record<string, unknown>> {
  const token = process.env.PAPERLESS_API_TOKEN;
  if (!token) return {};

  const headers = { Authorization: `Token ${token}` };

  const [docsRes, statsRes] = await Promise.allSettled([
    fetch(`${baseUrl}/api/documents/?page_size=1`, {
      headers,
      cache: "no-store",
      signal: AbortSignal.timeout(4000),
    }),
    fetch(`${baseUrl}/api/statistics/`, {
      headers,
      cache: "no-store",
      signal: AbortSignal.timeout(4000),
    }),
  ]);

  const result: Record<string, unknown> = {};

  if (docsRes.status === "fulfilled" && docsRes.value.ok) {
    const data = (await docsRes.value.json()) as { count: number };
    result.docCount = data.count;
  }

  if (statsRes.status === "fulfilled" && statsRes.value.ok) {
    const data = (await statsRes.value.json()) as Record<string, unknown>;
    result.stats = data;
  }

  return result;
}

async function fetchOllamaStats(
  baseUrl: string
): Promise<Record<string, unknown>> {
  const [tagsRes, psRes] = await Promise.allSettled([
    fetch(`${baseUrl}/api/tags`, {
      cache: "no-store",
      signal: AbortSignal.timeout(4000),
    }),
    fetch(`${baseUrl}/api/ps`, {
      cache: "no-store",
      signal: AbortSignal.timeout(4000),
    }),
  ]);

  const result: Record<string, unknown> = {};

  if (tagsRes.status === "fulfilled" && tagsRes.value.ok) {
    const data = (await tagsRes.value.json()) as { models: { name: string }[] };
    result.modelCount = data.models?.length ?? 0;
  }

  if (psRes.status === "fulfilled" && psRes.value.ok) {
    const data = (await psRes.value.json()) as {
      models: {
        name: string;
        size_vram: number;
      }[];
    };
    if (data.models?.length > 0) {
      const m = data.models[0];
      result.activeModel = m.name;
      result.vramUsedMb = Math.round(m.size_vram / 1024 / 1024);
    }
  }

  return result;
}

async function fetchQuestDbStats(): Promise<Record<string, unknown>> {
  const questdbUrl = process.env.QUESTDB_URL ?? "http://questdb:9000";
  try {
    const res = await fetch(
      `${questdbUrl}/exec?query=${encodeURIComponent(
        "SELECT count() FROM gpu_metrics"
      )}`,
      { cache: "no-store", signal: AbortSignal.timeout(3000) }
    );
    if (!res.ok) return {};
    const data = (await res.json()) as {
      dataset: [[number]];
    };
    return { gpuRows: data.dataset?.[0]?.[0] ?? 0 };
  } catch {
    return {};
  }
}

export async function GET() {
  const config = readConfig();

  const containerNames = Object.values(config.services).map(
    (s) => s.dozzleContainer
  );

  const [results, idMap] = await Promise.all([
    Promise.all(
      Object.entries(config.services).map(([key, svc]) =>
        probeService(key, svc)
      )
    ),
    resolveContainerIds(containerNames),
  ]);

  const withIds = results.map((r) => ({
    ...r,
    dozzleContainerId: idMap[r.dozzleContainer],
  }));

  return NextResponse.json(withIds, {
    headers: { "Cache-Control": "no-store" },
  });
}
