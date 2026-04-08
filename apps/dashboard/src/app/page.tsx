import { ServiceCards } from "@/components/service-cards";
import { PipelineTimeline } from "@/components/pipeline-timeline";
import { SettingsModal } from "@/components/settings-modal";

export default function DashboardPage() {
  return (
    <main className="max-w-[1600px] mx-auto px-4 py-6 space-y-6">
      {/* Header */}
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-xl font-semibold text-neutral-100 tracking-tight">
            Paperless Stack
          </h1>
          <p className="text-xs text-neutral-600 mt-0.5 font-mono">
            AI document pipeline — 3 stages
          </p>
        </div>
        <div className="flex items-center gap-3">
          <SettingsModal />
        </div>
      </header>

      {/* GPU + Pipeline timeline */}
      <PipelineTimeline />

      {/* Service cards */}
      <section>
        <h2 className="text-xs font-semibold text-neutral-600 uppercase tracking-widest mb-3">
          Services
        </h2>
        <ServiceCards />
      </section>
    </main>
  );
}
