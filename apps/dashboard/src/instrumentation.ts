// Shim required for Next.js to load instrumentation.node.ts.
// All actual collector logic lives in instrumentation.node.ts (Node.js only).
export async function register() {}
