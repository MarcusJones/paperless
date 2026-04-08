"use client";

import { useEffect, useState, useCallback, useRef } from "react";
import ReactECharts from "echarts-for-react";
import type { EChartsOption } from "echarts";

interface GpuMetric {
  ts: string;
  gpu_pct: number;
  vram_used: number;
  vram_total: number;
}

interface PipelineEvent {
  ts: string;
  doc_id: number;
  title: string;
  stage: string;
  model_name: string;
  pages: number;
}

// Pipeline stage → display label + color
const STAGE_META: Record<string, { label: string; color: string }> = {
  ingest_start:     { label: "Ingest",    color: "#3b82f6" }, // blue
  ingest_end:       { label: "Ingest",    color: "#3b82f6" },
  ocr_start:        { label: "Vision OCR", color: "#f97316" }, // orange
  ocr_end:          { label: "Vision OCR", color: "#f97316" },
  classify_start:   { label: "AI Classify", color: "#22c55e" }, // green
  classify_end:     { label: "AI Classify", color: "#22c55e" },
};

interface DocSegment {
  docId: number;
  title: string;
  stage: string;
  model: string;
  startMs: number;
  endMs: number;
  color: string;
  pages: number;
}

// Group events into [start, end] pairs per doc per stage type.
function buildSegments(events: PipelineEvent[]): {
  segments: DocSegment[];
  docOrder: number[];
} {
  // Collect start timestamps keyed by `docId:stagePrefix`
  const startTimes: Record<string, { ts: number; model: string; pages: number; title: string }> =
    {};
  const segments: DocSegment[] = [];
  const docSet = new Set<number>();

  for (const e of events) {
    const docId = e.doc_id;
    docSet.add(docId);
    const ts = new Date(e.ts).getTime();
    const isStart = e.stage.endsWith("_start");
    const isEnd = e.stage.endsWith("_end");
    const prefix = e.stage.replace(/_start$/, "").replace(/_end$/, "");
    const key = `${docId}:${prefix}`;

    if (isStart) {
      startTimes[key] = { ts, model: e.model_name, pages: e.pages, title: e.title };
    } else if (isEnd && startTimes[key]) {
      const start = startTimes[key];
      const meta = STAGE_META[e.stage] ?? { label: e.stage, color: "#6b7280" };
      segments.push({
        docId,
        title: e.title || start.title,
        stage: meta.label,
        model: start.model || e.model_name,
        startMs: start.ts,
        endMs: ts,
        color: meta.color,
        pages: start.pages || e.pages,
      });
      delete startTimes[key];
    }
  }

  // Keep most recent 20 docs
  const allDocs = Array.from(docSet);
  const docOrder = allDocs.slice(-20);

  return { segments, docOrder };
}

function buildChartOption(
  gpuData: GpuMetric[],
  events: PipelineEvent[]
): EChartsOption {
  const now = Date.now();
  const windowStart = now - 60 * 60 * 1000;

  // GPU line series data
  const gpuPoints = gpuData.map((m) => [new Date(m.ts).getTime(), m.gpu_pct]);
  const vramPoints = gpuData.map((m) => {
    const pct = m.vram_total > 0 ? (m.vram_used / m.vram_total) * 100 : 0;
    return [new Date(m.ts).getTime(), Math.round(pct)];
  });

  const { segments, docOrder } = buildSegments(events);

  // Build swimlane custom series items
  const swimItems = segments
    .filter((s) => docOrder.includes(s.docId))
    .map((s) => {
      const rowIdx = docOrder.indexOf(s.docId);
      return {
        value: [rowIdx, s.startMs, s.endMs, s.stage, s.docId, s.title, s.model, s.pages],
        itemStyle: { color: s.color, opacity: 0.85 },
      };
    });

  const docLabels = docOrder.map((id) => {
    const title =
      events.find((e) => e.doc_id === id)?.title ?? `doc_${id}`;
    const short = title.length > 22 ? title.slice(0, 20) + "…" : title;
    return `#${id} ${short}`;
  });

  const hasSwimData = docOrder.length > 0;

  return {
    backgroundColor: "transparent",
    animation: false,
    tooltip: {
      trigger: "item",
      backgroundColor: "#1a1a1a",
      borderColor: "#333",
      textStyle: { color: "#e5e5e5", fontSize: 12, fontFamily: "monospace" },
      formatter: (params: unknown) => {
        const p = params as {
          seriesName: string;
          value: (string | number)[];
          data?: { value: (string | number)[] };
        };
        if (p.seriesName === "swimlane") {
          const v = p.value;
          const durationS = Math.round((Number(v[2]) - Number(v[1])) / 1000);
          const pages = Number(v[7]);
          return [
            `<b>#${v[4]}</b> — ${v[5]}`,
            `Stage: ${v[3]}`,
            `Model: ${v[6]}`,
            `Duration: ${durationS}s` + (pages > 0 ? ` (${pages}pg)` : ""),
          ].join("<br/>");
        }
        // GPU lines
        const ts = new Date(Number((p.value as number[])[0])).toLocaleTimeString();
        const val = (p.value as number[])[1];
        return `${p.seriesName}<br/>${ts}<br/><b>${val}%</b>`;
      },
    },
    grid: [
      { left: 60, right: 20, top: 16, height: hasSwimData ? "45%" : "80%" },
      ...(hasSwimData
        ? [{ left: 60, right: 20, top: "58%", bottom: 30 }]
        : []),
    ],
    xAxis: [
      {
        type: "time",
        gridIndex: 0,
        min: windowStart,
        max: now,
        axisLabel: { color: "#666", fontSize: 11 },
        axisLine: { lineStyle: { color: "#333" } },
        splitLine: { lineStyle: { color: "#222" } },
      },
      ...(hasSwimData
        ? [
            {
              type: "time" as const,
              gridIndex: 1,
              min: windowStart,
              max: now,
              axisLabel: { show: false },
              axisLine: { lineStyle: { color: "#333" } },
              splitLine: { lineStyle: { color: "#222" } },
            },
          ]
        : []),
    ],
    yAxis: [
      {
        type: "value",
        gridIndex: 0,
        min: 0,
        max: 100,
        interval: 25,
        axisLabel: { color: "#666", fontSize: 11, formatter: "{value}%" },
        splitLine: { lineStyle: { color: "#222" } },
      },
      ...(hasSwimData
        ? [
            {
              type: "category" as const,
              gridIndex: 1,
              data: docLabels,
              axisLabel: {
                color: "#888",
                fontSize: 10,
                fontFamily: "monospace",
                width: 150,
                overflow: "truncate" as const,
              },
              axisLine: { lineStyle: { color: "#333" } },
              splitLine: { show: false },
            },
          ]
        : []),
    ],
    series: [
      {
        name: "GPU %",
        type: "line",
        xAxisIndex: 0,
        yAxisIndex: 0,
        data: gpuPoints,
        lineStyle: { color: "#22c55e", width: 2 },
        itemStyle: { color: "#22c55e" },
        symbol: "none",
        smooth: true,
        areaStyle: { color: "rgba(34,197,94,0.08)" },
      },
      {
        name: "VRAM %",
        type: "line",
        xAxisIndex: 0,
        yAxisIndex: 0,
        data: vramPoints,
        lineStyle: { color: "#f97316", width: 2 },
        itemStyle: { color: "#f97316" },
        symbol: "none",
        smooth: true,
        areaStyle: { color: "rgba(249,115,22,0.08)" },
      },
      ...(hasSwimData
        ? [
            {
              name: "swimlane",
              type: "custom" as const,
              xAxisIndex: 1,
              yAxisIndex: 1,
              renderItem: (
                _params: unknown,
                api: {
                  value: (idx: number) => number;
                  coord: (v: number[]) => number[];
                  size: (v: number[]) => number[];
                  style: () => unknown;
                }
              ) => {
                const rowIdx = api.value(0);
                const startMs = api.value(1);
                const endMs = api.value(2);
                const startCoord = api.coord([startMs, rowIdx]);
                const endCoord = api.coord([endMs, rowIdx]);
                const height = (api.size([0, 1]) as number[])[1] * 0.6;
                const width = Math.max(endCoord[0] - startCoord[0], 2);
                return {
                  type: "rect",
                  shape: {
                    x: startCoord[0],
                    y: startCoord[1] - height / 2,
                    width,
                    height,
                    r: 3,
                  },
                  style: api.style(),
                };
              },
              encode: { x: [1, 2], y: 0 },
              data: swimItems,
            },
          ]
        : []),
    ],
    legend: {
      top: 0,
      right: 20,
      data: ["GPU %", "VRAM %"],
      textStyle: { color: "#888", fontSize: 11 },
      inactiveColor: "#444",
    },
  } as EChartsOption;
}

export function PipelineTimeline() {
  const [gpuData, setGpuData] = useState<GpuMetric[]>([]);
  const [events, setEvents] = useState<PipelineEvent[]>([]);
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const chartRef = useRef<ReactECharts | null>(null);

  const refresh = useCallback(async () => {
    try {
      const [metricsRes, eventsRes] = await Promise.allSettled([
        fetch("/api/metrics?minutes=60", { cache: "no-store" }),
        fetch("/api/events?minutes=60", { cache: "no-store" }),
      ]);

      if (
        metricsRes.status === "fulfilled" &&
        metricsRes.value.ok
      ) {
        const data = (await metricsRes.value.json()) as GpuMetric[];
        setGpuData(data);
      }

      if (eventsRes.status === "fulfilled" && eventsRes.value.ok) {
        const data = (await eventsRes.value.json()) as PipelineEvent[];
        setEvents(data);
      }

      setLastUpdated(new Date());
    } catch {
      // silently ignore
    }
  }, []);

  useEffect(() => {
    void refresh();
    const interval = setInterval(() => void refresh(), 10_000);
    return () => clearInterval(interval);
  }, [refresh]);

  const option = buildChartOption(gpuData, events);

  return (
    <div className="rounded-xl border border-neutral-800 bg-neutral-900 p-4">
      <div className="flex items-center justify-between mb-3">
        <h2 className="text-sm font-semibold text-neutral-300">
          GPU &amp; Pipeline — last 60 minutes
        </h2>
        {lastUpdated && (
          <span className="text-xs text-neutral-600 font-mono">
            {lastUpdated.toLocaleTimeString()}
          </span>
        )}
      </div>
      {gpuData.length === 0 && events.length === 0 ? (
        <div className="flex items-center justify-center h-40 text-neutral-600 text-sm font-mono">
          No data — collector starting up…
        </div>
      ) : (
        <ReactECharts
          ref={chartRef}
          option={option}
          style={{ height: events.length > 0 ? 420 : 220 }}
          opts={{ renderer: "canvas" }}
          notMerge
        />
      )}
    </div>
  );
}
