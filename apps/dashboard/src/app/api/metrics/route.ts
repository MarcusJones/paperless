import { NextRequest, NextResponse } from "next/server";
import { fetchGpuMetrics } from "@/lib/questdb";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export async function GET(req: NextRequest) {
  const minutes = Number(req.nextUrl.searchParams.get("minutes") ?? "60");

  try {
    const metrics = await fetchGpuMetrics(minutes);
    return NextResponse.json(metrics, {
      headers: { "Cache-Control": "no-store" },
    });
  } catch (err) {
    // QuestDB might not be ready yet or tables might not exist
    const message = err instanceof Error ? err.message : String(err);
    return NextResponse.json(
      { error: "metrics unavailable", detail: message },
      { status: 503, headers: { "Cache-Control": "no-store" } }
    );
  }
}
