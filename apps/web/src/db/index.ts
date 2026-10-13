import "server-only";
import { neon } from "@neondatabase/serverless";
import { drizzle, type NeonHttpDatabase } from "drizzle-orm/neon-http";
import { serverEnv } from "@/lib/env";
import * as schema from "./schema";

let client: NeonHttpDatabase<typeof schema> | undefined;

/** Lazily creates the Neon HTTP client so pages that don't touch the DB work without DATABASE_URL. */
export function db(): NeonHttpDatabase<typeof schema> {
  if (!client) {
    const url = serverEnv().DATABASE_URL;
    if (!url) throw new Error("DATABASE_URL is not set. See .env.example.");
    client = drizzle(neon(url), { schema });
  }
  return client;
}
