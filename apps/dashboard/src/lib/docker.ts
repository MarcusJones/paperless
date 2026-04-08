// Docker socket wrapper using dockerode.
// Used by the background collector in instrumentation.ts.
// Gracefully returns null/empty when the socket is unavailable (e.g., devcontainer).

import Dockerode from "dockerode";

let _docker: Dockerode | null = null;

function getDocker(): Dockerode {
  if (!_docker) {
    _docker = new Dockerode({ socketPath: "/var/run/docker.sock" });
  }
  return _docker;
}

// Returns the last N log lines from a container as a string array.
// Returns [] if the container is not found or Docker is unavailable.
export async function getLastLogLines(
  containerName: string,
  tail = 1
): Promise<string[]> {
  try {
    const docker = getDocker();
    const container = docker.getContainer(containerName);
    const stream = await container.logs({
      stdout: true,
      stderr: true,
      tail,
      timestamps: false,
    });
    // dockerode returns a Buffer with Docker multiplexing headers (8-byte prefix per frame)
    const raw = stream as unknown as Buffer;
    return demuxDockerStream(raw);
  } catch {
    return [];
  }
}

// Tail container logs as an async generator yielding lines.
// Yields lines until the generator is closed or the container stops.
export async function* tailContainerLogs(
  containerName: string,
  since?: number // Unix timestamp seconds
): AsyncGenerator<string> {
  try {
    const docker = getDocker();
    const container = docker.getContainer(containerName);
    const stream = await container.logs({
      stdout: true,
      stderr: true,
      follow: true,
      since: since ?? 0,
      timestamps: false,
    });

    // Pipe through a PassThrough to read line by line
    const { PassThrough } = await import("stream");
    const pass = new PassThrough();
    (stream as unknown as NodeJS.ReadableStream).pipe(pass);

    let buffer = "";
    for await (const chunk of pass) {
      // Strip Docker 8-byte multiplexing header from each frame
      const raw = chunk as Buffer;
      const text = stripDockerHeader(raw);
      buffer += text;
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) {
        if (line.trim()) yield line;
      }
    }
  } catch {
    // Socket unavailable or container not found — exit generator silently
  }
}

// Docker stream multiplexing: each frame has an 8-byte header.
// Byte 0: stream type (1=stdout, 2=stderr). Bytes 4-7: uint32 big-endian payload size.
function stripDockerHeader(buf: Buffer): string {
  const parts: string[] = [];
  let offset = 0;
  while (offset < buf.length) {
    if (offset + 8 > buf.length) break;
    const size = buf.readUInt32BE(offset + 4);
    const payload = buf.slice(offset + 8, offset + 8 + size);
    parts.push(payload.toString("utf8"));
    offset += 8 + size;
  }
  // If parsing fails (no valid header), fall back to raw string
  return parts.length > 0 ? parts.join("") : buf.toString("utf8");
}

function demuxDockerStream(buf: Buffer): string[] {
  const text = stripDockerHeader(buf);
  return text
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean);
}

// Parse the gpu-monitor JSON log line format:
// {"vram_used_mb":4521,"vram_total_mb":12288,"gpu_util_pct":72}
export function parseGpuMonitorLine(line: string): {
  gpu_pct: number;
  vram_used: number;
  vram_total: number;
} | null {
  try {
    const obj = JSON.parse(line) as {
      vram_used_mb: number;
      vram_total_mb: number;
      gpu_util_pct: number;
    };
    return {
      gpu_pct: obj.gpu_util_pct,
      vram_used: obj.vram_used_mb,
      vram_total: obj.vram_total_mb,
    };
  } catch {
    return null;
  }
}
