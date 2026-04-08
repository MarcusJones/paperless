// instrumentation.ts — Next.js server startup hook.
// Runs once when the Node.js process starts (not in Edge runtime).
// Starts two background jobs:
//   Job A: GPU poller — reads gpu-monitor container logs every 5s
//   Job B: Pipeline event tailer — reads pipeline-timing container JSONL output

export async function register() {
  // Guard: only run in Node.js runtime, not Edge
  if (process.env.NEXT_RUNTIME !== "nodejs") return;

  // Delay startup to allow QuestDB to become ready
  await sleep(5000);

  console.log("[collector] Starting background data collector…");

  await Promise.allSettled([startGpuPoller(), startPipelineEventTailer()]);
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ── Job A: GPU Poller ──────────────────────────────────────────────────────────

async function startGpuPoller() {
  const containerName =
    process.env.GPU_MONITOR_CONTAINER ?? "paperless-gpu-monitor-1";

  console.log(`[collector] GPU poller starting (container: ${containerName})`);

  // Dynamically import to avoid loading dockerode at build time
  const { getLastLogLines, parseGpuMonitorLine } = await import(
    "@/lib/docker"
  );
  const { insertGpuMetric, ensureTables } = await import("@/lib/questdb");

  // Ensure QuestDB tables exist, retrying until QuestDB is up
  let ready = false;
  for (let attempt = 0; attempt < 20; attempt++) {
    try {
      await ensureTables();
      ready = true;
      console.log("[collector] QuestDB tables ready");
      break;
    } catch {
      await sleep(5000);
    }
  }
  if (!ready) {
    console.error("[collector] QuestDB never became ready — GPU poller aborted");
    return;
  }

  // Poll loop — runs forever, retries after failures
  while (true) {
    try {
      const lines = await getLastLogLines(containerName, 1);
      if (lines.length > 0) {
        const parsed = parseGpuMonitorLine(lines[lines.length - 1]);
        if (parsed) {
          await insertGpuMetric({
            ts: new Date().toISOString(),
            ...parsed,
          });
        }
      }
    } catch (err) {
      console.warn("[collector] GPU poll error:", err);
    }
    await sleep(5000);
  }
}

// ── Job B: Pipeline Event Tailer ───────────────────────────────────────────────

interface JsonlEvent {
  ts: string;
  doc_id: number;
  title: string;
  stage: string;
  model: string;
  pages: number;
}

async function startPipelineEventTailer() {
  const containerName =
    process.env.PIPELINE_TIMING_CONTAINER ?? "paperless-pipeline-timing-1";

  console.log(
    `[collector] Pipeline event tailer starting (container: ${containerName})`
  );

  const { tailContainerLogs } = await import("@/lib/docker");
  const { insertPipelineEvent } = await import("@/lib/questdb");

  // Retry loop — reconnects if the container restarts or tailing drops
  while (true) {
    try {
      for await (const line of tailContainerLogs(containerName, Math.floor(Date.now() / 1000) - 300)) {
        const event = tryParseJsonlEvent(line);
        if (!event) continue;

        try {
          await insertPipelineEvent({
            ts: event.ts,
            doc_id: event.doc_id,
            title: event.title ?? "",
            stage: event.stage,
            model_name: event.model ?? "",
            pages: event.pages ?? 0,
          });
          console.log(
            `[collector] event: doc=${event.doc_id} stage=${event.stage}`
          );
        } catch (err) {
          console.warn("[collector] Failed to insert pipeline event:", err);
        }
      }
    } catch (err) {
      console.warn("[collector] Pipeline tailer error:", err);
    }

    // Back off before reconnecting
    console.log("[collector] Pipeline tailer reconnecting in 30s…");
    await sleep(30_000);
  }
}

function tryParseJsonlEvent(line: string): JsonlEvent | null {
  const trimmed = line.trim();
  if (!trimmed.startsWith("{")) return null;
  try {
    const obj = JSON.parse(trimmed) as JsonlEvent;
    // Must have the minimal required fields
    if (
      typeof obj.doc_id === "number" &&
      typeof obj.stage === "string" &&
      typeof obj.ts === "string"
    ) {
      return obj;
    }
  } catch {
    // Not JSON or not a pipeline event line
  }
  return null;
}
