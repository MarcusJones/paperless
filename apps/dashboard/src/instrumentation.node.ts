// Collector has moved to collector.js — started as a sibling process in the Dockerfile CMD.
// Next.js does not compile instrumentation.node.ts in standalone mode,
// so this file is intentionally a no-op.
export async function register() {}
