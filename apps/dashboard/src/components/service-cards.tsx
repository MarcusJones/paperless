"use client";

import { useEffect, useState, useCallback } from "react";

interface ServiceStatus {
  key: string;
  name: string;
  url: string;
  dozzleContainer: string;
  status: "green" | "yellow" | "red";
  latencyMs: number;
  stats?: {
    docCount?: number;
    activeModel?: string;
    vramUsedMb?: number;
    gpuRows?: number;
  };
}

const STATUS_COLOR: Record<string, string> = {
  green: "bg-green-500",
  yellow: "bg-yellow-400",
  red: "bg-red-500",
};

const DOZZLE_BASE = "http://localhost:9999";

function ServiceCard({ svc }: { svc: ServiceStatus }) {
  const dozzleUrl = `${DOZZLE_BASE}/container/${svc.dozzleContainer}`;

  return (
    <div className="rounded-xl border border-neutral-800 bg-neutral-900 p-4 flex flex-col gap-3 min-w-[180px]">
      {/* Header */}
      <div className="flex items-center gap-2">
        <span
          className={`h-2.5 w-2.5 rounded-full shrink-0 ${STATUS_COLOR[svc.status] ?? "bg-neutral-600"}`}
          title={svc.status}
        />
        <span className="text-sm font-semibold text-neutral-100 truncate">
          {svc.name}
        </span>
      </div>

      {/* Stats */}
      <div className="flex flex-col gap-1 text-xs text-neutral-400 font-mono min-h-[2.5rem]">
        {svc.stats?.docCount !== undefined && (
          <span>{svc.stats.docCount.toLocaleString()} docs</span>
        )}
        {svc.stats?.activeModel && (
          <span className="text-orange-400">{svc.stats.activeModel}</span>
        )}
        {svc.stats?.vramUsedMb !== undefined && (
          <span>{(svc.stats.vramUsedMb / 1024).toFixed(1)} GB VRAM</span>
        )}
        {svc.stats?.gpuRows !== undefined && (
          <span>{svc.stats.gpuRows.toLocaleString()} rows</span>
        )}
        {svc.latencyMs > 0 && svc.status !== "red" && (
          <span className="text-neutral-600">{svc.latencyMs}ms</span>
        )}
      </div>

      {/* Buttons */}
      <div className="flex gap-2 mt-auto">
        <a
          href={svc.url}
          target="_blank"
          rel="noopener noreferrer"
          className="flex-1 rounded-md border border-neutral-700 bg-neutral-800 px-2 py-1 text-xs text-neutral-300 text-center hover:bg-neutral-700 transition-colors"
        >
          Open
        </a>
        <a
          href={dozzleUrl}
          target="_blank"
          rel="noopener noreferrer"
          className="flex-1 rounded-md border border-neutral-700 bg-neutral-800 px-2 py-1 text-xs text-neutral-300 text-center hover:bg-neutral-700 transition-colors"
        >
          Logs
        </a>
      </div>
    </div>
  );
}

export function ServiceCards() {
  const [services, setServices] = useState<ServiceStatus[]>([]);
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    try {
      const res = await fetch("/api/status", { cache: "no-store" });
      if (res.ok) {
        const data = (await res.json()) as ServiceStatus[];
        setServices(data);
        setLastUpdated(new Date());
      }
    } catch {
      // silently ignore — cards keep showing last known state
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
    const interval = setInterval(() => void refresh(), 30_000);
    return () => clearInterval(interval);
  }, [refresh]);

  if (loading) {
    return (
      <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-7 gap-3">
        {Array.from({ length: 7 }).map((_, i) => (
          <div
            key={i}
            className="rounded-xl border border-neutral-800 bg-neutral-900 h-32 animate-pulse"
          />
        ))}
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-3">
      <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-7 gap-3">
        {services.map((svc) => (
          <ServiceCard key={svc.key} svc={svc} />
        ))}
      </div>
      {lastUpdated && (
        <p className="text-xs text-neutral-600 font-mono text-right">
          services updated {lastUpdated.toLocaleTimeString()}
        </p>
      )}
    </div>
  );
}
