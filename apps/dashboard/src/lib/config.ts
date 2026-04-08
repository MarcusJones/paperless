import fs from "fs";
import path from "path";
import yaml from "js-yaml";

export interface ServiceConfig {
  name: string;
  url: string;
  internalUrl: string;
  dozzleContainer: string;
  probeUrl: string;
}

export interface StackConfig {
  services: Record<string, ServiceConfig>;
}

// Fallback is the production Docker path (/app/config/stack.yaml).
// Set CONFIG_PATH env var to override in other environments.
const CONFIG_PATH = process.env.CONFIG_PATH ?? "/app/config/stack.yaml";

// In-memory cache; reload on each request (file is small)
export function readConfig(): StackConfig {
  try {
    const raw = fs.readFileSync(CONFIG_PATH, "utf8");
    return yaml.load(raw) as StackConfig;
  } catch {
    // Fall back to env-based defaults when config file is absent
    return buildDefaultConfig();
  }
}

export function writeConfig(config: StackConfig): void {
  const dir = path.dirname(CONFIG_PATH);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(CONFIG_PATH, yaml.dump(config), "utf8");
}

function buildDefaultConfig(): StackConfig {
  const paperlessUrl = process.env.PAPERLESS_URL ?? "http://paperless:8000";
  const ollamaUrl = process.env.OLLAMA_URL ?? "http://ollama:11434";

  return {
    services: {
      paperless: {
        name: "Paperless-ngx",
        url: "http://localhost:8000",
        internalUrl: paperlessUrl,
        dozzleContainer: "paperless-paperless-1",
        probeUrl: `${paperlessUrl}/accounts/login/`,
      },
      "paperless-ai-next": {
        name: "paperless-ai-next",
        url: "http://localhost:3000",
        internalUrl: "http://paperless-ai-next:3000",
        dozzleContainer: "paperless-paperless-ai-next-1",
        probeUrl: "http://paperless-ai-next:3000/health",
      },
      "paperless-gpt": {
        name: "paperless-gpt",
        url: "http://localhost:8080",
        internalUrl: "http://paperless-gpt:8080",
        dozzleContainer: "paperless-paperless-gpt-1",
        probeUrl: "http://paperless-gpt:8080/",
      },
      ollama: {
        name: "Ollama",
        url: "http://localhost:11434",
        internalUrl: ollamaUrl,
        dozzleContainer: "paperless-ollama-1",
        probeUrl: `${ollamaUrl}/api/tags`,
      },
      "open-webui": {
        name: "Open WebUI",
        url: "http://localhost:3001",
        internalUrl: "http://open-webui:3001",
        dozzleContainer: "paperless-open-webui-1",
        probeUrl: "http://open-webui:3001/",
      },
      dozzle: {
        name: "Dozzle",
        url: "http://localhost:9999",
        internalUrl: "http://dozzle:9999",
        dozzleContainer: "paperless-dozzle-1",
        probeUrl: "http://dozzle:9999/",
      },
      questdb: {
        name: "QuestDB",
        url: "http://localhost:9000",
        internalUrl: "http://questdb:9000",
        dozzleContainer: "paperless-questdb-1",
        probeUrl: "http://questdb:9000/",
      },
    },
  };
}
