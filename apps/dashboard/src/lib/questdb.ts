// QuestDB HTTP client — uses the /exec REST endpoint for both reads and writes.
// All timestamps stored as TIMESTAMP (microseconds) in QuestDB.

const QUESTDB_URL =
  process.env.QUESTDB_URL ?? "http://questdb:9000";

export interface GpuMetric {
  ts: string; // ISO 8601
  gpu_pct: number;
  vram_used: number; // MiB
  vram_total: number; // MiB
}

export interface PipelineEvent {
  ts: string; // ISO 8601
  doc_id: number;
  title: string;
  stage: string; // ingest_start | ingest_end | ocr_start | ocr_end | classify_start | classify_end
  model_name: string;
  pages: number;
}

interface QuestDbRow {
  [key: string]: string | number | null;
}

// Execute a SQL query and return rows as typed objects.
export async function query<T extends QuestDbRow>(sql: string): Promise<T[]> {
  const url = `${QUESTDB_URL}/exec?query=${encodeURIComponent(sql)}&limit=1000`;
  const res = await fetch(url, { cache: "no-store" });
  if (!res.ok) {
    throw new Error(`QuestDB query failed: ${res.status} ${await res.text()}`);
  }
  const json = (await res.json()) as {
    columns: { name: string }[];
    dataset: (string | number | null)[][];
  };
  return json.dataset.map((row) => {
    const obj: QuestDbRow = {};
    json.columns.forEach((col, i) => {
      obj[col.name] = row[i];
    });
    return obj as T;
  });
}

// Insert a GPU metric row.
export async function insertGpuMetric(m: GpuMetric): Promise<void> {
  const sql = `INSERT INTO gpu_metrics VALUES (
    '${m.ts}', ${m.gpu_pct}, ${m.vram_used}, ${m.vram_total}
  )`;
  await query(sql);
}

// Insert a pipeline event row.
export async function insertPipelineEvent(e: PipelineEvent): Promise<void> {
  const title = e.title.replace(/'/g, "''"); // escape single quotes
  const model = e.model_name.replace(/'/g, "''");
  const sql = `INSERT INTO pipeline_events VALUES (
    '${e.ts}', ${e.doc_id}, '${title}', '${e.stage}', '${model}', ${e.pages}
  )`;
  await query(sql);
}

// Fetch GPU metrics for the last N minutes.
export async function fetchGpuMetrics(minutes = 60): Promise<GpuMetric[]> {
  const sql = `
    SELECT ts, gpu_pct, vram_used, vram_total
    FROM gpu_metrics
    WHERE ts > dateadd('m', -${minutes}, now())
    ORDER BY ts ASC
  `;
  const rows = await query<{
    ts: string;
    gpu_pct: number;
    vram_used: number;
    vram_total: number;
  }>(sql);
  return rows.map((r) => ({
    ts: r.ts as string,
    gpu_pct: Number(r.gpu_pct),
    vram_used: Number(r.vram_used),
    vram_total: Number(r.vram_total),
  }));
}

// Fetch pipeline events for the last N minutes, most recent 20 docs.
export async function fetchPipelineEvents(minutes = 60): Promise<PipelineEvent[]> {
  const sql = `
    SELECT ts, doc_id, title, stage, model_name, pages
    FROM pipeline_events
    WHERE ts > dateadd('m', -${minutes}, now())
    ORDER BY ts ASC
  `;
  const rows = await query<{
    ts: string;
    doc_id: number;
    title: string;
    stage: string;
    model_name: string;
    pages: number;
  }>(sql);
  return rows.map((r) => ({
    ts: r.ts as string,
    doc_id: Number(r.doc_id),
    title: String(r.title ?? ""),
    stage: String(r.stage ?? ""),
    model_name: String(r.model_name ?? ""),
    pages: Number(r.pages ?? 0),
  }));
}

// Create tables if they don't exist. Called on first startup.
export async function ensureTables(): Promise<void> {
  const gpuDdl = `
    CREATE TABLE IF NOT EXISTS gpu_metrics (
      ts         TIMESTAMP,
      gpu_pct    INT,
      vram_used  INT,
      vram_total INT
    ) TIMESTAMP(ts) PARTITION BY HOUR ;
  `;
  const eventsDdl = `
    CREATE TABLE IF NOT EXISTS pipeline_events (
      ts         TIMESTAMP,
      doc_id     LONG,
      title      SYMBOL,
      stage      SYMBOL,
      model_name SYMBOL,
      pages      INT
    ) TIMESTAMP(ts) PARTITION BY DAY ;
  `;
  await query(gpuDdl);
  await query(eventsDdl);
}
