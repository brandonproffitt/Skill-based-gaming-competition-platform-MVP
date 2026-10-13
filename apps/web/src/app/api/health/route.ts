import { connection } from "next/server";
import { serverEnv } from "@/lib/env";

export async function GET() {
  await connection(); // report live config at request time, not build time
  const env = serverEnv();
  return Response.json({
    ok: true,
    chainId: env.CHAIN_ID,
    databaseConfigured: Boolean(env.DATABASE_URL),
  });
}
