import { NextRequest, NextResponse } from "next/server";
import { readConfig, writeConfig, type StackConfig } from "@/lib/config";

export const dynamic = "force-dynamic";

export async function GET() {
  const config = readConfig();
  return NextResponse.json(config);
}

export async function PUT(req: NextRequest) {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return NextResponse.json({ error: "invalid JSON" }, { status: 400 });
  }

  // Validate top-level shape
  if (
    typeof body !== "object" ||
    body === null ||
    !("services" in body) ||
    typeof (body as StackConfig).services !== "object"
  ) {
    return NextResponse.json(
      { error: "body must be { services: { ... } }" },
      { status: 400 }
    );
  }

  try {
    writeConfig(body as StackConfig);
    return NextResponse.json({ ok: true });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return NextResponse.json(
      { error: "failed to write config", detail: message },
      { status: 500 }
    );
  }
}
