'use strict';
/**
 * collector.js — standalone Node.js process that polls Docker and writes to QuestDB.
 * Started alongside the Next.js server from the Dockerfile CMD.
 * Crashes here do NOT affect the web server.
 */

const Docker = require('dockerode');
const docker = new Docker({ socketPath: '/var/run/docker.sock' });

const QUESTDB_URL = process.env.QUESTDB_URL ?? 'http://questdb:9000';
const GPU_CONTAINER = process.env.GPU_MONITOR_CONTAINER ?? 'paperless-gpu-monitor-1';
const PIPELINE_CONTAINER = process.env.PIPELINE_TIMING_CONTAINER ?? 'paperless-pipeline-timing-1';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ── QuestDB ────────────────────────────────────────────────────────────────────

async function questdb(sql) {
  const res = await fetch(`${QUESTDB_URL}/exec?query=${encodeURIComponent(sql)}`);
  if (!res.ok) throw new Error(`QuestDB ${res.status}: ${await res.text()}`);
  return res.json();
}

async function ensureTables() {
  await questdb(`CREATE TABLE IF NOT EXISTS gpu_metrics (
    ts TIMESTAMP, gpu_pct INT, vram_used INT, vram_total INT
  ) TIMESTAMP(ts) PARTITION BY HOUR`);
  await questdb(`CREATE TABLE IF NOT EXISTS pipeline_events (
    ts TIMESTAMP, doc_id LONG, title SYMBOL, stage SYMBOL, model_name SYMBOL, pages INT
  ) TIMESTAMP(ts) PARTITION BY DAY`);
  console.log('[collector] QuestDB tables ready');
}

// ── Docker helpers ─────────────────────────────────────────────────────────────

// Docker log frames have an 8-byte multiplexing header per frame.
function stripDockerHeader(buf) {
  const parts = [];
  let offset = 0;
  while (offset < buf.length) {
    if (offset + 8 > buf.length) break;
    const size = buf.readUInt32BE(offset + 4);
    parts.push(buf.slice(offset + 8, offset + 8 + size).toString('utf8'));
    offset += 8 + size;
  }
  return parts.length > 0 ? parts.join('') : buf.toString('utf8');
}

async function getLastLogLine(containerName) {
  try {
    const container = docker.getContainer(containerName);
    const buf = await container.logs({ stdout: true, stderr: true, tail: 1, timestamps: false });
    return stripDockerHeader(buf).trim();
  } catch {
    return null;
  }
}

// ── GPU poller ─────────────────────────────────────────────────────────────────
// Reads gpu-monitor JSON output every 5s.
// Format: {"vram_used_mb":4521,"vram_total_mb":12288,"gpu_util_pct":72}

async function gpuPoller() {
  console.log(`[collector] GPU poller starting (${GPU_CONTAINER})`);
  while (true) {
    try {
      const line = await getLastLogLine(GPU_CONTAINER);
      if (line) {
        const o = JSON.parse(line);
        if (typeof o.gpu_util_pct === 'number') {
          const ts = new Date().toISOString();
          await questdb(
            `INSERT INTO gpu_metrics VALUES ('${ts}', ${o.gpu_util_pct}, ${o.vram_used_mb}, ${o.vram_total_mb})`
          );
        }
      }
    } catch (err) {
      console.warn('[collector] GPU poll error:', err.message);
    }
    await sleep(5000);
  }
}

// ── Pipeline event tailer ──────────────────────────────────────────────────────
// Tails pipeline-timing container JSONL output and writes events to QuestDB.

async function pipelineTailer() {
  const { PassThrough } = require('stream');
  console.log(`[collector] Pipeline tailer starting (${PIPELINE_CONTAINER})`);

  while (true) {
    try {
      const container = docker.getContainer(PIPELINE_CONTAINER);
      const since = Math.floor(Date.now() / 1000) - 300; // last 5 min on reconnect
      const stream = await container.logs({
        stdout: true,
        stderr: true,
        follow: true,
        since,
        timestamps: false,
      });

      const pass = new PassThrough();
      stream.pipe(pass);

      let buf = '';
      for await (const chunk of pass) {
        const text = stripDockerHeader(chunk);
        buf += text;
        const lines = buf.split('\n');
        buf = lines.pop() ?? '';

        for (const line of lines) {
          const trimmed = line.trim();
          if (!trimmed.startsWith('{')) continue;
          try {
            const e = JSON.parse(trimmed);
            if (typeof e.doc_id !== 'number' || !e.stage || !e.ts) continue;
            const title = (e.title ?? '').replace(/'/g, "''");
            const model = (e.model ?? '').replace(/'/g, "''");
            await questdb(
              `INSERT INTO pipeline_events VALUES ('${e.ts}', ${e.doc_id}, '${title}', '${e.stage}', '${model}', ${e.pages ?? 0})`
            );
            console.log(`[collector] event: doc=${e.doc_id} stage=${e.stage}`);
          } catch { /* skip malformed lines */ }
        }
      }
    } catch (err) {
      console.warn('[collector] Pipeline tailer error:', err.message);
    }
    console.log('[collector] Pipeline tailer reconnecting in 30s…');
    await sleep(30_000);
  }
}

// ── Main ───────────────────────────────────────────────────────────────────────

async function main() {
  console.log('[collector] Starting…');

  // Wait for QuestDB to be ready (retries for up to ~100s)
  let ready = false;
  for (let i = 0; i < 20; i++) {
    try {
      await ensureTables();
      ready = true;
      break;
    } catch (err) {
      console.log(`[collector] Waiting for QuestDB (${i + 1}/20): ${err.message}`);
      await sleep(5000);
    }
  }
  if (!ready) {
    console.error('[collector] QuestDB never became ready — exiting');
    process.exit(1);
  }

  // Run both collectors; an error in one does not kill the other
  await Promise.all([
    gpuPoller().catch((err) => console.error('[collector] GPU poller crashed:', err)),
    pipelineTailer().catch((err) => console.error('[collector] Pipeline tailer crashed:', err)),
  ]);
}

main().catch((err) => {
  console.error('[collector] Fatal:', err);
  process.exit(1);
});
