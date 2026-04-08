import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "standalone",
  // instrumentation.ts is stable in Next.js 15 — no experimental flag needed
};

export default nextConfig;
