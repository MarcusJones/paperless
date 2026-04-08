import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "standalone",
  turbopack: {},
  // Exclude dockerode and its native deps from bundling — required at runtime from node_modules
  serverExternalPackages: ["dockerode", "ssh2", "cpu-features", "docker-modem"],
};

export default nextConfig;
