"use client";

import { useState, useEffect, useCallback } from "react";
import * as Dialog from "@radix-ui/react-dialog";
import * as Tabs from "@radix-ui/react-tabs";
import { Settings, X, Check, RotateCcw } from "lucide-react";

interface ServiceConfig {
  name: string;
  url: string;
  internalUrl: string;
  dozzleContainer: string;
  probeUrl: string;
}

interface StackConfig {
  services: Record<string, ServiceConfig>;
}

interface ServiceStatus {
  key: string;
  status: "green" | "yellow" | "red";
  latencyMs: number;
}

const STATUS_DOT: Record<string, string> = {
  green: "bg-green-500",
  yellow: "bg-yellow-400",
  red: "bg-red-500",
};

function ServiceRow({
  serviceKey,
  config,
  status,
  onUpdate,
}: {
  serviceKey: string;
  config: ServiceConfig;
  status?: ServiceStatus;
  onUpdate: (key: string, updated: ServiceConfig) => void;
}) {
  const [editing, setEditing] = useState(false);
  const [urlVal, setUrlVal] = useState(config.url);

  const save = () => {
    onUpdate(serviceKey, { ...config, url: urlVal });
    setEditing(false);
  };

  const cancel = () => {
    setUrlVal(config.url);
    setEditing(false);
  };

  return (
    <div className="flex items-center gap-3 py-2 border-b border-neutral-800 last:border-0">
      <span
        className={`h-2 w-2 rounded-full shrink-0 ${STATUS_DOT[status?.status ?? "red"] ?? "bg-neutral-600"}`}
      />
      <span className="w-36 text-sm text-neutral-300 shrink-0">{config.name}</span>

      {editing ? (
        <div className="flex flex-1 items-center gap-2">
          <input
            value={urlVal}
            onChange={(e) => setUrlVal(e.target.value)}
            className="flex-1 bg-neutral-800 border border-neutral-600 rounded px-2 py-1 text-xs font-mono text-neutral-200 outline-none focus:border-neutral-400"
            autoFocus
            onKeyDown={(e) => {
              if (e.key === "Enter") save();
              if (e.key === "Escape") cancel();
            }}
          />
          <button
            onClick={save}
            className="p-1 text-green-400 hover:text-green-300"
            title="Save"
          >
            <Check size={14} />
          </button>
          <button
            onClick={cancel}
            className="p-1 text-neutral-500 hover:text-neutral-300"
            title="Cancel"
          >
            <RotateCcw size={14} />
          </button>
        </div>
      ) : (
        <div className="flex flex-1 items-center gap-2">
          <span className="flex-1 text-xs font-mono text-neutral-500">
            {config.url}
          </span>
          {status?.latencyMs !== undefined && status.status !== "red" && (
            <span className="text-xs font-mono text-neutral-700">
              {status.latencyMs}ms
            </span>
          )}
          <button
            onClick={() => setEditing(true)}
            className="text-xs text-neutral-600 hover:text-neutral-400 px-1"
          >
            Edit
          </button>
        </div>
      )}
    </div>
  );
}

export function SettingsModal() {
  const [open, setOpen] = useState(false);
  const [config, setConfig] = useState<StackConfig | null>(null);
  const [statuses, setStatuses] = useState<ServiceStatus[]>([]);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);

  const loadConfig = useCallback(async () => {
    const [cfgRes, statusRes] = await Promise.allSettled([
      fetch("/api/config"),
      fetch("/api/status", { cache: "no-store" }),
    ]);
    if (cfgRes.status === "fulfilled" && cfgRes.value.ok) {
      setConfig((await cfgRes.value.json()) as StackConfig);
    }
    if (statusRes.status === "fulfilled" && statusRes.value.ok) {
      setStatuses((await statusRes.value.json()) as ServiceStatus[]);
    }
  }, []);

  useEffect(() => {
    if (open) void loadConfig();
  }, [open, loadConfig]);

  const handleUpdate = (key: string, updated: ServiceConfig) => {
    if (!config) return;
    setConfig({
      ...config,
      services: { ...config.services, [key]: updated },
    });
  };

  const handleSave = async () => {
    if (!config) return;
    setSaving(true);
    setSaveError(null);
    try {
      const res = await fetch("/api/config", {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(config),
      });
      if (!res.ok) {
        const err = (await res.json()) as { error?: string };
        setSaveError(err.error ?? "Save failed");
      }
    } catch (e) {
      setSaveError(String(e));
    } finally {
      setSaving(false);
    }
  };

  const statusMap = Object.fromEntries(statuses.map((s) => [s.key, s]));

  return (
    <Dialog.Root open={open} onOpenChange={setOpen}>
      <Dialog.Trigger asChild>
        <button
          className="p-1.5 rounded-md text-neutral-500 hover:text-neutral-300 hover:bg-neutral-800 transition-colors"
          title="Settings"
        >
          <Settings size={18} />
        </button>
      </Dialog.Trigger>

      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 bg-black/60 z-40" />
        <Dialog.Content className="fixed left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 z-50 w-full max-w-2xl bg-neutral-950 border border-neutral-800 rounded-2xl shadow-2xl p-0 overflow-hidden">
          {/* Header */}
          <div className="flex items-center justify-between px-6 py-4 border-b border-neutral-800">
            <Dialog.Title className="text-base font-semibold text-neutral-100">
              Settings
            </Dialog.Title>
            <Dialog.Close asChild>
              <button className="p-1 text-neutral-600 hover:text-neutral-300 rounded">
                <X size={16} />
              </button>
            </Dialog.Close>
          </div>

          {/* Tabs */}
          <Tabs.Root defaultValue="services" className="flex flex-col">
            <Tabs.List className="flex gap-0 border-b border-neutral-800 px-6">
              {(["services", "pipeline"] as const).map((tab) => (
                <Tabs.Trigger
                  key={tab}
                  value={tab}
                  className="px-4 py-2.5 text-sm text-neutral-500 capitalize border-b-2 border-transparent data-[state=active]:text-neutral-100 data-[state=active]:border-neutral-300 transition-colors"
                >
                  {tab}
                </Tabs.Trigger>
              ))}
            </Tabs.List>

            {/* Services tab */}
            <Tabs.Content value="services" className="px-6 py-4">
              {config ? (
                <div className="flex flex-col">
                  {Object.entries(config.services).map(([key, svc]) => (
                    <ServiceRow
                      key={key}
                      serviceKey={key}
                      config={svc}
                      status={statusMap[key]}
                      onUpdate={handleUpdate}
                    />
                  ))}
                </div>
              ) : (
                <div className="py-8 text-center text-neutral-600 text-sm">
                  Loading…
                </div>
              )}

              {saveError && (
                <p className="mt-3 text-xs text-red-400">{saveError}</p>
              )}

              <div className="flex justify-end gap-2 mt-4 pt-4 border-t border-neutral-800">
                <Dialog.Close asChild>
                  <button className="px-4 py-2 text-sm text-neutral-400 hover:text-neutral-200 transition-colors">
                    Close
                  </button>
                </Dialog.Close>
                <button
                  onClick={() => void handleSave()}
                  disabled={saving}
                  className="px-4 py-2 text-sm bg-neutral-700 hover:bg-neutral-600 text-neutral-100 rounded-md transition-colors disabled:opacity-50"
                >
                  {saving ? "Saving…" : "Save"}
                </button>
              </div>
            </Tabs.Content>

            {/* Pipeline tab */}
            <Tabs.Content value="pipeline" className="px-6 py-4">
              <div className="space-y-4">
                <p className="text-sm text-neutral-500">
                  Current pipeline configuration — read-only. Edit via{" "}
                  <code className="text-neutral-400 bg-neutral-800 px-1 py-0.5 rounded text-xs">
                    paperless-ai-next/.env
                  </code>{" "}
                  and{" "}
                  <code className="text-neutral-400 bg-neutral-800 px-1 py-0.5 rounded text-xs">
                    paperless-gpt/.env
                  </code>
                  .
                </p>

                <div className="space-y-2">
                  <PipelineRow label="Vision OCR model" value="qwen2.5vl:7b" />
                  <PipelineRow label="Classify model" value="qwen3:14b" />
                  <PipelineRow label="OCR trigger tag" value="paperless-gpt-ocr-auto" />
                  <PipelineRow label="Classify trigger tag" value="ai-process" />
                  <PipelineRow label="Max loaded models" value="1 (VRAM limit)" />
                </div>

                <p className="text-xs text-neutral-700 mt-4">
                  Pipeline configuration editing will be added in PRD 2 (Smart Pipeline).
                </p>
              </div>

              <div className="flex justify-end mt-4 pt-4 border-t border-neutral-800">
                <Dialog.Close asChild>
                  <button className="px-4 py-2 text-sm text-neutral-400 hover:text-neutral-200 transition-colors">
                    Close
                  </button>
                </Dialog.Close>
              </div>
            </Tabs.Content>
          </Tabs.Root>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

function PipelineRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center gap-3 py-1.5">
      <span className="w-44 text-sm text-neutral-500 shrink-0">{label}</span>
      <span className="text-sm font-mono text-neutral-300">{value}</span>
    </div>
  );
}
