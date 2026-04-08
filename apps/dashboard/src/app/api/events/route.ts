import { NextRequest, NextResponse } from "next/server";
import { fetchPipelineEvents } from "@/lib/questdb";

export const dynamic = "force-dynamic";
export const revalidate = 0;

export async function GET(req: NextRequest) {
  const minutes = Number(req.nextUrl.searchParams.get("minutes") ?? "60");

  try {
    const events = await fetchPipelineEvents(minutes);
    return NextResponse.json(events, {
      headers: { "Cache-Control": "no-store" },
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return NextResponse.json(
      { error: "events unavailable", detail: message },
      { status: 503, headers: { "Cache-Control": "no-store" } }
    );
  }
}
